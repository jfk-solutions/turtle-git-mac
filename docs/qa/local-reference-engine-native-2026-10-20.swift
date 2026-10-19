// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum LocalReferenceEngineVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Local reference native timeout at \(line)")
    }
    static func drained()->Bool {ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeMutations==0 && CommitContainingReferencesWindowController.activeOperations==0 && LocalGitCommandProgress.activeOperations==0 && LogWindowModel.activeHistoryDeletions==0 && ReferenceLogWindowModel.activeRevisionReads==0 && SynchronizationWindowModel.activeHistoryDeletions==0 && RevisionGraphWindowModel.activeOperations==0}
    static func verify(root:URL,git:URL,helper:URL,graphLayout:URL)async throws {
        let fm=FileManager.default,work=root.appendingPathComponent("repository")
        try fm.createDirectory(at:work,withIntermediateDirectories:true)
        let plain=GitRepository(root:work,executable:git)
        _ = try await plain.run(["init","-b","main"])
        for (key,value) in [("user.name","Local Reference QA"),("user.email","local@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_ = try await plain.run(["config",key,value])}
        let file=work.appendingPathComponent("file")
        try Data("base\n".utf8).write(to:file);try await plain.stage(["file"]);_ = try await plain.commit(message:"base")
        let base=try await plain.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await plain.run(["branch","old",base]);_ = try await plain.run(["tag","-a","annotated","-m","annotation",base])
        try Data("next\n".utf8).write(to:file);try await plain.stage(["file"]);_ = try await plain.commit(message:"next")
        let head=try await plain.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await plain.run(["checkout","-b","unmerged",base]);_ = try await plain.run(["commit","--allow-empty","-m","side"]);_ = try await plain.run(["checkout","main"])
        _ = try await plain.run(["symbolic-ref","refs/tags/symbolic","refs/tags/annotated"])
        // Packed refs retain canonical peers even on normalization-aliasing filesystems.
        let nfc="refs/tags/Café/one",nfd="refs/tags/Cafe\u{301}/one"
        _ = try await plain.run(["pack-refs","--all","--prune"])
        let packed=work.appendingPathComponent(".git/packed-refs")
        var packedText=try String(contentsOf:packed,encoding:.utf8)
        packedText=packedText.replacingOccurrences(of:" sorted",with:"")+head+" "+nfc+"\n"+head+" "+nfd+"\n"
        try Data(packedText.utf8).write(to:packed)
        let suite="TurtleGit.LocalReference.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress")
        let wrapper=root.appendingPathComponent("helper"),calls=root.appendingPathComponent("helper.calls"),hold=root.appendingPathComponent("helper.hold"),ready=root.appendingPathComponent("helper.ready")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        printf '%s\\n' "$@" >> "$0.calls"
        if [ -f "$0.hold" ]; then
          /bin/sh -c 'while [ -f "$1" ]; do /bin/sleep 0.1; done' hold "$0.hold" &
          child=$!
          trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$child" > "$0.ready.tmp"
          /bin/mv "$0.ready.tmp" "$0.ready"
          wait "$child"
        fi
        exec \(quote(helper.path)) "$@"
        """
        try script.write(to:wrapper,atomically:true,encoding:.utf8);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repo=GitRepository(root:work,executable:git,libgit2Configuration:.init(helperURL:wrapper)),grant=RepositoryAccessLease(url:work)
        func use(_ mask:UInt32,enabled:Bool=true){prefs.set(enabled,forKey:"UseLibgit2");prefs.set(mask,forKey:"UseLibgit2_mask")}
        func log()throws->String {fm.fileExists(atPath:calls.path) ? try String(contentsOf:calls):""}
        func clear()throws {try Data().write(to:calls)}
        var browsers=[ReferenceBrowserWindowController](),contains=[CommitContainingReferencesWindowController]()
        var confirmation:CheckedContinuation<Bool,Never>?,late:CheckedContinuation<[GitReferenceName],Error>?
        defer {
            confirmation?.resume(returning:false);late?.resume(throwing:OperationCancellationFailure.cancelled)
            for owner in browsers {owner.model.invalidate();owner.close()};for owner in contains {owner.close()}
            prefs.removePersistentDomain(forName:suite)
        }
        @MainActor func browser(_ initial:String="refs/heads/main")->ReferenceBrowserWindowController {
            let value=ReferenceBrowserWindowController(repository:repo,access:grant,initial:initial,preferences:prefs,picking:false){_ in}
            browsers.append(value);value.window?.orderFront(nil);return value
        }
        @MainActor func settled(_ owner:ReferenceBrowserWindowController)async throws {try await wait{!owner.model.busy && ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeMutations==0}}
        @MainActor func choose(_ owner:ReferenceBrowserWindowController,_ names:[String])throws {
            guard let first=names.first,let snapshot=owner.model.snapshot else{throw Failure(description:"No browser snapshot")}
            owner.model.setFolder(snapshot.initialSelection(first).folder)
            let exact=Set(names.map{GitReferenceName($0)})
            owner.model.select(exact,last:names.last.map{GitReferenceName($0)})
            try require(owner.model.selection==exact && owner.model.canDelete,"Native exact selection unavailable")
        }
        // Actual Browser inventory, metadata and source CLI merged/unmerged gate.
        use(1<<18);let browse=browser();browse.model.load();try await settled(browse)
        try require(browse.model.error==nil && browse.model.snapshotBackendIdentity != nil && (try log()).contains("turtlegit-local-refs"),"Browser selected engine not used")
        let selectedIdentity=browse.model.snapshotBackendIdentity,selectedNames=browse.model.snapshot!.references.map{Data($0.name.rawValue.utf8)}
        try require(selectedNames.contains(Data(nfc.utf8)) && selectedNames.contains(Data(nfd.utf8)),"Browser normalized canonical reference peers")
        try clear();browse.model.mergeFilter = .unmerged;browse.model.load();try await settled(browse)
        try require((try log()).isEmpty && browse.model.snapshot?.references.map(\.name)==[GitReferenceName("refs/heads/unmerged")],"Unmerged Browser did not retain source CLI route")
        browse.model.mergeFilter = .merged;browse.model.load();try await settled(browse)
        try require((try log()).isEmpty && browse.model.snapshot?.references.contains(where:{$0.name=="refs/heads/unmerged"})==false,"Merged Browser widened selection")
        use(0,enabled:false);browse.model.mergeFilter = .all;browse.model.load();try await settled(browse)
        try require(Set(browse.model.snapshot!.references.map{Data($0.name.rawValue.utf8)})==Set(selectedNames) && browse.model.snapshotBackendIdentity != selectedIdentity,"CLI/helper Browser metadata names diverged")
        // A read accepted with bit18 keeps that policy while its real process waits.
        use(1<<18);try clear();try Data().write(to:hold);browse.model.load()
        try await wait{fm.fileExists(atPath:ready.path) && browse.model.busy}
        use(0,enabled:false);try fm.removeItem(at:hold);try await settled(browse)
        try require(browse.model.snapshotBackendIdentity==selectedIdentity && (try log()).contains("turtlegit-local-refs"),"Accepted inventory changed engine while awaiting helper")
        try fm.removeItem(at:ready)
        // Completion is master-selected even when bit18 is off; contains16 is separate.
        use(0);try clear()
        let refs=CommitContainingReferencesWindowController(repository:repo,access:grant,revision:base,preferences:prefs);contains.append(refs);refs.window?.orderFront(nil);refs.refresh();try await wait{!refs.busy}
        try require(refs.snapshot?.hash==base && refs.rows.contains("refs/tags/annotated") && (try log()).contains("turtlegit-ref-names") && !(try log()).contains("turtlegit-containing-refs"),"Master-on/18-off completion or default-off Contains16 wrong")
        let namesIdentity=refs.completionBackendIdentity
        _ = try await plain.run(["branch","completion-later",base])
        refs.refresh();try await wait{!refs.busy}
        try require(!refs.revision.objectValues.contains{($0 as? String)=="refs/heads/completion-later"},"Same-engine completion cache unexpectedly refreshed")
        use(GitLibGit2Configuration.defaultMask);try clear();refs.refresh();try await wait{!refs.busy}
        try require(refs.snapshot?.hash==base && (try log()).contains("turtlegit-ref-names") && !(try log()).contains("turtlegit-containing-refs"),"Source-default Contains16 was enabled")
        use(1<<16);refs.refresh();try await wait{!refs.busy}
        try require(refs.snapshot?.hash==base && refs.completionBackendIdentity != namesIdentity && refs.revision.objectValues.contains{($0 as? String)=="refs/heads/completion-later"} && (try log()).contains("turtlegit-containing-refs"),"Contains engine/cache capture missing")
        use(0,enabled:false);try clear();refs.refresh();try await wait{!refs.busy}
        try require((try log()).isEmpty && refs.snapshotBackendIdentity=="local-references-cli-v1","Contains cache retained previous engine")
        // A late completion may not replace a newer read or closed controller.
        refs.readCompletion={_ in try await withCheckedThrowingContinuation{late=$0}}
        refs.refresh(reloadCompletion:true);try await wait{late != nil};refs.readCompletion=nil;refs.refresh();try await wait{!refs.busy}
        late?.resume(returning:[GitReferenceName("refs/heads/stale")]);late=nil
        try await wait{CommitContainingReferencesWindowController.activeOperations==0}
        try require(!refs.revision.objectValues.contains{($0 as? String)=="refs/heads/stale"},"Late completion replaced current cache")
        // Accepted deletion uses source8 despite preference changes during warning.
        use(GitLibGit2Configuration.defaultMask);try clear();browse.model.load();try await settled(browse);try choose(browse,["refs/tags/symbolic"])
        browse.model.confirmDeletion={_ in await withCheckedContinuation{confirmation=$0}}
        browse.model.deleteChosen();try await wait{confirmation != nil};use(0,enabled:false);confirmation?.resume(returning:true);confirmation=nil;try await settled(browse)
        let symbolic=try await plain.run(["symbolic-ref","-q","refs/tags/symbolic"],successfulExitCodes:0...128)
        let retained=try await plain.run(["rev-parse","refs/tags/annotated"]).text.trimmingCharacters(in:.newlines)
        try require(symbolic.exitCode != 0 && !retained.isEmpty && (try log()).contains("turtlegit-delete-local-ref") && browse.model.error==nil,"Symbolic deletion lost captured engine or removed target")
        // Moving the selected tag while warning is open must fail CAS, not delete it.
        _ = try await plain.run(["tag","moved",base]);use(1<<8);browse.model.load();try await settled(browse);try choose(browse,["refs/tags/moved"])
        browse.model.deleteChosen();try await wait{confirmation != nil};_ = try await plain.run(["update-ref","refs/tags/moved",head,base]);confirmation?.resume(returning:true);confirmation=nil;try await settled(browse)
        let moved=try await plain.run(["rev-parse","refs/tags/moved"]).text.trimmingCharacters(in:.newlines)
        try require(moved==head && browse.model.error != nil,"Moved reference was deleted after stale approval")
        // Same-OID retargeting changes the approved alias identity too.
        _ = try await plain.run(["tag","same-a",base]);_ = try await plain.run(["tag","same-b",base])
        _ = try await plain.run(["symbolic-ref","refs/tags/alias-moved","refs/tags/same-a"])
        browse.model.load();try await settled(browse);try choose(browse,["refs/tags/alias-moved"])
        browse.model.deleteChosen();try await wait{confirmation != nil}
        _ = try await plain.run(["symbolic-ref","refs/tags/alias-moved","refs/tags/same-b"])
        confirmation?.resume(returning:true);confirmation=nil;try await settled(browse)
        let alias=try await plain.run(["symbolic-ref","refs/tags/alias-moved"]).text.trimmingCharacters(in:.newlines)
        try require(alias=="refs/tags/same-b" && browse.model.error != nil,"Same-OID alias retarget was deleted after stale approval")
        // Ordered multi-row failure retains the first success and reports the failed row.
        for name in ["partial-a","partial-b"] {_ = try await plain.run(["tag",name,base])}
        browse.model.load();try await settled(browse);try choose(browse,["refs/tags/partial-a","refs/tags/partial-b"])
        let lock=work.appendingPathComponent(".git/refs/tags/partial-b.lock");try Data("owned lock".utf8).write(to:lock)
        browse.model.confirmDeletion={_ in true};browse.model.deleteChosen();try await settled(browse);try fm.removeItem(at:lock)
        let first=try await plain.run(["show-ref","--verify","refs/tags/partial-a"],successfulExitCodes:0...128),second=try await plain.run(["show-ref","--verify","refs/tags/partial-b"],successfulExitCodes:0...128)
        try require(first.exitCode != 0 && second.exitCode==0 && browse.model.error != nil,"Partial deletion rolled back success or erased failed row")
        // Owner retirement during warning prevents dispatch entirely.
        let closing=browser("refs/tags/partial-b");closing.model.load();try await settled(closing);try choose(closing,["refs/tags/partial-b"])
        closing.model.confirmDeletion={_ in await withCheckedContinuation{confirmation=$0}};closing.model.deleteChosen();try await wait{confirmation != nil}
        closing.model.invalidate();closing.close();confirmation?.resume(returning:true);confirmation=nil;try await settled(closing)
        let still=try await plain.run(["show-ref","--verify","refs/tags/partial-b"],successfulExitCodes:0...128);try require(still.exitCode==0,"Retired owner accepted late delete confirmation")
        // Shared native Log/Reflog/Sync/Graph consumers capture their engine
        // before each per-reference warning, not after the user replies.
        for name in ["consumer-log","consumer-reflog","consumer-sync","consumer-graph"] {_ = try await plain.run(["tag",name,head])}
        let logModel=LogWindowModel(repository:repo,access:grant,labelDefaults:prefs)
        defer{logModel.invalidate()}
        logModel.entries=try await plain.history();logModel.graph=CommitGraph.layout(logModel.entries);logModel.selected=[head]
        use(1<<8);try clear();logModel.confirmReferenceDeletion={_ in use(0,enabled:false);return .delete}
        logModel.deleteReferences([LogReferenceMenuTarget(hash:head,name:"refs/tags/consumer-log")]);try await wait{!logModel.busy && LogWindowModel.activeHistoryDeletions==0}
        try require(logModel.error==nil && (try log()).contains("turtlegit-delete-local-ref"),"Log deletion recaptured preferences after confirmation")
        let reflog=ReferenceLogWindowModel(repository:repo,access:grant,reference:"refs/heads/main",preferences:prefs)
        defer{reflog.invalidate()};reflog.reload();try await wait{!reflog.busy}
        guard let entry=reflog.entries.first(where:{$0.hash==head}) else{throw Failure(description:"Reflog current entry missing")}
        reflog.selection=[entry.id];use(1<<8);try clear();reflog.confirmReferenceDeletion={_ in use(0,enabled:false);return .delete}
        reflog.deleteNamedReferences(["refs/tags/consumer-reflog"],ids:reflog.selection);try await wait{!reflog.busy && ReferenceLogWindowModel.activeRevisionReads==0}
        try require(reflog.error==nil && (try log()).contains("turtlegit-delete-local-ref"),"Reflog deletion recaptured preferences")
        let sync=SynchronizationWindowModel(repository:repo,access:grant,preferences:prefs)
        defer{sync.invalidate()};use(1<<8);try clear();sync.confirmHistoryDeletion={_ in use(0,enabled:false);return .delete}
        sync.deleteHistoryReferences(["refs/tags/consumer-sync"],revision:head);try await wait{!sync.busy && SynchronizationWindowModel.activeHistoryDeletions==0}
        try require(sync.error==nil && (try log()).contains("turtlegit-delete-local-ref"),"Sync deletion recaptured preferences")
        let graph=RevisionGraphWindowModel(repository:repo,access:grant,preferences:prefs,layoutExecutable:graphLayout)
        defer{graph.invalidate()};graph.load();try await wait{!graph.busy}
        try require(graph.error==nil && graph.nodes.contains{$0.hash==head},"Actual graph layout unavailable: \(graph.error ?? "none")")
        graph.select(head,extending:false);use(1<<8);try clear();graph.confirmReferenceDeletion={_ in use(0,enabled:false);return .delete}
        graph.deleteReferences(["refs/tags/consumer-graph"],hash:head);try await wait{!graph.busy && RevisionGraphWindowModel.activeOperations==0}
        try require(graph.error==nil && (try log()).contains("turtlegit-delete-local-ref"),"Graph deletion recaptured preferences")
        for name in ["consumer-log","consumer-reflog","consumer-sync","consumer-graph"] {
            let result=try await plain.run(["show-ref","--verify","refs/tags/"+name],successfulExitCodes:0...128)
            try require(result.exitCode != 0,"Shared native consumer failed actual local deletion: "+name)
        }
        // Hold real selected helper+child; Quit/close keep lifetime until both reaped.
        use(1<<18);try Data().write(to:hold);let held=browser();held.model.load();try await wait{fm.fileExists(atPath:ready.path) && held.model.busy}
        let pids=try String(contentsOf:ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Live selected reader failed Quit ownership")
        held.model.invalidate();held.close();try await wait{drained() && pids.allSatisfy{kill($0,0) != 0}};try fm.removeItem(at:hold)
        try require(held.model.snapshot==nil,"Retired helper published a late Browser result")
        let finalHead=try await plain.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(finalHead==head && Data("next\n".utf8)==Data(contentsOf:file),"Reference operations changed working tree/HEAD")
        for owner in browsers {owner.model.invalidate();owner.close()};for owner in contains {owner.close()};try await wait{drained()}
    }
}
