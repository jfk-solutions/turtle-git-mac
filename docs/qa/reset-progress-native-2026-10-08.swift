import AppKit
import SwiftUI
import TurtleGitCore

@main struct ResetProgressVerification {
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws { let end = Date().addingTimeInterval(30); while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }; precondition(condition(),"Reset progress timed out") }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.ResetProgress.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let repo = GitRepository(root:root,executable:git); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Reset progress QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("next\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"next")
        let next = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        for policy in GitProgressAutoClose.allCases {
            for mode in ResetMode.allCases {
                _ = try await repo.run(["reset","--hard",next])
                try Data("staged\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); try Data("working\n".utf8).write(to:root.appendingPathComponent("file"))
                prefs.set(policy.rawValue,forKey:"AutoCloseGitProgress")
                let plan = try await repo.prepareReset(to:base,mode:mode), result = ResetProgressWindowModel(repository:repo,plan:try await repo.prepareReset(to:base,mode:mode),preferences:prefs)
                var closed = 0; result.close = { closed += 1 }; await result.run()
                precondition(result.success && result.postActions == (mode == .hard ? [.clean] : []) && closed == (policy == .noErrors || policy == .noOptions && mode != .hard ? 1 : 0))
                let head = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines), index = try await repo.run(["show",":file"]).text, working = try String(contentsOf:root.appendingPathComponent("file"))
                precondition(head == plan.revision && index == (mode == .soft ? "staged\n" : "base\n") && working == (mode == .hard ? "base\n" : "working\n"))
            }
        }
        prefs.set(0,forKey:"AutoCloseGitProgress"); _ = try await repo.run(["reset","--hard",next])
        let owner = ResetWindowModel(repository:repo,access:nil,revision:base,preferences:prefs); owner.load(); try await wait { !owner.busy && !owner.chooser.busy }
        var acknowledgements = 0, changes = 0, ownerCloses = 0, result:ResetProgressWindowModel?
        owner.onProgress = { result = $0 }; owner.onReset = { _ in acknowledgements += 1 }; owner.onChanged = { _ in changes += 1 }; owner.close = { ownerCloses += 1 }
        owner.mode = .hard; owner.confirmHard = { _,choose in choose(false) }; owner.reset(); try await wait { !owner.busy && !owner.confirmingHard }; precondition(result == nil && acknowledgements == 0)
        owner.confirmHard = { _,choose in choose(true) }; owner.reset(); try await wait { result?.busy == false }
        precondition(owner.busy && acknowledgements == 0 && changes == 1 && result!.success)
        let host = NSHostingView(rootView:ResetProgressDialog(model:result!)); host.frame = NSRect(x:0,y:0,width:760,height:430); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        result!.close(); precondition(!owner.busy && owner.progress == nil && acknowledgements == 1 && ownerCloses == 1)
        // Failed stale plan stays open and does not reset a newly checked-out branch.
        let stale = try await repo.prepareReset(to:next,mode:.soft); _ = try await repo.run(["checkout","-b","other"])
        let failure = ResetProgressWindowModel(repository:repo,plan:stale,preferences:prefs); var failedCloses = 0; failure.close = { failedCloses += 1 }; await failure.run(); precondition(!failure.success && failure.postActions == [.retry] && failedCloses == 0)
        failure.perform(.retry); try await wait { !failure.busy }; precondition(!failure.success && failedCloses == 0)
        _ = try await repo.run(["checkout","main"]); failure.perform(.retry); try await wait { !failure.busy }; precondition(failure.success && failure.postActions.isEmpty)
        // Worktree submodule configuration and active bisect determine ordered actions.
        _ = try await repo.run(["reset","--hard",next]); try Data("[submodule \"child\"]\n path = child\n url = local\n".utf8).write(to:root.appendingPathComponent(".gitmodules")); try await repo.stage([".gitmodules"]); _ = try await repo.run(["update-index","--add","--cacheinfo","160000",base,"child"]); _ = try await repo.commit(message:"submodule config")
        let configured = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let sub = ResetProgressWindowModel(repository:repo,plan:try await repo.prepareReset(to:configured,mode:.hard),preferences:prefs); await sub.run(); precondition(sub.postActions == [.submoduleUpdate,.clean])
        _ = try await repo.run(["rm","--cached","child"]); _ = try await repo.commit(message:"configuration without gitlink")
        let configOnly = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let configResult = ResetProgressWindowModel(repository:repo,plan:try await repo.prepareReset(to:configOnly,mode:.hard),preferences:prefs); await configResult.run(); precondition(configResult.postActions == [.submoduleUpdate,.clean])
        _ = try await repo.run(["bisect","start",configured,base])
        let bisect = ResetProgressWindowModel(repository:repo,plan:try await repo.prepareReset(to:next,mode:.soft),preferences:prefs); var dispatched:[ResetPostAction] = []; bisect.onPostAction = { dispatched.append($0) }; await bisect.run(); precondition(bisect.postActions == [.bisectGood,.bisectBad,.bisectSkip,.bisectReset]); bisect.perform(.bisectSkip); bisect.perform(.bisectBad); precondition(dispatched == [.bisectSkip]); _ = try await repo.run(["bisect","reset"])
        // Slow owned reset/helper: No keeps running, Yes stops, Retry is fresh.
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${4-}" = reset ] && [ ! -f "$0.release" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let slowRepo = GitRepository(root:root,executable:helper), slowPlan = try await repo.prepareReset(to:base,mode:.mixed)
        prefs.set(true,forKey:"ConfirmKillProcess"); let slow = ResetProgressWindowModel(repository:slowRepo,plan:slowPlan,preferences:prefs); slow.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        slow.confirmCancellation = { $0(false) }; slow.cancel(); precondition(slow.busy && !slow.cancelling)
        slow.confirmCancellation = { $0(true) }; slow.cancel(); try await wait { !slow.busy }; precondition(slow.cancelled && !slow.success && slow.postActions == [.retry]); try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }
        let unchanged = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines); precondition(unchanged == slowPlan.originalHead)
        try Data().write(to:release); slow.perform(.retry); try await wait { !slow.busy }; precondition(slow.success)
        print("Reset progress: actual Soft/Mixed/Hard effects across all close policies; native Hard No/Yes capture, success continuation after result acknowledgement, stale branch retry protection/recovery, submodule and bisect ordered actions/once dispatch, owned No/Yes cancellation and fresh Retry. Hidden progress layout; no displayed windows or standard preference/clipboard writes.")
    }
}
