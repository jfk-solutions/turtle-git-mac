import AppKit
import SwiftUI
import TurtleGitCore

@main struct CleanProgressPolicyVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Clean policy timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.CleanProgressPolicy.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Clean QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("tracked\n".utf8).write(to: root.appendingPathComponent("tracked")); try await repo.stage(["tracked"]); _ = try await repo.commit(message: "initial")
        let tracked = try Data(contentsOf: root.appendingPathComponent("tracked")), head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        func request(_ dry: Bool, _ permanent: Bool) -> CleanDialogRequest { CleanDialogRequest(options: CleanOptions(type: .nonIgnored), paths: [], dryRun: dry, submodules: false, permanently: permanent) }
        for policy in GitProgressAutoClose.allCases {
            for permanent in [false,true] {
                prefs.set(policy.rawValue, forKey: "AutoCloseGitProgress")
                try Data("candidate\n".utf8).write(to: root.appendingPathComponent("candidate"))
                let preview = CleanProgressWindowModel(repository: repo, access: nil, request: request(true,permanent), preferences: prefs)
                // Policy captured at window construction, regardless of later settings edits.
                prefs.set((policy.rawValue + 1) % 3, forKey: "AutoCloseGitProgress")
                var closed = 0; preview.close = { closed += 1 }; preview.start(); try await wait { !preview.busy }
                precondition(!preview.failed && preview.previewSucceeded && preview.postActions == (permanent ? [.permanent,.trash] : [.trash,.permanent]))
                precondition(closed == (policy == .noErrors ? 1 : 0) && FileManager.default.fileExists(atPath: root.appendingPathComponent("candidate").path))
                let host = NSHostingView(rootView: CleanProgressDialog(model: preview)); host.frame = NSRect(x:0,y:0,width:900,height:500); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
                prefs.set(policy.rawValue, forKey: "AutoCloseGitProgress")
                let execution = CleanProgressWindowModel(repository: repo, access: nil, request: request(false,true), preferences: prefs)
                var executionCloses = 0; execution.close = { executionCloses += 1 }; execution.start(); try await wait { !execution.busy }
                precondition(!execution.failed && execution.completed == 1 && execution.postActions.isEmpty && executionCloses == (policy == .manual ? 0 : 1))
                precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("candidate").path))
            }
        }
        // The separate Trash progress ends after successful removal, regardless
        // of the Git progress setting. Recover and remove only our own test item.
        for policy in GitProgressAutoClose.allCases {
            prefs.set(policy.rawValue,forKey:"AutoCloseGitProgress")
            try Data("trash bytes\n".utf8).write(to:root.appendingPathComponent("trash"))
            let trash = CleanProgressWindowModel(repository:repo,access:nil,request:request(false,false),preferences:prefs); var trashCloses = 0
            trash.close = { trashCloses += 1 }; trash.start(); try await wait { !trash.busy }
            precondition(!trash.failed && trashCloses == 1 && trash.trashedFiles.count == 1)
            for url in trash.trashedFiles { let recovered = try Data(contentsOf:url); precondition(recovered == Data("trash bytes\n".utf8)); try FileManager.default.removeItem(at:url) }
        }
        // Failed execution retains Retry even under no-errors; duplicate Retry is locked.
        prefs.set(2,forKey:"AutoCloseGitProgress")
        let lock = root.appendingPathComponent(".git/index.lock"); try Data("foreign lock".utf8).write(to:lock); try Data("retry\n".utf8).write(to:root.appendingPathComponent("retry"))
        let failure = CleanProgressWindowModel(repository:repo,access:nil,request:request(false,true),preferences:prefs); var failureCloses = 0; failure.close = { failureCloses += 1 }; failure.start(); try await wait { !failure.busy }
        precondition(failure.failed && failure.postActions == [.retry] && failureCloses == 0)
        let lockBytes = try Data(contentsOf:lock); precondition(lockBytes == Data("foreign lock".utf8)); try FileManager.default.removeItem(at:lock)
        failure.perform(.retry); failure.perform(.retry); try await wait { !failure.busy }; precondition(!failure.failed && failureCloses == 1 && failure.completed == 1)
        // Real slow clean preview: No preserves running work, Yes kills owned helper.
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${6-}" = clean ] && [ ! -f "$0.release" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let slowRepo = GitRepository(root:root,executable:helper); prefs.set(true,forKey:"ConfirmKillProcess"); prefs.set(0,forKey:"AutoCloseGitProgress")
        let slow = CleanProgressWindowModel(repository:slowRepo,access:nil,request:request(true,true),preferences:prefs); slow.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        slow.confirmCancellation = { $0(false) }; slow.cancel(); precondition(slow.busy && !slow.cancelRequested)
        slow.confirmCancellation = { $0(true) }; slow.cancel(); try await wait { !slow.busy }; precondition(slow.failed && slow.current == "Cancelled" && slow.postActions == [.retry]); try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }
        try Data().write(to:release); slow.perform(.retry); try await wait { !slow.busy }; precondition(slow.previewSucceeded && !slow.failed)
        // Completion while a confirmation is pending must wait for its response.
        try FileManager.default.removeItem(at:marker); try FileManager.default.removeItem(at:release); prefs.set(2,forKey:"AutoCloseGitProgress")
        let deferred = CleanProgressWindowModel(repository:slowRepo,access:nil,request:request(true,true),preferences:prefs); var answer:((Bool)->Void)?, deferredCloses = 0
        deferred.close = { deferredCloses += 1 }; deferred.confirmCancellation = { answer = $0 }; deferred.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }; deferred.cancel()
        precondition(deferred.confirmingCancellation); deferred.perform(.retry); try Data().write(to:release)
        let runningPids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(runningPids.count == 2)
        // Release the owned sleeping gate, letting the actual Git preview finish.
        kill(runningPids[1],SIGTERM); try await wait { !deferred.busy }; precondition(deferred.previewSucceeded && deferredCloses == 0 && deferred.confirmingCancellation)
        answer?(false); precondition(!deferred.confirmingCancellation && deferredCloses == 1); try await wait { kill(runningPids[0],0) != 0 && kill(runningPids[1],0) != 0 }
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")), afterTracked = try Data(contentsOf:root.appendingPathComponent("tracked"))
        precondition(head == afterHead && index == afterIndex && tracked == afterTracked)
        precondition(CleanPostAction.allIconsAvailable)
        print("Clean policy: captured policies; actual dry-run preservation/permanent deletion; ordered split actions; retained failure and fresh Retry; owned No/Yes cancellation; delayed automatic close across pending prompt; tracked HEAD/index/worktree preserved. Hidden progress host, no displayed UI or standard preference writes.")
    }
}
private extension CleanPostAction {
    static var allIconsAvailable: Bool { [Self.retry,.trash,.permanent].allSatisfy { $0.icon.image() != nil } }
}
