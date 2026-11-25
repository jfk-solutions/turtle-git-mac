// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum SSHConfigurationAccessVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func settle(_ label:String,_ predicate:()->Bool)async throws{
        for _ in 0..<1500 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"SSH configuration manager timeout: "+label)
    }
    final class Provider:RepositoryBookmarkProvider,@unchecked Sendable {
        private let lock=NSLock()
        private var starts=0,stops=0
        var balanced:Bool{lock.lock();defer{lock.unlock()};return starts==stops}
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark{ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{lock.lock();defer{lock.unlock()};starts += 1;return true}
        func stopAccessing(_ url:URL){lock.lock();defer{lock.unlock()};stops += 1}
    }
    static func verify(base:URL,git:URL)async throws {
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let home=base.appendingPathComponent("home"),ssh=home.appendingPathComponent(".ssh"),included=base.appendingPathComponent("explicit Include")
        try FileManager.default.createDirectory(at:ssh,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:included,withIntermediateDirectories:true)
        let config=ssh.appendingPathComponent("config"),hosts=ssh.appendingPathComponent("known_hosts")
        let configBytes=Data("Include deliberately-not-traversed/*\n".utf8),hostBytes=Data("unchanged known-host fixture\n".utf8)
        try configBytes.write(to:config);try hostBytes.write(to:hosts)
        let provider=Provider(),store=SSHConfigurationAccessStore(storageURL:base.appendingPathComponent("permissions/grants.json"),provider:provider)
        let parent=NSWindow(contentRect:.init(x:-24000,y:-24000,width:720,height:460),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false;parent.alphaValue=0;parent.orderFront(nil)
        var current=true
        let controller=SSHConfigurationAccessWindowController(store:store,requireSecurityScope:true,parentIsCurrent:{current})
        let child=controller.window!;child.alphaValue=0
        var closed=0;controller.onClosed={closed += 1};parent.beginSheet(child,completionHandler:{_ in})
        defer{current=false;controller.retire();parent.orderOut(nil);parent.close()}
        try await settle("manager presentation"){child.isVisible && child.sheetParent===parent}
        controller.homeDirectory=home
        var reply:((NSApplication.ModalResponse)->Void)?,chooser:NSOpenPanel?
        controller.presentPanel={panel,window,answer in chooser=panel;reply=answer;window.beginSheet(panel,completionHandler:{_ in})}
        let invalid=base.appendingPathComponent("missing configuration selection")
        controller.selectedURLs={_ in [invalid,ssh,included]}
        controller.browse()
        try require(chooser?.showsHiddenFiles==true && chooser?.canChooseFiles==true && chooser?.canChooseDirectories==true && chooser?.canCreateDirectories==true && chooser?.directoryURL?.standardizedFileURL.path==ssh.standardizedFileURL.path,"Chooser did not start in private .ssh with explicit file/directory access: actual=\(String(describing:chooser?.directoryURL)), expected=\(ssh), hidden=\(String(describing:chooser?.showsHiddenFiles)), files=\(String(describing:chooser?.canChooseFiles)), folders=\(String(describing:chooser?.canChooseDirectories)), create=\(String(describing:chooser?.canCreateDirectories))")
        try require(SSHConfigurationAccessWindowController.activeOperations>0,"Chooser lost Quit lifetime")
        reply?(.OK);reply?(.OK)
        try await settle("accepted chooser detaches before exact grant publication"){controller.panel==nil && controller.model.grants.count==2 && child.attachedSheet==nil}
        try require(Set(controller.model.grants.map(\.configuredPath))==Set([ssh.path,included.path]),"Permission selection traversed Include or changed explicit locations")
        try require(controller.model.grants.allSatisfy{$0.kind == .directory},"Folder permissions lost type")
        try require(controller.model.error?.contains(invalid.path)==true && controller.model.error?.contains("Some permissions were saved")==true,"A later successful grant masked the first selected location failure")
        controller.model.selection=Set(controller.model.grants.map(\.id));controller.renew()
        try await settle("renewal scopes drain"){!controller.model.busy && SSHConfigurationAccessWindowController.activeOperations==0 && provider.balanced}
        let before=controller.model.grants
        // A separately renewed record is not the displayed opaque snapshot.
        try store.remember(ssh,requireSecurityScope:true)
        controller.forget()
        try require(controller.model.error != nil && (try store.grants()).count==2,"Stale selection forgot a replacement grant")
        controller.model.refresh();controller.model.selection=Set(controller.model.grants.map(\.id));controller.forget()
        try require(try store.grants().isEmpty,"Current Forget did not remove exact selected grants")
        try require(try Data(contentsOf:config)==configBytes && Data(contentsOf:hosts)==hostBytes,"Permissions UI modified SSH configuration/known hosts")
        try require(!before.isEmpty,"Native permission list never acquired grants")
        // A retired page's pending chooser cannot publish late or duplicate URLs.
        controller.browse();let late=reply
        try require(controller.panel != nil,"Second actual owned chooser missing")
        current=false;controller.retire();late?(.OK);late?(.OK)
        try await settle("forced owner retirement and paired sheet drain"){controller.released && controller.panel==nil && child.sheetParent==nil && parent.attachedSheet==nil && SSHConfigurationAccessWindowController.activeOperations==0}
        try require(closed==1 && (try store.grants()).isEmpty && !child.isVisible && provider.balanced,"Late reply mutated permissions or owner/operation lifetime leaked")
        try require(try Data(contentsOf:config)==configBytes && Data(contentsOf:hosts)==hostBytes,"Retirement modified private SSH input bytes")
        let suite="TurtleGit.SSHConfiguration.Native."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let repository=GitRepository(root:base,executable:git,sshConfigurationAccess:nil)
        let network=NetworkSettingsModel(repository:repository,access:nil,localAvailable:false,preferences:prefs)
        network.authorizeFile={_ in true}
        network.readProxy={_ in var proxy=GitProxySettings();proxy.enabled=true;return proxy}
        network.window=parent;network.activate()
        defer{network.deactivate()}
        try await settle("Network page metadata"){network.loaded && !network.busy}
        var returned:((NSApplication.ModalResponse)->Void)?
        network.makeConfigurationAccess={
            let manager=SSHConfigurationAccessWindowController(store:store,requireSecurityScope:true)
            manager.homeDirectory=home
            manager.presentPanel={panel,window,answer in returned=answer;window.beginSheet(panel,completionHandler:{_ in})}
            manager.selectedURLs={_ in [config]}
            return manager
        }
        network.showConfigurationAccess(identity:network.editorIdentity)
        let embedded=network.configurationAccessController
        try require(embedded != nil && network.configurationAccessOpen && embedded?.window?.sheetParent===parent,"Network did not present its owned Configuration Access child")
        embedded?.browse();try require(embedded?.panel != nil,"Network child did not admit real chooser")
        network.deactivate();returned?(.OK)
        try await settle("Network deactivation retires exact child/panel"){network.configurationAccessController==nil && !network.configurationAccessOpen && embedded?.released==true && parent.attachedSheet==nil && SSHConfigurationAccessWindowController.activeOperations==0}
        try require(try store.grants().isEmpty,"Deactivated Network page accepted late configuration permission")
        let failed=NetworkSettingsModel(repository:repository,access:nil,localAvailable:false,preferences:prefs)
        failed.authorizeFile={_ in true}
        failed.readProxy={_ in throw Failure(description:"Private proxy metadata read refused")}
        failed.window=parent;failed.activate();defer{failed.deactivate()}
        try await settle("failed proxy read releases independent permission repair"){!failed.busy && !failed.loaded && failed.error != nil}
        try require(failed.canManageConfigurationAccess && !failed.canEditSSH && !failed.acceptsEditor(failed.editorIdentity),"Failed proxy loading blocked permission repair or enabled client edits")
        failed.makeConfigurationAccess={SSHConfigurationAccessWindowController(store:store,requireSecurityScope:true)}
        failed.showConfigurationAccess(identity:failed.editorIdentity)
        let recovery=failed.configurationAccessController
        try require(recovery != nil && recovery?.window?.sheetParent===parent,"Failed Network metadata could not open permission repair")
        failed.deactivate()
        try await settle("failed metadata page retires permission repair"){failed.configurationAccessController==nil && !failed.configurationAccessOpen && recovery?.released==true && parent.attachedSheet==nil && SSHConfigurationAccessWindowController.activeOperations==0}
        print("PASS: SSH configuration access native explicit folder/Include grants, private .ssh chooser, one-use callbacks, actual sheet detachment, snapshot Renew/Forget ABA refusal, balanced scopes, source retirement/late replies and Quit drainage; unchanged configuration bytes; no external SSH or physical/signed acceptance claimed")
    }
}
