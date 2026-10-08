import AppKit
import SwiftUI
import TurtleGitCore

@main struct PushProgressVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(condition(), "Push progress timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.PushProgress.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let client = root.appendingPathComponent("client"), destination = root.appendingPathComponent("remote.git")
        for dir in [client,destination] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        let repo = GitRepository(root:client,executable:git), remote = GitRepository(root:destination,executable:git)
        _ = try await remote.run(["init","--bare"]); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Push progress QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        try await repo.saveRemote(name:"origin",fetchURL:destination.path,pushURL:"",existing:false)
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        for policy in GitProgressAutoClose.allCases {
            prefs.set(policy.rawValue,forKey:"AutoCloseGitProgress")
            let owner = PushWindowModel(repository:repo,access:nil,preferences:prefs); owner.load(); try await wait { !owner.busy }
            owner.options.source = "main"; owner.options.remote = "origin"; owner.options.destination = "published-" + String(policy.rawValue); owner.options.setUpstream = false
            var presented:PushProgressWindowModel?, closes = 0, pushed = 0, actions:[PushPostAction] = []
            owner.onProgress = { presented = $0 }; owner.close = { closes += 1 }; owner.onPushed = { _ in pushed += 1 }
            owner.onPostAction = { action, options,_ in precondition(owner.progress == nil && !owner.busy); precondition(options.source == "main" && options.destination == "published-" + String(policy.rawValue)); actions.append(action) }
            owner.push(); owner.push(); try await wait { presented?.busy == false }
            let result = presented!; precondition(result.success && result.postActions == [.requestPull,.push,.switchBranch] && pushed == 1 && result.output.contains("refs/heads/published-"))
            if policy == .noErrors { precondition(closes == 1 && owner.progress == nil && !owner.busy && actions.isEmpty) }
            else {
                precondition(closes == 0 && owner.busy && !owner.transportRunning && owner.progress === result)
                owner.options.source = "mutated"; owner.options.destination = "mutated"; owner.push(); precondition(pushed == 1)
                let host = NSHostingView(rootView:PushProgressDialog(owner:owner,result:result)); host.frame = NSRect(x:0,y:0,width:760,height:430); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
                result.perform(.requestPull); result.perform(.push); precondition(closes == 1 && actions == [.requestPull] && owner.progress == nil && !owner.busy)
            }
            let received = try await remote.run(["rev-parse","refs/heads/published-" + String(policy.rawValue)]).text.trimmingCharacters(in:.newlines); precondition(received == base)
        }
        // A real non-fast-forward rejection uses porcelain flag/reason formatting.
        _ = try await repo.run(["commit","--allow-empty","-m","remote next"])
        var seed = PushOptions(); seed.source = "main"; seed.remote = "origin"; _ = try await repo.push(seed)
        _ = try await repo.run(["reset","--hard",base]); _ = try await repo.run(["commit","--allow-empty","-m","local diverged"])
        prefs.set(2,forKey:"AutoCloseGitProgress")
        let rejected = PushWindowModel(repository:repo,access:nil,preferences:prefs); rejected.load(); try await wait { !rejected.busy }; rejected.options.setUpstream = false
        var failed:PushProgressWindowModel?, failedCloses = 0, dispatched:[PushPostAction] = []
        rejected.onProgress = { failed = $0 }; rejected.close = { failedCloses += 1 }; rejected.onPostAction = { action,options,_ in precondition(options.remote == "origin"); dispatched.append(action) }
        rejected.push(); try await wait { failed?.busy == false }
        precondition(!failed!.success && failed!.postActions == [.pull,.fetch,.push] && failedCloses == 0 && rejected.error == nil)
        failed!.perform(.fetch); precondition(failedCloses == 1 && dispatched == [.fetch])
        let missing = PushWindowModel(repository:repo,access:nil,preferences:prefs); missing.load(); try await wait { !missing.busy }; missing.options.arbitraryURL = true; missing.url = root.appendingPathComponent("missing.git").path; missing.options.setUpstream = false
        var unavailable:PushProgressWindowModel?; missing.onProgress = { unavailable = $0 }; missing.push(); try await wait { unavailable?.busy == false }; precondition(!unavailable!.success && unavailable!.postActions == [.push]); unavailable!.close()
        // Server-side hook rejection does not offer Pull/Fetch as source [rejected] does.
        let hooks = destination.appendingPathComponent("hooks"); let rejectHook = hooks.appendingPathComponent("pre-receive")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to:rejectHook); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:rejectHook.path)
        let hookOwner = PushWindowModel(repository:repo,access:nil,preferences:prefs); hookOwner.load(); try await wait { !hookOwner.busy }; hookOwner.options.destination = "hook-reject"; hookOwner.options.setUpstream = false
        var hookResult:PushProgressWindowModel?; hookOwner.onProgress = { hookResult = $0 }; hookOwner.push(); try await wait { hookResult?.busy == false }; precondition(!hookResult!.success && hookResult!.output.contains("[remote rejected]") && hookResult!.postActions == [.push]); hookResult!.close(); try FileManager.default.removeItem(at:rejectHook)
        // Fetch follow-up presets are applied after loading saved/default state.
        let fetch = FetchWindowModel(repository:repo,access:nil,isPull:false,preferences:prefs); fetch.load(remote:"origin",allRemotes:false); try await wait { !fetch.busy }; precondition(fetch.options.remote == "origin" && !fetch.options.allRemotes && !fetch.options.arbitraryURL)
        fetch.load(remote:destination.path,allRemotes:false); try await wait { !fetch.busy }; precondition(fetch.options.arbitraryURL && fetch.url == destination.path)
        fetch.load(allRemotes:true); try await wait { !fetch.busy }; precondition(fetch.options.allRemotes && !fetch.options.arbitraryURL && !fetch.launchRebase)
        // A real submodule adds the superproject follow-up only after success.
        let parentRoot = root.appendingPathComponent("parent"); try FileManager.default.createDirectory(at:parentRoot,withIntermediateDirectories:true)
        let parent = GitRepository(root:parentRoot,executable:git); _ = try await parent.run(["init","-b","main"])
        _ = try await parent.run(["-c","protocol.file.allow=always","submodule","add",client.path,"child"])
        let child = GitRepository(root:parentRoot.appendingPathComponent("child"),executable:git)
        let subOwner = PushWindowModel(repository:child,access:nil,preferences:prefs); subOwner.load(); try await wait { !subOwner.busy }; subOwner.options.destination = "sub-published"; subOwner.options.setUpstream = false
        prefs.set(0,forKey:"AutoCloseGitProgress"); var subResult:PushProgressWindowModel?; subOwner.onProgress = { subResult = $0 }; subOwner.push(); try await wait { subResult?.busy == false }
        precondition(subResult!.success && subResult!.superproject?.standardizedFileURL.path == parentRoot.path && subResult!.postActions.last == .commitSuperproject); subResult!.close()
        // Missing presenter terminates the owned request and releases owner state.
        let absent = PushWindowModel(repository:repo,access:nil,preferences:prefs); absent.load(); try await wait { !absent.busy }; absent.options.destination = "not-presented"; absent.options.setUpstream = false
        var absentSuccess = 0; absent.onPushed = { _ in absentSuccess += 1 }; absent.onProgress = { $0.abandonPresentation() }; absent.push(); try await wait { !absent.busy }; precondition(absent.progress == nil && absentSuccess == 0)
        // Owned progress cancellation retains its result until acknowledgement.
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path + ".started"), release = URL(fileURLWithPath:helper.path + ".release")
        let gitQuote = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${4-}" = push ] && [ ! -f "$0.release" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(gitQuote) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        prefs.set(true,forKey:"ConfirmKillProcess"); prefs.set(2,forKey:"AutoCloseGitProgress")
        let slow = PushWindowModel(repository:GitRepository(root:client,executable:helper),access:nil,preferences:prefs); slow.load(); try await wait { !slow.busy }; slow.options.destination = "retry-after-cancel"; slow.options.setUpstream = false
        var slowResult:PushProgressWindowModel?, slowCallbacks = 0, slowCloses = 0
        slow.onProgress = { slowResult = $0 }; slow.onPushed = { _ in slowCallbacks += 1 }; slow.close = { slowCloses += 1 }; slow.push(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        slow.confirmCancellation = { $0(false) }; slow.cancel(); precondition(slow.transportRunning && !slow.cancelling)
        slow.confirmCancellation = { $0(true) }; slow.cancel(); try await wait { slowResult?.busy == false }
        precondition(slowResult!.cancelled && !slowResult!.success && slowResult!.postActions == [.push] && slow.busy && slowCallbacks == 0 && slowCloses == 0 && slow.error == nil)
        try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }; slowResult!.close(); precondition(!slow.busy && slowCloses == 1)
        try Data().write(to:release)
        let retry = PushWindowModel(repository:GitRepository(root:client,executable:helper),access:nil,preferences:prefs); retry.load(); try await wait { !retry.busy }; retry.options = slowResult!.options; retry.onProgress = { _ in }; var retried = 0; retry.onPushed = { _ in retried += 1 }; retry.push(); try await wait { !retry.busy }; precondition(retried == 1 && retry.progress == nil)
        // Deferred auto-close resumes once a native cancellation prompt releases.
        var promptBlocksClose = true, deferredCloses = 0
        let deferred = PushProgressWindowModel(options:PushOptions(),superproject:nil,preferences:prefs)
        deferred.close = { if !promptBlocksClose { deferredCloses += 1; deferred.invalidate() } }
        deferred.complete(output:"success",success:true,cancelled:false); precondition(deferredCloses == 0)
        promptBlocksClose = false; deferred.tryAutomaticClose(); deferred.tryAutomaticClose(); precondition(deferredCloses == 1)
        print("Push progress: three close policies, actual success/rejection/missing URL/server hook failure, ordered actions and once-only post-action callback after owner release; immutable source/destination snapshot and duplicate gate; actual submodule superproject; Fetch named/URL/all-remote presets; missing presenter cancellation; hidden progress layout. No displayed windows or standard preference/clipboard writes.")
    }
}
