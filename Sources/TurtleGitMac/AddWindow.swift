import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

private final class AddNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    var accept: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.specialKey == .f5 { refresh(); return true }
        if event.charactersIgnoringModifiers == "\r", !event.modifierFlags.intersection([.command, .control]).isEmpty { accept(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class AddWindowController: NSWindowController, NSWindowDelegate {
    let model: AddWindowModel
    private let access: RepositoryAccessLease?
    private var ignoreController: IgnoreWindowController?
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = AddWindowModel(repository: repository, access: access); self.access = access
        let window = AddNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Add – TurtleGit"
        window.contentMinSize = NSSize(width: 580, height: 320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AddDialogView(model: model))
        super.init(window: window); window.delegate = self; window.setFrameAutosaveName("AddDialog"); window.center()
        model.close = { [weak window] in window?.close() }
        model.onOpen = { [weak self] path, action in self?.openFile(path, action: action) }
        model.onIgnore = { [weak self] paths, mask in self?.ignore(paths, mask: mask) }
        model.onDelete = { [weak self] selected, permanently in self?.confirmDelete(selected, permanently: permanently) }
        window.refresh = { [weak model] in model?.reload() }; window.accept = { [weak model] in model?.apply() }
    }
    private func confirmDelete(_ selected: [StatusEntry], permanently: Bool) {
        guard let window, window.attachedSheet == nil, model.beginDeleteConfirmation(selected, permanently: permanently) else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = permanently ? "Permanently delete the selected paths?" : "Move the selected paths to Trash?"
        alert.informativeText = "\(selected.count) selected item(s). Any exact index entries will also be removed." + (permanently ? " This cannot be undone." : " Files moved to Trash can be recovered in Finder.")
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: permanently ? "Delete Permanently" : "Move to Trash")
        alert.beginSheetModal(for: window) { [weak model] response in _ = model?.finishDeleteConfirmation(accepted: response == .alertSecondButtonReturn) }
    }
    private func ignore(_ paths: [String], mask: Bool) {
        guard let window, window.attachedSheet == nil, ignoreController == nil, !model.busy, !model.confirmingQuit else { return }
        do {
            let controller = try IgnoreWindowController(repository: model.repository, access: access, paths: paths, mask: mask, delete: false)
            guard let child = controller.window, model.beginIgnore() else { return }
            var changed = false
            controller.onChanged = { [weak model] output in changed = true; model?.onIgnoreChanged(output) }
            controller.onClosed = { [weak self, weak child] in
                guard let self else { return }
                if let child, let parent = child.sheetParent { parent.endSheet(child) }
                self.ignoreController = nil; self.model.finishIgnore(changed: changed)
            }
            ignoreController = controller; window.beginSheet(child)
        } catch { model.error = error.localizedDescription }
    }
    private func openFile(_ path: String, action: AddFileOpenAction) {
        guard let window, !model.busy, !model.confirmingQuit, window.attachedSheet == nil else { return }
        let file = model.repository.root.appendingPathComponent(path)
        if action == .openWith {
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.beginSheetModal(for: window) { [weak model] response in
                guard response == .OK, let application = panel.url, let model, !model.busy, !model.confirmingQuit else { return }
                let scoped = application.startAccessingSecurityScopedResource()
                NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if scoped { application.stopAccessingSecurityScopedResource() }
                    DispatchQueue.main.async { if let error { model.error = error.localizedDescription } }
                }
            }
        } else if action == .editor {
            AlternativeEditor.open(file) { [weak model] failure in if let failure { model?.error = failure } }
        } else if !NSWorkspace.shared.open(file) { model.error = "Could not open the file. Choose an application using Open With." }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.confirmingQuit }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class AddWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var entries: [AddDialogEntry] = []
    @Published var checked = Set<String>()
    @Published var highlighted = Set<String>()
    @Published var includeIgnored = false
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var sortOrder = [KeyPathComparator(\AddDialogEntry.path)]
    private var paths: [String] = ["."]
    private var loaded = false
    private(set) var ignoring = false
    private var pendingDelete: (selected: [StatusEntry], permanently: Bool)?
    private(set) var lastDeleteResult: WorkingFileDeleteResult?
    private var cancellation = OperationCancellation()
    var close: () -> Void = {}
    var onAccepted: ([String]) -> Void = { _ in }
    var onPreview: (String) -> Void = { _ in }
    var onOpen: (String, AddFileOpenAction) -> Void = { _, _ in }
    var onIgnore: ([String], Bool) -> Void = { _, _ in }
    var onIgnoreChanged: (String) -> Void = { _ in }
    func beginIgnore() -> Bool {
        guard !busy, !confirmingQuit else { return false }
        ignoring = true; busy = true; return true
    }
    func finishIgnore(changed: Bool) {
        guard ignoring else { return }
        ignoring = false; busy = false
        if changed { reload() }
    }
    var onDelete: ([StatusEntry], Bool) -> Void = { _, _ in }
    var onDeleteChanged: (String) -> Void = { _ in }
    func beginDeleteConfirmation(_ selected: [StatusEntry], permanently: Bool) -> Bool {
        guard !busy, !confirmingQuit, !selected.isEmpty, selected.contains(where: \.canDeleteFromStatusList) else { return false }
        pendingDelete = (selected, permanently); lastDeleteResult = nil; busy = true; return true
    }
    @discardableResult func finishDeleteConfirmation(accepted: Bool) -> Task<Void, Never>? {
        guard let pendingDelete else { return nil }; self.pendingDelete = nil
        guard accepted else { busy = false; return nil }
        cancellation = OperationCancellation()
        return Task {
            do {
                try validateAccess()
                let result = try await repository.deleteWorkingFiles(pendingDelete.selected, permanently: pendingDelete.permanently, cancellation: cancellation)
                lastDeleteResult = result
                checked.subtract(pendingDelete.selected.map(\.path)); highlighted.subtract(pendingDelete.selected.map(\.path))
                onDeleteChanged("\(pendingDelete.selected.count) item(s) deleted." + (result.trashedFiles.isEmpty ? "" : "\n" + result.trashedFiles.map { "Moved to Trash: " + $0.path }.joined(separator: "\n")))
            } catch {
                self.error = error.localizedDescription
                if let failure = error as? WorkingFileDeleteFailure, !failure.removedPaths.isEmpty { onDeleteChanged(failure.localizedDescription) }
            }
            cancellation = OperationCancellation()
            do { try await read() } catch { self.error = [self.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
            busy = false
        }
    }
    var canApply: Bool { !busy && !confirmingQuit && !checked.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    func setScope(_ paths: [String]) { self.paths = paths.isEmpty ? ["."] : paths; loaded = false; checked = []; highlighted = [] }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func read() async throws {
        try validateAccess()
        let selection = try await repository.addDialogSelection(paths: paths, includeIgnored: includeIgnored, cancellation: cancellation)
        let previous = Set(entries.map(\.path))
        entries = selection.entries
        if loaded { checked.formIntersection(Set(entries.map(\.path))); checked.formUnion(selection.initiallyChecked.subtracting(previous)) }
        else { checked = selection.initiallyChecked; loaded = true }
        highlighted.formIntersection(Set(entries.map(\.path)))
    }
    func reload() {
        guard !busy, !confirmingQuit else { return }; busy = true; cancellation = OperationCancellation()
        Task {
            do { try await read() }
            catch { if !cancellation.isCancelled { self.error = error.localizedDescription } }
            busy = false
            if cancellation.isCancelled { close() }
        }
    }
    func cancel() { guard !confirmingQuit, !ignoring, pendingDelete == nil else { return }; if busy { cancellation.cancel() } else { close() } }
    func apply() { guard canApply else { return }; onAccepted(entries.filter { checked.contains($0.path) }.map(\.path)); close() }
    func addDropped(_ urls: [URL]) -> Bool {
        guard !busy, !confirmingQuit, !urls.isEmpty else { return false }
        let request = FinderRequest(action: .add, paths: urls)
        guard request.paths.allSatisfy({ $0.path == repository.root.path || $0.path.hasPrefix(repository.root.path + "/") }) else { return false }
        busy = true
        Task {
            do {
                try validateAccess()
                for item in request.paths {
                    let type = try FileManager.default.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType
                    let location = type == .typeDirectory ? item : item.deletingLastPathComponent()
                    let owner = try await GitRepository(root: location, executable: repository.executable).discoverRoot()
                    guard owner.path == repository.root.path else { throw AddFailure.outsideRepository }
                }
                let additions = request.relativePaths(root: repository.root)
                paths = Array(Set(paths + additions)).sorted()
                try await read(); checked.formUnion(entries.filter { row in additions.contains { row.path == $0 || row.path.hasPrefix($0 + "/") } }.map(\.path))
            } catch { self.error = error.localizedDescription }
            busy = false
        }
        return true
    }
}
enum AddFileOpenAction { case open, openWith, editor }

struct AddDialogView: View {
    @ObservedObject var model: AddWindowModel
    var body: some View {
        VStack(spacing: 10) {
            AddFileTable(model: model).frame(minHeight: 220)
            HStack {
                SelectionAllCheckbox(checked: model.checked.count, total: model.entries.count) { model.checked = $0 ? Set(model.entries.map(\.path)) : [] }.frame(width: 180, height: 22)
                Toggle("Include ignored files", isOn: $model.includeIgnored).toggleStyle(.checkbox).onChange(of: model.includeIgnored) { _ in model.reload() }
                Spacer()
            }.disabled(model.busy)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                if !model.busy && model.entries.isEmpty { Text("There is nothing to add.").foregroundStyle(.secondary) }
                Spacer()
                Button("OK") { model.apply() }.keyboardShortcut(.defaultAction).disabled(!model.canApply)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-add.html")!) }
            }
        }.padding(12).disabled(model.confirmingQuit)
        .dropDestination(for: URL.self) { urls, _ in model.addDropped(urls) }
        .alert("Add failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
