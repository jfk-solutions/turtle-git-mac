// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum SubmoduleUpdateRecoveryVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2600 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description: "Submodule recovery did not settle at \(line)")
    }
    static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        func repository(_ name:String) async throws -> GitRepository {
            let root=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repository=GitRepository(root:root,executable:git);_ = try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Recovery QA"),("user.email","recovery@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repository.stage(["file"]);_ = try await repository.commit(message:"base")
            return repository
        }
        let source=try await repository("source"),parent=try await repository("parent")
        let first="group/quoted ' 雪\nfirst",second="other/second",third="unselected"
        for (name,path) in [("one",first),("two",second),("three",third)] {_ = try await parent.run(["-c","protocol.file.allow=always","submodule","add","--name",name,"--",source.root.path,path])}
        _ = try await parent.commit(message:"modules")
        let head=try await parent.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:parent.root.appendingPathComponent(".git/index")),modules=try Data(contentsOf:parent.root.appendingPathComponent(".gitmodules"))
        let wrapper=folder.appendingPathComponent("git-recovery-wrapper")
        let script="""
        #!/bin/sh
        task_operation=no
        for task_argument in "$@"; do
          [ "$task_argument" = update ] && task_operation=update
          [ "$task_argument" = sync ] && task_operation=sync
        done
        if [ "$task_operation" != no ]; then
          printf '%s\\n' "$task_operation" >> "$0.calls"
          if [ "$task_operation" = update ]; then
            task_paths=no
            for task_argument in "$@"; do
              if [ "$task_paths" = yes ]; then printf '%s\\n' attempted >> \(quote(parent.root.path))/"$task_argument/recovery-marker"; fi
              [ "$task_argument" = -- ] && task_paths=yes
            done
          fi
          \(quote(git.path)) "$@"
          task_result=$?
          [ "$task_result" != 0 ] && exit "$task_result"
          if [ -f "$0.fail-first" ] && [ ! -f "$0.failed" ]; then touch "$0.failed"; printf '%s\\n' 'actual selected command completed before injected exit 7' >&2;exit 7;fi
          if [ -f "$0.pause-second" ] && [ "$(/usr/bin/wc -l < "$0.calls" | /usr/bin/tr -d ' ')" = 2 ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.started"
            wait "$task_child"
          fi
          exit 0
        fi
        exec \(quote(git.path)) "$@"
        """
        try script.write(to:wrapper,atomically:false,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repository=GitRepository(root:parent.root,executable:wrapper),suite="TurtleGit.SubmoduleRecovery."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        preferences.set(0,forKey:"AutoCloseGitProgress");preferences.set(false,forKey:"ConfirmKillProcess");DialogGeometry.install(preferences:preferences)
        var updates:[SubmoduleUpdateProgressWindowController]=[],syncs:[SubmoduleSyncWindowController]=[]
        let owner=NSWindow(contentRect:.init(x:0,y:0,width:800,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.appearance=NSAppearance(named:.darkAqua)
        defer {for update in updates {update.close()};for sync in syncs {sync.close()};owner.close();preferences.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        var options=SubmoduleUpdateOptions();options.noFetch=true
        let pointer=MemoryLayout<UnsafeRawPointer?>.size,fixed=[wrapper.path,"--literal-pathspecs","-C",parent.root.path,"-c","core.precomposeunicode=false"]+options.arguments(paths:[])
        let limit=fixed.reduce(pointer) {$0+$1.utf8.count+1+pointer}+[first,second,third].map {$0.utf8.count+1+pointer}.max()!
        func resetFlags() throws {for suffix in [".calls",".started",".failed",".fail-first",".pause-second"] {let path=wrapper.path+suffix;if FileManager.default.fileExists(atPath:path){try FileManager.default.removeItem(atPath:path)}}}
        func newUpdate(_ paths:[String])->SubmoduleUpdateProgressWindowController {
            let update=SubmoduleUpdateProgressWindowController(repository:repository,access:nil,paths:paths,options:options,preferences:preferences)
            update.window?.alphaValue=0;update.window?.appearance=owner.appearance;update.model.argumentByteLimit=limit;updates.append(update);return update
        }
        func newSync(_ paths:[String])->SubmoduleSyncWindowController {
            let sync=SubmoduleSyncWindowController(repository:repository,access:nil,scope:paths,preferences:preferences)
            sync.window?.alphaValue=0;sync.window?.appearance=owner.appearance;syncs.append(sync);return sync
        }
        do {
            try Data().write(to:URL(fileURLWithPath:wrapper.path+".fail-first"))
            let update=newUpdate([first,second]);var receipts:[SubmoduleUpdateResult]=[],successes=0
            update.model.onAttemptCompleted={receipts.append($0)};update.model.onUpdated={_ in successes += 1}
            update.model.start();update.model.start();try await wait {!update.model.busy && SubmoduleUpdateProgressWindowModel.activeOperations==0}
            try require(receipts.count==1 && successes==0 && receipts[0].entries.map(\.exitCode)==[7,0] && receipts[0].successfulPaths==[second],"Partial batched Update suppressed refresh, advanced success, stopped later batch or duplicated result")
            try require(receipts[0].attemptedPaths==[first,second] && !FileManager.default.fileExists(atPath:parent.root.appendingPathComponent(third+"/recovery-marker").path),"Explicit batch selection widened to an unchecked submodule")
            try require(FileManager.default.fileExists(atPath:parent.root.appendingPathComponent(first+"/recovery-marker").path),"Partial real update effect missing")
            update.model.close();try resetFlags()
            for name in ["one","two"] {_ = try await parent.run(["config","submodule."+name+".url","https://stale.invalid/"+name])}
            try Data().write(to:URL(fileURLWithPath:wrapper.path+".fail-first"))
            let sync=newSync([first,second]);var syncReceipts:[SubmoduleSyncResult]=[],syncSuccesses=0
            sync.model.onAttemptCompleted={syncReceipts.append($0)};sync.model.onSynced={_ in syncSuccesses += 1};sync.model.start()
            try await wait {!sync.model.busy && SubmoduleSyncWindowModel.activeOperations==0}
            let firstURL=try await parent.run(["config","--get","submodule.one.url"]).text.trimmingCharacters(in:.newlines)
            try require(syncReceipts.count==1 && syncSuccesses==0 && syncReceipts[0].entries.map(\.exitCode)==[7,0] && firstURL==source.root.path,"Partial Sync failed to refresh actual changed config or advanced success")
            sync.model.close()
            // Forced closure must keep attempted receipts and process ownership,
            // while success callbacks and later selected commands stay retired.
            for syncing in [false,true] {
                try resetFlags();try Data().write(to:URL(fileURLWithPath:wrapper.path+".pause-second"))
                let marker=URL(fileURLWithPath:wrapper.path+".started")
                var attempts=0,completed=0,cancelledReceipt=false
                let active:NSWindowController
                if syncing {
                    let value=newSync([first,second,third]);active=value
                    value.model.onAttemptCompleted={attempts += 1;cancelledReceipt=$0.cancelled && $0.entries.map {$0.command.scope} == [first,second]}
                    value.model.onSynced={_ in completed += 1};value.model.start()
                } else {
                    let value=newUpdate([first,second,third]);active=value
                    value.model.onAttemptCompleted={attempts += 1;cancelledReceipt=$0.cancelled && $0.attemptedPaths == [first,second] && $0.successfulPaths == [first]}
                    value.model.onUpdated={_ in completed += 1};value.model.start()
                }
                try await wait {FileManager.default.fileExists(atPath:marker.path)}
                let pids=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap {Int32($0)}
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit lost active submodule ownership")
                active.close()
                try await wait {SubmoduleUpdateProgressWindowModel.activeOperations==0 && SubmoduleSyncWindowModel.activeOperations==0}
                try require(attempts==1 && completed==0 && cancelledReceipt && pids.count==2 && pids.allSatisfy {kill($0,0) != 0},"Forced close lost partial receipt, advanced success or leaked process children")
                try require(try String(contentsOf:URL(fileURLWithPath:wrapper.path+".calls")).split(separator:"\n").count==2,"Cancellation started a later selected command")
            }
            try resetFlags()
            try Data("main\n".utf8).write(to:parent.root.appendingPathComponent(".git/BISECT_START"))
            let bisect=newUpdate([first]);var events:[String]=[],operations:[BisectOperation]=[]
            bisect.onClosed={events.append("closed")}
            bisect.model.onBisect={operation in
                operations.append(operation);events.append("bisect")
                if owner.attachedSheet != nil || bisect.window?.sheetParent != nil || SubmoduleUpdateProgressWindowController.activeChildReleases != 0 || bisect.model.presentationPreferences !== preferences {events.append("invalid owner")}
            }
            owner.orderFront(nil);owner.beginSheet(bisect.window!,completionHandler:nil);bisect.model.start()
            try await wait {!bisect.model.busy && bisect.model.postActions.contains(.reset)}
            bisect.model.perform(.reset);bisect.model.perform(.reset)
            try await wait {operations.count==1 && SubmoduleUpdateProgressWindowController.activeChildReleases==0}
            try require(operations==[.reset] && events==["closed","bisect"],"Bisect post-action repeated or dispatched before native sheet release")
            let after=try await parent.run(["rev-parse","HEAD"]).stdout
            try require(after==head && (try Data(contentsOf:parent.root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:parent.root.appendingPathComponent(".gitmodules")))==modules,"Update/Sync changed parent HEAD/index/gitmodules")
            owner.orderOut(nil)
            try require(!updates.contains {$0.window?.isVisible==true} && !syncs.contains {$0.window?.isVisible==true},"Owned recovery window remained presented")
        } catch {
            for update in updates {update.close()};for sync in syncs {sync.close()};owner.orderOut(nil)
            try? await wait {SubmoduleUpdateProgressWindowModel.activeOperations==0 && SubmoduleSyncWindowModel.activeOperations==0 && SubmoduleUpdateProgressWindowController.activeChildReleases==0}
            throw error
        }
    }
}
