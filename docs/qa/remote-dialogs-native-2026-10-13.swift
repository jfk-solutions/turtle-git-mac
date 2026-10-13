import AppKit
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
        precondition(AddRemoteWindowModel.activeOperations == 0 && !NSApp.windows.contains { $0.isVisible })
    }
}
