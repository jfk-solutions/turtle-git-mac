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
@MainActor final class NetworkSettingsModel: ObservableObject, SettingsLifecyclePresenting {
    let settingsRegistration = UUID()
    static var activeSaves = 0
    private(set) static var activeReads=0
    private(set) static var activeSSHChoosers=0
    private(set) static var activeSheetReleases=0
    @Published private(set) var editorIdentity=UUID()
    @Published private(set) var checkingSSH=false
    @Published private(set) var cancellingCheck=false
    @Published private(set) var selectingSSH=false
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
    private var lifecycle=UUID()
    private var editorReceipt=UUID()
    private let attachments=SettingsLifecycleAttachments()
    private var sshChoiceOwner:NetworkSSHChoice?
    private var saving = false
    private var acceptedWrite:UUID?
    private var generation = UUID()
    private var token: OperationCancellation?
    private(set) var panel: NSOpenPanel?
    private var sshChoiceID:UUID?
    var presentSSHPanel:(NSOpenPanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void = {panel,window,reply in panel.beginSheetModal(for:window,completionHandler:reply)}
    var selectedSSHURL:(NSOpenPanel)->URL? = {$0.url}
    var bookmarkSSH:(URL)throws->Data = {try $0.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)}
    var fieldPreferences:UserDefaults {preferences}
    var pathBase:URL {repository.root}
    var canEditSSH:Bool {active && loaded && !busy && !selectingSSH && !GitRuntime.isAppStoreBuild}
    private var permissionReply: ((Bool) -> Void)?
    weak var window: NSWindow?
    init(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool, preferences: UserDefaults = .standard, passwords: (any ProxyPasswordStoring)? = nil) {
        self.repository = repository; self.access = access; self.localAvailable = localAvailable
        self.preferences = preferences; cache = passwords ?? ProxyPasswordCache()
        ssh = .load(from: preferences); savedSSH = ssh
    }
    var modified: Bool { loaded && (proxy != savedProxy || ssh != savedSSH) }
    var isActive:Bool {active}
    func acceptsCommand(_ identity:UUID)->Bool {active && editorReceipt==identity && editorIdentity==identity}
    func acceptsEditor(_ identity:UUID)->Bool {acceptsCommand(identity) && loaded && !busy && !selectingSSH}
    func attachPresentation(_ owner:UUID) {window=attachments.claim(owner)}
    func detachPresentation(_ owner:UUID) {if attachments.releaseOwner(owner) {window=nil;deactivate()}}
    func attachProbe(owner:UUID,identity:UUID,window:NSWindow) {if attachments.attach(owner:owner,identity:identity,window:window) {self.window=window}}
    func detachProbe(_ identity:UUID) {if attachments.releaseProbe(identity) {window=nil;deactivate()}}
    fileprivate static func beginSSHChoice() {activeSSHChoosers += 1}
    fileprivate static func endSSHChoice() {activeSSHChoosers -= 1}
    func activate() {
        lifecycle=UUID()
        if !saving || acceptedWrite != generation {generation=UUID();token?.cancel();token=nil}
        active=true;editorReceipt=UUID();editorIdentity=editorReceipt
        if !saving {busy=false};checkingSSH=false;cancellingCheck=false;selectingSSH=false
        if !loaded {load()}
    }
    func deactivate() {
        active=false;lifecycle=UUID();generation=UUID();editorReceipt=UUID();token?.cancel();token=nil
        let retirement=lifecycle,editor=editorReceipt
        let panel=self.panel;self.panel=nil
        sshChoiceID=nil;let choice=sshChoiceOwner;sshChoiceOwner=nil
        let reply=permissionReply;permissionReply=nil
        let sheets=[panel].compactMap {$0}
        let releasing = !sheets.isEmpty || reply != nil || choice != nil
        if releasing {Self.activeSheetReleases += 1}
        DispatchQueue.main.async { [self] in
            SettingsLifecycleSheetDrain.close(sheets) { [self] in
                choice?.release();reply?(false)
                if releasing {Self.activeSheetReleases -= 1}
                guard !active,lifecycle==retirement else {return}
                editorIdentity=editor;checkingSSH=false;cancellingCheck=false;selectingSSH=false
                if !saving {busy=false}
            }
        }
    }
    func editSSHPath(_ value:String,identity:UUID) {guard canEditSSH,acceptsEditor(identity) else {return};ssh.path=value;ssh.bookmark=nil;version=""}
    func useAutomaticSSH(identity:UUID) {guard canEditSSH,acceptsEditor(identity) else {return};ssh=SSHClientPreferences();version=""}
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && localAvailable && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func permission(_ file: URL) async -> Bool {
        guard active else {return false}
        if let authorizeFile { return await authorizeFile(file) }
        if GitConfigurationPermissions.authorized(file) { return true }
        guard active, let window, window.attachedSheet == nil else { return false }
        let chooser = NSOpenPanel(); chooser.canChooseFiles = false; chooser.canChooseDirectories = true; chooser.canCreateDirectories = true
        chooser.message = "Authorize the folder containing " + file.path; chooser.directoryURL = file.deletingLastPathComponent(); chooser.prompt = "Authorize"; panel = chooser
        chooser.alphaValue=window.alphaValue;chooser.appearance=window.appearance
        let request=generation,activation=lifecycle
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            permissionReply = reply
            chooser.beginSheetModal(for: window) { [weak self] response in
                guard let self,self.panel===chooser else {return};self.panel=nil;self.permissionReply=nil
                SettingsLifecycleSheetDrain.close([chooser]) { [weak self] in
                    guard let self,self.active,self.generation==request,self.lifecycle==activation,response == .OK,let folder=chooser.url else {reply(false);return}
                    do {try GitConfigurationPermissions.remember(folder,for:file);reply(true)}
                    catch {self.error=error.localizedDescription;reply(false)}
                }
            }
        }
    }
    private func load() {
        guard active, !busy, !selectingSSH else { return }
        let request = UUID(), token = OperationCancellation(); generation = request; self.token = token; busy = true; error = nil
        Self.activeReads += 1
        Task { [self,access] in
            defer {Self.activeReads -= 1;withExtendedLifetime(access) {};if generation == request {busy=false;self.token=nil}}
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
        guard !selectingSSH else {return "Finish selecting the SSH client first."}
        guard loaded, !busy else { return "Finish loading or checking Network settings first." }
        do { _ = try proxy.value(); if !GitRuntime.isAppStoreBuild { _ = try ssh.executable() }; return nil }
        catch { return error.localizedDescription }
    }
    func apply(owner: NSWindow?) async -> Bool {
        if !modified { return true }
        if let error = validate() { self.error = error; return false }
        let wasActive=active,activation=lifecycle;active=true; if window == nil { window = owner }
        let proxy = proxy, ssh = ssh, request = generation
        busy = true; saving = true; Self.activeSaves += 1
        defer {busy=false;saving=false;acceptedWrite=nil;Self.activeSaves -= 1;if generation==request,lifecycle==activation {active=wasActive}}
        do {
            try checkAccess()
            if proxy != savedProxy {
                guard let files else { throw GitConfigurationFailure.destination }
                for file in [files.global, files.xdg].compactMap({ $0 }) { guard await permission(file), active, generation == request else { return false } }
                acceptedWrite=request
                try await cache.save(proxy.password)
                preferences.set(proxy.server, forKey: "TurtleGit.ProxyServer"); preferences.set(proxy.port, forKey: "TurtleGit.ProxyPort"); preferences.set(proxy.username, forKey: "TurtleGit.ProxyUsername")
                if let writeProxy { try await writeProxy(proxy) } else { try await repository.saveProxyConfiguration(proxy) }
                if active,generation==request {savedProxy=proxy}
            }
            if !GitRuntime.isAppStoreBuild, ssh != savedSSH {
                let token = OperationCancellation()
                let version: String
                if let sshVersion { version = try await sshVersion(ssh, token) } else { version = try await Task.detached { try ssh.version(cancellation: token) }.value }
                guard acceptedWrite==request || active && generation==request else {return false}
                acceptedWrite=request
                try ssh.save(to:preferences)
                if active,generation==request {savedSSH=ssh;self.version=version}
            }
            return true
        } catch {if active,generation==request {self.error=error.localizedDescription};return false}
    }
    func cancelDraft() { guard !saving,!selectingSSH else { return }; proxy = savedProxy; ssh = savedSSH; error = nil }
    func cancelSSHCheck() {
        guard active,checkingSSH,!cancellingCheck else {return}
        cancellingCheck=true;token?.cancel()
    }
    func checkSSH() {
        guard active,loaded,!busy,!selectingSSH,!GitRuntime.isAppStoreBuild else {return}
        let ssh=ssh,token=OperationCancellation(),request=UUID();generation=request;self.token=token
        busy=true;checkingSSH=true;cancellingCheck=false;error=nil;Self.activeReads += 1
        Task { [self,access] in
            defer {
                Self.activeReads -= 1;withExtendedLifetime(access) {}
                if generation==request {busy=false;checkingSSH=false;cancellingCheck=false;self.token=nil}
            }
            do {
                let version:String
                if let sshVersion {version=try await sshVersion(ssh,token)}
                else {version=try await Task.detached {try ssh.version(cancellation:token)}.value}
                if active,generation==request,!token.isCancelled,self.ssh==ssh {self.version=version}
            } catch {if active,generation==request,!token.isCancelled,self.ssh==ssh {self.error=error.localizedDescription}}
        }
    }
    func browseSSH() {
        guard canEditSSH,panel==nil,let window,window.attachedSheet==nil else {return}
        let chooser=NSOpenPanel();chooser.canChooseFiles=true;chooser.canChooseDirectories=false;chooser.title="Choose OpenSSH client";chooser.prompt="Select SSH"
        chooser.directoryURL=URL(fileURLWithPath:ssh.path.isEmpty ? "/usr/bin" : (ssh.path as NSString).deletingLastPathComponent)
        panel=chooser;let choice=UUID(),request=generation,activation=lifecycle,captured=ssh
        let ownership=NetworkSSHChoice();sshChoiceOwner=ownership;sshChoiceID=choice;selectingSSH=true
        chooser.alphaValue=window.alphaValue;chooser.appearance=window.appearance
        presentSSHPanel(chooser,window) { [weak self,weak chooser] response in
            guard let self,let chooser,self.panel===chooser,self.sshChoiceID==choice,self.sshChoiceOwner===ownership else {return}
            self.panel=nil;self.sshChoiceID=nil;self.sshChoiceOwner=nil
            SettingsLifecycleSheetDrain.close([chooser]) { [weak self] in
                ownership.release()
                guard let self,self.active,self.generation==request,self.lifecycle==activation else {return}
                self.selectingSSH=false
                guard self.ssh==captured,response == .OK,let file=self.selectedSSHURL(chooser) else {return}
                do {
                    var isDirectory:ObjCBool=false
                    guard file.isFileURL,FileManager.default.fileExists(atPath:file.path,isDirectory:&isDirectory),!isDirectory.boolValue,FileManager.default.isExecutableFile(atPath:file.path) else {throw NetworkSettingsFailure.ssh}
                    var selected=captured;selected.bookmark=try self.bookmarkSSH(file);selected.path=file.path
                    self.ssh=selected;self.version=""
                } catch {self.error=error.localizedDescription}
            }
        }
    }
    func retry() { guard active,!busy,!selectingSSH else { return }; loaded = false; load() }
}
struct NetworkSettingsPage: View {
    @ObservedObject var model: NetworkSettingsModel
    @Environment(\.settingsTransaction) private var transaction
    @State private var presentation=UUID()
    var body: some View {
        let identity=model.editorIdentity
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Enable Proxy Server", isOn: guarded($model.proxy.enabled,identity:identity)).disabled(!model.loaded || model.busy || model.selectingSSH)
            GroupBox("Proxy Settings") {
                VStack(alignment:.leading,spacing:12) {
                    HStack(spacing:10) {
                        Text("Server address:").frame(width:112,alignment:.leading)
                        TextField("",text:guarded($model.proxy.server,identity:identity)).accessibilityLabel("Server address").help("Address of the proxy server used for HTTP and HTTPS Git operations.")
                        Text("Port:")
                        TextField("",text:guarded($model.proxy.port,identity:identity)).frame(width:85).multilineTextAlignment(.trailing).accessibilityLabel("Proxy port")
                    }
                    HStack(spacing:10) {Text("Username:").frame(width:112,alignment:.leading);TextField("",text:guarded($model.proxy.username,identity:identity)).frame(maxWidth:340).accessibilityLabel("Proxy username");Spacer(minLength:0)}
                    HStack(spacing:10) {Text("Password:").frame(width:112,alignment:.leading);SecureField("",text:guarded($model.proxy.password,identity:identity)).frame(maxWidth:340).accessibilityLabel("Proxy password");Spacer(minLength:0)}
                    Text("Saves http.proxy globally. Repository and URL-specific overrides retain Git precedence. Proxy credentials are part of Git’s configured proxy URL.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:12)
                }.padding(10).frame(height:225,alignment:.topLeading).disabled(!model.proxy.enabled || !model.loaded || model.busy || model.selectingSSH)
            }
            GroupBox("SSH") {
                VStack(alignment:.leading,spacing:10) {
                    Text("SSH client:")
                    HStack {
                        if GitRuntime.isAppStoreBuild {TextField("",text:.constant("Bundled OpenSSH")).disabled(true)}
                        else {
                            PathEntryField(text:Binding(get:{model.ssh.path},set:{model.editSSHPath($0,identity:identity)}),label:"SSH client",base:model.pathBase,preferences:model.fieldPreferences,mayEdit:{model.canEditSSH && model.acceptsEditor(identity)})
                                .frame(height:24).disabled(!model.canEditSSH)
                        }
                        Button("Browse…") {if model.acceptsCommand(identity) {model.browseSSH()}}.disabled(!model.canEditSSH)
                    }
                    HStack {
                        Button("Use automatic OpenSSH") {model.useAutomaticSSH(identity:identity)}.disabled(!model.canEditSSH)
                        Button(model.cancellingCheck ? "Cancelling…" : model.checkingSSH ? "Cancel check" : "Check now") {if model.acceptsCommand(identity) {if model.checkingSSH {model.cancelSSHCheck()} else {model.checkSSH()}}}
                            .disabled(GitRuntime.isAppStoreBuild || !model.loaded || model.selectingSSH || model.cancellingCheck || model.busy && !model.checkingSSH)
                        Text(model.version).font(.caption).textSelection(.enabled)
                    }
                    Text(GitRuntime.isAppStoreBuild ? "App Store builds use bundled OpenSSH. Existing Git SSH command overrides still apply." : "Custom clients must be OpenSSH. Git’s SSH environment and repository command overrides retain precedence.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }.padding(10)
            }.disabled(!model.loaded)
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.loaded { Button("Retry loading") {if model.acceptsCommand(identity) {model.retry()}}.disabled(model.busy) }
            Spacer()
        }.padding(12)
        .background(SettingsLifecycleWindowProbe(model:model,owner:presentation).frame(width: 0, height: 0))
        .onAppear {
            model.attachPresentation(presentation);model.activate()
            transaction?.register("network", participant: .init(page: .network, modified: { model.modified }, validate: model.validate, apply: { await model.apply(owner: transaction?.window) }, cancel: model.cancelDraft), registration: model.settingsRegistration)
        }
        .onChange(of: model.proxy) { _ in transaction?.notify() }
        .onChange(of: model.ssh) { _ in transaction?.notify() }
        .onChange(of: model.busy) { _ in transaction?.notify() }
        .onChange(of: model.selectingSSH) { _ in transaction?.notify() }
        .onDisappear {model.detachPresentation(presentation)}
    }
    private func guarded<Value>(_ value:Binding<Value>,identity:UUID)->Binding<Value> {
        Binding(get:{value.wrappedValue},set:{if model.acceptsEditor(identity) {value.wrappedValue=$0}})
    }

}
@MainActor private final class NetworkSSHChoice {
    private var released=false
    init() {NetworkSettingsModel.beginSSHChoice()}
    func release() {guard !released else {return};released=true;NetworkSettingsModel.endSSHChoice()}
}
