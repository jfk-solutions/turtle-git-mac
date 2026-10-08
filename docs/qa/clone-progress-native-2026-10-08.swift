import AppKit
import SwiftUI
import TurtleGitCore

@main struct CloneProgressVerification {
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws { let end = Date().addingTimeInterval(30); while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }; precondition(condition(),"Clone timed out") }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2]), source = root.appendingPathComponent("source 雪")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let repo = GitRepository(root:source,executable:git), suite = "TurtleGit.CloneProgress.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Clone QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:source.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        _ = try await repo.run(["checkout","-b","feature/review"]); try Data("feature\n".utf8).write(to:source.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"feature"); _ = try await repo.run(["checkout","main"])
        let sourceHead = try await repo.run(["rev-parse","HEAD"]).stdout, sourceIndex = try Data(contentsOf:source.appendingPathComponent(".git/index")), sourceWorking = try Data(contentsOf:source.appendingPathComponent("file"))
        let lease = RepositoryAccessLease(url:root)
        // Actual shallow selected branch/custom origin, immutable fields/history and three policies.
        for policy in 0...2 {
            prefs.set(policy,forKey:"AutoCloseGitProgress")
            let destination = root.appendingPathComponent("nested/clone '雪' \(policy)"), owner = CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:git)
            owner.source = source.absoluteString; owner.directory = destination.path; owner.useDepth = true; owner.depth = "1"; owner.useBranch = true; owner.branch = "feature/review"; owner.useOrigin = true; owner.origin = "upstream"; owner.recursive = false
            var result:CloneProgressWindowModel?, adoptions = 0, closes = 0, adopted:GitRepository?
            owner.onProgress = { result = $0 }; owner.close = { closes += 1 }; owner.onCloned = { candidate,access,_,bare,_ in precondition(access.contains(candidate.root) && !bare); adoptions += 1; adopted = candidate }
            owner.clone(); owner.directory = root.appendingPathComponent("wrong-destination").path; owner.source = "wrong-source"; owner.recursive = true; owner.branch = "wrong-branch"; owner.origin = "wrong-origin"; owner.clone()
            try await wait { result?.busy == false }; precondition(result!.success && adoptions == 1 && adopted != nil && result!.postActions == [.log,.explore])
            let clone = GitRepository(root:destination,executable:git), branch = try await clone.branch(), shallow = try await clone.run(["rev-parse","--is-shallow-repository"]).text, remote = try await clone.remoteNames()
            precondition(branch == "feature/review" && shallow == "true\n" && remote == ["upstream"] && prefs.bool(forKey:"Clone.Recursive") == false && prefs.stringArray(forKey:"Clone.URLHistory")?.first == source.absoluteString)
            precondition(!FileManager.default.fileExists(atPath:root.appendingPathComponent("wrong-destination").path))
            if policy == 2 { precondition(!owner.busy && owner.progress == nil && closes == 1) }
            else { precondition(owner.busy && closes == 0); result!.close(); precondition(!owner.busy && owner.progress == nil && closes == 1) }
            owner.finish(result!); owner.clone(); precondition(adoptions == 1 && closes == 1)
        }
        prefs.set(0,forKey:"AutoCloseGitProgress")
        // Bare and no-checkout semantics remain real clone effects; once close-before-Log callback.
        for bare in [false,true] {
            let dest = root.appendingPathComponent(bare ? "bare.git" : "no-checkout"), owner = CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:git)
            owner.source = source.path; owner.directory = dest.path; owner.bare = bare; owner.noCheckout = !bare
            var result:CloneProgressWindowModel?, events:[String] = [], adoptedBare:Bool?
            owner.onProgress = { result = $0 }; owner.onCloned = { _,_,_,flag,_ in adoptedBare = flag }; owner.close = { events.append("close") }; owner.onLog = { candidate,_ in precondition(candidate.root.standardizedFileURL.path == dest.standardizedFileURL.path); events.append("log") }
            owner.clone(); try await wait { result?.busy == false }; precondition(result!.success && adoptedBare == bare)
            let cloned = GitRepository(root:dest,executable:git), actualBare = try await cloned.isBare(); precondition(actualBare == bare && !FileManager.default.fileExists(atPath:dest.appendingPathComponent("file").path))
            if !bare { let index = try await cloned.run(["ls-files"]).text; precondition(index.isEmpty) }
            result!.perform(.log); result!.perform(.explore); precondition(events == ["close","log"])
        }
        // Failed retry retains captured source/destination and preserves occupied content.
        let occupied = root.appendingPathComponent("occupied"); try FileManager.default.createDirectory(at:occupied,withIntermediateDirectories:true); let keep = occupied.appendingPathComponent("keep"); try Data("user bytes".utf8).write(to:keep)
        let failedOwner = CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:git); failedOwner.source = source.path; failedOwner.directory = occupied.path
        var failed:CloneProgressWindowModel?, failedAdoptions = 0; failedOwner.onProgress = { failed = $0 }; failedOwner.onCloned = { _,_,_,_,_ in failedAdoptions += 1 }; failedOwner.clone(); try await wait { failed?.busy == false }; precondition(!failed!.success && failed!.postActions == [.retry])
        failedOwner.directory = root.appendingPathComponent("later-edit").path; failedOwner.source = "later-source"; failed!.perform(.retry); try await wait { !failed!.busy }; let keptBytes = try Data(contentsOf:keep); precondition(!failed!.success && failedAdoptions == 0 && keptBytes == Data("user bytes".utf8) && !FileManager.default.fileExists(atPath:root.appendingPathComponent("later-edit").path))
        failed!.close(); precondition(!failedOwner.busy && failedOwner.progress == nil)
        failedOwner.source = source.path; failedOwner.directory = root.appendingPathComponent("reviewed").path; failedOwner.clone(); try await wait { failed?.busy == false }; precondition(failed!.success && failedAdoptions == 1); failed!.close()
        // Missing presentation cancels before any destination is created.
        let absent = CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:git), absentDest = root.appendingPathComponent("absent")
        absent.source = source.path; absent.directory = absentDest.path; absent.onProgress = { $0.abandonPresentation() }; absent.clone(); try await wait { !absent.busy }; precondition(absent.progress == nil && !FileManager.default.fileExists(atPath:absentDest.path))
        // Owned wrapper at clone boundary writes partial content; No/Yes cancellation preserves it.
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${4-}" = clone ] && [ ! -f "$0.release" ]; then
          for task_argument do task_destination="$task_argument"; done
          /bin/mkdir -p "$task_destination"
          printf '%s' 'partial clone' > "$task_destination/partial-owned"
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        var options = CloneOptions(); options.source = source.path
        let slowDest = root.appendingPathComponent("slow"), partial = slowDest.appendingPathComponent("partial-owned")
        prefs.set(true,forKey:"ConfirmKillProcess")
        let slow = CloneProgressWindowModel(options:options,destination:slowDest,executable:helper,destinationAccess:lease,sourceAccess:nil,keyAccess:nil,preferences:prefs); slow.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        slow.confirmCancellation = { $0(false) }; slow.cancel(); precondition(slow.busy && !slow.cancelling && kill(pids[0],0) == 0 && kill(pids[1],0) == 0)
        slow.confirmCancellation = { $0(true) }; slow.cancel(); try await wait { !slow.busy }; precondition(slow.cancelled && !slow.success && slow.postActions == [.retry]); try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }
        let partialBytes = try Data(contentsOf:partial); precondition(partialBytes == Data("partial clone".utf8)); try Data().write(to:release); slow.perform(.retry); try await wait { !slow.busy }; let retryPartial = try Data(contentsOf:partial); precondition(!slow.success && retryPartial == Data("partial clone".utf8))
        // Fixture alone removes its own synthetic partial file, then fresh Retry succeeds.
        try FileManager.default.removeItem(at:partial); slow.perform(.retry); try await wait { !slow.busy }; precondition(slow.success)
        // Success under pending confirmation defers auto-close; duplicate late Yes is harmless.
        try FileManager.default.removeItem(at:marker); try FileManager.default.removeItem(at:release); prefs.set(2,forKey:"AutoCloseGitProgress")
        let deferredDest = root.appendingPathComponent("deferred"), deferred = CloneProgressWindowModel(options:options,destination:deferredDest,executable:helper,destinationAccess:lease,sourceAccess:nil,keyAccess:nil,preferences:prefs)
        var answer:((Bool)->Void)?, deferredCloses = 0; deferred.confirmCancellation = { answer = $0 }; deferred.close = { deferredCloses += 1 }; deferred.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }; deferred.cancel()
        let deferredPids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; try FileManager.default.removeItem(at:deferredDest.appendingPathComponent("partial-owned")); try Data().write(to:release); _ = kill(deferredPids[1],SIGTERM)
        try await wait { !deferred.busy }; precondition(deferred.success && deferred.confirmingCancellation && deferredCloses == 0); answer?(true); answer?(true); precondition(deferredCloses == 1 && !deferred.cancelled)
        let host = NSHostingView(rootView:CloneProgressDialog(model:deferred)); host.frame = NSRect(x:0,y:0,width:760,height:430); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        let controller = CloneWindowController(directory:root,access:lease,preferences:prefs,executable:helper); controller.window?.contentViewController = nil
        controller.model.source = source.path; controller.model.directory = root.appendingPathComponent("controller-clone").path; var controllerResult:CloneProgressWindowModel?; controller.model.onProgress = { controllerResult = $0 }; controller.model.clone()
        precondition(!controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel); try await wait { controllerResult?.busy == false }; controller.close()
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterIndex = try Data(contentsOf:source.appendingPathComponent(".git/index")), afterWorking = try Data(contentsOf:source.appendingPathComponent("file")); precondition(afterHead == sourceHead && afterIndex == sourceIndex && afterWorking == sourceWorking)
        print("Clone: actual shallow branch/custom origin, bare/no-checkout, captured choices/history/adoption across policies, once close-before-Log, occupied destination/captured Retry/review, missing presenter, owned No/Yes process cancellation preserving partial files/fresh Retry, deferred completion/duplicate answers and hidden close/Quit. Source HEAD/index/worktree unchanged; no displayed UI/network/Finder reveal/standard preference writes.")
    }
}
