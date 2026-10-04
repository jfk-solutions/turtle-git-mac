import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

private final class RevertNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    var accept: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.specialKey == .f5 { refresh(); return true }
        if event.charactersIgnoringModifiers == "\r", event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { accept(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class RevertWindowController: NSWindowController, NSWindowDelegate {
    let model: RevertWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = RevertWindowModel(repository: repository, access: access)
        let window = RevertNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Revert – TurtleGit"
        window.contentMinSize = NSSize(width: 900, height: 360); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RevertDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 520))
        window.setFrameAutosaveName("RevertDialog"); window.center()
        model.close = { [weak window] in window?.close() }
        window.refresh = { [weak model] in model?.reload() }
        window.accept = { [weak model] in model?.apply() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.confirmingQuit }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class RevertWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var entries: [StatusEntry] = []
    @Published var statistics: [String: CommitFile] = [:]
    @Published var checked = Set<String>()
    @Published var highlighted = Set<String>()
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var patch: String?
    @Published var hasUnversionedItems = false
    private var paths: [String] = []
    private var hasLoaded = false
    var close: () -> Void = {}
    var onAccepted: ([StatusEntry]) -> Void = { _ in }
    var onFileLog: (String) -> Void = { _ in }
    var canApply: Bool { !busy && !confirmingQuit && patch == nil && !checked.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    func setScope(_ paths: [String]) {
        guard !busy, !confirmingQuit else { return }
        self.paths = paths.isEmpty ? ["."] : paths; hasLoaded = false; checked = []; highlighted = []; reload()
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func reload(forceChecked: Set<String> = []) {
        guard !busy, !confirmingQuit else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                try validateAccess()
                let direct = Set(paths.filter { path in
                    path != "." && (try? FileManager.default.attributesOfItem(atPath: repository.root.appendingPathComponent(path).path)[.type]) as? FileAttributeType != .typeDirectory
                })
                let list = RevertDialogSelection(status: try await repository.status(), paths: paths, directFiles: direct)
                let oldPaths = Set(entries.map(\.path))
                entries = list.entries; hasUnversionedItems = list.hasUnversionedItems
                if !hasLoaded { checked = list.initiallyChecked; hasLoaded = true }
                else { checked.formIntersection(Set(entries.map(\.path))); checked.formUnion(list.initiallyChecked.subtracting(oldPaths)); checked.formUnion(forceChecked.intersection(Set(entries.map(\.path)))) }
                highlighted.formIntersection(Set(entries.map(\.path)))
                statistics = Dictionary(try await repository.workingTreeFiles().map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
            } catch { self.error = error.localizedDescription }
        }
    }
    func apply() {
        guard canApply else { return }
        let selected = entries.filter { checked.contains($0.path) }
        onAccepted(selected); close()
    }

    func diff(_ ids: Set<String>) {
        guard !busy, !confirmingQuit, !ids.isEmpty else { return }; busy = true
        Task { defer { busy = false }; do { patch = try await repository.workingTreeDiff(paths: ids.sorted()) } catch { self.error = error.localizedDescription } }
    }
    func addDropped(_ urls: [URL]) -> Bool {
        guard !busy, !confirmingQuit, !urls.isEmpty else { return false }
        let request = FinderRequest(action: .revert, paths: urls)
        guard request.paths.allSatisfy({ $0.path == repository.root.path || ($0.path.hasPrefix(repository.root.path + "/") && RepositoryAccessLease(url: repository.root).contains($0.deletingLastPathComponent())) }) else { return false }
        busy = true
        Task {
            do {
                try validateAccess()
                for url in request.paths {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let location = attributes?[.type] as? FileAttributeType == .typeDirectory ? url : url.deletingLastPathComponent()
                    let owner = try await GitRepository(root: location, executable: repository.executable).discoverSelectionRoot(for: .revert, selected: url)
                    guard owner == repository.root else { throw RevertDropFailure.outsideRepository }
                }
                let added = request.relativePaths(root: repository.root)
                paths = Array(Set(paths + added)).sorted()
                busy = false; reload(forceChecked: Set(added))
            } catch { self.error = error.localizedDescription; busy = false }
        }
        return true
    }
}

private struct RevertDialog: View {
    @ObservedObject var model: RevertWindowModel
    private func lineCount(_ path: String, added: Bool) -> String {
        let count = added ? model.statistics[path]?.added : model.statistics[path]?.removed
        return count.map { String($0) } ?? "–"
    }
    var body: some View {
        VStack(spacing: 10) {
            Table(model.entries, selection: $model.highlighted) {
                TableColumn("") { row in Toggle("Revert \(row.path)", isOn: Binding(get: { model.checked.contains(row.path) }, set: { if $0 { model.checked.insert(row.path) } else { model.checked.remove(row.path) } })).labelsHidden().toggleStyle(.checkbox) }.width(24)
                TableColumn("Path") { row in HStack { Image(nsImage: row.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(row.path).foregroundStyle(model.highlighted.contains(row.path) ? Color.primary : row.state.textColor) }.help(row.originalPath.map { "Renamed from \($0)" } ?? row.path) }.width(min: 250, ideal: 390)
                TableColumn("Extension") { (row: StatusEntry) in Text((row.path as NSString).pathExtension) }.width(70)
                TableColumn("Status") { row in Text(row.originalPath != nil ? "Renamed" : row.state.rawValue.capitalized) }.width(95)
                TableColumn("Lines added") { (row: StatusEntry) in Text(lineCount(row.path, added: true)) }.width(80)
                TableColumn("Lines removed") { (row: StatusEntry) in Text(lineCount(row.path, added: false)) }.width(95)
            }.contextMenu(forSelectionType: String.self) { ids in
                Button { model.diff(ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty)
                Button { model.checked.formUnion(ids) } label: { CommandLabel(title: "Check selected files", icon: .add) }.disabled(ids.isEmpty)
                Button { model.checked.subtract(ids) } label: { CommandLabel(title: "Uncheck selected files", icon: .revert) }.disabled(ids.isEmpty)
                if ids.count == 1, let path = ids.first { Button { model.onFileLog(path) } label: { CommandLabel(title: "Show log", icon: .log) } }
            } primaryAction: { model.diff($0) }
            HStack {
                RevertAllCheckbox(checked: model.checked.count, total: model.entries.count) { model.checked = $0 ? Set(model.entries.map(\.path)) : [] }.frame(width: 190, height: 22)
                Spacer()
                if model.hasUnversionedItems && UserDefaults.standard.bool(forKey: "Status.UnversionedAsModified") { Text("Note: the folder contains unversioned items").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                if model.entries.isEmpty && !model.busy { Text("No files or folders were modified.").foregroundStyle(.secondary) }
                Spacer()
                Button("OK") { model.apply() }.keyboardShortcut(.defaultAction).disabled(!model.canApply)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-revert.html")!) }
            }
        }.padding(12).disabled(model.busy || model.confirmingQuit)
        .dropDestination(for: URL.self) { urls, _ in model.addDropped(urls) }
        .alert("Revert failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) { VStack { Text("Revert – working changes").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12) }
    }
}
private struct RevertAllCheckbox: NSViewRepresentable {
    let checked: Int
    let total: Int
    let change: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Select/deselect all", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = checked == 0 ? .off : checked == total ? .on : .mixed; button.isEnabled = enabled && total > 0
        context.coordinator.change = change; context.coordinator.selectOnClick = checked == 0
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void
        var selectOnClick = true
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) { change(selectOnClick) }
    }
}

private enum RevertDropFailure: LocalizedError {
    case outsideRepository
    var errorDescription: String? { "Only paths from this repository can be dropped here." }
}
