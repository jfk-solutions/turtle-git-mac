import AppKit
import SwiftUI
import TurtleGitCore

@main struct SwitchProgressVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws { let end = Date().addingTimeInterval(30); while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }; precondition(condition(), "Switch timed out") }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        let suite = "TurtleGit.SwitchProgress.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Switch QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("next\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "next")
        _ = try await repo.run(["branch","older",base]); _ = try await repo.run(["tag","v1",base])
        // Owner uses real submitted options, refreshes each attempt, and acknowledges once.
        for policy in 0...2 {
            _ = try await repo.run(["checkout","main"]); prefs.set(policy,forKey: "AutoCloseGitProgress")
            let owner = SwitchWindowModel(repository: repo,access: nil,preferences: prefs); owner.load(revision: "refs/tags/v1"); try await wait { !owner.busy }
            owner.options.createBranch = true; owner.options.branchName = "from-tag-\(policy)"
            var result: SwitchProgressWindowModel?, changes = 0, acknowledgements = 0, closes = 0
            owner.onProgress = { result = $0 }; owner.onChanged = { _ in changes += 1 }; owner.onSwitched = { _ in acknowledgements += 1 }; owner.close = { closes += 1 }
            owner.checkout(); owner.options.branchName = "wrong"; owner.load(revision: base)
            try await wait { result?.busy == false }
            let branch = try await repo.branch(); precondition(branch == "from-tag-\(policy)" && result!.options.branchName == branch && changes == 1 && result!.success)
            if policy == 2 { precondition(!owner.busy && acknowledgements == 1 && closes == 1) }
            else { precondition(owner.busy && acknowledgements == 0); result!.close(); precondition(!owner.busy && acknowledgements == 1 && closes == 1) }
            owner.finish(result!); owner.checkout(); precondition(acknowledgements == 1 && closes == 1)
        }
        prefs.set(0,forKey: "AutoCloseGitProgress"); _ = try await repo.run(["checkout","main"])
        // Remote tracking and detached commit share progress, not branch-only express behavior.
        _ = try await repo.run(["remote","add","origin",root.path]); _ = try await repo.run(["update-ref","refs/remotes/origin/team/topic",base])
        let remote = SwitchWindowModel(repository: repo,access: nil,preferences: prefs); remote.load(revision: "refs/remotes/origin/team/topic"); try await wait { !remote.busy }; remote.options.tracking = .track; remote.options.branchName = "tracked"
        var remoteResult: SwitchProgressWindowModel?; remote.onProgress = { remoteResult = $0 }; remote.checkout(); try await wait { remoteResult?.busy == false }
        let merge = try await repo.run(["config","--get","branch.tracked.merge"]).text; precondition(remoteResult!.success && merge == "refs/heads/team/topic\n"); remoteResult!.close()
        var detachedOptions = CheckoutOptions(); detachedOptions.target = .commit; detachedOptions.revision = base
        let detached = SwitchProgressWindowModel(repository: repo,access: nil,options: detachedOptions,preferences: prefs); await detached.run(); let detachedBranch = try await repo.branch(); precondition(detached.success && detachedBranch.isEmpty && detached.postActions == [.mergePreviousBranch,.commit])
        // Cross-name Continue captures the first draft; no duplicate mutation before Continue.
        _ = try await repo.run(["checkout","main"])
        let warning = SwitchWindowModel(repository: repo,access: nil,preferences: prefs); warning.load(revision: "refs/tags/v1"); try await wait { !warning.busy }; warning.options.createBranch = true; warning.options.branchName = "v1"
        var warnedResult: SwitchProgressWindowModel?; warning.onProgress = { warnedResult = $0 }; warning.checkout(); try await wait { !warning.busy }; precondition(warning.hasPendingTagConflict && warnedResult == nil)
        warning.options.branchName = "wrong-warning"; warning.checkout(); warning.checkout(allowTagConflict: true); try await wait { warnedResult?.busy == false }; let warnedBranch = try await repo.branch(); precondition(warnedBranch == "v1" && warnedResult!.options.allowTagNameConflict); warnedResult!.close()
        // Failed checkout retains captured revision/force/branch options for Retry.
        _ = try await repo.run(["checkout","main"]); try Data("working\n".utf8).write(to: root.appendingPathComponent("file"))
        let failure = SwitchWindowModel(repository: repo,access: nil,preferences: prefs); failure.load(revision: "refs/heads/older"); try await wait { !failure.busy }
        var failed: SwitchProgressWindowModel?, attempts = 0; failure.onProgress = { failed = $0 }; failure.onChanged = { _ in attempts += 1 }; failure.checkout(); try await wait { failed?.busy == false }
        precondition(!failed!.success && failed!.postActions == [.stash,.retry,.switchWithMerge] && attempts == 1)
        failure.branchRevision = "refs/heads/main"; _ = try await repo.run(["reset","--hard","HEAD"]); failed!.perform(.retry); try await wait { !failed!.busy }; let retriedBranch = try await repo.branch(); precondition(retriedBranch == "older" && attempts == 2); failed!.close()
        // Force + override options are retained; source .gitmodules gate needs no gitlink.
        var force = CheckoutOptions(); force.target = .commit; force.revision = "refs/heads/main"; force.createBranch = true; force.branchName = "older"; force.overrideBranch = true; force.overwriteChanges = true
        try Data("discard\n".utf8).write(to: root.appendingPathComponent("file"))
        let forced = SwitchProgressWindowModel(repository: repo,access: nil,options: force,preferences: prefs); await forced.run(); let forcedFile = try String(contentsOf: root.appendingPathComponent("file")); precondition(forced.success && forcedFile == "next\n")
        try Data("[submodule \"child\"]\n path = child\n url = local\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
        let modules = SwitchProgressWindowModel(repository: repo,access: nil,reference: "refs/heads/main",preferences: prefs); var actionEvents: [String] = []; modules.close = { actionEvents.append("close") }; modules.onPostAction = { action,_ in actionEvents.append(action.rawValue) }; await modules.run(); precondition(modules.postActions == [.submoduleUpdate,.mergePreviousBranch,.pull,.commit]); modules.perform(.submoduleUpdate); modules.perform(.commit); precondition(actionEvents == ["close",SwitchPostAction.submoduleUpdate.rawValue])
        let host = NSHostingView(rootView: SwitchProgressDialog(model: modules)); host.frame = NSRect(x:0,y:0,width:760,height:420); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".gitmodules"))
        // Owned slow switch leader/helper: No preserves, Yes cancels; fresh retry succeeds.
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath: helper.path+".started"), release = URL(fileURLWithPath: helper.path+".release")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${4-}" = switch ] && [ ! -f "$0.release" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let slowRepo = GitRepository(root:root,executable:helper); prefs.set(true,forKey:"ConfirmKillProcess")
        let slow = SwitchProgressWindowModel(repository: slowRepo,access:nil,reference:"refs/heads/older",preferences:prefs); slow.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) }
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        slow.confirmCancellation = { $0(false) }; slow.cancel(); precondition(slow.busy && !slow.cancelling && kill(pids[0],0) == 0 && kill(pids[1],0) == 0)
        slow.confirmCancellation = { $0(true) }; slow.cancel(); try await wait { !slow.busy }; precondition(slow.cancelled && !slow.success); try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }
        try Data().write(to:release); slow.perform(.retry); try await wait { !slow.busy }; precondition(slow.success)
        // Completion under a pending cancellation question defers close; late Yes cannot cancel completion.
        try FileManager.default.removeItem(at: marker); try FileManager.default.removeItem(at: release); prefs.set(2,forKey:"AutoCloseGitProgress")
        let deferred = SwitchProgressWindowModel(repository:slowRepo,access:nil,reference:"refs/heads/main",preferences:prefs); var answer: ((Bool)->Void)?, deferredCloses = 0
        deferred.confirmCancellation = { answer = $0 }; deferred.close = { deferredCloses += 1 }; deferred.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }; deferred.cancel(); precondition(deferred.confirmingCancellation)
        let deferredPids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; try Data().write(to:release); _ = kill(deferredPids[1],SIGTERM)
        try await wait { !deferred.busy }; precondition(deferred.success && deferredCloses == 0); answer?(true); answer?(true); precondition(deferredCloses == 1 && !deferred.cancelled)
        // Missing presentation cancels before switch; hidden running controller blocks Quit/Close.
        _ = try await repo.run(["checkout","main"]); prefs.set(0,forKey:"AutoCloseGitProgress")
        let absent = SwitchWindowModel(repository:repo,access:nil,preferences:prefs); absent.load(revision:"refs/heads/older"); try await wait { !absent.busy }; absent.onProgress = { $0.abandonPresentation() }; absent.checkout(); try await wait { !absent.busy }; let retainedBranch = try await repo.branch(); precondition(retainedBranch == "main" && absent.progress == nil)
        let controller = SwitchWindowController(repository:repo,access:nil,preferences:prefs); controller.model.load(); precondition(!controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel); try await wait { !controller.model.busy }; controller.close()
        print("Switch: captured full options, owner acknowledgement/three policies, remote tracking/detach/force/override, cross-name capture, failed retry, source .gitmodules gate/once actions, owned No/Yes cancellation and fresh retry, deferred completion/duplicate answers, missing presentation and hidden close/Quit passed; no displayed UI/network/standard preference writes.")
    }
}
