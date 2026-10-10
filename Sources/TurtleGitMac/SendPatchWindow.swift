// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SendMailDlg; see NOTICE and SEND-PATCH-PARITY.md.
import AppKit
import SwiftUI
import TurtleGitCore

struct SendPatchRow: Identifiable, Equatable { let id = UUID(); let file: URL }
struct SendPatchRequest: Sendable {
    let files: [URL]
    let options: PatchMailOptions
    let messages: [PatchMailMessage]
    let delivery: EmailConfiguration
}

@MainActor final class SendPatchWindowModel: ObservableObject {
    enum Delivery { case mailClient, smtp }
    @Published private(set) var rows: [SendPatchRow]
    @Published private(set) var checked: Set<UUID>
    @Published private(set) var highlighted: Set<UUID>
    @Published var to = ""
    @Published var cc = ""
    @Published var combinedSubject = ""
    @Published var attachment: Bool
    @Published var combine: Bool
    @Published private(set) var previewSubject = ""
    @Published private(set) var previewBusy = false
    @Published private(set) var busy = false
    @Published private(set) var pendingLoads = 0
    @Published var error: String?
    private let deliveryOverride: Delivery?
    var delivery: Delivery { capturedDelivery().delivery == .mailClient ? .mailClient : .smtp }
    private let preferences: UserDefaults
    private var access: [RepositoryAccessLease]
    private var invalidated = false, submitted = false
    private var previewGeneration = UUID()
    private var previewWork: Task<SerialPatch, Error>?
    private var preparationWork: Task<[PatchMailMessage], Error>?
    private var previews: [UUID: String] = [:]
    @Published var onSubmit: ((SendPatchRequest) -> Void)?
    var close: () -> Void = {}
    var endEditing: () -> Void = {}
    @Published var showPatch: ((URL) -> Void)?
    @Published var showAlternatePatch: ((URL) -> Void)?
    @Published var reviewPatch: ((URL) -> Void)?
    @Published var applyPatches: (([URL]) -> Void)?
    @Published var showSettings: (() -> Void)?
    var addresses: [String] { preferences.stringArray(forKey: "SendMail.Addresses") ?? [] }
    var subject: String { combine ? combinedSubject : previewSubject }
    var canSubmit: Bool { !invalidated && !submitted && !busy && onSubmit != nil }
    var canInteract: Bool { !invalidated && !submitted && !busy }

    init(files: [URL], delivery: Delivery? = nil, access: [RepositoryAccessLease] = [], preferences: UserDefaults = .standard) {
        let initial = files.map { SendPatchRow(file: $0) }
        rows = initial; checked = Set(initial.map(\.id)); highlighted = initial.count == 1 ? Set(initial.map(\.id)) : []
        self.deliveryOverride = delivery; self.access = access; self.preferences = preferences
        attachment = preferences.bool(forKey: "SendMail.Attach"); combine = preferences.bool(forKey: "SendMail.Combine")
    }
    private func capturedDelivery() -> EmailConfiguration {
        // Upstream SendMail/SendMailDlg use MAPI when the preference is absent;
        // the settings page separately defaults to direct SMTP.
        var configuration = EmailConfiguration(preferences: preferences, missingDelivery: .mailClient)
        if let deliveryOverride {
            if deliveryOverride == .mailClient { configuration.delivery = .mailClient }
            else if configuration.delivery == .mailClient { configuration.delivery = .direct }
        }
        return configuration
    }
    func setChecked(_ ids: Set<UUID>) { guard canInteract else { return }; checked = ids.intersection(rows.map(\.id)) }
    func setHighlighted(_ ids: Set<UUID>) {
        guard canInteract else { return }; highlighted = ids.intersection(rows.map(\.id)); refreshPreview()
    }
    func combineChanged() { guard canInteract else { return }; refreshPreview() }
    private func checkAccess(_ files: [URL]) throws {
        if GitRuntime.isAppStoreBuild && !files.allSatisfy({ file in access.contains { $0.hasSecurityScope && $0.contains(file) } }) {
            throw RepositoryAccessFailure.securityScopeUnavailable
        }
    }
    func refreshPreview() {
        guard canInteract else { return }
        previewWork?.cancel(); previewGeneration = UUID(); previewBusy = false
        guard !combine, highlighted.count == 1, let row = rows.first(where: { highlighted.contains($0.id) }) else { previewSubject = ""; return }
        if let cached = previews[row.id] { previewSubject = cached; return }
        do { try checkAccess([row.file]) } catch { previewSubject = ""; self.error = error.localizedDescription; return }
        previewSubject = ""; previewBusy = true; pendingLoads += 1
        let generation = previewGeneration, file = row.file
        let work = Task.detached { try Task.checkCancellation(); let patch = try SerialPatch(file: file); try Task.checkCancellation(); return patch }
        previewWork = work
        Task {
            defer { pendingLoads -= 1 }
            do {
                let patch = try await work.value
                guard !invalidated, generation == previewGeneration else { return }
                previews[row.id] = patch.subject; previewSubject = patch.subject
            } catch {
                if !invalidated && generation == previewGeneration && !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if generation == previewGeneration { previewBusy = false; previewWork = nil }
        }
    }
    func submit() {
        guard canSubmit, let onSubmit else { return }
        endEditing(); guard canSubmit else { return }
        previewWork?.cancel(); previewWork = nil; previewGeneration = UUID(); previewBusy = false
        let files = rows.filter { checked.contains($0.id) }.map(\.file)
        let deliverySnapshot = capturedDelivery()
        var options = PatchMailOptions(); options.to = to; options.cc = cc; options.subject = combinedSubject
        options.attachment = attachment; options.combine = combine
        do {
            try checkAccess(files)
            if deliverySnapshot.delivery != .mailClient && (to + ";" + cc).split(separator: ";").allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                error = "Enter at least one To or CC address."; return
            }
        } catch { self.error = error.localizedDescription; return }
        let headerFields = [options.to, options.cc] + (options.combine ? [options.subject] : [])
        guard headerFields.allSatisfy({ $0.utf8.allSatisfy { $0 != 13 && $0 != 10 && $0 != 0 } }) else {
            error = PatchMailPreparationFailure.header.localizedDescription; return
        }
        remember(options)
        if files.isEmpty { submitted = true; close(); return }
        busy = true; error = nil; pendingLoads += 1
        let snapshot = options
        let work = Task.detached {
            var patches: [SerialPatch] = []
            for file in files { try Task.checkCancellation(); patches.append(try SerialPatch(file: file)) }
            let messages = try PatchMailPreparation.messages(patches: patches, options: snapshot)
            try Task.checkCancellation(); return messages
        }
        preparationWork = work
        Task {
            defer { busy = false; pendingLoads -= 1; preparationWork = nil }
            do {
                let messages = try await work.value
                guard !invalidated, !submitted else { return }
                submitted = true
                onSubmit(SendPatchRequest(files: files, options: snapshot, messages: messages, delivery: deliverySnapshot)); close()
            } catch { if !invalidated && !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    private func remember(_ options: PatchMailOptions) {
        preferences.set(options.attachment, forKey: "SendMail.Attach"); preferences.set(options.combine, forKey: "SendMail.Combine")
        var history = addresses
        // Upstream shares To/CC history, adds CC first then To, newest first.
        for value in (options.cc + ";" + options.to).split(separator: ";") {
            let address = value.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { continue }
            history.removeAll { $0 == address }; history.insert(address, at: 0)
        }
        preferences.set(Array(history.prefix(0xFFFF)), forKey: "SendMail.Addresses")
    }
    /// CPatchListCtrl appends checked non-directory paths, suppressing dropped
    /// duplicates without rechecking an existing unchecked row.
    func appendDroppedFiles(_ files: [URL]) -> Bool {
        guard canInteract else { return false }
        var known = Set(rows.map { $0.file.standardizedFileURL.path }), added: [SendPatchRow] = []
        for file in files where file.isFileURL {
            let path = file.standardizedFileURL.path
            guard !known.contains(path) else { continue }
            let lease = RepositoryAccessLease(url: file)
            if GitRuntime.isAppStoreBuild && !lease.hasSecurityScope && !access.contains(where: { $0.hasSecurityScope && $0.contains(file) }) {
                error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; continue
            }
            var directory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            guard !directory.boolValue else { continue }
            known.insert(path); added.append(SendPatchRow(file: file)); access.append(lease)
        }
        guard !added.isEmpty else { return false }
        rows.append(contentsOf: added); checked.formUnion(added.map(\.id)); return true
    }
    func review(_ id: UUID) {
        guard canInteract, let row = rows.first(where: { $0.id == id }) else { return }; reviewPatch?(row.file)
    }
    func apply(_ ids: Set<UUID>) {
        guard canInteract else { return }
        let files = rows.filter { ids.contains($0.id) }.map(\.file)
        guard !files.isEmpty else { return }; applyPatches?(files)
    }
    func openPatch(_ id: UUID, alternate: Bool = false) {
        guard canInteract, let row = rows.first(where: { $0.id == id }) else { return }
        if alternate, let showAlternatePatch { showAlternatePatch(row.file) } else { showPatch?(row.file) }
    }
    func cancel() { guard !invalidated && !submitted else { return }; endEditing(); guard !invalidated && !submitted else { return }; invalidate(); close() }
    func invalidate() { invalidated = true; previewGeneration = UUID(); previewBusy = false; previewWork?.cancel(); preparationWork?.cancel() }
}

@MainActor final class SendPatchWindowController: NSWindowController, NSWindowDelegate {
    let model: SendPatchWindowModel
    var onClosed: () -> Void = {}
    init(files: [URL], delivery: SendPatchWindowModel.Delivery? = nil, access: [RepositoryAccessLease] = [], preferences: UserDefaults = .standard,
         settingsPresenter: ((UserDefaults) -> Void)? = nil) {
        model = SendPatchWindowModel(files: files, delivery: delivery, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Send Patch – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 620, height: 380)
        window.contentViewController = NSHostingController(rootView: SendPatchDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }; model.endEditing = { [weak window] in window?.makeFirstResponder(nil) }; model.refreshPreview()
        model.showSettings = { [weak model] in
            guard model?.canInteract == true else { return }
            model?.endEditing()
            if let settingsPresenter { settingsPresenter(preferences) }
            else { EmailSettingsWindowController.present(preferences: preferences) }
        }
        DialogGeometry.attach(window, identifier: "SendPatchDialog", legacyName: "SendPatchDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct SendPatchDialog: View {
    @ObservedObject var model: SendPatchWindowModel
    var body: some View {
        VStack(spacing: 10) {
            GroupBox("Mail") {
                VStack(spacing: 8) {
                    HStack { Text("To:").frame(width: 60, alignment: .leading); SendPatchAddressField(value: $model.to, choices: model.addresses, label: "To addresses") }
                    HStack { Text("CC:").frame(width: 60, alignment: .leading); SendPatchAddressField(value: $model.cc, choices: model.addresses, label: "CC addresses") }
                    HStack { Text("Subject:").frame(width: 60, alignment: .leading)
                        TextField("", text: Binding(get: { model.subject }, set: { if model.combine { model.combinedSubject = $0 } })).disabled(!model.combine)
                    }
                }.padding(8)
            }.disabled(!model.canInteract)
            HStack {
                Toggle("Patch As Attachment", isOn: $model.attachment)
                Toggle("Combine One Mail", isOn: Binding(get: { model.combine }, set: { model.endEditing(); model.combine = $0; model.combineChanged() }))
                Spacer()
                Button("eMail settings") { model.showSettings?() }.buttonStyle(.link).disabled(model.showSettings == nil)
            }.disabled(!model.canInteract)
            SendPatchList(model: model).disabled(!model.canInteract).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.error { Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack {
                if model.busy || model.previewBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Send") { model.submit() }.keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-patch.html")!) }
            }
        }.padding(16).frame(minWidth: 620, minHeight: 380)
    }
}

struct SendPatchAddressField: NSViewRepresentable {
    @Binding var value: String; let choices: [String]; let label: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let view = NSComboBox(); view.delegate = context.coordinator; view.usesDataSource = true; view.dataSource = context.coordinator; view.completes = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }
    func updateNSView(_ view: NSComboBox, context: Context) {
        let c = context.coordinator; c.updating = true; defer { c.updating = false }
        c.change = { value = $0 }
        if c.choices != choices { c.choices = choices; view.reloadData() }
        if view.stringValue != value { view.stringValue = value }; view.isEnabled = enabled; view.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSComboBoxDelegate, NSComboBoxDataSource {
        var updating = false; var choices: [String] = []; var change: (String) -> Void = { _ in }
        func numberOfItems(in comboBox: NSComboBox) -> Int { choices.count }
        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? { choices.indices.contains(index) ? choices[index] : nil }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let view = notification.object as? NSComboBox else { return }; change(view.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let view = notification.object as? NSComboBox, choices.indices.contains(view.indexOfSelectedItem) else { return }; change(choices[view.indexOfSelectedItem]) }
        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            let end = string.lastIndex(of: ";").map { string.index(after: $0) } ?? string.startIndex
            let suffix = String(string[end...]), trimmed = suffix.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let match = choices.first(where: { $0.lowercased().hasPrefix(trimmed.lowercased()) }) else { return nil }
            return String(string[..<end]) + String(suffix.prefix { $0 == " " || $0 == "\t" }) + match
        }
    }
}

/// Configured-server orchestration only. Captured delivery and message bytes
/// come from Send; preferences, files and credentials are never reread on retry.
enum SendPatchSMTPDelivery {
    typealias SenderSource = @Sendable (OperationCancellation) async throws -> PatchMailSender
    typealias Transport = @Sendable ([PatchMailMessage], PatchMailSender, SMTPServer, SMTPAuthentication?, OperationCancellation, @escaping @Sendable (SMTPSeriesProgress) -> Void) async throws -> [SMTPReceipt]
    @MainActor static func send(_ request: SendPatchRequest, repository: GitRepository, access: RepositoryAccessLease?,
                               credentials: any SMTPTransportCredentialSource = SMTPKeychainStore(),
                               cancellation: OperationCancellation,
                               onProgress: @escaping @Sendable (SMTPSeriesProgress) -> Void) async throws -> [SMTPReceipt] {
        if GitRuntime.isAppStoreBuild {
            guard access?.hasSecurityScope == true, access?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
        }
        defer { withExtendedLifetime(access) {} }
        return try await send(request, credentials: credentials, cancellation: cancellation, onProgress: onProgress,
                              sender: { try await repository.patchMailSender(cancellation: $0) },
                              transport: { messages, sender, server, authentication, token, progress in
            try await PatchMailSMTP.sendSeries(messages: messages, sender: sender, server: server,
                                               authentication: authentication, cancellation: token, onProgress: progress)
        })
    }
    static func send(_ request: SendPatchRequest, credentials: any SMTPTransportCredentialSource,
                     cancellation: OperationCancellation, onProgress: @escaping @Sendable (SMTPSeriesProgress) -> Void,
                     sender: SenderSource, transport: Transport) async throws -> [SMTPReceipt] {
        return try await withTaskCancellationHandler(operation: {
            func check() throws {
                if cancellation.isCancelled || Task.isCancelled { throw OperationCancellationFailure.cancelled }
            }
            try check()
            guard request.delivery.delivery == .configured else { throw SendPatchSMTPDeliveryFailure.delivery }
            var server = SMTPServer(host: request.delivery.server, port: Int(request.delivery.port),
                                    encryption: SMTPEncryption(rawValue: Int32(request.delivery.encryption.rawValue)) ?? .none)
            // Credentials are fetched only after server, sender and all messages
            // validate; retries retain this one atomic pair.
            server.trustedCertificates = nil
            try PatchMailSMTP.validate(server: server)
            guard !request.messages.isEmpty else { return [] }
            let identity = try await sender(cancellation); try check()
            for message in request.messages {
                guard !(message.to + message.cc).isEmpty else { throw SMTPFailure.recipients }
                _ = try (message.to + message.cc).map { try PatchMailMIME.envelopeAddress($0) }
                _ = try PatchMailMIME.data(message: message, sender: identity)
                try check()
            }
            let authentication: SMTPAuthentication?
            if request.delivery.authenticate {
                guard let pair = try await credentials.credentials() else { throw SendPatchSMTPDeliveryFailure.credentials }
                try check()
                authentication = SMTPAuthentication(login: pair.login, password: pair.password)
                try PatchMailSMTP.validate(server: server, authentication: authentication)
            } else { authentication = nil }
            try check()
            return try await transport(request.messages, identity, server, authentication, cancellation, onProgress)
        }, onCancel: { cancellation.cancel() })
    }
}
enum SendPatchSMTPDeliveryFailure: LocalizedError {
    case delivery, credentials
    var errorDescription: String? {
        switch self {
        case .delivery: return "This operation requires configured SMTP delivery."
        case .credentials: return "Store SMTP credentials in Email settings before sending with authentication."
        }
    }
}

/// Preserve notification order while coalescing frequent byte progress updates.
private final class SendPatchProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SMTPSeriesProgress] = [], upload: SMTPSeriesProgress?
    func append(_ event: SMTPSeriesProgress) {
        lock.lock(); defer { lock.unlock() }
        if case .upload = event { upload = event } else { events.append(event) }
    }
    func drain() -> [SMTPSeriesProgress] {
        lock.lock(); defer { lock.unlock() }
        let result = events + (upload.map { [$0] } ?? []); events.removeAll(); upload = nil; return result
    }
}
@MainActor final class SendPatchProgressModel: ObservableObject, ActionLogProgress {
    typealias Submission = @MainActor (OperationCancellation, @escaping @Sendable (SMTPSeriesProgress) -> Void) async throws -> [SMTPReceipt]
    let repository: GitRepository
    let total: Int
    private let files: [URL], combined: Bool
    @Published private(set) var notifications: [SendPatchNotification] = []
    var notificationPreferences: UserDefaults { preferences }
    private let submission: Submission, preferences: UserDefaults, policy: GitProgressAutoClose
    private let token = OperationCancellation()
    private var started = false, invalidated = false, logBytes = 0
    private let logLimit: Int
    @Published private(set) var busy = false
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var accepted = 0
    @Published private(set) var currentIndex = 0
    @Published private(set) var percentage = 0
    @Published private(set) var currentWork = ""
    @Published private(set) var output = ""
    @Published private(set) var error: String?
    @Published private(set) var completionRange: NSRange?
    @Published private(set) var confirmingCancellation = false
    var close: () -> Void = {}
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var activeOperation: Bool { busy || confirmingCancellation }
    var actionLogRepository: URL { repository.root }
    var actionLogCancelled: Bool { cancelled }
    var actionLogEligible: Bool { started && !busy && !invalidated }
    init(request: SendPatchRequest, repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, submission: Submission? = nil) {
        self.repository = repository; total = request.messages.count; self.preferences = preferences
        files = request.files; combined = request.options.combine
        policy = GitProgressAutoClose(preferences: preferences); logLimit = GitProgressOutputState(preferences: preferences).limit
        self.submission = submission ?? { token, progress in
            try await SendPatchSMTPDelivery.send(request, repository: repository, access: access, cancellation: token, onProgress: progress)
        }
    }
    func start() {
        guard !started, !invalidated else { return }; started = true; busy = true; currentWork = "Capturing sender and credentials…"
        notify(action: "Command", path: "Send Email", kind: .command)
        let began = ProcessInfo.processInfo.systemUptime, mailbox = SendPatchProgressMailbox()
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task {
            let work = Task {
                defer { continuation.finish() }
                return try await submission(token, { event in mailbox.append(event); continuation.yield(()) })
            }
            for await _ in updates { if !invalidated { mailbox.drain().forEach(consume) } }
            if !invalidated { mailbox.drain().forEach(consume) }
            do {
                let receipts = try await work.value
                guard !invalidated else { busy = false; return }
                accepted = receipts.count; success = receipts.count == total
                if !success { error = "The transport returned an incomplete acceptance result."; append("error: " + error!)
                    notify(action: "Error", path: error!, kind: .error) }
            } catch {
                guard !invalidated else { busy = false; return }
                if let failure = error as? SMTPSeriesFailure { accepted = failure.accepted.count; currentIndex = failure.index }
                self.error = error.localizedDescription
                var uncertain = false
                if let failure = error as? SMTPSeriesFailure, case SMTPFailure.transfer(_, _, true) = failure.cause { uncertain = true }
                cancelled = token.isCancelled && !uncertain
                append((cancelled ? "warning: " : "error: ") + error.localizedDescription)
                notify(action: "Error", path: error.localizedDescription, kind: .error)
            }
            append("Accepted \(accepted) of \(total) messages.")
            let completion = SubmoduleProgressCompletion(success: success, cancelled: cancelled, exitCode: nil,
                elapsed: ProcessInfo.processInfo.systemUptime - began, preferences: preferences)
            currentWork = completion.currentWork; completionRange = completion.append(to: &output)
            let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .medium
            if (preferences.object(forKey: "UseSystemLocaleForDates") as? NSNumber)?.boolValue == false {
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let milliseconds = Int64(max(0, min(elapsed.isFinite ? elapsed : 0, Double(Int64.max / 2000))) * 1000)
            notify(action: "Finished!", path: "\(success ? "Success" : "Fail") (\(milliseconds) ms @ \(formatter.string(from: Date())))", kind: success ? .finishedSuccess : .finishedFailure)
            percentage = success ? 100 : total == 0 ? 0 : Int(Double(accepted) / Double(total) * 100)
            busy = false; saveActionLog(); finishAutomaticClose()
        }
    }
    private func notify(action: String, path: String, kind: SendPatchNotification.Kind) {
        let lines = kind == .sending ? [path] : path.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        for value in lines {
            notifications.append(SendPatchNotification(action: action, path: value, kind: kind))
        }
    }
    private func append(_ line: String) {
        let value = line + "\n"
        guard logBytes < logLimit else { return }
        if value.utf8.count > logLimit - logBytes { output += "[Output truncated]\n"; logBytes = logLimit }
        else { output += value; logBytes += value.utf8.count }
    }
    private func consume(_ event: SMTPSeriesProgress) {
        switch event {
        case let .sending(index, count, attempt):
            currentIndex = index; currentWork = "Sending message \(index + 1) of \(count) (attempt \(attempt))"
            append(currentWork)
            notify(action: "Sending...", path: !combined && files.indices.contains(index) ? files[index].path : "", kind: .sending)
        case let .retry(index, next):
            notify(action: "Notice", path: "Retrying in 2 seconds...", kind: .notice)
            append("Retrying message \(index + 1) (attempt \(next))…")
        case let .accepted(index, response):
            accepted = max(accepted, index + 1); append("Message \(index + 1) accepted (SMTP \(response)).")
            percentage = total == 0 ? 0 : Int(Double(accepted) / Double(total) * 100)
        case let .upload(index, progress):
            guard index == currentIndex, index >= accepted, total > 0, progress.total > 0 else { return }
            percentage = min(99, Int((Double(index) + min(1, Double(progress.uploaded) / Double(progress.total))) / Double(total) * 100))
        }
    }
    func cancel() {
        guard busy, !invalidated, !cancelling, !confirmingCancellation else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.currentWork = "Cancelling…"; self.token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; currentWork = "Cancelling…"; token.cancel() }
    }
    func invalidate() { invalidated = true; token.cancel() }
    private func finishAutomaticClose() { if !activeOperation, !invalidated, policy.shouldClose(success: success, postActionCount: 0) { close() } }
}

@MainActor final class SendPatchProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: SendPatchProgressModel
    var onClosed: () -> Void = {}
    init(model: SendPatchProgressModel) {
        self.model = model
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(model.repository.root.lastPathComponent) – Send Email – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 600, height: 320)
        window.contentViewController = NSHostingController(rootView: SendPatchProgressDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.activeOperation, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        window.escapeAction = { [weak model] in if model?.busy == true { model?.cancel() } else { model?.close() } }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.activeOperation && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.saveActionLog(); model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct SendPatchProgressDialog: View {
    @ObservedObject var model: SendPatchProgressModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SendPatchNotificationList(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.busy {
                HStack {
                    Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption)
                    Spacer()
                    ProgressView(value: Double(model.percentage), total: 100).frame(width: 240)
                }
            }
            HStack {
                Text("Accepted \(model.accepted) of \(model.total)").foregroundStyle(model.success ? Color.green : model.busy ? Color.primary : Color.red)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.activeOperation)
                Button("Abort") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.success || model.confirmingCancellation || model.busy && model.cancelling)
            }
        }.padding(12)
    }
}

/// Retains options, progress and access until the final user close. Configured
/// routing is introduced first; other delivery modes retain their existing path.
@MainActor final class ConfiguredSendPatchWorkflow {
    private var options: SendPatchWindowController?, progress: SendPatchProgressWindowController?
    private var finished = false
    private let completion: (String?) -> Void
    private let present: (NSWindowController) -> Void
    init(files: [URL], repository: GitRepository, access: RepositoryAccessLease?, fileAccess: [RepositoryAccessLease], preferences: UserDefaults, presentation: ((NSWindowController) -> Void)? = nil, completion: @escaping (String?) -> Void) {
        self.completion = completion
        present = presentation ?? { $0.showWindow(nil); $0.window?.makeKeyAndOrderFront(nil) }
        let controller = SendPatchWindowController(files: files, access: fileAccess, preferences: preferences)
        options = controller
        controller.model.onSubmit = { [weak self] request in
            guard let self, !self.finished, self.progress == nil else { return }
            let model = SendPatchProgressModel(request: request, repository: repository, access: access, preferences: preferences)
            let progress = SendPatchProgressWindowController(model: model); self.progress = progress
            progress.onClosed = { [weak self, weak model] in self?.finish(model?.success == true ? nil : model?.error) }
            self.present(progress); model.start()
        }
        controller.onClosed = { [weak self] in
            guard let self else { return }; self.options = nil
            if self.progress == nil { self.finish(nil) }
        }
    }
    func start() { if let options { present(options) } }
    private func finish(_ error: String?) {
        guard !finished else { return }; finished = true; options = nil; progress = nil; completion(error)
    }
}
