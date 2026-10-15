import AppKit
import Darwin
import TurtleGitCore

@main struct RemoteDialogsVerification {
    @MainActor static func main() async {
        do { try await run(); print("PASS remote dialogs: real local Add/collision, captured inputs, source chooser defaults/editing/refresh, captured Fetch/Pull remote, cancel/retirement fences and Quit accounting") }
        catch { fputs("FAIL remote dialogs: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root,executable: URL(fileURLWithPath: CommandLine.arguments[2]),askpass: nil)
        _ = try await repository.run(["init","-b","main"])
        let add = AddRemoteWindowModel(repository: repository,access: nil)
        var closes = 0; add.close = { closes += 1 }; add.name = "origin"; add.url = root.path
        func wait(_ ready: () -> Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw NSError(domain: "Remote dialogs timeout",code: 1) }
        add.save(); add.name = "changed-after-click"; add.url = "different"
        try await wait { !add.busy }; precondition(closes == 1)
        let settings = try await repository.remoteSettings(name: "origin"); precondition(settings.url == root.path)
        add.name = "origin"; add.url = "new-url"; add.save(); try await wait { !add.busy }
        precondition(add.error != nil && closes == 1)
        let unchanged = try await repository.remoteSettings(name: "origin"); precondition(unchanged.url == root.path)
        add.retire(); add.save(); precondition(!add.busy)

        let selector = RemoteReferenceWindowModel(repository: repository,access: nil,remote: "captured-origin")
        var captured = ""; selector.query = { remote,_ in captured = remote; return ["branch2","branch10"] }
        selector.refresh(); try await wait { !selector.busy }
        precondition(captured == "captured-origin" && selector.branch == "branch2" && selector.canAccept)
        var chosen: [String] = []; selector.accept = { chosen.append($0) }; selector.branch = "typed-case-sensitive"; selector.choose(); precondition(chosen == ["typed-case-sensitive"])
        selector.query = { _,_ in [] }; selector.refresh(); try await wait { !selector.busy }; precondition(!selector.canAccept && selector.branch.isEmpty)
        selector.query = { _,_ in throw NSError(domain: "Fixture remote failure",code: 1) }; selector.refresh(); try await wait { !selector.busy }; precondition(selector.error != nil && selector.refs.isEmpty)
        var release: CheckedContinuation<[String],Error>?
        selector.query = { _,_ in try await withCheckedThrowingContinuation { release = $0 } }
        selector.refresh(); try await wait { release != nil }
        precondition(RemoteReferenceWindowModel.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        selector.requestClose(); precondition(selector.busy && selector.cancelling)
        selector.close = { closes += 1 }; release?.resume(returning: ["late-result"]); release = nil
        try await wait { !selector.busy }; precondition(selector.refs.isEmpty && closes == 2 && RemoteReferenceWindowModel.activeOperations == 0)
        selector.retire(); selector.refresh(); precondition(!selector.busy)
        let retired = RemoteReferenceWindowModel(repository: repository,access: nil,remote: "another")
        retired.query = { _,_ in try await withCheckedThrowingContinuation { release = $0 } }
        retired.refresh(); try await wait { release != nil }; retired.retire()
        release?.resume(returning: ["discarded"]); release = nil; try await wait { !retired.busy }; precondition(retired.refs.isEmpty)
        for pull in [false,true] {
            let fetch = FetchWindowModel(repository: repository,access: nil,isPull: pull)
            fetch.options.arbitraryURL = true; fetch.url = root.path
            var targets: [String] = []; fetch.onBrowseRemote = { targets.append($0) }
            fetch.browse(); fetch.url = "edited-later"; fetch.browse()
            precondition(targets == [root.path] && fetch.browsing && fetch.operationActive)
            fetch.selectBranch("topic"); fetch.selectBranch("TOPIC"); precondition(fetch.options.branch == "TOPIC" && fetch.branchHistory.contains("topic") && fetch.branchHistory.contains("TOPIC"))
            fetch.selectBranch("é"); fetch.selectBranch("e\u{301}"); precondition(Set(fetch.branchHistory.prefix(2).map { Data($0.utf8) }).count == 2)
            fetch.invalidate(); precondition(!fetch.browsing)
            let suite = "TurtleGit.RemoteDialogs.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let parent = FetchWindowController(repository: repository,access: nil,isPull: pull,preferences: preferences)
            defer { parent.close() }
            parent.model.options.arbitraryURL = true; parent.model.url = root.path
            parent.configureRemoteReferences = { child in child.model.query = { _,_ in ["first","second"] } }
            parent.model.browse()
            guard let child = parent.remoteReferenceController else { throw NSError(domain: "Remote picker not owned",code: 1) }
            try await wait { !child.model.busy }
            precondition(child.window?.sheetParent === parent.window && child.model.branch == "first")
            child.model.branch = "second"; child.model.choose()
            try await wait { parent.remoteReferenceController == nil && parent.window?.attachedSheet == nil }
            precondition(!parent.model.browsing && parent.model.options.branch == "second")
            parent.presentRemoteReferences = { _,_ in false }; parent.model.browse()
            precondition(parent.remoteReferenceController == nil && !parent.model.browsing)
            parent.close()
        }
        try await transportPickers(git: URL(fileURLWithPath: CommandLine.arguments[2]))
        precondition(AddRemoteWindowModel.activeOperations == 0 && !NSApp.windows.contains { $0.isVisible })
    }
    @MainActor static func transportPickers(git: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitTransportPickers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Picker QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "release", first])
        try Data("tip\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "tip")
        let tip = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        for remote in ["origin", "team/nested"] { _ = try await repo.run(["config", "remote." + remote + ".url", root.path]); _ = try await repo.run(["config", "remote." + remote + ".fetch", "+refs/heads/*:refs/remotes/" + remote + "/*"]) }
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", tip]); _ = try await repo.run(["update-ref", "refs/remotes/team/nested/topic/one", tip])
        _ = try await repo.run(["config", "branch.main.remote", "origin"]); _ = try await repo.run(["config", "branch.main.merge", "refs/heads/main"])
        let suite = "TurtleGit.TransportPickers." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "EnableGravatar")
        func wait(_ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw NSError(domain: "Transport picker timeout", code: 1) }
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: message, code: 1) } }
        func choose(_ picker: ReferenceBrowserWindowController, _ name: GitReferenceName) {
            picker.model.nested = true; picker.model.setFolder("refs"); picker.model.select([name], last: name); picker.model.accept()
        }
        let regex = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let push = PushWindowController(repository: repo, access: nil, preferences: prefs, historyRegexExecutable: regex)
        defer { push.close() }; push.window!.alphaValue = 0; push.showWindow(nil); push.model.load(); try await wait { !push.model.busy && !push.model.preparing }
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config")), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var configured = 0; push.configureReferencePicker = { if $0.preferences === prefs { configured += 1 } }
        push.showReferencePicker(destination: false); try await wait { push.referencePicker?.model.busy == false }
        try check(push.model.choosingReference && !push.model.canCancel && configured == 1, "Push did not own reference picker or private preferences")
        try check(push.referencePicker!.model.scope == .headsAndTags && push.referencePicker!.window!.alphaValue == 0, "Push source scope/alpha did not match owner")
        push.model.push(); try check(push.model.progress == nil && !push.model.busy, "Push submitted while picker owned draft")
        choose(push.referencePicker!, "refs/tags/release")
        try await wait { !push.model.choosingReference && !push.model.preparing && push.window!.attachedSheet == nil }
        try check(push.model.options.source == "refs/tags/release", "Push source tag lost canonical namespace")
        push.showReferencePicker(destination: true); try await wait { push.referencePicker?.model.busy == false }
        choose(push.referencePicker!, "refs/remotes/team/nested/topic/one")
        try await wait { !push.model.choosingReference && push.window!.attachedSheet == nil }
        try check(push.model.options.remote == "team/nested" && push.model.options.destination == "topic/one" && !push.model.options.arbitraryURL && !push.model.options.allRemotes, "Push destination split slash-containing remote incorrectly")
        push.showReferencePicker(destination: false); try await wait { push.referencePicker?.model.busy == false }
        push.model.options.destination = "edited draft"; choose(push.referencePicker!, "refs/heads/main")
        try await wait { !push.model.choosingReference && push.window!.attachedSheet == nil }
        try check(push.model.options.source == "refs/tags/release" && push.model.options.destination == "edited draft", "Stale source picker clobbered changed Push draft")
        var logConfigured = false; push.configureLogPicker = { logConfigured = $0.colorPreferences === prefs }
        push.showSourceHistory(referenceLog: false); try await wait { push.sourceLogPicker?.model.busy == false && push.sourceLogPicker?.model.entries.isEmpty == false }
        let log = push.sourceLogPicker!; try check(logConfigured && log.model.endRevision == "refs/tags/release" && !log.model.showWorkingTree && log.window!.alphaValue == 0, "Push Log lost source/selection/preferences/alpha")
        log.model.finishSelection(log.model.entries.first { $0.hash == first })
        try await wait { !push.model.choosingReference && !push.model.preparing && push.window!.attachedSheet == nil }
        try check(push.model.options.source == first, "Push Log did not apply captured old commit")
        push.showSourceHistory(referenceLog: true); try await wait { push.sourceRefLogPicker?.model.commandSurfaceAvailable == true && push.sourceRefLogPicker?.model.entries.isEmpty == false }
        let reflog = push.sourceRefLogPicker!; try check(reflog.model.selecting && reflog.window!.alphaValue == 0, "Push RefLog lost selection owner")
        reflog.model.close(); try await wait { !push.model.choosingReference && push.window!.attachedSheet == nil }
        try check(push.model.options.source == first, "Push RefLog Cancel changed source")
        push.close()
        for pull in [false, true] {
            let fetch = FetchWindowController(repository: repo, access: nil, isPull: pull, preferences: prefs); defer { fetch.close() }
            fetch.window!.alphaValue = 0; fetch.model.options.remote = "origin"; fetch.model.options.branch = "draft"
            fetch.configureRemoteReferences = { $0.model.query = { _, _ in ["first", "second"] } }
            fetch.model.browse(); try await wait { fetch.remoteReferenceController?.model.busy == false }
            try check(fetch.remoteReferenceController!.window!.alphaValue == 0, "Remote selector did not inherit parent visibility")
            fetch.model.options.branch = "edited while child open"; fetch.remoteReferenceController!.model.branch = "second"; fetch.remoteReferenceController!.model.choose()
            try await wait { !fetch.model.browsing && fetch.window!.attachedSheet == nil }
            try check(fetch.model.options.branch == "edited while child open", "Stale remote branch result clobbered changed draft")
            fetch.model.browse(); try await wait { fetch.remoteReferenceController?.model.busy == false }; fetch.close()
            try await wait { fetch.model.closed && RemoteReferenceWindowModel.activeOperations == 0 }
            try check(fetch.remoteReferenceController == nil && !fetch.model.browsing, "Retired Fetch/Pull retained remote selector")
        }
        let sync = SynchronizationWindowController(repository: repo, access: nil, preferences: prefs); defer { sync.close() }
        sync.window!.alphaValue = 0; sync.model.reload(initial: true); try await wait { !sync.model.busy }
        sync.showBranchPicker(.remote); try await wait { sync.branchPicker?.model.busy == false }
        choose(sync.branchPicker!, "refs/remotes/team/nested/topic/one")
        try await wait { !sync.model.choosingBranch && !sync.model.busy && sync.window!.attachedSheet == nil }
        try check(sync.model.remote == "team/nested" && sync.model.remoteBranch == "topic/one", "Sync selected wrong remote/branch namespace")
        sync.showBranchPicker(.remote); try await wait { sync.branchPicker?.model.busy == false }
        sync.model.remoteBranch = "retained draft"; choose(sync.branchPicker!, "refs/remotes/origin/main")
        try await wait { !sync.model.choosingBranch && sync.window!.attachedSheet == nil }
        try check(sync.model.remote == "team/nested" && sync.model.remoteBranch == "retained draft", "Sync stale picker clobbered changed inputs")
        sync.close()
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\''") + "'" }
        let helper = root.appendingPathComponent(".git/picker-git"), gate = root.appendingPathComponent(".git/picker-gate"), ready = root.appendingPathComponent(".git/picker-ready")
        let script = """
        #!/bin/sh
        if [ -f \(quote(gate.path)) ]; then
          for argument in "$@"; do
            if [ "$argument" = for-each-ref ]; then
              echo $$ > \(quote(ready.path))
              while :; do /bin/sleep 0.02; done
            fi
          done
        fi
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let closing = PushWindowController(repository: GitRepository(root: root, executable: helper), access: nil, preferences: prefs)
        defer { closing.close() }; closing.window!.alphaValue = 0; closing.model.load(); try await wait { !closing.model.busy && !closing.model.preparing }
        try Data().write(to: gate); closing.showReferencePicker(destination: false); try await wait { FileManager.default.fileExists(atPath: ready.path) }
        let pid = pid_t(try String(contentsOf: ready).trimmingCharacters(in: .whitespacesAndNewlines))!
        try check(ReferenceBrowserWindowModel.activeReads > 0 && kill(pid, 0) == 0, "Reference picker had no owned active reader")
        closing.close(); try await wait { closing.model.closed && ReferenceBrowserWindowModel.activeReads == 0 }
        try check(closing.referencePicker == nil && !closing.model.choosingReference && kill(pid, 0) == -1 && errno == ESRCH, "Forced Push close leaked child/read or selection state")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try check(head == tip && Data(contentsOf: root.appendingPathComponent(".git/config")) == config && Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Picker-only workflows changed Git state")
        print("Transport reference family: scoped shared Push source/destination, tag and nested remote names, private source Log/RefLog, blocked submission, stale Push/Fetch/Pull/Sync draft refusal, post-sheet selection, forced started-reader cancellation/reaping and unchanged HEAD/config/index passed.")
    }

}
