import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RequestPullWindowController: NSWindowController, NSWindowDelegate {
    let model: RequestPullWindowModel
    var onClosed: () -> Void = {}
    private var picker: LogWindowController?
    private var sendPatch: SendMailWorkflow?
    private let mailPreferences: UserDefaults
    private let mailPresentation: ((NSWindowController) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, end: String? = nil, repositoryURL: String? = nil, preferences: UserDefaults = .standard, mailPresentation: ((NSWindowController) -> Void)? = nil) {
        self.mailPreferences = preferences; self.mailPresentation = mailPresentation
        model = RequestPullWindowModel(repository: repository, access: access, preferences: preferences, end: end, repositoryURL: repositoryURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 210), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Request pull – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RequestPullDialog(model: model))
        super.init(window: window); window.delegate = self
        window.contentMinSize = NSSize(width: 600, height: 210); window.contentMaxSize = NSSize(width: 4000, height: 210)
        window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.composingMail, self.window?.attachedSheet == nil else { return }; self.window?.performClose(nil) }
        model.chooseStart = { [weak self] in self?.chooseStart() }
        model.presentDocument = { [weak self] file, sendMail in self?.present(file, sendMail: sendMail) }
        model.load()

        DialogGeometry.attach(window, identifier: "RequestPullDialog", legacyName: "RequestPullDialog")
    }
    private func chooseStart() {
        guard let window, window.attachedSheet == nil, picker == nil, !model.busy else { return }
        let controller = LogWindowController(repository: model.repository, access: model.access, onChoose: { [weak self] entry in self?.model.acceptStart(entry?.hash) })
        picker = controller; controller.onClosed = { [weak self] in self?.picker = nil }
        model.configureLog(controller.model)
        if let child = controller.window { window.beginSheet(child) }
    }
    private func present(_ file: URL, sendMail: Bool) {
        if sendMail {
            do {
                guard !model.composingMail else { return }
                model.composingMail = true
                let workflow = SendMailWorkflow(files: [file], repository: model.repository, access: model.access,
                    fileAccess: [], preferences: mailPreferences, presentation: mailPresentation,
                    customSubject: true, appOwnedFiles: [file]) { [weak self] _ in
                    guard let self else { return }; self.sendPatch = nil; self.model.composingMail = false
                    self.model.close()
                }
                sendPatch = workflow; workflow.start(); return
            }

        } else if NSWorkspace.shared.open(file) { model.close() }
        else { model.error = "Could not open the generated request. Use Open request to try again." }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.composingMail && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); if let child = picker?.window { child.sheetParent?.endSheet(child); child.close() }; picker = nil; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class RequestPullWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    private var invalidated = false
    private var cancellation: OperationCancellation?
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
        guard !busy, !invalidated else { return }; busy = true
        Task { defer { busy = false }; do { let refs = try await repository.checkoutReferences(); guard !invalidated else { return }; references = refs.filter { $0.name.hasPrefix("refs/heads/") || $0.remote }.map { $0.name.hasPrefix("refs/heads/") ? String($0.name.dropFirst(11)) : $0.name.hasPrefix("refs/") ? String($0.name.dropFirst(5)) : $0.name }.sorted() } catch { if !invalidated { self.error = error.localizedDescription } } }
    }
    func configureLog(_ log: LogWindowModel) {
        let revision = FetchDialogHistory.trim(start)
        log.endRevision = revision.isEmpty ? nil : revision; log.allBranches = false; log.showWorkingTree = false; log.historyPaths = []; log.showWholeProject = true; log.reload()
    }
    func acceptStart(_ hash: String?) { guard !busy, !invalidated, let hash, !hash.isEmpty else { return }; start = hash }
    func deleteURL(at index: Int) {
        guard !busy, !invalidated, let result = FetchDialogHistory.removing(index, entries: urls, preferences: preferences, key: Self.urlHistoryKey) else { return }; urls = result.entries; repositoryURL = result.selection
    }
    func invalidate() { invalidated = true; cancellation?.cancel() }
    func cancel() { if let cancellation { cancelling = true; cancellation.cancel() } else if !busy, !composingMail { close() } }
    func create() {
        guard !busy, !composingMail, !invalidated else { return }
        var options = RequestPullOptions(); options.start = start; options.repositoryURL = FetchDialogHistory.trim(repositoryURL.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")); options.end = FetchDialogHistory.trim(end)
        let mail = sendMail, token = OperationCancellation(); cancellation = token; busy = true; cancelling = false; error = nil
        // RequestPullDlg saves URL/last fields before its end-name validation.
        urls = FetchDialogHistory.save(options.repositoryURL, entries: urls, preferences: preferences, key: Self.urlHistoryKey, caseSensitive: true)
        preferences.set(options.start, forKey: key + "startrevision"); preferences.set(options.repositoryURL, forKey: key + "repositoryurl"); preferences.set(options.end, forKey: key + "endrevision")
        Task {
            var validated = false
            do {
                try await repository.validateRequestPullEnd(options.end)
                validated = true
                preferences.set(mail, forKey: Self.sendMailKey)
                let bytes = try await repository.requestPull(options, cancellation: token)
                guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }; guard !invalidated else { return }
                let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-request-pull-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("pullrequest.txt")
                do { try bytes.write(to: file, options: .atomic) } catch { try? FileManager.default.removeItem(at: directory); throw error }
                document = file; busy = false; cancellation = nil; cancelling = false
                presentDocument(file, mail)
            } catch { if !invalidated { self.error = token.isCancelled ? "User cancelled." : (validated ? "Failed to create pull-request.\n" : "") + error.localizedDescription } }
            busy = false; cancellation = nil; cancelling = false
        }
    }
    func openDocument() { guard !busy, !composingMail, !invalidated, let document else { return }; presentDocument(document, false) }
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
            }.disabled(model.busy || model.composingMail)
            Spacer(minLength: 0)
            HStack { if model.busy { ProgressView().controlSize(.small); Text(model.cancelling ? "Cancelling…" : "Creating pull-request...").font(.caption) }; if model.document != nil { Button("Open request") { model.openDocument() }.disabled(model.busy || model.composingMail) }; Spacer()
                Button("OK") { model.create() }.keyboardShortcut(.defaultAction).disabled(model.busy || model.composingMail)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.cancelling || model.composingMail)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-patch.html#tgit-dug-request-pull")!) }
            }
        }.padding(16)
        .alert("Request pull", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
