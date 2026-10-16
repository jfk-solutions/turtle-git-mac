// Adapts TortoiseGit's ImportPatchDlg controls and git-am workflow (see NOTICE).
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class ImportPatchWindowController: NSWindowController, NSWindowDelegate {
    let model: ImportPatchWindowModel
    var onClosed: () -> Void = {}
    private var approvedClose = false
    private var patch: PatchWindowController?
    private var review: WorkingTreePatchWindowController?
    private var sendPatch: SendMailWorkflow?
    var activeOperation: Bool { model.confirmingQuit || model.receivingDrop || model.busy || model.closing || model.openingViewer || model.composingMail || window?.attachedSheet != nil || patch?.model.busy == true || patch?.window?.attachedSheet != nil || review?.activeOperation == true }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, mailPresentation: ((NSWindowController) -> Void)? = nil) {
        model = ImportPatchWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Apply Patch Serial", preferences: preferences)
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
            controller.model.onMutationStopped = { [weak self] in self?.model.onMutationStopped() }
            controller.model.onBusyChanged = { [weak self] in self?.model.objectWillChange.send() }
            controller.onClosed = { [weak self, weak controller] in if self?.review === controller { self?.review = nil; self?.model.objectWillChange.send() } }
            self.review = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
        model.chooseFiles = { [weak self] in self?.chooseFiles() }
        model.showPatch = { [weak self] bytes, title, alternate in
            guard let self else { return }
            if try await UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: preferences, title: title, permissions: access.map { [$0] } ?? []) { return }
            self.patch = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: self.patch, title: title, onClosed: { [weak self] in self?.patch = nil })
        }
        model.composeMail = { [weak self] files, completion in
            guard let self else { completion("The patch window was closed."); return }
            do {
                let leases = self.model.items.filter { files.contains($0.file) }.map(\.access) + [access].compactMap { $0 }
                let workflow = SendMailWorkflow(files: files, repository: repository, access: access,
                    fileAccess: leases, preferences: preferences, presentation: mailPresentation) { [weak self] _ in
                    self?.sendPatch = nil; completion(nil)
                }
                self.sendPatch = workflow; workflow.start(); return
            }

        }
        model.configureIdentity = { [weak self] in
            guard let self else { return false }
            guard await self.prompt("Git identity is incomplete", "A user name and email are required before importing commits. Configure them now?", buttons: ["Configure…", "Cancel"]) == 0 else { return false }
            guard !self.model.closed else { return false }
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
        model.close = { [weak self] in
            guard let self, let window = self.window else { return }
            self.approvedClose = true
            if let parent = window.sheetParent {
                parent.endSheet(window)
                window.close()
            } else { window.performClose(nil) }
        }
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
        guard !model.closed, let window, window.attachedSheet == nil else { return false }
        let request = model.activeCancellation
        let name = NSTextField(string: try await model.repository.run(["config", "--get", "user.name"], successfulExitCodes: 0...1, cancellation: request).text.trimmingCharacters(in: .newlines))
        let email = NSTextField(string: try await model.repository.run(["config", "--get", "user.email"], successfulExitCodes: 0...1, cancellation: request).text.trimmingCharacters(in: .newlines))
        guard !model.closed, request?.isCancelled != true else { return false }
        let scope = NSPopUpButton(); scope.addItems(withTitles: ["This repository", "Global"])
        let form = NSGridView(views: [[NSTextField(labelWithString: "Name:"), name], [NSTextField(labelWithString: "Email:"), email], [NSTextField(labelWithString: "Save in:"), scope]])
        form.frame = NSRect(x: 0, y: 0, width: 360, height: 92); form.column(at: 1).width = 270
        name.setAccessibilityLabel("Git user name"); email.setAccessibilityLabel("Git user email"); scope.setAccessibilityLabel("Git configuration scope")
        let alert = NSAlert(); alert.messageText = "Git identity"; alert.informativeText = "Set user.name and user.email. Existing author/committer overrides remain in effect."
        alert.accessoryView = form; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"; alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        guard !model.closed, request?.isCancelled != true, response == .alertFirstButtonReturn else { return false }
        let userName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), userEmail = email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userName.isEmpty, !userEmail.isEmpty, !userName.contains("\0"), !userEmail.contains("\0"), !userName.contains("\n"), !userEmail.contains("\n") else { throw NSError(domain: "TurtleGit.GitIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a nonempty Git name and email without line breaks."]) }
        let option = scope.indexOfSelectedItem == 0 ? "--local" : "--global"
        _ = try await model.repository.run(["config", option, "user.name", userName], cancellation: request)
        _ = try await model.repository.run(["config", option, "user.email", userEmail], cancellation: request)
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
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
        if let window { window.sheetParent?.endSheet(window) }
        patch?.close(); review?.close(); onClosed()
    }
    func setQuitConfirmation(_ value: Bool) {
        model.confirmingQuit = value; review?.setQuitConfirmation(value)
    }
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
    private var operation: OperationCancellation?
    var activeCancellation: OperationCancellation? { operation }
    var closed: Bool { invalidated }
    private(set) var accepted = false
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
    var onMutationStopped: () -> Void = {}
    var finished: Bool { !items.isEmpty && items.allSatisfy { $0.state == .success || $0.state == .skipped } }
    var editable: Bool { !confirmingQuit && !receivingDrop && !busy && !closing && !openingViewer && !composingMail && !invalidated && !childActive() }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access
        previewDocument = PatchWindowModel(repository: repository, access: access, appearancePreferences: preferences)
        previewDocument.setReadOnlyDiff(Data()); previewDocument.refreshAvailable = false
    }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; operation?.cancel(); operation = nil
        close = {}; onChanged = { _ in }; onStateChanged = {}
        previewGeneration = UUID(); items = []; selection = []
        busy = false; closing = false; receivingDrop = false; openingViewer = false; composingMail = false
    }
    private func live(_ request: OperationCancellation) -> Bool { !invalidated && operation === request && !request.isCancelled }
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
                guard !invalidated else { return }
                try await showPatch(bytes, item.file.lastPathComponent, alternate)
            } catch { if !invalidated { self.error = error.localizedDescription } }
        }
    }
    func reviewPatch(_ ids: Set<UUID>) {
        guard editable, contextActions(ids).contains(.reviewPatch), let item = items.first(where: { ids.contains($0.id) }) else { return }
        openingViewer = true
        Task {
            defer { openingViewer = false }
            do {
                let bytes = try await Task.detached { try Data(contentsOf: item.file) }.value
                guard !invalidated else { return }
                try showReview(bytes, item.file.lastPathComponent, item.access)
            } catch { if !invalidated { self.error = error.localizedDescription } }
        }
    }
    func sendMail(_ ids: Set<UUID>) {
        guard editable, contextActions(ids).contains(.sendMail) else { return }
        let selected = items.filter { ids.contains($0.id) }
        composingMail = true
        composeMail(selected.map(\.file)) { [weak self] error in
            // Capture the leases until macOS finishes composing or reports failure.
            _ = selected
            guard let self, !self.invalidated else { return }
            self.composingMail = false
            if let error { self.error = error }
        }
    }
    func add(_ urls: [URL], retaining grants: [RepositoryAccessLease] = []) {
        guard editable else { return }
        for url in urls {
            guard url.isFileURL else { error = MailPatchFailure.file.localizedDescription; continue }
            let lease = grants.first { $0.contains(url) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) } ?? RepositoryAccessLease(url: url)
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
        if finished { requestClose(accepted: true); return }
        guard !items.isEmpty else { return }
        let batch = items, flags = options
        let request = OperationCancellation(); operation = request
        busy = true; stopRequested = false; error = nil; tab = 1
        Task {
            defer { if operation === request { operation = nil; busy = false; if !invalidated { onChanged(output) } } }
            do {
                try checkAccess()
                guard try await ensureIdentity(request) else { guard !invalidated else { return }; output += "\nImport cancelled before applying patches.\n"; return }
                guard live(request) else { return }
                try await recoverSession(request)
                for item in batch {
                    guard live(request) else { return }
                    guard !stopRequested else { output += "\nBatch stopped after the current Git command.\n"; break }
                    guard let current = items.first(where: { $0.id == item.id }), current.state != .success, current.state != .skipped else { continue }
                    guard current.checked else { state(item.id, .skipped); output += "\nSkipped: \(item.file.path)\n"; continue }
                    state(item.id, .applying); output += "\nApplying: \(item.file.path)\n"
                    do {
                        let result = try await repository.importMailPatch(item.file, options: flags, cancellation: request)
                        guard live(request) else { return }
                        output += result + "\nSuccess\n"; state(item.id, .success)
                    } catch {
                        guard live(request) else { return }
                        state(item.id, .failed); failedRow = item.id; throw error
                    }
                    onChanged(output)
                }
            } catch {
                guard live(request) else { return }
                output += "\n" + error.localizedDescription + "\n"; self.error = error.localizedDescription
            }
        }
    }
    private func ensureIdentity(_ request: OperationCancellation) async throws -> Bool {
        while true {
            guard live(request) else { throw OperationCancellationFailure.cancelled }
            let environment = ProcessInfo.processInfo.environment
            func configured(_ key: String) async throws -> String {
                try await repository.run(["config", "--get", key], successfulExitCodes: 0...1, cancellation: request).text.trimmingCharacters(in: .newlines)
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
                _ = try await repository.run(["var", "GIT_AUTHOR_IDENT"], cancellation: request)
                _ = try await repository.run(["var", "GIT_COMMITTER_IDENT"], cancellation: request)
                return live(request) && !stopRequested
            }
            guard live(request), !stopRequested, try await configureIdentity() else { return false }
        }
    }
    private func recoverSession(_ request: OperationCancellation) async throws {
        var session = try await repository.mailPatchSession(cancellation: request)
        while session == .applying {
            guard live(request), !stopRequested, let action = await chooseRecovery() else { if !invalidated { stopRequested = true }; return }
            guard live(request) else { return }
            output += "\ngit am --\(action.rawValue)\n"
            let result = try await repository.recoverMailPatch(action, cancellation: request)
            guard live(request) else { return }
            output += result
            session = try await repository.mailPatchSession(cancellation: request)
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
    func requestClose(accepted: Bool = false) {
        if busy { requestStop(); return }
        guard editable else { return }
        let request = OperationCancellation(); operation = request; closing = true
        Task {
            defer { if operation === request { operation = nil; closing = false } }
            if await confirmCloseState(request), live(request) { self.accepted = accepted && finished; close() }
        }
    }
    /// Quit uses the same session choices without closing windows before every
    /// other document has approved termination.
    func confirmQuit() async -> Bool {
        guard !busy, !closing, !receivingDrop, !openingViewer, !composingMail, !invalidated else { return false }
        let request = OperationCancellation(); operation = request; closing = true
        defer { if operation === request { operation = nil; closing = false } }
        return await confirmCloseState(request) && live(request)
    }
    private func confirmCloseState(_ request: OperationCancellation) async -> Bool {
        let session: MailPatchSession
        do {
            try checkAccess()
            session = try await repository.mailPatchSession(cancellation: request)
            guard live(request) else { return false }
        } catch {
            guard live(request) else { return false }
            // Unknown state may only be kept, never automatically aborted.
            let answer = await chooseUnavailableClose(error.localizedDescription)
            return live(request) && answer
        }
        do {
            if session == .applying {
                let answer = await chooseClose(); guard live(request) else { return false }
                switch answer {
                case .cancel: return false
                case .keep: break
                case .abort:
                    let result = try await repository.recoverMailPatch(.abort, cancellation: request)
                    guard live(request) else { return false }
                    output += result; onChanged(output)
                }
            }
            return live(request)
        } catch { if live(request) { self.error = error.localizedDescription }; return false }
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
                Button("Help") { TurtleGitHelp.show(.patches) }
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

@MainActor final class WorkingTreePatchWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let editorFileMenu = MergeEditorFileMenu()
    var editorCommandMenu: MergeEditorCommandMenu?
    var editorToolbar:MergeEditorToolbar?
    var commandsAvailable:Bool { !retired && !preparingReplacement && editorOpenWorkflow == nil }
    var editorOpenWorkflow: MergeEditorOpenWorkflow?
    var replacementOwner: MergeEditorReplacementOwner?
    weak var sharedReplacementOwner: MergeEditorReplacementOwner?
    var preparingReplacement: Bool { (sharedReplacementOwner ?? replacementOwner)?.preparingPatch == true }
    func windowDidBecomeKey(_ notification: Notification) { editorFileMenu.remove();editorCommandMenu?.install() }
    func windowDidResignKey(_ notification: Notification) { editorCommandMenu?.remove();editorFileMenu.remove() }
    func detachForReplacement() { editorToolbar?.retire();editorCommandMenu?.retire();editorFileMenu.remove(); model.retire(); model.window = nil }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { !retired && !activeOperation && !preparingReplacement && (item.action == #selector(openMergeDocument(_:)) || item.action == #selector(reloadEditor(_:))) }
    @objc func reloadEditor(_ sender: Any?) {
        guard !activeOperation, !preparingReplacement else { return }
        Task { if await model.resolveDraft() { model.refresh() } }
    }
    @objc func openMergeDocument(_ sender: Any?) {
        guard !retired, !activeOperation, !preparingReplacement, let window else { return }
        let workflow = MergeEditorOpenWorkflow(window: window, permissions: model.openPermissions, preferences: model.openPreferences)
        editorOpenWorkflow = workflow
        workflow.onClosed = { [weak self] in self?.editorOpenWorkflow = nil }
        workflow.accept = { [weak self] request, permissions in
            guard let self, let window = self.window, !self.model.busy, !self.model.confirmingQuit else { throw OperationCancellationFailure.cancelled }
            let owner = self.sharedReplacementOwner ?? self.replacementOwner ?? MergeEditorReplacementOwner(onClosed: self.onClosed)
            if self.sharedReplacementOwner == nil { self.replacementOwner = owner }
            try owner.replace(request, permissions: permissions, preferences: self.model.openPreferences, window: window, previous: self)
        }
        workflow.start(dirty: model.dirty, description: window.title, save: { [weak self] completion in
            guard let self else { completion(false); return }; self.model.saveDraft(completion: completion)
        })
    }
    let model: WorkingTreePatchWindowModel
    var onClosed: () -> Void = {}
    private var approvedClose = false
    private var retired = false
    var activeOperation: Bool { editorOpenWorkflow != nil || model.busy || model.confirmingQuit || model.draftDecisionPending || model.previewDocument.busy || model.editor?.hasPendingEditorChoice == true || model.editor?.busy == true || model.conflictOperationActive || window?.attachedSheet != nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, fileAccess: RepositoryAccessLease?, bytes: Data, title: String, preferences: UserDefaults = .standard, directoryMode: Bool = false, isGitWorkingTree: Bool = true, initialStripCount: Int = 1, automaticallyRefresh: Bool = true) {
        model = WorkingTreePatchWindowModel(repository: repository, access: access, fileAccess: fileAccess, bytes: bytes, preferences: preferences, directoryMode: directoryMode, isGitWorkingTree: isGitWorkingTree, initialStripCount: initialStripCount)
        let window = TextConflictNSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) – Review Patch – TurtleGitMerge"; window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: WorkingTreePatchDialog(model: model)); host.sizingOptions = []
        window.contentViewController = host
        super.init(window: window); window.delegate = self; window.patchModel = model; window.openMergeDocument = { [weak self] in self?.openMergeDocument(nil) }; model.window = window
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
        model.onConflictEditorChanged = { [weak self] conflict in
            guard let self else {return}
            self.editorToolbar?.retire();self.editorToolbar = nil
            if let conflict,let window = self.window {
                self.editorToolbar = MergeEditorToolbar.conflict(model:conflict,window:window,ownerReady:{ [weak self] in self?.commandsAvailable == true },open:{ [weak self] in self?.openMergeDocument(nil) },reload:{ [weak self] in self?.reloadEditor(nil) },help:{TurtleGitHelp.show(.patches)})
            }
            self.editorCommandMenu?.remove()
            if self.window?.isKeyWindow == true {self.editorCommandMenu?.install()}
        }
        editorCommandMenu = MergeEditorCommandMenu.patchReview(self)
        if automaticallyRefresh { model.refresh() }
    }
    func setQuitConfirmation(_ value: Bool) { model.confirmingQuit = value; model.previewDocument.confirmingQuit = value }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !preparingReplacement else { return false }
        if approvedClose { return true }
        guard !activeOperation else { return false }
        if model.dirty { model.requestClose(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true; editorToolbar?.retire();editorCommandMenu?.retire();editorFileMenu.remove(); editorOpenWorkflow?.retire(); editorOpenWorkflow = nil; model.retire()
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class WorkingTreePatchWindowModel: ObservableObject {
    static private(set) var activeOperations = 0
    private(set) var retired = false
    private var operation: OperationCancellation?
    private var specialQuestion:NSAlert?
    var chooseSpecialResolution:((WorkingTreePatchResolutionChoice,WorkingTreePatchFileComparison) async -> Bool)?
    @Published private(set) var keptCurrentPaths:Set<Data> = []
    @Published private(set) var specialSavedResult:WorkingTreePatchSaveResult?
    @Published private(set) var specialResolutionChoice:WorkingTreePatchResolutionChoice?
    var specialComparison:WorkingTreePatchFileComparison? {
        guard let comparison,comparison.requiresMerge,comparison.recoveryKind != .text else {return nil}
        return comparison
    }
    var canResolveSpecial:Bool {editable && !requiresRefresh && specialComparison.map {!appliedPaths.contains(Data($0.document.destination.path.utf8))} == true}
    enum DraftChoice { case save, discard, cancel }
    let repository: GitRepository
    let directoryMode: Bool
    let isGitWorkingTree: Bool
    var openPreferences: UserDefaults { preferences }
    var openPermissions: [RepositoryAccessLease] { [access, fileAccess].compactMap { $0 } + (editor?.openPermissions ?? []) + (conflictEditor?.openPermissions ?? []) }
    private let preferences: UserDefaults
    private let access: RepositoryAccessLease?
    private let fileAccess: RepositoryAccessLease?
    private let bytes: Data
    let previewDocument: PatchWindowModel
    @Published private(set) var review: WorkingTreePatchReview?
    @Published private(set) var selected: Set<Int> = []
    @Published private(set) var appliedPaths: Set<Data> = []
    @Published private(set) var fileResults: [Data: WorkingTreePatchFileResult] = [:]
    @Published private(set) var fileInspections:[Data:WorkingTreePatchFileInspection] = [:]
    var onConflictEditorChanged:(TextConflictWindowModel?)->Void = {_ in}
    @Published private(set) var conflictEditor:TextConflictWindowModel? {didSet {onConflictEditorChanged(conflictEditor)}}
    private var conflictChanges:AnyCancellable?
    var conflictOperationActive:Bool {conflictEditor.map {$0.busy || $0.preparing || $0.formatPending || $0.exportingSource} == true}
    @Published private(set) var highlightedFiles = Set<Int>()
    private(set) var fileListGeneration = UUID()
    private var comparisonRead = false
    var canPatchFiles: Bool { canReplaceComparison && !requiresRefresh && review?.files.contains(where: { !appliedPaths.contains($0.pathBytes) }) == true }
    @Published private(set) var fileListVisible = true
    var canToggleFileList:Bool { !retired && review?.files.isEmpty == false && !confirmingQuit && !draftDecisionPending && window?.attachedSheet == nil }
    func toggleFileList() {
        guard canToggleFileList else {return}
        fileListVisible.toggle()
        if !fileListVisible,let table = window?.firstResponder as? NSTableView,table.identifier?.rawValue == "TurtleGit.Patch.Files",let destination = afterScroll?.documentView {
            window?.makeFirstResponder(destination)
        }
    }
    var canHighlightFiles:Bool { !retired && !conflictOperationActive && editor?.hasPendingEditorChoice != true && (!busy || comparisonRead) && !dirty && !editingEnabled && !confirmingQuit && !draftDecisionPending && !requiresRefresh }
    func highlightFiles(_ ids: Set<Int>) {
        guard canHighlightFiles,let review else {return}
        // Source LVN_ITEMCHANGED changes selection only; preview is explicit.
        highlightedFiles = ids.intersection(Set(review.files.map(\.id)))
    }
    func canPreviewFiles(_ ids:Set<Int>,generation:UUID) -> Bool {
        generation == fileListGeneration && canReplaceComparison && !requiresRefresh && ids.count == 1 && review?.files.contains(where:{ ids.contains($0.id) && !appliedPaths.contains($0.pathBytes) }) == true
    }
    func previewFiles(_ ids:Set<Int>,generation:UUID) {
        guard canPreviewFiles(ids,generation:generation) else {return}
        focusFile(ids.first)
    }
    func fileState(_ file:WorkingTreePatchReview.File) -> String {
        if keptCurrentPaths.contains(file.pathBytes) {return "kept current"}
        if appliedPaths.contains(file.pathBytes) {return "patched"}
        if let result = fileResults[file.pathBytes],!result.success {return result.requiresMerge ? "conflict" : "error"}
        switch fileInspections[file.pathBytes]?.state {case .error:return "error";case .conflict:return "conflict";default:return ""}
    }
    func patchFiles(_ ids: Set<Int>, generation: UUID) {
        guard generation == fileListGeneration, canPatchFiles, let review else { return }
        let targets = Set(review.files.filter { ids.contains($0.id) && !appliedPaths.contains($0.pathBytes) }.map(\.id))
        guard !targets.isEmpty, let token = begin() else { return }
        selectedReview = nil
        let reverse = reversed, strip = stripCount
        Task { [self] in
            defer { finish(token) }
            var reported = false
            do {
                try checkAccess()
                var engine = try? SubversionMergeConfiguration.bundled();engine?.options = .load(from:preferences)
                let batch = try await repository.applyWorkingTreePatchBatch(review, fileIDs: targets, mergeConfiguration:engine, cancellation: token) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, !self.retired, self.operation === token else { return }
                        self.fileResults[result.pathBytes] = result
                        if result.success { self.appliedPaths.insert(result.pathBytes) }
                    }
                }
                let report = batch.files.map { ( $0.success ? "Patched: " : "Error: " ) + String(decoding: $0.pathBytes, as: UTF8.self) + "\n" + $0.output }.joined(separator: "\n")
                // Notify the repository owner even if the window was closed after
                // a file changed; UI publications still require the live token.
                if batch.files.contains(where: \.success) { onChanged(report) } else { onMutationStopped() }
                reported = true
                guard !retired, operation === token else { return }
                for result in batch.files { fileResults[result.pathBytes] = result; if result.success { appliedPaths.insert(result.pathBytes) } }
                output += "\n" + report + "\n"
                try ensure(token)
                try await load(reverse: reverse, strip: strip, token: token)
            } catch {
                if !reported { onMutationStopped() }
                if !retired && !token.isCancelled { notice = error.localizedDescription }
            }
        }
    }
    @Published private(set) var busy = false { didSet { updateParentState(); onBusyChanged() } }
    @Published var confirmingQuit = false { didSet { updateParentState() } }
    @Published private(set) var reversed = false
    @Published private(set) var stripCount = 1
    @Published private(set) var comparison: WorkingTreePatchFileComparison?
    @Published private(set) var editor: FileComparisonWindowModel?
    private var editorChanges: AnyCancellable?
    @Published private(set) var draftDecisionPending = false { didSet { updateParentState(); onBusyChanged() } }
    var chooseDraft: () async -> DraftChoice = { .cancel }
    weak var window: NSWindow? { didSet { editor?.window = window;conflictEditor?.window = window } }
    var alignment: FileComparisonAlignment? { editor?.alignment }
    var dirty: Bool { conflictEditor?.dirty == true || editor?.dirty == true }
    var editingEnabled: Bool { editor?.patchEditingEnabled == true }
    var canReplaceComparison: Bool { editable && !dirty && !editingEnabled }
    var canEditResult: Bool { editable && !requiresRefresh && (editor?.savedPaneURL(base: false) != nil || comparison.map({ !appliedPaths.contains(Data($0.document.destination.path.utf8)) }) == true) && alignment != nil && editor?.canEdit(base: false) == true }
    var canSaveDraft: Bool { conflictEditor.map {editable && !$0.patchResultCompleted && $0.document != nil} ?? (canEditResult && editingEnabled) }
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
    var onMutationStopped: () -> Void = {}
    var onBusyChanged: () -> Void = {}
    var parentActive: () -> Bool = { false }
    var editable: Bool { !retired && !busy && !conflictOperationActive && editor?.busy != true && editor?.hasPendingEditorChoice != true && !confirmingQuit && !draftDecisionPending && !previewDocument.busy && !parentActive() }
    private func begin() -> OperationCancellation? {
        guard !retired, !busy else { return nil }
        let token = OperationCancellation(); operation = token; busy = true; Self.activeOperations += 1
        return token
    }
    private func finish(_ token: OperationCancellation) {
        Self.activeOperations -= 1
        if operation === token {
            operation = nil; busy = false
            if !retired && token.isCancelled {
                if editor?.dirty == true { notice = "Operation canceled. Draft retained; retry Save, or discard edits and refresh." }
                else { requiresRefresh = true; notice = "Operation canceled. Refresh to check current files." }
            }
            if !retired, !token.isCancelled, !requiresRefresh, highlightedFiles.count == 1,
               let wanted = review?.files.first(where: { highlightedFiles.contains($0.id) && !appliedPaths.contains($0.pathBytes) }), wanted.id != focusedFile {
                focusFile(wanted.id)
            }
        }
    }
    private func ensure(_ token: OperationCancellation) throws {
        guard !retired, operation === token, !token.isCancelled else { throw OperationCancellationFailure.cancelled }
    }
    func cancelOperation() {operation?.cancel();dismissSpecialQuestion();editor?.cancelOutput();editor?.cancelPaneSave();conflictEditor?.cancelPatchOperation()}
    private func dismissSpecialQuestion() {
        guard let question = specialQuestion else {return};specialQuestion = nil
        if let window,question.window.sheetParent === window {window.endSheet(question.window,returnCode:.alertFirstButtonReturn)}
        question.window.orderOut(nil)
    }
    func retire() {
        guard !retired else { return }; retired = true; operation?.cancel();dismissSpecialQuestion()
        fileListGeneration = UUID()
        previewDocument.retire(); editor?.retireImageLoader(); editorChanges = nil;conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil
        beforeScroll = nil; afterScroll = nil; close = {}; chooseDraft = { .cancel }; onBusyChanged = {}
    }
    var canApply: Bool { canReplaceComparison && !requiresRefresh && selectedReview?.canApply == true && !selected.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?, fileAccess: RepositoryAccessLease?, bytes: Data, preferences: UserDefaults = .standard, directoryMode: Bool = false, isGitWorkingTree: Bool = true, initialStripCount: Int = 1) {
        self._stripCount = Published(initialValue: initialStripCount)
        self.directoryMode = directoryMode; self.isGitWorkingTree = isGitWorkingTree
        self.repository = repository; self.access = access; self.fileAccess = fileAccess; self.bytes = bytes; self.preferences = preferences
        previewDocument = PatchWindowModel(repository: repository, access: access, appearancePreferences: preferences)
        previewDocument.setReadOnlyDiff(bytes); previewDocument.refreshAvailable = false
    }
    func setReversed(_ value: Bool) {
        guard canReplaceComparison, value != reversed else { return }
        reversed = value; requiresRefresh = true; selectedReview = nil; comparison = nil; editor?.retireImageLoader(); editor = nil; editorChanges = nil; conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil; beforeScroll = nil; afterScroll = nil; notice = "Refresh to check the changed options."
    }
    func setStripCount(_ value: Int) {
        guard canReplaceComparison, value != stripCount else { return }
        stripCount = value; requiresRefresh = true; selectedReview = nil; comparison = nil; editor?.retireImageLoader(); editor = nil; editorChanges = nil; conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil; beforeScroll = nil; afterScroll = nil; notice = "Refresh to check the changed options."
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func refresh(completion: (() -> Void)? = nil) {
        guard canReplaceComparison, let token = begin() else { completion?(); return }; selectedReview = nil; appliedPaths = []; keptCurrentPaths = []; comparison = nil; editor?.retireImageLoader(); editor = nil; editorChanges = nil; conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil; beforeScroll = nil; afterScroll = nil
        fileResults = [:];fileInspections = [:]
        let reverse = reversed, strip = stripCount
        Task {
            defer { finish(token); completion?() }
            do { try checkAccess(); try await load(reverse: reverse, strip: strip, token: token) }
            catch { if !retired && !token.isCancelled { review = nil; selected = []; notice = error.localizedDescription } }
        }
    }
    private func load(reverse: Bool, strip: Int, token: OperationCancellation, retainingSavedComparison: Bool = false) async throws {
        try ensure(token)
        let next = try await repository.reviewWorkingTreePatch(bytes, reversed: reverse, stripCount: strip, directoryMode: directoryMode, isGitWorkingTree: isGitWorkingTree, cancellation: token)
        try ensure(token)
        review = next; requiresRefresh = false; fileListGeneration = UUID()
        highlightedFiles.formIntersection(Set(next.files.map(\.id)))
        selected = Set(next.files.filter { !appliedPaths.contains($0.pathBytes) }.map(\.id))
        try await validateSelection(token)
        let inspections = try await repository.inspectWorkingTreePatchFiles(next,excluding:appliedPaths,cancellation:token)
        try ensure(token);fileInspections = inspections
        if !retainingSavedComparison { await loadComparison(token) }
    }
    private func validateSelection(_ token: OperationCancellation) async throws {
        try ensure(token)
        selectedReview = nil
        guard let review, !selected.isEmpty else { notice = appliedPaths.isEmpty ? "Select files to apply." : "Selected files have been applied."; return }
        let next = try await repository.reviewWorkingTreePatchFiles(review, fileIDs: selected, cancellation: token)
        try ensure(token)
        selectedReview = next; notice = next.validationError ?? "Choose files to patch, or patch all remaining files."
    }
    func focusFile(_ id: Int?) {
        guard canReplaceComparison, !requiresRefresh else { return }
        if let id, let file = review?.files.first(where: { $0.id == id }) {
            // FilePatchesDlg does not reopen or redirect an already-patched row.
            if appliedPaths.contains(file.pathBytes) { return }
            if let result = fileResults[file.pathBytes], !result.success && !result.requiresMerge {
                comparisonNotice = result.output; return
            }
        } else if id != nil { return }
        guard let token = begin() else { return }
        focusedFile = id
        comparisonRead = true
        Task { defer { comparisonRead = false; finish(token) }; await loadComparison(token) }
    }
    private func loadComparison(_ token: OperationCancellation) async {
        guard (try? ensure(token)) != nil else { return }
        comparison = nil;specialSavedResult = nil;specialResolutionChoice = nil; editor?.retireImageLoader(); editor = nil; editorChanges = nil; conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil; beforeScroll = nil; afterScroll = nil; comparisonNotice = ""; difference = -1
        guard let review else { focusedFile = nil; return }
        let file: WorkingTreePatchReview.File?
        if let focusedFile { file = review.files.first(where: { $0.id == focusedFile }) }
        else { file = review.files.first(where: { !appliedPaths.contains($0.pathBytes) }) }
        guard let file else { focusedFile = nil; return }
        guard !appliedPaths.contains(file.pathBytes) else { return }
        if let result = fileResults[file.pathBytes], !result.success && !result.requiresMerge { comparisonNotice = result.output; return }
        focusedFile = file.id
        do {
            try checkAccess()
            let value = try await repository.compareWorkingTreePatchFile(review, fileID: file.id, cancellation: token)
            try ensure(token)
            comparison = value
            if value.requiresMerge {
                if value.recoveryKind == .text {installConflict(value)}
                else {onConflictEditorChanged(nil);comparisonNotice = "Choose the current or patched file state to complete this file."}
                return
            }
            let nextEditor = FileComparisonWindowModel(patchComparison: value, access: access, preferences: preferences)
            nextEditor.window = window; nextEditor.retainPermissions(openPermissions)
            nextEditor.onExportStateChanged = { [weak self] in self?.updateParentState(); self?.onBusyChanged() }
            nextEditor.onRegisterScroll = { [weak self] scroll, base in if base { self?.beforeScroll = scroll } else { self?.afterScroll = scroll } }
            editorChanges = nextEditor.objectWillChange.sink { [weak self] in self?.objectWillChange.send(); self?.onBusyChanged() }
            editor = nextEditor; updateParentState()
        } catch { if !retired && !token.isCancelled { comparisonNotice = error.localizedDescription } }
    }
    func resolveSpecial(_ choice:WorkingTreePatchResolutionChoice) {
        guard canResolveSpecial,let comparison = specialComparison,let token = begin() else {return}
        let generation = fileListGeneration
        Task { [self] in
            defer {finish(token)}
            var reported = false
            do {
                let accepted:Bool
                if let chooseSpecialResolution {accepted = await chooseSpecialResolution(choice,comparison)}
                else if choice == .patched,comparison.document.destination.mode == nil {
                    guard let window,window.attachedSheet == nil else {return}
                    let question = NSAlert();question.alertStyle = .warning;question.messageText = "Delete “" + comparison.document.base.path + "”?"
                    question.informativeText = "The patch deletes this file. Delete the reviewed current version?"
                    let cancel = question.addButton(withTitle:"Cancel");cancel.keyEquivalent = "\r";question.addButton(withTitle:"Delete").keyEquivalent = ""
                    question.window.defaultButtonCell = cancel.cell as? NSButtonCell
                    specialQuestion = question
                    let response = await withCheckedContinuation {continuation in question.beginSheetModal(for:window) {continuation.resume(returning:$0)}}
                    if specialQuestion === question {specialQuestion = nil}
                    accepted = response == .alertSecondButtonReturn
                } else {accepted = true}
                try ensure(token)
                guard accepted,generation == fileListGeneration,self.comparison?.fileID == comparison.fileID else {return}
                try checkAccess()
                let saved = try await repository.resolveWorkingTreePatchFile(comparison,choice:choice,autoAddNewFiles:MergeEditorPreferences.load(from:preferences).autoAdd,cancellation:token)
                onChanged(saved.output);reported = true
                try ensure(token)
                specialSavedResult = saved;specialResolutionChoice = choice
                if choice == .current {keptCurrentPaths.insert(Data(comparison.document.destination.path.utf8))}
                appliedPaths.insert(Data(comparison.document.destination.path.utf8));output += saved.output
                comparisonNotice = choice == .current ? "Current working file and paths kept." : "Selected patched file state saved."
                if let failure = saved.addError {notice = "Saved selected file state, but Add failed: " + failure}
            } catch {
                if !reported {onMutationStopped()}
                if !retired,!token.isCancelled {notice = error.localizedDescription;output += notice + "\n"}
            }
        }
    }
    private func installConflict(_ comparison:WorkingTreePatchFileComparison) {
        let next = TextConflictWindowModel(repository:repository,access:access,path:comparison.document.destination.path)
        next.patchComparison = comparison;next.window = window;next.comparisonDefaults = preferences
        next.workingMergePermissions = [access,fileAccess].compactMap {$0}
        next.patchResultSaver = { [weak self,weak next] text,encoding,cancellation in
            guard let self,let next,!self.retired,let document = next.document else {throw OperationCancellationFailure.cancelled}
            do {
                try self.checkAccess()
                let saved = try await self.repository.saveWorkingTreePatchFile(comparison,text:text,encoding:encoding,autoAddNewFiles:MergeEditorPreferences.load(from:self.preferences).autoAdd,cancellation:cancellation)
                self.onChanged(saved.output)
                if !self.retired {
                    self.appliedPaths.insert(Data(comparison.document.destination.path.utf8));self.output += saved.output
                    next.patchResultCompleted = true;next.resetHistory()
                    if let failure = saved.addError {self.notice = "Saved patched result, but Add failed: " + failure}
                }
                return try document.recordingPatchSave(saved)
            } catch {self.onMutationStopped();throw error}
        }
        next.onChanged = {_ in}
        conflictChanges = next.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send();self?.onBusyChanged() }
        conflictEditor = next;next.load();updateParentState()
    }
    enum ComparisonPresentation: Equatable { case text, processing, failure(String), binary, empty }
    var comparisonPresentation: ComparisonPresentation {
        guard comparison != nil else { return .empty }
        if editor?.filtering == true { return .processing }
        if alignment != nil { return .text }
        if let error = editor?.error { return .failure(error) }
        if editor?.document?.base.text != nil && editor?.document?.destination.text != nil {
            return .failure("The text comparison is unavailable. Refresh to rebuild its preview.")
        }
        return .binary
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
    func undoPreview() {if let conflictEditor {conflictEditor.undo()} else {editor?.undo()}}
    func redoPreview() {if let conflictEditor {conflictEditor.redo()} else {editor?.redo()}}
    var canUndoPreview:Bool {conflictEditor?.canUndo ?? editor?.canUndo ?? false}
    var canRedoPreview:Bool {conflictEditor?.canRedo ?? editor?.canRedo ?? false}
    func findComparison() {
        guard editable else { return }
        if conflictEditor != nil {(window as? TextConflictNSWindow)?.find(.showFindInterface);return}
        guard let view = afterScroll?.documentView as? NSTextView else { return }
        view.window?.makeFirstResponder(view)
        let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(sender)
    }
    func updateParentState() {
        editor?.busy = busy || editor?.exporting == true
        editor?.confirmingQuit = confirmingQuit || draftDecisionPending || parentActive()
        let blocked = confirmingQuit || draftDecisionPending || busy || parentActive()
        if conflictEditor?.confirmingQuit != blocked {conflictEditor?.confirmingQuit = blocked}
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
        if conflictEditor != nil {conflictEditor?.retire();conflictChanges = nil;installConflict(comparison);return}
        editor?.resetHistory(); editor?.retireImageLoader(); beforeScroll = nil; afterScroll = nil
        let next = FileComparisonWindowModel(patchComparison: comparison, access: access, preferences: preferences)
        next.window = window; next.retainPermissions(openPermissions)
        next.onExportStateChanged = { [weak self] in self?.updateParentState(); self?.onBusyChanged() }
        next.onRegisterScroll = { [weak self] scroll, base in if base { self?.beforeScroll = scroll } else { self?.afterScroll = scroll } }
        editorChanges = next.objectWillChange.sink { [weak self] in self?.objectWillChange.send(); self?.onBusyChanged() }
        editor = next; updateParentState(); onBusyChanged()
    }
    func saveDraft(completion: ((Bool) -> Void)? = nil) {
        if let conflictEditor {guard canSaveDraft else {completion?(false);return};conflictEditor.save(markResolved:false,completion:completion);return}
        guard canSaveDraft, let token = begin() else { completion?(false); return }
        Task { let saved = await performSave(token); finish(token); completion?(saved) }
    }
    private func performSave(_ token: OperationCancellation) async -> Bool {
        guard !retired, let comparison, let editor, editor.canEdit(base: false) else { return false }
        if editor.savedPaneURL(base: false) != nil {
            let saved = await withCheckedContinuation { continuation in editor.saveReboundResultFromOwner { continuation.resume(returning: $0) } }
            if saved { onChanged("Saved selected pane: " + (editor.savedPaneURL(base: false)?.path ?? "")) }
            else { onMutationStopped() }
            guard !retired, operation === token, !token.isCancelled else { return false }
            if saved { output += "Saved selected pane: " + (editor.savedPaneURL(base: false)?.path ?? "") + "\n" }
            return saved
        }
        let text = editor.draftText(base: false), encoding = editor.encoding(base: false)
        let autoAdd = MergeEditorPreferences.load(from: preferences).autoAdd
        var reported = false
        do {
            try checkAccess()
            let saved = try await repository.saveWorkingTreePatchFile(comparison, text: text, encoding: encoding, autoAddNewFiles: autoAdd, cancellation: token)
            onChanged(saved.output); reported = true
            try ensure(token)
            appliedPaths.insert(Data(comparison.document.destination.path.utf8)); output += saved.output
            try editor.acceptPatchSave(saved.document)
            try await load(reverse: reversed, strip: stripCount, token: token, retainingSavedComparison: true)
            if let failure = saved.addError { notice = "Saved patched result, but Add failed: " + failure; output += notice + "\n"; return false }
            return true
        } catch {
            if !reported { onMutationStopped() }
            if !retired && !token.isCancelled { notice = error.localizedDescription; output += notice + "\n" }
            return false
        }
    }
    func resolveDraft(discardImmediately: Bool = true) async -> Bool {
        guard !retired, !conflictOperationActive, editor?.hasPendingEditorChoice != true else { return false }
        guard dirty else { return true }
        guard !busy, !draftDecisionPending else { return false }
        draftDecisionPending = true; Self.activeOperations += 1
        defer { draftDecisionPending = false; Self.activeOperations -= 1 }
        let choice = await chooseDraft()
        guard !retired else { return false }
        switch choice {
        case .cancel: return false
        case .save:
            if let conflictEditor {return await withCheckedContinuation {continuation in conflictEditor.saveForQuit {continuation.resume(returning:$0)}}}
            guard let token = begin() else { return false }
            defer { finish(token) }
            return await performSave(token)
        case .discard:
            if discardImmediately { resetComparisonDraft() }
            return true
        }
    }
    func requestClose() { Task { if await resolveDraft() { close() } } }
    func check(_ id: Int, _ value: Bool) {
        guard canReplaceComparison, !requiresRefresh, let file = review?.files.first(where: { $0.id == id }), !appliedPaths.contains(file.pathBytes) else { return }
        if value { selected.insert(id) } else { selected.remove(id) }
        guard let token = begin() else { return }; selectedReview = nil
        Task { defer { finish(token) }; do { try checkAccess(); try await validateSelection(token) } catch { if !retired && !token.isCancelled { notice = error.localizedDescription } } }
    }
    func apply() {
        guard canApply, let selection = selectedReview, let token = begin() else { return }; selectedReview = nil
        let reverse = reversed, strip = stripCount
        Task {
            defer { finish(token) }
            var reported = false
            do {
                try checkAccess()
                let result = try await repository.applyWorkingTreePatch(selection, cancellation: token)
                onChanged(result + "\nApplied \(selection.files.count) file(s).\n"); reported = true
                try ensure(token)
                appliedPaths.formUnion(selection.files.map(\.pathBytes)); output += result + "\nApplied \(selection.files.count) file(s).\n"
                try await load(reverse: reverse, strip: strip, token: token)
            } catch {
                if !reported { onMutationStopped() }
                if !retired && !token.isCancelled { notice = error.localizedDescription; output += "\n" + notice + "\n" }
            }
        }
    }
}

private struct WorkingTreePatchFileList: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    var body: some View {
        VStack(alignment: .leading) {
                    Text("Files to patch:")
                    WorkingTreePatchNativeFileList(model:model)
                    Button { model.patchFiles(model.highlightedFiles, generation: model.fileListGeneration) } label: {
                        Text("Patch selected item").frame(maxWidth: .infinity)
                    }.disabled(!model.canPatchFiles || model.highlightedFiles.isEmpty)
                    Button { model.patchFiles(Set(model.review?.files.map(\.id) ?? []), generation: model.fileListGeneration) } label: {
                        Text("Patch all items").frame(maxWidth: .infinity)
                    }.disabled(!model.canPatchFiles)
                }.frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
    }
}

struct WorkingTreePatchDialog: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.repository.root.path).lineLimit(1).help(model.repository.root.path)
                Spacer()
                Button(model.fileListVisible ? "Hide file list" : "Show file list") {model.toggleFileList()}.disabled(!model.canToggleFileList)
                Toggle("Reverse patch", isOn: Binding(get: { model.reversed }, set: { model.setReversed($0) }))
                Text("Strip paths:"); TextField("Strip paths", value: Binding(get: { model.stripCount }, set: { model.setStripCount($0) }), formatter: NumberFormatter()).frame(width: 45)
                Button("Refresh") { model.refresh() }
            }.disabled(!model.canReplaceComparison)
            HSplitView {
                if model.fileListVisible { WorkingTreePatchFileList(model: model) }
                TabView(selection: $model.previewTab) {
                    WorkingTreePatchComparisonView(model: model).tabItem { Text("Compare") }.tag(0)
                    VStack(alignment: .leading) { Text("Original patch:"); PatchTextView(model: model.previewDocument) }.tabItem { Text("Original patch") }.tag(1)
                }.frame(minWidth: 440)
            }
            Text(model.notice).foregroundStyle(model.canApply ? Color.secondary : Color.orange).textSelection(.enabled)
            if !model.output.isEmpty { DisclosureGroup("Output") { OutputView(text: model.output, usesLogFont: true).frame(height: 100) } }
            HStack {
                if model.busy || model.editor?.exporting == true || model.conflictEditor?.busy == true { ProgressView().controlSize(.small); Text(model.editor?.exporting == true ? "Saving copy…" : "Processing patch…"); Button("Cancel operation", action: model.cancelOperation) }
                Spacer()
                Button("Close") { model.requestClose() }.disabled(!model.editable)
            }
        }.padding(16)
    }
}

struct WorkingTreePatchComparisonView: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    private func pane(base: Bool) -> some View {
        let content = base ? (model.editor?.document?.base ?? model.comparison?.document.base) : (model.editor?.document?.destination ?? model.comparison?.document.destination)
        return VStack(alignment: .leading, spacing: 5) {
            Text(base ? "Before patch" : "After patch").font(.headline)
            if let content {
                Text(content.path).font(.caption).lineLimit(1).help(content.path)
                if let alignment = model.alignment {
                    // Keep the coordinator, native editor and Undo manager alive
                    // while the authoritative engine refines the provisional rows.
                    WorkingTreePatchComparisonEditor(model: model, cells: alignment.rows.map { base ? $0.base : $0.destination }, base: base)
                        .overlay(alignment: .topTrailing) {
                            if model.comparisonPresentation == .processing { ProgressView("Comparing…").controlSize(.small).padding(6).allowsHitTesting(false) }
                        }
                } else if case .failure(let error) = model.comparisonPresentation {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if model.comparisonPresentation == .processing {
                    ProgressView("Comparing…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let special = model.specialComparison {
                PatchSpecialRecoveryView(model:model,comparison:special)
            } else if let conflict = model.conflictEditor {
                PatchMergeEditor(model:conflict)
                if conflict.dirty {Button("Discard edits") {model.discardDraft()}.disabled(!model.editable)}
            } else {
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
            if let error = model.editor?.error, model.alignment != nil {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.editor?.error = nil }
                }.accessibilityElement(children: .contain).accessibilityLabel("Comparison error")
            }
            }
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

/// Source FilePatchesDlg selection and preview are separate operations. AppKit
/// owns row selection, keyboard navigation and context-menu positioning.
struct WorkingTreePatchNativeFileList: NSViewRepresentable {
    @ObservedObject var model:WorkingTreePatchWindowModel
    func makeCoordinator() -> Coordinator {Coordinator(model)}
    func makeNSView(context:Context) -> NSScrollView {
        let table = PatchReviewFileTable();table.coordinator = context.coordinator
        table.identifier = NSUserInterfaceItemIdentifier("TurtleGit.Patch.Files")
        table.setAccessibilityLabel("Files to patch")
        table.allowsMultipleSelection = true;table.allowsEmptySelection = true
        table.allowsColumnReordering = false;table.rowHeight = 22
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (name,width) in [("Path",235.0),("State",65.0)] {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(name));column.title = name;column.width = width;column.minWidth = name == "Path" ? 100 : 45;table.addTableColumn(column)
        }
        table.delegate = context.coordinator;table.dataSource = context.coordinator
        table.target = context.coordinator;table.doubleAction = #selector(Coordinator.preview(_:))
        let scroll = NSScrollView();scroll.borderType = .bezelBorder;scroll.hasVerticalScroller = true;scroll.documentView = table
        context.coordinator.table = table;context.coordinator.update();return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {context.coordinator.update()}
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {
        (scroll.documentView as? PatchReviewFileTable)?.coordinator = nil
        coordinator.table?.delegate = nil;coordinator.table?.dataSource = nil;coordinator.table?.target = nil;coordinator.table = nil;coordinator.retired = true
    }
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSMenuItemValidation {
        let model:WorkingTreePatchWindowModel
        weak var table:NSTableView?
        var retired = false,updating = false
        private var rows:[WorkingTreePatchReview.File] = []
        private struct RowState:Equatable {let id:Int,path:Data,state:String,shown:Bool,diagnostic:String}
        private var rendered:[RowState] = []
        private final class Invocation {
            enum Action {case preview,selected,all}
            let action:Action,ids:Set<Int>,generation:UUID
            init(_ action:Action,_ ids:Set<Int>,_ generation:UUID) {self.action = action;self.ids = ids;self.generation = generation}
        }
        init(_ model:WorkingTreePatchWindowModel) {self.model = model}
        func update() {
            guard !retired,let table else {return}
            updating = true;defer {updating = false}
            rows = model.review?.files ?? []
            let next = rows.map {RowState(id:$0.id,path:$0.pathBytes,state:model.fileState($0),shown:model.focusedFile == $0.id,diagnostic:model.fileResults[$0.pathBytes]?.output ?? model.fileInspections[$0.pathBytes]?.diagnostic ?? "")}
            if next != rendered {
                let origin = table.enclosingScrollView?.contentView.bounds.origin
                rendered = next;table.reloadData()
                if let origin {table.enclosingScrollView?.contentView.scroll(to:origin)}
            }
            let selected = IndexSet(rows.indices.filter {model.highlightedFiles.contains(rows[$0].id)})
            if table.selectedRowIndexes != selected {table.selectRowIndexes(selected,byExtendingSelection:false)}
        }
        func numberOfRows(in tableView:NSTableView) -> Int {rows.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
            guard rows.indices.contains(row) else {return nil};let file = rows[row],state = model.fileState(file)
            let cell = NSTableCellView(),label = NSTextField(labelWithString:tableColumn?.identifier.rawValue == "State" ? state : (file.path as NSString).lastPathComponent)
            label.lineBreakMode = .byTruncatingTail
            label.font = model.focusedFile == file.id ? .boldSystemFont(ofSize:NSFont.systemFontSize) : .systemFont(ofSize:NSFont.systemFontSize)
            label.textColor = ["error","conflict"].contains(state) ? .systemRed : ["patched","kept current"].contains(state) ? .secondaryLabelColor : .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false;cell.addSubview(label);cell.textField = label
            cell.toolTip = model.repository.root.appendingPathComponent(file.path).path + (["error","conflict"].contains(state) ? "\n" + (model.fileResults[file.pathBytes]?.output ?? model.fileInspections[file.pathBytes]?.diagnostic ?? "") : "")
            if tableColumn?.identifier.rawValue == "Path" {
                let image = NSImageView();image.image = NSWorkspace.shared.icon(for:UTType(filenameExtension:(file.path as NSString).pathExtension) ?? .data);image.translatesAutoresizingMaskIntoConstraints = false;cell.addSubview(image);cell.imageView = image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4),image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),image.widthAnchor.constraint(equalToConstant:16),image.heightAnchor.constraint(equalToConstant:16),label.leadingAnchor.constraint(equalTo:image.trailingAnchor,constant:4)])
            } else {label.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4).isActive = true}
            NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        func selectionShouldChange(in tableView:NSTableView) -> Bool {updating || !retired && model.canHighlightFiles}
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !retired,!updating,let table else {return}
            model.highlightFiles(Set(table.selectedRowIndexes.compactMap {rows.indices.contains($0) ? rows[$0].id : nil}))
        }
        var selectedIDs:Set<Int> {Set((table?.selectedRowIndexes ?? []).compactMap {rows.indices.contains($0) ? rows[$0].id : nil})}
        @objc func preview(_ sender:Any?) {guard !retired else {return};model.previewFiles(selectedIDs,generation:model.fileListGeneration)}
        func contextMenu() -> NSMenu {
            let menu = NSMenu();let ids = selectedIDs,generation = model.fileListGeneration
            let commands:[(String,Invocation.Action,MenuIcon)] = [("Preview patched file",.preview,.compare),("Patch all files",.all,.patch),("Patch selected files",.selected,.patch)]
            for (title,action,icon) in commands {
                let item = NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"");item.target = self;item.representedObject = Invocation(action,ids,generation)
                item.image = MenuPresentationSettings.applicationContextIcons(defaults:model.openPreferences) ? icon.image() : nil
                item.isEnabled = validateMenuItem(item);menu.addItem(item)
            }
            return menu
        }
        func validateMenuItem(_ item:NSMenuItem) -> Bool {
            guard !retired,let invocation = item.representedObject as? Invocation,invocation.generation == model.fileListGeneration else {return false}
            switch invocation.action {
            case .preview:return model.canPreviewFiles(invocation.ids,generation:invocation.generation)
            case .all:return model.canPatchFiles
            case .selected:return model.canPatchFiles && model.review?.files.contains(where:{invocation.ids.contains($0.id) && !model.appliedPaths.contains($0.pathBytes)}) == true
            }
        }
        @objc private func invoke(_ item:NSMenuItem) {
            guard validateMenuItem(item),let invocation = item.representedObject as? Invocation else {return}
            switch invocation.action {
            case .preview:model.previewFiles(invocation.ids,generation:invocation.generation)
            case .all:model.patchFiles(Set(model.review?.files.map(\.id) ?? []),generation:invocation.generation)
            case .selected:model.patchFiles(invocation.ids,generation:invocation.generation)
            }
        }
    }
}

private final class PatchReviewFileTable:NSTableView {
    weak var coordinator:WorkingTreePatchNativeFileList.Coordinator?
    override func menu(for event:NSEvent) -> NSMenu? {
        let row = self.row(at:convert(event.locationInWindow,from:nil))
        if row >= 0,!selectedRowIndexes.contains(row),coordinator?.model.canHighlightFiles == true {selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
        return coordinator?.contextMenu()
    }
    override func keyDown(with event:NSEvent) {
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if flags.isEmpty,(event.keyCode == 36 || event.keyCode == 76) {coordinator?.preview(nil);return}
        if flags == .shift,event.keyCode == 109,let menu = coordinator?.contextMenu() {
            let row = selectedRow >= 0 ? selectedRow : 0
            let point = numberOfRows > row ? NSPoint(x:bounds.minX + 12,y:rect(ofRow:row).midY) : NSPoint(x:bounds.midX,y:bounds.midY)
            menu.popUp(positioning:nil,at:point,in:self);return
        }
        super.keyDown(with:event)
    }
}

private struct PatchSpecialRecoveryView:View {
    @ObservedObject var model:WorkingTreePatchWindowModel
    let comparison:WorkingTreePatchFileComparison
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title).font(.headline)
            Text("Preview does not change files. Choose which complete file state to keep.").foregroundStyle(.secondary)
            HSplitView {
                PatchFileStatePreview(title:"Current working file",content:comparison.document.base)
                PatchFileStatePreview(title:"Patched recorded base",content:comparison.document.destination)
            }
            if let choice = model.specialResolutionChoice {
                Label(choice == .current ? "Current working file and paths kept." : "Selected patched file state saved.",systemImage:"checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                Button {model.resolveSpecial(.current)} label: {CommandLabel(title:comparison.document.base.mode == nil ? "Keep current deletion" : "Keep current file",icon:.mergeUseMine)}
                    .help("Keep the reviewed current files and paths without applying this patch record.")
                Spacer()
                Button {model.resolveSpecial(.patched)} label: {CommandLabel(title:comparison.document.destination.mode == nil ? "Use patched deletion…" : "Use patched file",icon:.mergeUseTheirs)}
                    .help("Use the complete patched contents, file type and paths shown above.")
            }.disabled(!model.canResolveSpecial)
        }.padding(12)
    }
    private var title:String {
        switch comparison.recoveryKind {
        case .binary:return "Binary file conflict"
        case .symbolicLink:return "Symbolic link or file-type conflict"
        case .deletion:return "Deleted or modified file conflict"
        default:return "File conflict"
        }
    }
}
private struct PatchFileStatePreview:View {
    let title:String
    let content:ComparisonFileContent
    private var isLink:Bool {content.mode == "120000"}
    private var image:NSImage? {
        guard ["100644","100755"].contains(content.mode ?? ""),content.bytes.count <= 16 * 1024 * 1024,
              UTType(filenameExtension:(content.path as NSString).pathExtension)?.conforms(to:.image) == true else {return nil}
        return NSImage(data:content.bytes)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.headline)
            Text(content.path).font(.caption).lineLimit(1).help(content.path)
            Text(content.mode.map {isLink ? "Symbolic link · \(content.bytes.count) bytes" : "\($0) · \(content.bytes.count) bytes"} ?? "Absent / deleted").font(.caption).foregroundStyle(.secondary)
            if content.mode == nil {
                VStack {Spacer();Image(systemName:"doc.badge.minus").font(.system(size:32)).foregroundStyle(.orange);Text("No file on this side");Spacer()}.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if isLink {
                ScrollView {Text("Link target:\n" + String(decoding:content.bytes,as:UTF8.self)).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
            } else {
                if let image {Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:240)}
                ScrollView {
                    Text(content.bytes.prefix(4096).enumerated().map {($0.offset % 16 == 0 ? String(format:"\n%08X  ",$0.offset) : " ") + String(format:"%02X",$0.element)}.joined()).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                }.accessibilityLabel(title + " byte preview")
                if content.bytes.count > 4096 {Text("First 4096 bytes shown").font(.caption).foregroundStyle(.secondary)}
            }
        }.padding(10).frame(minWidth:200,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Color(nsColor:.textBackgroundColor))
    }
}
