// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum RequestPullWorkflowVerification {
    static func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:message,code:2)}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func hide(_ owner:NSWindowController){owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);owner.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));owner.showWindow(nil)}
    static func executable(_ file:URL,_ script:String)throws{try Data(script.utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)}
    static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),client=root.appendingPathComponent("client space 雪"),published=root.appendingPathComponent("published space.git")
        try FileManager.default.createDirectory(at:client,withIntermediateDirectories:true)
        let repo=GitRepository(root:client,executable:git);_ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Request workflow"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        for value in ["base","tip"]{try Data((value+"\n").utf8).write(to:client.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:value)}
        let base=try await repo.run(["rev-parse","HEAD~1"]).text.trimmingCharacters(in:.newlines)
        for branch in ["zulu","Alpha","beta"]{_ = try await repo.run(["branch",branch])};_ = try await repo.run(["update-ref","refs/remotes/origin/a-remote",base])
        _ = try await repo.run(["clone","--bare","--",client.path,published.path])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:client.appendingPathComponent(".git/index")),config=try Data(contentsOf:client.appendingPathComponent(".git/config")),working=try Data(contentsOf:client.appendingPathComponent("file"))
        let suite="TurtleGit.RequestPullWorkflow."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        try await editor(repo:repo,base:base,published:published,root:root,preferences:prefs)
        try await failedEditor(repo:repo,base:base,published:published,root:root,preferences:prefs)
        try await mail(repo:repo,base:base,published:published,root:root,preferences:prefs)
        try await heldWrite(repo:repo,base:base,published:published,root:root,preferences:prefs)
        try await cancellation(repo:repo,base:base,published:published,root:root,preferences:prefs)
        try await staleQuit(repo:repo,base:base,published:published,root:root,preferences:prefs)
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:client.appendingPathComponent(".git/index"))==index && Data(contentsOf:client.appendingPathComponent(".git/config"))==config && Data(contentsOf:client.appendingPathComponent("file"))==working,"Request Pull changed source HEAD/index/config/working bytes")
        print("PASS Request Pull waiting-dialog actual detach, captured configured editor and executable argv, real document/mail, held writer retirement, direct Cancel/retry/error acknowledgement and Quit-stale handoff; private captured preferences and unchanged repository.")
    }
    static func configure(_ owner:RequestPullWindowController,base:String)async throws {
        hide(owner);try await wait("Request Pull initial load did not drain"){!owner.model.busy && !owner.model.hasPendingWork};owner.model.start=base;owner.model.end="main";owner.model.sendMail=false
    }
    static func writer(_ owner:RequestPullWindowController,root:URL){
        owner.model.writeRequest={bytes,token in
            try token.check();let folder=try TurtleGitTemporaryStorage.root.appendingPathComponent("request-qa-"+UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let file=folder.appendingPathComponent("pullrequest.txt");try bytes.write(to:file,options:.atomic);try token.check();return file
        }
    }
    static func editor(repo:GitRepository,base:String,published:URL,root:URL,preferences:UserDefaults)async throws {
        let helper=root.appendingPathComponent("captured editor 雪"),marker=root.appendingPathComponent("editor.argv")
        try executable(helper,"#!/bin/sh\nprintf '%s\\0' \"$@\" > "+quote(marker.path)+"\n")
        let chosen=AlternativeEditorPreferences(custom:true,applicationPath:helper.path);chosen.save(to:preferences)
        let owner=RequestPullWindowController(repository:repo,access:nil,end:"main",repositoryURL:published.path,preferences:preferences)
        defer{owner.close()};try await configure(owner,base:base);writer(owner,root:root)
        try require(owner.model.references==["Alpha","beta","main","zulu","remotes/origin/a-remote"],"Request Pull lost source local-first/natural branch ordering")
        preferences.set(true,forKey:"NoSortLocalBranchesFirst");owner.model.load();try await wait("Private alternate branch ordering did not reload"){!owner.model.hasPendingWork}
        try require(owner.model.references==["Alpha","beta","main","remotes/origin/a-remote","zulu"],"Request Pull ignored captured alternate branch ordering preference")
        preferences.set(false,forKey:"NoSortLocalBranchesFirst")
        var launches=0,closed=0;owner.onClosed={closed+=1}
        owner.launchEditor={file,settings,permissions,token in
            try require(owner.waitingController==nil && owner.window?.attachedSheet==nil && owner.model.pendingOperations==1 && owner.model.openingEditor,"Editor launched before waiting/worker actual detach or without own launch lifetime")
            try require(settings==chosen,"Editor did not capture private settings before generation")
            launches+=1;try await AlternativeEditor.openDocument(file,settings:settings,permissions:permissions,cancellation:token)
        }
        owner.model.create();try require(owner.model.hasPendingWork,"Request Pull did not reserve generation synchronously")
        AlternativeEditorPreferences(custom:true,applicationPath:"/must-not-launch").save(to:preferences);owner.model.end="edited-after-submit";owner.model.sendMail=true
        try await wait("Configured controlled editor did not launch once and retire owner"){closed==1 && FileManager.default.fileExists(atPath:marker.path) && ExternalToolProcesses.activeRequests==0}
        let file=owner.model.document!;defer{try? FileManager.default.removeItem(at:file.deletingLastPathComponent())}
        let argv=try Data(contentsOf:marker).split(separator:0).map{String(decoding:$0,as:UTF8.self)}
        try require(argv==[file.path] && launches==1 && owner.model.isRetired,"Configured executable lost literal document argv or repeated launch")
        var options=RequestPullOptions();options.start=base;options.repositoryURL=published.path;options.end="main"
        try require(try Data(contentsOf:file)==(try await repo.requestPull(options)),"Generated editor document differs from real Git request bytes")
        let key="History.RequestPull."+repo.root.path+"."
        try require(preferences.string(forKey:key+"endrevision")=="main" && !preferences.bool(forKey:RequestPullWindowModel.sendMailKey),"Submitted Request Pull history/mail flag followed later draft")
    }
    static func failedEditor(repo:GitRepository,base:String,published:URL,root:URL,preferences:UserDefaults)async throws {
        AlternativeEditorPreferences(custom:true,applicationPath:root.appendingPathComponent("missing-editor").path).save(to:preferences)
        let owner=RequestPullWindowController(repository:repo,access:nil,end:"main",repositoryURL:published.path,preferences:preferences)
        defer{owner.close()};try await configure(owner,base:base);writer(owner,root:root)
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,opened=0
        owner.presentError={question,parent,reply in alert=question;answer=reply;question.beginSheetModal(for:parent,completionHandler:reply)}
        owner.model.create();try await wait("Configured editor failure did not retain actual fallback after waiting detach"){owner.errorWindow != nil && alert?.window.sheetParent===owner.window}
        let file=owner.model.document!,bytes=try Data(contentsOf:file);defer{try? FileManager.default.removeItem(at:file.deletingLastPathComponent())}
        try require(owner.waitingController==nil && !owner.model.hasPendingWork && owner.model.error?.contains("Open request")==true && !owner.model.isRetired,"Editor failure bypassed owned error/waiting drain or lost fallback")
        answer?(.alertFirstButtonReturn);try await wait("Configured editor failure acknowledgement did not detach"){owner.errorWindow==nil && owner.model.error==nil}
        let chosen=AlternativeEditorPreferences(custom:true,applicationPath:root.appendingPathComponent("captured editor 雪").path);chosen.save(to:preferences)
        owner.launchEditor={document,settings,permissions,token in
            try require(owner.errorWindow==nil && owner.window?.attachedSheet==nil && document==file && settings==chosen,"Open request did not recapture explicit retry editor after actual error detach")
            opened+=1;try await AlternativeEditor.openDocument(document,settings:settings,permissions:permissions,cancellation:token)
        }
        owner.model.openDocument();answer?(.alertFirstButtonReturn)
        try await wait("Configured editor retry did not retire owner and worker"){owner.model.isRetired && ExternalToolProcesses.activeRequests==0}
        try require(opened==1 && (try Data(contentsOf:file))==bytes,"Open request retry repeated or changed generated bytes")
    }
    static func mail(repo:GitRepository,base:String,published:URL,root:URL,preferences:UserDefaults)async throws {
        var shown:SendPatchWindowController?,calls=0
        let owner=RequestPullWindowController(repository:repo,access:nil,end:"main",repositoryURL:published.path,preferences:preferences,mailPresentation:{child in shown=child as? SendPatchWindowController;calls+=1;precondition(child.window?.appearance?.name==NSAppearance.Name.darkAqua && child.window?.alphaValue==0,"Mail source snapshot missing before presentation");child.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));child.showWindow(nil)})
        defer{shown?.close();owner.close()};try await configure(owner,base:base);writer(owner,root:root);owner.model.sendMail=true
        owner.model.create();try await wait("Request Pull did not present actual mail after waiting detach"){shown != nil && !owner.model.busy}
        let file=owner.model.document!;defer{try? FileManager.default.removeItem(at:file.deletingLastPathComponent())}
        try require(owner.waitingController==nil && owner.window?.attachedSheet==nil && calls==1 && shown!.model.presentationPreferences===preferences && shown!.window?.appearance?.name==NSAppearance.Name.darkAqua && shown!.window?.alphaValue==0,"Actual Request Pull mail lost waiting detach or captured preference/theme")
        try await wait("Request mail preview did not drain"){!shown!.model.previewBusy && SendPatchWindowModel.activeLoads==0}
        try require(shown!.model.customSubject && shown!.model.rows.map(\.file)==[file] && owner.model.composingMail,"Actual custom-subject mail lost generated document")
        shown!.model.cancel();try await wait("Request mail cancellation did not retire options"){owner.model.isRetired && !owner.model.composingMail};try require(calls==1,"Request mail presented repeatedly")
    }
    static func heldWrite(repo:GitRepository,base:String,published:URL,root:URL,preferences:UserDefaults)async throws {
        let owner=RequestPullWindowController(repository:repo,access:nil,end:"main",repositoryURL:published.path,preferences:preferences)
        defer{owner.close()};try await configure(owner,base:base)
        var pending:CheckedContinuation<URL,Never>?,token:OperationCancellation?,closed=0,presented=0
        let file=root.appendingPathComponent("held-writer/pullrequest.txt");try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        defer{pending?.resume(returning:file);pending=nil;try? FileManager.default.removeItem(at:file.deletingLastPathComponent())}
        owner.onClosed={closed+=1};owner.launchEditor={_,_,_,_ in presented+=1}
        owner.model.writeRequest={bytes,request in token=request;try bytes.write(to:file);return await withCheckedContinuation{pending=$0}}
        owner.model.create();try await wait("Request Pull real generation did not hold writer behind waiting dialog"){pending != nil && owner.waitingController != nil}
        try require(owner.model.busy && owner.model.hasPendingWork && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held Request Pull writer escaped work/Quit ownership")
        owner.close();try require(closed==0 && owner.model.hasPendingWork && token?.isCancelled==true,"Forced Request Pull close released actual writer early")
        pending?.resume(returning:file);pending=nil
        try await wait("Retired Request Pull writer/waiting dialog did not actually drain"){closed==1 && !owner.model.hasPendingWork && owner.waitingController==nil && owner.window?.attachedSheet==nil}
        try require(presented==0 && owner.model.document==nil && owner.model.isRetired,"Retired writer emitted document/editor handoff")
    }
    static func cancellation(repo:GitRepository,base:String,published:URL,root:URL,preferences:UserDefaults)async throws {
        let helper=root.appendingPathComponent("held-request-git"),marker=URL(fileURLWithPath:helper.path+".started"),release=URL(fileURLWithPath:helper.path+".release")
        let script="""
        #!/bin/sh
        is_request() {
          if [ "${1-}" = --literal-pathspecs ] || [ "${1-}" = --no-literal-pathspecs ];then shift;fi
          if [ "${1-}" = -C ];then shift 2;fi
          test "${1-}" = request-pull
        }
        if is_request "$@";then printf '%s\\0' "$@" > "$0.argv";fi
        if is_request "$@" && [ ! -f "$0.release" ];then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null;wait "$task_child" 2>/dev/null;exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp";/bin/mv "$0.started.tmp" "$0.started"
          wait "$task_child"
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try executable(helper,script)
        let slow=GitRepository(root:repo.root,executable:helper),owner=RequestPullWindowController(repository:slow,access:nil,end:"main",repositoryURL:published.path,preferences:preferences)
        defer{owner.close()};try await configure(owner,base:base);writer(owner,root:root)
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,launches=0
        owner.presentError={question,parent,reply in alert=question;answer=reply;question.beginSheetModal(for:parent,completionHandler:reply)}
        owner.launchEditor={_,_,_,_ in launches+=1}
        owner.model.create();try await wait("Actual Request Pull helper did not arrive"){FileManager.default.fileExists(atPath:marker.path) && owner.waitingController != nil}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Request Pull helper registry missing")
        let actual=try Data(contentsOf:URL(fileURLWithPath:helper.path+".argv")).split(separator:0).map{String(decoding:$0,as:UTF8.self)}
        try require(actual==["--literal-pathspecs","-C",repo.root.path,"request-pull","--",base,published.path,"main"],"Actual Request Pull argv lost validated captured values or literal argument boundary: \(actual)")
        try require(owner.waitingController?.cancelButton.isEnabled == true,"Native Request Pull Cancel unavailable")
        owner.waitingController!.cancelButton.performClick(nil);try await wait("Direct Cancel did not reap worker and attach error after waiting detach"){pids.allSatisfy{kill($0,0) != 0} && owner.waitingController==nil && alert?.window.sheetParent===owner.window}
        try require(launches==0 && alert!.window.defaultButtonCell===(alert!.buttons[0].cell as? NSButtonCell) && owner.model.error=="User cancelled.","Direct Request Pull Cancel lost native acknowledgement/default or launched editor")
        answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn);try await wait("Cancelled Request Pull error did not actually detach"){owner.errorWindow==nil && owner.window?.attachedSheet==nil && owner.model.error==nil}
        try Data().write(to:release);owner.model.create();try await wait("Request Pull fresh retry did not hand off generated document"){launches==1 && owner.model.isRetired}
        if let file=owner.model.document{try? FileManager.default.removeItem(at:file.deletingLastPathComponent())}
    }
    static func staleQuit(repo:GitRepository,base:String,published:URL,root:URL,preferences:UserDefaults)async throws {
        let owner=RequestPullWindowController(repository:repo,access:nil,end:"main",repositoryURL:published.path,preferences:preferences)
        defer{owner.close()};try await configure(owner,base:base);writer(owner,root:root)
        var launches=0;owner.launchEditor={_,_,_,_ in launches+=1}
        let waitingBlocker=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:120,height:80),styleMask:[.titled],backing:.buffered,defer:false);waitingBlocker.isReleasedWhenClosed=false;waitingBlocker.alphaValue=0
        owner.presentWaiting={parent,child in parent.beginSheet(child);child.beginSheet(waitingBlocker);return true}
        owner.model.create();try await wait("Request Pull handoff did not wait actual nested waiting sheet"){owner.model.waitingForHandoff && !owner.model.busy}
        owner.model.confirmingQuit=true;owner.model.confirmingQuit=false
        owner.waitingWindow?.endSheet(waitingBlocker,returnCode:.abort);waitingBlocker.close()
        try await wait("Quit-stale Request Pull waiting presentation did not drain"){owner.waitingController==nil && !owner.model.waitingForHandoff}
        try require(launches==0 && !owner.model.composingMail,"Pre-Quit generation opened a stale editor/mail handoff")
        if let file=owner.model.document{try? FileManager.default.removeItem(at:file.deletingLastPathComponent())}
    }
}
