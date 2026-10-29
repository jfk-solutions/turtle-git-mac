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
        var logs:[LogWindowController]=[],blames:[BlameWindowController]=[],comparisons:[FileComparisonWindowController]=[]
        var owners:[RepositoryBrowserWindowController]=[],releases:[()->Void]=[],previewFiles:[URL]=[]
        let text=Data("stored body\n".utf8),binary=Data([0,0xff,0x10,0x41])
        var revision="",head=Data(),index:Data?,config=Data()
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar")}
        func repository(backend:GitLibGit2Configuration? = nil)->GitRepository{GitRepository(root:folder,executable:git,askpass:nil,libgit2Configuration:backend ?? .init(enabled:false))}
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
        func owner(repository accepted:GitRepository? = nil)async throws->RepositoryBrowserWindowController{
            let owner=RepositoryBrowserWindowController(repository:accepted ?? repository(),access:nil,revision:revision,preferences:prefs)
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
            releases.forEach{$0()};releases=[];owners.forEach{$0.close()};logs.forEach{$0.close()};blames.forEach{$0.close()};comparisons.forEach{$0.close()}
            for _ in 0..<3000{if RepositoryBrowserExportFiles.activeLoads==0 && FileListDrag.activeLoads==0 && owners.allSatisfy({!$0.hasPendingWork}) && RepositoryBrowserWindowModel.activeOperations==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeActionReads==0 && BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && comparisons.allSatisfy({!$0.model.mergeToolHasPendingWork}) && DiffToolApplication.activeRequests==0{break};try? await Task.sleep(nanoseconds:10_000_000)}
            previewFiles.forEach{HistoricalPreviewFiles.discard($0)};previewFiles=[];DiffToolApplication.discardAll();RepositoryBrowserExportFiles.discardAll()
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
            try require(menu.items.contains{$0.title=="Open" && $0.isEnabled && $0.image != nil && $0.action != nil},"Raw historical Open unavailable or missing native icon/selector")
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
        m.open(raw);try await wait{!m.hasPendingWork};m.showEntryLog(raw);m.showEntryBlame(raw);m.compareEntryToWorkingTree(raw)
        m.markForComparison(raw);try await wait{!m.busy && !m.hasPendingWork};m.revert([raw])
        try require(dispatches==3 && m.comparisonMark?.path==raw.path && m.comparisonMark?.revision==c.revision && !m.mutating && m.error==RepositoryBrowserWindowModel.rawPathReason,"Raw historical delivery or filesystem boundary changed")
        m.comparisonMark=nil
        m.error=nil // The filesystem refusal above was already asserted.
        m.selection=[raw.id]
        guard let rawProvider=m.dragProvider(raw),let rawTransfer=m.captureTransfer([raw.id]),let rawPromise=rawTransfer.promises.first else{throw Failure(description:"Safe individual raw-file delivery unavailable")}
        let rawName="Git-path-365963acba3863622ba68f851c94ff4f7b4a438db7c9d6441e080035263e485e.txt"
        try require(rawTransfer.paths==[raw.path] && rawTransfer.names==[rawName] && rawProvider.suggestedName==rawName && !rawTransfer.text.contains("\0") && !rawName.contains("\0"),"Raw transfer lost original identity or exposed opaque key")
        let rawDelivered=c.folder.deletingLastPathComponent().appendingPathComponent(rawName)
        defer{try? FileManager.default.removeItem(at:rawDelivered)}
        try await rawPromise.write(to:rawDelivered)
        let rawProviderBytes:Data=try await withCheckedThrowingContinuation{continuation in
            _=rawProvider.loadFileRepresentation(forTypeIdentifier:"public.plain-text"){url,error in
                if let error{continuation.resume(throwing:error);return}
                guard let url else{continuation.resume(throwing:Failure(description:"Raw provider omitted URL"));return}
                do{continuation.resume(returning:try Data(contentsOf:url))}catch{continuation.resume(throwing:error)}
            }
        }
        let rawPromiseBytes=try Data(contentsOf:rawDelivered)
        try require(rawPromise.name==rawName && rawPromiseBytes==c.text && rawProviderBytes==c.text,"Safe raw-file promise/provider changed exact stored bytes")
        m.error=nil;m.showEntryLog(valid);try require(dispatches==4,"Valid sibling Log suppressed")
        let badFolder=m.entries.first{$0.name=="valid-folder"}!
        m.error=nil;m.selection=[badFolder.id];try require(m.captureTransfer([badFolder.id])==nil && m.error?.contains("cannot be delivered")==true,"Representable folder with raw descendant offered a transfer")
        m.error=nil;m.selection=[valid.id]
        guard let transfer=m.captureTransfer([valid.id]),let promise=transfer.promises.first else{throw Failure(description:"Raw unrelated siblings blocked valid transfer")}
        let delivered=c.folder.deletingLastPathComponent().appendingPathComponent("delivered-valid.txt")
        defer{try? FileManager.default.removeItem(at:delivered)}
        try await promise.write(to:delivered)
        try require(promise.name=="valid.txt" && (try Data(contentsOf:delivered))==c.text,"Actual valid sibling promise delivery changed")
        m.open(valid);try await wait{!m.busy && !m.hasPendingWork};try require(dispatches==5,"Valid sibling materialized Open suppressed")
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
    static func delivery(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model
        let entry=m.entries.first{$0.rawName==Data([0xfe,0x2e,0x74,0x78,0x74])}!
        let expectedName="Git-blob-"+entry.objectID+".txt"
        let previewName="Git-blob-"+entry.objectID+"-"+String(m.snapshot!.objectID!.prefix(7))+".txt"
        guard let table=owner.contentsTable,let menu=table.menu else{throw Failure(description:"Delivery native table/menu absent")}
        func item(_ title:String)throws->NSMenuItem{
            table.selectRowIndexes(IndexSet(integer:m.entries.firstIndex(of:entry)!),byExtendingSelection:false);m.selection=[entry.id]
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let found=menu.items.first(where:{$0.title==title}) else{throw Failure(description:"Missing stored delivery menu: "+title)}
            try require(found.isEnabled && found.image != nil,"Stored delivery unavailable or missing source icon: "+title)
            return found
        }
        func invoke(_ item:NSMenuItem)throws{guard let action=item.action else{throw Failure(description:"Delivery selector absent")};try require(NSApp.sendAction(action,to:item.target,from:item),"Delivery selector did not dispatch")}
        for title in ["Open stored blob (unfiltered)","Open stored blob with…","View stored blob with alternative editor","Save stored blob (unfiltered) to…"]{_=try item(title)}
        for title in ["Compare with working tree"]{
            guard let filtered=menu.items.first(where:{$0.title==title})else{throw Failure(description:"Ordinary filtered command disappeared: "+title)}
            try require(!filtered.isEnabled,"Unfiltered delivery enabled a pathname-dependent action: "+title)
        }
        // Save the invalid-UTF8-named binary object through the shipping controller.
        let destination=c.folder.deletingLastPathComponent().appendingPathComponent("stored-delivery.bin")
        defer{try? FileManager.default.removeItem(at:destination)}
        var suggestions:[String]=[],savePanels=0,saveWrites=0
        let originalWriter=owner.writeDocument
        owner.writeDocument={bytes,url,token in saveWrites+=1;try await originalWriter(bytes,url,token)}
        owner.saveDestination={_ in destination}
        owner.presentSavePanel={panel,_,reply in suggestions.append(panel.nameFieldStringValue);savePanels+=1;reply(.OK);reply(.OK)}
        try invoke(item("Save stored blob (unfiltered) to…"))
        try await wait{!m.hasPendingWork && !owner.hasPendingWork}
        try require(savePanels==1 && saveWrites==1 && suggestions==[expectedName],"Stored Save suggested a lossy filename: \(suggestions)")
        try require(try Data(contentsOf:destination)==c.binary,"Stored Save altered invalid bytes or applied filters")
        // Actual preview preparation/launch path, with launch injected before NSWorkspace.
        var launched:[URL]=[],applicationCalls=0
        let app=c.folder.deletingLastPathComponent().appendingPathComponent("PrivateViewer.app")
        owner.defaultApplication={_ in app}
        owner.launchDocument={application,documents,configuration in
            try require(application==app && documents.count==1 && configuration.arguments.isEmpty,"Stored Open lost native document route")
            let file=documents[0];c.previewFiles.append(file);launched.append(file)
            try require(file.lastPathComponent==previewName,"Stored Open materialized escaped or opaque path")
            try require(try Data(contentsOf:file)==c.binary,"Stored Open changed raw object bytes")
        }
        try invoke(item("Open stored blob (unfiltered)"))
        try await wait{!owner.hasPendingWork && !m.hasPendingWork}
        try require(launched.count==1 && m.error==nil,"Stored Open failed: \(m.error ?? "no launch")")
        // Open With cancellation must not prepare/launch another receiving document.
        owner.presentApplicationPanel={_,_,reply in applicationCalls+=1;reply(.cancel)}
        try invoke(item("Open stored blob with…"));try await wait{!owner.hasPendingWork && !m.hasPendingWork}
        try require(applicationCalls==1 && launched.count==1 && !m.handlingFile,"Cancelled stored Open With launched or retained ownership")
        // A selected application opens a distinct private preview exactly once,
        // even if a faulty chooser sends its completion twice.
        var selectedApplications=0
        owner.selectedApplication={_ in selectedApplications+=1;return app}
        owner.presentApplicationPanel={_,_,reply in applicationCalls+=1;reply(.OK);reply(.OK)}
        try invoke(item("Open stored blob with…"));try await wait{!owner.hasPendingWork && !m.hasPendingWork}
        try require(applicationCalls==2 && selectedApplications==1 && launched.count==2 && m.error==nil,"Stored Open With did not launch exactly once")
        try require(launched[0].deletingLastPathComponent() != launched[1].deletingLastPathComponent(),"Stored Open With reused the first preview directory")
        try require(try Data(contentsOf:launched[1])==c.binary,"Selected application preview changed stored bytes")
        // Alternative-editor menu carries the same exact content and distinct action.
        let nativePresent=m.presentFile;var alternative=0
        m.presentFile={content,action in
            if action == .alternativeEditor && content.bytes==c.binary && content.path==expectedName{alternative+=1}
        }
        try invoke(item("View stored blob with alternative editor"));try await wait{!m.hasPendingWork}
        try require(alternative==1,"Alternative editor lost unfiltered bytes/action")
        m.presentFile=nativePresent
        // Retained table receipts cannot become current after a fresh snapshot.
        let retained=try item("Open stored blob (unfiltered)")
        m.refresh();try await wait{!m.busy && !m.hasPendingWork}
        try invoke(retained);try await Task.sleep(nanoseconds:20_000_000)
        try require(launched.count==2 && !m.hasPendingWork,"Retained delivery menu survived refresh")
        // Quit gate rejects new delivery before invoking the injected object reader.
        var reads=0;m.readStoredFile={snapshot,entry,token in reads+=1;return try await c.repository().storedRepositoryBrowserFile(snapshot,entry:entry,cancellation:token)}
        m.confirmingQuit=true;m.openStoredBlob(entry);m.confirmingQuit=false
        try require(reads==0 && !m.hasPendingWork,"Quit gate started a stored-object read")
        // A read completing during Quit may not publish to the controller either.
        var reply:CheckedContinuation<Data,Error>?
        m.readStoredFile={snapshot,entry,token in
            reads+=1
            let _:Data=try await withCheckedThrowingContinuation{reply=$0}
            return try await c.repository().storedRepositoryBrowserFile(snapshot,entry:entry,cancellation:token)
        }
        m.openStoredBlob(entry);try await wait{reply != nil}
        c.releases.append{reply?.resume(returning:c.binary);reply=nil}
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit escaped live stored delivery")
        m.confirmingQuit=true;reply?.resume(returning:c.binary);reply=nil
        try await wait{!m.hasPendingWork};m.confirmingQuit=false
        try require(launched.count==2,"Quit-pending read published a stored document")
        // A cancelled generation keeps the held worker owned but cannot launch.
        m.openStoredBlob(entry);try await wait{reply != nil}
        m.refresh();reply?.resume(returning:c.binary);reply=nil
        try await wait{!m.busy && !m.hasPendingWork}
        try require(launched.count==2,"Stale stored read survived a refreshed tree receipt")
        // Forced close keeps actual object I/O owned until its late reply settles.
        m.openStoredBlob(entry);try await wait{reply != nil};owner.close()
        try require(!m.active && m.hasPendingWork && RepositoryBrowserWindowModel.activeOperations>0,"Closed delivery dropped unfinished read ownership")
        reply?.resume(returning:c.binary);reply=nil;try await wait{!owner.hasPendingWork && RepositoryBrowserWindowModel.activeOperations==0}
        try require(launched.count==2,"Retired delivery read launched late")
        // A held Open With panel callback after retirement cannot launch either.
        let second=try await c.owner(),other=second.model
        let otherEntry=other.entries.first{$0.rawName==entry.rawName}!
        var panelReply:((NSApplication.ModalResponse)->Void)?
        second.selectedApplication={_ in app};second.launchDocument={_,_,_ in launched.append(app)}
        second.presentApplicationPanel={_,_,reply in panelReply=reply}
        c.releases.append{panelReply?(.cancel);panelReply=nil}
        other.openStoredBlob(otherEntry,action:.openWith);try await wait{panelReply != nil}
        try require(other.handlingFile && second.hasPendingWork,"Held stored Open With lost its owned request")
        second.close();panelReply?(.OK);panelReply=nil
        try await wait{!second.hasPendingWork && RepositoryBrowserFileOperation.activeRequests==0}
        try require(launched.count==2 && !other.active,"Retired Open With callback launched a document")
        try await c.unchanged()
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
    static func history(_ c:Context)async throws {
        // HEAD deliberately has neither raw spelling: all navigation must use
        // the Browser's captured object, never the current branch or checkout.
        let futureBlob=try await c.oid(["hash-object","-w","--stdin"],input:Data("future\n".utf8))
        let futureTree=try await c.tree([("100644","blob",futureBlob,Data("future.txt".utf8))])
        let future=try await c.oid(["commit-tree",futureTree,"-p",c.revision,"-m","future"])
        _=try await c.repository().run(["update-ref","refs/heads/main",future]);c.head=try await c.repository().run(["rev-parse","HEAD"]).stdout
        let owner=try await c.owner(),model=owner.model
        let raw=model.entries.first{$0.rawName==Data([0xff,0x2e,0x74,0x78,0x74])}!
        let directory=model.entries.first{$0.kind == .directory && !$0.isPathRepresentable}!
        let expected=RepositoryBrowserGitPath.display(key:raw.path)
        let rawHelp=RepositoryFileHelpText.text(repository:c.folder,path:raw.path)
        try require(rawHelp.contains(expected) && !rawHelp.contains(c.folder.path) && !rawHelp.contains("\0"),"Raw tooltip fabricated a native path")
        try require(RepositoryFileHelpText.text(repository:c.folder,path:"valid.txt",detail:"detail")==c.folder.appendingPathComponent("valid.txt").path+"\ndetail","Ordinary tooltip changed")
        let rawMark=PreparedFileComparisonMark(path:raw.path,revision:c.revision)
        try require(rawMark.label(for:raw.path)==c.revision,"Comparison label compared escaped caption instead of exact key")
        var logCalls:[(String,String)]=[],blameCalls:[(String,String)]=[]
        model.onLog={logCalls.append(($0,$1))};model.onBlame={blameCalls.append(($0,$1))}
        guard let table=owner.contentsTable,let menu=table.menu else{throw Failure(description:"History contents table absent")}
        func item(_ title:String)throws->NSMenuItem {
            table.selectRowIndexes(IndexSet(integer:model.entries.firstIndex(of:raw)!),byExtendingSelection:false);model.selection=[raw.id]
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let result=menu.items.first(where:{$0.title==title}) else{throw Failure(description:"Missing history menu "+title)}
            try require(result.isEnabled && result.image != nil,"Raw history disabled or source icon missing: "+title);return result
        }
        func invoke(_ item:NSMenuItem)throws {
            guard let action=item.action else{throw Failure(description:"History selector missing")}
            try require(NSApp.sendAction(action,to:item.target,from:item),"Native history selector refused")
        }
        try invoke(item("Show log"));try invoke(item("Blame"))
        try require(logCalls.count==1 && blameCalls.count==1 && logCalls[0].0==raw.path && blameCalls[0].0==raw.path && logCalls[0].1==c.revision && blameCalls[0].1==c.revision,"History replaced raw bytes or pinned revision")
        let retained=try item("Blame")
        model.refresh();try await wait{!model.busy && !model.hasPendingWork};try invoke(retained)
        try require(blameCalls.count==1,"Retained native history action survived Browser refresh")
        func outline(in view:NSView)->NSOutlineView? {
            if let value=view as? NSOutlineView{return value}
            return view.subviews.lazy.compactMap{outline(in:$0)}.first
        }
        guard let view=owner.window?.contentView,let tree=outline(in:view),let folderMenu=tree.menu else{throw Failure(description:"Folder outline absent")}
        tree.expandItem(nil,expandChildren:true);try await wait{!model.busy && !model.hasPendingWork}
        let folderRow=(0..<tree.numberOfRows).first{row in
            (tree.view(atColumn:0,row:row,makeIfNecessary:true) as? NSTableCellView)?.textField?.stringValue==directory.displayName+" [raw]"
        }
        guard let folderRow else{throw Failure(description:"Raw folder row absent")}
        (tree as? RepositoryBrowserFolderOutline)?.contextSelection(folderRow);folderMenu.delegate?.menuNeedsUpdate?(folderMenu)
        guard let folderAction=folderMenu.items.first(where:{$0.title=="Show log"})else{throw Failure(description:"Raw folder Log menu absent")}
        try require(folderAction.isEnabled && folderAction.image != nil,"Raw folder Log disabled or missing source icon");try invoke(folderAction)
        try require(logCalls.count==2 && logCalls[1].0==directory.path && logCalls[1].1==c.revision,"Raw directory history lost captured path")
        model.refresh();try await wait{!model.busy && !model.hasPendingWork};try invoke(folderAction)
        try require(logCalls.count==2,"Retained folder menu survived refreshed snapshot")
        let folderLog=LogWindowController(repository:c.repository(),access:nil,labelDefaults:c.prefs,savesGeometry:false,initialRevision:c.revision,loadsImmediately:false);c.logs.append(folderLog)
        folderLog.model.showWorkingTree=false;folderLog.model.setPathScope([directory.path]);try await wait{!folderLog.model.busy && folderLog.model.pendingHistoryLoads==0}
        try require(folderLog.model.error==nil && folderLog.model.entries.map(\.hash)==[c.revision],"Pinned raw directory Log read failed: "+(folderLog.model.error ?? "wrong history"))
        let log=LogWindowController(repository:c.repository(),access:nil,labelDefaults:c.prefs,savesGeometry:false,initialRevision:c.revision,loadsImmediately:false)
        c.logs.append(log);log.window?.alphaValue=0
        log.model.showWorkingTree=false;log.model.setPathScope([raw.path])
        try await wait{!log.model.busy && log.model.pendingHistoryLoads==0}
        try require(log.model.error==nil && log.model.entries.map(\.hash)==[c.revision],"Raw pinned Log failed: "+(log.model.error ?? "wrong revisions"))
        try require(log.window?.title.contains("\0")==false && log.window?.title.contains(expected)==true,"Log title exposed opaque key or lost scope")
        log.model.select([c.revision]);try await wait{!log.model.busy && !log.model.loadingNote && !log.model.savingNote && LogWindowModel.activeActionReads==0 && log.model.files.contains{$0.path==raw.path}}
        guard let file=log.model.files.first(where:{$0.path==raw.path})else{throw Failure(description:"Raw changed file missing")}
        try require(log.model.changedFileText(file,column:.path).contains(expected),"Log row did not escape raw pathname")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};log.model.clipboard=board
        log.model.copyChangedFileIDs([file.id]);try require(board.string(forType:.string)==expected,"Log copied opaque key or replacement spelling")
        var navigated:[String]=[];log.model.onFileLog={path,hash in if hash==c.revision{navigated.append(path)}};log.model.onBlame={path,hash in if hash==c.revision{navigated.append(path)}}
        let receipt=log.model.fileMenuSnapshot(GitPathSet([file.id]))
        log.model.withFileMenu(receipt){log.model.fileLog([file.id])}
        log.model.blameFile([file.id]);try require(navigated==[raw.path,raw.path],"Log to Log/Blame origin changed raw identity")
        try require(!log.model.canRevertHistoricalFiles([file.id],parent:false) && !log.model.hasRepresentableFilePaths([file.id]),"Raw history enabled filesystem mutation")
        log.model.revealFile([file.id]);try require(log.model.error==RepositoryBrowserWindowModel.rawPathReason,"Raw reveal did not refuse explicitly");log.model.error=nil
        let blame=BlameWindowController(repository:c.repository(),access:nil,path:raw.path,revision:c.revision,preferences:c.prefs,requireScope:false)
        c.blames.append(blame);blame.window?.alphaValue=0
        try await wait{!blame.model.busy && BlameWindowModel.activeHistoryOperations==0}
        try require(blame.model.error==nil && blame.model.snapshot?.revision==c.revision && blame.model.snapshot?.path==raw.path && blame.model.snapshot?.contents==c.text,"Raw pinned Blame failed: "+(blame.model.error ?? "wrong source"))
        try require(blame.window?.title.contains(expected)==true && blame.window?.title.contains("\0")==false,"Blame title exposed opaque path")
        try require(blame.model.lines.allSatisfy{$0.filename==raw.path} && blame.model.marginText("filename",row:0)==expected,"Blame origins/margin lost exact/display identity")
        var origin:String?;blame.model.onLog={path,hash in if hash==c.revision{origin=path}}
        if let first=blame.model.lines.first{blame.model.showLog(first)}
        try require(origin==raw.path,"Blame Show log retargeted escaped spelling")
        // Exact authored wrapper owns one open fixture resource. Cancellation
        // must reap its process group before any late history can publish.
        let wrapper=c.folder.appendingPathComponent("held-helper"),hold=c.folder.appendingPathComponent("hold-history"),pid=c.folder.appendingPathComponent("history.pid"),resource=c.folder.appendingPathComponent("owned-history-resource")
        func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        try Data().write(to:resource)
        let script="#!/bin/sh\nexec 9<"+quote(resource.path)+"\nfor arg in \"$@\"; do\n if [ \"$arg\" = log ] || [ \"$arg\" = blame ]; then\n  if [ -e "+quote(hold.path)+" ]; then\n   echo $$ >"+quote(pid.path)+"\n   while [ -e "+quote(hold.path)+" ]; do sleep 0.02; done\n  fi\n fi\ndone\nexec "+quote(c.git.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        c.releases.append{try? FileManager.default.removeItem(at:hold)}
        let heldRepo=GitRepository(root:c.folder,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))
        try Data().write(to:hold)
        let heldLog=LogWindowController(repository:heldRepo,access:nil,labelDefaults:c.prefs,savesGeometry:false,initialRevision:c.revision,loadsImmediately:false);c.logs.append(heldLog)
        heldLog.model.showWorkingTree=false;heldLog.model.historyPaths=[raw.path];heldLog.model.showWholeProject=false;heldLog.model.reload()
        try await wait{FileManager.default.fileExists(atPath:pid.path)}
        heldLog.close();try? FileManager.default.removeItem(at:hold)
        try await wait{LogWindowModel.activeHistoryLoads==0}
        try require(heldLog.model.isInvalidated && heldLog.model.entries.isEmpty,"Retired Log published held raw history")
        try? FileManager.default.removeItem(at:pid);try Data().write(to:hold)
        let heldBlame=BlameWindowController(repository:heldRepo,access:nil,path:raw.path,revision:c.revision,preferences:c.prefs,requireScope:false);c.blames.append(heldBlame)
        try await wait{FileManager.default.fileExists(atPath:pid.path)}
        heldBlame.close();try? FileManager.default.removeItem(at:hold)
        try await wait{BlameWindowModel.activeHistoryOperations==0}
        try require(heldBlame.model.retired && heldBlame.model.snapshot==nil,"Retired Blame published held raw source")
        // This wrapper is test setup, not a working-tree mutation by an action.
        for url in [wrapper,resource,pid,hold]{try? FileManager.default.removeItem(at:url)}
        try await c.unchanged()
    }
    static func historical(_ c:Context)async throws {
        let selected=GitLibGit2Configuration(enabled:true,mask:GitLibGit2Operation.getOneFile.mask)
        c.prefs.set(true,forKey:"UseLibgit2");c.prefs.set(GitLibGit2Operation.getOneFile.mask,forKey:"UseLibgit2_mask")
        let repo=c.repository(backend:selected)
        let backendDescription="selected helper GetOneFile mask="+String(selected.mask)
        _=try await repo.run(["config","filter.qa.smudge","sed 's/stored/filtered/g'"])
        try FileManager.default.createDirectory(at:c.folder.appendingPathComponent(".git/info"),withIntermediateDirectories:true)
        try Data("*.txt filter=qa\n".utf8).write(to:c.folder.appendingPathComponent(".git/info/attributes"))
        c.config=try Data(contentsOf:c.folder.appendingPathComponent(".git/config"))
        let owner=try await c.owner(repository:repo),m=owner.model,raw=m.entries.first{$0.rawName==Data([0xff,0x2e,0x74,0x78,0x74])}!
        let filtered=Data("filtered body\n".utf8),expectedLeaf="Git-blob-"+raw.objectID+".txt"
        guard let table=owner.contentsTable,let menu=table.menu else{throw Failure(description:"Historical native menu absent")}
        func item(_ title:String)throws->NSMenuItem {
            table.selectRowIndexes(IndexSet(integer:m.entries.firstIndex(of:raw)!),byExtendingSelection:false);m.selection=[raw.id];menu.delegate?.menuNeedsUpdate?(menu)
            guard let value=menu.items.first(where:{$0.title==title})else{throw Failure(description:"Missing historical command "+title)}
            try require(value.isEnabled && value.image != nil,"Historical command disabled/icon absent: "+title);return value
        }
        func invoke(_ value:NSMenuItem)throws {
            guard let selector=value.action else{throw Failure(description:"Historical selector absent")}
            try require(NSApp.sendAction(selector,to:value.target,from:value),"Historical selector not delivered")
        }
        for title in ["Open","Open With…","View revision with alternative editor","Save revision to…","Mark for comparison"]{_=try item(title)}
        let destination=c.folder.deletingLastPathComponent().appendingPathComponent("filtered-historical.txt")
        defer{try? FileManager.default.removeItem(at:destination)}
        var names:[String]=[],writes=0
        let write=owner.writeDocument
        owner.writeDocument={bytes,url,token in writes+=1;try await write(bytes,url,token)}
        owner.saveDestination={_ in destination};owner.presentSavePanel={panel,_,reply in names.append(panel.nameFieldStringValue);reply(.OK);reply(.OK)}
        try invoke(item("Save revision to…"));try await wait{!owner.hasPendingWork && !m.hasPendingWork}
        try require(m.error==nil,"Filtered raw Save failed ("+backendDescription+"): "+(m.error ?? ""))
        try require(names==[expectedLeaf],"Filtered Save names=\(names), expected=\(expectedLeaf), "+backendDescription)
        try require(writes==1,"Filtered Save writes=\(writes), expected=1, "+backendDescription)
        let savedBytes=try Data(contentsOf:destination)
        try require(savedBytes==filtered,"Filtered Save actual=\(String(decoding:savedBytes,as:UTF8.self)), expected=\(String(decoding:filtered,as:UTF8.self)), "+backendDescription)
        let app=c.folder.deletingLastPathComponent().appendingPathComponent("PrivateHistoricalViewer.app")
        var launched:[URL]=[]
        owner.defaultApplication={_ in app};owner.selectedApplication={_ in app}
        owner.launchDocument={application,documents,_ in
            try require(application==app && documents.count==1,"Historical launch retargeted program")
            let file=documents[0];c.previewFiles.append(file);launched.append(file)
            try require(file.lastPathComponent=="Git-blob-"+raw.objectID+"-"+String(c.revision.prefix(7))+".txt" && (try Data(contentsOf:file))==filtered,"Filtered preview used escaped path or unfiltered bytes")
        }
        try invoke(item("Open"));try await wait{!owner.hasPendingWork && !m.hasPendingWork}
        try require(launched.count==1 && m.error==nil,"Raw ordinary Open failed")
        owner.presentApplicationPanel={_,_,reply in reply(.cancel)}
        try invoke(item("Open With…"));try await wait{!owner.hasPendingWork && !m.hasPendingWork}
        try require(launched.count==1,"Cancelled ordinary raw Open With launched")
        owner.presentApplicationPanel={_,_,reply in reply(.OK);reply(.OK)}
        try invoke(item("Open With…"));try await wait{!owner.hasPendingWork && !m.hasPendingWork}
        try require(launched.count==2 && launched[0] != launched[1] && m.error==nil,"Raw Open With reused preview or dispatched twice")
        let native=m.presentFile;var alternative=0
        m.presentFile={content,action in if action == .alternativeEditor && content.path==raw.path && content.objectID==raw.objectID && content.bytes==filtered{alternative+=1}}
        try invoke(item("View revision with alternative editor"));try await wait{!m.hasPendingWork}
        try require(alternative==1,"Alternative editor lost filtered content/exact source identity");m.presentFile=native
        try invoke(item("Mark for comparison"));try await wait{!m.hasPendingWork && !m.busy}
        try require(m.comparisonMark?.path==raw.path && m.comparisonMark?.revision==c.revision,"Raw historical mark retargeted")
        var compared=0
        m.onPreparedFileCompare={base,to in if base.path==raw.path && to.path==raw.path && base.revision==c.revision && to.revision==c.revision{compared+=1}}
        m.compareWithMarkedFile(raw);try await wait{!m.hasPendingWork && !m.busy};try require(compared==1,"Raw historical mark comparison did not dispatch")
        m.comparisonMark=PreparedFileComparisonMark(path:"valid.txt",revision:"")
        m.compareWithMarkedFile(raw);try require(m.error==RepositoryBrowserWindowModel.rawPathReason && compared==1,"Raw working-tree mark crossed filesystem boundary");m.error=nil
        // A retained application chooser cannot deliver to a retired Browser.
        var reply:((NSApplication.ModalResponse)->Void)?
        owner.presentApplicationPanel={_,_,callback in reply=callback};c.releases.append{reply?(.cancel);reply=nil}
        try invoke(item("Open With…"));try await wait{reply != nil};owner.close();reply?(.OK);reply=nil
        try await wait{!owner.hasPendingWork && !m.hasPendingWork};try require(launched.count==2,"Late filtered application choice launched after retirement")
        let nextBlob=try await c.oid(["hash-object","-w","--stdin"],input:Data("stored next\n".utf8))
        let nextTree=try await c.tree([("100644","blob",nextBlob,raw.rawName)])
        let next=try await c.oid(["commit-tree",nextTree,"-p",c.revision,"-m","next raw version"])
        let comparison=try await repo.preparedPathComparison(from:.revision(c.revision),fromPath:raw.path,to:.revision(next),toPath:raw.path)
        let merge=FileComparisonWindowController(repository:repo,access:nil,snapshot:comparison,path:raw.path,preferences:c.prefs);c.comparisons.append(merge)
        merge.model.load();try await wait{!merge.model.busy && !merge.model.mergeToolHasPendingWork}
        try require(merge.model.error==nil && merge.model.document?.base.bytes==c.text && merge.model.document?.destination.bytes==Data("stored next\n".utf8),"Raw comparison did not load exact original revisions: "+(merge.model.error ?? ""))
        try require(!merge.model.windowTitle.contains("\0") && !merge.model.paneHeader(base:true).contains("\0") && !merge.model.paneHelp(base:false).contains("\0"),"Comparison exposed opaque path key")
        var saveNames:[String]=[]
        merge.model.chooseExportLocation={_,name,_ in saveNames.append(name);return nil};merge.model.saveAs(base:false)
        try await wait{!merge.model.mergeToolHasPendingWork}
        try require(saveNames==["Git-blob-"+nextBlob+".txt"],"Comparison Save As suggested raw/escaped path")
        let patch=c.folder.deletingLastPathComponent().appendingPathComponent("raw-historical.diff")
        defer{try? FileManager.default.removeItem(at:patch)}
        merge.model.patchExecutable=c.git;merge.model.choosePatchLocation={_,name,_ in saveNames.append(name);return patch}
        merge.model.createUnifiedPatch();try await wait{!merge.model.mergeToolHasPendingWork}
        let bytes=try Data(contentsOf:patch)
        try require(merge.model.error==nil && bytes.range(of:Data("\\377.txt".utf8)) != nil && !bytes.contains(0),"Edited-buffer patch lost quoted exact raw filename")
        let blame=BlameWindowController(repository:repo,access:nil,path:raw.path,revision:next,options:GitBlameOptions(),preferences:c.prefs,requireScope:false);c.blames.append(blame)
        try await wait{!blame.model.busy && BlameWindowModel.activeHistoryOperations==0}
        var parentsReady=false
        blame.model.prepareParentMenu(number:1){parentsReady=true};try await wait{parentsReady && !blame.model.loadingParents}
        guard let target=blame.model.sourceParentTarget(next),let choice=blame.model.parentChoices.first else{throw Failure(description:"Raw Blame previous-origin choice missing: "+(blame.model.error ?? ""))}
        try require(choice.path==raw.path && choice.revision==c.revision,"Blame parent origin lost raw bytes or old commit")
        var previous=0,blameCompared=0,unified=0
        blame.model.onPrevious={path,revision,_,_ in if path==raw.path && revision==c.revision{previous+=1}}
        blame.model.onChanges={snapshot in if snapshot.from == .revision(c.revision) && snapshot.to == .revision(next) && snapshot.files.first?.path==raw.path{blameCompared+=1}}
        blame.model.onHistoryUnified={bytes,title,_ in
            try require(bytes.range(of:Data("\\377.txt".utf8)) != nil && !title.contains("\0"),"Blame unified diff lost raw header/display caption");unified+=1
        }
        blame.model.performHistoryParent(target,choices:[choice],action:.previous)
        blame.model.performHistoryParent(target,choices:[choice],action:.compare)
        blame.model.performHistoryParent(target,choices:[choice],action:.unified)
        try await wait{BlameWindowModel.activeHistoryOperations==0}
        try require(previous==1 && blameCompared==1 && unified==1 && blame.model.error==nil,"Raw Blame previous/compare/unified family did not deliver")
        let log=LogWindowController(repository:repo,access:nil,labelDefaults:c.prefs,savesGeometry:false,initialRevision:c.revision,loadsImmediately:false);c.logs.append(log)
        log.model.showWorkingTree=false;log.model.setPathScope([raw.path]);try await wait{!log.model.busy && log.model.pendingHistoryLoads==0 && LogWindowModel.activeActionReads==0}
        guard let file=log.model.files.first(where:{$0.path==raw.path})else{throw Failure(description:"Historical Log raw row absent")}
        var saved:ComparisonFileContent?,opened:ComparisonFileContent?,pairPaths:[String]=[]
        log.model.presentHistoricalSave={value,_ in saved=value};log.model.saveHistoricalFile([file.id]);try await wait{LogWindowModel.activeFileOpenReads==0}
        try require(saved?.bytes==filtered && saved?.path==raw.path && saved?.objectID==raw.objectID,"Log Save did not preserve filtered raw origin")
        log.model.presentHistoricalOpen={value,_ in opened=value};log.model.openHistoricalFile([file.id],action:.openWith);try await wait{LogWindowModel.activeFileOpenReads==0}
        try require(opened?.bytes==filtered && opened?.path==raw.path,"Log Open did not use filtered raw historical content")
        log.model.onFileComparisons={requests in pairPaths=requests.flatMap{$0.2}}
        log.model.compareFiles([file.id]);try require(pairPaths==[raw.path],"Log parent comparison replaced raw path")
        log.model.compareFiles([file.id],workingTree:true);try require(log.model.error==RepositoryBrowserWindowModel.rawPathReason && pairPaths==[raw.path],"Log raw working-tree comparison dispatched");log.model.error=nil
        // Generic external comparison receives real private files separately
        // from escaped labels; original raw keys never become argv or URLs.
        guard let externalDocument=merge.model.document else{throw Failure(description:"External comparison document absent")}
        var program=DiffToolProgram();program.enabled=true;program.applicationPath=app.path;program.arguments="%base %mine %bname %yname %bpath %ypath"
        var externalCalls=0,privateFiles:[URL]=[]
        let openedExternal=try await DiffToolApplication.open(externalDocument,root:c.folder,permissions:[],alternate:false,preferences:c.prefs,selection:.program(program),launch:{application,configuration in
            let args=configuration.arguments;externalCalls+=1
            try require(application==app && args.count==6 && args.allSatisfy{!$0.contains("\0")},"External raw comparison passed opaque argv")
            let a=URL(fileURLWithPath:args[0]),b=URL(fileURLWithPath:args[1]);privateFiles += [a,b]
            try require(a.lastPathComponent==expectedLeaf && b.lastPathComponent=="Git-blob-"+nextBlob+".txt" && args[4]==a.path && args[5]==b.path,"External raw path arguments were not private safe leaves")
            try require(args[2]==RepositoryBrowserGitPath.display(key:raw.path)+" : "+c.revision && args[3]==RepositoryBrowserGitPath.display(key:raw.path)+" : "+next,"External raw display labels changed identity")
            try require((try Data(contentsOf:a))==c.text && (try Data(contentsOf:b))==Data("stored next\n".utf8),"External comparison altered original source bytes")
            for file in [a,b]{try require((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue==0o444,"External input not read-only")}
        })
        try require(openedExternal && externalCalls==1 && DiffToolApplication.activeRequests==0,"External comparison ownership did not settle")
        let absentSnapshot=try await repo.revisionComparison(from:.emptyTree,to:.revision(next),paths:[raw.path])
        let absentDocument=try await repo.comparisonFile(absentSnapshot,path:raw.path)
        let addedMerge=FileComparisonWindowController(repository:repo,access:nil,snapshot:absentSnapshot,path:raw.path,preferences:c.prefs);c.comparisons.append(addedMerge)
        addedMerge.model.load();try await wait{!addedMerge.model.busy && !addedMerge.model.mergeToolHasPendingWork}
        try require(addedMerge.model.error==nil && addedMerge.model.document?.base.mode==nil,"Added raw comparison did not expose absent base")
        var absentNames:[String]=[]
        addedMerge.model.chooseExportLocation={_,name,_ in absentNames.append(name);return nil};addedMerge.model.saveAs(base:true)
        try await wait{!addedMerge.model.mergeToolHasPendingWork}
        try require(absentNames==["base-absent.txt"],"Added raw absent-base Save As required a fictional blob")
        let deletedSnapshot=try await repo.revisionComparison(from:.revision(next),to:.emptyTree,paths:[raw.path])
        let deletedMerge=FileComparisonWindowController(repository:repo,access:nil,snapshot:deletedSnapshot,path:raw.path,preferences:c.prefs);c.comparisons.append(deletedMerge)
        deletedMerge.model.load();try await wait{!deletedMerge.model.busy && !deletedMerge.model.mergeToolHasPendingWork}
        try require(deletedMerge.model.error==nil && deletedMerge.model.document?.destination.mode==nil,"Deleted raw comparison did not expose absent destination")
        deletedMerge.model.chooseExportLocation={_,name,_ in absentNames.append(name);return nil};deletedMerge.model.saveAs(base:false)
        try await wait{!deletedMerge.model.mergeToolHasPendingWork}
        deletedMerge.model.choosePatchLocation={_,name,_ in absentNames.append(name);return nil};deletedMerge.model.createUnifiedPatch()
        try await wait{!deletedMerge.model.mergeToolHasPendingWork}
        try require(absentNames==["base-absent.txt","mine-absent.txt","mine-absent.txt.diff"] && deletedMerge.model.error==nil,"Raw deletion patch/Save As proposal required an absent blob")
        _=try await DiffToolApplication.open(absentDocument,root:c.folder,permissions:[],alternate:false,preferences:c.prefs,selection:.program(program),launch:{_,configuration in
            let args=configuration.arguments;externalCalls+=1
            try require(args.count==6,"Absent-side external argument count changed")
            let file=URL(fileURLWithPath:args[0]);privateFiles.append(file)
            try require(file.lastPathComponent=="base-absent.txt" && (try Data(contentsOf:file)).isEmpty && args[4]==file.path,"Absent raw side invented a blob or original filesystem path")
        })
        let cancelled=OperationCancellation();cancelled.cancel()
        do{_=try await DiffToolApplication.open(externalDocument,root:c.folder,permissions:[],alternate:false,preferences:c.prefs,cancellation:cancelled,selection:.program(program),launch:{_,_ in externalCalls+=1});throw Failure(description:"Cancelled external raw comparison dispatched")}
        catch is OperationCancellationFailure{}
        try require(externalCalls==2 && DiffToolApplication.activeRequests==0,"Cancelled external comparison lost ownership")
        let ordinarySnapshot=try await repo.preparedPathComparison(from:.revision(c.revision),fromPath:"valid.txt",to:.revision(c.revision),toPath:"valid.txt")
        let ordinaryDocument=try await repo.comparisonFile(ordinarySnapshot,path:"valid.txt")
        _=try await DiffToolApplication.open(ordinaryDocument,root:c.folder,permissions:[],alternate:false,preferences:c.prefs,selection:.program(program),launch:{_,configuration in
            let args=configuration.arguments;externalCalls+=1
            try require(args.count==6 && args[4]=="valid.txt" && args[5]=="valid.txt" && args[2]=="valid.txt : "+c.revision,"Ordinary external path/title arguments changed")
            try require(URL(fileURLWithPath:args[0]).lastPathComponent=="valid.txt","Ordinary private preview leaf changed")
        })
        DiffToolApplication.discardAll();try require(privateFiles.allSatisfy{!FileManager.default.fileExists(atPath:$0.path)},"External private previews survived owned cleanup")
        // Hold the real selected-helper smudge child, then force retirement.
        // Its exact authored script/resource is recognized by runner cleanup.
        let wrapper=c.folder.appendingPathComponent("held-helper"),hold=c.folder.appendingPathComponent("hold-filter"),pid=c.folder.appendingPathComponent("filter.pid"),resource=c.folder.appendingPathComponent("owned-filter-resource")
        func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        try Data().write(to:resource);try Data().write(to:hold)
        let script="#!/bin/sh\nexec 9<"+quote(resource.path)+"\necho $$ >"+quote(pid.path)+"\nwhile [ -e "+quote(hold.path)+" ]; do sleep 0.02; done\nsed 's/stored/filtered/g'\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        _=try await repo.run(["config","filter.qa.smudge",quote(wrapper.path)])
        c.releases.append{try? FileManager.default.removeItem(at:hold)}
        let heldRepository=c.repository(backend:selected)
        let held=RepositoryBrowserWindowController(repository:heldRepository,access:nil,revision:c.revision,preferences:c.prefs);c.owners.append(held)
        try await wait{!held.model.busy && !held.model.hasPendingWork}
        guard let heldFile=held.model.entries.first(where:{$0.rawName==raw.rawName})else{throw Failure(description:"Held filtered raw row missing")}
        var late=0;held.model.presentFile={_,_ in late+=1};held.model.open(heldFile)
        try await wait{FileManager.default.fileExists(atPath:pid.path)}
        held.close();try require(held.model.hasPendingWork && !held.model.active,"Filtered producer ownership disappeared on close")
        try? FileManager.default.removeItem(at:hold);try await wait{!held.model.hasPendingWork && RepositoryBrowserWindowModel.activeOperations==0}
        try require(late==0,"Retired filtered producer launched a document")
        _=try await repo.run(["config","filter.qa.smudge","sed 's/stored/filtered/g'"])
        for url in [wrapper,hold,pid,resource]{try? FileManager.default.removeItem(at:url)}
        try await c.unchanged()
    }
    static func main()async{
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.namespaceFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.namespaceOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}}
        defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context(),name=CommandLine.arguments[3]
        do{try await c.prepare();switch name{case "listing":try await listing(c);case "navigation":try await navigation(c);case "actions":try await actions(c);case "ownership":try await ownership(c);case "delivery":try await delivery(c);case "history":try await history(c);case "historical":try await historical(c);default:throw Failure(description:"Unknown case")};await c.cleanup();print("PASS: Browser namespace "+name)}catch{await c.cleanup();fputs("\(error)\n",stderr);exit(1)}
    }
}
