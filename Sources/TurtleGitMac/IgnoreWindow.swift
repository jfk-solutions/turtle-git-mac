import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class IgnoreWindowController: NSWindowController, NSWindowDelegate {
    let model: IgnoreWindowModel
    var onClosed: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    private var retired = false
    private var question: (id: UUID, alert: NSAlert, reply: (NSApplication.ModalResponse?) -> Void)?
    var presentQuestion: (NSWindow, NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, alert, reply in
        guard owner.attachedSheet == nil else { return false }; alert.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], mask: Bool, delete: Bool, preferences: UserDefaults = .standard) throws {
        model = IgnoreWindowModel(repository: repository, access: access, options: try IgnoreOptions(paths: paths, mask: mask), delete: delete)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Ignore – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 550, height: 300)
        window.contentViewController = NSHostingController(rootView: IgnoreDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 550, height: 300)); window.center()
        model.close = { [weak self] in guard let self, !self.retired else { return }; self.window?.close() }
        model.onRulesWritten = { [weak self] files in
            guard let self, !self.retired else { return }
            self.onChanged(files.isEmpty ? "Ignore rules already present." : "Updated ignore rules in " + files.map(\.path).joined(separator: ", "))
        }
        model.chooseKeepLocal = { [weak self] in
            let alert = NSAlert(); alert.messageText = "Keep file locally?"; alert.alertStyle = .warning
            alert.informativeText = "Yes removes the selected paths from version control and keeps their local contents. No also removes their working copies, including local modifications."
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            let answer = await self?.ask(alert)
            if answer == .alertFirstButtonReturn { return true }; if answer == .alertSecondButtonReturn { return false }; return nil
        }
        model.continueAfterRemovalFailure = { [weak self] path, message in
            let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "Could not remove “\(path)”"
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
            alert.informativeText = message + "\nOK continues with the next path. The ignore rules have already been written."
            return await self?.ask(alert) == .alertFirstButtonReturn
        }
        model.showRemovalSummary = { [weak self] count in
            guard let self, !self.retired else { return }
            let message = "\(count) files removed."; self.onChanged(message)
            let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "OK")
            _ = await self.ask(alert)
        }
        DialogGeometry.attach(window, identifier: "IgnoreDialog", legacyName: "IgnoreDialog")
    }
    private func ask(_ alert: NSAlert) async -> NSApplication.ModalResponse? {
        guard !retired, question == nil, let window, window.attachedSheet == nil else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) })
            if !presentQuestion(window, alert, { [weak self] answer in self?.finishQuestion(id, answer: answer) }) { finishQuestion(id, answer: nil) }
        }
    }
    private func finishQuestion(_ id: UUID, answer: NSApplication.ModalResponse?) {
        guard let pending = question, pending.id == id else { return }; question = nil
        if pending.alert.window.sheetParent === window { window?.endSheet(pending.alert.window, returnCode: answer ?? .abort) }
        pending.alert.window.orderOut(nil); pending.reply(answer)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && question == nil && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true; model.invalidate()
        if let pending = question { finishQuestion(pending.id, answer: nil) }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class IgnoreWindowModel: ObservableObject {
    static private(set) var activeOperations = 0
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let delete: Bool
    private var retired = false, submitted = false
    private var cancellation: OperationCancellation?
    @Published var options: IgnoreOptions
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var removed = 0
    var close: () -> Void = {}
    var onRulesWritten: ([URL]) -> Void = { _ in }
    var chooseKeepLocal: () async -> Bool? = { nil }
    var continueAfterRemovalFailure: (String, String) async -> Bool = { _, _ in false }
    var showRemovalSummary: (Int) async -> Void = { _ in }
    var writeRules: ((IgnoreOptions, OperationCancellation) async throws -> [URL])?
    var removePath: ((String, Bool, OperationCancellation) async throws -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, options: IgnoreOptions, delete: Bool = false) {
        self.repository = repository; self.access = access; self.options = options; self.delete = delete
    }
    var requiresSecurityScope = GitRuntime.isAppStoreBuild
    var validateMutation: (OperationCancellation, Bool) async throws -> Void = { _, _ in }
    func cancel() { cancellation?.cancel() }
    func invalidate() { retired = true; cancellation?.cancel(); busy = false }
    private func isCurrent(_ token: OperationCancellation) -> Bool { !retired && cancellation === token && !token.isCancelled }
    func apply() {
        guard !retired, !submitted, !busy else { return }; busy = true; error = nil; removed = 0
        let selected = options, token = OperationCancellation(); cancellation = token
        Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1; if cancellation === token { cancellation = nil; if !retired { busy = false } } }
            do {
                let destinations = try await repository.ignoreDestinations(selected, cancellation: token)
                guard isCurrent(token) else { return }
                if requiresSecurityScope {
                    guard access?.hasSecurityScope == true, access?.contains(repository.root) == true,
                          destinations.allSatisfy({ access?.permits($0) == true }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
                try await validateMutation(token, true); try token.check()
                guard isCurrent(token) else { return }
                let files: [URL]
                if let writeRules { files = try await writeRules(selected, token) }
                else { files = try await repository.addIgnoreRules(selected, cancellation: token) }
                guard isCurrent(token) else { return }; onRulesWritten(files)
                guard isCurrent(token) else { return }
                if delete {
                    guard let keepLocal = await chooseKeepLocal(), isCurrent(token) else { if isCurrent(token) { submitted = true; close() }; return }
                    try await validateMutation(token, false); try token.check()
                    for path in selected.paths {
                        guard isCurrent(token) else { return }
                        do {
                            try await validateMutation(token, false); try token.check()
                            if let removePath { try await removePath(path, keepLocal, token) }
                            else { _ = try await repository.removeVersionedPath(path, keepLocal: keepLocal, cancellation: token) }
                            guard isCurrent(token) else { return }; removed += 1
                        } catch {
                            guard isCurrent(token) else { return }
                            let proceed = await continueAfterRemovalFailure(path, error.localizedDescription)
                            guard isCurrent(token) else { return }
                            if !proceed { submitted = true; close(); return }
                        }
                    }
                    guard isCurrent(token) else { return }; await showRemovalSummary(removed)
                }
                guard isCurrent(token) else { return }; submitted = true; close()
            } catch { if isCurrent(token) { self.error = error.localizedDescription } }
        }
    }
}

private struct IgnoreDialog: View {
    @ObservedObject var model: IgnoreWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Ignore Type") {
                Picker("Ignore Type", selection: $model.options.scope) {
                    Text("Ignore item(s) only in the containing folder(s)").tag(IgnoreScope.containingFolder)
                    Text("Ignore item(s) recursively").tag(IgnoreScope.recursively)
                }.pickerStyle(.radioGroup).labelsHidden().frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("Ignore File") {
                Picker("Ignore File", selection: $model.options.destination) {
                    Text(".gitignore in the repository root").tag(IgnoreDestination.repositoryRoot)
                    Text(".gitignore in the containing directories of the items").tag(IgnoreDestination.containingFolders)
                    Text(".git/info/exclude").tag(IgnoreDestination.exclude)
                }.pickerStyle(.radioGroup).labelsHidden().frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.apply() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button { TurtleGitHelp.show(.ignore) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(16).disabled(model.busy)
        .alert("Could not update ignore rules", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

/// The shared status-list Ignore action writes rules, without removing tracked
/// files. Its containing-folder entry is distinct from the shell Delete/ignore.
struct IgnoreSelectionMenu: View {
    let paths: [String]
    var deleting = false
    let action: (RepositoryAction, [String]) -> Void
    var body: some View {
        let suffixes = paths.map { IgnoreOptions.extensionSuffix(for: $0) ?? "" }
        if !deleting && Set(suffixes.map { $0.lowercased() }).count > 1 {
            Button { action(.ignore, paths) } label: { CommandLabel(title: "Ignore \(paths.count) items by name", icon: .ignore) }
            if let suffix = suffixes.first, !suffix.isEmpty {
                Button { action(.ignoreMask, paths) } label: { CommandLabel(title: "Ignore \(paths.count) items by extension", icon: .ignore) }
            }
        } else {
        Menu {
            Button { action(deleting ? .ignoreDelete : .ignore, paths) } label: { CommandLabel(title: paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "Ignore \(paths.count) items by name", icon: .ignore, localized: false) }
            let suffixes = paths.map { IgnoreOptions.extensionSuffix(for: $0) ?? "" }
            if Set(suffixes.map { $0.lowercased() }).count == 1, let suffix = suffixes.first, !suffix.isEmpty {
                Button { action(deleting ? .ignoreDeleteMask : .ignoreMask, paths) } label: { CommandLabel(title: paths.count == 1 ? "*" + suffix : "Ignore \(paths.count) items by extension", icon: .ignore, localized: false) }
            }
            if paths.count == 1 && !deleting {
                let folder = (paths[0] as NSString).deletingLastPathComponent
                if !folder.isEmpty { Button { action(.ignore, [folder]) } label: { CommandLabel(title: folder, icon: .ignore) } }
            }
        } label: { CommandLabel(title: deleting ? "Delete and add to ignore list" : "Add to ignore list", icon: .ignore) }
        }
    }
}
