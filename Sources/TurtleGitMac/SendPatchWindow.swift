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
