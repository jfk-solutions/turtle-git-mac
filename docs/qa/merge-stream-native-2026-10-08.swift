import AppKit
import SwiftUI
import TurtleGitCore

@main struct MergeStreamVerification {
    @MainActor static func wait(_ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(predicate(), "Merge streaming timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.MergeStream.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        prefs.set(0,forKey:"AutoCloseGitProgress")
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let producer = GitRepository(root:source,executable:git)
        _ = try await producer.run(["init","-b","main"])
        for (key,value) in [("user.name","Merge stream QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:source.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message:"base")
        let base = try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await producer.run(["switch","-c","feature"]); try Data("feature\n".utf8).write(to:source.appendingPathComponent("feature")); try await producer.stage(["feature"]); _ = try await producer.commit(message:"feature")
        let feature = try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines); _ = try await producer.run(["switch","main"])
        for name in ["regular","cancel","deferred","limited","ff","ff-deferred","ff-cancel"] {
            let dest = root.appendingPathComponent(name); _ = try await producer.run(["clone",source.path,dest.path]); let repo = GitRepository(root:dest,executable:git)
            for (key,value) in [("user.name","Merge stream QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            _ = try await repo.run(["branch","feature","refs/remotes/origin/feature"])
        }
        try Data("remote\n".utf8).write(to:source.appendingPathComponent("remote")); try await producer.stage(["remote"]); _ = try await producer.commit(message:"remote next")
        let remoteHead = try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release"), flood = URL(fileURLWithPath:helper.path+".flood")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${4-}" = merge ] && [ ! -f "$0.release" ]; then
          printf '\\351\\233'
          /bin/sleep 0.02
          printf '\\252\\360\\237\\220\\242\\n'
          printf 'Merge phase: 10%% (1/10)\\rMerge phase: 50%% (5/10)\\r' >&2
          if [ -f "$0.flood" ]; then
            task_line=0
            while [ "$task_line" -lt 6000 ]; do printf 'payload %s\\n' "$task_line"; task_line=$((task_line+1)); done
          fi
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        func pids() throws -> [Int32] { try String(contentsOf:marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) } }
        func resume() throws { let ids = try pids(); precondition(ids.count==2); try Data().write(to:release); _ = kill(ids[1],SIGTERM) }
        func clear() throws { for url in [marker,release,flood] where FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
        var options = MergeOptions(); options.revision = "refs/heads/feature"; options.fastForwardOnly = true
        for name in ["regular","cancel","deferred"] {
            prefs.set(name == "deferred" ? 2 : 0,forKey:"AutoCloseGitProgress"); prefs.set(name != "regular",forKey:"ConfirmKillProcess")
            let client = root.appendingPathComponent(name), actual = GitRepository(root:client,executable:git)
            let beforeIndex = try Data(contentsOf:client.appendingPathComponent(".git/index"))
            let model = MergeProgressWindowModel(repository:GitRepository(root:client,executable:helper),access:nil,options:options,target:.branch,showStashPop:false,preferences:prefs)
            var raw = "", changes=0, closes=0; model.onChanged = { raw=$0; changes += 1 }; model.close = { closes += 1 }; model.start()
            try await wait { model.percentage==50 && model.output.contains("雪🐢") && FileManager.default.fileExists(atPath:marker.path) }
            precondition(model.busy && changes==0 && model.currentWork=="Merge phase" && !model.output.contains("10%"))
            let host=NSHostingView(rootView:MergeProgressDialog(model:model)); host.frame=NSRect(x:0,y:0,width:780,height:420); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width>0)
            if name == "cancel" {
                let ids=try pids(); model.confirmCancellation={ $0(false) }; model.cancel(); precondition(model.busy && !model.cancelling && ids.allSatisfy { kill($0,0)==0 })
                model.confirmCancellation={ $0(true) }; model.cancel(); try await wait { !model.busy }; try await wait { ids.allSatisfy { kill($0,0) != 0 } }
                precondition(model.cancelled && !model.success && changes==1 && raw.contains("雪🐢")); let index=try Data(contentsOf:client.appendingPathComponent(".git/index")); precondition(index==beforeIndex)
            } else if name == "deferred" {
                var answer:((Bool)->Void)?; model.confirmCancellation={ answer=$0 }; model.cancel(); try resume(); try await wait { !model.busy }
                precondition(model.success && model.confirmingCancellation && closes==0 && !model.cancelled); model.perform(.push); precondition(closes==0)
                answer?(true); answer?(true); precondition(closes==1 && !model.cancelled && changes==1)
            } else {
                try resume(); try await wait { !model.busy }; precondition(model.success && changes==1 && closes==0 && raw.contains("10%") && raw.contains("50%") && !model.output.contains("10%") && model.postActions==[.removeBranch,.push])
            }
            if name == "regular" {
                model.confirmDeletion = { _,choose in choose(true) }; model.perform(.removeBranch); try await wait { !model.busy }
                precondition(changes==2 && raw.contains("10%") && raw.contains("Deleted branch") && !model.output.contains("10%"))
                let refs=try await actual.checkoutReferences(); precondition(!refs.contains { $0.name=="refs/heads/feature" })
            }
            let head=try await actual.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines); precondition(head == (name=="cancel" ? base : feature)); try clear()
        }
        // Truncation must not hide the repository-based conflict recovery decision.
        let limitedRoot=root.appendingPathComponent("limited"), actual=GitRepository(root:limitedRoot,executable:git)
        _ = try await actual.run(["switch","feature"]); try Data("theirs\n".utf8).write(to:limitedRoot.appendingPathComponent("file")); try await actual.stage(["file"]); _ = try await actual.commit(message:"theirs")
        _ = try await actual.run(["switch","main"]); try Data("ours\n".utf8).write(to:limitedRoot.appendingPathComponent("file")); try await actual.stage(["file"]); _ = try await actual.commit(message:"ours")
        prefs.set(16,forKey:"GitOutputLimitinKiB"); prefs.set(0,forKey:"AutoCloseGitProgress"); prefs.set(false,forKey:"ConfirmKillProcess")
        var conflictOptions=options; conflictOptions.fastForwardOnly=false
        let limited=MergeProgressWindowModel(repository:GitRepository(root:limitedRoot,executable:helper),access:nil,options:conflictOptions,target:.branch,showStashPop:false,preferences:prefs)
        prefs.set(100*1024,forKey:"GitOutputLimitinKiB"); try Data().write(to:flood); limited.start(); try await wait { limited.output.contains("Output truncated") && FileManager.default.fileExists(atPath:marker.path) }
        precondition(limited.busy && limited.percentage==nil && limited.outputLimit==16*1024); try resume(); try await wait { !limited.busy }
        precondition(!limited.success && limited.rawOutput.contains("payload 5999") && limited.rawOutput.contains("CONFLICT") && !limited.output.contains("CONFLICT") && limited.postActions==[.resolve,.commit,.stash]); try clear()
        let unmerged=try await actual.run(["ls-files","--unmerged"]).stdout.split(separator:10); precondition(unmerged.count==3)
        // Fetch's ff-only Merge uses a fresh phase and retains the preceding Fetch log.
        for name in ["ff","ff-deferred","ff-cancel"] {
            prefs.set(2048,forKey:"GitOutputLimitinKiB"); prefs.set(0,forKey:"AutoCloseGitProgress"); prefs.set(name != "ff",forKey:"ConfirmKillProcess")
            let client=root.appendingPathComponent(name), actual=GitRepository(root:client,executable:git)
            var fetch=FetchOptions(); fetch.remote="origin"; fetch.branch="main"
            let model=FetchProgressWindowModel(repository:GitRepository(root:client,executable:helper),access:nil,options:fetch,preferences:prefs,rebaseMode:.manual)
            model.presentRebasePrompt={ prompt in precondition(prompt == .fastForward); return FetchRebaseAnswer(value:1,suppress:false) }
            var changes=0,closes=0; model.onCompleted={ changes += 1 }; model.close={ closes += 1 }; model.start()
            try await wait { model.merging && model.percentage==50 && model.output.contains("雪🐢") && FileManager.default.fileExists(atPath:marker.path) }
            precondition(model.busy && model.output.contains("origin") && !model.output.contains("10%")); let beforeHead=try await actual.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines); precondition(beforeHead==base)
            if name=="ff-cancel" {
                let ids=try pids(); model.confirmCancellation={ $0(false) }; model.cancel(); precondition(model.busy && !model.cancelling); model.confirmCancellation={ $0(true) }; model.cancel(); try await wait { !model.busy }; try await wait { ids.allSatisfy { kill($0,0) != 0 } }
                precondition(model.cancelled && !model.success && model.rawOutput.contains("origin") && model.rawOutput.contains("雪🐢") && changes==1 && closes==0)
            } else if name=="ff-deferred" {
                var answer:((Bool)->Void)?; model.confirmCancellation={ answer=$0 }; model.cancel(); try resume(); try await wait { !model.busy }
                precondition(model.success && model.confirmingCancellation && closes==0); answer?(true); answer?(true); precondition(closes==1 && !model.cancelled && changes==1)
            } else { try resume(); try await wait { !model.busy }; precondition(model.success && closes==1 && changes==1 && model.rawOutput.contains("10%") && !model.output.contains("10%")) }
            let head=try await actual.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines); precondition(head == (name=="ff-cancel" ? base : remoteHead)); model.invalidate(); try clear()
        }
        print("Merge/Fetch ff-only live Unicode/CR/phase, real HEAD/conflicts, captured limit/raw callbacks, No/Yes owned cancellation and deferred completion passed")
    }
}
