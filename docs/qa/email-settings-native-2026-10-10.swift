import AppKit
import SwiftUI
import Security
import LocalAuthentication
import TurtleGitCore

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private actor PrivateCredentials: SMTPCredentialStore {
    var username = "stored@example.invalid", password = "", writes = 0, deletes = 0
    var failing = false, held = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    func gate() async { if held { await withCheckedContinuation { waiting.append($0) } } }
    func login() async throws -> String { await gate(); if failing { throw SMTPKeychainFailure(status: errSecAuthFailed) }; return username }
    func store(login: String, password: String) async throws { await gate(); if failing { throw SMTPKeychainFailure(status: errSecAuthFailed) }; username = login; self.password = password; writes += 1 }
    func clear() async throws { if failing { throw SMTPKeychainFailure(status: errSecAuthFailed) }; username = ""; password = ""; deletes += 1 }
    func hold() { held = true }
    func release() { held = false; let work = waiting; waiting = []; work.forEach { $0.resume() } }
    func fail(_ value: Bool) { failing = value }
    func state() -> (String, String, Int, Int) { (username, password, writes, deletes) }
}
// All simulated Security calls are serialized by SMTPKeychainStore's actor.
private final class SecurityProbe: @unchecked Sendable {
    var calls: [String] = [], queries: [[String: Any]] = []
    var updateStatus: OSStatus = errSecItemNotFound, copyStatus: OSStatus = errSecItemNotFound
    var addStatus: OSStatus = errSecSuccess, deleteStatus: OSStatus = errSecSuccess
    var copied: [String: Any]?
    func api() -> SMTPKeychainAPI {
        SMTPKeychainAPI(copy: { [self] query in calls.append("copy"); queries.append(query); return (copyStatus, copied) },
            update: { [self] query, values in calls.append("update"); queries.append(query); queries.append(values); return updateStatus },
            add: { [self] query in calls.append("add"); queries.append(query); return addStatus },
            delete: { [self] query in calls.append("delete"); queries.append(query); return deleteStatus })
    }
}
@main struct EmailSettingsVerification {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw CheckFailure(description: message) } }
    @MainActor static func settle(_ model: EmailSettingsModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.pendingOperations != 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(model.pendingOperations == 0, "Credential work did not finish")
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.Email.QA." + UUID().uuidString
        guard let prefs = UserDefaults(suiteName: suite) else { throw CheckFailure(description: "Private preferences unavailable") }
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let store = PrivateCredentials(), model = EmailSettingsModel(preferences: prefs, credentials: store)
        try require(model.delivery == .direct && model.port == "25" && model.encryption == .none && !model.authenticate, "Source page defaults")
        try require(!model.configuredControls && !model.credentialControls && !model.canApply, "Initial gates")
        model.refreshCredentials(); try await settle(model)
        try require(model.login == "stored@example.invalid" && model.canClear, "Clear existing credentials in direct mode")
        model.delivery = .configured
        try require(model.configuredControls && !model.credentialControls, "Configured/auth-off gates")
        model.authenticate = true
        try require(model.credentialControls, "Auth gates")
        model.server = "smtp.example.invalid"; model.port = "587"; model.encryption = .startTLS
        try require(model.canApply, "Changed valid settings")
        try require(prefs.object(forKey: "SendMail.Address") == nil, "Draft edits wrote preferences")
        model.apply()
        let saved = EmailConfiguration(preferences: prefs)
        try require(saved.delivery == .configured && saved.server == model.server && saved.port == 587 && saved.encryption == .startTLS && saved.authenticate && !model.changed, "Apply exact settings")
        model.port = "4294967295"; try require(model.validPort, "Source DWORD port limit")
        for invalid in ["", "-1", "1.5", "4294967296", " 25"] { model.port = invalid; try require(!model.validPort && !model.canApply, "Invalid port accepted"); model.apply() }
        try require(EmailConfiguration(preferences: prefs) == saved, "Invalid apply changed saved options")
        model.discard(); try require(model.port == "587" && !model.changed, "Cancel draft settings")
        model.storeCredentials(login: "", password: "ignored"); try await settle(model)
        var state = await store.state(); try require(state.2 == 0, "Empty username accepted")
        await store.hold()
        model.storeCredentials(login: "captured 雪", password: "private secret 雪")
        try require(model.busy && !model.canApply && !model.canClear && !model.credentialControls, "In-flight gates")
        model.storeCredentials(login: "second", password: "ignored")
        await store.release(); try await settle(model)
        state = await store.state(); try require(state.0 == "captured 雪" && state.1 == "private secret 雪" && state.2 == 1 && model.login == state.0, "Exactly-once captured credential store")
        let domain = prefs.persistentDomain(forName: suite) ?? [:]
        try require(domain.keys.sorted() == ["SendMail.Address", "SendMail.AuthenticationRequired", "SendMail.DeliveryType", "SendMail.Encryption", "SendMail.Port"].sorted(), "Credentials leaked into preferences")
        model.storeCredentials(login: "blank-password", password: ""); try await settle(model)
        state = await store.state(); try require(state.1.isEmpty && state.2 == 2, "Source permits empty password")
        model.delivery = .mailClient; model.authenticate = false
        try require(!model.configuredControls && !model.credentialControls && model.canClear, "Client mode gates")
        await store.fail(true); model.clearCredentials(); try await settle(model)
        try require(model.error != nil && model.login == "blank-password", "Failed clear lost stored login")
        await store.fail(false); model.clearCredentials(); try await settle(model)
        try require(model.login.isEmpty && !model.canClear, "Clear updates login immediately")
        model.discard(); try require(model.login.isEmpty, "Cancel incorrectly rolled back immediate credential clear")
        prefs.set(99, forKey: "SendMail.DeliveryType"); prefs.set(99, forKey: "SendMail.Encryption")
        let corrupt = EmailConfiguration(preferences: prefs)
        try require(corrupt.delivery == .direct && corrupt.encryption == .none, "Unknown enum fallback")
        saved.save(prefs)
        // Check actual host/layout and native read-only/selectable Login field.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let hostModel = EmailSettingsModel(preferences: prefs, credentials: store)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: EmailSettingsPage(model: hostModel)); host.appearance = NSAppearance(named: name)
            window.isReleasedWhenClosed = false
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 760, height: 700); host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000); try await settle(hostModel)
            func find(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.identifier?.rawValue == "SMTPLogin" { return field }
                return view.subviews.compactMap(find).first
            }
            guard let field = find(host) else { throw CheckFailure(description: "Native Login control absent") }
            try require(!field.isEditable && field.isSelectable, "Login must be read-only/selectable")
            try require(host.fittingSize.width <= 760 && host.fittingSize.height <= 700, "Email settings overflow")
            hostModel.invalidate(); window.contentView = nil; window.close()
        }
        // Closing a model fences a late refresh without mutating visible state.
        let lateStore = PrivateCredentials(), late = EmailSettingsModel(preferences: prefs, credentials: lateStore)
        await lateStore.hold(); late.refreshCredentials(); late.invalidate(); await lateStore.release(); try await settle(late)
        try require(late.login.isEmpty && late.error == nil && !late.busy, "Late credential callback escaped invalidation")
        // Exercise production adapter branches through simulated Security APIs;
        // never invoke live Keychain APIs or write user credentials.
        let probe = SecurityProbe(), keychain = SMTPKeychainStore(api: probe.api())
        var login = try await keychain.login(); try require(login.isEmpty, "Missing keychain item")
        try await keychain.store(login: "adapter 雪", password: "fixture-secret")
        try require(probe.calls == ["copy", "update", "add"], "Update then missing-item Add flow")
        let added = probe.queries.last!
        try require(added[kSecAttrService as String] as? String == "org.turtlegit.macos.smtp" && added[kSecAttrAccount as String] as? String == "SMTP-Credentials", "Keychain namespace")
        try require(added[kSecUseDataProtectionKeychain as String] as? Bool == true && added[kSecAttrSynchronizable as String] as? Bool == false, "Data protection/local-only keychain")
        try require(added[kSecValueData as String] as? Data == Data("fixture-secret".utf8) && added[kSecAttrGeneric as String] as? Data == Data("adapter 雪".utf8), "Exact credential bytes")
        probe.updateStatus = errSecSuccess
        try await keychain.store(login: "updated", password: "")
        try require(probe.calls.suffix(1) == ["update"], "Existing item must update without delete/add")
        probe.copyStatus = errSecSuccess; probe.copied = [kSecAttrGeneric as String: Data("updated".utf8)]
        login = try await keychain.login(); try require(login == "updated", "Attribute-only login read")
        let request = probe.queries.last!
        try require(request[kSecReturnData as String] == nil && (request[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true, "Login refresh must not request password or authentication UI")
        probe.copied = [kSecAttrGeneric as String: Data("pair 雪".utf8), kSecValueData as String: Data("pair-secret 雪".utf8)]
        let pair = try await keychain.credentials()
        try require(pair?.login == "pair 雪" && pair?.password == "pair-secret 雪", "Atomic username/password capture")
        try require(probe.queries.last?[kSecReturnData as String] as? Bool == true && probe.queries.last?[kSecReturnAttributes as String] as? Bool == true, "Credential pair fetched in one query")
        probe.copied = [kSecAttrGeneric as String: Data("new".utf8), kSecValueData as String: Data("new-secret".utf8)]
        try require(pair?.login == "pair 雪" && pair?.password == "pair-secret 雪", "Captured pair remains immutable")
        probe.copyStatus = errSecItemNotFound
        let missing = try await keychain.credentials(); try require(missing == nil, "Missing credential pair")
        probe.copyStatus = errSecSuccess; probe.copied = [kSecAttrGeneric as String: Data("bad".utf8)]
        do { _ = try await keychain.credentials(); throw CheckFailure(description: "Missing password accepted") } catch is SMTPKeychainFailure { }
        probe.copied = [kSecAttrGeneric as String: Data("bad".utf8), kSecValueData as String: Data([255])]
        do { _ = try await keychain.credentials(); throw CheckFailure(description: "Invalid password encoding accepted") } catch is SMTPKeychainFailure { }
        probe.deleteStatus = errSecItemNotFound; try await keychain.clear()
        probe.copyStatus = errSecAuthFailed
        do { _ = try await keychain.login(); throw CheckFailure(description: "Keychain access failure swallowed") } catch is SMTPKeychainFailure { }
        probe.copyStatus = errSecSuccess; probe.copied = [:]
        do { _ = try await keychain.login(); throw CheckFailure(description: "Malformed Keychain attributes accepted") } catch is SMTPKeychainFailure { }
        probe.updateStatus = errSecAuthFailed
        let count = probe.calls.count
        do { try await keychain.store(login: "ignored", password: "ignored"); throw CheckFailure(description: "Update failure swallowed") } catch is SMTPKeychainFailure { }
        try require(probe.calls.count == count + 1 && probe.calls.last == "update", "Access failure must not Add or Delete")
        model.invalidate()
        print("Email settings: source defaults/gates, Apply/Cancel, UInt32 ports, immediate credentials, captured async work/error/late-close, private preference exclusion, read-only native Login and hidden light/dark layout passed. Simulated Security API namespace/update/add/delete/metadata/error branches passed. No live Keychain, mail, network or main app.")
        print("Private suite cleaned: " + suite)
    }
    static func main() async { do { try await verify() } catch { fputs("Email settings QA failed: \(error)\n", stderr); exit(1) } }
}
