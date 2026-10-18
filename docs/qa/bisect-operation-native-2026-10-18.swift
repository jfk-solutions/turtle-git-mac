// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum BisectOperationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {for _ in 0..<2600 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Bisect operation timeout at \(line)")}
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repository=GitRepository(root:root,executable:git)
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Bisect Native"),("user.email","bisect@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
        var hashes:[String]=[];let file=root.appendingPathComponent("file")
        for index in 0..<8 {try Data("\(index)\n".utf8).write(to:file);try await repository.stage(["file"]);_ = try await repository.commit(message:"step \(index)");hashes.append(try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines))}
        try Data().write(to:root.appendingPathComponent(".gitmodules"))
        let suite="TurtleGit.BisectOperation."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        preferences.set(0,forKey:"AutoCloseGitProgress");preferences.set(true,forKey:"ShowGitexeTimings");preferences.set(true,forKey:"ShowAppContextMenuIcons");DialogGeometry.install(preferences:preferences)
        var owners:[BisectWindowController]=[]
        let parent=NSWindow(contentRect:.init(x:0,y:0,width:800,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false;parent.alphaValue=0;parent.appearance=NSAppearance(named:.darkAqua)
        defer {for owner in owners {owner.close()};parent.close();preferences.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        func owner(_ repo:GitRepository)->BisectWindowController {
            let value=BisectWindowController(repository:repo,access:nil,good:hashes[0],bad:"HEAD",preferences:preferences)
            value.window?.alphaValue=0;value.window?.appearance=parent.appearance;owners.append(value);return value
        }
        let controller=owner(repository),model=controller.model,window=controller.window!
        var attempts:[BisectMutationResult]=[];model.onAttemptCompleted={attempts.append($0)}
        do {
            window.orderFront(nil);try await wait {!model.busy};window.contentView?.layoutSubtreeIfNeeded()
            try await wait {views(window.contentView!).compactMap {$0 as? NSComboBox}.count==2}
            let binding=model.revision(\.good,context:model.formContext),old=model.formContext,good=model.good
            model.confirmingQuit=true;binding.wrappedValue="HEAD";model.start(context:old);controller.chooseRevision(good:true)
            try require(model.good==good && !model.busy && !model.hasPicker && !model.canStart && !controller.windowShouldClose(window),"Quit allowed native review/picker/close mutation")
            model.confirmingQuit=false;binding.wrappedValue="HEAD";model.start(context:old)
            try require(model.good==good && !model.busy,"Retired form epoch revived after Quit")
            controller.chooseRevision(good:true);try await wait {window.attachedSheet?.delegate is LogWindowController}
            let picker=window.attachedSheet!.delegate as! LogWindowController
            try require(picker.window?.alphaValue==0 && picker.model.colorPreferences === preferences,"Revision picker escaped hidden/private owner")
            picker.close();try await wait {!model.hasPicker && window.attachedSheet==nil}
            try Data("dirty aborted\n".utf8).write(to:file);model.start()
            try await wait {window.attachedSheet != nil}
            let abortSheet=window.attachedSheet!
            try require(abortSheet.alphaValue==0,"Stash question escaped hidden owner")
            window.endSheet(abortSheet,returnCode:.alertFirstButtonReturn)
            try await wait {!model.busy}
            try require(attempts.isEmpty && !model.showingProgress && (try Data(contentsOf:file))==Data("dirty aborted\n".utf8),"Aborted review dispatched a mutation or lost dirty bytes")
            model.start();try await wait {window.attachedSheet != nil}
            window.endSheet(window.attachedSheet!,returnCode:.alertSecondButtonReturn)
            try await wait {!model.busy && BisectWindowModel.activeOperations==0}
            try require(attempts.count==2 && attempts.allSatisfy(\.success) && model.lastExitCode==0 && model.percentage==100 && model.currentWork=="Success" && model.completionRange != nil,"Actual Stash/Start receipts or completed100 status missing")
            try require(model.output.contains(" ms @ ") && model.output.contains("Success (") && (model.output as NSString).substring(with:model.completionRange!).contains("Success"),"Completed timing/footer range missing")
            var handoffs=0;model.onSubmoduleUpdate={handoffs += 1}
            try require(model.postActions == [.submoduleUpdate,.operation(.good),.operation(.bad),.operation(.skip),.operation(.reset)],"Source default/menu action order missing")
            for action in model.postActions {try require(model.icon(action).image(size:16) != nil,"Source continuation icon missing")}
            let menuContext=model.formContext,commands=attempts.count
            model.confirmingQuit=true;model.perform(.operation(.good),context:menuContext);model.updateSubmodules();model.confirmingQuit=false
            model.perform(.operation(.good),context:menuContext)
            try require(attempts.count==commands && !model.busy && handoffs==0,"Retired split-menu/Quit callback executed")
            preferences.set(false,forKey:"ShowGitexeTimings");model.perform(.reset)
            try await wait {!model.busy}
            try require(model.state?.active==false && model.output.hasSuffix("\nSuccess\n") && model.percentage==100 && model.postActions==[.submoduleUpdate],"Reset completion/actions/timing preference differ from source")
            var events:[String]=[];controller.onClosed={events.append("closed")}
            model.onSubmoduleUpdate={
                handoffs += 1;events.append("update")
                if parent.attachedSheet != nil || window.sheetParent != nil || !model.retired || BisectWindowController.activeChildReleases != 0 || model.preferences !== preferences {events.append("invalid owner")}
            }
            window.orderOut(nil);parent.orderFront(nil);parent.beginSheet(window,completionHandler:nil)
            let handoffContext=model.formContext
            model.perform(.submoduleUpdate,context:handoffContext);model.perform(.submoduleUpdate,context:handoffContext)
            try await wait {handoffs==1 && BisectWindowController.activeChildReleases==0}
            try require(events==["closed","update"],"Submodule continuation repeated or ran before owner sheet detachment")
            parent.orderOut(nil)
            // Real cancellation and forced closure use an owned wrapper/sleeper;
            // Start's first command has already created a recoverable session.
            let wrapper=root.appendingPathComponent("bisect-operation-git"),marker=root.appendingPathComponent("bisect-ready")
            let script="""
            #!/bin/sh
            if [ "$4-$5" = bisect-good ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null;wait "$task_child" 2>/dev/null;exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$3/bisect-ready"
              wait "$task_child"
            fi
            exec '\(git.path.replacingOccurrences(of:"'",with:"'\\''"))' "$@"
            """
            try script.write(to:wrapper,atomically:false,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
            let wrapped=GitRepository(root:root,executable:wrapper)
            for forced in [false,true] {
                try? FileManager.default.removeItem(at:marker)
                let active=owner(wrapped),live=active.model;var receipts:[BisectMutationResult]=[],legacy=0
                live.onAttemptCompleted={receipts.append($0)};live.onChanged={_ in legacy += 1}
                try await wait {!live.busy};live.start();try await wait {FileManager.default.fileExists(atPath:marker.path)}
                let pids=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap {Int32($0)},before=live.output
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Active Bisect lost Quit ownership")
                if forced {active.close()}
                else {
                    preferences.set(true,forKey:"ConfirmKillProcess");live.cancel()
                    try await wait {active.window?.attachedSheet != nil}
                    let question=active.window!.attachedSheet!
                    try require(question.alphaValue==0,"Cancel question escaped hidden owner")
                    active.window!.endSheet(question,returnCode:.alertFirstButtonReturn)
                }
                try await wait {!live.busy && BisectWindowModel.activeOperations==0}
                try require(receipts.count==1 && receipts[0].cancelled && receipts[0].commands.count==2 && pids.count==2 && pids.allSatisfy {kill($0,0) != 0},"Cancelled/retired mutation receipt or owned process drain missing")
                if forced {try require(legacy==0 && live.output==before,"Forced owner received late legacy presentation")}
                else {try require(live.cancelled && live.currentWork=="User cancelled" && live.percentage==100 && live.postActions==[.operation(.reset)],"Cancelled result lost completed status/Reset")}
                _ = try await repository.bisect(.reset);active.close()
            }
            let final=try await repository.bisectState(),stashes=try await repository.run(["stash","list","--format=%H"]).text.split(separator:"\n")
            try require(!final.active && final.head==hashes.last && stashes.count==1 && BisectWindowModel.activeOperations==0,"Final cleanup lost original HEAD/stash or retained operations")
        } catch {
            for owner in owners {owner.close()};parent.orderOut(nil)
            try? await wait {BisectWindowModel.activeOperations==0 && BisectWindowController.activeChildReleases==0}
            throw error
        }
    }
}
