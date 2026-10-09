import AppKit
import TurtleGitCore

@main struct ReferenceMergeVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String) -> T? {
        if let result = view as? T, result.accessibilityLabel() == label { return result }
        for child in view.subviews { if let result = find(type, child, label: label) { return result } }; return nil
    }
    @MainActor static func wait(_ windows: [NSWindow], _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ReferenceMerge.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        print("PREFERENCES: " + suite); defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set(0, forKey: "AutoCloseGitProgress")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Merge route QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.run(["commit", "-m", "base"])
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "-b", "feature"])
        try Data("feature\n".utf8).write(to: root.appendingPathComponent("feature")); try await repo.stage(["feature"]); _ = try await repo.run(["commit", "-m", "feature"])
        let feature = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); _ = try await repo.run(["checkout", "main"])
        _ = try await repo.run(["remote", "add", "origin", root.path]); _ = try await repo.run(["update-ref", "refs/remotes/origin/topic", feature]); _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/topic"])
        _ = try await repo.run(["tag", "release", base]); _ = try await repo.run(["-c", "tag.gpgsign=false", "tag", "-a", "annotated", "-m", "tag", base]); _ = try await repo.run(["update-ref", "refs/notes/custom", base])
        let blob = try await repo.run(["hash-object", "-w", "file"]).text.trimmingCharacters(in: .newlines); _ = try await repo.run(["update-ref", "refs/custom/blob", blob])
        let nfc = "refs/heads/Café", nfd = "refs/heads/Cafe\u{301}"
        _ = try await repo.run(["pack-refs", "--all", "--prune"])
        let packed = root.appendingPathComponent(".git/packed-refs"); let text = try String(contentsOf: packed).replacingOccurrences(of: " sorted", with: "") + base + " " + nfc + "\n" + base + " " + nfd + "\n"; try Data(text.utf8).write(to: packed)
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let browser = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/feature", preferences: prefs) { _ in }; defer { browser.close() }
        browser.presentMerge = { owner, _ in owner.makeFirstResponder(nil); return true }
        var configured = 0, changes = 0
        browser.model.configureMerge = { child in
            configured += 1; child.model.onChanged = { _ in changes += 1 }; child.model.onPostAction = { _, _ in }
            child.presentProgress = { owner, _ in owner.makeFirstResponder(nil) }
        }
        browser.model.load(); try await wait([browser.window!]) { !browser.model.busy && browser.model.snapshot != nil }
        func select(_ name: String) async throws {
            let choice = browser.model.snapshot!.initialSelection(name); browser.model.folder = choice.folder; browser.model.selected = choice.reference
            try await wait([browser.window!]) { browser.model.chosen?.name == GitReferenceName(name) }
        }
        func menu() throws -> NSMenu {
            guard let table = find(NSTableView.self, browser.window!.contentView!, label: "References"), let menu = table.menu else { throw Failure(description: "Native menu missing") }
            menu.delegate?.menuNeedsUpdate?(menu); return menu
        }
        func open() throws -> MergeWindowController {
            let menu = try menu(); let title = browser.model.mergeTitle
            guard let command = menu.items.first(where: { $0.title == title }), command.isEnabled, command.image != nil else { throw Failure(description: "Original Merge menu/icon missing") }
            try require(menu.indexOfItem(withTitle: title) < menu.indexOfItem(withTitle: "Switch/Checkout to this…"), "Merge/Switch order differs")
            _ = (command.target as? NSObject)?.perform(command.action!)
            guard let child = browser.mergeDialog else { throw Failure(description: "Owned Merge missing") }; return child
        }
        for (ref, target) in [("refs/heads/feature", CheckoutTarget.branch), ("refs/remotes/origin/topic", .branch), ("refs/remotes/origin/HEAD", .branch), ("refs/tags/release", .tag), ("refs/notes/custom", .commit), (nfc, .branch), (nfd, .branch)] {
            try await select(ref); let child = try open(); try await wait([child.window!]) { !child.model.busy && !child.model.references.isEmpty }
            try require(child.model.target == target && GitReferenceName.equal(child.model.revision, ref) && child.model.repository === repo && child.model.onPostAction != nil, "Canonical Merge preset/role/configuration differs")
            if target != .commit {
                let label = target == .tag ? "Merge tag revision" : "Merge branch revision"
                guard let popup = find(NSPopUpButton.self, child.window!.contentView!, label: label) else { throw Failure(description: "Native popup missing") }
                let refs = target == .tag ? child.model.tags : child.model.branches
                try require(refs.indices.contains(popup.indexOfSelectedItem) && GitReferenceName.equal(refs[popup.indexOfSelectedItem].name, ref), "Exact native selection lost")
            } else { try require(find(NSTextField.self, child.window!.contentView!, label: "Merge commit revision")?.stringValue == ref, "Commit field differs") }
            try require(browser.model.hasChild && !browser.model.canAccept && !browser.windowShouldClose(browser.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Parent/close/Quit lock differs")
            let count = configured; browser.showMerge(); browser.showSwitch(); browser.selectTracking(); browser.model.load(); browser.model.currentBranch(); browser.model.accept()
            try require(configured == count && browser.mergeDialog === child && !browser.model.busy, "Competing route escaped")
            child.model.close(); try require(browser.mergeDialog == nil && !browser.model.hasChild, "Cancel did not release Merge")
        }
        for ref in ["refs/heads/main", "refs/tags/annotated", "refs/custom/blob"] {
            try await select(ref); try require(!browser.model.canMerge && (try menu()).indexOfItem(withTitle: browser.model.mergeTitle) == -1, "Current/type gate differs")
            browser.showMerge(); try require(browser.mergeDialog == nil, "Forbidden Merge opened")
        }
        try await select("refs/heads/feature")
        _ = try await repo.run(["symbolic-ref", "HEAD", "refs/heads/feature"])
        try require(!browser.model.canMerge && browser.model.mergeTitle == "Merge to \"feature\"…", "Live HEAD gate/label did not update")
        _ = try await repo.run(["symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try await repo.run(["checkout", "--detach", base]); try require(browser.model.canMerge && browser.model.mergeTitle == "Merge to \"(no branch)\"…", "Detached gate/label differs"); _ = try await repo.run(["checkout", "main"])
        let linkedRoot = root.appendingPathComponent("linked")
        _ = try await repo.run(["worktree", "add", "-b", "linked-current", linkedRoot.path, base])
        let linked = ReferenceBrowserWindowController(repository: GitRepository(root: linkedRoot, executable: repo.executable), access: nil, initial: "main", preferences: prefs) { _ in }; defer { linked.close() }
        linked.model.load(); try await wait([linked.window!]) { !linked.model.busy && linked.model.snapshot != nil }
        try require(linked.model.currentBranchName == "linked-current" && linked.model.canMerge && linked.model.mergeTitle == "Merge to \"linked-current\"…", "Linked worktree HEAD location differs")
        linked.close()
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = ReferenceBrowserWindowController(repository: GitRepository(root: bareRoot, executable: repo.executable), access: nil, initial: "feature", preferences: prefs) { _ in }; defer { bare.close() }
        bare.model.load(); try await wait([bare.window!]) { !bare.model.busy && bare.model.snapshot != nil }; try require(!bare.model.canMerge, "Bare Merge exposed")
        browser.presentMerge = { _, _ in false }; browser.showMerge(); try require(browser.mergeDialog == nil && !browser.model.hasChild, "Rejected presentation leaked")
        try require(head == Data(contentsOf: root.appendingPathComponent(".git/HEAD")) && config == Data(contentsOf: root.appendingPathComponent(".git/config")), "Open/cancel changed repository")
        let beforeTree = try await repo.run(["write-tree"]).text
        browser.presentMerge = { owner, _ in owner.makeFirstResponder(nil); return true }; let child = try open()
        try await wait([child.window!]) { !child.model.busy }; child.model.merge(); child.model.branchRevision = "refs/heads/main"
        try await wait([child.window!]) { child.progressController?.model.busy == false }
        guard let progress = child.progressController else { throw Failure(description: "Owned native progress missing") }
        try require(progress.model.success && progress.model.options.revision == "refs/heads/feature" && child.model.busy && browser.model.hasChild && changes == 1, "Owned merge transaction/lock/capture differs")
        let merged = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try require(merged == feature && FileManager.default.fileExists(atPath: root.appendingPathComponent("feature").path), "Real merge not applied")
        progress.model.close(); try await wait([browser.window!]) { browser.mergeDialog == nil }
        try require(!browser.model.hasChild && !child.model.busy && child.progressController == nil, "Acknowledgement did not release owned route")
        let afterTree = try await repo.run(["write-tree"]).text; try require(beforeTree != afterTree && index != Data(contentsOf: root.appendingPathComponent(".git/index")), "Merge did not update index")
        let closing = try open(); browser.close()
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(browser.model.closed && browser.mergeDialog == nil && !closing.model.busy && closing.model.references.isEmpty, "Forced close allowed initial metadata publication")
        try require(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "Displayed windows")
        print("PASS: original Merge menu/icon/order, canonical native local/remote/symbolic/tag/notes/NFC/NFD presets, live HEAD/current/type/bare gates, owned/cancel/reject/competing/Quit/forced-load cleanup and real captured merge/progress acknowledgement. Private preferences/repository, no ordered windows or physical sheets.")
    }
}
