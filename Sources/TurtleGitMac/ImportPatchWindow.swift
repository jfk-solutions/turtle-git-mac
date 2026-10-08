// Adapts TortoiseGit's ImportPatchDlg controls and git-am workflow (see NOTICE).
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class ImportPatchWindowController: NSWindowController, NSWindowDelegate, NSSharingServiceDelegate {
    let model: ImportPatchWindowModel
    var onClosed: () -> Void = {}
    private var approvedClose = false
    private var patch: PatchWindowController?
    private var review: WorkingTreePatchWindowController?
    private var mail: NSSharingService?
    private var mailCompletion: ((String?) -> Void)?
    var activeOperation: Bool { model.confirmingQuit || model.receivingDrop || model.busy || model.closing || model.openingViewer || model.composingMail || window?.attachedSheet != nil || patch?.model.busy == true || patch?.window?.attachedSheet != nil || review?.activeOperation == true }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = ImportPatchWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Apply Patch Serial – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ImportPatchDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(.init(width: 800, height: 620))
        window.contentMinSize = .init(width: 660, height: 460); window.center()
        model.childActive = { [weak self] in self?.review?.activeOperation == true || self?.review?.model.dirty == true || self?.review?.model.editingEnabled == true || self?.patch?.model.busy == true || self?.patch?.window?.attachedSheet != nil }
        model.onStateChanged = { [weak self] in self?.review?.model.updateParentState() }
        model.showReview = { [weak self] bytes, title, lease in
            guard let self else { return }
            self.review?.close()
            let controller = WorkingTreePatchWindowController(repository: repository, access: access, fileAccess: lease, bytes: bytes, title: title, preferences: preferences)
            controller.model.parentActive = { [weak self] in
                guard let self else { return true }
                return self.model.busy || self.model.closing || self.model.confirmingQuit || self.window?.attachedSheet != nil
            }
            controller.model.onChanged = { [weak self] output in self?.model.onChanged(output) }
            controller.model.onBusyChanged = { [weak self] in self?.model.objectWillChange.send() }
            controller.onClosed = { [weak self, weak controller] in if self?.review === controller { self?.review = nil; self?.model.objectWillChange.send() } }
            self.review = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
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
        model.configureIdentity = { [weak self] in
            guard let self else { return false }
            guard await self.prompt("Git identity is incomplete", "A user name and email are required before importing commits. Configure them now?", buttons: ["Configure…", "Cancel"]) == 0 else { return false }
            return try await self.configureIdentity()
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
    private func configureIdentity() async throws -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        let name = NSTextField(string: try await model.repository.run(["config", "--get", "user.name"], successfulExitCodes: 0...1).text.trimmingCharacters(in: .newlines))
        let email = NSTextField(string: try await model.repository.run(["config", "--get", "user.email"], successfulExitCodes: 0...1).text.trimmingCharacters(in: .newlines))
        let scope = NSPopUpButton(); scope.addItems(withTitles: ["This repository", "Global"])
        let form = NSGridView(views: [[NSTextField(labelWithString: "Name:"), name], [NSTextField(labelWithString: "Email:"), email], [NSTextField(labelWithString: "Save in:"), scope]])
        form.frame = NSRect(x: 0, y: 0, width: 360, height: 92); form.column(at: 1).width = 270
        name.setAccessibilityLabel("Git user name"); email.setAccessibilityLabel("Git user email"); scope.setAccessibilityLabel("Git configuration scope")
        let alert = NSAlert(); alert.messageText = "Git identity"; alert.informativeText = "Set user.name and user.email. Existing author/committer overrides remain in effect."
        alert.accessoryView = form; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"; alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        guard response == .alertFirstButtonReturn else { return false }
        let userName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), userEmail = email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userName.isEmpty, !userEmail.isEmpty, !userName.contains("\0"), !userEmail.contains("\0"), !userName.contains("\n"), !userEmail.contains("\n") else { throw NSError(domain: "TurtleGit.GitIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a nonempty Git name and email without line breaks."]) }
        let option = scope.indexOfSelectedItem == 0 ? "--local" : "--global"
        _ = try await model.repository.run(["config", option, "user.name", userName])
        _ = try await model.repository.run(["config", option, "user.email", userEmail])
        return true
    }
    private func chooseFiles() {
        guard !activeOperation, model.editable, let window else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.title = "Add patches"; panel.directoryURL = model.repository.root
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.model.add(panel.urls) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        guard review?.activeOperation != true, sender.attachedSheet == nil, !model.confirmingQuit, !model.receivingDrop, !model.openingViewer, !model.composingMail, patch?.model.busy != true, patch?.window?.attachedSheet == nil else { return false }
        if let review, review.model.dirty {
            Task { [weak self] in if await review.model.resolveDraft() { self?.model.requestClose() } }
        } else { model.requestClose() }
        return false
    }
    func windowWillClose(_ notification: Notification) { model.invalidate(); patch?.close(); review?.close(); onClosed() }
    func setQuitConfirmation(_ value: Bool) {
        model.confirmingQuit = value; review?.setQuitConfirmation(value)
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finishMail(nil) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { finishMail(error.localizedDescription) }
    private func finishMail(_ error: String?) { let completion = mailCompletion; mailCompletion = nil; mail = nil; completion?(error) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ImportPatchWindowModel: ObservableObject {
    enum State: String { case pending = "", applying = "Applying", success = "Success", failed = "Failed", skipped = "Skipped" }
    enum CloseChoice { case abort, keep, cancel }
    enum ContextAction: String { case viewPatch = "View Patch", reviewPatch = "Review Patch with TurtleGitMerge", sendMail = "Send Mail…" }
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
    @Published private(set) var busy = false { didSet { onStateChanged() } }
    @Published private(set) var stopRequested = false
    @Published var confirmingQuit = false { didSet { onStateChanged() } }
    @Published private(set) var closing = false { didSet { onStateChanged() } }
    @Published private(set) var receivingDrop = false
    @Published private(set) var openingViewer = false
    @Published private(set) var composingMail = false
    @Published var error: String?
    private var failedRow: UUID?
    private var invalidated = false
    private var previewGeneration = UUID()
    var chooseFiles: () -> Void = {}
    var onStateChanged: () -> Void = {}
    var childActive: () -> Bool = { false }
    var showReview: (Data, String, RepositoryAccessLease) throws -> Void = { _, _, _ in }
    var showPatch: (Data, String, Bool) async throws -> Void = { _, _, _ in }
    var composeMail: ([URL], @escaping (String?) -> Void) -> Void = { _, done in done("No mail composition service is available.") }
    var configureIdentity: () async throws -> Bool = { false }
    var chooseRecovery: () async -> MailPatchRecovery? = { nil }
    var chooseClose: () async -> CloseChoice = { .cancel }
    var chooseUnavailableClose: (String) async -> Bool = { _ in false }
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var finished: Bool { !items.isEmpty && items.allSatisfy { $0.state == .success || $0.state == .skipped } }
    var editable: Bool { !confirmingQuit && !receivingDrop && !busy && !closing && !openingViewer && !composingMail && !invalidated && !childActive() }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access
        previewDocument = PatchWindowModel(repository: repository, access: access, appearancePreferences: preferences)
        previewDocument.setReadOnlyDiff(Data()); previewDocument.refreshAvailable = false
    }
    func invalidate() { guard !receivingDrop, !busy, !openingViewer, !composingMail else { return }; invalidated = true; previewGeneration = UUID(); items = []; selection = [] }
    func contextActions(_ ids: Set<UUID>) -> [ContextAction] {
        guard editable else { return [] }
        let count = items.filter { ids.contains($0.id) }.count
        return count == 1 ? [.viewPatch, .reviewPatch, .sendMail] : count > 1 ? [.sendMail] : []
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
    func reviewPatch(_ ids: Set<UUID>) {
        guard editable, contextActions(ids).contains(.reviewPatch), let item = items.first(where: { ids.contains($0.id) }) else { return }
        openingViewer = true
        Task {
            defer { openingViewer = false }
            do {
                let bytes = try await Task.detached { try Data(contentsOf: item.file) }.value
                try showReview(bytes, item.file.lastPathComponent, item.access)
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
    /// Matches CPatchListCtrl::OnDropFiles: ordered files, no directories or duplicates.
    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard editable else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        receivingDrop = true
        Task {
            var urls: [URL] = []
            var failure: String?
            for provider in files {
                do {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                            if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: error ?? MailPatchFailure.file) }
                        }
                    }
                    guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { throw MailPatchFailure.file }
                    urls.append(url)
                } catch { failure = error.localizedDescription }
            }
            receivingDrop = false
            guard !invalidated else { return }
            var paths = Set(items.map { $0.file.standardizedFileURL.path })
            let newFiles = urls.filter { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return false }
                return paths.insert(url.standardizedFileURL.path).inserted
            }
            add(newFiles)
            if let failure { error = failure }
        }
        return true
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
                guard try await ensureIdentity() else { output += "\nImport cancelled before applying patches.\n"; return }
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
    private func ensureIdentity() async throws -> Bool {
        while true {
            let environment = ProcessInfo.processInfo.environment
            func configured(_ key: String) async throws -> String {
                try await repository.run(["config", "--get", key], successfulExitCodes: 0...1).text.trimmingCharacters(in: .newlines)
            }
            let name = try await configured("user.name"), email = try await configured("user.email")
            let authorName = try await configured("author.name"), authorEmail = try await configured("author.email")
            let committerName = try await configured("committer.name"), committerEmail = try await configured("committer.email")
            func value(_ environmentKey: String, _ override: String, _ fallback: String) -> String {
                let env = environment[environmentKey] ?? ""
                return !env.isEmpty ? env : !override.isEmpty ? override : fallback
            }
            let fields = [value("GIT_AUTHOR_NAME", authorName, name), value("GIT_AUTHOR_EMAIL", authorEmail, email), value("GIT_COMMITTER_NAME", committerName, name), value("GIT_COMMITTER_EMAIL", committerEmail, email)]
            if fields.allSatisfy({ !$0.isEmpty }) {
                _ = try await repository.run(["var", "GIT_AUTHOR_IDENT"])
                _ = try await repository.run(["var", "GIT_COMMITTER_IDENT"])
                return !stopRequested
            }
            guard !stopRequested, try await configureIdentity() else { return false }
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
            if await confirmCloseState() { close() }
        }
    }
    /// Quit uses the same session choices without closing windows before every
    /// other document has approved termination.
    func confirmQuit() async -> Bool {
        guard !busy, !closing, !receivingDrop, !openingViewer, !composingMail, !invalidated else { return false }
        closing = true
        defer { closing = false }
        return await confirmCloseState()
    }
    private func confirmCloseState() async -> Bool {
        let session: MailPatchSession
        do {
            try checkAccess()
            session = try await repository.mailPatchSession()
        } catch {
            // Unknown state may only be kept, never automatically aborted.
            return await chooseUnavailableClose(error.localizedDescription)
        }
        do {
            if session == .applying {
                switch await chooseClose() {
                case .cancel: return false
                case .keep: break
                case .abort: output += try await repository.recoverMailPatch(.abort); onChanged(output)
                }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
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
                        case .reviewPatch: model.reviewPatch(ids)
                        case .sendMail: model.sendMail(ids)
                        }
                    } label: {
                        HStack {
                            if contextIcons { Image(nsImage: (action == .sendMail ? MenuIcon.sendMail : .patch).image() ?? NSImage()) }
                            Text(action.rawValue)
                        }
                    }
                }
            } primaryAction: { ids in model.viewPatch(ids, alternate: NSEvent.modifierFlags.contains(.shift)) }
            .frame(minHeight: 120)
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { model.receiveDrop($0) }
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
                Button(model.busy ? "Abort" : "Cancel") { model.requestClose() }.keyboardShortcut(.cancelAction).disabled(model.confirmingQuit || model.receivingDrop || model.closing || model.stopRequested && model.busy)
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

@MainActor private final class WorkingTreePatchNativeWindow: NSWindow {
    weak var model: WorkingTreePatchWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "s" { model?.saveDraft(); return true }
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", (firstResponder as? NSTextView)?.isFieldEditor != true {
            if flags.contains(.shift) { model?.editor?.redo() } else { model?.editor?.undo() }; return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class WorkingTreePatchWindowController: NSWindowController, NSWindowDelegate {
    let model: WorkingTreePatchWindowModel
    var onClosed: () -> Void = {}
    private var approvedClose = false
    var activeOperation: Bool { model.busy || model.confirmingQuit || model.draftDecisionPending || model.previewDocument.busy || window?.attachedSheet != nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, fileAccess: RepositoryAccessLease?, bytes: Data, title: String, preferences: UserDefaults = .standard) {
        model = WorkingTreePatchWindowModel(repository: repository, access: access, fileAccess: fileAccess, bytes: bytes, preferences: preferences)
        let window = WorkingTreePatchNativeWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) – Review Patch – TurtleGitMerge"; window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: WorkingTreePatchDialog(model: model)); host.sizingOptions = []
        window.contentViewController = host
        super.init(window: window); window.delegate = self; window.model = model
        window.setContentSize(.init(width: 1100, height: 720)); window.contentMinSize = .init(width: 800, height: 460); window.center()
        DialogGeometry.attach(window, identifier: "TurtleGit.PatchReview")
        model.close = { [weak self] in self?.approvedClose = true; self?.window?.performClose(nil) }
        model.chooseDraft = { [weak self] in
            guard let window = self?.window, window.attachedSheet == nil else { return .cancel }
            let alert = NSAlert(); alert.messageText = "Save the edited patched result?"
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
            alert.buttons[0].keyEquivalent = ""; alert.buttons[2].keyEquivalent = "\r"; alert.window.defaultButtonCell = alert.buttons[2].cell as? NSButtonCell
            let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            return response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .cancel
        }
        model.refresh()
    }
    func setQuitConfirmation(_ value: Bool) { model.confirmingQuit = value; model.previewDocument.confirmingQuit = value }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        guard !activeOperation else { return false }
        if model.dirty { model.requestClose(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class WorkingTreePatchWindowModel: ObservableObject {
    enum DraftChoice { case save, discard, cancel }
    let repository: GitRepository
    private let preferences: UserDefaults
    private let access: RepositoryAccessLease?
    private let fileAccess: RepositoryAccessLease?
    private let bytes: Data
    let previewDocument: PatchWindowModel
    @Published private(set) var review: WorkingTreePatchReview?
    @Published private(set) var selected: Set<Int> = []
    @Published private(set) var appliedPaths: Set<Data> = []
    @Published private(set) var busy = false { didSet { updateParentState(); onBusyChanged() } }
    @Published var confirmingQuit = false { didSet { updateParentState() } }
    @Published private(set) var reversed = false
    @Published private(set) var stripCount = 1
    @Published private(set) var comparison: WorkingTreePatchFileComparison?
    @Published private(set) var editor: FileComparisonWindowModel?
    private var editorChanges: AnyCancellable?
    @Published private(set) var draftDecisionPending = false { didSet { updateParentState(); onBusyChanged() } }
    var chooseDraft: () async -> DraftChoice = { .cancel }
    var alignment: FileComparisonAlignment? { editor?.alignment }
    var dirty: Bool { editor?.dirty == true }
    var editingEnabled: Bool { editor?.patchEditingEnabled == true }
    var canReplaceComparison: Bool { editable && !dirty && !editingEnabled }
    var canEditResult: Bool { editable && !requiresRefresh && alignment != nil && editor?.canEdit(base: false) == true }
    var canSaveDraft: Bool { canEditResult && editingEnabled }
    @Published private(set) var focusedFile: Int?
    @Published private(set) var comparisonNotice = ""
    @Published var previewTab = 0
    @Published var difference = -1
    weak var beforeScroll: NSScrollView?
    weak var afterScroll: NSScrollView?
    private var synchronizingScroll = false
    @Published private(set) var requiresRefresh = false
    @Published private(set) var notice = ""
    @Published private(set) var output = ""
    private var selectedReview: WorkingTreePatchReview?
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onBusyChanged: () -> Void = {}
    var parentActive: () -> Bool = { false }
    var editable: Bool { !busy && !confirmingQuit && !draftDecisionPending && !previewDocument.busy && !parentActive() }
    var canApply: Bool { canReplaceComparison && !requiresRefresh && selectedReview?.canApply == true && !selected.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?, fileAccess: RepositoryAccessLease?, bytes: Data, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.fileAccess = fileAccess; self.bytes = bytes; self.preferences = preferences
        previewDocument = PatchWindowModel(repository: repository, access: access, appearancePreferences: preferences)
        previewDocument.setReadOnlyDiff(bytes); previewDocument.refreshAvailable = false
    }
    func setReversed(_ value: Bool) {
        guard canReplaceComparison, value != reversed else { return }
        reversed = value; requiresRefresh = true; selectedReview = nil; comparison = nil; editor = nil; editorChanges = nil; beforeScroll = nil; afterScroll = nil; notice = "Refresh to check the changed options."
    }
    func setStripCount(_ value: Int) {
        guard canReplaceComparison, value != stripCount else { return }
        stripCount = value; requiresRefresh = true; selectedReview = nil; comparison = nil; editor = nil; editorChanges = nil; beforeScroll = nil; afterScroll = nil; notice = "Refresh to check the changed options."
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func refresh() {
        guard canReplaceComparison else { return }; busy = true; selectedReview = nil; appliedPaths = []; comparison = nil; editor = nil; editorChanges = nil; beforeScroll = nil; afterScroll = nil
        let reverse = reversed, strip = stripCount
        Task {
            defer { busy = false }
            do { try checkAccess(); try await load(reverse: reverse, strip: strip) }
            catch { review = nil; selected = []; notice = error.localizedDescription }
        }
    }
    private func load(reverse: Bool, strip: Int) async throws {
        let next = try await repository.reviewWorkingTreePatch(bytes, reversed: reverse, stripCount: strip)
        review = next; requiresRefresh = false
        selected = Set(next.files.filter { !appliedPaths.contains($0.pathBytes) }.map(\.id))
        try await validateSelection()
        await loadComparison()
    }
    private func validateSelection() async throws {
        selectedReview = nil
        guard let review, !selected.isEmpty else { notice = appliedPaths.isEmpty ? "Select files to apply." : "Selected files have been applied."; return }
        let next = try await repository.reviewWorkingTreePatchFiles(review, fileIDs: selected)
        selectedReview = next; notice = next.validationError ?? "Checked files can be applied to the working tree."
    }
    func focusFile(_ id: Int?) {
        guard canReplaceComparison, !requiresRefresh else { return }
        focusedFile = id; busy = true
        Task { defer { busy = false }; await loadComparison() }
    }
    private func loadComparison() async {
        comparison = nil; editor = nil; editorChanges = nil; beforeScroll = nil; afterScroll = nil; comparisonNotice = ""; difference = -1
        guard let review else { focusedFile = nil; return }
        let candidates = review.files.filter { !appliedPaths.contains($0.pathBytes) }
        guard let file = candidates.first(where: { $0.id == focusedFile }) ?? candidates.first else { focusedFile = nil; return }
        focusedFile = file.id
        do {
            try checkAccess()
            let value = try await repository.compareWorkingTreePatchFile(review, fileID: file.id)
            comparison = value
            let nextEditor = FileComparisonWindowModel(patchComparison: value, access: access, preferences: preferences)
            nextEditor.onRegisterScroll = { [weak self] scroll, base in if base { self?.beforeScroll = scroll } else { self?.afterScroll = scroll } }
            editorChanges = nextEditor.objectWillChange.sink { [weak self] in self?.objectWillChange.send(); self?.onBusyChanged() }
            editor = nextEditor; updateParentState()
        } catch { comparisonNotice = error.localizedDescription }
    }
    func synchronizeScroll(from scroll: NSScrollView) {
        guard !synchronizingScroll else { return }
        let other = scroll === beforeScroll ? afterScroll : beforeScroll
        guard let other else { return }
        synchronizingScroll = true; defer { synchronizingScroll = false }
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.minX, y: scroll.contentView.bounds.minY))
        other.reflectScrolledClipView(other.contentView)
    }
    func navigate(_ step: Int) {
        guard editable, let alignment, !alignment.differences.isEmpty else { return }
        difference = min(max(difference + step, 0), alignment.differences.count - 1)
        let row = alignment.differences[difference].lowerBound
        for (scroll, base) in [(beforeScroll, true), (afterScroll, false)] {
            guard let text = scroll?.documentView as? NSTextView else { continue }
            let cells = alignment.rows.map { base ? $0.base : $0.destination }
            let offset = cells.prefix(row).reduce(0) { $0 + ($1.displayText as NSString).length + 1 }
            text.setSelectedRange(NSRange(location: min(offset, (text.string as NSString).length), length: 0))
            text.scrollRangeToVisible(text.selectedRange())
        }
    }
    func findComparison() {
        guard let view = afterScroll?.documentView as? NSTextView else { return }
        view.window?.makeFirstResponder(view)
        let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(sender)
    }
    func updateParentState() {
        editor?.busy = busy
        editor?.confirmingQuit = confirmingQuit || draftDecisionPending || parentActive()
        objectWillChange.send()
    }
    func setEditing(_ value: Bool) {
        guard canEditResult, !dirty else { return }
        editor?.setPatchEditing(value)
    }
    func discardDraft() {
        guard editable else { return }
        resetComparisonDraft()
    }
    private func resetComparisonDraft() {
        guard let comparison else { return }
        editor?.resetHistory(); beforeScroll = nil; afterScroll = nil
        let next = FileComparisonWindowModel(patchComparison: comparison, access: access, preferences: preferences)
        next.onRegisterScroll = { [weak self] scroll, base in if base { self?.beforeScroll = scroll } else { self?.afterScroll = scroll } }
        editorChanges = next.objectWillChange.sink { [weak self] in self?.objectWillChange.send(); self?.onBusyChanged() }
        editor = next; updateParentState(); onBusyChanged()
    }
    func saveDraft() {
        guard canSaveDraft else { return }
        busy = true
        Task { _ = await performSave(alreadyBusy: true) }
    }
    private func performSave(alreadyBusy: Bool = false) async -> Bool {
        guard (alreadyBusy ? busy : !busy), let comparison, let editor, editor.canEdit(base: false) else { return false }
        let text = editor.draftText(base: false), encoding = editor.encoding(base: false)
        let autoAdd = MergeEditorPreferences.load(from: preferences).autoAdd
        busy = true; defer { busy = false }
        do {
            try checkAccess()
            let saved = try await repository.saveWorkingTreePatchFile(comparison, text: text, encoding: encoding, autoAddNewFiles: autoAdd)
            appliedPaths.insert(Data(comparison.document.destination.path.utf8)); output += saved.output
            editor.resetHistory(); self.editor = nil; onChanged(output)
            try await load(reverse: reversed, strip: stripCount)
            if let failure = saved.addError { notice = "Saved patched result, but Add failed: " + failure; output += notice + "\n"; return false }
            return true
        } catch { notice = error.localizedDescription; output += notice + "\n"; return false }
    }
    func resolveDraft(discardImmediately: Bool = true) async -> Bool {
        guard dirty else { return true }
        guard !busy, !draftDecisionPending else { return false }
        draftDecisionPending = true; defer { draftDecisionPending = false }
        switch await chooseDraft() {
        case .cancel: return false
        case .save: return await performSave()
        case .discard:
            if discardImmediately { resetComparisonDraft() }
            return true
        }
    }
    func requestClose() { Task { if await resolveDraft() { close() } } }
    func check(_ id: Int, _ value: Bool) {
        guard canReplaceComparison, !requiresRefresh, let file = review?.files.first(where: { $0.id == id }), !appliedPaths.contains(file.pathBytes) else { return }
        if value { selected.insert(id) } else { selected.remove(id) }
        busy = true; selectedReview = nil
        Task { defer { busy = false }; do { try checkAccess(); try await validateSelection() } catch { notice = error.localizedDescription } }
    }
    func apply() {
        guard canApply, let selection = selectedReview else { return }; busy = true; selectedReview = nil
        let reverse = reversed, strip = stripCount
        Task {
            defer { busy = false }
            do {
                try checkAccess()
                let result = try await repository.applyWorkingTreePatch(selection)
                appliedPaths.formUnion(selection.files.map(\.pathBytes)); output += result + "\nApplied \(selection.files.count) file(s).\n"
                onChanged(output)
                try await load(reverse: reverse, strip: strip)
            } catch { notice = error.localizedDescription; output += "\n" + notice + "\n" }
        }
    }
}

struct WorkingTreePatchDialog: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.repository.root.path).lineLimit(1).help(model.repository.root.path)
                Spacer(); Toggle("Reverse patch", isOn: Binding(get: { model.reversed }, set: { model.setReversed($0) }))
                Text("Strip paths:"); TextField("Strip paths", value: Binding(get: { model.stripCount }, set: { model.setStripCount($0) }), formatter: NumberFormatter()).frame(width: 45)
                Button("Refresh") { model.refresh() }
            }.disabled(!model.canReplaceComparison)
            HSplitView {
                VStack(alignment: .leading) {
                    Text("Files to patch:")
                    Table(model.review?.files ?? [], selection: Binding(get: { model.focusedFile }, set: { model.focusFile($0) })) {
                        TableColumn("") { file in
                            Toggle(file.path, isOn: Binding(get: { model.selected.contains(file.id) }, set: { model.check(file.id, $0) })).labelsHidden().disabled(!model.canReplaceComparison || model.requiresRefresh || model.appliedPaths.contains(file.pathBytes))
                        }.width(26)
                        TableColumn("Path") { file in Text(file.path).help(file.path) }
                        TableColumn("Changes") { file in
                            Text(model.appliedPaths.contains(file.pathBytes) ? "Applied" : file.isBinary ? "Binary" : "+\(file.additions ?? 0) −\(file.deletions ?? 0)")
                                .foregroundStyle(model.appliedPaths.contains(file.pathBytes) ? Color.green : .secondary)
                        }.width(80)
                    }
                }.frame(minWidth: 280, idealWidth: 350)
                TabView(selection: $model.previewTab) {
                    WorkingTreePatchComparisonView(model: model).tabItem { Text("Compare") }.tag(0)
                    VStack(alignment: .leading) { Text("Original patch:"); PatchTextView(model: model.previewDocument) }.tabItem { Text("Original patch") }.tag(1)
                }.frame(minWidth: 440)
            }
            Text(model.notice).foregroundStyle(model.canApply ? Color.secondary : Color.orange).textSelection(.enabled)
            if !model.output.isEmpty { DisclosureGroup("Output") { OutputView(text: model.output, usesLogFont: true).frame(height: 100) } }
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text("Checking patch…") }
                Text("Only checked files will be applied.").foregroundStyle(.secondary)
                Spacer(); Button("Apply selected") { model.apply() }.disabled(!model.canApply)
                Button("Close") { model.requestClose() }.disabled(!model.editable)
            }
        }.padding(16)
    }
}

struct WorkingTreePatchComparisonView: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    private func pane(base: Bool) -> some View {
        let content = base ? model.comparison?.document.base : model.comparison?.document.destination
        return VStack(alignment: .leading, spacing: 5) {
            Text(base ? "Before patch" : "After patch").font(.headline)
            if let content {
                Text(content.path).font(.caption).lineLimit(1).help(content.path)
                if let alignment = model.alignment {
                    WorkingTreePatchComparisonEditor(model: model, cells: alignment.rows.map { base ? $0.base : $0.destination }, base: base)
                } else {
                    ScrollView {
                        Text("Binary or unsupported text encoding · \(content.bytes.count) bytes\n" + content.bytes.prefix(4096).enumerated().map { ($0.offset % 16 == 0 ? "\n" : " ") + String(format: "%02X", $0.element) }.joined())
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("\(content.mode ?? "Absent") · \(content.bytes.count) bytes").font(.caption).foregroundStyle(.secondary)
            } else { Color(nsColor: .textBackgroundColor) }
        }.padding(6).frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
    }
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button { model.navigate(-1) } label: { Image(nsImage: MenuIcon.mergePreviousConflict.image() ?? NSImage()) }.help("Previous difference").accessibilityLabel("Previous difference").disabled(model.difference <= 0)
                Button { model.navigate(1) } label: { Image(nsImage: MenuIcon.mergeNextConflict.image() ?? NSImage()) }.help("Next difference").accessibilityLabel("Next difference").disabled(model.alignment?.differences.isEmpty != false || model.difference >= (model.alignment?.differences.count ?? 0) - 1)
                Button { model.findComparison() } label: { CommandLabel(title: "Find", icon: .mergeFind) }.disabled(model.alignment == nil)
                Button { model.saveDraft() } label: { CommandLabel(title: "Save patched result", icon: .mergeSave) }.disabled(!model.canSaveDraft)
                Button("Discard edits") { model.discardDraft() }.disabled(!model.editingEnabled)
                Spacer()
                Toggle("Edit patched result", isOn: Binding(get: { model.editingEnabled }, set: { model.setEditing($0) })).disabled(!model.canEditResult || model.dirty)
            }.disabled(!model.editable)
            HSplitView { pane(base: true); pane(base: false) }
            if model.requiresRefresh { Text("Refresh to compare the changed options.").foregroundStyle(.orange) }
            else if !model.comparisonNotice.isEmpty { Text(model.comparisonNotice).foregroundStyle(.orange).textSelection(.enabled) }
            else if model.comparison == nil { Text("Select a file to compare.").foregroundStyle(.secondary) }
        }.padding(6)
    }
}

struct WorkingTreePatchComparisonEditor: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    let cells: [MergeSourceCell]
    let base: Bool
    var body: some View {
        if let editor = model.editor { WorkingTreePatchPreparedEditor(editor: editor, base: base).id(ObjectIdentifier(editor)) }
    }
}
private struct WorkingTreePatchPreparedEditor: View {
    @ObservedObject var editor: FileComparisonWindowModel
    let base: Bool
    var body: some View {
        VStack(alignment: .leading) {
            FileComparisonEditor(model: editor, cells: editor.alignment?.rows.map { base ? $0.base : $0.destination } ?? [], base: base)
            MergeFormatControls(label: base ? "Before" : "After", encoding: editor.encoding(base: base), text: editor.document == nil ? nil : editor.draftText(base: base), editable: editor.canTransfer(toBase: base), changeEncoding: { editor.changeEncoding($0, base: base) }, changeEnding: { editor.changeLineEnding($0, base: base) })
            if let error = editor.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }
    }
}
