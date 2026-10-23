// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func identityFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func identityOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){if let owner=windowController as? FileComparisonWindowController{WindowByteIdentityVerification.configureOrderedComparison?(owner)};alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));identityOrder(mode,relativeTo:number)}
}
@MainActor @main enum WindowByteIdentityVerification {
    static var configureOrderedComparison:((FileComparisonWindowController)->Void)?
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Window identity \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func exact(_ a:String,_ b:String)->Bool{Data(a.utf8)==Data(b.utf8)}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<4000{window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Window identity timeout \(line)")}
    static func drained()->Bool{FileListComparisonSession.activeOperations==0 && RevisionComparisonWindowModel.activeFileOperations==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeReferenceReads==0 && RepositoryBrowserWindowModel.activeOperations==0}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.WindowIdentities."+UUID().uuidString,prefs:UserDefaults
        let nfc="caf\u{e9}.txt",nfd="cafe\u{301}.txt",refNFC="refs/heads/r\u{e9}vision",refNFD="refs/heads/re\u{301}vision"
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!,workspace:RepositoryModel!,host:NSWindow!
        var owners:[NSWindowController]=[],comparisons:[FileComparisonWindowController]=[],logs:[LogWindowController]=[],browsers:[RepositoryBrowserWindowController]=[],revisions:[RevisionComparisonWindowController]=[]
        var baseOID="",a="",c="",treeA="",treeC="",head=Data(),index=Data(),work=Data(),config=Data(),release:[()->Void]=[]
        var configureComparison:((FileComparisonWindowController)->Void)?
        init(){prefs=UserDefaults(suiteName:suite)!;for key in ["UseLibgit2","EnableLogCache","EnableGravatar"]{prefs.set(false,forKey:key)};prefs.set(100,forKey:"NumDiffWarning")}
        func object(_ bytes:Data)async throws->String{try await repo.run(["hash-object","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines)}
        func tree(_ files:[(String,String)])async throws->String{
            var input=Data();for(path,text)in files.sorted(by:{$0.0.utf8.lexicographicallyPrecedes($1.0.utf8)}){let oid=try await object(Data(text.utf8));input.append(Data("100644 blob \(oid)\t\(path)\0".utf8))}
            return try await repo.run(["mktree","-z"],input:input).text.trimmingCharacters(in:.newlines)
        }
        func commit(_ tree:String,parent:String,message:String)async throws->String{try await repo.run(["commit-tree",tree,"-p",parent],input:Data((message+"\n").utf8)).text.trimmingCharacters(in:.newlines)}
        func prepare()async throws{
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Identity QA"),("user.email","identity@example.invalid"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
            work=Data("untouched working sentinel\n".utf8);try work.write(to:root.appendingPathComponent("sentinel.txt"));try await repo.stage(["sentinel.txt"]);_=try await repo.commit(message:"working sentinel")
            let initial=try await repo.rebaseCommit("HEAD").hash
            let baseTree=try await tree([("sentinel.txt",String(decoding:work,as:UTF8.self)),(nfc,"base NFC\n"),(nfd,"base NFD\n")])
            baseOID=try await commit(baseTree,parent:initial,message:"both literal spellings")
            treeA=try await tree([("sentinel.txt",String(decoding:work,as:UTF8.self)),(nfc,"changed NFC A\n"),(nfd,"base NFD\n")]);a=try await commit(treeA,parent:baseOID,message:"NFC change")
            treeC=try await tree([("sentinel.txt",String(decoding:work,as:UTF8.self)),(nfc,"changed NFC A\n"),(nfd,"changed NFD C\n"),("destination.txt","destination copy\n")]);c=try await commit(treeC,parent:a,message:"NFD change and destination")
            // Author the valid packed-ref database directly, as the focused
            // Core fixture does. A loose-ref/pack round trip passes through
            // filesystem normalization and cannot author this raw-name pair.
            let refs=[(refNFC,a),(refNFD,c)].sorted{$0.0.utf8.lexicographicallyPrecedes($1.0.utf8)}
            let packed=Data(("# pack-refs with: sorted\n"+refs.map{$0.1+" "+$0.0+"\n"}.joined()).utf8)
            try packed.write(to:root.appendingPathComponent(".git/packed-refs"))
            try require(packed.range(of:Data((a+" "+refNFC+"\n").utf8)) != nil && packed.range(of:Data((c+" "+refNFD+"\n").utf8)) != nil,"Raw packed reference fixture collapsed spellings")
            for(name,oid)in refs {
                let resolved=try await repo.run(["-c","core.precomposeunicode=false","rev-parse","--verify",name]).text.trimmingCharacters(in:.newlines)
                try require(resolved==oid,"Raw packed reference did not resolve its exact object")
            }
            let store=try RepositoryAccessStore(storageURL:base.appendingPathComponent("access.json"))
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[git] in GitRepository(root:$0,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:store,cachePersistenceDefaults:prefs,publishCachePersistence:{_ in})
            workspace.fileComparisonPreferences=prefs;workspace.notifyFinder={}
            host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);workspace.workspaceWindow=host
            workspace.fileComparisonWindowPresentation={ [weak self] owner in guard let self else{return};self.comparisons.append(owner);self.owners.append(owner);self.configureComparison?(owner);owner.showWindow(nil);owner.window?.orderFront(nil)}
            workspace.logWindowPresentation={ [weak self] owner in self?.logs.append(owner);self?.owners.append(owner);owner.showWindow(nil);owner.window?.orderFront(nil)}
            workspace.browserWindowPresentation={ [weak self] owner in self?.browsers.append(owner);self?.owners.append(owner);owner.showWindow(nil);owner.window?.orderFront(nil)}
            workspace.revisionComparisonWindowPresentation={ [weak self] owner in self?.revisions.append(owner);self?.owners.append(owner);owner.showWindow(nil);owner.window?.orderFront(nil)}
            workspace.open(root);try await wait(host){self.workspace.root?.resolvingSymlinksInPath()==self.root.resolvingSymlinksInPath() && !self.workspace.busy}
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"));config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        }
        func compare(_ paths:[String]){workspace.showHistoricalFiles(repository:repo,access:nil,from:.revision(baseOID),to:.revision(c),paths:paths,owner:host,preferences:prefs)}
        func preserved()async throws{let final=try await repo.run(["rev-parse","HEAD"]).stdout;try require(final==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:root.appendingPathComponent("sentinel.txt")))==work && (try Data(contentsOf:root.appendingPathComponent(".git/config")))==config,"Display requests changed HEAD/index/work")}
        func clean()async{release.forEach{$0()};release=[];for owner in owners{if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()};workspace?.stopMonitoringForTermination();host?.close();for _ in 0..<4000{if drained() && workspace?.hasPendingRepositoryWork != true && (owners.compactMap{$0 as? FileComparisonWindowController}+revisions.flatMap{$0.model.allComparisonWindows}).allSatisfy({!$0.model.mergeToolHasPendingWork}){break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite)}
    }
    static func loaded(_ owners:[FileComparisonWindowController])async throws{try await wait{!owners.isEmpty && owners.allSatisfy{!$0.model.busy && $0.model.document != nil}}}
    static func compare(_ c:Context)async throws{
        c.compare([c.nfc,c.nfd]);try await wait{c.comparisons.count==2 && !c.workspace.hasPendingRepositoryWork};let pair=c.comparisons;try await loaded(pair)
        try require(pair[0] !== pair[1],"Canonically equivalent path requests shared actual owner")
        for(path,base,new)in[(c.nfc,"base NFC\n","changed NFC A\n"),(c.nfd,"base NFD\n","changed NFD C\n")]{let child=try unwrap(pair.first{exact($0.model.path,path)},"Missing literal child");let doc=try unwrap(child.model.document,"Missing actual document");try require(exact(doc.base.path,path) && doc.base.bytes==Data(base.utf8) && doc.destination.bytes==Data(new.utf8) && child.model.comparisonDefaults === c.prefs,"Literal child loaded another spelling/preferences")}
        c.compare([c.nfc]);try await wait{c.comparisons.count==3 && !c.workspace.hasPendingRepositoryWork};try require(c.comparisons.last === pair.first{exact($0.model.path,c.nfc)},"Exact comparison repeat did not reuse")
        let first=try unwrap(pair.first{exact($0.model.path,c.nfc)},"Missing first child"),other=try unwrap(pair.first{exact($0.model.path,c.nfd)},"Missing peer child")
        first.close();try await wait{!c.workspace.fileComparisonWindows.values.contains{$0 === first}};try require(c.workspace.fileComparisonWindows.values.contains{$0 === other},"Closing one byte path evicted its peer")
        // Hold the actual post-read external-tool decision; closing cancels its
        // accepted load, and a replacement must survive the old close callback.
        var held:CheckedContinuation<Bool,Error>?,old:FileComparisonWindowController?
        c.configureComparison={owner in if exact(owner.model.path,c.nfc),old==nil{old=owner;owner.model.openExternalComparison={_,_,_,_ in try await withCheckedThrowingContinuation{held=$0}}}}
        c.compare([c.nfc]);try await wait{held != nil};let closing=try unwrap(old,"Missing held actual child"),late=closing.onClosed
        c.release.append{held?.resume(returning:false);held=nil};closing.close();try require(closing.model.inputEncodingOwnerRetired,"Close did not retire held child")
        c.compare([c.nfc]);try await wait{c.comparisons.last !== closing && !c.workspace.hasPendingRepositoryWork};let replacement=try unwrap(c.comparisons.last,"Missing replacement")
        try await loaded([replacement]);held?.resume(returning:false);held=nil;try await wait{!closing.model.mergeToolHasPendingWork};late()
        try require(c.workspace.fileComparisonWindows.values.contains{$0 === replacement} && !replacement.model.inputEncodingOwnerRetired,"Late old close evicted/resurrected replacement")
        let count=c.comparisons.count
        ComparisonToolInvocation.$alternate.withValue(true){c.compare([c.nfd])}
        try await wait{c.comparisons.count==count+1 && !c.workspace.hasPendingRepositoryWork};let alternate=try unwrap(c.comparisons.last,"Missing alternate child");try await loaded([alternate])
        try require(alternate !== other && alternate.model.alternateTool && alternate.model.comparisonDefaults === c.prefs,"Shift/captured owner context reused default child")
    }
    static func revision(_ c:Context)async throws{
        c.workspace.showRevisionComparison(repository:c.repo,access:nil,from:.revision(c.baseOID),to:.revision(c.c),preferences:c.prefs)
        let owner=try unwrap(c.revisions.last,"Missing actual Changed Files owner"),m=owner.model
        try await wait(owner.window){!m.busy && m.snapshot != nil}
        m.compare([c.nfc,c.nfd]);try await wait{m.comparisonWindows.count==2 && !m.hasOwnedPreparation};try await loaded(Array(m.comparisonWindows.values))
        try require(GitPathSet(m.comparisonWindows.values.map(\.model.path))==GitPathSet([c.nfc,c.nfd]),"Changed Files collapsed literal paths")
        let from=ComparisonRevision.revision(c.baseOID),to=ComparisonRevision.revision(c.c)
        for oldPath in [c.nfc,c.nfd]{let file=CommitFile(path:"destination.txt",oldPath:oldPath,action:"C100",added:nil,removed:nil,hasStatistics:false,isSubmodule:false);m.installEmbeddedSnapshot(.init(root:c.root,from:from,to:to,fromDetails:nil,toDetails:nil,files:[file],options:.init()),bare:false);m.compare(["destination.txt"]);try await wait{!m.hasOwnedPreparation && m.comparisonWindows.values.contains{exact($0.model.document?.base.path ?? "",oldPath)}}}
        let metadata=m.comparisonWindows.values.filter{exact($0.model.path,"destination.txt")};try await loaded(metadata)
        try require(metadata.count==2 && Set(metadata.compactMap{$0.model.document?.base.bytes})==Set([Data("base NFC\n".utf8),Data("base NFD\n".utf8)]),"Same destination reused stale rename/copy preimage")
        let added=CommitFile(path:"destination.txt",oldPath:nil,action:"A",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
        m.installEmbeddedSnapshot(.init(root:c.root,from:from,to:to,fromDetails:nil,toDetails:nil,files:[added],options:.init()),bare:false);m.compare(["destination.txt"])
        try await wait{!m.hasOwnedPreparation && m.comparisonWindows.values.contains{exact($0.model.path,"destination.txt") && $0.model.document.map{$0.base.bytes.isEmpty && $0.base.mode==nil}==true}}
        let count=m.comparisonWindows.count;m.compare(["destination.txt"]);try await wait{!m.hasOwnedPreparation};try require(m.comparisonWindows.count==count,"Exact metadata repeat duplicated child")
        let survivor=try unwrap(metadata.first{exact($0.model.document?.base.path ?? "",c.nfd)},"Missing metadata peer"),closed=try unwrap(metadata.first{exact($0.model.document?.base.path ?? "",c.nfc)},"Missing metadata child"),late=closed.onClosed
        closed.close();try await wait{!m.comparisonWindows.values.contains{$0 === closed}};late();try require(m.comparisonWindows.values.contains{$0 === survivor},"Old metadata close evicted peer")
        // Historical panes are intentionally immutable. Exercise dirty-parent
        // refusal with an actual working-tree child, without saving its draft.
        let workingFile=CommitFile(path:"sentinel.txt",oldPath:nil,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
        m.installEmbeddedSnapshot(.init(root:c.root,from:from,to:.workingTree,fromDetails:nil,toDetails:nil,files:[workingFile],options:.init()),bare:false)
        m.compare(["sentinel.txt"])
        try await wait{!m.hasOwnedPreparation && m.comparisonWindows.values.contains{exact($0.model.path,"sentinel.txt") && $0.model.document != nil && !$0.model.busy}}
        let working=try unwrap(m.comparisonWindows.values.first{exact($0.model.path,"sentinel.txt")},"Missing editable working-tree child")
        working.model.activatePane(base:false);working.model.editingEnabled=true
        try require(working.model.canEdit(base:false),"Working-tree child did not expose real editable pane")
        working.model.updateDraft("private unsaved draft\n",base:false)
        try require(working.model.dirty && !m.canReuseForComparison(from:from,to:.workingTree),"Dirty child permitted parent reuse")
        working.model.updateDraft(String(decoding:try unwrap(working.model.document,"No working document").destination.bytes,as:UTF8.self),base:false)
        try require(!working.model.dirty,"Restoring original draft did not clear dirty state")
        m.confirmingQuit=true;let before=m.comparisonWindows.count;m.compare(["sentinel.txt"]);try require(m.comparisonWindows.count==before && !m.hasOwnedPreparation && !m.busy,"Quit admitted comparison");m.confirmingQuit=false
        // Configure the actual new child before its first ordered appearance;
        // its normal Git read still runs, then the external-tool decision holds
        // the accepted load while owner close and replacement are exercised.
        let earlierChildren=Set(m.comparisonWindows.values.map{ObjectIdentifier($0)})
        var held:CheckedContinuation<Bool,Error>?,retiring:FileComparisonWindowController?
        configureOrderedComparison={child in
            guard retiring==nil,exact(child.model.path,"destination.txt") else{return}
            retiring=child
            child.model.openExternalComparison={_,_,_,_ in try await withCheckedThrowingContinuation{held=$0}}
        }
        defer{configureOrderedComparison=nil}
        let renamed=CommitFile(path:"destination.txt",oldPath:c.nfc,action:"R100",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
        m.installEmbeddedSnapshot(.init(root:c.root,from:from,to:to,fromDetails:nil,toDetails:nil,files:[renamed],options:.init()),bare:false)
        m.compare(["destination.txt"]);try await wait{held != nil && !m.hasOwnedPreparation}
        let old=try unwrap(retiring,"Missing held Changed Files child"),oldClosed=old.onClosed
        c.release.append{held?.resume(returning:false);held=nil}
        old.close();try require(old.model.inputEncodingOwnerRetired,"Changed Files close did not retire held load")
        m.compare(["destination.txt"])
        func isFreshReplacement(_ child:FileComparisonWindowController)->Bool {
            child !== old && !earlierChildren.contains(ObjectIdentifier(child)) &&
            exact(child.model.path,"destination.txt") && child.model.document?.base.bytes==Data("base NFC\n".utf8)
        }
        try await wait{
            !m.hasOwnedPreparation && m.retiringComparisonWindows.values.contains{$0 === old} &&
            m.comparisonWindows.values.contains(where:isFreshReplacement)
        }
        let fresh=try unwrap(m.comparisonWindows.values.first(where:isFreshReplacement),"Missing fresh Changed Files replacement")
        try await loaded([fresh]);try require(!m.canReuseForComparison(from:from,to:to),"Parent reused while retired comparison load still owned work")
        held?.resume(returning:false);held=nil
        try await wait{!old.model.mergeToolHasPendingWork && m.retiringComparisonWindows.isEmpty}
        oldClosed();try require(m.comparisonWindows.values.contains{$0 === fresh} && !fresh.model.inputEncodingOwnerRetired,"Late Changed Files close removed fresh replacement")
    }
    static func log(_ c:Context)async throws{
        func open(_ path:String){c.workspace.showLog(repository:c.repo,access:nil,paths:[path],endRevision:c.c,preferences:c.prefs,sourceWindow:c.host)}
        open(c.nfc);open(c.nfd);try require(c.logs.count==2 && c.logs[0] !== c.logs[1],"Scoped Log merged canonical path keys")
        let pair=c.logs;try await wait{pair.allSatisfy{!$0.model.busy && !$0.model.entries.isEmpty}}
        try require(pair[0].model.entries.contains{$0.hash==c.a} && !pair[0].model.entries.contains{$0.hash==c.c} && pair[1].model.entries.contains{$0.hash==c.c},"Scoped Log histories loaded wrong literal path")
        open(c.nfc);try require(c.logs.last === pair[0],"Exact scoped Log did not reuse")
        pair[0].model.setPathScope([c.nfd]);try require(exact(pair[0].model.historyPaths.first ?? "",c.nfd),"Scope setter ignored byte-different path");try await wait{!pair[0].model.busy}
        let r1=HistoryRevisionRange(from:"main",to:c.refNFC),r2=HistoryRevisionRange(from:"main",to:c.refNFD)
        for range in [r1,r2]{c.workspace.showLog(repository:c.repo,access:nil,paths:[],revisionRange:range,preferences:c.prefs,sourceWindow:c.host)}
        let one=c.logs[c.logs.count-2],two=try unwrap(c.logs.last,"No range Log");try await wait{!one.model.busy && !two.model.busy}
        try require(one !== two && one.model.canReuseForRange(r1) && !one.model.canReuseForRange(r2) && two.model.canReuseForRange(r2),"Range endpoint predicate collapsed ref spelling")
        try require(!one.model.entries.contains{$0.hash==c.c} && two.model.entries.contains{$0.hash==c.c},"Range loaded other named endpoint")
        c.workspace.showLog(repository:c.repo,access:nil,paths:[],revisionRange:r1,preferences:c.prefs);try require(c.logs.last === one,"Exact range did not reuse")
        one.model.confirmingQuit=true;try require(!one.model.canReuseForRange(r1),"Quit Log remained reusable");one.model.confirmingQuit=false
        one.close();try await wait{one.window?.isVisible != true};c.workspace.showLog(repository:c.repo,access:nil,paths:[],revisionRange:r2,preferences:c.prefs);try require(c.logs.last === two && two.model.colorPreferences === c.prefs,"Closing range peer lost live owner/preferences")
    }
    static func browser(_ c:Context)async throws{
        func open(_ name:String){c.workspace.showRepositoryBrowser(repository:c.repo,access:nil,revision:name,preferences:c.prefs,sourceWindow:c.host)}
        open(c.refNFC);open(c.refNFD);let pair=c.browsers;try require(pair.count==2 && pair[0] !== pair[1],"Named Browser collapsed canonical refs")
        try await wait{pair.allSatisfy{!$0.model.busy && $0.model.snapshot != nil}}
        for(owner,name,oid,tree)in[(pair[0],c.refNFC,c.a,c.treeA),(pair[1],c.refNFD,c.c,c.treeC)]{let snapshot=try unwrap(owner.model.snapshot,"No browser tree");try require(exact(snapshot.revision,name) && snapshot.objectID==oid && snapshot.treeID==tree && GitPathSet(snapshot.entries.map(\.path)).contains(c.nfc) && GitPathSet(snapshot.entries.map(\.path)).contains(c.nfd) && owner.model.preferences === c.prefs,"Browser loaded wrong named tree/preferences")}
        try require(pair[0].model.canReuseForRevision(c.refNFC) && !pair[0].model.canReuseForRevision(c.refNFD),"Browser predicate canonicalized ref")
        open(c.refNFC);try require(c.browsers.last === pair[0],"Exact Browser did not reuse")
        pair[0].model.busy=true;try require(!pair[0].model.canReuseForRevision(c.refNFC),"Busy browser reusable");pair[0].model.busy=false
        pair[0].close();open(c.refNFD);try require(c.browsers.last === pair[1],"Closing named peer evicted other Browser")
    }
    static func main()async{
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.identityFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.identityOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();let kind=CommandLine.arguments[3];switch kind{case "compare":try await compare(c);case "revision":try await revision(c);case "log":try await log(c);case "browser":try await browser(c);default:throw Failure(description:"Unknown window identity case")};try await c.preserved();await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned identity windows/sheets survived cleanup");print("PASS: window byte identities "+kind);fflush(stdout)}catch{await c.clean();fputs("Window identities failed: \(error)\n",stderr);exit(1)}
    }
}
