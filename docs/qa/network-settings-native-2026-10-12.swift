import AppKit
import SwiftUI
import TurtleGitCore

private actor NativeProxyPasswords: ProxyPasswordStoring {
    var value = "cached fixture", failSave = false, loads = 0, saves = 0
    func load() throws -> String { loads += 1; return value }
    func save(_ value: String) throws { if failSave { throw NSError(domain:"Private proxy cache failure",code:1) }; saves += 1; self.value = value }
    func failing(_ value: Bool) { failSave = value }
    func snapshot() -> (String,Int,Int) { (value,loads,saves) }
}
@main struct NetworkSettingsVerification {
    @MainActor static func main() async { do { try await verify() } catch { fputs("FAIL: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ message:String)throws {if !value {throw NSError(domain:"NetworkNative",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
        func wait(_ ready:()->Bool)async throws {for _ in 0..<1000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"Network settings did not settle",code:1)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"])
        let suite="TurtleGit.NetworkNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,passwords=NativeProxyPasswords()
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set("retained.example",forKey:"TurtleGit.ProxyServer");prefs.set("3128",forKey:"TurtleGit.ProxyPort");prefs.set("cached-user",forKey:"TurtleGit.ProxyUsername")
        let model=NetworkSettingsModel(repository:repo,access:nil,localAvailable:true,preferences:prefs,passwords:passwords)
        defer {model.deactivate()}
        model.activate();try await wait {model.loaded && !model.busy}
        try require(!model.proxy.enabled && model.proxy.server=="retained.example" && model.proxy.password=="cached fixture" && !model.modified,"Disabled draft retention differs")
        model.proxy.enabled=true;model.proxy.server="proxy.example";model.proxy.port="8080";model.proxy.username="name@host";model.proxy.password="fixture:p@ss"
        let accepted=await model.apply(owner:nil);try require(accepted && !model.modified && NetworkSettingsModel.activeSaves==0,"Proxy Apply failed")
        let global=try await repo.proxyConfiguration(source:.global)
        try require(global.enabled && global.username=="name@host" && global.password=="fixture:p@ss" && global.port=="8080","Actual Git proxy escaping/value differs")
        _=try await repo.run(["config","--local","http.https://example.invalid.proxy","http://local.example:9999"])
        model.proxy.enabled=false;let disabled=await model.apply(owner:nil);try require(disabled,"Disable Apply failed")
        let absent=try await repo.proxyConfiguration(source:.global),override=try await repo.run(["config","--local","--get","http.https://example.invalid.proxy"])
        try require(!absent.enabled && override.text.contains("local.example"),"Disable changed scoped override")
        let cached=await passwords.snapshot();try require(cached.0=="fixture:p@ss" && prefs.string(forKey:"TurtleGit.ProxyServer")=="proxy.example" && prefs.object(forKey:"TurtleGit.ProxyPassword")==nil,"Retained credentials escaped cache boundary")
        model.proxy.enabled=true;model.proxy.server="changed.example";await passwords.failing(true)
        let failedCache=await model.apply(owner:nil);try require(!failedCache && model.modified && prefs.string(forKey:"TurtleGit.ProxyServer")=="proxy.example","Cache failure saved later preferences")
        await passwords.failing(false)
        let file=URL(fileURLWithPath:ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]!),lock=file.appendingPathExtension("lock")
        try Data().write(to:lock);let failedGit=await model.apply(owner:nil);try FileManager.default.removeItem(at:lock)
        try require(!failedGit && model.modified && prefs.string(forKey:"TurtleGit.ProxyServer")=="changed.example" && !(model.error ?? "").contains("fixture:p@ss"),"Source-ordered partial failure/sanitization differs")
        model.cancelDraft();try require(!model.modified && !model.proxy.enabled,"Cancel did not restore saved UI draft")
        let transaction=SettingsTransaction(),window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:720),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:NetworkSettingsPage(model:model).environment(\.settingsTransaction,transaction));window.contentView=host;host.frame=window.contentLayoutRect;host.layoutSubtreeIfNeeded()
        defer {transaction.invalidate();window.contentView=nil;window.close()}
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {host.appearance=NSAppearance(named:appearance);host.layoutSubtreeIfNeeded()}
        model.proxy.enabled=true;model.proxy.server="invalid\naddress";try await wait {transaction.modified}
        transaction.apply(closeAfter:false);try await wait {!transaction.busy && transaction.error != nil}
        transaction.cancel();try await wait {!transaction.modified}
        // An authorized SSH Apply may finish after forced close, but must not reactivate the model.
        model.ssh.path="/usr/bin/ssh";var reply:CheckedContinuation<String,Error>?,checks=0
        model.sshVersion={_,_ in checks += 1;return try await withCheckedThrowingContinuation{reply=$0}}
        let save=Task {await model.apply(owner:nil)};try await wait {reply != nil && NetworkSettingsModel.activeSaves==1}
        model.deactivate();reply?.resume(returning:"OpenSSH_fixture");let saved=await save.value
        try require(saved && prefs.string(forKey:"TurtleGit.SSHClient")=="/usr/bin/ssh" && NetworkSettingsModel.activeSaves==0,"Captured SSH Apply did not finish")
        model.checkSSH();try require(!model.busy && checks==1,"Forced-close Apply resurrected the page")
        let late=NetworkSettingsModel(repository:repo,access:nil,localAvailable:true,preferences:prefs,passwords:passwords)
        defer {late.deactivate()}
        var read:CheckedContinuation<GitProxySettings,Error>?
        late.readProxy={_ in try await withCheckedThrowingContinuation{read=$0}}
        late.activate();try await wait {read != nil};let countBefore=await passwords.snapshot().1
        late.deactivate();read?.resume(returning:GitProxySettings());try await Task.sleep(nanoseconds:30_000_000)
        let countAfter=await passwords.snapshot().1
        try require(!late.loaded && !late.busy && countAfter==countBefore,"Late read touched cache/visible state")
        print("Network: actual private Git proxy Apply/Disable/scoped override preservation, captured credential retention and source-ordered partial failures, sanitized diagnostics, Settings validation/Cancel and light/dark host, SSH Apply-after-close without reactivation, late read/cache fencing passed. Private config/preferences/mock Keychain only; no network or user Keychain.")
    }
}
