// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

private actor ExactTextPasswords:ProxyPasswordStoring {
    var value="",loads=0,writes:[String]=[]
    func load()throws->String{loads+=1;return value}
    func save(_ value:String)throws{self.value=value;writes.append(value)}
    func snapshot()->(String,Int,[String]){(value,loads,writes)}
}
@MainActor enum SettingsExactTextVerification {
    static let nfc="caf\u{e9}",nfd="cafe\u{301}"
    static func exact(_ a:String,_ b:String)->Bool{Data(a.utf8)==Data(b.utf8)}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"Exact settings timeout at \(line)",code:2)}
    static func views(_ root:NSView)->[NSView]{[root]+root.subviews.flatMap(views)}
    static func window()->NSWindow{let w=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:900,height:760),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.isReleasedWhenClosed=false;w.alphaValue=0;w.appearance=NSAppearance(named:.darkAqua);return w}
    static func repository()async throws->GitRepository{
        let repo=GitRepository(root:URL(fileURLWithPath:CommandLine.arguments[1]),executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"]);_ = try await repo.run(["config","core.precomposeunicode","true"])
        _ = try await repo.run(["config","user.name",nfc]);_ = try await repo.run(["config","user.email","qa@example.invalid"])
        return repo
    }
    static func raw(_ repo:GitRepository,_ key:String,global:Bool=false)async throws->Data{
        try await repo.run(["-c","core.precomposeunicode=false","config",global ? "--global":"--local","--null","--get-all","--",key],successfulExitCodes:0...1).stdout
    }
    static func set(_ repo:GitRepository,_ key:String,_ value:String,add:Bool=false,global:Bool=false)async throws{
        _ = try await repo.run(["-c","core.precomposeunicode=false","config",global ? "--global":"--local",add ? "--add":"--replace-all","--",key,value])
    }
    static func identity()async throws{
        let repo=try await repository(),suite="TurtleGit.ExactIdentity."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,owner=window(),model=GitConfigurationSettingsModel(preferences:prefs)
        prefs.set(true,forKey:"HintHierarchicalConfig");model.window=owner;model.authorizeFile={_ in true}
        defer{model.deactivate();owner.close();prefs.removePersistentDomain(forName:suite)}
        model.activate(repository:repo,access:nil,localAvailable:true);try await wait{model.loaded && !model.busy};model.load(.local);try await wait{model.loaded && !model.busy}
        try require(exact(model.draft.name.value,nfc) && !model.changed,"Identity initial exact config missing")
        model.draft.name.value=nfd;try require(model.changed,"NFC to NFD identity edit was not dirty")
        try require(await model.applyForSettings(owner:owner),"Exact identity Apply failed")
        try require(try await raw(repo,"user.name")==Data((nfd+"\0").utf8) && !model.changed,"Identity Apply normalized accepted bytes or retained false dirty")
        var permission:CheckedContinuation<Bool,Never>?,writes=0,permissionCalls=0
        defer{permission?.resume(returning:false);permission=nil}
        model.destination = .global;model.draft.name.value=nfc
        model.authorizeFile={_ in permissionCalls+=1;if permissionCalls>1{return true};return await withCheckedContinuation{permission=$0}}
        let writer=model.writeSettings;model.writeSettings={r,value,source in writes+=1;try await writer(r,value,source)}
        // Native source/destination confirmation holds the captured save first.
        let applying=Task{await model.applyForSettings(owner:owner)}
        try await wait{owner.attachedSheet != nil}
        model.draft.name.value=nfd
        owner.endSheet(owner.attachedSheet!,returnCode:.alertSecondButtonReturn)
        try await wait{permission != nil};permission?.resume(returning:true);permission=nil
        let accepted=await applying.value
        try require(!accepted && writes==0 && model.changed && exact(model.draft.name.value,nfd) && model.error != nil,"Exact draft mutation during identity confirmation was written or lost")
        model.destination = .local;model.error=nil;model.authorizeFile={_ in true};model.draft.name.value=nfc
        var pending:CheckedContinuation<Void,Never>?,captured:GitConfigurationSettings?
        defer{pending?.resume();pending=nil}
        model.writeSettings={r,value,source in captured=value;await withCheckedContinuation{pending=$0};try await writer(r,value,source)}
        let saving=Task{await model.applyForSettings(owner:owner)};try await wait{pending != nil}
        model.draft.name.value=nfd;pending?.resume();pending=nil
        try require(await saving.value,"Already accepted immutable identity save failed")
        let capturedNameBytes=try await raw(repo,"user.name")
        try require(exact(captured!.name.value,nfc) && exact(model.draft.name.value,nfd) && model.changed && capturedNameBytes==Data((nfc+"\0").utf8),"Accepted identity snapshot followed newer draft or cleared its dirty state")
        model.deactivate();let before=model.draft;model.apply();try require(model.draft==before && GitConfigurationSettingsModel.activeSaves==0,"Retired identity page accepted another save")
        print("PASS exact identity dirty/Apply and raw Git bytes; real confirmation rejects canonical-only edit; accepted immutable write preserves newer dirty draft and retired command gate")
    }
    static func credentials()async throws{
        let repo=try await repository(),a="https://exact.invalid/"+nfc,b="https://exact.invalid/"+nfd,helper="!helper "+nfc,replacement="!helper "+nfd
        for (url,user) in [(a,nfc),(b,"other-user")]{try await set(repo,"credential."+url+".helper",helper);try await set(repo,"credential."+url+".username",user);try await set(repo,"credential."+url+".username",user+"-last",add:true);try await set(repo,"credential."+url+".useHttpPath","yes");try await set(repo,"credential."+url+".useHttpPath","off",add:true)}
        let model=CredentialSettingsModel(repository:repo,access:nil,localAvailable:true),owner=window(),host=NSHostingView(rootView:CredentialSettingsPage(model:model))
        owner.contentView=host;model.window=owner;model.authorizeFile={_ in true};model.confirmAction={_,_,_ in true}
        defer{model.deactivate();owner.contentView=nil;owner.close()};model.activate();owner.orderFront(nil)
        try await wait{model.snapshot != nil && !model.busy}
        let groups=model.snapshot!.groups,first=groups.first{exact($0.url,a)}!,second=groups.first{exact($0.url,b)}!
        try require(first.id != second.id && Set(groups.map(\.id)).count==2,"Canonical credential URLs collapsed group identifiers")
        model.select(first.id);try await wait{!model.busy && model.selected==first.id};owner.contentView?.layoutSubtreeIfNeeded()
        try await wait{views(host).contains{($0 as? NSComboBox)?.accessibilityLabel()=="Credential helper"}}
        let combo=views(host).compactMap{$0 as? NSComboBox}.first{$0.accessibilityLabel()=="Credential helper"}!,editor=combo.delegate as! CloneHistoryCombo.Coordinator,staleCallback=editor.change
        var fields:[GitCredentialFields]=[]
        model.writeCredentialFields={value,file,expected,mask in fields.append(mask);try await repo.saveCredential(value,file:file,expected:expected,fields:mask)}
        editor.change(replacement);try await wait{owner.contentView?.layoutSubtreeIfNeeded();return exact(combo.stringValue,replacement)};try require(model.modified && exact(model.draft.helpers[0],replacement),"Hosted helper binding ignored canonical-only edit")
        try require(await model.apply(),"Exact helper Apply failed")
        let helperBytes=try await raw(repo,"credential."+a+".helper"),usernames=try await raw(repo,"credential."+a+".username"),httpPath=try await raw(repo,"credential."+a+".useHttpPath")
        try require(fields.last == .helper && helperBytes==Data((replacement+"\0").utf8),"Helper dirty mask/Apply normalized bytes")
        try require(usernames==Data((nfc+"\0"+nfc+"-last\0").utf8) && httpPath==Data("yes\0off\0".utf8),"Helper Apply collapsed untouched repeated credential fields")
        model.editUsername(nfd,identity:model.editorIdentity);try require(model.modified,"Canonical username edit was not dirty");try require(await model.apply(),"Exact username Apply failed")
        let usernameBytes=try await raw(repo,"credential."+a+".username")
        try require(fields.last == .username && usernameBytes==Data((nfd+"\0").utf8),"Username Apply lost exact field mask/bytes")
        model.select(second.id);try await wait{!model.busy && model.selected==second.id};staleCallback("stale-helper")
        try require(exact(model.draft.url,b) && exact(model.draft.helpers[0],helper),"Distinct selection or stale native helper callback changed another exact URL")
        model.editURL(a,identity:model.editorIdentity);try require(model.modified && !model.editsExistingOrigin,"Canonical-only URL edit did not leave existing origin")
        model.cancelDraft();model.select(first.id);try await wait{!model.busy && model.selected==first.id}
        var answer:CheckedContinuation<Bool,Never>?
        defer{answer?.resume(returning:false);answer=nil}
        model.confirmAction={_,_,_ in await withCheckedContinuation{answer=$0}}
        model.editHelper(helper,identity:model.editorIdentity)
        let saving=Task{await model.saveAdvanced()};try await wait{answer != nil};model.draft.helpers=[replacement];answer?.resume(returning:true);answer=nil
        try require(!(await saving.value) && model.modified && exact(model.draft.helpers[0],replacement),"Held credential confirmation accepted exact-only changed draft")
        model.cancelDraft();model.confirmAction={_,_,_ in true}
        let before=try Data(contentsOf:repo.root.appendingPathComponent(".git/config"))
        try await set(repo,"credential."+b+".username","external "+nfd)
        model.editHelper(helper,identity:model.editorIdentity);try require(!(await model.apply()) && model.error != nil,"Stale credential snapshot wrote across external exact changes")
        let staleHelper=try await raw(repo,"credential."+a+".helper"),externalUser=try await raw(repo,"credential."+b+".username")
        try require(staleHelper==Data((replacement+"\0").utf8) && externalUser==Data(("external "+nfd+"\0").utf8),"Stale refusal changed selected or neighboring exact group")
        try require(try Data(contentsOf:repo.root.appendingPathComponent(".git/config")) != before,"External stale setup did not change config")
        model.cancelDraft();model.refresh();try await wait{!model.busy};model.select(second.id);try await wait{!model.busy && model.selected==second.id};model.remove();try await wait{!model.busy}
        let remaining=try await repo.credentialConfiguration()
        try require(remaining.groups.count==1 && exact(remaining.groups[0].url,a),"Remove merged canonical groups or removed the wrong exact URL")
        model.select(remaining.groups[0].id);try await wait{!model.busy && model.selected==remaining.groups[0].id}
        var writing:CheckedContinuation<Void,Never>?
        defer{writing?.resume();writing=nil}
        model.writeCredentialFields={value,file,expected,mask in await withCheckedContinuation{writing=$0};try await repo.saveCredential(value,file:file,expected:expected,fields:mask)}
        model.editHelper(helper,identity:model.editorIdentity)
        let acceptedWrite=Task{await model.apply()};try await wait{writing != nil}
        model.draft.helpers=[replacement];model.draft.username=nfc;writing?.resume();writing=nil
        let wrote=await acceptedWrite.value,writtenHelper=try await raw(repo,"credential."+a+".helper")
        try require(wrote && model.modified && exact(model.draft.helpers[0],replacement) && exact(model.draft.username,nfc) && writtenHelper==Data((helper+"\0").utf8),"Accepted credential readback replaced a newer exact draft or followed mutable fields")
        print("PASS hosted credential helper exact edit; distinct URL IDs/selection, username field mask, untouched repeated values, stale editor/confirmation/snapshot refusal and exact Remove")
    }
    static func network()async throws{
        let repo=try await repository(),suite="TurtleGit.ExactNetwork."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,cache=ExactTextPasswords(),owner=window()
        let model=NetworkSettingsModel(repository:repo,access:nil,localAvailable:true,preferences:prefs,passwords:cache)
        model.authorizeFile={_ in true};owner.contentView=NSHostingView(rootView:NetworkSettingsPage(model:model));model.window=owner
        defer{model.deactivate();owner.contentView=nil;owner.close();prefs.removePersistentDomain(forName:suite)}
        model.activate();owner.orderFront(nil);try await wait{model.loaded && !model.busy}
        model.proxy.enabled=true;model.proxy.server="proxy.invalid";model.proxy.port="8080";model.proxy.username=nfc;model.proxy.password=nfc
        try require(await model.apply(owner:owner),"Initial private proxy Apply failed")
        model.proxy.username=nfd;model.proxy.password=nfd;try require(model.modified,"Canonical proxy credentials were not dirty")
        var permission:CheckedContinuation<Bool,Never>?,permissionCalls=0
        defer{permission?.resume(returning:false);permission=nil}
        model.authorizeFile={_ in permissionCalls+=1;if permissionCalls>1{return true};return await withCheckedContinuation{permission=$0}}
        let obsolete=Task{await model.apply(owner:owner)};try await wait{permission != nil}
        model.proxy.username=nfc;model.proxy.password=nfc;permission?.resume(returning:true);permission=nil
        let refused=await obsolete.value,prior=try await repo.proxyConfiguration(source:.global)
        try require(!refused && exact(prior.password,nfc),"Proxy accepted obsolete canonical-only draft after permission wait")
        model.authorizeFile={_ in true};model.error=nil;model.proxy.username=nfd;model.proxy.password=nfd
        try require(await model.apply(owner:owner),"Exact proxy credential Apply failed")
        let actual=try await repo.proxyConfiguration(source:.global),cached=await cache.snapshot()
        try require(exact(actual.username,nfd) && exact(actual.password,nfd) && exact(cached.0,nfd),"Proxy global config or private password consumer normalized credentials")
        model.proxy.enabled=false;try require(await model.apply(owner:owner),"Proxy Disable failed")
        let again=NetworkSettingsModel(repository:repo,access:nil,localAvailable:true,preferences:prefs,passwords:cache);again.authorizeFile={_ in true};defer{again.deactivate()};again.activate();try await wait{again.loaded && !again.busy}
        try require(!again.proxy.enabled && exact(again.proxy.username,nfd) && exact(again.proxy.password,nfd),"Disabled proxy cache/preference reload collapsed exact credentials")
        // A single real executable accepts either lexical Unicode spelling on
        // normalization-insensitive filesystems; the saved preference stays exact.
        let executable=repo.root.appendingPathComponent("ssh-"+nfc)
        try Data("#!/bin/sh\nprintf 'OpenSSH_fixture\\n'\n".utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let nfcPath=repo.root.path+"/ssh-"+nfc,nfdPath=repo.root.path+"/ssh-"+nfd
        // On a normalization-sensitive volume also create the second spelling.
        if !FileManager.default.isExecutableFile(atPath:nfdPath){try Data("#!/bin/sh\nprintf 'OpenSSH_fixture\\n'\n".utf8).write(to:URL(string:"file://"+nfdPath.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed)!)!);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:nfdPath)}
        model.editSSHPath(nfcPath,identity:model.editorIdentity);try require(await model.apply(owner:owner),"Initial SSH private executable Apply failed")
        let countBefore=await cache.snapshot().2.count
        model.editSSHPath(nfdPath,identity:model.editorIdentity);try require(model.modified,"Canonical-only SSH path edit was not dirty")
        try await wait{owner.contentView?.layoutSubtreeIfNeeded();return views(owner.contentView!).compactMap{$0 as? PathEntryField.Field}.contains{exact($0.stringValue,nfdPath)}}
        try require(await model.apply(owner:owner),"Exact SSH private executable Apply failed")
        let countAfter=await cache.snapshot().2.count
        try require(exact(prefs.string(forKey:"TurtleGit.SSHClient")!,nfdPath) && countAfter==countBefore,"SSH preference normalized path or rewrote unrelated cached password")
        var held:CheckedContinuation<Void,Never>?,accepted:GitProxySettings?
        defer{held?.resume();held=nil}
        model.proxy.username=nfc;model.proxy.password=nfc;model.writeProxy={value in accepted=value;await withCheckedContinuation{held=$0};try await repo.saveProxyConfiguration(value)}
        let saving=Task{await model.apply(owner:owner)};try await wait{held != nil};model.proxy.username=nfd;model.proxy.password=nfd;held?.resume();held=nil
        try require(await saving.value && model.modified && exact(model.proxy.password,nfd) && exact(accepted!.password,nfc),"Accepted proxy snapshot followed newer canonical draft or cleared dirty state")
        model.cancelDraft();try require(exact(model.proxy.password,nfc) && !model.modified,"Network Cancel did not restore exact accepted snapshot")
        print("PASS private proxy credentials/config/cache and disabled reload; native SSH path exact-only dirty/save, unrelated password preserved and immutable accepted save/newer draft/Cancel")
    }
}
