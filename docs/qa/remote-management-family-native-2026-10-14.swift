import AppKit
import TurtleGitCore

@main struct RemoteManagementFamilyVerification {
    enum Failure: Error { case assertion(String), timeout(UInt) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure.timeout(line) }
    @MainActor static func main() async {
        do { try await verify(); print("PASS: Remote rename/remove exact Sync history cleanup, timed origin hint retirement, manager catalog draft preservation, Pull/Fetch reload and collision Quit ownership") }
        catch {
            for _ in 0..<2000 { if RemoteSettingsWindowModel.activeOperations == 0 && PushWindowModel.activePreparationReads == 0 && FetchWindowModel.activePreparationReads == 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            fputs("Remote management failed: \(error)\n", stderr); exit(1)
        }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git, askpass: nil)
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Remote QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let file = root.appendingPathComponent("file"); try Data("base\n".utf8).write(to:file); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf:file)
        let suite = "TurtleGit.RemoteManagement." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let settings = RemoteSettingsWindowModel(repository:repo,access:nil,preferences:prefs,noFetch:true); defer { settings.invalidate() }
        settings.originHintDelay = 0; settings.load(); try await wait { !settings.busy && settings.originHint != nil }
        settings.edit(.url) { $0.url = root.path }; try require(settings.draft.name == "origin" && settings.originHint == nil,"URL autofill/hint lifetime")
        settings.confirm = { _ in (true,false) }; settings.save(); try await wait { !settings.busy && RemoteSettingsWindowModel.activeOperations == 0 }
        _ = try await repo.run(["config","branch.main.remote","origin"]); _ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        let history = "TurtleGit.Sync." + root.path + ".urls", otherHistory = "TurtleGit.Sync." + root.path + "/other.urls"
        let url = "https://example.invalid/origin", caseName = "Origin"
        prefs.set(["origin",caseName,url,"unchanged"],forKey:history); prefs.set(["origin"],forKey:otherHistory)
        settings.edit(.name) { $0.name = "renamed" }; settings.rename(); try await wait { !settings.busy && RemoteSettingsWindowModel.activeOperations == 0 }
        try require(settings.error == nil && prefs.stringArray(forKey:history) == [caseName,url,"unchanged"] && prefs.stringArray(forKey:otherHistory) == ["origin"],"Rename history cleanup crossed case/URL/repository")
        prefs.set(["renamed",caseName,url],forKey:history)
        let push = PushWindowModel(repository:repo,access:nil,preferences:prefs); defer { push.invalidate() }; push.load(); try await wait { !push.busy && PushWindowModel.activePreparationReads == 0 }
        push.options.destination = "typed-branch"; push.options.force = true; push.options.pushOption = "native-choice"; push.options.submodules = .onDemand
        settings.remove(); try await wait { !settings.busy && RemoteSettingsWindowModel.activeOperations == 0 }
        try require(settings.error == nil && prefs.stringArray(forKey:history) == [caseName,url],"Remove did not prune exact renamed history")
        _ = try await repo.run(["remote","add","replacement",root.path]); _ = try await repo.run(["config","branch.main.remote","replacement"])
        push.refreshRemoteCatalog(); try await wait { !push.busy && PushWindowModel.activePreparationReads == 0 }
        try require(push.remotes == ["replacement"] && push.options.remote == "replacement" && push.options.destination == "typed-branch" && push.options.force && push.options.pushOption == "native-choice" && push.options.submodules == .onDemand,"Catalog refresh reset Push draft")
        push.options.arbitraryURL = true; push.url = "https://example.invalid/typed"; push.refreshRemoteCatalog(); try await wait { !push.busy && PushWindowModel.activePreparationReads == 0 }
        try require(push.options.arbitraryURL && push.url == "https://example.invalid/typed", "Catalog replaced arbitrary destination")
        for pull in [false,true] {
            let fetch = FetchWindowModel(repository:repo,access:nil,isPull:pull,preferences:prefs); defer { fetch.invalidate() }
            fetch.load(); try await wait { !fetch.busy && FetchWindowModel.activePreparationReads == 0 }
            fetch.options.branch = "typed-remote-branch"; fetch.squash = true; fetch.options.tags = .enabled
            fetch.remoteSettings.remotes = ["replacement"]; fetch.reloadRemotes(); try await wait { FetchWindowModel.activePreparationReads == 0 }
            try require(fetch.options.remote == "replacement" && fetch.options.branch == "typed-remote-branch" && fetch.squash && fetch.options.tags == .enabled,"Fetch/Pull remote adoption reset draft")
        }
        let sync = SynchronizationWindowModel(repository:repo,access:nil,preferences:prefs); defer { sync.invalidate() }
        sync.localBranch = "main"; sync.remote = "renamed"; sync.remoteWasSelected = true; sync.remoteBranch = "typed-branch"
        sync.reload(refreshRemoteSelection:true); try await wait { !sync.busy }
        try require(!sync.remoteChoices.contains("renamed") && sync.remoteBranch == "typed-branch", "Sync retained removed history or reset typed branch")
        let retired = RemoteSettingsWindowModel(repository:repo,access:nil,preferences:prefs,noFetch:true); retired.originHintDelay = 0; retired.load(); retired.invalidate()
        try await wait { RemoteSettingsWindowModel.activeOperations == 0 }; try require(retired.originHint == nil,"Retired hint was published")
        let wrapper=root.appendingPathComponent("collision-git"),ready=root.appendingPathComponent("collision-ready")
        try Data(#"""
        #!/bin/sh
        task_next=""; task_root=""; task_command=""
        for task_argument in "$@"; do
          if [ -n "$task_next" ]; then
            if [ "$task_next" = root ]; then task_root="$task_argument"; fi
            task_next=""; continue
          fi
          case "$task_argument" in
            -C) task_next=root ;;
            -c|--git-dir|--work-tree|--namespace|--config-env) task_next=skip ;;
            -*) ;;
            *) task_command="$task_argument"; break ;;
          esac
        done
        if [ "$task_command" = config ]; then : > "$task_root/collision-ready"; /bin/sleep 30; fi
        exec "$TG_REMOTE_GIT" "$@"
        """#.utf8).write(to:wrapper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        setenv("TG_REMOTE_GIT",git.path,1); defer { unsetenv("TG_REMOTE_GIT") }
        let pending = RemoteSettingsWindowModel(repository:GitRepository(root:root,executable:wrapper,askpass:nil),access:nil,preferences:prefs,noFetch:true)
        defer { pending.invalidate() }
        pending.edit(.name) { $0.name = "collision-candidate" }; try await wait { FileManager.default.fileExists(atPath:ready.path) }
        try require(RemoteSettingsWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Collision read lacks Quit ownership")
        pending.invalidate(); try await wait { RemoteSettingsWindowModel.activeOperations == 0 }; try require(!pending.collision && pending.error == nil,"Retired collision reply was published")
        let catalogWrapper=root.appendingPathComponent("catalog-git"),gate=root.appendingPathComponent("catalog-gate"),catalogReady=root.appendingPathComponent("catalog-ready")
        try Data(#"""
        #!/bin/sh
        task_next=""; task_root=""; task_command=""
        for task_argument in "$@"; do
          if [ -n "$task_next" ]; then
            if [ "$task_next" = root ]; then task_root="$task_argument"; fi
            task_next=""; continue
          fi
          case "$task_argument" in
            -C) task_next=root ;;
            -c|--git-dir|--work-tree|--namespace|--config-env) task_next=skip ;;
            -*) ;;
            *) task_command="$task_argument"; break ;;
          esac
        done
        if [ "$task_command" = remote ] && [ -f "$task_root/catalog-gate" ]; then
          : > "$task_root/catalog-ready"; while [ -f "$task_root/catalog-gate" ]; do /bin/sleep 0.1; done
        fi
        exec "$TG_REMOTE_GIT" "$@"
        """#.utf8).write(to:catalogWrapper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:catalogWrapper.path)
        let catalog = PushWindowModel(repository:GitRepository(root:root,executable:catalogWrapper,askpass:nil),access:nil,preferences:prefs); defer { catalog.invalidate(); try? FileManager.default.removeItem(at:gate) }
        catalog.options = push.options; catalog.url = push.url
        try Data().write(to:gate); catalog.refreshRemoteCatalog(); try await wait { FileManager.default.fileExists(atPath:catalogReady.path) }
        catalog.cancel(); try FileManager.default.removeItem(at:gate); try await wait { PushWindowModel.activePreparationReads == 0 }
        try require(catalog.preparationNeedsRetry,"Cancelled catalog remained submittable")
        catalog.retryPreparation(); try await wait { !catalog.busy && PushWindowModel.activePreparationReads == 0 }
        try require(!catalog.preparationNeedsRetry && catalog.options.destination == "typed-branch" && catalog.options.force && catalog.options.arbitraryURL && catalog.url == push.url,"Catalog Retry used source defaults/reset draft")
        try? FileManager.default.removeItem(at:catalogReady); try Data().write(to:gate); catalog.refreshRemoteCatalog(); try await wait { FileManager.default.fileExists(atPath:catalogReady.path) }
        catalog.invalidate(); try FileManager.default.removeItem(at:gate); try await wait { PushWindowModel.activePreparationReads == 0 }
        try require(catalog.closed && !catalog.preparationNeedsRetry,"Retired catalog published a failure")
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")), afterBytes = try Data(contentsOf:file)
        try require(head == afterHead && index == afterIndex && bytes == afterBytes,"Remote settings changed HEAD/index/worktree")
    }
}
