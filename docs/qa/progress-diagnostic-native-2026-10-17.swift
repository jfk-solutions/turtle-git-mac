// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import Darwin
import TurtleGitCore

@main struct ProgressDiagnosticVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1800 {for window in NSApp.windows {window.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Progress diagnostic wait at \(line)")
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_PROGRESS_DIAGNOSTIC_CAPTURE"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned capture unavailable")}
        try require(window.frame.width>=650 && window.frame.height>=350,"Progress capture size: \(window.frame)")
        window.alphaValue=1;window.orderFront(nil);defer {window.alphaValue=0}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned progress capture unavailable")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Capture encoding")}
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("progress-diagnostic-"+name+".png"))
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repoRoot=root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:repoRoot,withIntermediateDirectories:true)
        let repo=GitRepository(root:repoRoot,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Progress QA"),("user.email","progress@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:repoRoot.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repoRoot.appendingPathComponent(".git/index")),configuration=try Data(contentsOf:repoRoot.appendingPathComponent(".git/config"))
        let suite="TurtleGit.ProgressDiagnostic."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(16,forKey:"GitOutputLimitinKiB");prefs.set(0,forKey:"AutoCloseGitProgress")
        let args=["-c","core.precomposeunicode=false","-C",repoRoot.path,"rev-parse","--verify","refs/heads/missing"]
        let earlier=(0..<6000).map{"Preparation payload \($0)\n"}.joined()
        var published=GitProgressOutputState(preferences:prefs),raw=""
        do {
            let _:String=try await LocalGitCommandProgress.stream(preferences:prefs,update:{published=$0},resultText:{$0},operation:{emit in
                emit(GitOutputChunk(stream:.stdout,data:Data(earlier.utf8)))
                return try await repo.run(args).text // This later command has no live callback.
            });throw Failure(description:"Missing reference succeeded")
        } catch let failure as GitFailure {
            raw=failure.message
            try require(failure.identity.command=="rev-parse" && failure.outputWasDelivered,"Delivered fallback lost operation metadata")
            try require(published.output.contains("fatal:") && published.output.contains("git rev-parse failed") && !published.output.contains("git -c failed"),"Silent later failure hidden behind prior output")
            try require(published.output.utf8.count<=published.limit && published.output.contains("Output truncated"),"Fallback bypassed captured limit")
            let shown=published.output;prefs.set(100*1024,forKey:"GitOutputLimitinKiB")
            try require(LocalGitCommandProgress.failure(failure,existing:shown,preferences:prefs)==shown,"Caller duplicated/reexpanded an already delivered diagnostic")
        }
        try require(raw.contains("fatal:"),"Raw error diagnostics were replaced by UI clipping")
        // A live failing producer must retain its full raw tail for recovery, but
        // must not append that tail again after its captured visible limit.
        let helper=root.appendingPathComponent("producer")
        let script="""
        #!/bin/sh
        task_line=0
        while [ "$task_line" -lt 6000 ]; do printf 'payload %s\n' "$task_line"; task_line=$((task_line+1)); done
        printf 'fatal: LIVE_DIAGNOSTIC_END\n' >&2
        exit 7
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let producer=GitRepository(root:repoRoot,executable:helper)
        prefs.set(16,forKey:"GitOutputLimitinKiB");var sawLive=false
        do {
            let _:String=try await LocalGitCommandProgress.stream(preferences:prefs,update:{state in published=state;if state.hasOutput && !sawLive {sawLive=true;prefs.set(100*1024,forKey:"GitOutputLimitinKiB")}},resultText:{$0},operation:{emit in
                try await producer.run(["-c","core.foo=ignored","status"],onOutput:emit).text
            });throw Failure(description:"Producer failure succeeded")
        } catch let failure as GitFailure {
            try require(failure.message.contains("payload 5999") && failure.message.contains("LIVE_DIAGNOSTIC_END") && failure.code==7,"Raw live failure was truncated")
            try require(published.limit==16*1024 && published.output.utf8.count<=published.limit && published.output.contains("git status failed (7)"),"Live failure summary/captured limit")
            try require(!published.output.contains("payload 5999") && !published.output.contains("LIVE_DIAGNOSTIC_END"),"Live failure re-appended its full raw result")
        }
        // Cancellation still drains and reaps the owned group, carrying partial
        // output independently of the completed display snapshot.
        let slow=root.appendingPathComponent("slow-producer"),marker=root.appendingPathComponent("cancel-pids")
        let cancelScript="""
        #!/bin/sh
        printf 'Cancellation phase: 20%%\n' >&2
        /bin/sleep 30 &
        task_child=$!
        printf '%s\n%s\n' "$$" "$task_child" > "$0.pids"
        wait "$task_child"
        """
        try Data(cancelScript.utf8).write(to:slow);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:slow.path)
        let slowRepo=GitRepository(root:repoRoot,executable:slow),token=OperationCancellation()
        prefs.set(16,forKey:"GitOutputLimitinKiB")
        let operation=Task { @MainActor in
            try await LocalGitCommandProgress.stream(preferences:prefs,update:{published=$0},resultText:{$0},operation:{emit in try await slowRepo.run(["-c","core.foo=ignored","status"],cancellation:token,onOutput:emit).text})
        }
        defer {token.cancel()}
        let pidFile=URL(fileURLWithPath:slow.path+".pids")
        try await wait {FileManager.default.fileExists(atPath:pidFile.path) && published.output.contains("Cancellation phase")}
        let pids=try String(contentsOf:pidFile).split(separator:"\n").compactMap{Int32($0)}
        token.cancel()
        do {_=try await operation.value;throw Failure(description:"Cancellation succeeded")}
        catch let failure as GitCommandCancellationFailure {try require(failure.outputWasDelivered && failure.result.text.contains("Cancellation phase"),"Cancellation lost raw output/delivery metadata")}
        try await wait {pids.allSatisfy{kill($0,0) != 0}}
        try require(published.output.contains("Operation cancelled.") && published.output.utf8.count<=published.limit,"Cancellation summary missing or unbounded")
        try Data(pids.map(String.init).joined(separator:"\n").utf8).write(to:marker)
        // The real Stash progress UI consumes the same failure bridge.
        let invalid=root.appendingPathComponent("not-a-repository");try FileManager.default.createDirectory(at:invalid,withIntermediateDirectories:true)
        let log=ActionLogStore(storageURL:root.appendingPathComponent("action-log.txt"));ProgressActionLog.install(store:log,preferences:prefs)
        let model=StashSaveProgressWindowModel(repository:GitRepository(root:invalid,executable:git),access:nil,options:StashSaveOptions(),followUp:StashSaveFollowUp(),preferences:prefs)
        let owner=StashSaveProgressWindowController(model:model),window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.start()
        try await wait {!model.busy && LocalGitCommandProgress.activeOperations==0}
        guard let text=descendants(window.contentView!).compactMap({$0 as? SubmoduleProgressTextView}).first else{throw Failure(description:"Native progress output missing")}
        try await wait {text.string==model.output}
        guard let completionRange=model.completionRange else {throw Failure(description:"Real progress model lost its completion footer")}
        let completion=(model.output as NSString).substring(with:completionRange)
        try require(!model.success && model.commandFinished && !model.commandSucceeded && model.output.contains("fatal:") && completion.contains("git did not exit cleanly (exit code 128)"),"Real progress model hid the command failure or its actual native completion status")
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()};text.clipboard=board
        let selection=NSRange(location:0,length:min(5,text.string.utf16.count));text.setSelectedRange(selection)
        let menu=text.outputMenu();guard let all=menu.items.first(where:{$0.action==#selector(SubmoduleProgressTextView.copyAllInformation(_:))}) else{throw Failure(description:"Native Copy All action missing")}
        _=NSApp.sendAction(all.action!,to:all.target,from:all)
        try require(board.string(forType:.string)==model.output && text.selectedRange()==selection && all.image != nil,"Named diagnostic native Copy All/icon/selection")
        if ProcessInfo.processInfo.environment["TURTLEGIT_PROGRESS_DIAGNOSTIC_CAPTURE"] != nil {window.setContentSize(NSSize(width:760,height:460));window.contentView?.layoutSubtreeIfNeeded()}
        try await capture(window);owner.close();try await wait {owner.presentationClosed};try require(try log.read().contains(model.output),"Action log lost bounded diagnostic result")
        // A command receipt may finish its footer before a silent producer
        // delivers its error. The preamble must not suppress that later fallback.
        let silent=StashSaveProgressWindowModel(repository:repo,access:nil,options:StashSaveOptions(),followUp:StashSaveFollowUp(),preferences:prefs)
        let silentOwner=StashSaveProgressWindowController(model:silent)
        defer {silentOwner.close()}
        silentOwner.window?.alphaValue=0;silentOwner.window?.orderFront(nil)
        var pending:CheckedContinuation<StashSaveResult,Error>?
        defer {pending?.resume(throwing:OperationCancellationFailure.cancelled);pending=nil}
        silent.saveOperation={_,_,emit,finished in
            emit(GitOutputChunk(stream:.stdout,data:Data("git stash push\n".utf8)))
            finished(StashSaveCommandCompletion(success:false,cancelled:false,exitCode:9,elapsed:0))
            return try await withCheckedThrowingContinuation {pending=$0}
        }
        silent.start();try await wait {pending != nil && silent.commandFinished}
        try require(silent.busy && silent.hasPendingWork && silent.output.contains("exit code 9") && !silent.output.contains("SILENT_STASH_FAILURE"),"Receipt prematurely settled its owned operation")
        pending?.resume(throwing:GitFailure(arguments:["stash","push"],code:9,message:"fatal: SILENT_STASH_FAILURE\n"));pending=nil
        try await wait {!silent.busy && !silent.hasPendingWork}
        try require(!silent.success && silent.output.contains("fatal: SILENT_STASH_FAILURE") && silent.output.contains("git stash push failed (9)") && silent.output.utf8.count<=silent.progressPresentation.outputLimit,"Finished command receipt hid the silent producer's diagnostic")
        try require(silent.output.components(separatedBy:"git did not exit cleanly (exit code 9)").count==2,"Fallback duplicated the native completion footer")
        silentOwner.close();try await wait {silentOwner.presentationClosed}
        try require(try log.read().contains(silent.output),"Closing silent failure lost its complete displayed Action log")
        // Accepted command success remains distinct from a later inspection
        // failure, and that failure must be appended exactly once.
        let inspection=StashSaveProgressWindowModel(repository:repo,access:nil,options:StashSaveOptions(),followUp:StashSaveFollowUp(),preferences:prefs)
        let inspectionOwner=StashSaveProgressWindowController(model:inspection)
        defer {inspectionOwner.close()}
        inspectionOwner.window?.alphaValue=0;inspectionOwner.window?.orderFront(nil)
        inspection.saveOperation={_,_,emit,finished in
            emit(GitOutputChunk(stream:.stdout,data:Data("git stash push\n".utf8)))
            finished(StashSaveCommandCompletion(success:true,cancelled:false,exitCode:0,elapsed:0))
            return try await withCheckedThrowingContinuation {pending=$0}
        }
        inspection.start();try await wait {pending != nil && inspection.commandFinished}
        try require(inspection.commandSucceeded && inspection.busy && inspection.hasPendingWork,"Accepted command lost its result-inspection owner")
        pending?.resume(throwing:GitFailure(arguments:["rev-parse","refs/stash"],code:8,message:"fatal: INSPECTION_FAILURE\n"));pending=nil
        try await wait {!inspection.busy && !inspection.hasPendingWork}
        try require(!inspection.success && inspection.commandSucceeded && inspection.output.components(separatedBy:"INSPECTION_FAILURE").count==2 && inspection.postActions.isEmpty,"Inspection failure duplicated its detail, erased accepted success or exposed follow-ups")
        guard let inspectionCompletion=inspection.completionRange else {throw Failure(description:"Inspection failure lost accepted completion footer")}
        try require((inspection.output as NSString).substring(with:inspectionCompletion).contains("Success"),"Inspection failure rewrote accepted command completion")
        inspectionOwner.close();try await wait {inspectionOwner.presentationClosed}
        try require(try log.read().contains(inspection.output),"Inspection failure Action log lost accepted command/diagnostic")
        // Both the representable identity and native cache retain Unicode spelling.
        let nfc="fatal: café\n",nfd="fatal: cafe\u{301}\n"
        let host=NSHostingView(rootView:SubmoduleProgressOutputView(text:nfc,completed:true,preferences:prefs,clipboard:board))
        let exactWindow=NSWindow(contentRect:.init(x:0,y:0,width:600,height:180),styleMask:[.titled],backing:.buffered,defer:false)
        exactWindow.isReleasedWhenClosed=false;exactWindow.contentView=host;exactWindow.alphaValue=0;exactWindow.orderFront(nil);defer {exactWindow.close()}
        try await wait {descendants(host).compactMap{$0 as? SubmoduleProgressTextView}.first?.string==nfc}
        host.rootView=SubmoduleProgressOutputView(text:nfd,completed:true,preferences:prefs,clipboard:board)
        try await wait {descendants(host).compactMap{$0 as? SubmoduleProgressTextView}.first.map{GitReferenceName.equal($0.string,nfd)}==true}
        let exact=descendants(host).compactMap{$0 as? SubmoduleProgressTextView}.first!;exact.copyAllInformation(nil)
        try require(board.string(forType:.string).map{GitReferenceName.equal($0,nfd)}==true,"Native diagnostic folded Unicode spelling")
        exactWindow.close()
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && Data(contentsOf:repoRoot.appendingPathComponent(".git/index"))==index && Data(contentsOf:repoRoot.appendingPathComponent(".git/config"))==configuration,"Diagnostic presentation changed repository")
        print("PASS: prefixed command diagnostics, silent later failure, bounded live/raw output, captured policy, cancellation/reaped group, native Stash receipt/silent fallback/result/Copy/action log, exact Unicode representable/cache and ownership")
    }
}
