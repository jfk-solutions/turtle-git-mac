// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SettingSMTP and UserPassword; see NOTICE.
import AppKit
import SwiftUI
import Security
import LocalAuthentication
import TurtleGitCore

enum EmailDelivery: Int, CaseIterable, Sendable {
    case direct = 0, mailClient = 1, configured = 2
    var title: String {
        switch self {
        case .direct: return "SMTP, directly to destination server"
        case .mailClient: return "Mail client"
        case .configured: return "Use configured server"
        }
    }
}
enum EmailEncryption: Int, CaseIterable, Sendable {
    case none = 0, startTLS = 1, tls = 2
    var title: String { switch self { case .none: return "none"; case .startTLS: return "STARTTLS"; case .tls: return "SSL/TLS" } }
}
struct EmailConfiguration: Equatable, Sendable {
    var delivery: EmailDelivery = .direct
    var server = ""
    var port: UInt32 = 25
    var encryption: EmailEncryption = .none
    var authenticate = false
    init(preferences: UserDefaults, missingDelivery: EmailDelivery = .direct) {
        if preferences.object(forKey: "SendMail.DeliveryType") == nil { delivery = missingDelivery }
        else { delivery = EmailDelivery(rawValue: preferences.integer(forKey: "SendMail.DeliveryType")) ?? .direct }
        server = preferences.string(forKey: "SendMail.Address") ?? ""
        port = (preferences.object(forKey: "SendMail.Port") as? NSNumber)?.uint32Value ?? 25
        encryption = EmailEncryption(rawValue: preferences.integer(forKey: "SendMail.Encryption")) ?? .none
        authenticate = preferences.bool(forKey: "SendMail.AuthenticationRequired")
    }
    func save(_ preferences: UserDefaults) {
        preferences.set(delivery.rawValue, forKey: "SendMail.DeliveryType")
        preferences.set(server, forKey: "SendMail.Address")
        preferences.set(NSNumber(value: port), forKey: "SendMail.Port")
        preferences.set(encryption.rawValue, forKey: "SendMail.Encryption")
        preferences.set(authenticate, forKey: "SendMail.AuthenticationRequired")
    }
}
protocol SMTPCredentialStore: Sendable {
    func login() async throws -> String
    func store(login: String, password: String) async throws
    func clear() async throws
}
struct SMTPLoginSecret: Sendable {
    let login: String
    let password: String
}
protocol SMTPTransportCredentialSource: Sendable {
    func credentials() async throws -> SMTPLoginSecret?
}
struct SMTPKeychainFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "SMTP credentials could not be accessed in Keychain (\(status))." }
}
struct SMTPKeychainAPI: Sendable {
    var copy: @Sendable ([String: Any]) -> (OSStatus, [String: Any]?)
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var add: @Sendable ([String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus
    static let live = SMTPKeychainAPI(copy: { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? [String: Any])
    }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
       add: { SecItemAdd($0 as CFDictionary, nil) }, delete: { SecItemDelete($0 as CFDictionary) })
}
/// One app-private credential pair, matching upstream's single SMTP slot.
/// Actor isolation keeps potentially blocking Security calls off the main actor.
actor SMTPKeychainStore: SMTPCredentialStore, SMTPTransportCredentialSource {
    private let api: SMTPKeychainAPI
    init(api: SMTPKeychainAPI = .live) { self.api = api }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.turtlegit.macos.smtp",
         kSecAttrAccount as String: "SMTP-Credentials",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    func login() throws -> String {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let (status, attributes) = api.copy(request)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw SMTPKeychainFailure(status: status) }
        guard let attributes,
              let bytes = attributes[kSecAttrGeneric as String] as? Data,
              let login = String(data: bytes, encoding: .utf8) else { throw SMTPKeychainFailure(status: errSecDecode) }
        return login
    }
    /// Read the pair in one query so a concurrent credential replacement cannot
    /// combine a previous username with a new password. Used only by transport.
    func credentials() throws -> SMTPLoginSecret? {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let (status, attributes) = api.copy(request)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SMTPKeychainFailure(status: status) }
        guard let attributes, let name = attributes[kSecAttrGeneric as String] as? Data,
              let secret = attributes[kSecValueData as String] as? Data,
              let login = String(data: name, encoding: .utf8), let password = String(data: secret, encoding: .utf8) else {
            throw SMTPKeychainFailure(status: errSecDecode)
        }
        return SMTPLoginSecret(login: login, password: password)
    }
    func store(login: String, password: String) throws {
        let values: [String: Any] = [kSecAttrGeneric as String: Data(login.utf8),
                                    kSecAttrLabel as String: "TurtleGit SMTP",
                                    kSecValueData as String: Data(password.utf8)]
        var status = api.update(query, values)
        if status == errSecItemNotFound {
            var item = query; item.merge(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = api.add(item)
        }
        guard status == errSecSuccess else { throw SMTPKeychainFailure(status: status) }
    }
    func clear() throws {
        let status = api.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SMTPKeychainFailure(status: status) }
    }
}

@MainActor final class EmailSettingsModel: ObservableObject {
    @Published var delivery: EmailDelivery
    @Published var server: String
    @Published var port: String
    @Published var encryption: EmailEncryption
    @Published var authenticate: Bool
    @Published private(set) var login = ""
    @Published private(set) var busy = false
    @Published private(set) var pendingOperations = 0
    @Published var error: String?
    private let preferences: UserDefaults
    private let credentials: any SMTPCredentialStore
    private var baseline: EmailConfiguration
    private var generation = UUID()
    private var invalidated = false
    init(preferences: UserDefaults = .standard, credentials: any SMTPCredentialStore = SMTPKeychainStore()) {
        self.preferences = preferences; self.credentials = credentials
        let value = EmailConfiguration(preferences: preferences); baseline = value
        delivery = value.delivery; server = value.server; port = String(value.port)
        encryption = value.encryption; authenticate = value.authenticate
    }
    var configuredControls: Bool { !invalidated && !busy && delivery == .configured }
    var credentialControls: Bool { configuredControls && authenticate }
    // Upstream Clear remains available for stored credentials regardless of delivery/auth.
    var canClear: Bool { !invalidated && !busy && !login.isEmpty }
    var validPort: Bool { !port.isEmpty && port.utf8.allSatisfy { (48...57).contains($0) } && UInt32(port) != nil }
    var changed: Bool {
        delivery != baseline.delivery || server != baseline.server || port != String(baseline.port) || encryption != baseline.encryption || authenticate != baseline.authenticate
    }
    var canApply: Bool { !invalidated && !busy && changed && validPort }
    func apply() {
        guard canApply, let number = UInt32(port) else { return }
        var value = baseline
        value.delivery = delivery; value.server = server; value.port = number
        value.encryption = encryption; value.authenticate = authenticate
        value.save(preferences); baseline = value; port = String(number); error = nil
    }
    func discard() {
        guard !invalidated, !busy else { return }
        let value = EmailConfiguration(preferences: preferences); baseline = value
        delivery = value.delivery; server = value.server; port = String(value.port)
        encryption = value.encryption; authenticate = value.authenticate; error = nil
    }
    func invalidate() { invalidated = true; generation = UUID(); busy = false }
    private func perform(_ operation: @escaping @Sendable (any SMTPCredentialStore) async throws -> String) {
        guard !invalidated, !busy else { return }
        let request = UUID(); generation = request; busy = true; pendingOperations += 1; error = nil
        Task { [weak self, credentials] in
            let result: Result<String, Error>
            do { result = .success(try await operation(credentials)) } catch { result = .failure(error) }
            guard let self else { return }
            self.pendingOperations -= 1
            guard !self.invalidated, self.generation == request else { return }
            self.busy = false
            switch result { case .success(let login): self.login = login; case .failure(let error): self.error = error.localizedDescription }
        }
    }
    func refreshCredentials() { perform { try await $0.login() } }
    func storeCredentials(login: String, password: String) {
        guard credentialControls, !login.isEmpty else { return }
        perform { store in try await store.store(login: login, password: password); return try await store.login() }
    }
    func clearCredentials() { guard canClear else { return }; perform { store in try await store.clear(); return "" } }
}

@MainActor struct EmailSettingsPage: View {
    @StateObject private var model: EmailSettingsModel
    @State private var credentialSheet = false
    private let onCancel: (() -> Void)?
    private let onOK: (() -> Void)?
    init(model: EmailSettingsModel? = nil, onCancel: (() -> Void)? = nil, onOK: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: model ?? EmailSettingsModel()); self.onCancel = onCancel; self.onOK = onOK
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { if let image = MenuIcon.sendMail.image() { Image(nsImage: image) }; Text("Email").font(.headline) }
            HStack {
                Text("Delivery:").frame(width: 95, alignment: .leading)
                Picker("Delivery", selection: $model.delivery) { ForEach(EmailDelivery.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
            }
            HStack {
                Text("SMTP Server:").frame(width: 95, alignment: .leading)
                TextField("", text: $model.server)
                Text("Port:")
                TextField("25", text: $model.port).frame(width: 75).multilineTextAlignment(.trailing)
            }.disabled(!model.configuredControls)
            HStack { Text("From").frame(width: 95, alignment: .leading); TextField("", text: .constant("")) }.disabled(true)
            HStack {
                Text("Encryption").frame(width: 95, alignment: .leading)
                Picker("Encryption", selection: $model.encryption) { ForEach(EmailEncryption.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
            }.disabled(!model.configuredControls)
            Toggle("SMTP Server requires authentication", isOn: $model.authenticate).disabled(!model.configuredControls)
            GroupBox("Credentials") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Login:").frame(width: 65, alignment: .leading); SMTPLoginField(login: model.login, enabled: model.credentialControls) }
                    HStack {
                        Spacer().frame(width: 65)
                        Button("Store credentials…") { credentialSheet = true }.disabled(!model.credentialControls)
                        Button("Clear") { model.clearCredentials() }.disabled(!model.canClear)
                        Spacer()
                    }
                }.padding(10)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.validPort { Text("Enter a whole number from 0 to 4294967295.").foregroundStyle(.red) }
            Spacer()
            HStack {
                Spacer()
                if let onOK { Button("OK", action: onOK).keyboardShortcut(.defaultAction).disabled(model.busy || !model.validPort) }
                Button("Cancel") { model.discard(); onCancel?() }.disabled(model.busy).keyboardShortcut(.cancelAction)
                Button("Apply") { model.apply() }.disabled(!model.canApply)
            }
        }.padding(20).disabled(model.busy)
            .onAppear { model.refreshCredentials() }
            .sheet(isPresented: $credentialSheet) { SMTPCredentialSheet(login: model.login) { login, password in model.storeCredentials(login: login, password: password) } }
    }
}

/// The source settings link launches an independent settings window. Keep its
/// lifetime separate from Send Patch and reuse it for repeated settings links.
@MainActor final class EmailSettingsWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: EmailSettingsWindowController?
    let model: EmailSettingsModel
    var onClosed: () -> Void = {}
    static func present(preferences: UserDefaults = .standard) {
        let controller: EmailSettingsWindowController
        if let current { controller = current }
        else {
            controller = EmailSettingsWindowController(preferences: preferences)
            current = controller
            controller.onClosed = { [weak controller] in if current === controller { current = nil } }
        }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    init(preferences: UserDefaults = .standard, credentials: any SMTPCredentialStore = SMTPKeychainStore()) {
        model = EmailSettingsModel(preferences: preferences, credentials: credentials)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Email – Settings – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 460)
        super.init(window: window); window.delegate = self
        window.contentViewController = NSHostingController(rootView: EmailSettingsPage(model: model,
            onCancel: { [weak self] in self?.window?.performClose(nil) }, onOK: { [weak self] in self?.accept() }))
        window.center()
    }
    func accept() {
        guard !model.busy, window?.attachedSheet == nil else { return }
        window?.makeFirstResponder(nil)
        guard model.validPort else { return }
        model.apply(); window?.performClose(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct SMTPLoginField: NSViewRepresentable {
    var login: String
    var enabled: Bool
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(); field.isEditable = false; field.isSelectable = true
        field.identifier = NSUserInterfaceItemIdentifier("SMTPLogin")
        field.setAccessibilityLabel("Login"); return field
    }
    func updateNSView(_ field: NSTextField, context: Context) { field.stringValue = login; field.isEnabled = enabled }
}
private struct SMTPCredentialSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var login: String
    @State private var password = ""
    @FocusState private var focused: Field?
    enum Field { case login, password }
    let save: (String, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Password").font(.headline)
            HStack { Text("Username:").frame(width: 85, alignment: .leading); TextField("", text: $login).focused($focused, equals: .login) }
            HStack { Text("Password:").frame(width: 85, alignment: .leading); SecureField("", text: $password).focused($focused, equals: .password) }
            HStack {
                Spacer()
                Button("Cancel") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { save(login, password); password = ""; dismiss() }.keyboardShortcut(.defaultAction).disabled(login.isEmpty)
            }
        }.padding(20).frame(width: 420).onAppear { focused = login.isEmpty ? .login : .password }.onDisappear { password = "" }
    }
}
