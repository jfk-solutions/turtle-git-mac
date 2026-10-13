// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Security
import LocalAuthentication
import TurtleGitCore

protocol ProxyPasswordStoring: Sendable {
    func load() async throws -> String
    func save(_ value: String) async throws
}
private actor ProxyPasswordCache: ProxyPasswordStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.turtlegit.macos.proxy", kSecAttrAccount as String: "DisabledProxyDraft", kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
    }
    func load() throws -> String {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }; return value
    }
    func save(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }; return
        }
        let values = [kSecValueData as String: Data(value.utf8), kSecAttrLabel as String: "TurtleGit proxy draft"] as [String: Any]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(values) { _, value in value }; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not access the saved proxy draft in Keychain (\(status))."])
    }
}
@MainActor final class NetworkSettingsModel: ObservableObject {
    let settingsRegistration = UUID()
    static var activeSaves = 0
    @Published var proxy = GitProxySettings()
    @Published var ssh = SSHClientPreferences.load()
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published var version = ""
    @Published var error: String?
    private var savedProxy = GitProxySettings()
    private var savedSSH = SSHClientPreferences.load()
    private let cache: any ProxyPasswordStoring
    private let preferences: UserDefaults
    var readProxy: ((OperationCancellation) async throws -> GitProxySettings)?
    var writeProxy: ((GitProxySettings) async throws -> Void)?
    var authorizeFile: ((URL) async -> Bool)?
    var sshVersion: ((SSHClientPreferences, OperationCancellation) async throws -> String)?
    private let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let localAvailable: Bool
    private var files: GitConfigurationFiles?
    private var active = false
    private var saving = false
    private var generation = UUID()
    private var token: OperationCancellation?
    private var panel: NSOpenPanel?
    private var permissionReply: ((Bool) -> Void)?
    weak var window: NSWindow?
    init(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool, preferences: UserDefaults = .standard, passwords: (any ProxyPasswordStoring)? = nil) {
        self.repository = repository; self.access = access; self.localAvailable = localAvailable
        self.preferences = preferences; cache = passwords ?? ProxyPasswordCache()
        ssh = .load(from: preferences); savedSSH = ssh
    }
    var modified: Bool { loaded && (proxy != savedProxy || ssh != savedSSH) }
    func activate() { active = true; if !loaded { load() } }
    func deactivate() {
        active = false; generation = UUID(); token?.cancel(); token = nil
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        let reply = permissionReply; permissionReply = nil; reply?(false)
        if !saving { busy = false }
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && localAvailable && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func permission(_ file: URL) async -> Bool {
        if let authorizeFile { return await authorizeFile(file) }
        if GitConfigurationPermissions.authorized(file) { return true }
        guard active, let window, window.attachedSheet == nil else { return false }
        let chooser = NSOpenPanel(); chooser.canChooseFiles = false; chooser.canChooseDirectories = true; chooser.canCreateDirectories = true
        chooser.message = "Authorize the folder containing " + file.path; chooser.directoryURL = file.deletingLastPathComponent(); chooser.prompt = "Authorize"; panel = chooser
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            permissionReply = reply
            chooser.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.panel === chooser else { reply(false); return }; self.panel = nil; self.permissionReply = nil
                guard self.active, response == .OK, let folder = chooser.url else { reply(false); return }
                do { try GitConfigurationPermissions.remember(folder, for: file); reply(true) } catch { self.error = error.localizedDescription; reply(false) }
            }
        }
    }
    private func load() {
        guard active, !busy else { return }
        let request = UUID(), token = OperationCancellation(); generation = request; self.token = token; busy = true; error = nil
        Task {
            defer { if generation == request { busy = false; self.token = nil } }
            do {
                try checkAccess()
                let files = try await repository.gitConfigurationFiles(hasRepository: localAvailable, cancellation: token)
                guard active, generation == request else { return }; self.files = files
                for file in [files.global, files.xdg].compactMap({ $0 }) { guard await permission(file), active, generation == request else { return } }
                var proxy: GitProxySettings
                do { if let readProxy { proxy = try await readProxy(token) } else { proxy = try await repository.proxyConfiguration(cancellation: token) } }
                catch NetworkSettingsFailure.proxy {
                    proxy = GitProxySettings(); proxy.enabled = true
                    if active, generation == request { self.error = "The effective proxy URL could not be parsed. Enter a new proxy address to replace the global setting; existing repository overrides remain unchanged." }
                }
                guard active, generation == request, !token.isCancelled else { return }
                if !proxy.enabled {
                    proxy.server = preferences.string(forKey: "TurtleGit.ProxyServer") ?? ""
                    proxy.port = preferences.string(forKey: "TurtleGit.ProxyPort") ?? ""
                    proxy.username = preferences.string(forKey: "TurtleGit.ProxyUsername") ?? ""
                    do { proxy.password = try await cache.load() }
                    catch {
                        if active, generation == request { self.error = "The retained proxy password is unavailable. Re-enter it before enabling the proxy. SSH-only changes leave the cached password untouched." }
                    }
                }
                guard active, generation == request, !token.isCancelled else { return }
                self.proxy = proxy; savedProxy = proxy; loaded = true
            } catch { if active, generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func validate() -> String? {
        guard loaded, !busy else { return "Finish loading or checking Network settings first." }
        do { _ = try proxy.value(); if !GitRuntime.isAppStoreBuild { _ = try ssh.executable() }; return nil }
        catch { return error.localizedDescription }
    }
    func apply(owner: NSWindow?) async -> Bool {
        if !modified { return true }
        if let error = validate() { self.error = error; return false }
        let wasActive = active; active = true; if window == nil { window = owner }
        let proxy = proxy, ssh = ssh, request = generation
        busy = true; saving = true; Self.activeSaves += 1
        defer { busy = false; saving = false; Self.activeSaves -= 1; if generation == request { active = wasActive } }
        do {
            try checkAccess()
            if proxy != savedProxy {
                guard let files else { throw GitConfigurationFailure.destination }
                for file in [files.global, files.xdg].compactMap({ $0 }) { guard await permission(file), active, generation == request else { return false } }
                try await cache.save(proxy.password)
                preferences.set(proxy.server, forKey: "TurtleGit.ProxyServer"); preferences.set(proxy.port, forKey: "TurtleGit.ProxyPort"); preferences.set(proxy.username, forKey: "TurtleGit.ProxyUsername")
                if let writeProxy { try await writeProxy(proxy) } else { try await repository.saveProxyConfiguration(proxy) }
                savedProxy = proxy
            }
            if !GitRuntime.isAppStoreBuild, ssh != savedSSH {
                let token = OperationCancellation()
                let version: String
                if let sshVersion { version = try await sshVersion(ssh, token) } else { version = try await Task.detached { try ssh.version(cancellation: token) }.value }
                try ssh.save(to: preferences); savedSSH = ssh; if active, generation == request { self.version = version }
            }
            return true
        } catch { if active { self.error = error.localizedDescription }; return false }
    }
    func cancelDraft() { guard !saving else { return }; proxy = savedProxy; ssh = savedSSH; error = nil }
    func checkSSH() {
        guard active, !busy else { return }
        let ssh = ssh, token = OperationCancellation(), request = UUID(); generation = request; self.token = token; busy = true; error = nil
        Task {
            defer { if generation == request { busy = false; self.token = nil } }
            do { let version: String
                if let sshVersion { version = try await sshVersion(ssh, token) } else { version = try await Task.detached { try ssh.version(cancellation: token) }.value }
                if active, generation == request, !token.isCancelled { self.version = version } }
            catch { if active, generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func browseSSH() {
        guard active, !busy, !GitRuntime.isAppStoreBuild, let window, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.canChooseFiles = true; chooser.canChooseDirectories = false; chooser.title = "Choose OpenSSH client"; chooser.prompt = "Select SSH"
        chooser.directoryURL = URL(fileURLWithPath: ssh.path.isEmpty ? "/usr/bin" : (ssh.path as NSString).deletingLastPathComponent); panel = chooser
        chooser.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.panel === chooser else { return }; self.panel = nil
            guard self.active, response == .OK, let file = chooser.url else { return }
            do { self.ssh.bookmark = try file.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil); self.ssh.path = file.path; self.version = "" }
            catch { self.error = error.localizedDescription }
        }
    }
    func retry() { guard !busy else { return }; loaded = false; load() }
}
struct NetworkSettingsPage: View {
    @ObservedObject var model: NetworkSettingsModel
    @Environment(\.settingsTransaction) private var transaction
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Enable Proxy Server", isOn: $model.proxy.enabled).disabled(!model.loaded || model.busy)
            GroupBox("Proxy Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { TextField("Server address:", text: $model.proxy.server); TextField("Port:", text: $model.proxy.port).frame(width: 100) }
                    TextField("Username:", text: $model.proxy.username)
                    SecureField("Password:", text: $model.proxy.password)
                    Text("Saves http.proxy globally. Repository and URL-specific overrides retain Git precedence. Proxy credentials are part of Git’s configured proxy URL.").font(.caption).foregroundStyle(.secondary)
                }.padding(10).disabled(!model.proxy.enabled || !model.loaded || model.busy)
            }
            Spacer().frame(minHeight: 30, maxHeight: 70)
            GroupBox("SSH") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SSH client:")
                    HStack {
                        TextField("Automatic OpenSSH", text: Binding(get: { GitRuntime.isAppStoreBuild ? "Bundled OpenSSH" : model.ssh.path }, set: { model.ssh.path = $0; model.ssh.bookmark = nil; model.version = "" }))
                        Button("Browse…", action: model.browseSSH)
                    }.disabled(GitRuntime.isAppStoreBuild || model.busy)
                    HStack { Button("Use automatic OpenSSH") { model.ssh = SSHClientPreferences(); model.version = "" }.disabled(GitRuntime.isAppStoreBuild || model.busy); Button("Check now", action: model.checkSSH).disabled(GitRuntime.isAppStoreBuild || model.busy); Text(model.version).font(.caption).textSelection(.enabled) }
                    Text(GitRuntime.isAppStoreBuild ? "App Store builds use bundled OpenSSH. Existing Git SSH command overrides still apply." : "Custom clients must be OpenSSH. Git’s SSH environment and repository command overrides retain precedence.").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }.disabled(!model.loaded)
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.loaded { Button("Retry loading", action: model.retry).disabled(model.busy) }
            Spacer()
        }.padding(12)
        .background(NetworkWindowCapture(model: model).frame(width: 0, height: 0))
        .onAppear {
            model.activate()
            transaction?.register("network", participant: .init(page: .network, modified: { model.modified }, validate: model.validate, apply: { await model.apply(owner: transaction?.window) }, cancel: model.cancelDraft), registration: model.settingsRegistration)
        }
        .onChange(of: model.proxy) { _ in transaction?.notify() }
        .onChange(of: model.ssh) { _ in transaction?.notify() }
        .onChange(of: model.busy) { _ in transaction?.notify() }
        .onDisappear { model.deactivate() }
    }
}
private struct NetworkWindowCapture: NSViewRepresentable {
    let model: NetworkSettingsModel
    func makeNSView(context: Context) -> NSView { Capture(model: model) }
    func updateNSView(_ view: NSView, context: Context) {}
    final class Capture: NSView {
        weak var model: NetworkSettingsModel?
        init(model: NetworkSettingsModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.window = window }
    }
}
