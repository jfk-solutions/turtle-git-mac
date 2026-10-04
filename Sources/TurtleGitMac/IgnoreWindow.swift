import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class IgnoreWindowController: NSWindowController, NSWindowDelegate {
    let model: IgnoreWindowModel
    var onClosed: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    private let delete: Bool
    private var removed = 0
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], mask: Bool, delete: Bool) throws {
        model = IgnoreWindowModel(repository: repository, access: access, options: try IgnoreOptions(paths: paths, mask: mask))
        self.delete = delete
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Ignore – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 550, height: 300)
        window.contentViewController = NSHostingController(rootView: IgnoreDialog(model: model))
        super.init(window: window); window.delegate = self; window.setFrameAutosaveName("IgnoreDialog")
        window.setContentSize(NSSize(width: 550, height: 300)); window.center()
        model.close = { [weak window] in window?.close() }
        model.onRulesWritten = { [weak self] files in
            guard let self else { return }
            self.onChanged(files.isEmpty ? "Ignore rules already present." : "Updated ignore rules in " + files.map(\.path).joined(separator: ", "))
            if self.delete { self.askKeepLocal() } else { self.close() }
        }
    }
    private func askKeepLocal() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Keep file locally?"; alert.alertStyle = .warning
        alert.informativeText = "Yes removes the selected paths from version control and keeps their local contents. No also removes their working copies, including local modifications."
        alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        alert.beginSheetModal(for: window) { [weak self] response in self?.removeNext(0, keepLocal: response == .alertFirstButtonReturn) }
    }
    private func removeNext(_ index: Int, keepLocal: Bool) {
        guard index < model.options.paths.count else { finishRemoval(); return }
        let path = model.options.paths[index]
        Task {
            do {
                _ = try await model.repository.removeVersionedPath(path, keepLocal: keepLocal)
                removed += 1; removeNext(index + 1, keepLocal: keepLocal)
            } catch {
                guard let window else { return }
                let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "Could not remove “\(path)”"
                alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
                alert.informativeText = error.localizedDescription + "\nOK continues with the next path. The ignore rules have already been written."
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.removeNext(index + 1, keepLocal: keepLocal) }
                    else { self?.finishRemoval() }
                }
            }
        }
    }
    private func finishRemoval() {
        let summary = "\(removed) files removed."; onChanged(summary)
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = summary; alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class IgnoreWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var options: IgnoreOptions
    @Published var busy = false
    @Published var error: String?
    var close: () -> Void = {}
    var onRulesWritten: ([URL]) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, options: IgnoreOptions) {
        self.repository = repository; self.access = access; self.options = options
    }
    func apply() {
        guard !busy else { return }; busy = true
        let selected = options
        Task {
            do {
                let destinations = try await repository.ignoreDestinations(selected)
                if GitRuntime.isAppStoreBuild {
                    guard access?.hasSecurityScope == true, access?.contains(repository.root) == true,
                          destinations.allSatisfy({ access?.contains($0) == true }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
                onRulesWritten(try await repository.addIgnoreRules(selected))
            } catch { busy = false; self.error = error.localizedDescription }
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
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-ignore.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
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
        Menu {
            Button { action(deleting ? .ignoreDelete : .ignore, paths) } label: { CommandLabel(title: paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "Ignore \(paths.count) items by name", icon: .ignore) }
            let suffixes = paths.map { ($0 as NSString).pathExtension }
            if Set(suffixes.map { $0.lowercased() }).count == 1, let suffix = suffixes.first, !suffix.isEmpty {
                Button { action(deleting ? .ignoreDeleteMask : .ignoreMask, paths) } label: { CommandLabel(title: paths.count == 1 ? "*." + suffix : "Ignore \(paths.count) items by extension", icon: .ignore) }
            }
            if paths.count == 1 && !deleting {
                let folder = (paths[0] as NSString).deletingLastPathComponent
                if !folder.isEmpty { Button { action(.ignore, [folder]) } label: { CommandLabel(title: folder, icon: .ignore) } }
            }
        } label: { CommandLabel(title: deleting ? "Delete and add to ignore list" : "Add to ignore list", icon: .ignore) }
    }
}
