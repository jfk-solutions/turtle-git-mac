// Adapts TortoiseGit's ImportPatchDlg controls and git-am workflow (see NOTICE).
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ImportPatchWindowController: NSWindowController, NSWindowDelegate, NSSharingServiceDelegate {
    let model: ImportPatchWindowModel
    var onClosed: () -> Void = {}
    private var approvedClose = false
    private var patch: PatchWindowController?
    private var mail: NSSharingService?
    private var mailCompletion: ((String?) -> Void)?
    var activeOperation: Bool { model.busy || model.closing || model.openingViewer || model.composingMail || window?.attachedSheet != nil || patch?.model.busy == true || patch?.window?.attachedSheet != nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = ImportPatchWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Apply Patch Serial – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ImportPatchDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(.init(width: 800, height: 620))
        window.contentMinSize = .init(width: 660, height: 460); window.center()
        model.chooseFiles = { [weak self] in self?.chooseFiles() }
        model.showPatch = { [weak self] bytes, title, alternate in
            guard let self else { return }
            if try await UnifiedDiffApplication.openExternal(bytes, alternate: alternate) { return }
            self.patch = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: self.patch, title: title, onClosed: { [weak self] in self?.patch = nil })
        }
        model.composeMail = { [weak self] files, completion in
            guard let self else { completion("The patch window was closed."); return }
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) else {
                completion("No mail composition service is available."); return
            }
            self.mail = service; self.mailCompletion = completion
            service.delegate = self; service.subject = "Patch series"; service.perform(withItems: files)
        }
        model.chooseRecovery = { [weak self] in
            guard let self else { return nil }
            let response = await self.prompt("A patch import is active", "Resolve conflicts and stage the result before choosing Resolved.", buttons: ["Abort", "Skip", "Resolved", "Cancel"])
            return (0..<3).contains(response) ? [MailPatchRecovery.abort, .skip, .resolved][response] : nil
        }
        model.chooseClose = { [weak self] in
            guard let self else { return .cancel }
            let response = await self.prompt("A patch import is active", "Abort the import, or keep its state to continue later?", buttons: ["Abort", "Keep session", "Cancel"])
            return response == 0 ? .abort : response == 1 ? .keep : .cancel
        }
        model.chooseUnavailableClose = { [weak self] reason in
            guard let self else { return false }
            return await self.prompt("Could not check patch import state", reason + "\n\nClose this window and keep any existing Git state?", buttons: ["Close and keep state", "Cancel"]) == 0
        }
        model.close = { [weak self] in self?.approvedClose = true; self?.window?.performClose(nil) }
        DialogGeometry.attach(window, identifier: "ImportDlg", legacyName: "ImportDlg")
    }
    private func prompt(_ title: String, _ message: String, buttons: [String]) async -> Int {
        guard let window, window.attachedSheet == nil else { return -1 }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        for title in buttons { alert.addButton(withTitle: title) }
        // Cancel is the safe keyboard default; recovery remains an explicit choice.
        alert.buttons.first?.keyEquivalent = ""; alert.buttons.last?.keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons.last?.cell as? NSButtonCell
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        }
    }
    private func chooseFiles() {
        guard !activeOperation, let window else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.title = "Add patches"; panel.directoryURL = model.repository.root
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.model.add(panel.urls) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        guard sender.attachedSheet == nil, !model.openingViewer, !model.composingMail, patch?.model.busy != true, patch?.window?.attachedSheet == nil else { return false }
        model.requestClose(); return false
    }
    func windowWillClose(_ notification: Notification) { model.invalidate(); patch?.close(); onClosed() }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finishMail(nil) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { finishMail(error.localizedDescription) }
    private func finishMail(_ error: String?) { let completion = mailCompletion; mailCompletion = nil; mail = nil; completion?(error) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ImportPatchWindowModel: ObservableObject {
    enum State: String { case pending = "", applying = "Applying", success = "Success", failed = "Failed", skipped = "Skipped" }
    enum CloseChoice { case abort, keep, cancel }
    enum ContextAction: String { case viewPatch = "View Patch", sendMail = "Send Mail…" }
    struct Item: Identifiable {
        let id = UUID()
        let file: URL
        let access: RepositoryAccessLease
        var checked = true
        var state = State.pending
    }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let previewDocument: PatchWindowModel
    @Published private(set) var items: [Item] = []
    @Published var selection: Set<UUID> = [] { didSet { loadPreview() } }
    @Published var options = MailPatchOptions()
    @Published var tab = 0
    @Published private(set) var preview = ""
    @Published private(set) var previewNotice: String?
    @Published private(set) var output = ""
    @Published private(set) var busy = false
    @Published private(set) var stopRequested = false
    @Published private(set) var closing = false
    @Published private(set) var openingViewer = false
    @Published private(set) var composingMail = false
    @Published var error: String?
    private var failedRow: UUID?
    private var invalidated = false
    private var previewGeneration = UUID()
    var chooseFiles: () -> Void = {}
    var showPatch: (Data, String, Bool) async throws -> Void = { _, _, _ in }
    var composeMail: ([URL], @escaping (String?) -> Void) -> Void = { _, done in done("No mail composition service is available.") }
    var chooseRecovery: () async -> MailPatchRecovery? = { nil }
    var chooseClose: () async -> CloseChoice = { .cancel }
    var chooseUnavailableClose: (String) async -> Bool = { _ in false }
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var finished: Bool { !items.isEmpty && items.allSatisfy { $0.state == .success || $0.state == .skipped } }
    var editable: Bool { !busy && !closing && !openingViewer && !composingMail && !invalidated }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access
        previewDocument = PatchWindowModel(repository: repository, access: access, appearancePreferences: preferences)
        previewDocument.setReadOnlyDiff(Data()); previewDocument.refreshAvailable = false
    }
    func invalidate() { guard !busy, !openingViewer, !composingMail else { return }; invalidated = true; previewGeneration = UUID(); items = []; selection = [] }
    func contextActions(_ ids: Set<UUID>) -> [ContextAction] {
        guard editable else { return [] }
        let count = items.filter { ids.contains($0.id) }.count
        return count == 1 ? [.viewPatch, .sendMail] : count > 1 ? [.sendMail] : []
    }
    func viewPatch(_ ids: Set<UUID>, alternate: Bool) {
        guard editable, contextActions(ids).contains(.viewPatch), let item = items.first(where: { ids.contains($0.id) }) else { return }
        openingViewer = true
        Task {
            defer { openingViewer = false }
            do {
                // Retain the selected item and its lease through the viewer handoff.
                // The external viewer receives an exact app-owned byte snapshot.
                let bytes = try await Task.detached { try Data(contentsOf: item.file) }.value
                try await showPatch(bytes, item.file.lastPathComponent, alternate)
            } catch { self.error = error.localizedDescription }
        }
    }
    func sendMail(_ ids: Set<UUID>) {
        guard editable, contextActions(ids).contains(.sendMail) else { return }
        let selected = items.filter { ids.contains($0.id) }
        composingMail = true
        composeMail(selected.map(\.file)) { [weak self] error in
            // Capture the leases until macOS finishes composing or reports failure.
            _ = selected
            self?.composingMail = false
            if let error { self?.error = error }
        }
    }
    func add(_ urls: [URL]) {
        guard editable else { return }
        for url in urls {
            guard url.isFileURL else { error = MailPatchFailure.file.localizedDescription; continue }
            let lease = RepositoryAccessLease(url: url)
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope || (access?.hasSecurityScope == true && access?.contains(url) == true) else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; continue }
            items.append(Item(file: url, access: lease))
        }
    }
    func check(_ id: UUID, _ checked: Bool) {
        guard editable, let index = items.firstIndex(where: { $0.id == id }), items[index].state != .success else { return }
        items[index].checked = checked
        if items[index].state == .skipped { items[index].state = .pending }
    }
    func remove() {
        guard editable else { return }
        items.removeAll { selection.contains($0.id) }; selection = []
        // Retain failedRow's identity even if its row was removed: Git's active
        // session must still be recovered, without marking a different row done.
    }
    func move(_ direction: Int) {
        guard editable, direction == -1 || direction == 1 else { return }
        let indexes = items.indices.filter { selection.contains(items[$0].id) }
        guard let first = indexes.first, let last = indexes.last,
              direction < 0 ? first > 0 : last < items.count - 1 else { return }
        for index in direction < 0 ? indexes : indexes.reversed() { items.swapAt(index, index + direction) }
    }
    private func state(_ id: UUID, _ value: State) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = value }
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func loadPreview() {
        let generation = UUID(); previewGeneration = generation; preview = ""; previewNotice = nil; previewDocument.setReadOnlyDiff(Data())
        guard !invalidated, selection.count == 1, let item = items.first(where: { selection.contains($0.id) }) else { return }
        Task {
            let result = await Task.detached { () -> (Data?, String?) in
                let size = (try? item.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 250 * 1024 * 1024 else { return (nil, "This patch is too large to preview. It can still be imported.") }
                guard let data = try? Data(contentsOf: item.file) else { return (nil, "The patch could not be read.") }
                return (data, nil)
            }.value
            guard !invalidated, previewGeneration == generation else { return }
            if let bytes = result.0 { previewDocument.setReadOnlyDiff(bytes); preview = previewDocument.document.text }
            else { previewNotice = result.1; preview = result.1 ?? "" }
        }
    }
    func apply() {
        guard editable else { return }
        if finished { requestClose(); return }
        guard !items.isEmpty else { return }
        let batch = items, flags = options
        busy = true; stopRequested = false; error = nil; tab = 1
        Task {
            defer { busy = false; onChanged(output) }
            do {
                try checkAccess()
                _ = try await repository.run(["var", "GIT_COMMITTER_IDENT"])
                try await recoverSession()
                for item in batch {
                    guard !stopRequested else { output += "\nBatch stopped after the current Git command.\n"; break }
                    guard let current = items.first(where: { $0.id == item.id }), current.state != .success, current.state != .skipped else { continue }
                    guard current.checked else { state(item.id, .skipped); output += "\nSkipped: \(item.file.path)\n"; continue }
                    state(item.id, .applying); output += "\nApplying: \(item.file.path)\n"
                    do {
                        let result = try await repository.importMailPatch(item.file, options: flags)
                        output += result + "\nSuccess\n"; state(item.id, .success)
                    } catch {
                        state(item.id, .failed); failedRow = item.id; throw error
                    }
                    onChanged(output)
                }
            } catch {
                output += "\n" + error.localizedDescription + "\n"; self.error = error.localizedDescription
            }
        }
    }
    private func recoverSession() async throws {
        var session = try await repository.mailPatchSession()
        while session == .applying {
            guard !stopRequested, let action = await chooseRecovery() else { stopRequested = true; return }
            output += "\ngit am --\(action.rawValue)\n"
            output += try await repository.recoverMailPatch(action)
            session = try await repository.mailPatchSession()
            if session == .none {
                if let failedRow {
                    switch action {
                    case .abort: state(failedRow, .pending)
                    case .skip: state(failedRow, .skipped)
                    case .resolved: state(failedRow, .success)
                    }
                }
                failedRow = nil
            }
            onChanged(output)
        }
        if session == .rebase { throw MailPatchFailure.rebase }
        // An externally aborted session permits retry of the retained failed row.
        if session == .none { failedRow = nil }
    }
    func requestStop() { if busy { stopRequested = true } }
    func requestClose() {
        if busy { requestStop(); return }
        guard editable else { return }; closing = true
        Task {
            defer { closing = false }
            let session: MailPatchSession
            do {
                try checkAccess()
                session = try await repository.mailPatchSession()
            } catch {
                // Missing repository/runtime or lost access must not trap an idle
                // window. An unknown session can only be left intact, not aborted.
                if await chooseUnavailableClose(error.localizedDescription) { close() }
                return
            }
            do {
                if session == .applying {
                    switch await chooseClose() {
                    case .cancel: return
                    case .keep: break
                    case .abort: output += try await repository.recoverMailPatch(.abort); onChanged(output)
                    }
                }
                close()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ImportPatchDialog: View {
    @ObservedObject var model: ImportPatchWindowModel
    @AppStorage("ShowAppContextMenuIcons") private var contextIcons = true
    private func tool(_ title: String, _ icon: MenuIcon, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Image(nsImage: icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(title) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ImportPatchSplit(upper: AnyView(VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Patch files:"); Spacer()
                tool("Up", .jumpUp) { model.move(-1) }.disabled(model.selection.isEmpty)
                tool("Down", .jumpDown) { model.move(1) }.disabled(model.selection.isEmpty)
                tool("Remove", .remove) { model.remove() }.disabled(model.selection.isEmpty)
                tool("Add…", .add) { model.chooseFiles() }
            }.disabled(!model.editable)
            Table(model.items, selection: $model.selection) {
                TableColumn("") { item in Toggle("Import \(item.file.lastPathComponent)", isOn: Binding(get: { item.checked }, set: { model.check(item.id, $0) })).labelsHidden().disabled(!model.editable || item.state == .success) }.width(28)
                TableColumn("Path") { item in Text(item.file.path).help(item.file.path) }
                TableColumn("Status") { item in Text(item.state.rawValue).foregroundStyle(item.state == .failed ? Color.red : item.state == .success ? .green : item.state == .applying ? .blue : .secondary) }.width(85)
            }.contextMenu(forSelectionType: UUID.self) { ids in
                ForEach(model.contextActions(ids), id: \.self) { action in
                    Button {
                        switch action {
                        case .viewPatch: model.viewPatch(ids, alternate: NSEvent.modifierFlags.contains(.shift))
                        case .sendMail: model.sendMail(ids)
                        }
                    } label: {
                        HStack {
                            if contextIcons { Image(nsImage: (action == .viewPatch ? MenuIcon.patch : .sendMail).image() ?? NSImage()) }
                            Text(action.rawValue)
                        }
                    }
                }
            } primaryAction: { ids in model.viewPatch(ids, alternate: NSEvent.modifierFlags.contains(.shift)) }
            .frame(minHeight: 120)
            HStack {
                Toggle("3-way", isOn: $model.options.threeWay)
                Toggle("Ignore space change", isOn: $model.options.ignoreSpaceChange)
                Toggle("Sign-off", isOn: $model.options.signOff)
                Toggle("Keep CR", isOn: $model.options.keepCR)
            }.disabled(!model.editable)
            }), lower: AnyView(TabView(selection: $model.tab) {
                Group {
                    if let notice = model.previewNotice { ScrollView { Text(notice).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12) } }
                    else { PatchTextView(model: model.previewDocument) }
                }.tabItem { Text("Patch") }.tag(0)
                OutputView(text: model.output, usesLogFont: true).tabItem { Text("Log") }.tag(1)
            }), preferences: model.previewDocument.appearancePreferences)
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text(model.stopRequested ? "Stopping after current command…" : "Applying patches…") }
                Spacer()
                Button(model.finished ? "OK" : "Apply") { model.apply() }.keyboardShortcut(.defaultAction).disabled(!model.editable || model.items.isEmpty)
                Button(model.busy ? "Abort" : "Cancel") { model.requestClose() }.keyboardShortcut(.cancelAction).disabled(model.closing || model.stopRequested && model.busy)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-patch.html")!) }
            }
        }.padding(16)
        .alert("Apply Patch Serial", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

/// Native divider; the source persists AMDlgSizer in ResizableState.
struct ImportPatchSplit: NSViewControllerRepresentable {
    let upper: AnyView
    let lower: AnyView
    let preferences: UserDefaults
    private func hosted(_ view: AnyView, environment: EnvironmentValues) -> AnyView {
        AnyView(view.environment(\.self, environment).defaultAppStorage(preferences))
    }
    func makeNSViewController(context: Context) -> ImportPatchSplitController {
        ImportPatchSplitController(upper: hosted(upper, environment: context.environment), lower: hosted(lower, environment: context.environment), preferences: preferences)
    }
    func updateNSViewController(_ controller: ImportPatchSplitController, context: Context) {
        controller.upper.rootView = hosted(upper, environment: context.environment); controller.lower.rootView = hosted(lower, environment: context.environment)
    }
}

@MainActor final class ImportPatchSplitController: NSViewController, NSSplitViewDelegate {
    static let positionKey = WindowGeometryStore.prefix + "AMDlgSizer"
    let splitView = NSSplitView()
    let upper: NSHostingController<AnyView>
    let lower: NSHostingController<AnyView>
    private let preferences: UserDefaults
    private var initialized = false
    init(upper: AnyView, lower: AnyView, preferences: UserDefaults) {
        self.upper = NSHostingController(rootView: upper); self.lower = NSHostingController(rootView: lower)
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() { view = splitView }
    override func viewDidLoad() {
        super.viewDidLoad(); splitView.isVertical = false; splitView.dividerStyle = .thin
        splitView.setAccessibilityLabel("Patch list and preview divider")
        upper.sizingOptions = []; lower.sizingOptions = []
        addChild(upper); addChild(lower)
        splitView.addArrangedSubview(upper.view); splitView.addArrangedSubview(lower.view)
        splitView.delegate = self; splitView.adjustSubviews()
    }
    private func fitted(_ value: CGFloat) -> CGFloat {
        let available = max(0, splitView.bounds.height - splitView.dividerThickness)
        let topMinimum = min(220, available / 2), bottomMinimum = min(160, available / 2)
        return min(max(value, topMinimum), available - bottomMinimum)
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.bounds.height > 0 else { return }
        let stored = preferences.double(forKey: Self.positionKey)
        let wanted = initialized ? upper.view.frame.height : stored.isFinite && stored > 0 ? CGFloat(stored) : splitView.bounds.height / 2
        let height = fitted(wanted), divider = splitView.dividerThickness
        upper.view.frame = NSRect(x: 0, y: 0, width: splitView.bounds.width, height: height)
        lower.view.frame = NSRect(x: 0, y: height + divider, width: splitView.bounds.width, height: max(0, splitView.bounds.height - height - divider))
        initialized = true
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { fitted(0) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { fitted(.greatestFiniteMagnitude) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard initialized else { return }
        let position = Double(upper.view.frame.height)
        guard position.isFinite, position > 0 else { return }
        if preferences.double(forKey: Self.positionKey) != position { preferences.set(position, forKey: Self.positionKey) }
    }
}
