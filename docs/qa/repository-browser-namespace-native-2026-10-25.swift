// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func namespaceFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func namespaceOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));namespaceOrder(mode,relativeTo:number)}
}
@MainActor
@main enum RepositoryBrowserNamespaceVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws{if !condition{throw Failure(description:"Browser namespace \(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Browser namespace timeout \(line)")}
    @MainActor final class Context {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.BrowserNamespace."+UUID().uuidString
        let prefs:UserDefaults
        var owners:[RepositoryBrowserWindowController]=[],releases:[()->Void]=[]
        let text=Data("stored body\n".utf8),binary=Data([0,0xff,0x10,0x41])
        var revision="",head=Data(),index:Data?,config=Data()
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar")}
        func repository()->GitRepository{GitRepository(root:folder,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        func oid(_ args:[String],input:Data?=nil)async throws->String{String(decoding:try await repository().run(args,input:input).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)}
        func tree(_ records:[(String,String,String,Data)])async throws->String{
            var data=Data();for(mode,type,oid,name)in records{data.append(Data("\(mode) \(type) \(oid)\t".utf8));data.append(name);data.append(0)}
            return try await oid(["mktree","-z"],input:data)
        }
        func prepare()async throws{
            let repo=repository();_=try await repo.run(["init","--template=","-b","main"])
            for(k,v)in[("user.name","Browser QA"),("user.email","browser@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")]{_=try await repo.run(["config",k,v])}
            let blob=try await oid(["hash-object","-w","--stdin"],input:text),binaryOID=try await oid(["hash-object","-w","--stdin"],input:binary)
            let child=try await tree([("100644","blob",blob,Data("nested.txt".utf8)),("100644","blob",binaryOID,Data([0xfe,0x2e,0x62,0x69,0x6e]))])
            let root=try await tree([("100644","blob",blob,Data("valid.txt".utf8)),("100644","blob",blob,Data("�.txt".utf8)),("100644","blob",blob,Data("\\xFF.txt".utf8)),("100644","blob",blob,Data([0xff,0x2e,0x74,0x78,0x74])),("100644","blob",binaryOID,Data([0xfe,0x2e,0x74,0x78,0x74])),("040000","tree",child,Data([0xfd,0x64,0x69,0x72])),("040000","tree",child,Data("valid-folder".utf8))])
            revision=try await oid(["commit-tree",root,"-m","namespace"]);_=try await repo.run(["update-ref","refs/heads/main",revision])
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try? Data(contentsOf:folder.appendingPathComponent(".git/index"));config=try Data(contentsOf:folder.appendingPathComponent(".git/config"))
        }
        func owner()async throws->RepositoryBrowserWindowController{
            let owner=RepositoryBrowserWindowController(repository:repository(),access:nil,revision:revision,preferences:prefs)
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.window?.isReleasedWhenClosed=false
            owner.presentStoredBlobWindow={child in child.window?.alphaValue=0;child.window?.setFrameOrigin(.init(x:-24000,y:-24000));_ = child.window?.contentView}
            owners.append(owner);owner.model.refresh();try await RepositoryBrowserNamespaceVerification.wait{!owner.model.busy && !owner.model.hasPendingWork}
            try RepositoryBrowserNamespaceVerification.require(owner.model.error==nil,owner.model.error ?? "load failed")
            _=owner.window?.contentView;owner.window?.contentView?.layoutSubtreeIfNeeded()
            try await RepositoryBrowserNamespaceVerification.wait{owner.contentsTable?.numberOfRows==owner.model.entries.count}
            return owner
        }
        func unchanged()async throws{
            try RepositoryBrowserNamespaceVerification.require(try await repository().run(["rev-parse","HEAD"]).stdout==head,"HEAD changed")
            try RepositoryBrowserNamespaceVerification.require((try? Data(contentsOf:folder.appendingPathComponent(".git/index")))==index,"Index changed")
            try RepositoryBrowserNamespaceVerification.require(try Data(contentsOf:folder.appendingPathComponent(".git/config"))==config,"Config changed")
            let files=try FileManager.default.contentsOfDirectory(atPath:folder.path)
            try RepositoryBrowserNamespaceVerification.require(files==[".git"],"A path action wrote a working file")
        }
        func cleanup()async{
            releases.forEach{$0()};releases=[];owners.forEach{$0.close()}
            for _ in 0..<3000{if owners.allSatisfy({!$0.hasPendingWork}) && RepositoryBrowserWindowModel.activeOperations==0{break};try? await Task.sleep(nanoseconds:10_000_000)}
            UserDefaults.standard.removePersistentDomain(forName:suite)
        }
    }
    static func listing(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model
        try require(m.entries.count==7,"One raw name hid valid siblings")
        let raw=m.entries.filter{!$0.isPathRepresentable};try require(raw.count==3 && Set(raw.map(\.id)).count==3,"Raw identities collapsed")
        try require(m.entries.contains{$0.name=="�.txt" && $0.isPathRepresentable} && m.entries.contains{$0.name=="\\xFF.txt" && $0.isPathRepresentable},"Literal display-looking siblings lost")
        m.selection=Set(raw.map(\.id));let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};m.copy(pasteboard:board)
        try require(board.string(forType:.string)?.contains("\0")==false,"Opaque key copied")
        m.copy(hashes:true,pasteboard:board);try require(board.string(forType:.string)==raw.sorted{a,b in m.entries.firstIndex(of:a)! < m.entries.firstIndex(of:b)!}.map(\.objectID).joined(separator:"\r\n"),"Hash copy changed")
        try require(!m.displayPath.contains("\0") && !m.absoluteDisplayPath.contains("\0") && !m.info.contains("\0"),"Opaque key in visible metadata")
        if let table=owner.contentsTable,let menu=table.menu {
            table.selectRowIndexes(IndexSet(integer:m.entries.firstIndex(of:raw.first{$0.kind != .directory}!)!),byExtendingSelection:false)
            m.selection=[raw.first{$0.kind != .directory}!.id];menu.delegate?.menuNeedsUpdate?(menu)
            try require(menu.items.contains{$0.title=="View stored blob" && $0.isEnabled},"Raw blob inspection action missing")
            try require(menu.items.contains{$0.title=="Open" && !$0.isEnabled},"Raw path Open enabled")
        } else {throw Failure(description:"Shipping contents table absent")}
        try await c.unchanged()
    }
    static func navigation(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model,dir=owner.model.entries.first{$0.kind == .directory && !$0.isPathRepresentable}!
        m.open(dir);try await wait{m.snapshot?.directory==dir.path && !m.hasPendingWork}
        try require(m.entries.count==2 && m.entries.contains{!$0.isPathRepresentable},"Raw folder did not load")
        try require(!m.displayPath.contains("\0") && !m.absoluteDisplayPath.contains("\0"),"Opaque directory visible")
        let ids=Set(m.entries.map(\.id));m.refresh();try await wait{!m.busy && !m.hasPendingWork}
        try require(m.snapshot?.directory==dir.path && Set(m.entries.map(\.id))==ids,"Refresh lost raw folder/identity")
        m.openFolder("");try await wait{m.snapshot?.directory.isEmpty==true && !m.hasPendingWork}
        try require(m.entries.count==7,"Root navigation lost siblings");try await c.unchanged()
    }
    static func actions(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model,raw=m.entries.first{$0.rawName==Data([0xff,0x2e,0x74,0x78,0x74])}!,valid=m.entries.first{$0.name=="valid.txt"}!
        var dispatches=0;m.onLog={_,_ in dispatches+=1};m.onBlame={_,_ in dispatches+=1};m.onCompare={_,_ in dispatches+=1};m.onPreparedFileCompare={_,_ in dispatches+=1};m.presentFile={_,_ in dispatches+=1}
        m.open(raw);m.showEntryLog(raw);m.showEntryBlame(raw);m.compareEntryToWorkingTree(raw);m.markForComparison(raw);m.revert([raw])
        try require(dispatches==0 && m.comparisonMark==nil && !m.mutating && m.error==RepositoryBrowserWindowModel.rawPathReason,"Raw path dispatched an action")
        m.selection=[raw.id]
        try require(m.dragProvider(raw)==nil && m.captureTransfer([raw.id])==nil,"Raw drag offered")
        m.error=nil;m.showEntryLog(valid);try require(dispatches==1,"Valid sibling Log suppressed")
        let badFolder=m.entries.first{$0.name=="valid-folder"}!
        m.error=nil;m.selection=[badFolder.id];try require(m.captureTransfer([badFolder.id])==nil && m.error?.contains("cannot be delivered")==true,"Representable folder with raw descendant offered a transfer")
        m.error=nil;m.selection=[valid.id]
        guard let transfer=m.captureTransfer([valid.id]),let promise=transfer.promises.first else{throw Failure(description:"Raw unrelated siblings blocked valid transfer")}
        let delivered=c.folder.deletingLastPathComponent().appendingPathComponent("delivered-valid.txt")
        defer{try? FileManager.default.removeItem(at:delivered)}
        try await promise.write(to:delivered)
        try require(promise.name=="valid.txt" && (try Data(contentsOf:delivered))==c.text,"Actual valid sibling promise delivery changed")
        m.open(valid);try await wait{!m.busy && !m.hasPendingWork};try require(dispatches==2,"Valid sibling materialized Open suppressed")
        owner.window?.appearance=NSAppearance(named:.darkAqua)
        let binary=m.entries.first{$0.rawName==Data([0xfe,0x2e,0x74,0x78,0x74])}!
        guard let table=owner.contentsTable,let menu=table.menu else{throw Failure(description:"Shipping native menu absent")}
        table.selectRowIndexes(IndexSet(integer:m.entries.firstIndex(of:binary)!),byExtendingSelection:false);m.selection=[binary.id]
        menu.delegate?.menuNeedsUpdate?(menu)
        guard let inspect=menu.items.first(where:{$0.title=="View stored blob"}),let action=inspect.action else{throw Failure(description:"Stored blob menu action absent")}
        try require(inspect.isEnabled && NSApp.sendAction(action,to:inspect.target,from:inspect),"Actual stored blob menu did not dispatch")
        try await wait{!m.busy && !m.hasPendingWork}
        try require(owner.storedBlobWindows.count==1 && owner.storedBlobWindows[0].bytes==c.binary,"Inspector bytes changed")
        try require(owner.storedBlobWindows[0].textView.string.contains("00 ff 10 41") && !owner.storedBlobWindows[0].textView.isEditable,"Binary inspection not lossless/read-only")
        try require(owner.storedBlobWindows[0].window?.appearance?.name == .darkAqua && owner.storedBlobWindows[0].window?.alphaValue==0,"Inspector lost owner appearance/opacity")
        owner.window?.appearance=NSAppearance(named:.aqua)
        m.inspectStoredBlob(raw);try await wait{!m.busy && !m.hasPendingWork}
        try require(owner.storedBlobWindows.count==2 && owner.storedBlobWindows[1].textView.string=="stored body\n","Text stored blob changed")
        try require(owner.storedBlobWindows[1].window?.appearance?.name == .aqua,"Light inspector lost owner appearance")
        owner.storedBlobWindows[0].close();try require(owner.storedBlobWindows.count==1,"Closed inspector retained its byte buffer")
        try await c.unchanged();owner.close();try require(owner.storedBlobWindows.isEmpty,"Owned inspectors survived parent")
    }
    static func ownership(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model,entry=m.entries.first{!$0.isPathRepresentable && $0.kind != .directory}!
        var reply:CheckedContinuation<Data,Error>?,published=0
        m.readStoredBlob={_,_,_ in try await withCheckedThrowingContinuation{reply=$0}}
        m.presentStoredBlob={_,_ in published+=1};m.inspectStoredBlob(entry);try await wait{reply != nil}
        c.releases.append{reply?.resume(returning:c.text);reply=nil}
        owner.close();try require(!m.active && m.hasPendingWork && RepositoryBrowserWindowModel.activeOperations>0,"Retired worker lost ownership")
        reply?.resume(returning:c.text);reply=nil;try await wait{!owner.hasPendingWork && RepositoryBrowserWindowModel.activeOperations==0}
        try require(published==0 && owner.storedBlobWindows.isEmpty,"Retired read opened late inspector")
        let other=try await c.owner();try require(other.model.entries.count==7,"Independent Browser invalidated")
        try await c.unchanged()
    }
    static func main()async{
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.namespaceFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.namespaceOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}}
        defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context(),name=CommandLine.arguments[3]
        do{try await c.prepare();switch name{case "listing":try await listing(c);case "navigation":try await navigation(c);case "actions":try await actions(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown case")};await c.cleanup();print("PASS: Browser namespace "+name)}catch{await c.cleanup();fputs("\(error)\n",stderr);exit(1)}
    }
}
