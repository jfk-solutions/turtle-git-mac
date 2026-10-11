// SPDX-License-Identifier: GPL-2.0-or-later
// Native consumers of AppUtils::EditNote and GitLogList::RevertSelectedCommits.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class HistoryNotesWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryNotesWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences: UserDefaults) {
        model = HistoryNotesWindowModel(repository: repository, access: access, revision: revision)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Edit Notes – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 560, height: 280)
        window.contentViewController = NSHostingController(rootView: HistoryNotesDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in guard let self, !self.model.saving else { return }; self.close() }
        DialogGeometry.attach(window, identifier: "HistoryNotesWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.saving && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); if let window { window.sheetParent?.endSheet(window) }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class HistoryNotesWindowModel: ObservableObject {
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
    var canSave: Bool { !invalidated && !loading && !saving && snapshot?.accepts(text) == true }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String) { self.repository = repository; self.access = access; self.revision = revision }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        guard !invalidated, !loading, !saving, snapshot == nil else { return }
        loading = true; error = nil
        let token = OperationCancellation(); cancellation = token
        worker = Task { [weak self, access, repository, revision] in
            _ = access
            do {
                guard let self else { return }; try self.validateAccess()
                let note = try await repository.editableCommitNote(revision: revision, cancellation: token)
                guard !self.invalidated, self.cancellation === token, !token.isCancelled else { return }
                self.snapshot = note; self.text = note.text
            } catch { if let self, !self.invalidated, self.cancellation === token, !token.isCancelled { self.error = error.localizedDescription } }
            guard let self, self.cancellation === token else { return }
            self.cancellation = nil; self.worker = nil; self.loading = false
        }
    }
    func save() {
        guard canSave, let snapshot else { return }; saving = true; error = nil
        let text = text
        // Notes mutation is atomic at Git's ref lock and is kept open until it ends.
        worker = Task { [weak self, access, repository] in
            _ = access
            do {
                guard let self else { return }; try self.validateAccess()
                let display = try await repository.saveCommitNote(snapshot, text: text)
                guard !self.invalidated else { return }
                self.saving = false; self.worker = nil; self.onChanged(display); self.close()
            } catch {
                guard let self, !self.invalidated else { return }
                self.saving = false; self.worker = nil
                if let failure = error as? CommitNoteFailure, case .savedButRefreshFailed = failure { self.onChanged(error.localizedDescription) }
                self.error = error.localizedDescription
            }
        }
    }
    func invalidate() { invalidated = true; cancellation?.cancel(); cancellation = nil; if !saving { worker?.cancel() }; worker = nil; loading = false }
}
private struct HistoryNotesDialog: View {
    @ObservedObject var model: HistoryNotesWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Notes").font(.headline)
            LogNotesEditor(text: $model.text, enabled: !model.loading && !model.saving, accept: model.save)
                .frame(minHeight: 190, maxHeight: .infinity).border(Color.secondary.opacity(0.3))
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.loading || model.saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK", action: model.save).disabled(!model.canSave).keyboardShortcut(.return, modifiers: .command)
                Button("Cancel", action: model.close).disabled(model.saving).keyboardShortcut(.cancelAction)
            }
        }.padding(12).frame(minWidth: 560, minHeight: 280)
    }
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
        guard !started, !invalidated else { return }; started = true; busy = true
        worker = Task { [weak self, access] in
            _ = access
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
                    self.output += entry.hash + " " + entry.subject + "\n"
                    do {
                        let result = try await self.repository.revertLogRevision(revision: entry.hash, mainline: self.entries.count == 1 ? self.mainline : nil, cancellation: self.cancellation)
                        guard !self.invalidated else { return }
                        self.output += result.text; changed = true
                        if let message = try? String(contentsOf: messageURL, encoding: .utf8) { messages += (messages.isEmpty ? "" : "\n") + message }
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
