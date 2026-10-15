import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FormatPatchWindowController: NSWindowController, NSWindowDelegate {
    let model: FormatPatchWindowModel
    var onClosed: () -> Void = {}
    private(set) var picker: LogWindowController?
    private(set) var referencePicker: ReferenceBrowserWindowController?
    private(set) var directoryPanel: NSOpenPanel?
    private var retired = false
    private struct Options: Equatable {
        let values: [GitReferenceName]
        let count: Int
        let mode: FormatPatchWindowModel.Mode
        let sendMail: Bool, noPrefix: Bool
    }
    private var options: Options { Options(values: [model.directory, model.since, model.from, model.to].map { GitReferenceName($0) }, count: model.count, mode: model.mode, sendMail: model.sendMail, noPrefix: model.noPrefix) }
    private var choiceRequest: UUID?
    private var pendingDirectory: (UUID, Options, URL?)?
    var selectedDirectory: (NSOpenPanel) -> URL? = { $0.url }
    private var pendingChoice: (UUID, Options, FormatPatchWindowModel.Mode, String?)?
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var presentPicker: (NSWindow, NSWindow) -> Bool = { parent, child in
        guard parent.attachedSheet == nil else { return false }; parent.beginSheet(child); return true
    }
    var presentDirectory: (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, parent, completion in panel.beginSheetModal(for: parent, completionHandler: completion) }
    var makeLogPicker: (GitRepository, RepositoryAccessLease?, String?, UserDefaults, @escaping (LogEntry?) -> Void) -> LogWindowController = { repository, access, revision, preferences, choose in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, initialRevision: revision)
    }
    private(set) var patch: PatchWindowController?
    private var sendPatch: SendMailWorkflow?
    private let mailPreferences: UserDefaults
    private let mailPresentation: ((NSWindowController) -> Void)?
    var activeOperation: Bool { model.hasOptionSheet || model.busy || model.progress || model.confirmingCancellation || model.finishScheduled || model.composingMail || model.openingViewer }
    init(repository: GitRepository, access: RepositoryAccessLease?, preset: FormatPatchPreset? = nil, sendMail: Bool = false, preferences: UserDefaults = .standard, mailPresentation: ((NSWindowController) -> Void)? = nil) {
        mailPreferences = preferences; self.mailPresentation = mailPresentation
        model = FormatPatchWindowModel(repository: repository, access: access, preferences: preferences)
        model.apply(preset)
        if sendMail { model.sendMail = true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 365), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Format Patch – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FormatPatchDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 680, height: 365))
        window.contentMinSize = NSSize(width: 650, height: 365); window.contentMaxSize = NSSize(width: 4000, height: 365)
        window.center()
        model.close = { [weak self] in
            guard let self else { return }
            if self.model.cancelRead(closeAfter: true) { return }
            guard !self.activeOperation else { return }; self.window?.performClose(nil)
        }
        model.chooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.chooseRevision = { [weak self] target in self?.chooseRevision(target) }
        model.showPatch = { [weak self] bytes, alternate in self?.showPatch(bytes, alternate: alternate) }
        model.composeMail = { [weak self] files in self?.composeMail(files) }
        model.confirmCancellation = { [weak self] choose in
            guard let self, let window = self.window else { choose(false); return }
            let parent = window.attachedSheet ?? window
            guard parent.attachedSheet == nil else { choose(false); return }
            parent.makeFirstResponder(nil)
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: parent) { choose($0 == .alertFirstButtonReturn) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(optionSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        model.load()

        DialogGeometry.attach(window, identifier: "FormatPatchDialog", legacyName: "FormatPatchDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.cancelRead(closeAfter: true) { return false }
        guard !activeOperation && sender.attachedSheet == nil && patch?.model.busy != true && patch?.window?.attachedSheet == nil else { return false }
        return PatchDocumentSession.permitOwnerClose(patch.map { [$0] } ?? [])
    }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true
        NotificationCenter.default.removeObserver(self)
        choiceRequest = nil; pendingChoice = nil; pendingDirectory = nil; model.hasOptionSheet = false
        model.saveActionLog(); model.invalidate()
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }
        directoryPanel?.cancel(nil); directoryPanel = nil
        referencePicker?.abandonPresentation(); referencePicker = nil
        picker?.close(); picker = nil; patch?.close(); patch = nil; onClosed()
    }
    func chooseDirectory() {
        guard !retired, model.optionsAvailable, let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(nil)
        let captured = options, request = UUID()
        choiceRequest = request; model.hasOptionSheet = true
        let panel = NSOpenPanel(); directoryPanel = panel
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.title = "Output Directory"; panel.directoryURL = URL(fileURLWithPath: model.directory)
        presentDirectory(panel, window) { [weak self, weak panel] response in
            guard let self, !self.retired, self.choiceRequest == request, self.directoryPanel === panel else { return }
            let selected = response == .OK ? panel.flatMap(self.selectedDirectory) : nil
            self.directoryPanel = nil; self.pendingDirectory = (request, captured, selected)
            self.drainDirectory()
        }
    }
    private func acceptDirectory(_ folder: URL) {
        let lease = RepositoryAccessLease(url: folder)
        guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
        model.outputAccess = lease; model.directory = folder.path
    }
    func chooseRevision(_ target: FormatPatchWindowModel.Mode) {
        guard target != .number, !retired, model.optionsAvailable,
              picker == nil, referencePicker == nil, let window, window.attachedSheet == nil else { return }
        // Commit the field editor before capturing the entered range.
        window.makeFirstResponder(nil)
        let captured = options, request = UUID()
        choiceRequest = request; model.hasOptionSheet = true
        let receive: (String?) -> Void = { [weak self] value in
            guard let self, !self.retired, self.choiceRequest == request else { return }
            self.pendingChoice = (request, captured, target, value); self.drainChoice()
        }
        let child: NSWindowController
        if target == .since {
            let browser = ReferenceBrowserWindowController(repository: model.repository, access: model.access, initial: model.since, preferences: mailPreferences, scope: .excludingTags, onChoose: receive)
            referencePicker = browser; configureReferencePicker(browser.model)
            browser.onClosed = { [weak self, weak browser] in
                guard let self, self.referencePicker === browser else { return }
                self.referencePicker = nil; self.drainChoice()
            }
            child = browser
        } else {
            let revision = target == .from ? model.from : model.to
            let log = makeLogPicker(model.repository, model.access, revision.isEmpty ? nil : revision, mailPreferences) { receive($0?.hash) }
            picker = log; configureLogPicker(log.model); log.model.showWorkingTree = false
            log.onClosed = { [weak self, weak log] in
                guard let self, self.picker === log else { return }
                self.picker = nil; self.drainChoice()
            }
            child = log
        }
        guard let childWindow = child.window else { abandonChoice(); return }
        childWindow.appearance = window.appearance; childWindow.alphaValue = window.alphaValue
        guard presentPicker(window, childWindow) else { abandonChoice(); return }
        referencePicker?.model.load()
    }
    private func abandonChoice() {
        choiceRequest = nil; pendingChoice = nil; pendingDirectory = nil; model.hasOptionSheet = false
        referencePicker?.abandonPresentation(); referencePicker = nil
        picker?.close(); picker = nil
    }
    @objc private func optionSheetEnded() { drainChoice(); drainDirectory() }
    private func drainDirectory() {
        guard !retired, let pending = pendingDirectory, choiceRequest == pending.0,
              window?.attachedSheet == nil, directoryPanel == nil else { return }
        pendingDirectory = nil; choiceRequest = nil; model.hasOptionSheet = false
        guard options == pending.1, model.optionsAvailable else { return }
        if let folder = pending.2 { acceptDirectory(folder) }
        window?.makeKeyAndOrderFront(nil)
    }
    private func drainChoice() {
        guard !retired, let pending = pendingChoice, choiceRequest == pending.0,
              window?.attachedSheet == nil, referencePicker == nil, picker == nil else { return }
        pendingChoice = nil; choiceRequest = nil; model.hasOptionSheet = false
        guard options == pending.1, model.optionsAvailable else { return }
        if let value = pending.3 {
            switch pending.2 {
            case .since: model.since = value; model.mode = .since
            case .from: model.from = value; model.mode = .from
            case .to: model.to = value; model.mode = .from
            case .number: break
            }
        }
        window?.makeKeyAndOrderFront(nil)
    }
    private func showPatch(_ bytes: Data, alternate: Bool) {
        guard !retired, patch?.model.busy != true, patch?.window?.attachedSheet == nil else { return }
        let preferences = UnifiedDiffViewerPreferences.load(from: mailPreferences)
        do {
            if case .external(let application) = try preferences.choice(alternate: alternate) {
                let preview = try UnifiedDiffPreview.create(bytes)
                UnifiedDiffPreviewFiles.retain(preview)
                model.openingViewer = true
                UnifiedDiffApplication.open(preview.file, application: application, bookmark: preferences.bookmark) { [weak model] error in
                    model?.openingViewer = false
                    if let error { UnifiedDiffPreviewFiles.discard(preview.file); if model?.isRetired == false { model?.error = error } }
                }
                return
            }
        } catch { model.error = error.localizedDescription; return }
        let controller = patch ?? PatchWindowController(repository: model.repository, access: model.access)
        controller.presentDocument(bytes, title: "Unified Diff – TurtleGit", comparison: "HEAD → Working tree",
            information: "Unified diff since HEAD. Right-click to save the patch.", refreshAvailable: true, refresh: { [weak model = model, weak controller] in
                guard let controller else { return }; let identity = controller.documentSession.documentIdentity
                model?.unifiedDiff(onResult: { [weak controller] bytes in
                    guard let controller, controller.documentSession.documentIdentity == identity else { return }
                    controller.documentSession.replace(bytes)
                })
            })
        controller.onClosed = { [weak self] in self?.patch = nil }
        controller.window?.appearance = window?.appearance; controller.window?.alphaValue = window?.alphaValue ?? 1
        patch = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func composeMail(_ files: [URL]) {
        guard !files.isEmpty else { model.error = "No patches were created to attach."; return }
        do {
            model.composingMail = true
            let leases = [model.access, model.outputAccess].compactMap { $0 }
            let workflow = SendMailWorkflow(files: files, repository: model.repository, access: model.access,
                fileAccess: leases, preferences: mailPreferences, presentation: mailPresentation) { [weak self] _ in
                guard let self else { return }; self.sendPatch = nil; self.model.composingMail = false
                // Format Patch reports export success independently of mail outcome.
                // The retained mail result has already been reviewed before close.
                self.model.close()
            }
            sendPatch = workflow; workflow.start(); return
        }

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class FormatPatchWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    enum Mode: Equatable { case since, number, from, to }
    @Published var hasOptionSheet = false
    var optionsAvailable: Bool { !invalidated && !hasOptionSheet && !busy && !progress && !finishScheduled && !confirmingCancellation && !composingMail && !openingViewer }
    var isRetired: Bool { invalidated }
    private var readCancellation: OperationCancellation?
    private var closeAfterRead = false
    func cancelRead(closeAfter: Bool = false) -> Bool {
        guard let token = readCancellation else { return false }
        closeAfterRead = closeAfterRead || closeAfter; token.cancel(); return true
    }
    private func beginRead() -> OperationCancellation {
        let token = OperationCancellation(); readCancellation = token; busy = true; Self.activeOperations += 1; return token
    }
    private func finishRead(_ token: OperationCancellation) {
        Self.activeOperations -= 1; withExtendedLifetime(access) {}
        guard readCancellation === token else { return }
        readCancellation = nil; busy = false
        if closeAfterRead, !invalidated { closeAfterRead = false; close() }
    }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    var outputAccess: RepositoryAccessLease?
    @Published var directory: String
    @Published var since: String
    @Published var from: String
    @Published var to: String
    @Published var count = 1
    @Published var mode = Mode.since
    @Published var sendMail: Bool
    @Published var noPrefix: Bool
    @Published var busy = false
    @Published var composingMail = false
    @Published var openingViewer = false
    @Published var hasHead = false
    @Published var bare = false
    @Published var references: [String] = []
    @Published var error: String?
    @Published var progress = false
    @Published var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange: NSRange?
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    var actionLogEligible: Bool { !busy && !invalidated && (progress || !output.isEmpty) }
    var canCancel: Bool { busy && cancellation != nil && !cancelRequested && !confirmingCancellation && !invalidated }
    @Published var success = false
    @Published var cancelRequested = false
    @Published var cancelled = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var finishScheduled = false
    let preferences: UserDefaults
    private var invalidated = false
    private var progressClosePolicy = GitProgressAutoClose.manual
    private var cancellation: OperationCancellation?
    private var files: [URL] = []
    private var exportSendMail = false
    var close: () -> Void = {}
    var chooseDirectory: () -> Void = {}
    var chooseRevision: (Mode) -> Void = { _ in }
    var showPatch: (Data, Bool) -> Void = { _, _ in }
    var composeMail: ([URL]) -> Void = { _ in }
    var onOutputChanged: (String) -> Void = { _ in }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    func invalidate() { invalidated = true; readCancellation?.cancel(); confirmingCancellation = false; progress = false; cancellation?.cancel() }
    func apply(_ preset: FormatPatchPreset?) {
        guard let preset, optionsAvailable else { return }
        from = preset.from; to = preset.to
        switch preset.selection {
        case .since(let value): since = value; mode = .since
        case .range: mode = .from
        case .number(let value): count = value; mode = .number
        }
    }
    var dirs: [String] { preferences.stringArray(forKey: "FormatPatchDirectories") ?? [] }
    var fromHistory: [String] { preferences.stringArray(forKey: "FormatPatchFrom") ?? [] }
    var toHistory: [String] { preferences.stringArray(forKey: "FormatPatchTo") ?? [] }
    private var sinceKey: String { "FormatPatchSince:" + repository.root.path }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences; outputState = GitProgressOutputState(preferences: preferences); directory = repository.root.path
        let defaults = preferences
        since = defaults.string(forKey: "FormatPatchSince:" + repository.root.path) ?? ""
        from = defaults.stringArray(forKey: "FormatPatchFrom")?.first ?? ""
        to = defaults.stringArray(forKey: "FormatPatchTo")?.first ?? ""
        sendMail = defaults.bool(forKey: "FormatPatchSendMail"); noPrefix = defaults.bool(forKey: "FormatPatchNoPrefix")
    }
    func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        guard optionsAvailable else { return }
        let token = beginRead()
        Task {
            defer { finishRead(token) }
            do {
                try checkAccess()
                let head = try await repository.run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], successfulExitCodes: 0...1, cancellation: token).exitCode == 0
                let isBare = try await repository.isBare(cancellation: token)
                let names = try await repository.checkoutReferences(includeFetchHead: preferences.includesFetchHead, localBranchesFirst: AdvancedListBehavior(defaults: preferences).localBranchesFirst, cancellation: token).filter { !$0.name.hasPrefix("refs/tags/") && $0.symbolicTarget == nil }.map(\.name)
                guard !invalidated, !token.isCancelled else { return }
                hasHead = head; bare = isBare; references = names
            } catch { if !invalidated && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func remember(_ value: String, key: String) {
        guard !value.isEmpty else { return }
        let old = preferences.stringArray(forKey: key) ?? []
        preferences.set(Array(([value] + old.filter { !GitReferenceName.equal($0, value) }).prefix(25)), forKey: key)
    }
    var valid: Bool { hasHead && !directory.isEmpty && (mode == .number ? (1...Int(Int32.max)).contains(count) : (mode == .since ? !since.isEmpty : !from.isEmpty && !to.isEmpty)) }
    var progressStatus: String {
        if busy { return cancelRequested ? "Stopping Git…" : "Creating patches…" }
        if cancelled { return "Cancelled" }
        return success ? "Finished" : "Failed"
    }
    func export() {
        guard optionsAvailable, valid else { return }
        let folder = URL(fileURLWithPath: directory).standardizedFileURL
        if GitRuntime.isAppStoreBuild && !((access?.hasSecurityScope == true && access?.contains(folder) == true) || (outputAccess?.hasSecurityScope == true && outputAccess?.contains(folder) == true)) { chooseDirectory(); return }
        let selection: FormatPatchSelection = mode == .since ? .since(since) : mode == .number ? .number(count) : .range(from: from, to: to)
        let prefix = noPrefix, capturedOutputAccess = outputAccess; exportSendMail = sendMail
        remember(directory, key: "FormatPatchDirectories"); remember(from, key: "FormatPatchFrom"); remember(to, key: "FormatPatchTo")
        if mode == .since { preferences.set(since, forKey: sinceKey) }
        preferences.set(sendMail, forKey: "FormatPatchSendMail"); preferences.set(prefix, forKey: "FormatPatchNoPrefix")
        progressClosePolicy = GitProgressAutoClose(preferences: preferences)
        ProgressActionLog.nextAttempt(self, savePrevious: !output.isEmpty)
        outputState = GitProgressOutputState(preferences: preferences)
        busy = true; progress = true; success = false; output = ""; files = []
        currentWork = ""; percentage = nil; completionRange = nil
        cancelRequested = false; cancelled = false
        let token = OperationCancellation(); cancellation = token
        Self.activeOperations += 1
        let startedAt = ProcessInfo.processInfo.systemUptime
        Task {
            var exitCode: Int32?
            defer {
                Self.activeOperations -= 1; withExtendedLifetime(access) {}; withExtendedLifetime(capturedOutputAccess) {}
                busy = false; cancellation = nil
                if !invalidated {
                    let completion = SubmoduleProgressCompletion(success: success, cancelled: cancelled, exitCode: exitCode,
                        elapsed: ProcessInfo.processInfo.systemUptime - startedAt, preferences: preferences)
                    currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &output)
                    onOutputChanged(output); finishAutomatically()
                }
            }
            do {
                try checkAccess()
                let parser = GitCliOutputParser(limit: outputState.limit)
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.formatPatch(selection: selection, to: folder, noPrefix: prefix, cancellation: token, onOutput: { chunk in
                        parser.appendChunk(chunk.data); continuation.yield(())
                    })
                }
                for await _ in updates { consume(parser.processPending(), parser: parser) }
                consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
                let result = try await operation.value
                guard !invalidated else { return }
                guard !token.isCancelled else { cancelled = true; appendDiagnostic("Operation cancelled. Any patches written before cancellation remain in the output directory."); return }
                if !outputState.hasOutput { appendDiagnostic("No patches created for this selection.") }
                // Use the full stdout, independently of the visible output limit.
                // A newline in the directory remains literal; Git sanitizes names.
                let resolved = folder.resolvingSymlinksInPath()
                files = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: resolved.path + "/").dropFirst().compactMap { part in
                    let name = part.hasSuffix("\n") ? String(part.dropLast()) : part
                    guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), name != ".", name != ".." else { return nil }
                    let file = resolved.appendingPathComponent(name)
                    return FileManager.default.fileExists(atPath: file.path) ? file : nil
                }
                success = true; exitCode = 0
            } catch let failure as GitCommandCancellationFailure {
                cancelled = true; exitCode = failure.result.exitCode
                if !invalidated { appendDiagnostic("Operation cancelled. Any patches written before cancellation remain in the output directory.") }
            } catch is OperationCancellationFailure {
                cancelled = true
                if !invalidated { appendDiagnostic("Operation cancelled. Any patches written before cancellation remain in the output directory.") }
            } catch {
                exitCode = (error as? GitFailure)?.code
                let alreadyStreamed = outputState.hasOutput && (error as? GitFailure)?.arguments.first == "format-patch"
                if !invalidated && !alreadyStreamed { appendDiagnostic(error.localizedDescription) }
            }
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard !invalidated else { return }
        outputState.consume(emission, parser: parser); output = outputState.output
        currentWork = outputState.currentWork; percentage = outputState.percentage
    }
    private func appendDiagnostic(_ text: String) {
        let parser = GitCliOutputParser(limit: outputState.limit)
        parser.appendChunk(Data(((output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + text).utf8))
        consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser)
    }
    private func finishAutomatically() {
        if !busy, !confirmingCancellation, !invalidated,
           progressClosePolicy.shouldClose(success: success, postActionCount: 0) { finish() }
    }
    func cancelExport() {
        guard busy, let token = cancellation, !cancelRequested, !confirmingCancellation, !invalidated else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, self.confirmingCancellation, !self.invalidated else { return }; self.confirmingCancellation = false
                if self.busy, self.cancellation === token, accepted { self.cancelRequested = true; token.cancel() }
                self.finishAutomatically()
            }
        } else { cancelRequested = true; token.cancel() }
    }
    func finish() {
        guard !busy, progress, !confirmingCancellation, !finishScheduled, !invalidated else { return }; saveActionLog(); progress = false
        guard success else { return }
        finishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.finishScheduled = false
            guard !self.invalidated else { return }
            if self.exportSendMail { self.composeMail(self.files) } else { self.close() }
        }
    }
    func unifiedDiff(alternate: Bool = false, onResult: ((Data) -> Void)? = nil) {
        guard optionsAvailable, hasHead, !bare else { return }
        let prefix = noPrefix
        preferences.set(prefix, forKey: "FormatPatchNoPrefix"); let token = beginRead()
        Task {
            defer { finishRead(token) }
            do {
                try checkAccess()
                let result = try await repository.run(["diff", "--no-ext-diff", "--no-color", "--stat", "--patch"] + (prefix ? ["--no-prefix"] : []) + ["--end-of-options", "HEAD", "--"], cancellation: token)
                guard !invalidated, !token.isCancelled else { return }
                if let onResult { onResult(result.stdout) } else { showPatch(result.stdout, alternate) }
            } catch { if !invalidated && !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct FormatPatchDialog: View {
    @ObservedObject var model: FormatPatchWindowModel
    func radio(_ title: String, mode: FormatPatchWindowModel.Mode) -> some View {
        FormatPatchRadio(title: title, selected: model.mode == mode) { model.mode = mode }.frame(width: 145, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Output Directory") { HStack {
                Text("Directory:").frame(width: 90, alignment: .leading)
                FormatPatchCombo(value: $model.directory, choices: model.dirs, label: "Output directory")
                Button("…") { model.chooseDirectory() }.accessibilityLabel("Choose output directory")
            }.padding(8) }
            GroupBox("Version") { VStack(spacing: 8) {
                HStack { radio("Since", mode: .since)
                    FormatPatchCombo(value: $model.since, choices: model.references, label: "Since revision").disabled(model.mode != .since)
                    Button("…") { model.chooseRevision(.since) }.accessibilityLabel("Browse branches").disabled(model.mode != .since)
                }
                HStack { radio("Number Commits", mode: .number)
                    TextField("Commit count", value: $model.count, format: .number.grouping(.never)).disabled(model.mode != .number)
                    Stepper("", value: $model.count, in: 1...Int(Int32.max)).labelsHidden().disabled(model.mode != .number)
                }
                HStack { radio("Range", mode: .from); Text("From:").frame(width: 40, alignment: .leading)
                    FormatPatchCombo(value: $model.from, choices: model.fromHistory, label: "From revision").disabled(model.mode != .from)
                    Button("…") { model.chooseRevision(.from) }.accessibilityLabel("Choose From commit").disabled(model.mode != .from)
                }
                HStack { Color.clear.frame(width: 145); Text("To:").frame(width: 40, alignment: .leading)
                    FormatPatchCombo(value: $model.to, choices: model.toHistory, label: "To revision").disabled(model.mode != .from)
                    Button("…") { model.chooseRevision(.to) }.accessibilityLabel("Choose To commit").disabled(model.mode != .from)
                }
            }.padding(8) }
            Toggle("Send Mail after create", isOn: $model.sendMail)
            Toggle("No a/ and b/ prefixes", isOn: $model.noPrefix)
            HStack {
                Button("Save unified diff since HEAD") { model.unifiedDiff(alternate: NSEvent.modifierFlags.contains(.shift)) }.disabled(!model.hasHead || model.bare)
                Spacer(); if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Button("OK") { model.export() }.keyboardShortcut(.defaultAction).disabled(!model.valid)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                    .environment(\.isEnabled, !model.isRetired && !model.hasOptionSheet && !model.progress && !model.finishScheduled && !model.composingMail && !model.openingViewer)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-patch.html")!) }
            }
        }.padding(16).disabled(!model.optionsAvailable)
        .alert("Format Patch", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.progress) {
            FormatPatchProgressDialog(model: model).environment(\.isEnabled, true)
                .interactiveDismissDisabled()
                .onExitCommand { if model.busy { model.cancelExport() } else { model.finish() } }
        }
    }
}

struct FormatPatchProgressDialog: View {
    @ObservedObject var model: FormatPatchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                .tint(model.busy ? .accentColor : model.success ? .blue : .red).accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, completionRange: model.completionRange, success: model.success)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Text(model.progressStatus).foregroundStyle(model.busy ? Color.primary : model.success ? .green : .red)
                Spacer()
                Button("Close") { model.finish() }.keyboardShortcut(.defaultAction).disabled(model.busy || model.confirmingCancellation)
                Button("Abort") { if model.busy { model.cancelExport() } else { model.finish() } }.keyboardShortcut(.cancelAction)
                    .disabled(model.success || model.confirmingCancellation || model.busy && !model.canCancel)
            }
        }.padding(16).frame(minWidth: 650, idealWidth: 760, minHeight: 320, idealHeight: 430)
    }
}

private struct FormatPatchRadio: NSViewRepresentable {
    let title: String; let selected: Bool; let select: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked)) }
    func updateNSView(_ button: NSButton, context: Context) { button.state = selected ? .on : .off; button.isEnabled = enabled; context.coordinator.select = select }
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked() { select() } }
}

private struct FormatPatchCombo: NSViewRepresentable {
    @Binding var value: String; let choices: [String]; let label: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox { let view = NSComboBox(); view.delegate = context.coordinator; view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    func updateNSView(_ view: NSComboBox, context: Context) {
        let c = context.coordinator; c.updating = true; defer { c.updating = false }; c.change = { value = $0 }
        if c.choices != choices { view.removeAllItems(); view.addItems(withObjectValues: choices); c.choices = choices }
        if view.stringValue != value { view.stringValue = value }; view.isEnabled = enabled; view.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var updating = false; var choices: [String] = []; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let view = notification.object as? NSComboBox else { return }; change(view.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let view = notification.object as? NSComboBox, choices.indices.contains(view.indexOfSelectedItem) else { return }; change(choices[view.indexOfSelectedItem]) }
    }
}
