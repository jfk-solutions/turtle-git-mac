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
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }
        model.onOpen = { [weak self] path, action in self?.openFile(path, action: action) }
        model.onIgnore = { [weak self] paths, mask in self?.ignore(paths, mask: mask) }
        model.onIndexFlags = { [weak self] action, paths, mark in self?.confirmFlags(action, paths: paths, mark: mark) }
        model.onRevertRequest = { [weak self] rows in self?.confirmRevert(rows) }
        model.onRestore = { [weak self] paths in self?.confirmRestore(paths) }
        model.onDelete = { [weak self] selected, permanently in self?.confirmDelete(selected, permanently: permanently) }
        model.onSave = { [weak self] path in self?.saveFile(path) }
        model.onExport = { [weak self] paths in self?.exportFiles(paths) }
        window.refresh = { [weak model] in model?.reload() }; window.accept = { [weak model] in model?.apply() }

        DialogGeometry.attach(window, identifier: "AddDialog", legacyName: "AddDialog")
    }
    private func saveFile(_ path: String) {
        guard let window, window.attachedSheet == nil, !model.busy, !model.confirmingQuit else { return }
        let panel = NSSavePanel(); panel.title = "Save As"; panel.canCreateDirectories = true
        let file = model.repository.root.appendingPathComponent(path)
        let name = file.lastPathComponent, ext = StatusListClipboard.fileExtension(path)
        panel.nameFieldStringValue = String(name.dropLast(ext.count)) + "-" + ext
        panel.directoryURL = file.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let target = panel.url else { return }
            _ = model?.startSave(path, to: target)
        }
    }
    private func exportFiles(_ paths: [String]) {
        guard let window, window.attachedSheet == nil, !model.busy, !model.confirmingQuit else { return }
        let panel = NSOpenPanel(); panel.title = "Export"; panel.prompt = "Export"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = model.repository.root
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let folder = panel.url else { return }
            _ = model?.startExport(paths, to: folder)
        }
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
    private func confirmFlags(_ action: IndexFlagAction, paths: [String], mark: String) {
        guard let window, window.attachedSheet == nil, model.beginFlagConfirmation(action, paths: paths, mark: mark) else { return }
        let alert = NSAlert(); alert.messageText = action.confirmation
        alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
        alert.beginSheetModal(for: window) { [weak model] response in _ = model?.finishFlagConfirmation(accepted: response == .alertSecondButtonReturn) }
    }
    private func confirmRevert(_ rows: [AddDialogEntry]) {
        guard let window, window.attachedSheet == nil, model.beginRevertConfirmation(rows) else { return }
        guard model.revertNeedsConfirmation else { model.finishRevertConfirmation(accepted: true); return }
        let alert = NSAlert(); alert.messageText = "Are you sure you want to revert \(rows.count) item(s)?"
        alert.informativeText = "You will lose ALL changes since the last update! Replaced working files are moved to Trash. Added files remain on disk as unversioned files."
        alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
        alert.beginSheetModal(for: window) { [weak model] response in model?.finishRevertConfirmation(accepted: response == .alertSecondButtonReturn) }
    }
    private func confirmRestore(_ paths: [String]) {
        guard let window, window.attachedSheet == nil, model.beginRestoreConfirmation(paths) else { return }
        let alert = NSAlert(); alert.messageText = "Do you really want to restore the copy?"
        alert.informativeText = "You will lose all changes that you have done after creating the copy."
        alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Restore")
        alert.beginSheetModal(for: window) { [weak model] response in _ = model?.finishRestoreConfirmation(accepted: response == .alertSecondButtonReturn) }
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
    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender.attachedSheet != nil { return false }; if model.busy { model.cancel(); return false }; return !model.confirmingQuit }
    func windowWillClose(_ notification: Notification) { model.restoreCopies.removeAll(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class AddWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var entries: [AddDialogEntry] = []
    @Published var checked = Set<String>()
    @Published var highlighted = Set<String>()
    @Published var selectionMark: String?
    @Published private(set) var hasHead = false
    @Published var includeIgnored = false
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var sortOrder = [KeyPathComparator(\AddDialogEntry.path)]
    private var paths: [String] = ["."]
    private var loaded = false
    private(set) var ignoring = false
    @Published var restoreCopies: [String: WorkingFileRestoreCopy] = [:]
    @Published private(set) var indexFlagFiles: [WorkingTreeFile] = []
    private var pendingFlags: (IndexFlagAction, [String], String)?
    var onIndexFlags: (IndexFlagAction, [String], String) -> Void = { _, _, _ in }
    func beginFlagConfirmation(_ action: IndexFlagAction, paths: [String], mark: String) -> Bool {
        guard !busy, !confirmingQuit, !paths.isEmpty, paths.contains(mark),
              paths.allSatisfy({ path in entries.contains { $0.path == path } }),
              let marked = indexFlagFiles.first(where: { $0.id == mark }), action.isAvailable(for: [marked]) else { return false }
        pendingFlags = (action, paths, mark); busy = true; return true
    }
    @discardableResult func finishFlagConfirmation(accepted: Bool) -> Task<Void, Never>? {
        guard let (action, paths, mark) = pendingFlags else { return nil }; pendingFlags = nil
        guard accepted else { busy = false; return nil }
        cancellation = OperationCancellation(); let operationCancellation = cancellation
        return Task {
            defer { busy = false; if operationCancellation.isCancelled || cancellation.isCancelled { close() }; cancellation = OperationCancellation() }
            do {
                try validateAccess()
                if operationCancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                // The shared locked index transaction finishes atomically once started.
                try await repository.setIndexFlags(action, paths: paths, markedPath: mark)
                onIgnoreChanged(action.rawValue + ": " + paths.joined(separator: ", "))
            } catch {
                if let failure = error as? IndexFlagPartialFailure, !failure.updatedPaths.isEmpty { onIgnoreChanged(failure.localizedDescription) }
                if !(error is OperationCancellationFailure) { self.error = error.localizedDescription }
            }
            cancellation = OperationCancellation()
            do { try await read() } catch { if !cancellation.isCancelled { self.error = [self.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") } }
        }
    }
    private var pendingRevert: [AddDialogEntry]?
    private(set) var reverting = false
    private var closeAfterRevert = false
    private var cancelRevert: (() -> Void)?
    var onRevertRequest: ([AddDialogEntry]) -> Void = { _ in }
    var onRevert: ([StatusEntry], @escaping (Bool) -> Void) -> (() -> Void) = { _, done in done(false); return {} }
    var revertNeedsConfirmation: Bool { pendingRevert?.contains { !$0.isDirectory && [$0.status.index, $0.status.worktree].contains { $0 == "M" || $0 == "T" } } == true }
    func beginRevertConfirmation(_ rows: [AddDialogEntry]) -> Bool {
        let marked = rows.first { $0.path == selectionMark } ?? rows.first
        guard !busy, !confirmingQuit, !rows.isEmpty, marked?.status.canCompareWithBaseFromStatusList == true else { return false }
        pendingRevert = rows; busy = true; return true
    }
    func finishRevertConfirmation(accepted: Bool) {
        guard let selected = pendingRevert else { return }; pendingRevert = nil
        guard accepted else { busy = false; return }
        reverting = true; closeAfterRevert = false
        let cancel = onRevert(selected.map(\.status)) { [weak self] succeeded in self?.finishRevert(selected, succeeded: succeeded) }
        if reverting { cancelRevert = cancel }
    }
    private func finishRevert(_ selected: [AddDialogEntry], succeeded: Bool) {
        guard reverting else { return }; reverting = false; cancelRevert = nil; cancellation = OperationCancellation()
        Task {
            defer { busy = false; if closeAfterRevert || cancellation.isCancelled { close() }; closeAfterRevert = false; cancellation = OperationCancellation() }
            if succeeded { checked.subtract(selected.map(\.path)); highlighted.subtract(selected.map(\.path)) }
            do {
                try await read()
                if succeeded {
                    let clean = Set(selected.filter { !$0.isDirectory && $0.state != .added }.map(\.path))
                    entries.removeAll { clean.contains($0.path) && $0.state == .normal }
                }
            } catch { if !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private var pendingRestore: [String]?
    var onRestore: ([String]) -> Void = { _ in }
    var onRestoreChanged: () -> Void = {}
    private var pendingDelete: (selected: [StatusEntry], permanently: Bool)?
    private(set) var lastDeleteResult: WorkingFileDeleteResult?
    private var cancellation = OperationCancellation()
    var close: () -> Void = {}
    var onAccepted: ([String]) -> Void = { _ in }
    var onPreview: (String) -> Void = { _ in }
    var onCompare: ([String]) -> Void = { _ in }
    var onCompareTwo: ([String]) -> Void = { _ in }
    var unifiedViewerBusy: () -> Bool = { false }
    var onUnifiedPatch: (Data, Bool) async throws -> Void = { _, _ in }
    var onLog: (String) -> Void = { _ in }
    var onBlame: (String) -> Void = { _ in }
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
    var onSave: (String) -> Void = { _ in }
    var onExport: ([String]) -> Void = { _ in }
    @Published var information = ""
    func saveFile(_ path: String, to target: URL) async { await startSave(path, to: target)?.value }
    func exportFiles(_ paths: [String], to folder: URL) async { await startExport(paths, to: folder)?.value }
    @discardableResult func startSave(_ path: String, to target: URL) -> Task<Void, Never>? { startCopy([path], to: target, save: true) }
    @discardableResult func startExport(_ paths: [String], to folder: URL) -> Task<Void, Never>? { startCopy(paths, to: folder, save: false) }
    private func startCopy(_ paths: [String], to target: URL, save: Bool) -> Task<Void, Never>? {
        guard !busy, !confirmingQuit, !paths.isEmpty else { return nil }; busy = true; cancellation = OperationCancellation()
        return Task {
            let scoped = target.startAccessingSecurityScopedResource()
            defer { if scoped { target.stopAccessingSecurityScopedResource() }; busy = false; cancellation = OperationCancellation() }
            do {
                try validateAccess()
                if GitRuntime.isAppStoreBuild && !scoped { throw RepositoryAccessFailure.securityScopeUnavailable }
                if save {
                    try await repository.saveWorkingFile(path: paths[0], to: target, cancellation: cancellation); information = "Saved " + target.path
                } else {
                    let count = try await repository.exportWorkingFiles(paths: paths, to: target, cancellation: cancellation); information = "\(count) file(s) exported."
                }
            } catch { self.error = error.localizedDescription }
        }
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
    @discardableResult func startMarkForRestore(_ paths: [String]) -> Task<Void, Never>? {
        let files = paths.filter { path in entries.contains { $0.path == path && !$0.isDirectory } && restoreCopies[path] == nil }
        guard !busy, !confirmingQuit, !files.isEmpty else { return nil }
        busy = true; cancellation = OperationCancellation()
        return Task {
            defer { busy = false; if cancellation.isCancelled { close() }; cancellation = OperationCancellation() }
            do {
                try validateAccess()
                var failures: [String] = []
                for path in files {
                    if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                    do { restoreCopies[path] = try await repository.captureWorkingFileRestoreCopy(path: path, allowUnversioned: true) }
                    catch { failures.append(path + ": " + error.localizedDescription) }
                }
                if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
            } catch { if !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func beginRestoreConfirmation(_ paths: [String]) -> Bool {
        guard !busy, !confirmingQuit, paths.contains(where: { restoreCopies[$0] != nil }) else { return false }
        pendingRestore = paths; busy = true; return true
    }
    @discardableResult func finishRestoreConfirmation(accepted: Bool) -> Task<Void, Never>? {
        guard let paths = pendingRestore else { return nil }; pendingRestore = nil
        guard accepted else { busy = false; return nil }
        cancellation = OperationCancellation()
        return Task {
            var changed = false
            defer { busy = false; if cancellation.isCancelled { close() }; cancellation = OperationCancellation() }
            do {
                try validateAccess()
                var failures: [String] = []
                for path in paths {
                    if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                    guard let copy = restoreCopies[path] else { continue }
                    do { try await repository.restoreWorkingFile(copy); restoreCopies.removeValue(forKey: path); changed = true }
                    catch { failures.append(path + ": " + error.localizedDescription) }
                }
                if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
            } catch { if !cancellation.isCancelled { self.error = error.localizedDescription } }
            if changed {
                onRestoreChanged()
                do { try await read() } catch { if !cancellation.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }
    @discardableResult func startUnifiedDiff(paths: [String], alternate: Bool = false) -> Task<Void, Never>? {
        let marked = entries.first { $0.path == selectionMark && paths.contains($0.path) } ?? entries.first { $0.path == paths.first }
        guard !busy, !confirmingQuit, !unifiedViewerBusy(), hasHead, !paths.isEmpty,
              Set(paths).count == paths.count, paths.allSatisfy({ path in entries.contains { $0.path == path } }),
              marked?.status.canCompareWithBaseFromStatusList == true else { return nil }
        busy = true; cancellation = OperationCancellation()
        return Task {
            defer {
                busy = false
                if cancellation.isCancelled { close() }
                cancellation = OperationCancellation()
            }
            do {
                try validateAccess(); if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                var bytes = Data()
                for path in paths {
                    bytes.append(try await repository.run(["diff", "--no-ext-diff", "--no-color", "--stat", "-p", "--end-of-options", "HEAD", "--", path], cancellation: cancellation).stdout)
                }
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                if unifiedViewerBusy() { throw NSError(domain: "TurtleGit.Add", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish the open unified diff operation before showing another comparison."]) }
                try await onUnifiedPatch(bytes, alternate)
            } catch { if !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    var canApply: Bool { !busy && !confirmingQuit && !checked.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    func setScope(_ paths: [String]) { self.paths = paths.isEmpty ? ["."] : paths; loaded = false; checked = []; highlighted = []; selectionMark = nil; hasHead = false }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func read() async throws {
        try validateAccess()
        let selection = try await repository.addDialogSelection(paths: paths, includeIgnored: includeIgnored, cancellation: cancellation)
        let head = try? await repository.run(["rev-parse", "--verify", "HEAD^{commit}"], cancellation: cancellation)
        if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }; hasHead = head != nil
        let flags = try await repository.workingTreeStatus(refreshIndex: false)
        if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
        indexFlagFiles = flags
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
    func cancel() {
        guard !confirmingQuit, !ignoring, pendingDelete == nil, pendingRestore == nil, pendingRevert == nil, pendingFlags == nil else { return }
        if reverting { closeAfterRevert = true; cancelRevert?() }
        else if busy { cancellation.cancel() }
        else { close() }
    }
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
                SelectionAllCheckbox(checked: model.checked.count, total: model.entries.count, checkedCount: { model.checked.count }) { model.checked = $0 ? Set(model.entries.map(\.path)) : [] }.frame(width: 180, height: 22)
                Toggle("Include ignored files", isOn: $model.includeIgnored).toggleStyle(.checkbox).onChange(of: model.includeIgnored) { _ in model.reload() }
                Spacer()
            }.disabled(model.busy)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                if !model.busy && !model.information.isEmpty { Text(model.information).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
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
