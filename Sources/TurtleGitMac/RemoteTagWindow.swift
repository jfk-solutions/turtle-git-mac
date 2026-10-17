import AppKit
import SwiftUI
import TurtleGitCore

private final class RemoteTagNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if event.keyCode == 96, event.window === self, attachedSheet == nil, event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty { refresh(); return true }; return super.performKeyEquivalent(with: event) }
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
    private var question: (id: UUID, alert: NSAlert, reply: (Bool) -> Void)?
    var presentQuestion: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { alert, owner, reply in
        guard owner.attachedSheet == nil else { return false }; alert.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    var progressWindow: NSWindow? { progress?.window }
    var presentProgress: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    init(repository: GitRepository, access: RepositoryAccessLease?, remote: String, preferences: UserDefaults = .standard) {
        model = RemoteTagWindowModel(repository: repository, access: access, remote: remote, preferences: preferences)
        let window = RemoteTagNativeWindow(contentRect: .init(x: 0, y: 0, width: 510, height: 290), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Delete remote tag – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 480, height: 250)
        let host = NSHostingController(rootView: RemoteTagDialog(model: model).defaultAppStorage(preferences))
        host.sizingOptions = []; window.contentViewController = host
        window.setContentSize(NSSize(width:510,height:290))
        super.init(window: window); window.delegate = self; window.center()
        model.phaseChanged = { [weak self] in self?.showProgress($0) }; window.refresh = { [weak model] in model?.load() }
        model.close = { [weak self] in guard let self, !self.model.busy, self.window?.attachedSheet == nil else { return }; self.close() }
        model.confirm = { [weak self] tags in
            await self?.ask(RemoteTagConfirmation.message(tags), destructive: true) ?? false
        }
        model.acknowledge = { [weak self] message in _ = await self?.ask(message, destructive: false) }
        model.sshSettings.present = { [weak self] prompt in
            guard let owner = self?.progressWindow ?? self?.window, owner.attachedSheet == nil, let child = prompt.window else { return false }
            owner.makeFirstResponder(nil); owner.beginSheet(child); return true
        }
        DialogGeometry.attach(window, identifier: "DeleteRemoteTagDlg", legacyName: "DeleteRemoteTagDlg")
    }
    private func ask(_ message: String, destructive: Bool) async -> Bool {
        guard !model.closed, question == nil, let owner = window, owner.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = "TurtleGit"; alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .critical
        let first = alert.addButton(withTitle: destructive ? "Delete" : "OK")
        if destructive {
            first.keyEquivalent = ""
            let abort = alert.addButton(withTitle: "Abort"); abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) })
            if !presentQuestion(alert, owner, { [weak self] response in self?.settleQuestion(id, accepted: response == .alertFirstButtonReturn) }) {
                settleQuestion(id, accepted: false)
            }
        }
    }
    private func settleQuestion(_ id: UUID, accepted: Bool) {
        guard let pending = question, pending.id == id else { return }
        question = nil
        if let parent = pending.alert.window.sheetParent { parent.endSheet(pending.alert.window, returnCode: .abort) }
        pending.alert.window.orderOut(nil); pending.reply(accepted)
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
    func windowWillClose(_ notification: Notification) { model.invalidate(); if let question { settleQuestion(question.id, accepted: false) }; showProgress(nil); if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort); sheet.close() }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RemoteTagWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    enum Phase: String { case loading = "Loading…", deleting = "Deleting remote refs…" }
    let repository: GitRepository
    let sshSettings: SSHTransportSettings
    let access: RepositoryAccessLease?
    let remote: String
    private var token: OperationCancellation?
    private(set) var closed = false
    @Published private(set) var tags: [RemoteTag] = []
    @Published private(set) var selection = Set<GitReferenceName>()
    @Published private(set) var busy = false { didSet { if oldValue != busy {formRevision=UUID()} } }
    @Published var error: String?
    @Published private(set) var phase: Phase? { didSet { phaseChanged(phase) } }
    var phaseChanged: (Phase?) -> Void = { _ in }
    var confirm: (([GitReferenceName]) async -> Bool)?
    var acknowledge: (String) async -> Void = { _ in }
    var query: (OperationCancellation) async throws -> [RemoteTag]
    var remove: ([GitReferenceName], OperationCancellation) async throws -> Void
    var close: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, remote: String, preferences: UserDefaults) {
        self.repository = repository; self.access = access; self.remote = remote
        let settings = SSHTransportSettings(repository: repository); settings.enabled = settings.available; sshSettings = settings
        query = { token in
            let coordinator = settings.capture()?(); defer { coordinator?.close() }
            return try await repository.remoteTags(remote: remote, reversed: preferences.bool(forKey: "SortTagsReversed"), cancellation: token, prepareTransport: coordinator?.preparation)
        }
        remove = { tags, token in
            let coordinator = settings.capture()?(); defer { coordinator?.close() }
            try await repository.deleteRemoteTags(remote: remote, tags: tags, cancellation: token, prepareTransport: coordinator?.preparation)
        }
    }
    private var formRevision=UUID()
    struct FormContext: Equatable { let owner:ObjectIdentifier;let revision:UUID }
    var formContext:FormContext {.init(owner:ObjectIdentifier(self),revision:formRevision)}
    private func accepts(_ context:FormContext)->Bool {!closed && !busy && context==formContext}
    func select(_ names:Set<GitReferenceName>,context:FormContext) {guard accepts(context) else{return};select(names)}
    func selectAll(_ state:NSControl.StateValue,context:FormContext) {guard accepts(context) else{return};selectAll(state)}
    func delete(context:FormContext) {guard accepts(context) else{return};delete()}
    var canDelete: Bool { !closed && !busy && !selection.isEmpty && confirm != nil }
    var selectedTags: [GitReferenceName] { tags.filter { selection.contains($0.name) }.map(\.name) }
    var selectAllState: NSControl.StateValue { selection.isEmpty ? .off : selection.count == tags.count ? .on : .mixed }
    func select(_ names: Set<GitReferenceName>) { guard !closed, !busy else { return }; selection = names.intersection(Set(tags.map(\.name))) }
    func selectAll(_ state: NSControl.StateValue) { select(state == .on ? Set(tags.map(\.name)) : []) }
    private func checkAccess() throws { if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable } }
    private func live(_ request: OperationCancellation) -> Bool { !closed && token === request && !request.isCancelled }
    func invalidate() { closed = true; token?.cancel(); phase = nil }
    private func perform(_ body: @escaping (OperationCancellation) async -> Void) {
        guard !closed, !busy else { return }
        let request = OperationCancellation(); token = request; busy = true; error = nil; Self.activeOperations += 1
        Task { [self, access] in
            defer {
                Self.activeOperations -= 1
                if token === request { token = nil; busy = false; phase = nil }
                withExtendedLifetime(access) {}
            }
            guard live(request) else { return }
            await body(request)
        }
    }
    private func report(_ failure: Error, request: OperationCancellation) async {
        guard live(request) else { return }
        phase = nil; error = failure.localizedDescription
        await acknowledge(failure.localizedDescription)
    }
    private func reload(_ request: OperationCancellation, query: @escaping (OperationCancellation) async throws -> [RemoteTag]) async {
        guard live(request) else { return }
        selection = []; tags = []; phase = .loading
        do { try checkAccess(); let rows = try await query(request); guard live(request) else { return }; tags = rows }
        catch { await report(error, request: request) }
        if live(request) { phase = nil }
    }
    func load(preservingError: String? = nil) {
        let query = query
        perform { [self] request in
            error = preservingError
            await reload(request, query: query)
        }
    }
    func delete() {
        guard canDelete, let confirm else { return }
        let captured = selectedTags, remove = remove, query = query
        perform { [self] request in
            let accepted = await confirm(captured)
            guard live(request), accepted else { return }
            phase = .deleting
            do { try checkAccess(); try await remove(captured, request) }
            catch { await report(error, request: request) }
            guard live(request) else { return }
            phase = nil
            await reload(request, query: query)
        }
    }
}
private struct RemoteTagDialog: View {
    @ObservedObject var model: RemoteTagWindowModel
    var body: some View {
        let context=model.formContext
        VStack(spacing: 12) {
            HStack { Text("Remote:").frame(width: 95, alignment: .leading); RemoteTagRemoteField(remote: model.remote).frame(maxWidth:.infinity).frame(height:24) }.frame(height:24)
            HStack(alignment: .top) { Text("Tags:").frame(width: 95, alignment: .leading); RemoteTagTable(model: model).frame(maxWidth: .infinity, maxHeight: .infinity).border(Color(nsColor: .separatorColor)) }
            HStack { RemoteTagAllCheckbox(model: model).frame(height:22); Spacer(); Button("Delete") { model.delete(context:context) }.keyboardShortcut(.defaultAction).disabled(!model.canDelete); Button("Close") { model.close() }.keyboardShortcut(.cancelAction).disabled(model.busy) }
        }.padding(12).disabled(model.busy).onAppear { model.load() }

    }
}
@MainActor final class RemoteTagOwnedCheckbox:NSButton {
    let lifetime=TransportControlLifetime()
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();lifetime.observe(self)}
}
private struct RemoteTagAllCheckbox: NSViewRepresentable {
    @ObservedObject var model: RemoteTagWindowModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {let button=RemoteTagOwnedCheckbox(checkboxWithTitle:"Select/deselect all",target:context.coordinator,action:#selector(Coordinator.changed(_:)));button.allowsMixedState=true;return button}
    func updateNSView(_ button:NSButton,context:Context) {
        guard (button as? RemoteTagOwnedCheckbox)?.lifetime.retired != true else {button.isEnabled=false;return}
        let form=model.formContext;context.coordinator.change={ [weak model] state in model?.selectAll(state == .mixed ? .off:state,context:form) }
        button.state=model.selectAllState;button.isEnabled = !model.busy && !model.closed
    }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator) {coordinator.live=false;coordinator.change={_ in};(button as? RemoteTagOwnedCheckbox)?.lifetime.retire();button.target=nil}
    @MainActor final class Coordinator:NSObject {
        var live=true;var change:(NSControl.StateValue)->Void={_ in}
        @objc func changed(_ sender:NSButton) {guard live,sender.isEnabled,sender.window != nil,(sender as? RemoteTagOwnedCheckbox)?.lifetime.retired != true else{return};change(sender.state)}
    }
}
@MainActor final class RemoteTagOwnedTable:NSTableView {
    let lifetime=TransportControlLifetime()
    var contentWidth:CGFloat=200
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();lifetime.observe(self)}
    func fitViewport(_ viewport:NSSize) {
        let width=max(200,contentWidth,viewport.width)
        if tableColumns.first?.width != width {tableColumns.first?.width=width}
        let size=NSSize(width:width,height:max(CGFloat(numberOfRows)*(rowHeight+intercellSpacing.height),viewport.height))
        if frame.size != size {setFrameSize(size)}
    }
}
@MainActor final class RemoteTagOwnedScroll:NSScrollView {
    private var fitting=false
    override func tile() {
        super.tile();guard !fitting,let table=documentView as? RemoteTagOwnedTable else{return}
        fitting=true;defer {fitting=false};table.fitViewport(contentSize)
    }
}
private struct RemoteTagTable:NSViewRepresentable {
    @ObservedObject var model:RemoteTagWindowModel
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->NSScrollView {
        let table=RemoteTagOwnedTable();table.setAccessibilityLabel("Remote tags");table.headerView=nil;table.allowsMultipleSelection=true;table.rowHeight=22;table.columnAutoresizingStyle = .noColumnAutoresizing
        let column=NSTableColumn(identifier:.init("tag"));column.maxWidth = .greatestFiniteMagnitude;table.addTableColumn(column)
        table.delegate=context.coordinator;table.dataSource=context.coordinator;context.coordinator.table=table
        let scroll=RemoteTagOwnedScroll();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.documentView=table;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        let coordinator=context.coordinator
        guard !coordinator.retired,let table=coordinator.table,table.lifetime.retired == false else{return}
        let form=model.formContext;coordinator.change={ [weak model] names in model?.select(names,context:form) }
        coordinator.updating=true;defer {coordinator.updating=false}
        let names=model.tags.map(\.name)
        if names != coordinator.names {coordinator.names=names;table.reloadData()}
        table.selectRowIndexes(IndexSet(names.indices.filter {model.selection.contains(names[$0])}),byExtendingSelection:false)
        table.isEnabled = !model.busy && !model.closed
        let font=NSFont.systemFont(ofSize:NSFont.systemFontSize)
        let width=names.map {($0.rawValue as NSString).size(withAttributes:[.font:font]).width+16}.max() ?? 0
        table.contentWidth=width;table.fitViewport(scroll.contentSize)
    }
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator) {coordinator.retired=true;coordinator.change={_ in};coordinator.table?.lifetime.retire();coordinator.table?.delegate=nil;coordinator.table?.dataSource=nil}
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        weak var table:RemoteTagOwnedTable?;var names:[GitReferenceName]=[];var updating=false,retired=false;var change:(Set<GitReferenceName>)->Void={_ in}
        func numberOfRows(in tableView:NSTableView)->Int {names.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard names.indices.contains(row) else{return nil}
            let cell=NSTextField(labelWithString:names[row].rawValue);cell.font = .systemFont(ofSize:NSFont.systemFontSize);cell.lineBreakMode = .byClipping;cell.toolTip=names[row].rawValue;return cell
        }
        func selectionShouldChange(in tableView:NSTableView)->Bool {updating || (!retired && table?.isEnabled==true && table?.lifetime.retired==false)}
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updating,!retired,let table,table.isEnabled,!table.lifetime.retired,table.window != nil else{return}
            change(Set(table.selectedRowIndexes.compactMap {names.indices.contains($0) ? names[$0]:nil}))
        }
    }
}

private struct RemoteTagRemoteField: NSViewRepresentable {
    let remote: String
    func makeNSView(context: Context) -> NSTextField { let field = NSTextField(); field.isEditable = false; field.isSelectable = true; field.isBordered = true; field.bezelStyle = .roundedBezel; field.setContentHuggingPriority(.defaultLow,for:.horizontal); field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); field.setAccessibilityLabel("Remote"); return field }
    func updateNSView(_ field: NSTextField, context: Context) { field.stringValue = remote }
}
