// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func browserArchiveQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));browserArchiveQAOrder(mode,relativeTo:number)}
}
@MainActor @main enum BrowserFolderArchiveVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"line \(line): "+message)}}
    static func wait(_ message:String,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Browser archive timeout at \(line): "+message)}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    @MainActor final class Context {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.BrowserFolderArchive.QA."+UUID().uuidString
        let preferences:UserDefaults,board=NSPasteboard.withUniqueName()
        var owners:[RepositoryBrowserWindowController]=[]
        var root:URL{folder.appendingPathComponent("repository")}
        var repo:GitRepository{GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(mask:0))}
        var old="",new="",head=Data(),index=Data(),config=Data(),working=Data()
        let rawFolder=Data([0xff])+Data(" raw folder [x]".utf8)
        var rawKey:String{try! RepositoryBrowserGitPath(rawData:rawFolder).key}
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(false,forKey:"UseLibgit2");preferences.set(true,forKey:"ShowAppContextMenuIcons")}
        func oid(_ args:[String],input:Data?=nil)async throws->String{try await repo.run(args,input:input).text.trimmingCharacters(in:.newlines)}
        func tree(_ entries:[(String,String,String,Data)])async throws->String{
            var packet=Data();for(mode,type,object,path)in entries{packet.append(Data("\(mode) \(type) \(object)\t".utf8));packet.append(path);packet.append(0)}
            return try await oid(["mktree","-z"],input:packet)
        }
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Folder archive QA"),("user.email","archive@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repo.run(["config",key,value])}
            let sentinel=root.appendingPathComponent("working-sentinel.txt");try Data("working/index sentinel\n".utf8).write(to:sentinel);try await repo.stage([sentinel.lastPathComponent]);_=try await repo.commit(message:"seed")
            let seed=try await oid(["rev-parse","HEAD"]),blob=try await oid(["hash-object","-w","--stdin"],input:Data("stored $Format:%H$\n".utf8)),attributes=try await oid(["hash-object","-w","--stdin"],input:Data("omit.txt export-ignore\n*.txt export-subst\n".utf8)),binary=try await oid(["hash-object","-w","--stdin"],input:Data([0,0xff,0x41,10])),link=try await oid(["hash-object","-w","--stdin"],input:Data("inside.txt".utf8))
            let child=try await tree([("100644","blob",attributes,Data(".gitattributes".utf8)),("100644","blob",blob,Data("inside.txt".utf8)),("100644","blob",blob,Data("omit.txt".utf8)),("100755","blob",binary,Data([0xfe])+Data(" executable.bin".utf8)),("120000","blob",link,Data("symbolic.link".utf8))])
            let sentinelOID=try await oid(["rev-parse","HEAD:working-sentinel.txt"])
            let oldTree=try await tree([("100644","blob",sentinelOID,Data("working-sentinel.txt".utf8)),("040000","tree",child,Data("deleted folder".utf8)),("040000","tree",child,rawFolder)])
            old=try await oid(["commit-tree",oldTree,"-p",seed],input:Data("historical folders\n".utf8))
            let newTree=try await tree([("100644","blob",sentinelOID,Data("working-sentinel.txt".utf8))])
            new=try await oid(["commit-tree",newTree,"-p",old],input:Data("folders deleted\n".utf8));_=try await repo.run(["update-ref","refs/heads/main",new]);_=try await repo.run(["update-ref","refs/heads/archive-source",old])
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"));config=try Data(contentsOf:root.appendingPathComponent(".git/config"));working=try Data(contentsOf:sentinel)
        }
        func owner(repository:GitRepository?=nil,revision:String?=nil)async throws->RepositoryBrowserWindowController {
            let value=RepositoryBrowserWindowController(repository:repository ?? repo,access:nil,revision:revision ?? old,preferences:preferences)
            owners.append(value);value.window?.isReleasedWhenClosed=false;value.window?.alphaValue=0;value.showWindow(nil);value.model.refresh()
            try await BrowserFolderArchiveVerification.wait("actual historical Browser ready"){!value.model.busy && !value.model.hasPendingWork && value.model.snapshot != nil}
            try BrowserFolderArchiveVerification.require(value.model.error==nil,"Browser failed: "+(value.model.error ?? ""))
            try await BrowserFolderArchiveVerification.wait("native Browser contents table ready"){value.window?.contentView?.layoutSubtreeIfNeeded();return value.contentsTable?.numberOfRows==value.model.entries.count}
            return value
        }
        func unchanged()async throws {
            try BrowserFolderArchiveVerification.require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Archive changed HEAD")
            try BrowserFolderArchiveVerification.require((try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:root.appendingPathComponent(".git/config")))==config && (try Data(contentsOf:root.appendingPathComponent("working-sentinel.txt")))==working,"Archive changed index/config/worktree")
            try BrowserFolderArchiveVerification.require(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()==[".git","working-sentinel.txt"],"Historical archive materialized absent/raw working folders")
        }
        func clean()async throws {
            for owner in owners {owner.model.cancelFileRead();owner.model.error=nil;if let sheet=owner.window?.attachedSheet{owner.window?.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)};owner.close()}
            try await BrowserFolderArchiveVerification.wait("all archive panels/process owners drain"){owners.allSatisfy{!$0.hasPendingWork && !$0.model.hasPendingWork && $0.window?.attachedSheet==nil && $0.window?.isVisible != true} && RepositoryBrowserFileOperation.activeRequests==0}
            preferences.removePersistentDomain(forName:suite);board.releaseGlobally()
        }
    }
    static func item(_ owner:RepositoryBrowserWindowController,scope:String?)async throws->NSMenuItem {
        let table=try unwrap(owner.contentsTable,"Missing actual Browser contents table"),model=owner.model
        if let scope {
            let row=try unwrap(model.entries.firstIndex{RepositoryBrowserPathIdentity.equal($0.path,scope)},"Requested archive folder absent from displayed listing")
            table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            try await wait("native folder selection accepted"){model.selection==[model.entries[row].id]}
        } else {table.deselectAll(nil);try await wait("native background selection accepted"){model.selection.isEmpty}}
        let menu=try unwrap(table.menu,"Missing actual Browser contents menu")
        menu.delegate?.menuNeedsUpdate?(menu)
        let entry=try unwrap(menu.items.first{$0.title=="Save as archive…"},"Historical folder archive menu missing")
        try require(entry.isEnabled && entry.image != nil && entry.target != nil && entry.action != nil,"Actual archive menu lacks source icon/eligible target")
        return entry
    }
    static func invoke(_ item:NSMenuItem)throws {
        try require(item.action != nil && NSApp.sendAction(item.action!,to:item.target,from:item),"Actual Browser archive menu refused dispatch")
    }
    static func expected(_ c:Context,scope:String,format:String="zip",repository:GitRepository?=nil)async throws->Data {
        let repository=repository ?? c.repo
        var args=["archive","--format="+format,"--end-of-options",c.old],overrides:[Int:Data]=[:]
        if !scope.isEmpty {args += [RepositoryBrowserGitPath.display(key:scope)];overrides[4]=try RepositoryBrowserGitPath(key:scope).rawData}
        return try await repository.run(args,argumentBytes:overrides).stdout
    }
    static func save(_ c:Context,_ owner:RepositoryBrowserWindowController,_ menu:NSMenuItem,scope expectedScope:String,to destination:URL)async throws {
        var panels=0,executions=0,defaultZIP=false,capturedScope:String?,capturedCommit:String?,capturedBackend:GitLibGit2Configuration?
        let execute=owner.archiveDirectory
        owner.archiveDirectory={repo,snapshot,scope,url,token in executions+=1;capturedScope=scope;capturedCommit=snapshot.objectID;capturedBackend=repo.libgit2Configuration;try await execute(repo,snapshot,scope,url,token)}
        owner.saveDestination={_ in destination};owner.presentSavePanel={panel,_,reply in
            panels+=1;defaultZIP=panel.nameFieldStringValue.hasSuffix(".zip")
            reply(.OK);reply(.OK)
        }
        try invoke(menu);try await wait("actual archive command/output settles"){!owner.hasPendingWork && !owner.model.hasPendingWork && !owner.model.handlingFile}
        try require(panels==1 && executions==1 && defaultZIP && capturedCommit==c.old && capturedScope.map{RepositoryBrowserPathIdentity.equal($0,expectedScope)}==true && capturedBackend?.enabled==false && owner.model.error==nil,"Archive retargeted revision/backend or repeated owned panel/process: "+(owner.model.error ?? ""))
        try require((try Data(contentsOf:destination))==(try await expected(c,scope:expectedScope,format:destination.pathExtension=="tar" ? "tar":"zip",repository:owner.model.repository)),"Native archive differs from literal pinned Git archive (raw names/attributes/modes/prefix)")
    }
    static func delivery(_ c:Context)async throws {
        for (label,scope,format) in [("deleted",String("deleted folder"),"zip"),("raw",c.rawKey,"zip"),("root","","tar")] {
            let owner=try await c.owner(),destination=c.folder.appendingPathComponent(label+"-archive."+format)
            try require(!FileManager.default.fileExists(atPath:c.root.appendingPathComponent("deleted folder").path),"Fixture historical directory unexpectedly exists in worktree")
            let command=try await item(owner,scope:scope.isEmpty ? nil:scope)
            try await save(c,owner,command,scope:scope,to:destination);try await c.unchanged();owner.close()
        }
        let bare=c.folder.appendingPathComponent("bare.git");_=try await c.repo.run(["clone","--bare","--no-hardlinks","--",c.root.path,bare.path])
        let bareRepo=GitRepository(root:bare,executable:c.git,askpass:nil,libgit2Configuration:.init(mask:0)),owner=try await c.owner(repository:bareRepo)
        try require(owner.model.snapshot?.bare==true && owner.model.canSaveArchive(directory:c.rawKey),"Bare Browser disabled captured raw folder archive")
        try await save(c,owner,try await item(owner,scope:c.rawKey),scope:c.rawKey,to:c.folder.appendingPathComponent("bare-raw.zip"));owner.close();try await c.unchanged()

        let treeOwner=try await c.owner();treeOwner.model.openFolder(c.rawKey)
        try await wait("raw historical folder opens"){!treeOwner.model.busy && treeOwner.model.snapshot?.directory==c.rawKey}
        let background=try await item(treeOwner,scope:nil)
        try await save(c,treeOwner,background,scope:c.rawKey,to:c.folder.appendingPathComponent("raw-current-folder.zip"))
        let outline=try unwrap(descendants(treeOwner.window!.contentView!).compactMap{$0 as? RepositoryBrowserFolderOutline}.first,"Missing actual Browser folder tree")
        try await wait("current raw folder tree selected"){outline.selectedRow>=0 && !treeOwner.model.handlingFile}
        let treeMenu=try unwrap(outline.menu,"Missing native tree folder menu");treeMenu.delegate?.menuNeedsUpdate?(treeMenu)
        let treeCommand=try unwrap(treeMenu.items.first{$0.title=="Save as archive…"},"Tree folder archive missing")
        try require(treeCommand.isEnabled && treeCommand.image != nil,"Tree archive omitted source icon/eligibility")
        try await save(c,treeOwner,treeCommand,scope:c.rawKey,to:c.folder.appendingPathComponent("raw-tree-folder.zip"));treeOwner.close();try await c.unchanged()
    }
    static func panelOwnership(_ c:Context)async throws {
        let staleOwner=try await c.owner(),staleMenu=try await item(staleOwner,scope:c.rawKey)
        let table=try unwrap(staleOwner.contentsTable,"Missing stale-menu table"),nextRow=try unwrap(staleOwner.model.entries.firstIndex{$0.path=="deleted folder"},"Missing replacement selected folder")
        table.selectRowIndexes(IndexSet(integer:nextRow),byExtendingSelection:false)
        try await wait("native replacement folder selection accepted"){staleOwner.model.selection==[staleOwner.model.entries[nextRow].id]}
        var stalePanels=0;staleOwner.presentSavePanel={_,_,reply in stalePanels+=1;reply(.cancel)}
        try invoke(staleMenu);try require(stalePanels==0 && !staleOwner.hasPendingWork,"Retained archive menu retargeted a later folder selection")
        staleOwner.close()
        for kind in ["cancel","selection","revision","retire"] {
            let owner=try await c.owner(),target=c.folder.appendingPathComponent("preserved-"+kind+".zip"),sentinel=Data("existing archive must remain byte-exact\n".utf8)
            try sentinel.write(to:target);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
            var answer:((NSApplication.ModalResponse)->Void)?,executions=0
            owner.saveDestination={_ in target};owner.presentSavePanel={_,_,reply in answer=reply};owner.archiveDirectory={_,_,_,_,_ in executions+=1;throw Failure(description:"Stale/canceled panel unexpectedly began archive")}
            try invoke(try await item(owner,scope:c.rawKey));try await wait("captured native save panel callback held"){answer != nil}
            try require(owner.hasPendingWork && owner.model.handlingFile && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held archive panel lost owned Quit accounting")
            if kind=="selection" {owner.model.selection=[]}
            if kind=="revision" {owner.model.revision=c.new}
            if kind=="retire" {owner.close()}
            answer?(kind=="cancel" ? .cancel:.OK);answer?(.OK);answer=nil
            try await wait("stale archive save callback drains"){!owner.hasPendingWork && !owner.model.hasPendingWork}
            try require(executions==0 && (try Data(contentsOf:target))==sentinel && ((try FileManager.default.attributesOfItem(atPath:target.path)[.posixPermissions]) as? NSNumber)?.intValue==0o600,"Canceled/stale panel overwrote existing archive or started Git")
            owner.model.error=nil;owner.close();try await c.unchanged()
        }
        let owner=try await c.owner(revision:"archive-source"),destination=c.folder.appendingPathComponent("pinned-reference.zip"),menu=try await item(owner,scope:"deleted folder")
        var reply:((NSApplication.ModalResponse)->Void)?
        owner.presentSavePanel={_,_,answer in reply=answer};owner.saveDestination={_ in destination}
        try invoke(menu);try await wait("captured archive path held"){reply != nil}
        _=try await c.repo.run(["update-ref","refs/heads/archive-source",c.new])
        reply?(.OK);reply=nil;try await wait("pinned old tree archive settles"){!owner.hasPendingWork && !owner.model.hasPendingWork}
        let pinnedArchive=try await expected(c,scope:"deleted folder")
        try require(owner.model.error==nil && (try Data(contentsOf:destination))==pinnedArchive,"Moving named ref retargeted accepted archive snapshot")
        owner.close();try await c.unchanged()
    }
    private final class ScopeProvider:RepositoryBookmarkProvider {
        let allowed:Bool
        init(_ allowed:Bool){self.allowed=allowed}
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{allowed}
        func stopAccessing(_ url:URL){}
    }
    static func outputFences(_ c:Context)async throws {
        for kind in ["no-scope","wrong-target","changed-destination"] {
            let owner=try await c.owner(),target=c.folder.appendingPathComponent(kind+".zip"),original=Data("existing archive\n".utf8),replacement=Data("external replacement after actual archive process\n".utf8)
            try original.write(to:target);var executions=0
            owner.saveDestination={_ in target};owner.presentSavePanel={_,_,reply in reply(.OK)}
            if kind != "changed-destination" {
                owner.requiresArchiveOutputScope=true
                let provider=ScopeProvider(kind=="wrong-target")
                owner.makeArchiveOutputLease={url in RepositoryAccessLease(url:kind=="wrong-target" ? c.root:url,provider:provider)}
                owner.archiveDirectory={_,_,_,_,_ in executions+=1;throw Failure(description:"Unauthorized archive executor admitted")}
            } else {
                owner.archiveDirectory={repo,snapshot,scope,url,token in
                    executions+=1
                    _=try await repo.archiveRepositoryBrowser(snapshot,directory:scope,to:url,cancellation:token,beforeFinalization:{try replacement.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o440],ofItemAtPath:url.path)})
                }
            }
            try invoke(try await item(owner,scope:c.rawKey));try await wait("archive output authority/CAS refusal"){!owner.hasPendingWork && !owner.model.hasPendingWork && owner.model.error != nil}
            try require(executions==(kind=="changed-destination" ? 1:0) && (try Data(contentsOf:target))==(kind=="changed-destination" ? replacement:original),"Archive output authority/CAS failure overwrote destination or ran unauthorized Git")
            if kind=="changed-destination" {try require(((try FileManager.default.attributesOfItem(atPath:target.path)[.posixPermissions]) as? NSNumber)?.intValue==0o440,"Archive replacement refusal changed external mode")}
            owner.model.error=nil;owner.close();try await c.unchanged()
        }
    }
    static func cancellation(_ c:Context)async throws {
        for close in [false,true] {
            let name=close ? "close":"cancel",helper=c.folder.appendingPathComponent("held-archive-"+name),entered=c.folder.appendingPathComponent("held-archive-"+name+".pid"),fifo=c.folder.appendingPathComponent("held-archive-"+name+".fifo")
            try require(mkfifo(fifo.path,mode_t(0o600))==0,"Cannot create private archive hold FIFO")
            let script="""
            #!/bin/sh
            task_archive=false
            for task_arg in "$@"; do if [ "$task_arg" = archive ]; then task_archive=true; fi; done
            if [ "$task_archive" = true ]; then
              printf '%s\\n' "$$" > \(quote(entered.path))
              IFS= read -r task_release < \(quote(fifo.path))
            fi
            exec \(quote(c.git.path)) "$@"
            """
            try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            let repo=GitRepository(root:c.root,executable:helper,askpass:nil,libgit2Configuration:.init(mask:0)),owner=try await c.owner(repository:repo)
            let destination=c.folder.appendingPathComponent("held-"+name+".zip"),original=Data("preserve old archive through cancellation\n".utf8)
            try original.write(to:destination);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            owner.saveDestination={_ in destination};owner.presentSavePanel={_,_,reply in reply(.OK)}
            try invoke(try await item(owner,scope:c.rawKey));try await wait("actual Git archive process held"){FileManager.default.fileExists(atPath:entered.path)}
            let pid=try unwrap(Int32(String(contentsOf:entered).trimmingCharacters(in:.whitespacesAndNewlines)),"Private archive PID invalid")
            try require(owner.hasPendingWork && owner.model.handlingFile && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Running archive lost process/Quit ownership")
            if close {owner.window?.performClose(nil);try require(owner.hasPendingWork,"Closed Browser released live archive process")}
            else {owner.model.cancelFileRead()}
            try await wait("canceled actual archive worker drains"){!owner.hasPendingWork && !owner.model.hasPendingWork && kill(pid,0) != 0}
            try require((try Data(contentsOf:destination))==original && ((try FileManager.default.attributesOfItem(atPath:destination.path)[.posixPermissions]) as? NSNumber)?.intValue==0o600,"Canceled archive changed existing bytes/mode")
            try require(kill(pid,0) != 0,"Canceled/closed archive helper survived actual drain")
            owner.close();try await c.unchanged()
        }
    }
    static func main()async {
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.browserArchiveQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            try await c.prepare();try await delivery(c);try await panelOwnership(c);try await outputFences(c);try await cancellation(c);try await c.unchanged();try await c.clean()
            print("PASS Browser folder archive: actual row/background/tree source menus, raw/deleted/bare pinned Git archives, attributes, owner/output fences, cancellation/process drain and unchanged HEAD/index/worktree")
        } catch {try? await c.clean();fputs("Browser folder archive failed: \(error)\n",stderr);exit(1)}
    }
}
