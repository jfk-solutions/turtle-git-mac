// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func savedResolveOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));savedResolveOrder(mode,relativeTo:number)}
    @objc func savedResolveSheet(_ child:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?){child.alphaValue=0;child.setFrameOrigin(.init(x:-24000,y:-24000));savedResolveSheet(child,completionHandler:completionHandler)}
}
private final class SavedResolveBookmarks:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data{Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool{true}
    func stopAccessing(_ url:URL){}
}
@MainActor @main enum MergeSavedResolveVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Saved result Resolve timeout: "+message)}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return[]};return[view]+view.subviews.flatMap{views($0)}}
    static func items(_ menu:NSMenu)->[NSMenuItem]{menu.items.flatMap{[$0]+($0.submenu.map(items) ?? [])}}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    @MainActor final class Case {
        let folder:URL,root:URL,metadataRoot:URL?,inputs:[URL],real:GitRepository,owner:TextConflictWindowController,suite:String,prefs:UserDefaults,menu:NSMenu,helper:URL,path:String,peer:Data,peerWorking:Data,head:String
        var target:URL,resolved=[(URL,String)]()
        var model:TextConflictWindowModel{owner.model}
        init(folder:URL,root:URL,metadataRoot:URL?,inputs:[URL],real:GitRepository,owner:TextConflictWindowController,suite:String,prefs:UserDefaults,menu:NSMenu,helper:URL,path:String,target:URL,peer:Data,peerWorking:Data,head:String){self.folder=folder;self.root=root;self.metadataRoot=metadataRoot;self.inputs=inputs;self.real=real;self.owner=owner;self.suite=suite;self.prefs=prefs;self.menu=menu;self.helper=helper;self.path=path;self.target=target;self.peer=peer;self.peerWorking=peerWorking;self.head=head}
        func clear()async throws{model.error=nil;try await wait("owned diagnostic release"){owner.window?.attachedSheet==nil}}
        func close()async throws{if let window=owner.window,let child=window.attachedSheet{window.endSheet(child,returnCode:.cancel);child.orderOut(nil);child.close()};owner.close();try await wait("actual saved Resolve owner drain"){!model.mergeToolHasPendingWork && MergeRegexOperations.activeRequests==0};prefs.removePersistentDomain(forName:suite)}
        func peersPreserved()async throws {
            let current=try await real.run(["ls-files","--stage","-z","--","peer.txt"]).stdout,headNow=try await real.rebaseCommit("HEAD").hash
            try require(current==peer && headNow==head && (try Data(contentsOf:root.appendingPathComponent("peer.txt")))==peerWorking,"Resolve changed peer index/working bytes or committed HEAD")
            for file in inputs{try require((try Data(contentsOf:file))==Data("input baseline\n".utf8),"Resolve wrote original standalone input")}
        }
    }
    static func make(_ folder:URL,git:URL,kind:String="tracked",p4:Bool=false,narrow:Bool=false,linked:Bool=false,readOnly:Bool=false)async throws->Case {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let inputFolder=folder.appendingPathComponent("inputs"),mainRoot=folder.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:inputFolder,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:mainRoot,withIntermediateDirectories:true)
        let inputs=["base.txt","theirs.txt","mine.txt"].map{inputFolder.appendingPathComponent($0)}
        for file in inputs{try Data("input baseline\n".utf8).write(to:file)}
        let main=GitRepository(root:mainRoot,executable:git,libgit2Configuration:.init(enabled:false)),path="results/-saved 雪\t[*].txt"
        _=try await main.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Saved Resolve QA"),("user.email","resolve@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await main.run(["config",key,value])}
        try Data("peer baseline\n".utf8).write(to:mainRoot.appendingPathComponent("peer.txt"));try await main.stage(["peer.txt"])
        if kind != "new"{try FileManager.default.createDirectory(at:mainRoot.appendingPathComponent("results"),withIntermediateDirectories:true);try Data("initial target\n".utf8).write(to:mainRoot.appendingPathComponent(path));try await main.stage([path])}
        _=try await main.commit(message:"private saved-target baseline")
        if kind=="unmerged" || kind=="rebound" {
            _=try await main.run(["switch","-c","side"]);try Data("incoming target\n".utf8).write(to:mainRoot.appendingPathComponent(path));try await main.stage([path]);_=try await main.commit(message:"incoming")
            _=try await main.run(["switch","main"]);try Data("current target\n".utf8).write(to:mainRoot.appendingPathComponent(path));try await main.stage([path]);_=try await main.commit(message:"current")
            let merge=try await main.run(["merge","--no-edit","side"],successfulExitCodes:0...1);try require(merge.exitCode==1,"Actual unmerged saved target setup failed")
        }
        let root:URL
        if linked{root=folder.appendingPathComponent("linked-worktree");_=try await main.run(["worktree","add","-b","linked",root.path])}else{root=mainRoot}
        let real=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("results"),withIntermediateDirectories:true)
        try Data("peer staged\n".utf8).write(to:root.appendingPathComponent("peer.txt"));try await real.stage(["peer.txt"]);try Data("peer working\n".utf8).write(to:root.appendingPathComponent("peer.txt"))
        let target=root.appendingPathComponent(path),helper=folder.appendingPathComponent("resolve-git")
        guard mkfifo(helper.path+".fifo",mode_t(0o600))==0 else{throw Failure(description:"Private Resolve FIFO unavailable")}
        let script="""
        #!/bin/sh
        printf '%s\\0' "$@" >> "$0.trace"
        task_add=false
        for task_arg in "$@"; do if [ "$task_arg" = add ]; then task_add=true; fi; done
        if [ "$task_add" = true ]; then
          /bin/cat > "$0.packet"
          printf '%s\\n' "$$" > "$0.entered"
          if [ -f "$0.mode" ]; then
            IFS= read -r task_mode < "$0.mode"
            if [ "$task_mode" = fail ]; then printf '%s\\n' 'Controlled saved Resolve failure' >&2; exit 17; fi
            if [ "$task_mode" = hold ]; then IFS= read -r task_release < "$0.fifo"; fi
          fi
          exec \(quote(git.path)) "$@" < "$0.packet"
        fi
        exec \(quote(git.path)) "$@"
        """
        try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let suite="TurtleGit.SavedResolve."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"TurtleGitMerge.AutoAdd");prefs.set(false,forKey:"TurtleGitMerge.Backup");prefs.set(false,forKey:"UseLibgit2");prefs.set(p4,forKey:"TurtleGit.Comparison.CurvedInterface")
        let provider=SavedResolveBookmarks(),permissions=(narrow ? inputs+[target]:[inputFolder,root]).map{RepositoryAccessLease(url:$0,provider:provider)}
        let repository=GitRepository(root:kind=="rebound" ? root:inputFolder,executable:helper,libgit2Configuration:.init(enabled:false))
        let working:WorkingTextMerge?=kind=="rebound" ? nil:try WorkingTextMerge(base:inputs[0],theirs:inputs[1],mine:inputs[2],merged:target,allowMissingInputs:true)
        let owner=TextConflictWindowController(repository:repository,access:nil,path:path,workingMerge:working,permissions:permissions,preferences:prefs,deferInitialLoad:true)
        owner.model.regexDefaults=prefs;owner.model.commentProfileURL=folder.appendingPathComponent("private-comments.txt");owner.model.newOutputAdd.executable={helper};owner.model.newOutputAdd.requiresScope=false
        do {
            if working != nil{guard let invocation=try MergeToolInvocation.parse(arguments:["--base",inputs[0].path,"--theirs",inputs[1].path,"--mine",inputs[2].path,"--merged",target.path]+(readOnly ? ["--readonly"]:[]),currentDirectory:inputFolder.path)else{throw Failure(description:"Actual saved-output invocation missing")};try owner.model.configureMergeTool(invocation)}
            owner.showWindow(nil);owner.model.beginTransferredDocument()
            try await wait("actual standalone/rebound result ready"){!owner.model.busy && owner.model.document != nil && (readOnly || owner.model.nativeEditorReady)}
            try require(owner.model.error==nil,"Actual saved-result load failed: "+(owner.model.error ?? "none"))
            print("Saved Resolve phase=\(folder.lastPathComponent) initialEncoding=\(owner.model.encoding.rawValue) p4=\(p4)");fflush(stdout)
            // ASCII-only inputs legitimately detect the selected legacy code page.
            // Choose the real result Format action before adding Unicode payload.
            if !readOnly {
                owner.model.changeEncoding(.utf8)
                try await wait("explicit UTF-8 result format accepted"){owner.model.encoding == .utf8 && !owner.model.formatPending}
                try require(owner.model.error==nil,"Explicit UTF-8 result format failed: "+(owner.model.error ?? "none"))
            }
            let menu=NSMenu(title:"Private saved Resolve")
            for title in ["Fixture","File","Edit"]{let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.submenu=NSMenu(title:title);menu.addItem(item)}
            NSApp.mainMenu=menu;guard let router=owner.editorCommandMenu else{throw Failure(description:"Saved Resolve command router missing")};router.keyWindow={ [weak owner] in owner?.window};router.install(in:menu)
            let c=Case(folder:folder,root:root,metadataRoot:linked ? mainRoot:nil,inputs:inputs,real:real,owner:owner,suite:suite,prefs:prefs,menu:menu,helper:helper,path:path,target:target,peer:try await real.run(["ls-files","--stage","-z","--","peer.txt"]).stdout,peerWorking:try Data(contentsOf:root.appendingPathComponent("peer.txt")),head:try await real.rebaseCommit("HEAD").hash)
            owner.model.onResolvedOutput={ [weak c] root,path in c?.resolved.append((root,path))}
            return c
        }catch{owner.close();try? await wait("failed saved Resolve owner drain"){!owner.model.mergeToolHasPendingWork};prefs.removePersistentDomain(forName:suite);throw error}
    }
    static func menuMark(_ c:Case)async throws {
        do {
            try await wait("native bottom-view Mark enabled") {c.owner.editorCommandMenu?.install(in:c.menu);return items(c.menu).first{$0.title=="Mark as resolved"}?.isEnabled==true}
        } catch {
            let item=items(c.menu).first{$0.title=="Mark as resolved"}
            let ownerGate=c.owner.editorCommandMenu?.keyWindow() === c.owner.window
            throw Failure(description:"Native Mark admission phase=\(c.folder.lastPathComponent), repositoryResolutionAllowed=\(c.model.repositoryResolutionAllowed), sourceToolsAllowed=\(c.model.sourceToolsAllowed), sourceMutationsAllowed=\(c.model.sourceMutationsAllowed), nativeEditorReady=\(c.model.nativeEditorReady), busy=\(c.model.busy), preparing=\(c.model.preparing), formatPending=\(c.model.formatPending), retired=\(c.model.retired), confirmingQuit=\(c.model.confirmingQuit), error=\(String(reflecting:c.model.error)), sheet=\(c.owner.window?.attachedSheet != nil), modal=\(NSApp.modalWindow != nil), item=\(String(reflecting:item?.title)), enabled=\(String(reflecting:item?.isEnabled)), ownerGate=\(ownerGate), applicationMenuMatches=\(NSApp.mainMenu === c.menu)")
        }
        guard let item=items(c.menu).first(where:{$0.title=="Mark as resolved"}),let action=item.action else{throw Failure(description:"Actual Mark command unavailable")}
        try require(NSApp.sendAction(action,to:item.target,from:item),"Native saved-result Mark action refused")
    }
    static func closedResolved(_ c:Case)async throws {
        try await wait("saved result actually resolved and owner closed"){!c.model.busy && !c.model.mergeToolHasPendingWork && c.owner.window?.isVisible != true}
        try require(c.model.error==nil && c.model.pendingResolve==nil && c.resolved.count==1,"Successful saved Resolve failed to acknowledge exact owner target")
        let relative=String(c.target.path.dropFirst(c.root.path.count+1))
        let actualRoot=c.resolved[0].0.standardizedFileURL.resolvingSymlinksInPath(),expectedRoot=c.root.standardizedFileURL.resolvingSymlinksInPath()
        try require(GitReferenceName.equal(actualRoot.path,expectedRoot.path) && GitReferenceName.equal(c.resolved[0].1,relative),"Resolve callback identified input repository or wrong target: actualURL=\(c.resolved[0].0.absoluteString), expectedURL=\(c.root.absoluteString), actualCanonicalPath=\(actualRoot.path), expectedCanonicalPath=\(expectedRoot.path), actualRelative=\(String(reflecting:c.resolved[0].1)), expectedRelative=\(String(reflecting:relative))")
        try await c.peersPreserved()
    }
    static func save(_ c:Case,mark:Bool=false,copy:Bool=false)async throws->Bool {
        var result:Bool?;c.model.save(markResolved:mark,chooseNewOutput:copy){result=$0}
        try await wait("saved result operation completes"){result != nil && !c.model.busy && !c.model.mergeToolHasPendingWork};return result!
    }
    static func basicTargets(_ folder:URL,git:URL)async throws {
        for (kind,p4) in [("tracked",false),("tracked",true),("unmerged",false),("new",false),("deleted",false),("legacy",false)] {
            let c=try await make(folder.appendingPathComponent(kind+(p4 ? "-p4":"")),git:git,kind:kind,p4:p4)
            do {
                if kind=="legacy" {
                    c.model.changeEncoding(.windows1252)
                    try await wait("explicit legacy result format accepted"){c.model.encoding == .windows1252 && !c.model.formatPending}
                    c.model.result="résolu\n"
                } else if kind=="deleted"{c.model.result="";c.model.chooseEmptyResult={_ in .delete}}else{c.model.result="resolved standalone target 🐢\n"}
                let expected=try c.model.encoding.encode(c.model.result)
                if p4 {
                    let beforeIndex=try await c.real.run(["ls-files","--stage","-z"]).stdout
                    try await wait("actual P4 Save menu enabled"){c.owner.editorCommandMenu?.install(in:c.menu);return items(c.menu).first{$0.title=="Save"}?.isEnabled==true}
                    guard let saveItem=items(c.menu).first(where:{$0.title=="Save"}),let action=saveItem.action else{throw Failure(description:"Actual P4 Save menu missing")}
                    try require(NSApp.sendAction(action,to:saveItem.target,from:saveItem),"Actual P4 Save action refused")
                    try await wait("actual P4 Save completed"){!c.model.busy && !c.model.mergeToolHasPendingWork && !c.model.dirty}
                    let afterIndex=try await c.real.run(["ls-files","--stage","-z"]).stdout
                    try require(c.model.error==nil && (try Data(contentsOf:c.target))==expected && afterIndex==beforeIndex,"P4 Save failed or unexpectedly resolved/staged output")
                    c.owner.editorCommandMenu?.install(in:c.menu)
                    try require(items(c.menu).first{$0.title=="Save As…"}?.isEnabled==true,"P4 Save As unavailable when toolbar intentionally absent")
                }
                try await menuMark(c);try await closedResolved(c)
                let staged=try await c.real.run(["ls-files","--stage","-z","--",c.path]).stdout
                if kind=="deleted"{try require(staged.isEmpty && !FileManager.default.fileExists(atPath:c.target.path),"Deleted saved target was not resolved as deletion")}
                else{let bytes=try await c.real.run(["show",":"+c.path]).stdout;try require(!staged.isEmpty && bytes==expected && (try Data(contentsOf:c.target))==expected,"Saved existing/new/unmerged/legacy target was not literally staged with its chosen encoding")
                    if kind=="legacy"{try require(expected==Data([0x72,0xe9,0x73,0x6f,0x6c,0x75,0x0a]),"Legacy output matrix did not exercise exact Windows-1252 bytes")}}
                try require((try Data(contentsOf:URL(fileURLWithPath:c.helper.path+".packet")))==Data(Array(c.path.utf8)+[0]),"Saved Resolve staged incorrect literal target scope")
                try await c.close()
            }catch{try? await c.close();throw error}
        }
    }
    static func rebound(_ folder:URL,git:URL,readOnly:Bool=false)async throws {
        let c=try await make(folder,git:git,kind:"rebound")
        do {
            let original=c.target,originalBytes=try Data(contentsOf:original)
            let originalStage=try await c.real.run(["ls-files","--stage","-z","--",c.path]).stdout
            let target=c.root.appendingPathComponent("results/rebound 雪\t[*].txt")
            c.model.chooseStandaloneOutput={_,_ in target};c.model.result="resolved chosen result\n"
            if readOnly {
                try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:original.path)
                try await menuMark(c);c.target=target
            } else {
                let saved=try await save(c,copy:true)
                try require(saved && c.model.mergedResultTarget?.url==target,"Actual repository result Save As did not bind chosen target")
                c.target=target;try await menuMark(c)
            }
            try await closedResolved(c)
            let originalNow=try await c.real.run(["ls-files","--stage","-z","--",c.path]).stdout
            let staged=try await c.real.run(["show",":results/rebound 雪\t[*].txt"]).stdout
            try require(originalNow==originalStage && (try Data(contentsOf:original))==originalBytes && staged==Data("resolved chosen result\n".utf8),"Rebound Resolve wrote/staged original conflict instead of saved copy")
            try await c.close()
        }catch{try? await c.close();throw error}
    }
    static func trace(_ c:Case)->Data{(try? Data(contentsOf:URL(fileURLWithPath:c.helper.path+".trace"))) ?? Data()}
    static func inode(_ file:URL)throws->NSNumber?{try FileManager.default.attributesOfItem(atPath:file.path)[.systemFileNumber] as? NSNumber}
    static func authority(_ folder:URL,git:URL,linked:Bool)async throws {
        let c=try await make(folder,git:git,narrow:true,linked:linked)
        do {
            let provider=SavedResolveBookmarks()
            c.model.saveFolderAccess.requireScope=true;c.model.saveFolderAccess.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
            c.model.saveFolderAccess.chooseFolder={_,_ in c.target.deletingLastPathComponent()}
            c.model.newOutputAdd.requiresScope=true;c.model.newOutputAdd.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
            var asks=[URL]()
            c.model.newOutputAdd.chooseRepository={_,suggested in asks.append(suggested);return linked && asks.count==1 ? c.root:nil}
            c.model.result="saved before root authority\n"
            let before=trace(c),index=try await c.real.run(["ls-files","--stage","-z"]).stdout
            let accepted=try await save(c,mark:true)
            let after=try await c.real.run(["ls-files","--stage","-z"]).stdout
            try require(!accepted && c.model.pendingResolve != nil && !c.model.dirty && after==index && trace(c)==before,"Narrow output grant authorized Git/index before exact root and metadata permission")
            try require(asks.count==(linked ? 2:1),"Root/linked metadata request sequence did not stop at denied grant")
            let bytes=try Data(contentsOf:c.target),savedInode=try inode(c.target),previousCount=asks.count
            try await c.clear()
            c.model.newOutputAdd.chooseRepository={_,suggested in asks.append(suggested);return c.metadataRoot ?? c.root}
            c.model.retrySavedResolve();try await closedResolved(c)
            try require((try Data(contentsOf:c.target))==bytes && (try inode(c.target))==savedInode,"Root permission retry rewrote successfully saved output")
            if linked {
                try require(asks.count>previousCount && asks.dropFirst(previousCount).allSatisfy{$0.standardizedFileURL != c.root.standardizedFileURL},"Linked metadata retry lost retained root grant")
            }
            let staged=try await c.real.run(["show",":"+c.path]).stdout
            try require(staged==bytes,"Scoped Resolve did not stage exact saved target in selected repository")
            try await c.close()
        }catch{try? await c.close();throw error}
    }
    static func warning(_ c:Case)async throws->NSWindow {
        try await wait("actual saved-output warning sheet"){c.owner.window?.attachedSheet != nil}
        guard let sheet=c.owner.window?.attachedSheet else{throw Failure(description:"Saved-output warning missing")}
        let buttons=views(sheet.contentView).compactMap{$0 as? NSButton}
        let control=sheet.defaultButtonCell?.controlView as? NSButton
        try require(control?.title=="Continue Resolving" && buttons.first{$0.title=="Save Anyway"}?.keyEquivalent != "\r" && buttons.first{$0.title=="Cancel"}?.keyEquivalent=="\u{1b}","Saved-output warning changed default/Escape contract")
        return sheet
    }
    static func press(_ sheet:NSWindow,_ title:String)throws {
        guard let button=views(sheet.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else{throw Failure(description:"Actual warning choice missing: "+title)}
        button.performClick(nil)
    }
    static func recovery(_ folder:URL,git:URL,cancel:Bool=false,external:Bool=false)async throws {
        let c=try await make(folder,git:git)
        do {
            let mode=URL(fileURLWithPath:c.helper.path+".mode"),entered=URL(fileURLWithPath:c.helper.path+".entered")
            try (cancel ? "hold\n":"fail\n").write(to:mode,atomically:true,encoding:.utf8)
            c.model.result=cancel ? "saved before stage cancellation\n":"<<<<<<< mine\nunresolved chosen output\n=======\nother\n>>>>>>> theirs\n"
            let expected=try c.model.encoding.encode(c.model.result)
            let index=try await c.real.run(["ls-files","--stage","-z"]).stdout
            try await menuMark(c)
            if !cancel{let sheet=try await warning(c);try press(sheet,"Save Anyway")}
            try await wait("actual Resolve add entered"){FileManager.default.fileExists(atPath:entered.path)}
            if cancel{try require(c.model.busy,"Resolve worker cancellation lost owner");c.model.cancelSaveOperation()}
            try await wait("failed/canceled Resolve retained saved baseline"){!c.model.busy && !c.model.mergeToolHasPendingWork && c.model.pendingResolve != nil}
            let after=try await c.real.run(["ls-files","--stage","-z"]).stdout
            try require(!c.model.dirty && c.model.error != nil && after==index && (try Data(contentsOf:c.target))==expected,"Resolve failure/cancel lost saved baseline or modified index")
            if let text=try? String(contentsOf:entered,encoding:.utf8),let pid=Int32(text.trimmingCharacters(in:.whitespacesAndNewlines)){try require(kill(pid,0) != 0,"Owned held Resolve worker remained alive after drain")}
            let savedInode=try inode(c.target)
            try await c.clear();try "pass\n".write(to:mode,atomically:true,encoding:.utf8)
            try FileManager.default.removeItem(at:entered)
            if external {
                let externalBytes=Data("external replacement must survive\n".utf8);try externalBytes.write(to:c.target,options:.atomic)
                c.model.chooseUnresolvedSave={_ in .saveAnyway}
                var completed:Bool?;c.model.retrySavedResolve{completed=$0}
                try await wait("changed saved receipt refused"){completed != nil && !c.model.busy && !c.model.mergeToolHasPendingWork}
                let unchanged=try await c.real.run(["ls-files","--stage","-z"]).stdout
                try require(completed==false && c.model.pendingResolve != nil && c.model.error != nil && unchanged==index && (try Data(contentsOf:c.target))==externalBytes && !FileManager.default.fileExists(atPath:entered.path),"Stale saved-output receipt overwrote external bytes or staged them")
                try await c.close();return
            }
            if !cancel {
                var questions=0,completion:Bool?;c.model.chooseUnresolvedSave={_ in questions += 1;return .cancel}
                c.model.retrySavedResolve{completion=$0}
                try await wait("fresh retry warning declines"){completion != nil && !c.model.busy}
                try require(questions==1 && completion==false && c.model.pendingResolve != nil && !FileManager.default.fileExists(atPath:entered.path) && (try inode(c.target))==savedInode,"Saved Resolve leaked prior approval or rewrote on negative retry")
                try await c.clear();c.model.chooseUnresolvedSave=nil
            }
            // The actual menu on an unchanged pending target routes no-rewrite Retry.
            try await menuMark(c)
            if !cancel{let sheet=try await warning(c);try press(sheet,"Save Anyway")}
            try await closedResolved(c)
            try require((try inode(c.target))==savedInode && (try Data(contentsOf:c.target))==expected,"Resolve retry duplicated successful disk write")
            let staged=try await c.real.run(["show",":"+c.path]).stdout
            try require(staged==expected,"Saved Resolve retry staged incorrect bytes")
            try await c.close()
        }catch{try? await c.close();throw error}
    }
    static func readOnly(_ folder:URL,git:URL)async throws {
        let c=try await make(folder,git:git,readOnly:true)
        do {
            let before=try await c.real.run(["ls-files","--stage","-z"]).stdout,bytes=try Data(contentsOf:c.target)
            c.owner.editorCommandMenu?.install(in:c.menu)
            try require(c.model.mergeToolReadOnly && !c.model.repositoryResolutionAllowed && items(c.menu).first{$0.title=="Mark as resolved"}?.isEnabled != true,"Read-only three-pane result exposes Resolve")
            if let item=items(c.menu).first(where:{$0.title=="Mark as resolved"}),let action=item.action{_=NSApp.sendAction(action,to:item.target,from:item)}
            let after=try await c.real.run(["ls-files","--stage","-z"]).stdout
            try require(after==before && (try Data(contentsOf:c.target))==bytes && c.model.pendingResolve==nil && !c.model.busy,"Disabled read-only native action wrote/staged result")
            try await c.close()
        }catch{try? await c.close();throw error}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let oldMenu=NSApp.mainMenu
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.savedResolveOrder(_:relativeTo:)))!
        let begin=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,hiddenBegin=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.savedResolveSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,hidden);method_exchangeImplementations(begin,hiddenBegin)
        defer{method_exchangeImplementations(order,hidden);method_exchangeImplementations(begin,hiddenBegin);NSApp.mainMenu=oldMenu}
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        if CommandLine.arguments.dropFirst(3).contains("read-only") {
            try await readOnly(folder.appendingPathComponent("read-only"),git:git)
            print("PASS: saved three-pane Resolve read-only native invocation/menu and unchanged target/index");return
        }
        try await basicTargets(folder.appendingPathComponent("targets"),git:git)
        try await rebound(folder.appendingPathComponent("rebound"),git:git)
        try await rebound(folder.appendingPathComponent("readonly-saveas"),git:git,readOnly:true)
        try await authority(folder.appendingPathComponent("root-permission"),git:git,linked:false)
        try await authority(folder.appendingPathComponent("linked-permission"),git:git,linked:true)
        try await recovery(folder.appendingPathComponent("stage-failure"),git:git)
        try await recovery(folder.appendingPathComponent("stage-cancel"),git:git,cancel:true)
        try await recovery(folder.appendingPathComponent("changed-output"),git:git,external:true)
        try await readOnly(folder.appendingPathComponent("read-only"),git:git)
        print("PASS: saved three-pane Resolve native menus/warnings, selected output scopes, literal staging, grants, failed/canceled stage and no-rewrite retry")
    }
}
