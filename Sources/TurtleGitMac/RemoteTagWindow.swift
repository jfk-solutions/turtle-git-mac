import AppKit
import SwiftUI
import TurtleGitCore

private final class RemoteTagNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if event.keyCode == 96 { refresh(); return true }; return super.performKeyEquivalent(with: event) }
}
@MainActor private final class RemoteTagProgressController: NSWindowController, NSWindowDelegate {
    var forcedClose: () -> Void = {}
    init(_ phase: RemoteTagWindowModel.Phase) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "TurtleGit"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: HStack(spacing: 16) { ProgressView().controlSize(.small); VStack(alignment: .leading, spacing: 8) { Text(phase.rawValue); Text("Please wait…").foregroundStyle(.secondary) }; Spacer() }.padding(20))
        super.init(window: window); window.delegate = self
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    func windowWillClose(_ notification: Notification) { forcedClose() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RemoteTagWindowController: NSWindowController, NSWindowDelegate {
    let model: RemoteTagWindowModel
    var onClosed: () -> Void = {}
    private var progress: RemoteTagProgressController?
    var progressWindow: NSWindow? { progress?.window }
    var presentProgress: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    init(repository: GitRepository, access: RepositoryAccessLease?, remote: String, preferences: UserDefaults = .standard) {
        model = RemoteTagWindowModel(repository: repository, access: access, remote: remote, preferences: preferences)
        let window = RemoteTagNativeWindow(contentRect: .init(x: 0, y: 0, width: 510, height: 290), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Delete remote tag – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 480, height: 250)
        window.contentViewController = NSHostingController(rootView: RemoteTagDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.phaseChanged = { [weak self] in self?.showProgress($0) }; window.refresh = { [weak model] in model?.load() }
        model.close = { [weak self] in guard let self, !self.model.busy, self.window?.attachedSheet == nil else { return }; self.close() }
        model.confirm = { [weak window] tags in
            guard let window, window.attachedSheet == nil else { return false }
            return await withCheckedContinuation { continuation in
                let alert = NSAlert(); alert.messageText = "TurtleGit"; alert.informativeText = RemoteTagConfirmation.message(tags); alert.alertStyle = .warning
                let deletion = alert.addButton(withTitle: "Delete"); deletion.keyEquivalent = ""; let abort = alert.addButton(withTitle: "Abort"); abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        DialogGeometry.attach(window, identifier: "DeleteRemoteTagDlg", legacyName: "DeleteRemoteTagDlg")
    }
    private func showProgress(_ phase: RemoteTagWindowModel.Phase?) {
        if let old = progress { progress = nil; if let child = old.window, child.sheetParent === window { window?.endSheet(child) }; old.close() }
        guard let phase, !model.closed, let owner = window else { return }
        owner.makeFirstResponder(nil)
        let child = RemoteTagProgressController(phase); progress = child
        child.forcedClose = { [weak self, weak child] in guard let self, let child, self.progress === child else { return }; self.model.invalidate(); self.close() }
        guard let window = child.window, presentProgress(owner, window) else { progress = nil; child.close(); model.invalidate(); close(); return }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); showProgress(nil); if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort); sheet.close() }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RemoteTagWindowModel: ObservableObject {
    enum Phase: String { case loading = "Loading…", deleting = "Deleting remote refs…" }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let remote: String
    private let preferences: UserDefaults
    private var token: OperationCancellation?
    private(set) var closed = false
    @Published private(set) var tags: [RemoteTag] = []
    @Published private(set) var selection = Set<GitReferenceName>()
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var phase: Phase? { didSet { phaseChanged(phase) } }
    var phaseChanged: (Phase?) -> Void = { _ in }
    var confirm: (([GitReferenceName]) async -> Bool)?
    var close: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, remote: String, preferences: UserDefaults) { self.repository = repository; self.access = access; self.remote = remote; self.preferences = preferences }
    var canDelete: Bool { !closed && !busy && !selection.isEmpty && confirm != nil }
    var selectedTags: [GitReferenceName] { tags.filter { selection.contains($0.name) }.map(\.name) }
    var selectAllState: NSControl.StateValue { selection.isEmpty ? .off : selection.count == tags.count ? .on : .mixed }
    func select(_ names: Set<GitReferenceName>) { guard !closed, !busy else { return }; selection = names.intersection(Set(tags.map(\.name))) }
    func selectAll(_ state: NSControl.StateValue) { select(state == .on ? Set(tags.map(\.name)) : []) }
    private func checkAccess() throws { if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable } }
    func invalidate() { closed = true; token?.cancel(); token = nil; busy = false; phase = nil }
    func load(preservingError: String? = nil) {
        guard !closed, !busy else { return }
        let request = OperationCancellation(); token = request; busy = true; selection = []; tags = []; error = preservingError; phase = .loading
        Task {
            defer { if token === request { token = nil; busy = false; phase = nil } }
            do { try checkAccess(); let rows = try await repository.remoteTags(remote: remote, reversed: preferences.bool(forKey: "SortTagsReversed"), cancellation: request); guard !closed, token === request, !request.isCancelled else { return }; tags = rows }
            catch { if !closed, token === request, !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func delete() {
        guard canDelete, let confirm else { return }
        let captured = selectedTags, request = OperationCancellation(); token = request; busy = true; error = nil
        Task {
            let accepted = await confirm(captured)
            guard !closed, token === request, !request.isCancelled else { return }
            guard accepted else { token = nil; busy = false; return }
            phase = .deleting; var failure: String?
            do { try checkAccess(); try await repository.deleteRemoteTags(remote: remote, tags: captured, cancellation: request) }
            catch { if !closed, token === request, !request.isCancelled { failure = error.localizedDescription } }
            guard !closed, token === request, !request.isCancelled else { return }
            token = nil; busy = false; phase = nil; load(preservingError: failure)
        }
    }
}
private struct RemoteTagDialog: View {
    @ObservedObject var model: RemoteTagWindowModel
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Remote:").frame(width: 95, alignment: .leading); RemoteTagRemoteField(remote: model.remote) }
            HStack(alignment: .top) { Text("Tags:").frame(width: 95, alignment: .leading); RemoteTagTable(model: model).frame(maxWidth: .infinity, maxHeight: .infinity).border(Color(nsColor: .separatorColor)) }
            HStack { RemoteTagAllCheckbox(model: model); Spacer(); Button("Delete") { model.delete() }.keyboardShortcut(.defaultAction).disabled(!model.canDelete); Button("Close") { model.close() }.keyboardShortcut(.cancelAction).disabled(model.busy) }
        }.padding(12).disabled(model.busy).onAppear { model.load() }
        .alert("Delete remote tag failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
private struct RemoteTagAllCheckbox: NSViewRepresentable {
    @ObservedObject var model: RemoteTagWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSButton { let button = NSButton(checkboxWithTitle: "Select/deselect all", target: context.coordinator, action: #selector(Coordinator.changed(_:))); button.allowsMixedState = true; return button }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.model = model; button.state = model.selectAllState; button.isEnabled = !model.busy && !model.closed }
    @MainActor final class Coordinator: NSObject { var model: RemoteTagWindowModel; init(_ model: RemoteTagWindowModel) { self.model = model }; @objc func changed(_ sender: NSButton) { model.selectAll(sender.state == .mixed ? .off : sender.state) } }
}
private struct RemoteTagTable: NSViewRepresentable {
    @ObservedObject var model: RemoteTagWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView { let table = NSTableView(); table.setAccessibilityLabel("Remote tags"); table.headerView = nil; table.allowsMultipleSelection = true; table.rowHeight = 22; let column = NSTableColumn(identifier: .init("tag")); table.addTableColumn(column); table.delegate = context.coordinator; table.dataSource = context.coordinator; context.coordinator.table = table; let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table; return scroll }
    func updateNSView(_ scroll: NSScrollView, context: Context) { let coordinator = context.coordinator; coordinator.model = model; coordinator.updating = true; defer { coordinator.updating = false }; guard let table = coordinator.table else { return }; table.reloadData(); table.selectRowIndexes(IndexSet(model.tags.indices.filter { model.selection.contains(model.tags[$0].name) }), byExtendingSelection: false); table.isEnabled = !model.busy; table.tableColumns.first?.width = max(200, scroll.contentSize.width) }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate { var model: RemoteTagWindowModel; weak var table: NSTableView?; var updating = false; init(_ model: RemoteTagWindowModel) { self.model = model }; func numberOfRows(in tableView: NSTableView) -> Int { model.tags.count }; func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSTextField(labelWithString: model.tags[row].name.rawValue) }; func tableViewSelectionDidChange(_ notification: Notification) { guard !updating, let table else { return }; model.select(Set(table.selectedRowIndexes.filter { model.tags.indices.contains($0) }.map { model.tags[$0].name })) } }
}

private struct RemoteTagRemoteField: NSViewRepresentable {
    let remote: String
    func makeNSView(context: Context) -> NSTextField { let field = NSTextField(); field.isEditable = false; field.isSelectable = true; field.isBordered = true; field.bezelStyle = .roundedBezel; field.setAccessibilityLabel("Remote"); return field }
    func updateNSView(_ field: NSTextField, context: Context) { field.stringValue = remote }
}
