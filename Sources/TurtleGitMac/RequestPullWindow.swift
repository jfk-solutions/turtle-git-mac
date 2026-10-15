import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RequestPullWindowController: NSWindowController, NSWindowDelegate {
    let model: RequestPullWindowModel
    var onClosed: () -> Void = {}
    private(set) var picker: LogWindowController?
    private var retired = false
    private var pickerRequest: UUID?
    private struct Options: Equatable {
        let values: [GitReferenceName]
        let sendMail: Bool
    }
    private var options: Options { Options(values: [model.start, model.repositoryURL, model.end].map { GitReferenceName($0) }, sendMail: model.sendMail) }
    private var pendingStart: (UUID, Options, String?)?
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var makePicker: (GitRepository, RepositoryAccessLease?, String?, UserDefaults, @escaping (LogEntry?) -> Void) -> LogWindowController = { repository, access, revision, preferences, choose in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, initialRevision: revision)
    }
    var presentPicker: (NSWindow, NSWindow) -> Bool = { parent, child in
        guard parent.attachedSheet == nil else { return false }; parent.beginSheet(child); return true
    }
    var openDocument: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var activeOperation: Bool { model.busy || model.composingMail || model.choosingStart || window?.attachedSheet != nil }

    private var sendPatch: SendMailWorkflow?
    private let mailPreferences: UserDefaults
    private let mailPresentation: ((NSWindowController) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, end: String? = nil, repositoryURL: String? = nil, preferences: UserDefaults = .standard, mailPresentation: ((NSWindowController) -> Void)? = nil) {
        self.mailPreferences = preferences; self.mailPresentation = mailPresentation
        model = RequestPullWindowModel(repository: repository, access: access, preferences: preferences, end: end, repositoryURL: repositoryURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 210), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Request pull", preferences: preferences); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RequestPullDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.contentMinSize = NSSize(width: 600, height: 210); window.contentMaxSize = NSSize(width: 4000, height: 210)
        window.center()
        model.close = { [weak self] in guard let self, !self.activeOperation else { return }; self.window?.performClose(nil) }
        model.chooseStart = { [weak self] in self?.chooseStart() }
        model.presentDocument = { [weak self] file, sendMail in self?.present(file, sendMail: sendMail) }
        NotificationCenter.default.addObserver(self, selector: #selector(pickerSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        model.load()

        DialogGeometry.attach(window, identifier: "RequestPullDialog", legacyName: "RequestPullDialog")
    }
    func chooseStart() {
        guard !retired, model.optionsAvailable, let window, window.attachedSheet == nil, picker == nil else { return }
        window.makeFirstResponder(nil)
        let captured = options, request = UUID(), revision = FetchDialogHistory.trim(model.start)
        pickerRequest = request; model.choosingStart = true
        let child = makePicker(model.repository, model.access, revision.isEmpty ? nil : revision, mailPreferences) { [weak self] entry in
            guard let self, !self.retired, self.pickerRequest == request else { return }
            self.pendingStart = (request, captured, entry?.hash); self.drainStart()
        }
        picker = child; configureLogPicker(child.model)
        child.model.showWorkingTree = false; child.model.historyPaths = []; child.model.showWholeProject = true
        child.onClosed = { [weak self, weak child] in
            guard let self, self.picker === child else { return }
            self.picker = nil; self.drainStart()
        }
        guard let sheet = child.window else { abandonPicker(); return }
        sheet.appearance = window.appearance; sheet.alphaValue = window.alphaValue
        guard presentPicker(window, sheet) else { abandonPicker(); return }
    }
    private func abandonPicker() {
        pickerRequest = nil; pendingStart = nil; model.choosingStart = false
        picker?.close(); picker = nil
    }
    @objc private func pickerSheetEnded() { drainStart() }
    private func drainStart() {
        guard !retired, let pending = pendingStart, pickerRequest == pending.0,
              picker == nil, window?.attachedSheet == nil else { return }
        pickerRequest = nil; pendingStart = nil; model.choosingStart = false
        guard options == pending.1, model.optionsAvailable else { return }
        model.acceptStart(pending.2); window?.makeKeyAndOrderFront(nil)
    }
    private func present(_ file: URL, sendMail: Bool) {
        guard !retired, !model.choosingStart else { return }
        if sendMail {
            do {
                guard !model.composingMail else { return }
                model.composingMail = true
                let workflow = SendMailWorkflow(files: [file], repository: model.repository, access: model.access,
                    fileAccess: [], preferences: mailPreferences, presentation: { [weak self] child in self?.presentMail(child) },
                    customSubject: true, appOwnedFiles: [file]) { [weak self] _ in
                    guard let self else { return }; self.sendPatch = nil; self.model.composingMail = false
                    guard !self.retired else { return }
                    self.model.close()
                }
                sendPatch = workflow; workflow.start(); return
            }

        } else if openDocument(file) { model.close() }
        else { model.error = "Could not open the generated request. Use Open request to try again." }
    }
    private func presentMail(_ child: NSWindowController) {
        guard !retired else { child.close(); return }
        child.window?.appearance = window?.appearance; child.window?.alphaValue = window?.alphaValue ?? 1
        if let mailPresentation { mailPresentation(child) }
        else { child.showWindow(nil); child.window?.makeKeyAndOrderFront(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(closeAfter: true); return false }
        return !activeOperation
    }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true; NotificationCenter.default.removeObserver(self)
        model.invalidate(); pickerRequest = nil; pendingStart = nil; model.choosingStart = false
        sendPatch?.invalidate(); sendPatch = nil; model.composingMail = false
        if let child = picker?.window { child.sheetParent?.endSheet(child); child.close() }; picker = nil; window?.contentViewController = nil; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class RequestPullWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private var invalidated = false
    private var cancellation: OperationCancellation?
    private var closeAfterOperation = false
    @Published private(set) var loading = false
    @Published var choosingStart = false
    var optionsAvailable: Bool { !invalidated && !busy && !composingMail && !choosingStart }
    var isRetired: Bool { invalidated }
    var requiresRepositoryScope = GitRuntime.isAppStoreBuild
    private func checkAccess() throws {
        if requiresRepositoryScope && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func begin(loading: Bool) -> OperationCancellation {
        let token = OperationCancellation(); cancellation = token; self.loading = loading
        busy = true; cancelling = false; Self.activeOperations += 1; return token
    }
    private func finish(_ token: OperationCancellation) {
        Self.activeOperations -= 1; withExtendedLifetime(access) {}
        guard cancellation === token else { return }
        cancellation = nil; busy = false; loading = false; cancelling = false
        if closeAfterOperation, !invalidated { closeAfterOperation = false; close() }
    }
    private var key: String { "History.RequestPull." + repository.root.path + "." }
    static let urlHistoryKey = "History.RequestPull.url"
    static let sendMailKey = "RequestPull.SendMail"
    @Published var start: String
    @Published var repositoryURL: String
    @Published var end: String
    @Published var sendMail: Bool
    @Published private(set) var references: [String] = []
    @Published private(set) var urls: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var cancelling = false
    @Published var composingMail = false
    @Published var error: String?
    @Published private(set) var document: URL?
    var close: () -> Void = {}
    var chooseStart: () -> Void = {}
    var presentDocument: (URL, Bool) -> Void = { _, _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, end: String? = nil, repositoryURL: String? = nil) {
        self.repository = repository; self.access = access; self.preferences = preferences
        let key = "History.RequestPull." + repository.root.path + "."
        start = preferences.string(forKey: key + "startrevision") ?? ""
        self.repositoryURL = repositoryURL.flatMap { $0.isEmpty ? nil : $0 } ?? preferences.string(forKey: key + "repositoryurl") ?? ""
        self.end = end.flatMap { $0.isEmpty ? nil : $0 } ?? preferences.string(forKey: key + "endrevision") ?? "HEAD"
        sendMail = preferences.bool(forKey: Self.sendMailKey)
        urls = FetchDialogHistory.load(preferences, key: Self.urlHistoryKey, caseSensitive: true)
    }
    func load() {
        guard optionsAvailable else { return }; let token = begin(loading: true)
        Task {
            defer { finish(token) }
            do {
                try checkAccess()
                let refs = try await repository.checkoutReferences(cancellation: token)
                guard !invalidated, !token.isCancelled else { return }
                references = refs.filter { $0.name.hasPrefix("refs/heads/") || $0.remote }.map {
                    $0.name.hasPrefix("refs/heads/") ? String($0.name.dropFirst(11)) : $0.name.hasPrefix("refs/") ? String($0.name.dropFirst(5)) : $0.name
                }.sorted()
            } catch { if !invalidated && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func configureLog(_ log: LogWindowModel) {
        let revision = FetchDialogHistory.trim(start)
        log.endRevision = revision.isEmpty ? nil : revision; log.allBranches = false; log.showWorkingTree = false; log.historyPaths = []; log.showWholeProject = true; log.reload()
    }
    func acceptStart(_ hash: String?) { guard optionsAvailable, let hash, !hash.isEmpty else { return }; start = hash }
    func deleteURL(at index: Int) {
        guard optionsAvailable, let result = FetchDialogHistory.removing(index, entries: urls, preferences: preferences, key: Self.urlHistoryKey) else { return }; urls = result.entries; repositoryURL = result.selection
    }
    func invalidate() { invalidated = true; cancellation?.cancel() }
    func cancel(closeAfter: Bool = false) {
        guard !invalidated, !choosingStart, !composingMail else { return }
        if let cancellation { closeAfterOperation = closeAfterOperation || closeAfter || loading; cancelling = true; cancellation.cancel() }
        else if optionsAvailable { close() }
    }
    func create() {
        guard optionsAvailable else { return }
        var options = RequestPullOptions(); options.start = start; options.repositoryURL = FetchDialogHistory.trim(repositoryURL.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")); options.end = FetchDialogHistory.trim(end)
        let mail = sendMail, token = begin(loading: false); error = nil
        // RequestPullDlg saves URL/last fields before its end-name validation.
        urls = FetchDialogHistory.save(options.repositoryURL, entries: urls, preferences: preferences, key: Self.urlHistoryKey, caseSensitive: true)
        preferences.set(options.start, forKey: key + "startrevision"); preferences.set(options.repositoryURL, forKey: key + "repositoryurl"); preferences.set(options.end, forKey: key + "endrevision")
        Task {
            defer { finish(token) }
            var validated = false
            do {
                try checkAccess()
                try await repository.validateRequestPullEnd(options.end, cancellation: token)
                try token.check(); guard !invalidated else { return }
                validated = true
                preferences.set(mail, forKey: Self.sendMailKey)
                let bytes = try await repository.requestPull(options, cancellation: token)
                guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }; guard !invalidated else { return }
                let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-request-pull-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("pullrequest.txt")
                do { try bytes.write(to: file, options: .atomic) } catch { try? FileManager.default.removeItem(at: directory); throw error }
                document = file; busy = false; cancelling = false
                presentDocument(file, mail)
            } catch { if !invalidated && !closeAfterOperation { self.error = token.isCancelled ? "User cancelled." : (validated ? "Failed to create pull-request.\n" : "") + error.localizedDescription } }
        }
    }
    func openDocument() { guard optionsAvailable, let document else { return }; presentDocument(document, false) }
}
struct RequestPullDialog: View {
    @ObservedObject var model: RequestPullWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                HStack { Text("Start").frame(width: 110, alignment: .leading); PushRefCombo(value: $model.start, choices: model.references, local: true); Button("…") { model.chooseStart() }.accessibilityLabel("Choose start revision from Log") }
                HStack { Text("Repository URL").frame(width: 110, alignment: .leading); FetchHistoryCombo(value: $model.repositoryURL, choices: model.urls, label: "Repository URL", onDelete: model.deleteURL) }
                HStack { Text("End").frame(width: 110, alignment: .leading); TextField("End", text: $model.end).labelsHidden() }
                Toggle("Send Mail after create", isOn: $model.sendMail)
            }.disabled(!model.optionsAvailable)
            Spacer(minLength: 0)
            HStack { if model.busy { ProgressView().controlSize(.small); Text(model.cancelling ? "Cancelling…" : model.loading ? "Loading revisions…" : "Creating pull-request...").font(.caption) }; if model.document != nil { Button("Open request") { model.openDocument() }.disabled(!model.optionsAvailable) }; Spacer()
                Button("OK") { model.create() }.keyboardShortcut(.defaultAction).disabled(!model.optionsAvailable)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.isRetired || model.cancelling || model.composingMail || model.choosingStart)
                Button("Help") { TurtleGitHelp.show(.patches) }
            }
        }.padding(16)
        .alert("Request pull", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
