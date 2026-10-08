import AppKit
import SwiftUI
import TurtleGitCore

@main struct PushStreamVerification {
    @MainActor static func wait(_ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(predicate(), "Push stream timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.PushStream.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        prefs.set(0,forKey:"AutoCloseGitProgress")
        let client = root.appendingPathComponent("client"), remoteRoot = root.appendingPathComponent("remote.git")
        for dir in [client,remoteRoot] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        let repo = GitRepository(root:client,executable:git), remote = GitRepository(root:remoteRoot,executable:git)
        _ = try await repo.run(["init","-b","main"]); _ = try await remote.run(["init","--bare"])
        for (key,value) in [("user.name","Push stream QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        try await repo.saveRemote(name:"origin",fetchURL:remoteRoot.path,pushURL:"",existing:false)
        let head = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release"), flood = URL(fileURLWithPath:helper.path+".flood")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${4-}" = push ] && [ ! -f "$0.release" ]; then
          printf '\\351\\233' >&2
          /bin/sleep 0.02
          printf '\\252\\360\\237\\220\\242\\n' >&2
          printf 'Writing objects: 10%% (1/10)\\rWriting objects: 50%% (5/10)\\r' >&2
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
        let wrapped = GitRepository(root:client,executable:helper)
        func pids() throws -> [Int32] { try String(contentsOf:marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) } }
        func resume() throws { let ids = try pids(); precondition(ids.count == 2); try Data().write(to:release); _ = kill(ids[1],SIGTERM) }
        func clear() throws { for url in [marker,release,flood] where FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
        func sourceState() async throws -> [Data] { [try await repo.run(["rev-parse","HEAD"]).stdout, try Data(contentsOf:client.appendingPathComponent(".git/index")), try Data(contentsOf:client.appendingPathComponent("file"))] }
        let before = try await sourceState()
        // Output and phase arrive while the owned push process is still blocked.
        let owner = PushWindowModel(repository:wrapped,access:nil,preferences:prefs); owner.load(); try await wait { !owner.busy }; owner.options.setUpstream = false; owner.options.destination = "live"
        var result:PushProgressWindowModel?, raw = "", callbacks = 0, closes = 0
        owner.onProgress = { result = $0 }; owner.onTransportResult = { output,success in precondition(success); raw = output; callbacks += 1 }; owner.close = { closes += 1 }
        owner.push(); try await wait { result?.percentage == 50 && result?.output.contains("雪🐢") == true && FileManager.default.fileExists(atPath:marker.path) }
        precondition(result!.busy && owner.transportRunning && callbacks == 0 && result!.currentWork == "Writing objects" && !result!.output.contains("10%"))
        let host = NSHostingView(rootView:PushProgressDialog(owner:owner,result:result!)); host.frame = NSRect(x:0,y:0,width:760,height:430); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        try resume(); try await wait { !result!.busy }; precondition(result!.success && callbacks == 1 && raw.contains("refs/heads/live") && raw.contains("10%") && raw.contains("50%"))
        precondition(result!.output.contains("雪🐢") && result!.output.contains("refs/heads/live") && !result!.output.contains("10%"))
        let received = try await remote.run(["rev-parse","refs/heads/live"]).text.trimmingCharacters(in:.newlines); precondition(received == head)
        result!.close(); precondition(closes == 1 && owner.progress == nil); try clear()
        // No leaves the process alive; Yes cancels its owned group and drains output.
        prefs.set(true,forKey:"ConfirmKillProcess")
        let cancelled = PushWindowModel(repository:wrapped,access:nil,preferences:prefs); cancelled.load(); try await wait { !cancelled.busy }; cancelled.options.setUpstream = false; cancelled.options.destination = "cancelled"
        var stopped:PushProgressWindowModel?; cancelled.onProgress = { stopped = $0 }; cancelled.push(); try await wait { stopped?.percentage == 50 && FileManager.default.fileExists(atPath:marker.path) }
        let ids = try pids(); cancelled.confirmCancellation = { $0(false) }; cancelled.cancel(); precondition(stopped!.busy && !cancelled.cancelling && ids.allSatisfy { kill($0,0) == 0 })
        cancelled.confirmCancellation = { $0(true) }; cancelled.cancel(); try await wait { !stopped!.busy }; try await wait { ids.allSatisfy { kill($0,0) != 0 } }
        precondition(stopped!.cancelled && !stopped!.success && stopped!.output.contains("雪🐢") && stopped!.postActions == [.push]); stopped!.close(); try clear()
        let refs = try await remote.checkoutReferences(); precondition(!refs.contains { $0.name == "refs/heads/cancelled" })
        let after = try await sourceState(); precondition(before == after)
        // Build a real non-fast-forward rejection after a captured 16 KiB limit.
        _ = try await repo.run(["commit","--allow-empty","-m","remote next"])
        var seed = PushOptions(); seed.source = "main"; seed.remote = "origin"; seed.destination = "rejected"; _ = try await repo.push(seed)
        _ = try await repo.run(["reset","--hard",head]); _ = try await repo.run(["commit","--allow-empty","-m","local diverged"])
        let divergentState = try await sourceState()
        prefs.set(false,forKey:"ConfirmKillProcess"); prefs.set(16,forKey:"GitOutputLimitinKiB"); prefs.set(2,forKey:"AutoCloseGitProgress")
        let limited = PushWindowModel(repository:wrapped,access:nil,preferences:prefs); limited.load(); try await wait { !limited.busy }; limited.options.setUpstream = false; limited.options.destination = "rejected"
        var truncated:PushProgressWindowModel?, failureRaw = "", failureCallbacks = 0, failedCloses = 0
        limited.onProgress = { truncated = $0; prefs.set(100*1024,forKey:"GitOutputLimitinKiB") }
        limited.onTransportResult = { output,success in precondition(!success); failureRaw = output; failureCallbacks += 1 }; limited.close = { failedCloses += 1 }
        try Data().write(to:flood); limited.push(); try await wait { truncated?.output.contains("Output truncated") == true && FileManager.default.fileExists(atPath:marker.path) }
        precondition(truncated!.busy && truncated!.percentage == nil && truncated!.outputLimit == 16*1024)
        try resume(); try await wait { !truncated!.busy }
        precondition(!truncated!.success && failureCallbacks == 1 && failureRaw.contains("[rejected]") && failureRaw.contains("payload 5999"))
        precondition(truncated!.postActions == [.pull,.fetch,.push] && !truncated!.output.contains("[rejected]") && !truncated!.output.contains("payload 5999") && truncated!.output.contains("Push to origin failed") && failedCloses == 0)
        truncated!.close(); try clear(); precondition(failedCloses == 1)
        let unchanged = try await sourceState(); precondition(unchanged == divergentState)
        print("Push live output, split Unicode/CR replacement, phase/percentage, hidden host, full raw callback, real refs, owned No/Yes cancellation, captured limit and truncated rejection recovery passed")
    }
}
