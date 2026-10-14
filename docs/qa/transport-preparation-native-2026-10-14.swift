import AppKit
import TurtleGitCore

@main struct TransportPreparationVerification {
    enum Failure: Error { case assertion(String), timeout(UInt) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure.assertion(message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure.timeout(line)
    }
    @MainActor static func main() async {
        do { try await verify(); print("PASS: Transport preparation snapshot/cancel/retry/source replacement, normal/forced close/Quit and Push post-cancel hook ownership") }
        catch {
            for window in NSApp.windows {
                if let owner = window.delegate as? PushWindowController { owner.close() }
                if let owner = window.delegate as? FetchWindowController { owner.close() }
            }
            for _ in 0..<3000 {
                if PushWindowModel.activePreparationReads == 0 && PushWindowModel.activePushWorkflows == 0 && FetchWindowModel.activePreparationReads == 0 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            fputs("Transport preparation failed: \(error)\n", stderr); exit(1)
        }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git, askpass: nil)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Preparation QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"]); _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["branch", "topic"])
        let remote = root.appendingPathComponent("remote.git"); _ = try await repo.run(["init", "--bare", remote.path]); _ = try await repo.run(["remote", "add", "origin", remote.path])
        _ = try await repo.run(["config", "branch.main.remote", "origin"]); _ = try await repo.run(["config", "branch.main.merge", "refs/heads/main"])
        _ = try await repo.run(["config", "branch.topic.remote", "origin"]); _ = try await repo.run(["config", "branch.topic.merge", "refs/heads/topic-destination"])
        let preserved = [".git/HEAD", ".git/index", "file"].map { root.appendingPathComponent($0) }, baseline = try preserved.map { try Data(contentsOf: $0) }
        let suite = "TurtleGit.TransportPreparation." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let wrapper = root.appendingPathComponent("gated-git"), gate = root.appendingPathComponent("gate"), ready = root.appendingPathComponent("ready")
        let script = #"""
        #!/bin/sh
        if [ -f "$3/gate" ] && [ "$4" = "$(/bin/cat "$3/gate")" ]; then
          : > "$3/ready"; while [ -f "$3/gate" ]; do /bin/sleep 0.1; done
        fi
        exec "$TG_PREPARATION_GIT" "$@"
        """#
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        setenv("TG_PREPARATION_GIT", git.path, 1); defer { unsetenv("TG_PREPARATION_GIT") }
        let wrapped = GitRepository(root: root, executable: wrapper, askpass: nil)
        func arm(_ command: String) throws { try? FileManager.default.removeItem(at: ready); try Data(command.utf8).write(to: gate) }
        func disarm() { try? FileManager.default.removeItem(at: gate) }
        defer { disarm() }
        for forced in [false, true] {
            try arm("remote")
            let owner = PushWindowController(repository: wrapped, access: nil, preferences: prefs); owner.window?.contentView = nil
            var closed = false; owner.onClosed = { closed = true }; owner.model.load()
            try await wait { FileManager.default.fileExists(atPath: ready.path) }
            try require(owner.model.remotes.isEmpty && owner.model.canCancel, "Push published incomplete initial metadata or disabled Cancel")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Push read lost Quit ownership")
            if forced { owner.close() } else { owner.window?.performClose(nil) }
            try require(PushWindowModel.activePreparationReads > 0, "Push close released worker early")
            try await wait { closed && PushWindowModel.activePreparationReads == 0 }
            try require(owner.model.closed && owner.model.remotes.isEmpty, "Retired Push published late metadata")
            disarm()
        }
        let presetPush = PushWindowModel(repository: wrapped, access: nil, preferences: prefs)
        try arm("remote"); presetPush.load(source: "topic", preserveAllBranches: true); try await wait { FileManager.default.fileExists(atPath: ready.path) }
        presetPush.cancel(); disarm(); try await wait { PushWindowModel.activePreparationReads == 0 }
        presetPush.retryPreparation(); try await wait { PushWindowModel.activePreparationReads == 0 }
        try require(presetPush.options.source == "topic" && presetPush.options.destination == "topic-destination", "Push Retry lost caller preset")
        presetPush.invalidate()
        let push = PushWindowModel(repository: wrapped, access: nil, preferences: prefs); defer { push.invalidate() }
        push.load(); try await wait { !push.busy && PushWindowModel.activePreparationReads == 0 }
        try require(push.options.source == "main" && push.localBranch == "main" && push.options.destination == "main", "Push defaults changed")
        try arm("remote"); push.options.source = "topic"; push.sourceChanged()
        try await wait { FileManager.default.fileExists(atPath: ready.path) }
        push.push(); try require(!push.transportRunning, "Push accepted unresolved source")
        push.cancel(); disarm(); try await wait { !push.preparing && PushWindowModel.activePreparationReads == 0 }
        try require(push.preparationNeedsRetry && push.options.destination == "main", "Cancelled source published stale defaults or accepted submission")
        push.retryPreparation(); try await wait { !push.preparing && PushWindowModel.activePreparationReads == 0 }
        try require(!push.preparationNeedsRetry && push.localBranch == "topic" && push.options.destination == "topic-destination", "Source retry failed")
        try arm("remote"); push.options.source = "main"; push.sourceChanged(); try await wait { FileManager.default.fileExists(atPath: ready.path) }
        disarm(); push.options.source = "topic"; push.sourceChanged(); try await wait { PushWindowModel.activePreparationReads == 0 }
        try require(push.options.destination == "topic-destination", "Superseded source replaced newer metadata")
        for pull in [false, true] {
            for forced in [false, true] {
                try arm("remote")
                let owner = FetchWindowController(repository: wrapped, access: nil, isPull: pull, preferences: prefs); owner.window?.contentView = nil
                var closed = false; owner.onClosed = { closed = true }; owner.model.load()
                try await wait { FileManager.default.fileExists(atPath: ready.path) }
                try require(owner.model.remotes.isEmpty && owner.model.canCancel, "Fetch/Pull partial publication or disabled Cancel")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Fetch/Pull read lost Quit ownership")
                if forced { owner.close() } else { owner.window?.performClose(nil) }
                try require(FetchWindowModel.activePreparationReads > 0, "Fetch/Pull close released read early")
                try await wait { closed && FetchWindowModel.activePreparationReads == 0 }; disarm()
                try require(owner.model.closed && owner.model.remotes.isEmpty, "Retired Fetch/Pull published metadata")
            }
            let model = FetchWindowModel(repository: wrapped, access: nil, isPull: pull, preferences: prefs); defer { model.invalidate() }
            let presetURL = "file://" + remote.path
            try arm("remote"); model.load(remote: presetURL); try await wait { FileManager.default.fileExists(atPath: ready.path) }
            model.cancel(); disarm(); try await wait { !model.preparing && FetchWindowModel.activePreparationReads == 0 }
            try require(model.preparationNeedsRetry && model.operationActive, "Cancelled Fetch/Pull can submit stale metadata")
            model.retryPreparation(); try await wait { !model.busy && FetchWindowModel.activePreparationReads == 0 }
            try require(!model.preparationNeedsRetry && model.remotes == ["origin"] && model.options.branch == "main" && model.options.arbitraryURL && model.url == presetURL, "Fetch/Pull retry/defaults changed")
            let tags = model.tagsDefault; try arm("remote"); model.remoteChanged(); try await wait { FileManager.default.fileExists(atPath: ready.path) }
            model.cancel(); disarm(); try await wait { FetchWindowModel.activePreparationReads == 0 }
            try require(model.preparationNeedsRetry && model.tagsDefault == tags, "Remote cancellation replaced accepted defaults")
            model.retryPreparation(); try await wait { FetchWindowModel.activePreparationReads == 0 }
            try require(!model.preparationNeedsRetry, "Remote retry unavailable")
        }
        let hook = root.appendingPathComponent("post-hook.sh"), events = root.appendingPathComponent("events")
        try Data(#"printf 'post\n' >> "$1/events""#.utf8).write(to: hook)
        let post = ClientHook(type: .postPush, path: root.path, command: "/bin/sh '" + hook.path + "' '%root%'", show: false)
        prefs.set(try ClientHookConfiguration.serialize([post]), forKey: "hooks")
        let transport = PushWindowModel(repository: wrapped, access: nil, preferences: prefs); defer { transport.invalidate() }
        transport.options.remote = "origin"; transport.options.source = "main"; transport.options.destination = "main"
        try arm("push"); transport.push(); try await wait { FileManager.default.fileExists(atPath: ready.path) }
        try require(PushWindowModel.activePushWorkflows == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Push lifecycle not owned")
        transport.cancel(); disarm(); try await wait { PushWindowModel.activePushWorkflows == 0 && !transport.busy && ClientHookProcessPool.shared.activeScripts == 0 }
        try require((try? String(contentsOf: events)) == "post\n", "Cancelled Push skipped fresh post-hook")
        try arm("remote")
        let retiring = PushWindowController(repository: wrapped, access: nil, preferences: prefs); retiring.window?.contentView = nil
        retiring.model.options.remote = "origin"; retiring.model.options.source = "main"; retiring.model.options.destination = "main"
        var lateResults = 0; retiring.model.onTransportResult = { _, _ in lateResults += 1 }
        retiring.model.push(); try await wait { FileManager.default.fileExists(atPath: ready.path) }
        retiring.close(); try require(PushWindowModel.activePushWorkflows == 1, "Forced preflight released workflow before child settlement")
        try await wait { PushWindowModel.activePushWorkflows == 0 }; disarm()
        try require(lateResults == 0 && retiring.model.progress == nil && (try? String(contentsOf: events)) == "post\n", "Retired preflight published progress/result/post-hook")
        let after = try preserved.map { try Data(contentsOf: $0) }; try require(baseline == after, "Preparation changed HEAD/index/worktree")
        try require(PushWindowModel.activePreparationReads == 0 && FetchWindowModel.activePreparationReads == 0, "Preparation workers remain")
    }
}
