import AppKit
import SwiftUI
import TurtleGitCore

@main struct FetchPullStreamVerification {
    @MainActor static func wait(_ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(predicate(), "Fetch/Pull stream timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.FetchPullStream.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        prefs.set(0,forKey:"AutoCloseGitProgress")
        let producerRoot = root.appendingPathComponent("producer"); try FileManager.default.createDirectory(at:producerRoot,withIntermediateDirectories:true)
        let producer = GitRepository(root:producerRoot,executable:git)
        _ = try await producer.run(["init","-b","main"])
        for (key,value) in [("user.name","Fetch Pull stream QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message:"base")
        let base = try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        for name in ["fetch","rebase","pull","cancel-fetch","cancel-pull","limited"] { _ = try await producer.run(["clone",producerRoot.path,root.appendingPathComponent(name).path]) }
        try Data("remote\n".utf8).write(to:producerRoot.appendingPathComponent("remote.txt")); try await producer.stage(["remote.txt"]); _ = try await producer.commit(message:"remote advancement")
        let target = try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release"), flood = URL(fileURLWithPath:helper.path+".flood")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if { [ "${4-}" = fetch ] || [ "${4-}" = pull ]; } && [ ! -f "$0.release" ]; then
          printf '\\351\\233' >&2
          /bin/sleep 0.02
          printf '\\252\\360\\237\\220\\242\\n' >&2
          printf 'remote: Receiving objects: 10%% (1/10)\\rremote: Receiving objects: 50%% (5/10)\\r' >&2
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
        func resume() throws { let ids = try pids(); precondition(ids.count == 2); try Data().write(to:release); _ = kill(ids[1],SIGTERM) }
        func clear() throws { for url in [marker,release,flood] where FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
        var fetch = FetchOptions(); fetch.remote = "origin"; fetch.branch = "main"
        for name in ["fetch","rebase","pull"] {
            let client = root.appendingPathComponent(name), repo = GitRepository(root:client,executable:helper), actual = GitRepository(root:client,executable:git)
            _ = try await actual.run(["config","core.hooksPath","/dev/null"])
            try Data("staged\n".utf8).write(to:client.appendingPathComponent("file")); try await actual.stage(["file"])
            try Data("later working\n".utf8).write(to:client.appendingPathComponent("file"))
            let beforeIndex = try Data(contentsOf:client.appendingPathComponent(".git/index"))
            if name == "pull" {
                var options = PullOptions(); options.fetch = fetch
                let model = PullProgressWindowModel(repository:repo,access:nil,options:options,followUp:PullFollowUp(),preferences:prefs); var completed=0; model.onCompleted = { completed += 1 }; model.start()
                try await wait { model.percentage == 50 && model.output.contains("雪🐢") && FileManager.default.fileExists(atPath:marker.path) }
                precondition(model.busy && completed == 0 && model.currentWork == "remote: Receiving objects" && !model.output.contains("10%"))
                let host = NSHostingView(rootView:PullProgressDialog(model:model)); host.frame = NSRect(x:0,y:0,width:760,height:430); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
                try resume(); try await wait { !model.busy }; precondition(model.success && completed == 1 && model.oldHead == base && model.newHead == target && model.rawOutput.contains("10%") && model.rawOutput.contains("50%") && !model.output.contains("10%"))
                model.invalidate()
            } else {
                let model = FetchProgressWindowModel(repository:repo,access:nil,options:fetch,preferences:prefs,rebaseMode:name == "rebase" ? .automatic : .none); var completed=0, rebases=0, closes=0
                model.onCompleted = { completed += 1 }; model.close = { closes += 1 }; model.onRebase = { revision,automatic,_ in precondition(revision == target && automatic); rebases += 1 }; model.start()
                try await wait { model.percentage == 50 && model.output.contains("雪🐢") && FileManager.default.fileExists(atPath:marker.path) }
                precondition(model.busy && completed == 0 && !model.output.contains("10%"))
                let host = NSHostingView(rootView:FetchProgressDialog(model:model)); host.frame = NSRect(x:0,y:0,width:760,height:430); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
                try resume(); try await wait { !model.busy }; precondition(model.success && completed == 1 && model.rawOutput.contains("10%") && !model.output.contains("10%"))
                precondition(rebases == (name == "rebase" ? 1 : 0) && closes == (name == "rebase" ? 1 : 0)); model.invalidate()
                let afterIndex = try Data(contentsOf:client.appendingPathComponent(".git/index")); precondition(beforeIndex == afterIndex)
            }
            let head = try await actual.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines), tracking = try await actual.run(["rev-parse","refs/remotes/origin/main"]).text.trimmingCharacters(in:.newlines)
            precondition(head == (name == "pull" ? target : base) && tracking == target)
            let staged = try await actual.run(["show",":file"]).text, working = try Data(contentsOf:client.appendingPathComponent("file")); precondition(staged == "staged\n" && working == Data("later working\n".utf8)); try clear()
        }
        prefs.set(true,forKey:"ConfirmKillProcess")
        for name in ["cancel-fetch","cancel-pull"] {
            let client = root.appendingPathComponent(name), actual = GitRepository(root:client,executable:git), repo = GitRepository(root:client,executable:helper)
            let beforeIndex = try Data(contentsOf:client.appendingPathComponent(".git/index"))
            if name == "cancel-fetch" {
                let model = FetchProgressWindowModel(repository:repo,access:nil,options:fetch,preferences:prefs); model.start(); try await wait { model.percentage == 50 && FileManager.default.fileExists(atPath:marker.path) }; let ids = try pids()
                model.confirmCancellation = { $0(false) }; model.cancel(); precondition(model.busy && !model.cancelling && ids.allSatisfy { kill($0,0) == 0 }); model.confirmCancellation = { $0(true) }; model.cancel(); try await wait { !model.busy }; try await wait { ids.allSatisfy { kill($0,0) != 0 } }; precondition(model.cancelled && !model.success && model.rawOutput.contains("雪🐢") && model.postActions == [.retry], "Fetch cancelled result must retain raw Unicode and Retry"); model.invalidate()
            } else {
                var options = PullOptions(); options.fetch = fetch
                let model = PullProgressWindowModel(repository:repo,access:nil,options:options,followUp:PullFollowUp(),preferences:prefs); model.start(); try await wait { model.percentage == 50 && FileManager.default.fileExists(atPath:marker.path) }; let ids = try pids()
                model.confirmCancellation = { $0(false) }; model.cancel(); precondition(model.busy && !model.cancelling && ids.allSatisfy { kill($0,0) == 0 }); model.confirmCancellation = { $0(true) }; model.cancel(); try await wait { !model.busy }; try await wait { ids.allSatisfy { kill($0,0) != 0 } }; precondition(model.cancelled && !model.success && model.rawOutput.contains("雪🐢") && model.postActions.contains(.pull), "Pull cancelled result must retain raw Unicode and recovery"); model.invalidate()
            }
            let head = try await actual.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines), afterIndex = try Data(contentsOf:client.appendingPathComponent(".git/index")); precondition(head == base && beforeIndex == afterIndex); try clear()
        }
        prefs.set(false,forKey:"ConfirmKillProcess"); prefs.set(16,forKey:"GitOutputLimitinKiB")
        let limitedRoot = root.appendingPathComponent("limited"), actual = GitRepository(root:limitedRoot,executable:git)
        _ = try await actual.run(["remote","set-url","origin",root.appendingPathComponent("missing.git").path])
        let limited = FetchProgressWindowModel(repository:GitRepository(root:limitedRoot,executable:helper),access:nil,options:fetch,preferences:prefs); prefs.set(100*1024,forKey:"GitOutputLimitinKiB"); try Data().write(to:flood); limited.start()
        try await wait { limited.output.contains("Output truncated") && FileManager.default.fileExists(atPath:marker.path) }; precondition(limited.busy && limited.percentage == nil && limited.outputLimit == 16*1024)
        try resume(); try await wait { !limited.busy }; precondition(!limited.success && limited.rawOutput.contains("payload 5999") && limited.rawOutput.contains("missing.git") && !limited.output.contains("payload 5999") && limited.postActions == [.retry])
        _ = try await actual.run(["remote","set-url","origin",producerRoot.path]); limited.perform(.retry); try await wait { !limited.busy }; precondition(limited.success && !limited.output.contains("Output truncated") && !limited.rawOutput.contains("payload") && limited.outputLimit == 16*1024); limited.invalidate(); try clear()
        // Pull uses the same captured display limit while retaining non-conflict recovery.
        prefs.set(16,forKey:"GitOutputLimitinKiB")
        _ = try await actual.run(["remote","set-url","origin",root.appendingPathComponent("missing.git").path])
        var limitedPullOptions = PullOptions(); limitedPullOptions.fetch = fetch
        let limitedPull = PullProgressWindowModel(repository:GitRepository(root:limitedRoot,executable:helper),access:nil,options:limitedPullOptions,followUp:PullFollowUp(),preferences:prefs)
        prefs.set(100*1024,forKey:"GitOutputLimitinKiB"); try Data().write(to:flood); limitedPull.start()
        try await wait { limitedPull.output.contains("Output truncated") && FileManager.default.fileExists(atPath:marker.path) }
        precondition(limitedPull.busy && limitedPull.percentage == nil && limitedPull.outputLimit == 16*1024)
        try resume(); try await wait { !limitedPull.busy }
        precondition(!limitedPull.success && limitedPull.rawOutput.contains("payload 5999") && limitedPull.rawOutput.contains("missing.git") && !limitedPull.output.contains("payload 5999") && limitedPull.postActions.contains(.pull) && limitedPull.postActions.contains(.reset))
        limitedPull.invalidate(); try clear()
        print("Fetch/Pull live Unicode/remote CR/percentage, ordinary/Rebase/pull real effects and mixed changes, hidden hosts, raw diagnostics, No/Yes owned cancellation, captured limit and fresh Retry passed")
    }
}
