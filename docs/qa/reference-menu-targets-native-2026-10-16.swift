import AppKit
import TurtleGitCore

struct ReferenceMenuTargetsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String) -> T? {
        if let found = view as? T, found.accessibilityLabel() == label { return found }
        for child in view.subviews { if let found = find(type, child, label: label) { return found } }; return nil
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Menu QA"), ("user.email", "menu@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        for name in ["left", "right", "delete-me", "rename-me"] { _ = try await repo.run(["branch", name]) }
        for name in ["bucket/one", "bucket/two", "keep"] { _ = try await repo.run(["tag", name]) }
        _ = try await repo.run(["remote", "add", "origin", "https://example.invalid/unused"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/topic", "HEAD"])
        _ = try await repo.run(["branch", "--set-upstream-to=origin/topic", "left"])
        _ = try await repo.run(["branch", "--set-upstream-to=origin/topic", "right"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let suite = "TurtleGit.ReferenceMenuTargets." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/left", preferences: prefs, picking: false) { _ in }, model = owner.model
        defer { owner.close() }
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<2500 { owner.window?.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw Failure(description: "Timed out waiting for native reference action")
        }
        model.load(); try await wait { !model.busy && model.snapshot != nil }
        guard let table = find(NSTableView.self, owner.window!.contentView!, label: "References"), let menu = table.menu,
              let tree = find(NSOutlineView.self, owner.window!.contentView!, label: "Reference namespaces"), let folderMenu = tree.menu else { throw Failure(description: "Missing reference native views") }
        func choose(_ names: Set<GitReferenceName>, last: GitReferenceName? = nil) { model.select(names, last: last ?? names.first) }
        func entry(_ title: String, folder: Bool = false) throws -> NSMenuItem {
            let source = folder ? folderMenu : menu; source.delegate?.menuNeedsUpdate?(source)
            guard let item = source.item(withTitle: title), item.isEnabled, item.image != nil else { throw Failure(description: "Missing enabled icon command: " + title) }; return item
        }
        func invoke(_ item: NSMenuItem) throws { try require(NSApplication.shared.sendAction(item.action!, to: item.target, from: item), "Native dispatch failed") }
        var calls: [String] = []
        model.onLog = { calls.append($0) }; model.onBrowse = { calls.append($0) }; model.onReflog = { calls.append($0) }; model.onCompare = { calls.append($0) }; model.copyReferences = { calls.append($0) }
        for title in ["Show log", "Browse repository", "Show Reflog", "Compare with working tree", "Copy ref names"] {
            choose(["refs/heads/left"]); let command = try entry(title); choose(["refs/heads/right"]); try invoke(command)
            try require(calls.last == (title == "Copy ref names" ? "left" : "refs/heads/left") && model.selection == ["refs/heads/right"], "Retargeted " + title)
        }
        for title in ["Merge to \"main\"…", "Switch/Checkout to this…", "Edit description", "Select tracked branch"] {
            let callback: () -> Void = { calls.append(model.chosen?.name.rawValue ?? "missing") }
            model.onMerge = callback; model.onSwitch = callback; model.onEditDescription = callback; model.onSelectTracking = callback
            choose(["refs/heads/left"]); let command = try entry(title); choose(["refs/heads/right"]); try invoke(command)
            try require(calls.last == "refs/heads/left" && model.chosen?.name == "refs/heads/right", "Child callback retargeted " + title)
        }
        choose(["refs/remotes/origin/topic"]); model.setFolder("refs"); choose(["refs/remotes/origin/topic"])
        model.onCreateBranch = { calls.append(model.chosen?.name.rawValue ?? "missing") }; model.onFetch = { calls.append(model.fetchRemote ?? "missing") }
        let creation = try entry("Create Branch…"), fetch = try entry("Fetch from \"origin\"")
        choose(["refs/heads/right"]); try invoke(creation); try invoke(fetch)
        try require(calls.suffix(2) == ["refs/remotes/origin/topic", "origin"], "Remote leaf target lost")
        model.onComparePair = { calls.append($0.from.rawValue + ":" + $0.to.rawValue) }
        model.onUnifiedPair = { pair, _ in calls.append(pair.from.rawValue + ":" + pair.to.rawValue) }
        model.onLogRange = { calls.append($0.expression) }
        for (title, expected) in [("Compare selected refs", "refs/heads/left:refs/heads/right"), ("Show changes as unified diff", "refs/heads/left:refs/heads/right"), ("Show log of left..right", "refs/heads/left..refs/heads/right"), ("Show log of left...right", "refs/heads/left...refs/heads/right"), ("Copy ref names", "left\nright")] {
            choose(["refs/heads/left", "refs/heads/right"], last: "refs/heads/right"); let command = try entry(title)
            choose(["refs/heads/main"]); try invoke(command); try require(calls.last == expected && model.selection == ["refs/heads/main"], "Pair target/order lost: " + title)
        }
        // Even a change followed by restoration must retire the old command.
        for change in [0, 1, 2, 3, 4, 5, 6, 7] {
            choose(["refs/heads/left"]); let command = try entry("Show log"), before = calls.count
            switch change {
            case 0: model.query = "left"; model.query = ""
            case 1: model.nested.toggle(); model.nested.toggle()
            case 2: model.fields = [.authors]; model.fields = ReferenceBrowserWindowModel.allFields
            case 3: model.descending.toggle(); model.descending.toggle()
            case 4: model.sortColumn = "hash"; model.sortColumn = "name"
            case 5: model.hasChild = true; model.hasChild = false
            case 6: model.setFolder("refs/tags"); model.setFolder("refs")
            default: model.mergeFilter = .merged; model.mergeFilter = .all
            }
            try invoke(command); try require(calls.count == before, "Retired menu ran after state transition \(change)")
        }
        choose(["refs/heads/left"]); let refreshed = try entry("Show log"), before = calls.count
        model.load(); try invoke(refreshed); try await wait { !model.busy }; try invoke(refreshed); try require(calls.count == before, "Refresh revived command")
        let context = model.menuContext()!, other = ReferenceBrowserWindowModel(repository: repo, access: nil, initial: "HEAD", preferences: prefs)
        defer { other.invalidate() }; other.performMenu(context) { calls.append("wrong owner") }; try require(calls.count == before, "Cross-owner capture accepted")
        // Real mutation keeps the captured reference and expected hash.
        choose(["refs/heads/left"]); let unset = try entry("Unset tracked branch"); choose(["refs/heads/right"]); try invoke(unset); try await wait { !model.busy }
        let tracked = try await repo.referenceBrowser()
        try require(tracked.references.first { $0.name == "refs/heads/left" }?.upstream.isEmpty == true && tracked.references.first { $0.name == "refs/heads/right" }?.upstream.isEmpty == false, "Tracking mutation retargeted")
        model.setFolder("refs"); choose(["refs/heads/rename-me"])
        try await wait { table.selectedRowIndexes.count == 1 && table.selectedRow >= 0 && model.rows[table.selectedRow].reference.name == "refs/heads/rename-me" }
        let rename = try entry("Rename"); choose(["refs/heads/right"]); try invoke(rename)
        try require(model.renameReference == "refs/heads/rename-me", "Inline rename retargeted")
        // At the refs root the editable label includes its heads/ namespace.
        model.commitRename("heads/renamed"); try await wait { !model.busy && ReferenceBrowserWindowModel.activeRenames == 0 }
        try require(model.error == nil && model.snapshot?.references.contains { $0.name == "refs/heads/renamed" } == true && model.snapshot?.references.contains { $0.name == "refs/heads/right" } == true, "Captured inline rename failed")
        model.setFolder("refs"); choose(["refs/heads/delete-me"])
        var confirmation: ReferenceBrowserDeletionConfirmation?
        model.confirmDeletion = { value in confirmation = value; return true }
        let deletion = try entry("Delete branch"); choose(["refs/heads/right"]); try invoke(deletion); try await wait { !model.busy }
        try require(confirmation?.references == ["refs/heads/delete-me"] && model.snapshot?.references.contains { $0.name == "refs/heads/delete-me" } == false && model.snapshot?.references.contains { $0.name == "refs/heads/right" } == true, "Deletion retargeted or failed")
        model.setFolder("refs/tags"); model.query = "bucket/"; model.refilter(); choose(["refs/tags/bucket/one"])
        let allTags = try entry("Delete all tags", folder: true); choose(["refs/tags/bucket/two"]); try invoke(allTags); try await wait { !model.busy }
        try require(confirmation?.references.count == 2 && model.error == nil && model.snapshot?.references.contains { $0.name == "refs/tags/keep" } == true && model.snapshot?.references.contains { $0.name.browserIsFrom("refs/tags/bucket") } == false, "Folder mutation lost displayed tags/hashes")
        model.query = ""; model.setFolder("refs/remotes/origin"); model.onFetchFolder = { calls.append($0) }; model.onDeleteRemoteTags = { calls.append($0) }
        let remoteFetch = try entry("Fetch from \"origin\"", folder: true), remoteTags = try entry("Delete remote tags…", folder: true)
        try invoke(remoteFetch); try invoke(remoteTags); try require(calls.suffix(2) == ["origin", "origin"], "Dynamic remote payload lost")
        model.setFolder("refs"); choose(["refs/heads/left"]); let closed = try entry("Show log"), count = calls.count; owner.close(); try invoke(closed); try require(calls.count == count, "Closed owner ran retained menu")
        try await wait { ReferenceBrowserWindowModel.activeReads == 0 && ReferenceBrowserWindowModel.activeMutations == 0 }
        try require(head == (try await repo.run(["rev-parse", "HEAD"])).stdout && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && file == Data(contentsOf: root.appendingPathComponent("file")), "Menu actions changed HEAD/index/worktree")
        print("PASS: captured native list/folder read, pair/range, child, copy, tracking/delete/filter/remote actions, stale state and owner gates; unchanged HEAD/index/worktree; owned windows closed")
    }
}
