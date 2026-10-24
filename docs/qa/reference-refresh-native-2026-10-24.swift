// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor @main struct ReferenceRefreshVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    static var phase="setup" {didSet{
        if CommandLine.arguments.count>1 {let file=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(".git/reference-refresh-phase");try? Data(phase.utf8).write(to:file)}
    }}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(message:"\(phase) line \(line): "+message)}}
    static func wait(line:Int = #line,_ condition:()->Bool)async throws{for _ in 0..<3000{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"\(phase) timeout line \(line)")}
    static let nfc="caf\u{e9}",nfd="cafe\u{301}"
    static func exact(_ a:String,_ b:String)->Bool{a.utf8.elementsEqual(b.utf8)}
    static func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    static func offscreen(_ window:NSWindow?){window?.isReleasedWhenClosed=false;window?.alphaValue=0;window?.setFrameOrigin(.init(x:-12000,y:-12000));window?.orderFront(nil)}
    static func f5(_ window:NSWindow,modifiers:NSEvent.ModifierFlags=[])->NSEvent{NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{f708}",charactersIgnoringModifiers:"\u{f708}",isARepeat:false,keyCode:96)!}
    @MainActor final class Context {
        let root:URL,repo:GitRepository,prefs:UserDefaults,suite:String
        var rebases:[RebaseWindowController]=[],fetches:[FetchWindowController]=[],pushes:[PushWindowController]=[],release:[()->Void]=[]
        var base=""
        init(root:URL,git:URL)async throws{
            self.root=root;repo=GitRepository(root:root,executable:git);suite="TurtleGit.ReferenceRefresh."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"ConfirmKillProcess")
            _ = try await repo.run(["init","-b","main"])
            for (k,v) in [("user.name","Refresh QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["-c","core.precomposeunicode=false","config",k,v])}
            for n in 0..<4 {try Data("\(n)\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"commit \(n)");if n==0 {base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);_ = try await repo.run(["branch","upstream"])}}
            for name in [nfc,nfd,"other"] {_ = try await repo.run(["-c","core.precomposeunicode=false","remote","add",name,root.appendingPathComponent("unused.git").path])}
            let names=try await repo.remoteNames()
            try require(names.contains{exact($0,nfc)} && names.contains{exact($0,nfd)},"Fixture setup collapsed canonical remote names")
            _ = try await repo.run(["-c","core.precomposeunicode=false","config","branch.main.remote",nfd]);_ = try await repo.run(["-c","core.precomposeunicode=false","config","branch.main.merge","refs/heads/topic-one"])
        }
        func rebase()async throws->RebaseWindowController{
            let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs);rebases.append(owner);offscreen(owner.window);owner.model.load(upstream:"refs/heads/upstream",force:true)
            try await settled(owner.model);return owner
        }
        func fetch(_ pull:Bool)async throws->FetchWindowController{
            let owner=FetchWindowController(repository:repo,access:nil,isPull:pull,preferences:prefs);fetches.append(owner);offscreen(owner.window);owner.model.load()
            try await wait{owner.model.pendingOperations==0 && !owner.model.busy && !owner.model.preparing};try require(owner.model.error==nil,"Initial Fetch/Pull failed");return owner
        }
        func cleanup()async{
            release.forEach{$0()}
            for window in rebases.compactMap(\.window)+fetches.compactMap(\.window)+pushes.compactMap(\.window) {
                if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil);sheet.close()}
                window.close()
            }
            for _ in 0..<3000 {if rebases.allSatisfy({!$0.transportBatchWorkPending}) && fetches.allSatisfy({!$0.serviceWorkPending}) && pushes.allSatisfy({!$0.serviceWorkPending}) && RemoteSettingsWindowModel.activeOperations==0 && RemoteSettingsWindowModel.activeRetirements==0 {break};try? await Task.sleep(nanoseconds:10_000_000)}
            (rebases.compactMap(\.window)+fetches.compactMap(\.window)+pushes.compactMap(\.window)).forEach{$0.orderOut(nil)};prefs.removePersistentDomain(forName:suite)
        }
    }
    static func settled(_ model:RebaseWindowModel)async throws{try await wait{!model.busy && !model.loadingPlan && model.pendingBatchWorkers==0}}
    static func run(_ body:(Context)async throws->Void)async throws{
        let c=try await Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do{try await body(c);await c.cleanup();try require(c.rebases.allSatisfy{!$0.transportBatchWorkPending} && c.fetches.allSatisfy{!$0.serviceWorkPending} && c.pushes.allSatisfy{!$0.serviceWorkPending},"Owned refresh work survived cleanup")}catch{fputs("Original fixture failure before cleanup: \(error)\n",stderr);await c.cleanup();throw error}
    }
    static func beginManager(_ model:FetchWindowModel)async throws->FetchWindowModel.RemoteManagerReceipt{
        model.manage(model.formContext);try await wait{model.remoteManagerModel != nil && model.window?.attachedSheet != nil && model.remoteManagerModel?.busy==false}
        try require(model.window?.attachedSheet?.alphaValue==0 && model.window?.attachedSheet?.isReleasedWhenClosed==false,"Manager sheet escaped invisible ownership")
        return model.remoteManagerReceipt!
    }
    static func popup(_ window:NSWindow)async throws->NSPopUpButton{
        try await wait{descendants(window.contentView!).compactMap{$0 as? TransportRemotePopup}.contains{$0.accessibilityLabel()=="Remote archive"}}
        return descendants(window.contentView!).compactMap{$0 as? TransportRemotePopup}.first{$0.accessibilityLabel()=="Remote archive"}!
    }
    static func acknowledgeError(_ owner:NSWindow)async throws {
        try await wait{owner.attachedSheet?.contentView.map{descendants($0).compactMap{$0 as? NSButton}.contains{$0.title=="OK"}}==true}
        let sheet=owner.attachedSheet!;sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        let ok=descendants(sheet.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="OK"}!
        ok.performClick(nil);try await wait{owner.attachedSheet==nil}
    }
    static func choose(_ name:String,in button:NSPopUpButton)throws{
        guard let index=button.itemArray.firstIndex(where:{exact($0.title,name)}),let action=button.action else{throw Failure(message:"Missing exact native remote item "+name)}
        button.selectItem(at:index);_ = NSApp.sendAction(action,to:button.target,from:button)
    }
    static func rebase()async throws{try await run{c in
        phase="Rebase F5 setup";let owner=try await c.rebase(),m=owner.model,window=owner.window as! RebaseNativeWindow;window.keyOwnerQuery={_ in true}
        try require(m.plan?.entries.count==3,"Fixture lacks three replay revisions")
        _ = try await c.repo.run(["branch","alias"]);m.chooseBranch("refs/heads/alias");try await settled(m)
        m.selection=[m.entries[0].id];m.setAction(.skip);m.move(up:false)
        let edited=m.plan!.entries.map{[$0.id,$0.action.rawValue]},oldPlan=m.plan!.branchHash
        _ = try await c.repo.run(["tag","new-catalog-tag"])
        let head=try await c.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:c.root.appendingPathComponent(".git/config"))
        phase="Rebase actual F5 catalog and source reset";_ = window.performKeyEquivalent(with:f5(window));try await settled(m)
        let expected=try await c.repo.rebasePlan(m.options)
        try require(exact(m.options.branch,"refs/heads/main") && exact(m.options.upstream,"refs/heads/upstream"),"F5 did not select current HEAD/preserve upstream")
        try require(m.plan!.entries.map{[$0.id,$0.action.rawValue]}==expected.entries.map{[$0.id,$0.action.rawValue]} && m.plan!.entries.map{[$0.id,$0.action.rawValue]} != edited,"Source refresh retained edited action/order instead of fresh plan defaults")
        try require(m.references.contains{exact($0.name,"refs/tags/new-catalog-tag")} && m.plan!.branchHash==oldPlan && m.draftEntries.isEmpty,"F5 omitted new reference or retained added draft")
        try await wait{descendants(window.contentView!).compactMap{$0 as? NSPopUpButton}.contains{$0.accessibilityLabel()=="Upstream" && $0.itemArray.contains{exact($0.title,"new-catalog-tag")}}}
        phase="Rebase source option/disabled key fences";let refs=m.references.map{GitReferenceName($0.name)};var reads=0
        m.readRefreshReferences={token in reads += 1;return try await c.repo.checkoutReferences(includeFetchHead:true,cancellation:token)}
        _ = window.performKeyEquivalent(with:f5(window,modifiers:.shift));try require(reads==0 && refs==m.references.map{GitReferenceName($0.name)},"Modified F5 refreshed dialog")
        m.options.isCherryPick=true;m.refreshFromSourceCommand();try require(reads==0,"Idle Cherry Pick incorrectly refreshed branch plan");m.options.isCherryPick=false
        m.revisionMenuLog.confirmingQuit=true;m.refreshFromSourceCommand();try require(reads==0,"Quit allowed F5");m.revisionMenuLog.confirmingQuit=false
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:20,height:20),styleMask:.borderless,backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;window.beginSheet(sheet,completionHandler:nil)
        _ = window.performKeyEquivalent(with:f5(window));try require(reads==0,"Attached sheet allowed parent F5");window.endSheet(sheet);sheet.close();try await wait{window.attachedSheet==nil}
        let finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(head==finalHead && index==Data(contentsOf:c.root.appendingPathComponent(".git/index")) && config==Data(contentsOf:c.root.appendingPathComponent(".git/config")),"Read-only F5 changed repository")
    }}
    static func metadata()async throws{try await run{c in
        for pull in [false,true] {
            phase="\(pull ? "Pull":"Fetch") exact native remote chooser";let owner=try await c.fetch(pull),m=owner.model
            let button=try await popup(owner.window!);try require(button.itemArray.filter{exact($0.title,nfc)||exact($0.title,nfd)}.count==2,"Native remote popup merged NFC/NFD")
            try await wait{button.isEnabled};try choose(nfc,in:button);try await wait{!m.preparing};try require(exact(m.options.remote,nfc),"Native NFC selection lost bytes")
            try await wait{button.isEnabled};try choose(nfd,in:button);try await wait{!m.preparing};try require(exact(m.options.remote,nfd),"Native NFD selection lost bytes")
            m.options.tags = .disabled;m.options.prune = .enabled;m.options.namedRemoteFetchAll=false;m.depth="7";m.squash=pull;m.noCommit=pull
            phase="\(pull ? "Pull":"Fetch") actual captured manager return";let receipt=try await beginManager(m),child=m.remoteManagerModel!
            _ = try await c.repo.run(["-c","core.precomposeunicode=false","config","branch.main.remote",nfc]);_ = try await c.repo.run(["-c","core.precomposeunicode=false","config","branch.main.merge","refs/heads/topic-two"])
            _ = try await c.repo.run(["-c","core.precomposeunicode=false","config","remote."+nfc+".tagopt","--no-tags"]);_ = try await c.repo.run(["-c","core.precomposeunicode=false","config","remote."+nfc+".prune","true"])
            let config=try Data(contentsOf:c.root.appendingPathComponent(".git/config")),index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),head=try await c.repo.run(["rev-parse","HEAD"]).stdout
            child.close();try await wait{m.remoteManagerModel==nil && m.pendingOperations==0 && !m.busy && !m.preparing}
            try require(m.error==nil && exact(m.options.remote,nfc) && exact(m.options.branch,"topic-two") && m.tagsDefault=="None" && m.pruneDefault=="true","Manager return did not reread tracking branch/remote/options")
            try require(m.options.tags == .disabled && m.options.prune == .enabled && !m.options.namedRemoteFetchAll && m.depth=="7" && m.squash==pull && m.noCommit==pull,"Manager return reset unrelated operation draft")
            m.remoteManagerReturned(receipt);try require(m.pendingOperations==0,"Duplicate retired child dispatched refresh")
            let finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
            try require(config==Data(contentsOf:c.root.appendingPathComponent(".git/config")) && index==Data(contentsOf:c.root.appendingPathComponent(".git/index")) && head==finalHead,"Metadata refresh wrote repository")
            phase="\(pull ? "Pull":"Fetch") removed exact manager selection"
            m.options.remote=nfd;m.options.allRemotes=false
            c.prefs.set(nfc,forKey:(pull ? "Pull.":"Fetch.")+c.root.path+".remote")
            let removedReceipt=try await beginManager(m),removing=m.remoteManagerModel!
            m.remoteManagerReturned(receipt)
            try require(m.remoteManagerReceipt==removedReceipt && m.remoteManagerModel === removing && !m.busy,"Old manager reply consumed a replacement child")
            try await c.repo.removeRemote(name:nfd)
            _ = try await c.repo.run(["-c","core.precomposeunicode=false","config","branch.main.remote",nfd])
            let remaining=try await c.repo.remoteNames();try require(remaining.contains{exact($0,nfc)} && !remaining.contains{exact($0,nfd)},"Manager removed wrong canonical remote")
            let afterRemoval=try Data(contentsOf:c.root.appendingPathComponent(".git/config"))
            removing.close();try await wait{m.remoteManagerModel==nil && m.pendingOperations==0 && !m.busy && !m.preparing}
            try require(!exact(m.options.remote,nfd) && m.options.allRemotes == !pull,"Missing exact remote did not use source first-row fallback")
            try require(afterRemoval==Data(contentsOf:c.root.appendingPathComponent(".git/config")),"Manager refresh wrote missing remote config")
            m.remoteManagerReturned(removedReceipt);owner.window?.close()
            _ = try await c.repo.run(["-c","core.precomposeunicode=false","remote","add",nfd,c.root.appendingPathComponent("unused.git").path])
            // Restore the original tracked pair for the next independent dialog.
            _ = try await c.repo.run(["-c","core.precomposeunicode=false","config","branch.main.remote",nfd]);_ = try await c.repo.run(["-c","core.precomposeunicode=false","config","branch.main.merge","refs/heads/topic-one"])
        }
        phase="Push removed exact selected remote";let owner=PushWindowController(repository:c.repo,access:nil,preferences:c.prefs);c.pushes.append(owner);offscreen(owner.window);owner.model.load();try await wait{owner.model.pendingOperations==0 && !owner.model.busy && !owner.model.preparing}
        let button=try await popup(owner.window!);try await wait{button.isEnabled};try choose(nfd,in:button);try require(exact(owner.model.options.remote,nfd),"Push native NFD selection lost")
        try await c.repo.removeRemote(name:nfd);_ = try await c.repo.run(["-c","core.precomposeunicode=false","config","branch.main.remote",nfd])
        let stored=try Data(contentsOf:c.root.appendingPathComponent(".git/config"))
        let window=owner.window as! PushNativeWindow;window.keyOwnerQuery={_ in true};_ = window.performKeyEquivalent(with:f5(window));try await wait{owner.model.pendingOperations==0 && !owner.model.busy && !owner.model.preparing}
        try require(!exact(owner.model.options.remote,nfd) && owner.model.remotes.contains{exact($0,nfc)},"Push F5 retained removed NFD remote through NFC sibling")
        try require(stored==Data(contentsOf:c.root.appendingPathComponent(".git/config")),"Push F5 wrote configuration")
    }}
    static func lifetime()async throws{try await run{c in
        phase="held Rebase catalog";let owner=try await c.rebase(),m=owner.model,catalog=try await c.repo.checkoutReferences(includeFetchHead:true)
        m.selection=[m.entries[0].id];m.setAction(.skip);let accepted=m.plan!.entries.map{[$0.id,$0.action.rawValue]}
        var held:[Int:CheckedContinuation<[CheckoutReference],Error>]=[:],reads=0
        c.release.append{for value in held.values{value.resume(throwing:CancellationError())};held=[:]}
        m.readRefreshReferences={_ in reads += 1;let n=reads;return try await withCheckedThrowingContinuation{held[n]=$0}}
        m.refreshFromSourceCommand();try await wait{held[1] != nil};try require(m.refreshingReferences && !m.canStart && m.plan!.entries.map{[$0.id,$0.action.rawValue]}==accepted,"Pending read cleared accepted plan")
        phase="superseded Rebase receipt";m.refreshFromSourceCommand();try await wait{held[2] != nil};held.removeValue(forKey:1)!.resume(returning:catalog);try await wait{m.pendingBatchWorkers==1}
        try require(m.refreshingReferences && m.plan!.entries.map{[$0.id,$0.action.rawValue]}==accepted,"Old read replaced accepted/current refresh")
        _ = m.cancelPreparation();held.removeValue(forKey:2)!.resume(returning:catalog);try await settled(m)
        try require(m.plan!.entries.map{[$0.id,$0.action.rawValue]}==accepted && m.canStart,"Cancelled refresh discarded accepted plan")
        phase="failed Rebase preserves draft";m.readRefreshReferences={_ in throw Failure(message:"held catalog failure")};m.refreshFromSourceCommand();try await settled(m)
        try require(m.error?.contains("held catalog failure")==true && m.plan!.entries.map{[$0.id,$0.action.rawValue]}==accepted,"Failed read discarded accepted draft")
        try await acknowledgeError(owner.window!);try require(m.error==nil,"Owned Rebase error acknowledgment did not clear diagnostic presentation")
        phase="retired Rebase suppresses reply";m.readRefreshReferences={_ in reads += 1;return try await withCheckedThrowingContinuation{held[reads]=$0}};m.refreshFromSourceCommand();try await wait{held[3] != nil};owner.window?.close();held.removeValue(forKey:3)!.resume(returning:catalog);try await wait{m.pendingBatchWorkers==0}
        try require(m.retired && m.plan!.entries.map{[$0.id,$0.action.rawValue]}==accepted,"Retired refresh published late")
        phase="Fetch cancelled captured manager refresh";let fetch=try await c.fetch(true),f=fetch.model,defaults=try await c.repo.fetchDefaults(),names=try await c.repo.remoteNames();let before=f.submissionIdentity
        var reply:CheckedContinuation<([String],FetchDefaults),Error>?
        c.release.append{reply?.resume(throwing:CancellationError());reply=nil}
        f.readRefreshDefaults={_ in try await withCheckedThrowingContinuation{reply=$0}}
        let receipt=try await beginManager(f);f.remoteManagerModel!.close();try await wait{reply != nil}
        f.cancel();try require(f.busy && f.preparationNeedsRetry,"Cancelled metadata lost worker ownership/retry");reply?.resume(returning:(names,defaults));reply=nil;try await wait{f.pendingOperations==0 && !f.preparing}
        try require(f.submissionIdentity==before && f.preparationNeedsRetry,"Cancelled metadata replaced accepted form")
        phase="Fetch failed refresh and same-form Retry"
        f.readRefreshDefaults={_ in throw Failure(message:"metadata refresh failure")};f.retryPreparation();try await wait{f.pendingOperations==0 && !f.preparing}
        try require(f.error?.contains("metadata refresh failure")==true && f.preparationNeedsRetry && f.submissionIdentity==before,"Failed refresh discarded accepted metadata draft")
        try await acknowledgeError(fetch.window!);try require(f.error==nil,"Owned Fetch error acknowledgment did not clear diagnostic presentation")
        f.readRefreshDefaults={token in try token.check();return (names,defaults)};f.retryPreparation();try await wait{f.pendingOperations==0 && !f.preparing}
        try require(!f.preparationNeedsRetry && f.error==nil,"Same-form Retry did not settle successful reread")
        phase="Fetch retired refresh suppresses reply"
        f.readRefreshDefaults={_ in try await withCheckedThrowingContinuation{reply=$0}}
        let retiredReceipt=try await beginManager(f);f.remoteManagerModel!.close();try await wait{reply != nil}
        fetch.window?.close();reply?.resume(returning:(names,defaults));reply=nil;try await wait{f.pendingOperations==0}
        let frozen=f.submissionIdentity;f.remoteManagerReturned(receipt);f.remoteManagerReturned(retiredReceipt);f.retryPreparation();try require(f.closed && f.submissionIdentity==frozen && f.pendingOperations==0,"Retired manager/Retry accepted late work")
        // Source F5 during conflict recovery reads only the owned recovery snapshot.
        phase="actual conflict recovery F5";_ = try await c.repo.run(["switch","upstream"]);try Data("conflict\n".utf8).write(to:c.root.appendingPathComponent("file"));try await c.repo.stage(["file"]);_ = try await c.repo.commit(message:"upstream conflict");_ = try await c.repo.run(["switch","main"])
        _ = try await c.repo.run(["rebase","upstream"],successfulExitCodes:0...1)
        let recovering=try await c.rebase(),r=recovering.model;try require(r.active && r.fileRecovery,"Fixture did not enter recovery")
        var sessionReads=0;r.readSession={identity,token in sessionReads += 1;return try await c.repo.rebaseSessionSnapshot(retaining:identity,cancellation:token)};r.readRefreshReferences={_ in throw Failure(message:"Conflict F5 incorrectly read idle refs")}
        let h=try await c.repo.run(["rev-parse","HEAD"]).stdout,i=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        r.refreshFromSourceCommand();try await settled(r);try require(sessionReads==1 && r.active && r.fileRecovery,"Conflict F5 did not use recovery route")
        let finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(h==finalHead && i==Data(contentsOf:c.root.appendingPathComponent(".git/index")),"Conflict refresh wrote HEAD/index")
        phase="Edit pause refuses conflict-shaped F5"
        recovering.window?.close();_ = try await c.repo.run(["rebase","--abort"])
        let editor=c.root.appendingPathComponent(".git/refresh-sequence-editor")
        try Data("#!/bin/sh\n/usr/bin/sed -i '' '1s/^pick /edit /' \"$1\"\n".utf8).write(to:editor)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:editor.path)
        _ = try await c.repo.run(["rebase","-i","--force-rebase",c.base],environmentOverrides:["GIT_SEQUENCE_EDITOR":editor.path])
        let editing=try await c.rebase(),e=editing.model
        try require(e.active && e.state?.isEditPause==true && e.state?.needsFileRecovery==false,"Fixture did not stop at Edit")
        e.fileRecovery=true // Exercise the retained presentation flag separately from the real session phase.
        var forbidden=0;e.readSession={identity,token in forbidden += 1;return try await c.repo.rebaseSessionSnapshot(retaining:identity,cancellation:token)}
        e.refreshFromSourceCommand();try require(!e.canRefreshDialog && forbidden==0,"Edit pause incorrectly used conflict F5 route")
    }}
    static func main()async{
        NSApplication.shared.setActivationPolicy(.prohibited)
        do{switch CommandLine.arguments[3]{case "rebase":try await rebase();case "metadata":try await metadata();case "lifetime":try await lifetime();default:throw Failure(message:"Unknown refresh case")};print("PASS: reference refresh "+CommandLine.arguments[3])}
        catch{fputs("Reference refresh failed: \(error)\n",stderr);exit(1)}
    }
}
