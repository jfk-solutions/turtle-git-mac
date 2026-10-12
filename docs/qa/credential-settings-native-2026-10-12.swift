import AppKit
import SwiftUI
import TurtleGitCore

@main struct CredentialSettingsVerification {
    @MainActor static func main() async { do { try await verify() } catch { fputs("FAIL: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        func require(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain:"CredentialNative",code:1,userInfo:[NSLocalizedDescriptionKey:message]) } }
        func wait(_ ready: () -> Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw NSError(domain:"Credential settings did not settle",code:1) }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), git=URL(fileURLWithPath:CommandLine.arguments[2]), repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"])
        let key="credential.https://example.invalid.helper"
        _=try await repo.run(["config","--local","--add",key,""])
        _=try await repo.run(["config","--local","--add",key,"fixture-helper"])
        _=try await repo.run(["config","--local","credential.https://example.invalid.custom","preserved"])
        let model=CredentialSettingsModel(repository:repo,access:nil,localAvailable:true)
        model.authorizeFile={_ in true}; model.confirmAction={_,_,_ in true}
        defer {model.deactivate()}
        model.activate(); try await wait {model.snapshot != nil && !model.busy}
        try require(model.mode=="advanced" && model.snapshot?.groups.count==1,"Scoped import differs")
        model.select(model.snapshot!.groups[0].id); try await wait {model.selected != nil}
        try require(model.draft.helpers==["","fixture-helper"] && !model.modified,"Helper reset/chain import differs")
        model.destination = .global
        try require(model.modified,"Destination-only edit was lost")
        model.cancelDraft(); try require(model.destination == .local && !model.modified,"Cancel did not restore scope")
        model.destination = .global
        let copied=await model.apply(); try require(copied && !model.modified,"Destination-only Save failed")
        let groups=try await repo.credentialConfiguration().groups
        try require(groups.count==2 && groups.allSatisfy{$0.helpers==["","fixture-helper"]},"Save did not copy chain/preserve source")
        model.draft.helpers=["replacement"]
        model.confirmAction={_,_,_ in false}
        let rejected=await model.apply(); try require(!rejected && model.modified,"Rejected replacement saved")
        model.confirmAction={_,_,_ in true}
        let replaced=await model.apply(); try require(replaced && !model.modified,"Accepted replacement failed")
        model.draft.username="unsaved"
        model.confirmAction={_,_,_ in false}; model.select(nil)
        try await Task.sleep(nanoseconds:30_000_000)
        try require(model.selected != nil && model.draft.username=="unsaved","Discard rejection lost draft")
        model.confirmAction={_,_,_ in true}; model.select(nil); try await wait {model.selected==nil}
        model.draft.url="https://new.invalid"; model.draft.helpers=["fixture-new"]; model.draft.useHTTPPath=true
        let added=await model.apply(); try require(added,"Add New failed")
        model.confirmAction={_,_,_ in false}; model.remove(); try await wait {!model.busy}
        try require(model.selected != nil,"Rejected Remove cleared selection")
        model.confirmAction={_,_,_ in true}; model.remove(); try await wait {!model.busy}
        try require(model.selected==nil && model.snapshot?.groups.count==2,"Accepted Remove differs")
        let custom=try await repo.run(["config","--local","--get","credential.https://example.invalid.custom"])
        try require(custom.text.trimmingCharacters(in:.whitespacesAndNewlines)=="preserved","Unrelated key lost")
        model.mode="global:unavailable-helper"; try require(model.validationError != nil,"Unavailable simple helper accepted")
        model.mode="none"; model.confirmAction={_,_,_ in false}
        let kept=await model.apply(); try require(!kept && model.snapshot?.groups.count==2,"Rejected simplification changed config")
        model.confirmAction={_,_,_ in true}; let cleared=await model.apply()
        try require(cleared && model.snapshot?.entries.isEmpty==true,"None did not clear scoped configuration")
        // An authorized captured write may finish after close; it must not refresh or reactivate.
        model.mode="advanced"; model.draft.helpers=["captured"]
        var write:CheckedContinuation<Void,Error>?,reads=0
        model.writeCredential={_,_,_ in try await withCheckedThrowingContinuation{write=$0}}
        model.readCredentials={_ in reads += 1;return try await repo.credentialConfiguration()}
        let save=Task {await model.applyForSettings(owner:nil)}; try await wait {write != nil}
        model.deactivate(); write?.resume(); let finished=await save.value
        try require(finished && reads==0 && CredentialSettingsModel.activeSaves==0,"Closed Apply refreshed stale page")
        model.refresh(); try require(!model.busy,"Apply resurrected closed page")
        let late=CredentialSettingsModel(repository:repo,access:nil,localAvailable:true)
        late.authorizeFile={_ in true}; var read:CheckedContinuation<GitCredentialSnapshot,Error>?
        late.readCredentials={_ in try await withCheckedThrowingContinuation{read=$0}}
        late.activate(); try await wait {read != nil}; late.deactivate()
        let empty=try await repo.credentialConfiguration(); read?.resume(returning:empty)
        try await Task.sleep(nanoseconds:30_000_000)
        try require(late.snapshot==nil && !late.busy,"Retired read changed visible state")
        let displayed=CredentialSettingsModel(repository:repo,access:nil,localAvailable:true)
        displayed.authorizeFile={_ in true}; displayed.activate();try await wait {displayed.snapshot != nil && !displayed.busy}
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:650),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:CredentialSettingsPage(model:displayed));window.contentView=host
        defer {displayed.deactivate(); window.contentView=nil;window.close()}
        for name in [NSAppearance.Name.aqua,.darkAqua] {host.appearance=NSAppearance(named:name);host.layoutSubtreeIfNeeded()}
        var launches=0; displayed.openPasswordManager={launches += 1;return false};displayed.openKeychain()
        try require(launches==1 && displayed.error != nil,"Password manager failure routing differs")
        print("Credential: scoped helper chains/reset, destination-only copy/Cancel, replacement/discard/remove confirmations, unknown key preservation, simple None/validation, forced-close Apply and late read fencing, light/dark host and injected password-manager routing passed. Private Git config only; no credential helper or user Keychain launched.")
    }
}
