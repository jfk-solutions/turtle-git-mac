// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum SyncInlineProgressVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Sync inline timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return[root]+root.subviews.flatMap{views($0)}}
    static func capture(_ owner:NSWindowController,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_PROGRESS_CAPTURES"],let window=owner.window,let view=window.contentView else{return}
        let appearance=window.appearance
        defer{window.appearance=appearance;view.needsDisplay=true}
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);view.needsDisplay=true;view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:60_000_000)
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw Failure(description:"Native content bitmap unavailable for "+name)}
            view.cacheDisplay(in:view.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else{throw Failure(description:"Native content PNG unavailable for "+name)}
            let directory=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try png.write(to:directory.appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    static func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    static func verify()async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),root=folder.appendingPathComponent("client"),server=folder.appendingPathComponent("server.git")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Inline QA"),("user.email","inline@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file"),original=Data("baseline\n".utf8)
        try original.write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"baseline")
        _ = try await repo.run(["clone","--bare","--",root.path,server.path]);_ = try await repo.run(["remote","add","origin",server.path]);_ = try await repo.run(["fetch","origin"])
        _ = try await repo.run(["config","branch.main.remote","origin"]);_ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        _ = try await repo.run(["branch","other"])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),staged=try await repo.run(["ls-files","--stage","-z"]).stdout
        let suite="TurtleGit.InlineProgress."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(true,forKey:"ConfirmKillProcess");prefs.set(16,forKey:"GitOutputLimitinKiB");prefs.set(0,forKey:"AutoCloseGitProgress")
        DialogGeometry.install(preferences:prefs)
        let enabled=root.appendingPathComponent(".git/inline-enabled"),marker=root.appendingPathComponent(".git/inline-ready"),release=root.appendingPathComponent(".git/inline-release"),mode=root.appendingPathComponent(".git/inline-mode"),wrapper=folder.appendingPathComponent("inline-git")
        let environment=GitRuntime.environment(executable:git).sorted{$0.key<$1.key}.map{"export "+$0.key+"="+quote($0.value)}.joined(separator:"\n")
        let script="""
        #!/bin/sh
        \(environment)
        case "$4" in
        fetch|stash|submodule)
          if [ -f "$3/.git/inline-enabled" ]; then
            printf 'Receiving objects: 10%%\\rReceiving objects: 35%%\\r\\nUnicode '
            printf '\\351\\233'; /bin/sleep 0.03; printf '\\252\\n'
            : > "$3/.git/inline-ready"
            while [ ! -f "$3/.git/inline-release" ]; do /bin/sleep 0.02; done
            if [ "$(cat "$3/.git/inline-mode")" = fail ]; then printf 'controlled inline failure\\n' >&2; exit 17; fi
          fi
          ;;
        esac
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        var owners:[SynchronizationWindowController]=[],heldCheckout:CheckedContinuation<SynchronizationPullCheckout,Error>?
        func own()->SynchronizationWindowController {
            let value=SynchronizationWindowController(repository:GitRepository(root:root,executable:wrapper),access:nil,preferences:prefs)
            value.window!.alphaValue=0;value.window!.appearance=NSAppearance(named:.darkAqua);value.showWindow(nil);value.model.sshSettings.enabled=false;owners.append(value);return value
        }
        func arm(_ failure:Bool=false)throws {
            for path in [marker,release] {try? FileManager.default.removeItem(at:path)}
            try Data((failure ? "fail":"success").utf8).write(to:mode);try Data().write(to:enabled)
        }
        func finishGate()throws {try Data().write(to:release)}
        func footer(_ model:SynchronizationWindowModel,success:Bool,cancelled:Bool=false)throws {
            guard let range=model.completionRange else {throw Failure(description:"Inline completed command has no source footer")}
            let text=(model.commandOutput as NSString).substring(with:range)
            try require(model.percentage==100 && model.commandCompleted && model.commandSucceeded==success && model.commandCancelled==cancelled,"Inline completion lost retained100/result")
            try require(text.contains(" ms @ ") && (success ? text.contains("Success"):!text.contains("Success")),"Inline source footer omitted elapsed/finished or mismatched outcome with Gitexe timing disabled: \(text)")
        }
        func cleanup()async {
            try? finishGate();heldCheckout?.resume(throwing:OperationCancellationFailure.cancelled);heldCheckout=nil
            owners.forEach{$0.close()}
            for _ in 0..<3000 {
                if SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0 && owners.allSatisfy({$0.window?.attachedSheet==nil && $0.window?.sheetParent==nil && $0.window?.isVisible != true}){break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)
        }
        do {
            let owner=own(),model=owner.model
            try await wait {!model.busy && model.outgoing != nil}
            try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.count>=2}
            var finished=0;model.onTransportFinished={_ in finished += 1}
            try arm();model.fetch()
            try await wait {model.percentage==35 && model.commandOutput.contains("Unicode 雪") && FileManager.default.fileExists(atPath:marker.path)}
            try require(model.transportRunning && model.busy && model.currentWork.contains("Receiving") && !model.commandOutput.contains("Receiving objects: 10%"),"Inline live phase/CR/UTF8 failed")
            try require(SynchronizationWindowModel.activeInlineOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Inline command lost worker/Quit ownership")
            try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.isEmpty}
            try await wait {DockProgressRegistry.shared.current?.kind == .running && DockProgressRegistry.shared.current?.percentage==35}
            try await capture(owner,"sync-running")
            try require(!owner.windowShouldClose(owner.window!),"Live Sync command frame closed")
            try finishGate();try await wait {!model.busy && SynchronizationWindowModel.activeInlineOperations==0}
            try footer(model,success:true);try require(finished==1 && model.currentWork=="Success","Inline success completion/callback lost")
            try await wait {DockProgressRegistry.shared.current==nil}
            try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.count>=2}
            let retained=model.commandOutput;model.tab=2;owner.window?.contentView?.layoutSubtreeIfNeeded()
            try await wait {views(owner.window?.contentView).compactMap{$0 as? SubmoduleProgressTextView}.contains{$0.string==retained}}
            try await capture(owner,"sync-completed")
            try require((try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:file))==original,"Fetch presentation changed source/index bytes")
            // Stash and submodule use the same main command surface; no separate
            // child progress or invented parent-only operation is involved.
            try Data("stash working bytes\n".utf8).write(to:file)
            try arm();model.stash(.save,shift:false);try await wait {model.percentage==35 && FileManager.default.fileExists(atPath:marker.path)}
            try finishGate();try await wait {!model.busy};try footer(model,success:true)
            try require(try Data(contentsOf:file)==original,"Stash success did not retain real Git work")
            try arm();model.submodule(.sync,shift:false);try await wait {model.percentage==35 && FileManager.default.fileExists(atPath:marker.path)}
            try finishGate();try await wait {!model.busy};try footer(model,success:true)
            // A failed transport remains visible and retained as a Dock error;
            // the next command replaces the attempt rather than appending twice.
            try arm(true);model.fetch();try await wait {model.percentage==35};try finishGate();try await wait {!model.busy}
            try footer(model,success:false);try require(model.commandOutput.contains("controlled inline failure"),"Failure diagnostic dropped")
            try await wait {DockProgressRegistry.shared.current?.kind == .failed}
            try arm();model.fetch();try await wait {model.percentage==35}
            var reply:((Bool)->Void)?;model.confirmCancellation={reply=$0};model.cancelTransport()
            try require(model.confirmingCancellation && !model.cancelling,"Kill question not owned")
            reply?(false);try require(!model.confirmingCancellation && model.transportRunning,"Rejected Kill stopped producer")
            model.cancelTransport();let late=reply;reply?(true);reply?(true)
            try await wait {!model.busy && SynchronizationWindowModel.activeInlineOperations==0}
            try footer(model,success:false,cancelled:true);let cancelledOutput=model.commandOutput;late?(true)
            try require(model.commandOutput==cancelledOutput,"Late Kill reply rewrote completed attempt")
            owner.close();try await wait {SynchronizationWindowController.activeInlineReleases==0 && DockProgressRegistry.shared.current==nil}
            try? FileManager.default.removeItem(at:enabled)
            // Noncooperative checkout preparation keeps the actual task/grant
            // alive after force-close, and a late throw cannot publish UI state.
            let forced=own();try await wait {!forced.model.busy}
            forced.model.localBranch="other";forced.model.remote="origin";forced.model.remoteBranch="main";forced.model.confirmCheckout={_ in true}
            var token:OperationCancellation?
            forced.model.performCheckout={_,request in token=request;return try await withCheckedThrowingContinuation{heldCheckout=$0}}
            forced.model.fetch(.pull);try await wait {heldCheckout != nil}
            forced.close();let retiredOutput=forced.model.commandOutput
            try require(token?.isCancelled==true && SynchronizationWindowModel.activeInlineOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close discarded noncooperative preparation/Quit fence")
            heldCheckout?.resume(throwing:OperationCancellationFailure.cancelled);heldCheckout=nil
            try await wait {SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0}
            try require(forced.model.closed && forced.model.commandOutput==retiredOutput && forced.window?.isVisible != true,"Late retired preparation published result or reopened frame")
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Inline synchronization moved source HEAD")
            // Real Stash Save legitimately refreshes the index stat/cache data
            // while restoring these baseline bytes. Its indexed modes, object
            // IDs, stages and exact paths must still match the captured index.
            let finalStage=try await repo.run(["ls-files","--stage","-z"]).stdout
            try require(finalStage==staged && (try Data(contentsOf:file))==original,"Inline operations changed staged modes/blobs/stages/paths or tracked working bytes")
            await cleanup()
            try require(SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0 && DockProgressRegistry.shared.ownerCount==0,"Inline worker/release/Dock owner survived cleanup")
            print("PASS: main Sync transport/stash/submodule live phase/header/UTF8, source completed100/timing, retained success/error/cancel, Dock ownership, Kill reply fences and forced-close noncooperative Quit drain")
        } catch {await cleanup();throw error}
    }
}
