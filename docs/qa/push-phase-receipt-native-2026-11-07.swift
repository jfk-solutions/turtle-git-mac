// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum PushPhaseReceiptVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ text:String)throws {if !value{fputs("FAIL Push phase receipt: \(text)\n",stderr);throw Failure(description:text)}}
    static func wait(_ text:String,_ predicate:()->Bool)async throws {for _ in 0..<3000 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:text)}
    static func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func verify()async throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let client=base.appendingPathComponent("client"),remoteRoot=base.appendingPathComponent("remote.git")
        for path in [client,remoteRoot] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)}
        let direct=GitRepository(root:client,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false)),remote=GitRepository(root:remoteRoot,executable:git,askpass:nil)
        _=try await direct.run(["init","-b","main"]);_=try await remote.run(["init","--bare"])
        for(key,value)in[("user.name","Push receipt QA"),("user.email","push@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await direct.run(["config",key,value])}
        try Data("base\n".utf8).write(to:client.appendingPathComponent("file"));try await direct.stage(["file"]);_=try await direct.commit(message:"base")
        try await direct.saveRemote(name:"origin",fetchURL:remoteRoot.path,pushURL:"",existing:false)
        let head=try await direct.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:client.appendingPathComponent(".git/index"))
        let wrapper=base.appendingPathComponent("push-phase-git"),hook=base.appendingPathComponent("post-push-held.sh")
        let hold=base.appendingPathComponent("hook.hold"),marker=base.appendingPathComponent("hook.started")
        let script="""
        #!/bin/sh
        task_is_push() {
          while [ "$#" -gt 0 ];do
            case "$1" in
              -C|-c|--git-dir|--work-tree|--config-env) shift 2;;
              --literal-pathspecs|--no-literal-pathspecs) shift;;
              -*) shift;;
              *) test "$1" = push;return;;
            esac
          done
          return 1
        }
        if task_is_push "$@";then printf 'push\\n' >> "$0.calls";fi
        exec \(quote(git.path)) "$@"
        """
        let hookScript="""
        #!/bin/sh
        if [ -f \(quote(hold.path)) ];then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null;wait "$task_child" 2>/dev/null;exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > \(quote(marker.path+".tmp"))
          /bin/mv \(quote(marker.path+".tmp")) \(quote(marker.path))
          wait "$task_child"
        fi
        """
        try script.write(to:wrapper,atomically:true,encoding:.utf8);try hookScript.write(to:hook,atomically:true,encoding:.utf8)
        for file in [wrapper,hook] {try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)}
        let repo=GitRepository(root:client,executable:wrapper,askpass:nil,diffDetection:.init(percentage:31),libgit2Configuration:.init(enabled:false,mask:0x1234))
        let suite="TurtleGit.PushPhaseReceipt."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"UseLibgit2");prefs.set(UInt32(0x1234),forKey:"UseLibgit2_mask");prefs.set(31,forKey:"DiffSimilarityIndexThreshold")
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        let configuredHook=ClientHook(type:.postPush,path:repo.root.path,command:"/bin/sh "+quote(hook.path),show:false)
        prefs.set(try ClientHookConfiguration.serialize([configuredHook]),forKey:"hooks")
        var owners:[PushWindowController]=[],parents:[NSWindow]=[]
        defer{try? FileManager.default.removeItem(at:hold);prefs.removePersistentDomain(forName:suite)}
        func cleanup()async throws {
            try? FileManager.default.removeItem(at:hold)
            owners.forEach{$0.close()}
            // Retain native parents while their owned controller release tasks
            // finish physical sheet detachment, including the failure path.
            try await wait("Push controllers did not drain before native parent close"){owners.allSatisfy{!$0.serviceWorkPending}}
            for parent in parents {if let sheet=parent.attachedSheet{parent.endSheet(sheet,returnCode:.abort)};parent.close()}
        }
        do {
        for mode in ["cancel-hook","retire-hook","fresh","stale"] {
            try? FileManager.default.removeItem(at:marker)
            if mode.hasSuffix("hook") {try Data().write(to:hold)}else{try? FileManager.default.removeItem(at:hold)}
            prefs.set(false,forKey:"UseLibgit2");prefs.set(UInt32(0x1234),forKey:"UseLibgit2_mask")
            let parent=NSWindow(contentRect:.init(x:-24000,y:-24000,width:800,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            parent.isReleasedWhenClosed=false;parent.alphaValue=0;parents.append(parent)
            let owner=PushWindowController(repository:repo,access:nil,preferences:prefs);owners.append(owner)
            owner.window?.alphaValue=0;parent.beginSheet(owner.window!,completionHandler:nil)
            let model=owner.model
            var closed=0,refreshes=0,replacements=0,liveSuccesses=0,postactions=0,hookContexts:[GitRepository]=[]
            owner.onClosed={closed += 1}
            model.clientHooks.readProjectHooks={accepted,_ in hookContexts.append(accepted);return []}
            model.onTransportResult={_,success in
                refreshes += 1
                precondition(success && model.pendingOperations==0 && PushWindowModel.activePushWorkflows==0 && ClientHookProcessPool.shared.activeScripts==0,"Accepted Push refresh preceded actual worker/hook drain")
            }
            model.onPushed={_ in liveSuccesses += 1}
            model.onRepositoryPostAction={action,options,_,accepted in
                postactions += 1
                precondition(action == .requestPull && options.destination==mode,"Push postaction lost accepted options")
                precondition(owner.window?.sheetParent==nil && parent.attachedSheet==nil && owner.window?.attachedSheet==nil && owner.progressController==nil && !owner.serviceWorkPending,"Push postaction preceded physical progress/options/parent detach")
                precondition(accepted.executable==repo.executable && accepted.askpass==repo.askpass && accepted.diffDetection==repo.diffDetection && accepted.libgit2Configuration?.enabled==false && accepted.libgit2Configuration?.mask==UInt32(0x1234),"Push postaction recaptured later executable/backend/diff policy")
            }
            model.load();try await wait("Push form not ready"){!model.busy}
            model.options.remote="origin";model.options.source="main";model.options.destination=mode;model.options.setUpstream=false
            model.push()
            if mode.hasSuffix("hook") {
                do{try await wait("Actual successful Push did not reach held post-hook"){FileManager.default.fileExists(atPath:marker.path) && model.postHookRunning && model.transportCompletion?.success==true}}
                catch{throw Failure(description:"Held Push boundary: mode=\(mode) marker=\(FileManager.default.fileExists(atPath:marker.path)) hook=\(model.postHookRunning) receipt=\(String(describing:model.transportCompletion)) error=\(model.error ?? "nil") output=\(owner.progressController?.result.output ?? "nil") hookRoots=\(hookContexts.map{$0.root.path})") }
                let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
                try require(pids.count==2 && pids.allSatisfy{kill($0,0)==0} && refreshes==0 && liveSuccesses==0 && owner.progressController?.result.busy==true,"Post-hook boundary lost command receipt or process ownership")
                let received=try await remote.run(["rev-parse","refs/heads/"+mode]).stdout
                try require(received==head,"Held post-hook had no actual remote publication")
                prefs.set(true,forKey:"UseLibgit2");prefs.set(UInt32(0),forKey:"UseLibgit2_mask")
                if mode=="retire-hook" {
                    model.onTransportResult={_,_ in replacements += 1};owner.close()
                    try require(closed==0 && refreshes==0 && model.pendingOperations>0,"Retired Push released actual post-hook early")
                }else{try require(model.canCancel,"Post-hook disabled owned Cancel");model.cancel()}
                try await wait("Post-hook cancellation/retirement did not drain"){refreshes==1 && model.pendingOperations==0 && pids.allSatisfy{kill($0,0) != 0}}
                try require(replacements==0 && model.transportCompletion?.success==true && model.transportCompletion?.cancelled==false,"Late hook cancellation replaced immutable actual transport result or captured refresh")
                if mode=="retire-hook" {try await wait("Retired Push controller did not detach"){closed==1 && !owner.serviceWorkPending};try require(liveSuccesses==0,"Retired post-hook emitted active success")}
                else {
                    try await wait("Cancelled hook did not finish successful Push UI"){owner.progressController?.result.busy==false}
                    let result=owner.progressController!.result
                    try require(result.success && !result.cancelled && liveSuccesses==1 && result.output.contains("post-push hook failed"),"Hook cancellation state: success=\(result.success) cancelled=\(result.cancelled) liveSuccesses=\(liveSuccesses) output=\(result.output)")
                    result.close();owner.close();try await wait("Successful Push did not close"){closed==1 && !owner.serviceWorkPending}
                }
            }else {
                try await wait("Actual Push completion did not settle"){owner.progressController?.result.busy==false && refreshes==1}
                let progress=owner.progressController!,result=progress.result
                try require(result.success && liveSuccesses==1 && result.postActions.contains(.requestPull),"Actual successful Push lost follow-up")
                prefs.set(true,forKey:"UseLibgit2");prefs.set(UInt32(0),forKey:"UseLibgit2_mask")
                if mode=="fresh" {
                    model.confirmingQuit=true;result.perform(.requestPull);try require(postactions==0,"Deferred Quit accepted Push followup")
                    model.confirmingQuit=false;result.perform(.requestPull);result.perform(.requestPull)
                    try await wait("Fresh post-Quit Push followup did not detach exactly once"){postactions==1 && closed==1 && !owner.serviceWorkPending}
                }else {
                    var retained:(()->Void)?;result.finishAndPerform={retained=$0}
                    result.perform(.requestPull);try require(retained != nil,"Push did not capture accepted followup")
                    model.confirmingQuit=true;model.confirmingQuit=false
                    let old=retained;retained=nil;old?();old?()
                    try await wait("Stale Push action did not close/drain"){closed==1 && !owner.serviceWorkPending}
                    try require(postactions==0,"Accepted pre-Quit Push followup revived after cancellation")
                }
            }
            try require(!hookContexts.isEmpty && hookContexts.allSatisfy{$0.libgit2Configuration?.enabled==false && $0.libgit2Configuration?.mask==UInt32(0x1234) && $0.executable==repo.executable},"Push hooks lost accepted repository/backend")
            parent.close()
        }
        let refused=PushWindowModel(repository:repo,access:nil,preferences:prefs);defer{refused.invalidate()}
        var refusalEvents=0;refused.onTransportResult={_,_ in refusalEvents += 1};refused.load();try await wait("Refusal form not ready"){!refused.busy}
        refused.options.source="missing";refused.options.remote="origin";refused.push();try await wait("Preflight refusal did not settle"){!refused.busy}
        try require(refusalEvents==0 && refused.transportCompletion==nil && refused.error != nil,"Preflight refusal fabricated actual transport refresh")
        let afterHead=try await direct.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && (try Data(contentsOf:client.appendingPathComponent(".git/index")))==index,"Push receipt/hook/dialog handoff changed source HEAD/index")
        try require(try String(contentsOf:URL(fileURLWithPath:wrapper.path+".calls"),encoding:.utf8)==String(repeating:"push\n",count:4),"Push handoff or recovery repeated actual transport")
        try await cleanup()
        print("PASS Push actual phase receipts: publication before owned hook; late hook Cancel and retirement preserve actual success and captured refresh after drain; no preflight event; native detached fresh/stale once-only postactions preserve accepted backend/options")
        }catch{let original=error;do{try await cleanup()}catch{throw Failure(description:"\(original); cleanup: \(error)")};throw original}
    }
}
