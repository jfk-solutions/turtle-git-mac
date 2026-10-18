// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@MainActor enum ResetOperationVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String? {message}}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2500 {if ready() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Reset operation did not settle at \(line)")
    }
    static func click(_ alert:NSAlert?,_ title:String) throws {
        guard let button=alert?.buttons.first(where:{$0.title == title}) else {throw Failure(message:"Native Reset alert button missing: \(title)")}
        button.performClick(nil)
    }
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Reset operation QA"),("user.email","reset@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.warnAmbiguousRefs","true")] {_ = try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file")
        try Data("base\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("next\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"next")
        let next=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["branch","collision",next]);_ = try await repo.run(["tag","collision",base])
        try Data("staged\n".utf8).write(to:file);try await repo.stage(["file"]);try Data("working\n".utf8).write(to:file)
        let suite="TurtleGit.ResetOperation.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"ConfirmKillProcess")
        defer {prefs.removePersistentDomain(forName:suite)}
        var owners:[ResetWindowController]=[],progresses:[ResetProgressWindowController]=[],hosts:[NSWindow]=[],pids:[Int32]=[]
        func host()->NSWindow {
            let value=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            value.isReleasedWhenClosed=false;value.alphaValue=0;value.appearance=NSAppearance(named:.darkAqua);value.orderFront(nil);hosts.append(value);return value
        }
        func drained()->Bool {ResetWindowModel.activeReads == 0 && SwitchWindowModel.activeReads == 0 && ResetProgressWindowModel.activeOperations == 0 && ResetWindowController.activeChildReleases == 0}
        func cleanup() async throws {
            owners.forEach {$0.close()};progresses.forEach {$0.close()}
            try await wait {drained() && pids.allSatisfy {kill($0,0) != 0} && owners.allSatisfy {$0.window?.attachedSheet == nil && $0.window?.sheetParent == nil && $0.window?.isVisible != true} && progresses.allSatisfy {$0.window?.attachedSheet == nil && $0.window?.sheetParent == nil && $0.window?.isVisible != true}}
            for window in hosts {if let sheet=window.attachedSheet {window.endSheet(sheet);sheet.close()};window.close()}
            try await wait {hosts.allSatisfy {$0.attachedSheet == nil && !$0.isVisible}}
        }
        do {
            let parent=host(),owner=ResetWindowController(repository:repo,access:nil,revision:"collision",preferences:prefs);owners.append(owner)
            owner.window?.alphaValue=0;owner.window?.appearance=parent.appearance
            owner.model.load();try await wait {!owner.model.busy && !owner.model.chooser.busy}
            parent.beginSheet(owner.window!,completionHandler:nil)
            let model=owner.model
            model.mode = .hard
            let oldField=model.field(\SwitchWindowModel.commitRevision,context:model.formContext),oldMode=model.modeBinding(context:model.formContext)
            let original=model.chooser.commitRevision
            model.confirmingQuit=true;oldField.wrappedValue=next;oldMode.wrappedValue = .soft;model.reset();model.showCommitPicker();model.showModifiedFiles()
            try require(model.chooser.commitRevision == original && model.mode == .hard && !model.busy && owner.commitPicker == nil && owner.modifiedComparison == nil && !owner.windowShouldClose(owner.window!),"Deferred Quit allowed a form change/action/close")
            model.confirmingQuit=false;oldField.wrappedValue=next;oldMode.wrappedValue = .soft
            try require(model.chooser.commitRevision == original && model.mode == .hard,"Held form receipts survived Quit roundtrip")
            model.reset();try await wait {owner.hardAlert != nil && model.confirmingHard}
            try require(owner.hardAlert?.window.alphaValue == 0 && owner.hardAlert?.window.appearance == owner.window?.appearance && !owner.windowShouldClose(owner.window!) && model.progress == nil,"Hard warning lost private appearance or owner gate")
            let heldField=model.field(\SwitchWindowModel.commitRevision,context:model.formContext)
            heldField.wrappedValue=next
            try require(model.chooser.commitRevision == original,"Hard confirmation allowed a delayed native field write")
            try click(owner.hardAlert,"Cancel");try await wait {!model.confirmingHard && owner.window?.attachedSheet == nil}
            heldField.wrappedValue=next
            try require(model.chooser.commitRevision == original,"Canceled warning revived a held field receipt")
            var completed=0,actions:[ResetPostAction]=[],detachedAtAction=false
            model.onReset={_ in completed += 1}
            model.onPostAction={action in
                detachedAtAction=parent.attachedSheet == nil && owner.window?.sheetParent == nil && owner.window?.attachedSheet == nil && ResetWindowController.activeChildReleases == 0
                actions.append(action)
            }
            model.reset();try await wait {owner.hardAlert != nil};try click(owner.hardAlert,"Reset")
            try await wait {owner.progressController != nil && model.progress?.busy == false}
            guard let result=model.progress,let child=owner.progressController else {throw Failure(message:"Accepted Reset progress missing")}
            progresses.append(child)
            try require(result.success && result.plan.revision == base && result.plan.mode == .hard && result.postActions == [.clean] && completed == 0 && child.window?.alphaValue == 0 && child.window?.appearance == owner.window?.appearance && child.window?.sheetParent === owner.window,"Captured ambiguous target/native result failed: \(result.output)")
            try require(result.postActions.map(\.icon) == [.clean],"Source Reset postaction icon changed")
            result.confirmingQuit=true;result.perform(.clean);result.close()
            try require(actions.isEmpty && completed == 0 && model.progress === result && !child.windowShouldClose(child.window!),"Deferred Quit dispatched/closed Reset result")
            result.confirmingQuit=false;result.perform(.clean);result.perform(.clean)
            try await wait {actions.count == 1 && completed == 1 && parent.attachedSheet == nil && model.progress == nil && drained()}
            try require(actions == [.clean] && detachedAtAction && (try String(contentsOf:file)) == "base\n","Followup ran before actual native sheet drain or repeated")

            // A real owned Git reset is held in a private helper. Both alert
            // answers use native buttons, and cancellation drains its process group.
            let helper=root.appendingPathComponent("slow-reset"),pause=URL(fileURLWithPath:root.appendingPathComponent("slow-reset").path+".pause"),marker=URL(fileURLWithPath:root.appendingPathComponent("slow-reset").path+".started")
            let quote="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
            let script="""
            #!/bin/sh
            task_reset=
            for task_argument do if [ "$task_argument" = reset ]; then task_reset=1; fi; done
            if [ -n "$task_reset" ] && [ -f "$0.pause" ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              wait "$task_child"
            fi
            exec \(quote) "$@"
            """
            try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            let slowRepo=GitRepository(root:root,executable:helper)
            try Data().write(to:pause)
            let slow=ResetProgressWindowModel(repository:slowRepo,plan:try await repo.prepareReset(to:base,mode:.mixed),preferences:prefs),slowController=ResetProgressWindowController(model:slow)
            progresses.append(slowController);slowController.window?.alphaValue=0;slowController.window?.appearance=NSAppearance(named:.darkAqua)
            let slowParent=host();slowParent.beginSheet(slowController.window!,completionHandler:nil);slow.start()
            try await wait {FileManager.default.fileExists(atPath:marker.path)}
            pids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap {Int32($0)}
            try require(pids.count == 2 && pids.allSatisfy {kill($0,0) == 0},"Reset helper group missing")
            slow.confirmingQuit=true;slow.cancel();try require(!slow.confirmingCancellation && slowController.cancellationAlert == nil,"Quit opened cancellation sheet");slow.confirmingQuit=false
            slow.cancel();try await wait {slowController.cancellationAlert != nil}
            try require(slow.confirmingCancellation && slowController.cancellationAlert?.window.alphaValue == 0 && slowController.cancellationAlert?.window.appearance == slowController.window?.appearance && !slowController.windowShouldClose(slowController.window!),"Held cancellation sheet lost appearance/ownership")
            try click(slowController.cancellationAlert,"No");try await wait {!slow.confirmingCancellation && slowController.window?.attachedSheet == nil}
            try require(slow.busy && !slow.cancelling,"No canceled owned reset")
            slow.cancel();try await wait {slowController.cancellationAlert != nil};try click(slowController.cancellationAlert,"Yes")
            try await wait {!slow.busy && ResetProgressWindowModel.activeOperations == 0 && pids.allSatisfy {kill($0,0) != 0}}
            try require(slow.cancelled && !slow.success && slow.postActions == [.retry] && slowController.window?.attachedSheet == nil,"Yes failed to drain/cancel owned reset")
            try FileManager.default.removeItem(at:pause);slow.perform(.retry);slow.perform(.retry);try await wait {!slow.busy}
            try require(slow.success && slow.postActions.isEmpty,"Captured Reset retry did not recover")
            slow.close();try await wait {slowParent.attachedSheet == nil}

            try FileManager.default.removeItem(at:marker);try Data().write(to:pause)
            let retiring=ResetProgressWindowModel(repository:slowRepo,plan:try await repo.prepareReset(to:base,mode:.mixed),preferences:prefs),retiringController=ResetProgressWindowController(model:retiring)
            progresses.append(retiringController);retiringController.window?.alphaValue=0;retiringController.window?.orderFront(nil)
            var lateChanges=0;retiring.onChanged={_ in lateChanges += 1};retiring.start()
            try await wait {FileManager.default.fileExists(atPath:marker.path)}
            let retiringPIDs=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap {Int32($0)}
            try require(retiringPIDs.count == 2,"Retiring Reset helper group missing")
            pids += retiringPIDs
            retiringController.close()
            try require(ResetProgressWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close released actual Reset operation/Quit ownership")
            try await wait {drained() && pids.allSatisfy {kill($0,0) != 0}}
            try require(lateChanges == 0,"Retired Reset published a late callback")
            try await cleanup()
            print("PASS: Reset canonical ambiguous target, guarded native form/Quit receipts, actual Hard/Cancel sheets and captured appearance, one-shot Clean after both actual sheets detach, private helper No/Yes/cancel/retry/forced-close with actual operation/Quit/process drain")
        } catch {let original=error;do {try await cleanup()} catch {throw Failure(message:"\(original); cleanup: \(error)")};throw original}
    }
}
