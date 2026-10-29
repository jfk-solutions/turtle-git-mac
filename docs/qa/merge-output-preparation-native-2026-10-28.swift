// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func mergeOutputOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));mergeOutputOrder(mode,relativeTo:number)}
}
private final class PreparedReloadGate:@unchecked Sendable {
    private let lock=NSLock()
    private var reply:CheckedContinuation<Void,Never>?,started=false,main=false
    var entered:Bool{lock.lock();defer{lock.unlock()};return started}
    var onMain:Bool{lock.lock();defer{lock.unlock()};return main}
    func observeExecutor(){lock.lock();main = main || Thread.isMainThread;lock.unlock()}
    func hold()async {await withCheckedContinuation{value in lock.lock();reply=value;started=true;main = main || Thread.isMainThread;lock.unlock()}}
    func release(){lock.lock();let value=reply;reply=nil;lock.unlock();value?.resume()}
}
private final class MergeOutputBookmarks:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data{Data(url.path.utf8)}
    func resolve(_ bytes:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool{true}
    func stopAccessing(_ url:URL){}
}
@MainActor @main enum MergeOutputPreparationVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Merge output/preparation timeout: "+message)}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    @MainActor final class Case {
        let root:URL,git:URL,repo:GitRepository,owner:TextConflictWindowController,output:URL,inputs:[URL],suite:String,prefs:UserDefaults,baselineIndex:Data
        var model:TextConflictWindowModel{owner.model}
        init(root:URL,git:URL,repo:GitRepository,owner:TextConflictWindowController,output:URL,inputs:[URL],suite:String,prefs:UserDefaults,index:Data){self.root=root;self.git=git;self.repo=repo;self.owner=owner;self.output=output;self.inputs=inputs;self.suite=suite;self.prefs=prefs;baselineIndex=index}
        func close()async throws{owner.close();try await wait("owned Merge readers drain"){!model.mergeToolHasPendingWork && model.reloadPreparationPending==0 && MergeRegexOperations.activeRequests==0 && MergeSourceExport.activeExports==0};prefs.removePersistentDomain(forName:suite)}
    }
    static func make(_ directory:URL,git:URL,autoAdd:Bool,existing:Bool=false,wrapped:Bool=false,leafGrants:Bool=false)async throws->Case {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let real=GitRepository(root:directory,executable:git,libgit2Configuration:.init(enabled:false))
        _=try await real.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Merge output QA"),("user.email","merge-output@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await real.run(["config",key,value])}
        let inputs=["base.txt","theirs.txt","mine.txt"].map{directory.appendingPathComponent($0)}
        for file in inputs{try Data("baseline\n".utf8).write(to:file)}
        let output=directory.appendingPathComponent(existing ? "existing.txt":"new folder 雪/deeper/result [x]\t.txt")
        if existing{try Data("baseline\n".utf8).write(to:output)}
        try await real.stage(inputs.map(\.lastPathComponent)+(existing ? [output.lastPathComponent]:[]));_=try await real.commit(message:"private source baseline")
        let index=try Data(contentsOf:directory.appendingPathComponent(".git/index")),helper=directory.appendingPathComponent("add-helper")
        if wrapped {
            let fifo=URL(fileURLWithPath:helper.path+".fifo");guard mkfifo(fifo.path,mode_t(0o600))==0 else{throw Failure(description:"Private Add FIFO unavailable")}
            let script="""
            #!/bin/sh
            task_add=false
            for task_arg in "$@"; do if [ "$task_arg" = add ]; then task_add=true; fi; done
            if [ "$task_add" = true ] && [ -f "$0.mode" ]; then
              /bin/cat > "$0.packet"
              printf '%s\\n' "$$" > "$0.entered"
              IFS= read -r task_mode < "$0.mode"
              if [ "$task_mode" = fail ]; then printf '%s\\n' 'Controlled private Add failure' >&2; exit 17; fi
              if [ "$task_mode" = hold ]; then IFS= read -r task_release < "$0.fifo"; fi
              exec \(quote(git.path)) "$@" < "$0.packet"
            fi
            exec \(quote(git.path)) "$@"
            """
            try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        }
        try Data("unrelated untracked bytes\n".utf8).write(to:directory.appendingPathComponent("unrelated [keep].txt"))
        let repo=GitRepository(root:directory,executable:wrapped ? helper:git,libgit2Configuration:.init(enabled:false))
        let suite="TurtleGit.MergeOutput."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(autoAdd,forKey:"TurtleGitMerge.AutoAdd");prefs.set(false,forKey:"TurtleGitMerge.Backup");prefs.set(false,forKey:"UseLibgit2")
        let provider=MergeOutputBookmarks(),permissions=(leafGrants ? inputs:[directory]).map{RepositoryAccessLease(url:$0,provider:provider)}
        let merge=try WorkingTextMerge(base:inputs[0],theirs:inputs[1],mine:inputs[2],merged:output,allowMissingInputs:true)
        let owner=TextConflictWindowController(repository:repo,access:nil,path:output.lastPathComponent,workingMerge:merge,permissions:permissions,preferences:prefs,deferInitialLoad:true)
        owner.model.regexDefaults=prefs;owner.model.commentProfileURL=directory.appendingPathComponent("private-comments.txt")
        owner.model.newOutputAdd.executable={wrapped ? helper:git}
        owner.model.newOutputAdd.requiresScope=false
        do {
        guard let invocation=try MergeToolInvocation.parse(arguments:["--base",inputs[0].path,"--theirs",inputs[1].path,"--mine",inputs[2].path,"--merged",output.path],currentDirectory:directory.path)else{throw Failure(description:"Actual three-file invocation missing")}
        try owner.model.configureMergeTool(invocation)
        owner.showWindow(nil);owner.model.beginTransferredDocument()
        try await wait("actual Merge document ready"){!owner.model.busy && !owner.model.preparing && owner.model.document != nil && owner.model.nativeEditorReady && owner.model.reloadPreparationPending==0}
        try require(owner.model.error==nil,"Initial native document failed")
        return Case(root:directory,git:git,repo:repo,owner:owner,output:output,inputs:inputs,suite:suite,prefs:prefs,index:index)
        }catch{owner.close();try? await wait("failed initial Merge owner drain"){!owner.model.mergeToolHasPendingWork && owner.model.reloadPreparationPending==0};prefs.removePersistentDomain(forName:suite);throw error}
    }
    static func save(_ value:Case,saveAs:Bool=false)async throws->Bool {
        var result:Bool?;value.model.save(markResolved:false,chooseNewOutput:saveAs){result=$0}
        try await wait("actual native save/Add completion"){result != nil && !value.model.mergeToolHasPendingWork}
        return result!
    }
    static func tracked(_ value:Case,_ file:URL)async throws->Bool{!(try await value.repo.run(["ls-files","--error-unmatch","--",file.path],successfulExitCodes:0...1)).stdout.isEmpty}
    static func preparation(_ folder:URL,git:URL)async throws {
        let c=try await make(folder,git:git,autoAdd:true,existing:true),gate=PreparedReloadGate()
        defer{gate.release()}
        do {
            let copy=folder.appendingPathComponent("kept-mine.txt")
            c.model.sourceExporter.selectedURL={_ in copy};c.model.sourceExporter.present={_,_,reply in reply(.OK)}
            c.model.exportSource(mine:true)
            try await wait("actual bound source Save As"){!c.model.exportingSource && c.model.sourceTargetURL(mine:true)==copy}
            let oldMine=c.model.document!.mine,oldResult=c.model.result,oldTarget=c.model.sourceTargets[true]!.content.bytes
            try Data("external source café\n".utf8).write(to:copy)
            c.model.prepareReload={work in gate.observeExecutor();let prepared=try await work();await gate.hold();return prepared}
            c.model.load()
            try await wait("saved-source actual prepared result held"){gate.entered && c.model.reloadPreparationPending>0}
            try require(!gate.onMain && c.model.busy && c.model.preparing,"Saved-source preparation executed inline or lost ownership")
            var heartbeat=false;DispatchQueue.main.async{heartbeat=true};try await wait("MainActor heartbeat during held preparation"){heartbeat}
            try require(c.model.document?.mine==oldMine && c.model.result==oldResult && c.model.sourceTargets[true]?.content.bytes==oldTarget,"Unaccepted prepared candidate changed native source/result/target")
            c.owner.close()
            try require(c.model.reloadPreparationPending>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Close/Quit abandoned held prepared worker")
            gate.release();try await wait("retired actual preparation drained"){c.model.reloadPreparationPending==0 && !c.model.mergeToolHasPendingWork && MergeRegexOperations.activeRequests==0}
            try require(c.model.document?.mine==oldMine && c.model.result==oldResult && c.model.sourceTargets[true]?.content.bytes==oldTarget,"Late prepared document adopted after owner retirement")
            try require((try Data(contentsOf:folder.appendingPathComponent(".git/index")))==c.baselineIndex,"Source Save As/preparation changed Git index")
            try await c.close()
        }catch{gate.release();try? await c.close();throw error}
    }
    static func addFailureAndCancellation(_ folder:URL,git:URL)async throws {
        for cancel in [false,true] {
            let c=try await make(folder.appendingPathComponent(cancel ? "canceled-add":"failed-add"),git:git,autoAdd:true,wrapped:true)
            do {
                let helper=c.root.appendingPathComponent("add-helper"),mode=URL(fileURLWithPath:helper.path+".mode"),packet=URL(fileURLWithPath:helper.path+".packet"),entered=URL(fileURLWithPath:helper.path+".entered")
                try (cancel ? "hold\n":"fail\n").write(to:mode,atomically:true,encoding:.utf8)
                c.model.result="saved before Add \(cancel)\n"
                var completed:Bool?
                c.model.save(markResolved:false,closeAfter:true){completed=$0}
                try await wait("actual Add worker after successful write"){FileManager.default.fileExists(atPath:entered.path)}
                let pid=Int32(try String(contentsOf:entered).trimmingCharacters(in:.whitespacesAndNewlines))
                if cancel {
                    try require(c.model.busy && c.model.pendingNewOutput != nil && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held Add lost saved receipt or Quit ownership")
                    c.model.cancelSaveOperation()
                }
                try await wait("failed/canceled Add real worker drain"){completed != nil && !c.model.busy && !c.model.mergeToolHasPendingWork}
                try require(completed==false && c.model.pendingNewOutput != nil && !c.model.dirty && c.owner.window?.isVisible==true,"Add failure/cancel lost saved baseline/receipt or closed owner")
                let bytes=try Data(contentsOf:c.output),attributes=try FileManager.default.attributesOfItem(atPath:c.output.path),inode=attributes[.systemFileNumber] as? NSNumber
                let trackedAfterFailure=try await tracked(c,c.output)
                try require(bytes==Data("saved before Add \(cancel)\n".utf8) && !trackedAfterFailure,"Failed Add lost saved bytes or staged output")
                let relative=String(c.output.path.dropFirst(c.root.path.count+1)),expected=Data(Array(relative.utf8)+[0])
                try require((try Data(contentsOf:packet))==expected,"Git Add did not use the exact literal selected output packet")
                if let pid{try require(kill(pid,0) != 0,"Failed/canceled Add helper survived completion")}
                c.model.error=nil;try await wait("Add failure diagnostic sheet retired"){c.owner.window?.attachedSheet==nil}
                try "pass\n".write(to:mode,atomically:true,encoding:.utf8)
                c.model.retryNewOutputAdd()
                try await wait("explicit Retry Add completion"){!c.model.busy && c.model.pendingNewOutput==nil}
                let trackedAfterRetry=try await tracked(c,c.output)
                try require(c.model.error==nil && trackedAfterRetry,"Explicit Add retry did not stage saved output")
                try require((try Data(contentsOf:packet))==expected && (try Data(contentsOf:c.output))==bytes && (try FileManager.default.attributesOfItem(atPath:c.output.path)[.systemFileNumber] as? NSNumber)==inode,"Retry Add rewrote saved file or changed literal staging scope")
                try await c.close()
            }catch{try? await c.close();throw error}
        }
        let resaved=try await make(folder.appendingPathComponent("ordinary-resave"),git:git,autoAdd:true,wrapped:true)
        do {
            let mode=resaved.root.appendingPathComponent("add-helper.mode")
            try "fail\n".write(to:mode,atomically:true,encoding:.utf8);resaved.model.result="first saved draft\n"
            try require(!(try await save(resaved)) && resaved.model.pendingNewOutput != nil,"Initial new-output intent not retained")
            let old=resaved.model.pendingNewOutput!
            resaved.model.error=nil;try await wait("resave initial Add diagnostic retired"){resaved.owner.window?.attachedSheet==nil}
            resaved.model.result="updated ordinary resave\n"
            try require(!(try await save(resaved)) && resaved.model.pendingNewOutput != nil && !resaved.model.dirty,"Ordinary resave lost pending initial-new Add intent")
            do{try old.validate();throw Failure(description:"Old saved receipt accepted rewritten own output")}catch is FileComparisonEditFailure{}
            try resaved.model.pendingNewOutput!.validate()
            resaved.model.error=nil;try await wait("resave Add diagnostic retired"){resaved.owner.window?.attachedSheet==nil}
            try "pass\n".write(to:mode,atomically:true,encoding:.utf8);resaved.model.retryNewOutputAdd()
            try await wait("resaved output Add retry settled"){!resaved.model.busy && resaved.model.pendingNewOutput==nil}
            let trackedResaved=try await tracked(resaved,resaved.output)
            try require(resaved.model.error==nil && trackedResaved && (try Data(contentsOf:resaved.output))==Data("updated ordinary resave\n".utf8),"Retry Add did not use current own-resave receipt")
            try await resaved.close()
        }catch{try? await resaved.close();throw error}
        let changed=try await make(folder.appendingPathComponent("changed-saved-output"),git:git,autoAdd:true,wrapped:true)
        do {
            let mode=changed.root.appendingPathComponent("add-helper.mode")
            try "fail\n".write(to:mode,atomically:true,encoding:.utf8);changed.model.result="original saved receipt\n"
            try require(!(try await save(changed)) && changed.model.pendingNewOutput != nil,"Controlled first Add did not retain receipt")
            changed.model.error=nil;try await wait("changed-output initial diagnostic retired"){changed.owner.window?.attachedSheet==nil}
            try Data("external replacement\n".utf8).write(to:changed.output,options:.atomic)
            try "pass\n".write(to:mode,atomically:true,encoding:.utf8);changed.model.retryNewOutputAdd()
            try await wait("changed saved-output retry refused"){!changed.model.busy && changed.model.error != nil}
            let trackedChanged=try await tracked(changed,changed.output)
            try require(changed.model.pendingNewOutput != nil && !trackedChanged && (try Data(contentsOf:changed.output))==Data("external replacement\n".utf8),"Stale Add receipt staged/replaced externally changed output")
            changed.model.error=nil;try await wait("changed output diagnostic retired"){changed.owner.window?.attachedSheet==nil};try await changed.close()
        }catch{try? await changed.close();throw error}
    }
    static func pendingIntentDisposition(_ folder:URL,git:URL)async throws {
        for rebind in [false,true] {
            let c=try await make(folder.appendingPathComponent(rebind ? "result-save-as":"preference-off"),git:git,autoAdd:true,wrapped:true)
            do {
                try "fail\n".write(to:c.root.appendingPathComponent("add-helper.mode"),atomically:true,encoding:.utf8)
                c.model.result="original pending saved bytes\n"
                let initialSaved=try await save(c)
                try require(!initialSaved && c.model.pendingNewOutput != nil,"Initial new output Add intent missing")
                c.model.error=nil;try await wait("pending-intent diagnostic retired"){c.owner.window?.attachedSheet==nil}
                let target:URL
                if rebind {
                    target=c.root.appendingPathComponent("rebound-result.txt")
                    c.model.chooseStandaloneOutput={_,_ in target}
                }else{
                    target=c.output;c.prefs.set(false,forKey:"TurtleGitMerge.AutoAdd")
                    NotificationCenter.default.post(name:.mergeEditorPreferencesChanged,object:nil)
                    try await wait("actual private AutoAdd setting consumer"){!c.model.editorPreferences.autoAdd}
                }
                c.model.result="successful pending disposition\n"
                let saved=try await save(c,saveAs:rebind),targetTracked=try await tracked(c,target),originalTracked=try await tracked(c,c.output)
                try require(saved && c.model.error==nil && c.model.pendingNewOutput==nil && !targetTracked && !originalTracked,"Preference-off resave or result rebind retained/staged old new-output intent")
                try require((try Data(contentsOf:target))==Data("successful pending disposition\n".utf8) && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==c.baselineIndex,"Pending intent disposition lost successful bytes or changed index")
                if rebind{try require((try Data(contentsOf:c.output))==Data("original pending saved bytes\n".utf8),"Result Save As overwrote prior saved output")}
                try await c.close()
            }catch{try? await c.close();throw error}
        }
    }
    static func ancestorGrant(_ folder:URL,git:URL)async throws {
        let c=try await make(folder,git:git,autoAdd:false,leafGrants:true)
        do {
            let provider=MergeOutputBookmarks();var asks=0;var hints=[URL]()
            c.model.saveFolderAccess.requireScope=true;c.model.saveFolderAccess.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
            c.model.saveFolderAccess.chooseFolder={_,suggested in asks += 1;hints.append(suggested);return nil}
            c.model.result="ancestor-authorized result\n"
            try require(!(try await save(c)) && asks==1 && hints.first?.path==c.root.path && !FileManager.default.fileExists(atPath:c.output.deletingLastPathComponent().path),"Missing-parent save did not suggest existing ancestor, or canceled grant created output")
            c.model.saveFolderAccess.chooseFolder={_,_ in asks += 1;return c.root}
            try require(try await save(c),"Existing ancestor grant did not authorize missing descendant output")
            let trackedAncestorOutput=try await tracked(c,c.output)
            try require(asks==2 && (try Data(contentsOf:c.output))==Data("ancestor-authorized result\n".utf8) && !trackedAncestorOutput,"Ancestor grant/save corrupted path or ignored AutoAdd disabled")
            try await c.close()
        }catch{try? await c.close();throw error}
    }
    static func repositoryAddGrant(_ folder:URL,git:URL)async throws {
        let c=try await make(folder,git:git,autoAdd:true,leafGrants:true)
        do {
            let provider=MergeOutputBookmarks(),narrow=c.root.appendingPathComponent("new folder 雪",isDirectory:true)
            try FileManager.default.createDirectory(at:narrow,withIntermediateDirectories:false)
            c.model.saveFolderAccess.requireScope=true;c.model.saveFolderAccess.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
            c.model.saveFolderAccess.chooseFolder={_,_ in narrow}
            c.model.newOutputAdd.requiresScope=true;c.model.newOutputAdd.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
            var choices=0
            c.model.newOutputAdd.chooseRepository={_,_ in choices += 1;return nil}
            c.model.result="saved with narrow folder authority\n"
            try require(!(try await save(c)) && c.model.pendingNewOutput != nil && !c.model.dirty && choices==1,"Canceled Git-root grant lost separate successful save")
            try require(!(try await tracked(c,c.output)),"Narrow output-folder grant authorized Git index update")
            let bytes=try Data(contentsOf:c.output),inode=try FileManager.default.attributesOfItem(atPath:c.output.path)[.systemFileNumber] as? NSNumber
            c.model.error=nil;try await wait("repository grant cancellation diagnostic retired"){c.owner.window?.attachedSheet==nil}
            c.model.newOutputAdd.chooseRepository={_,_ in choices += 1;return c.root}
            c.model.retryNewOutputAdd()
            try await wait("repository grant Add retry settled"){!c.model.busy && c.model.pendingNewOutput==nil}
            let trackedGrantedOutput=try await tracked(c,c.output)
            try require(choices==2 && c.model.error==nil && trackedGrantedOutput,"Retained saved receipt did not acquire actual Git-root grant for retry")
            try require((try Data(contentsOf:c.output))==bytes && (try FileManager.default.attributesOfItem(atPath:c.output.path)[.systemFileNumber] as? NSNumber)==inode,"Git-root permission retry rewrote saved output")
            try await c.close()
        }catch{try? await c.close();throw error}
    }
    static func outputs(_ folder:URL,git:URL)async throws {
        for enabled in [true,false] {
            let c=try await make(folder.appendingPathComponent(enabled ? "enabled":"disabled"),git:git,autoAdd:enabled)
            do {c.model.result="new ordinary result\n";try require(try await save(c),"New nested ordinary Save failed: "+(c.model.error ?? "none"));try require((try Data(contentsOf:c.output))==Data("new ordinary result\n".utf8),"Missing-parent output bytes incorrect");try require(try await tracked(c,c.output)==enabled,"AutoAdd preference did not control new ordinary output staging");let staged=try await c.repo.run(["diff","--cached","--name-only","-z"]).stdout;let relative=String(c.output.path.dropFirst(c.root.path.count+1));try require(staged==(enabled ? Data(Array(relative.utf8)+[0]):Data()),"Ordinary Save staged unrelated files or lost literal output path");try await c.close()}catch{try? await c.close();throw error}
        }
        let existing=try await make(folder.appendingPathComponent("existing"),git:git,autoAdd:true,existing:true)
        do {existing.model.result="edited existing result\n";try require(try await save(existing),"Existing ordinary Save failed");try require((try Data(contentsOf:existing.root.appendingPathComponent(".git/index")))==existing.baselineIndex,"Existing ordinary output was automatically staged");try await existing.close()}catch{try? await existing.close();throw error}
        let copy=try await make(folder.appendingPathComponent("save-as"),git:git,autoAdd:true,existing:true)
        do {let destination=copy.root.appendingPathComponent("chosen-copy.txt");copy.model.chooseStandaloneOutput={_,_ in destination};copy.model.result="explicit Save As result\n";try require(try await save(copy,saveAs:true),"Explicit result Save As failed");try require(!(try await tracked(copy,destination)),"Explicit Save As unexpectedly staged copy");try require((try Data(contentsOf:copy.root.appendingPathComponent(".git/index")))==copy.baselineIndex,"Save As changed original index");try await copy.close()}catch{try? await copy.close();throw error}
    }
    static func comparisonOutputs(_ folder:URL,git:URL)async throws {
        for mode in ["enabled","disabled","existing"] {
            let directory=folder.appendingPathComponent(mode);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let repo=GitRepository(root:directory,executable:git,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Comparison output QA"),("user.email","compare@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repo.run(["config",key,value])}
            let left=directory.appendingPathComponent("left.txt"),mine=directory.appendingPathComponent("mine.txt"),output=directory.appendingPathComponent(mode=="existing" ? "existing.txt":"nested 雪/deeper/result [x]\t.txt")
            for file in [left,mine]{try Data("baseline\n".utf8).write(to:file)}
            if mode=="existing"{try Data("original output\n".utf8).write(to:output)}
            try await repo.stage([left.lastPathComponent,mine.lastPathComponent]+(mode=="existing" ? [output.lastPathComponent]:[]));_=try await repo.commit(message:"comparison baseline")
            let indexURL=directory.appendingPathComponent(".git/index"),index=try Data(contentsOf:indexURL)
            let suite="TurtleGit.CompareOutput."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
            prefs.set(mode != "disabled",forKey:"TurtleGitMerge.AutoAdd");prefs.set(false,forKey:"TurtleGitMerge.Backup");prefs.set(false,forKey:"UseLibgit2")
            let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:mine),permissions:[RepositoryAccessLease(url:directory)],preferences:prefs,deferInitialLoad:true),model=owner.model
            defer{prefs.removePersistentDomain(forName:suite);owner.close()}
            do {
                guard let invocation=try MergeToolInvocation.parse(arguments:["--base",left.path,"--mine",mine.path,"--merged",output.path],currentDirectory:directory.path)else{throw Failure(description:"Actual two-file merged-output invocation missing")}
                try model.configureMergeTool(invocation);model.newOutputAdd.executable={git};model.newOutputAdd.requiresScope=false
                model.editorConfigEnabled=[true:false,false:false];owner.showWindow(nil);model.beginTransferredDocument()
                try await wait("actual comparison merged-output document ready"){!model.busy && !model.filtering && model.document != nil}
                model.editingEnabled=true;model.updateDraft("new comparison result\n",base:false)
                var saved:Bool?;model.save{saved=$0}
                try await wait("actual comparison ordinary Save/Add settled"){saved != nil && !model.busy && !model.filtering && !model.mergeToolHasPendingWork}
                try require(saved==true && model.error==nil && (try Data(contentsOf:output))==Data("new comparison result\n".utf8),"Comparison new-output ordinary Save failed")
                let staged=try await repo.run(["diff","--cached","--name-only","-z"]).stdout
                if mode=="enabled"{let relative=String(output.path.dropFirst(directory.path.count+1));try require(staged==Data(Array(relative.utf8)+[0]),"Comparison AutoAdd staged incorrect literal output scope")}
                else{try require((try Data(contentsOf:indexURL))==index,"Comparison AutoAdd disabled/existing output changed index")}
                if mode=="enabled" {
                    let beforeCopy=try Data(contentsOf:indexURL),copy=directory.appendingPathComponent("explicit-copy.txt")
                    model.chooseExportLocation={_,_,_ in copy};model.updateDraft("explicit comparison copy\n",base:false);model.saveAs(base:false)
                    try await wait("actual comparison explicit Save As settled"){FileManager.default.fileExists(atPath:copy.path) && !model.busy && !model.filtering && !model.mergeToolHasPendingWork}
                    try require((try Data(contentsOf:indexURL))==beforeCopy && (try Data(contentsOf:copy))==Data("explicit comparison copy\n".utf8),"Comparison Save As unexpectedly staged copy or changed bytes")
                }
                try require((try Data(contentsOf:mine))==Data("baseline\n".utf8),"Merged-output comparison overwrote original input")
                owner.close();try await wait("comparison output owner drain"){!model.mergeToolHasPendingWork}
            }catch{owner.close();try? await wait("failed comparison owner drain"){!model.mergeToolHasPendingWork};throw error}
        }
    }
    static func plainFolderOutputs(_ folder:URL,git:URL)async throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let suite="TurtleGit.PlainFolderOutput."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"TurtleGitMerge.Backup");prefs.set(false,forKey:"UseLibgit2")
        try require(prefs.object(forKey:"TurtleGitMerge.AutoAdd")==nil && MergeEditorPreferences.load(from:prefs).autoAdd,"Plain-folder fixture did not preserve AutoAdd default true")
        let inputs=["base.txt","theirs.txt","mine.txt"].map{folder.appendingPathComponent($0)},original=Data("plain source\n".utf8)
        for file in inputs{try original.write(to:file)}
        let compareOutput=folder.appendingPathComponent("compare nested/result.txt")
        let pair=FileComparisonWindowController(comparison:try WorkingFileComparison(base:inputs[0],destination:inputs[2]),permissions:[RepositoryAccessLease(url:folder)],preferences:prefs,deferInitialLoad:true)
        var merge:TextConflictWindowController?
        func cleanup()async throws {
            pair.model.cancelPaneSave();pair.model.error=nil;pair.close()
            if let merge {merge.model.cancelSaveOperation();merge.model.error=nil;merge.close()}
            try await wait("plain-folder native owners drain"){!pair.model.mergeToolHasPendingWork && merge?.model.mergeToolHasPendingWork != true && pair.window?.attachedSheet==nil && merge?.window?.attachedSheet==nil}
        }
        do {
            let request=try MergeToolInvocation.parse(arguments:["--base",inputs[0].path,"--mine",inputs[2].path,"--merged",compareOutput.path,"--saverequired"],currentDirectory:folder.path)!
            try pair.model.configureMergeTool(request);pair.model.editorConfigEnabled=[true:false,false:false]
            var pairExecutables=0,pairAdds=0
            pair.model.newOutputAdd.executable={pairExecutables+=1;return git};pair.model.newOutputAdd.requiresScope=false
            pair.model.newOutputAdd.addOutput={_,_,_ in pairAdds+=1;throw Failure(description:"Plain-folder Compare unexpectedly attempted Git Add")}
            var pairChoices=0;pair.model.newOutputAdd.chooseRepository={_,_ in pairChoices+=1;return nil}
            pair.showWindow(nil);pair.model.beginTransferredDocument()
            try await wait("plain-folder actual Compare ready"){!pair.model.busy && !pair.model.filtering && pair.model.document != nil}
            var pairSaved:Bool?;pair.model.saveAll{pairSaved=$0}
            try await wait("plain-folder default AutoAdd Compare Save"){pairSaved != nil && !pair.model.mergeToolHasPendingWork}
            try require(pairSaved==true && pairChoices==0 && pairExecutables==0 && pairAdds==0 && pair.model.pendingNewOutputAdd==nil && pair.model.error==nil && pair.model.mergeToolSaved && !pair.model.dirty && pair.window?.attachedSheet==nil && (try Data(contentsOf:compareOutput))==original,"Default AutoAdd asked for a repository or left Compare Save pending in proven plain folder")
            let output=folder.appendingPathComponent("three nested/result.txt")
            let working=try WorkingTextMerge(base:inputs[0],theirs:inputs[1],mine:inputs[2],merged:output,allowMissingInputs:true)
            let owner=TextConflictWindowController(repository:GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false)),access:nil,path:output.lastPathComponent,workingMerge:working,permissions:[RepositoryAccessLease(url:folder)],preferences:prefs,deferInitialLoad:true)
            merge=owner;owner.model.regexDefaults=prefs;owner.model.commentProfileURL=folder.appendingPathComponent("private-comments")
            var mergeExecutables=0,mergeAdds=0
            owner.model.newOutputAdd.executable={mergeExecutables+=1;return git};owner.model.newOutputAdd.requiresScope=false
            owner.model.newOutputAdd.addOutput={_,_,_ in mergeAdds+=1;throw Failure(description:"Plain-folder Merge unexpectedly attempted Git Add")}
            var mergeChoices=0;owner.model.newOutputAdd.chooseRepository={_,_ in mergeChoices+=1;return nil}
            let triple=try MergeToolInvocation.parse(arguments:["--base",inputs[0].path,"--theirs",inputs[1].path,"--mine",inputs[2].path,"--merged",output.path],currentDirectory:folder.path)!
            try owner.model.configureMergeTool(triple);owner.showWindow(nil);owner.model.beginTransferredDocument()
            try await wait("plain-folder actual three-file Merge ready"){!owner.model.busy && !owner.model.preparing && owner.model.document != nil && owner.model.nativeEditorReady}
            owner.model.result="plain three-file result\n"
            var merged:Bool?;owner.model.save(markResolved:false){merged=$0}
            try await wait("plain-folder default AutoAdd three-file Save"){merged != nil && !owner.model.mergeToolHasPendingWork}
            try require(merged==true && mergeChoices==0 && mergeExecutables==0 && mergeAdds==0 && owner.model.pendingNewOutput==nil && owner.model.error==nil && !owner.model.dirty && owner.window?.attachedSheet==nil && (try Data(contentsOf:output))==Data("plain three-file result\n".utf8),"Default AutoAdd asked for a repository or left three-file Save pending in proven plain folder")
            for input in inputs{try require((try Data(contentsOf:input))==original,"Plain-folder Save modified source input")}
            try require(!FileManager.default.fileExists(atPath:folder.appendingPathComponent(".git").path),"Plain-folder Save initialized a repository")
            try await cleanup()
        }catch{try? await cleanup();throw error}
    }
    static func acceptedAddLateCancellation(_ folder:URL,git:URL)async throws {
        for pair in [false,true] {for retry in [false,true] {
            let c=try await make(folder.appendingPathComponent("\(pair ? "compare":"merge")-\(retry ? "retry":"save")"),git:git,autoAdd:true)
            var comparison:FileComparisonWindowController?
            do {
                let peer="unrelated [keep].txt";try await c.repo.stage([peer])
                let peerBefore=try await c.repo.run(["ls-files","--stage","-z","--",peer]).stdout,head=try await c.repo.run(["rev-parse","HEAD"]).stdout
                let peerBytes=try Data(contentsOf:c.root.appendingPathComponent(peer)),inputBytes=try c.inputs.map{try Data(contentsOf:$0)}
                let expected=Data("accepted Add before late cancellation\n".utf8)
                var retryInode:NSNumber?
                if pair {
                    let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:c.inputs[0],destination:c.inputs[2]),permissions:[RepositoryAccessLease(url:c.root)],preferences:c.prefs,deferInitialLoad:true)
                    comparison=owner;let model=owner.model
                    let invocation=try MergeToolInvocation.parse(arguments:["--base",c.inputs[0].path,"--mine",c.inputs[2].path,"--merged",c.output.path],currentDirectory:c.root.path)!
                    try model.configureMergeTool(invocation);model.editorConfigEnabled=[true:false,false:false];model.newOutputAdd.executable={git};model.newOutputAdd.requiresScope=false
                    owner.showWindow(nil);model.beginTransferredDocument();try await wait("late-cancel Compare ready"){!model.busy && !model.filtering && model.document != nil}
                    model.editingEnabled=true;model.updateDraft(String(decoding:expected,as:UTF8.self),base:false)
                    if retry {
                        model.newOutputAdd.addOutput={_,_,_ in throw Failure(description:"Private prepublication Add failure")}
                        var first:Bool?;model.save{first=$0};try await wait("Compare initial Add refusal"){first != nil && !model.mergeToolHasPendingWork}
                        try require(first==false && model.pendingNewOutputAdd != nil && !model.dirty,"Compare retry setup lost saved baseline")
                        retryInode=try FileManager.default.attributesOfItem(atPath:c.output.path)[.systemFileNumber] as? NSNumber
                        model.error=nil;try await wait("Compare refusal sheet detached"){owner.window?.attachedSheet==nil}
                    }
                    var actualAdds=0;model.newOutputAdd.addOutput={repo,receipt,token in try await repo.addNewMergeOutput(receipt,cancellation:token);actualAdds+=1;token.cancel()}
                    if retry {model.retryNewOutputAdd()}
                    else {var done:Bool?;model.save{done=$0};try await wait("Compare accepted Add completion"){done != nil && !model.mergeToolHasPendingWork};try require(done==true,"Late cancellation changed actual successful Compare Add to failed save")}
                    try await wait("Compare accepted receipt adopted"){!model.busy && !model.filtering && !model.mergeToolHasPendingWork && model.pendingNewOutputAdd==nil}
                    try require(actualAdds==1 && model.error==nil && model.mergeToolSaved && !model.dirty,"Compare discarded actual Add success after token cancellation")
                    owner.close();try await wait("late-cancel Compare drains"){!model.mergeToolHasPendingWork}
                } else {
                    c.model.result=String(decoding:expected,as:UTF8.self)
                    if retry {
                        c.model.newOutputAdd.addOutput={_,_,_ in throw Failure(description:"Private prepublication Add failure")}
                        try require(!(try await save(c)) && c.model.pendingNewOutput != nil && !c.model.dirty,"Merge retry setup lost saved baseline")
                        retryInode=try FileManager.default.attributesOfItem(atPath:c.output.path)[.systemFileNumber] as? NSNumber
                        c.model.error=nil;try await wait("Merge refusal sheet detached"){c.owner.window?.attachedSheet==nil}
                    }
                    var actualAdds=0;c.model.newOutputAdd.addOutput={repo,receipt,token in try await repo.addNewMergeOutput(receipt,cancellation:token);actualAdds+=1;token.cancel()}
                    if retry {c.model.retryNewOutputAdd()}
                    else {try require(try await save(c),"Late cancellation changed actual successful Merge Add to failed save")}
                    try await wait("Merge accepted receipt adopted"){!c.model.busy && !c.model.mergeToolHasPendingWork && c.model.pendingNewOutput==nil}
                    try require(actualAdds==1 && c.model.error==nil && !c.model.dirty,"Merge discarded actual Add success after token cancellation")
                }
                let relative=String(c.output.path.dropFirst(c.root.path.count+1)),indexed=try await c.repo.run(["show",":"+relative]).stdout
                let peerAfter=try await c.repo.run(["ls-files","--stage","-z","--",peer]).stdout,finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
                try require(indexed==expected && (try Data(contentsOf:c.output))==expected && peerAfter==peerBefore && finalHead==head && (try Data(contentsOf:c.root.appendingPathComponent(peer)))==peerBytes,"Late-cancel accepted Add lost output or changed unrelated staged/work/HEAD bytes")
                if let retryInode {try require((try FileManager.default.attributesOfItem(atPath:c.output.path)[.systemFileNumber] as? NSNumber)==retryInode,"Accepted late-cancel Retry Add rewrote saved file")}
                for(index,file)in c.inputs.enumerated(){try require((try Data(contentsOf:file))==inputBytes[index],"Late-cancel Add changed source input")}
                try await c.close()
            }catch{comparison?.model.cancelPaneSave();comparison?.close();try? await wait("failed late-cancel Compare drain"){comparison?.model.mergeToolHasPendingWork != true};try? await c.close();throw error}
        }}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.mergeOutputOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try await plainFolderOutputs(folder.appendingPathComponent("plain-folder"),git:git)
        try await acceptedAddLateCancellation(folder.appendingPathComponent("accepted-late-cancel"),git:git)
        try await outputs(folder.appendingPathComponent("outputs"),git:git)
        try await addFailureAndCancellation(folder.appendingPathComponent("add-recovery"),git:git)
        try await pendingIntentDisposition(folder.appendingPathComponent("pending-disposition"),git:git)
        try await ancestorGrant(folder.appendingPathComponent("ancestor-grant"),git:git)
        try await repositoryAddGrant(folder.appendingPathComponent("repository-add-grant"),git:git)
        try await comparisonOutputs(folder.appendingPathComponent("comparison"),git:git)
        try await preparation(folder.appendingPathComponent("preparation"),git:git)
        print("PASS: connected Merge new-output Save and owned prepared reload family")
    }
}
