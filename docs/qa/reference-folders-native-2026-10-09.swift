import AppKit
import TurtleGitCore

@main struct ReferenceFolderVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(message: "Timeout") }
    @MainActor static func tree(_ view: NSView) -> NSOutlineView? { if let value = view as? NSOutlineView, value.accessibilityLabel() == "Reference namespaces" { return value }; for child in view.subviews { if let value = tree(child) { return value } }; return nil }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Folder QA failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.ReferenceFolders.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Folder QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("first\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "first"); _ = try await repo.run(["branch", "bucket/old"])
        try Data("second\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "second")
        for name in ["bucket/one", "bucket/two", "keep"] { _ = try await repo.run(["tag", name]) }
        let headHash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let owner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "HEAD", preferences: prefs, picking: false) { _ in }; defer { owner.close() }
        owner.model.load(); try await wait { !owner.model.busy && owner.model.snapshot != nil }
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        guard let outline = tree(owner.window!.contentView!), let menu = outline.menu else { throw Failure(message: "No native folder menu") }
        func update() { owner.window!.contentView!.layoutSubtreeIfNeeded(); menu.delegate?.menuNeedsUpdate?(menu) }
        func invoke(_ title: String) throws { update(); guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { throw Failure(message: "Missing " + title) }; try require(item.isEnabled && NSApplication.shared.sendAction(action, to: item.target, from: item), "Native folder dispatch") }
        owner.model.setFolder("refs/heads/bucket"); owner.model.select(["refs/heads/bucket/old"], last: "refs/heads/bucket/old"); update()
        try require(menu.items.map(\.title) == ["Create Branch…", "", "Copy ref names"] && menu.items[0].image?.name() == MenuIcon.branch.contextImage(defaults: prefs)?.name(), "Heads menu/order/icon")
        var configured: [Bool] = [], presented = 0
        owner.model.configureBranch = { configured.append($0.model.isTag) }; owner.presentBranch = { _, _ in presented += 1; return true }
        var copies: [String] = []; owner.model.copyReferences = { copies.append($0) }; try invoke("Copy ref names"); try require(copies == [""], "Folder copy incorrectly used selected leaves")
        for (folder, title, name, isTag) in [("refs/heads/bucket", "Create Branch…", "created-folder-branch", false), ("refs/tags/bucket", "Create Tag…", "created-folder-tag", true)] {
            owner.model.setFolder(GitReferenceName(folder)); try invoke(title)
            guard let child = owner.branchDialog else { throw Failure(message: "No owned creation") }
            try await wait { !child.model.busy && !child.model.chooser.busy }
            try require(child.model.isTag == isTag && child.model.useHead && child.model.options.name.isEmpty && owner.model.hasChild && !owner.windowShouldClose(owner.window!), "Folder creation guessed base/name or escaped owner")
            owner.model.load(); owner.model.accept(); owner.model.onCreateFolder?(isTag); try require(owner.branchDialog === child, "Duplicate creation")
            child.model.options.name = name; child.model.create()
            try await wait { owner.branchDialog == nil && !owner.model.busy }
            let createdHash = try await repo.run(["rev-parse", (isTag ? "refs/tags/" : "refs/heads/") + name]).text.trimmingCharacters(in: .newlines)
            try require(createdHash == headHash, "Folder creation used row/folder base instead of HEAD")
        }
        try require(configured == [false, true] && presented == 2, "Shared creation configuration")
        owner.model.setFolder("refs/tags/bucket"); update()
        try require(menu.items.map(\.title) == ["Create Tag…", "Delete all tags", "", "Copy ref names"] && menu.items[0].image?.name() == MenuIcon.tag.contextImage(defaults: prefs)?.name() && menu.items[1].image?.name() == MenuIcon.remove.contextImage(defaults: prefs)?.name(), "Tag menu/order/icons")
        var confirmation: ReferenceBrowserDeletionConfirmation?, answer: CheckedContinuation<Bool, Never>?
        owner.model.confirmDeletion = { value in confirmation = value; return await withCheckedContinuation { answer = $0 } }
        try invoke("Delete all tags"); try await wait { answer != nil }
        try require(confirmation?.references.map(\.rawValue) == ["refs/tags/bucket/one", "refs/tags/bucket/two"] && confirmation?.warning == false && owner.model.selection.count == 2, "Delete all ignored displayed namespace or tag warning")
        owner.model.load(); owner.model.deleteAllTags(); try require(owner.model.busy && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Pending folder deletion escaped gates")
        let no = answer; answer = nil; no?.resume(returning: false); try await wait { !owner.model.busy }
        try require(owner.model.snapshot!.references.contains { $0.name == "refs/tags/bucket/one" }, "No deleted tags")
        owner.model.setFolder("refs/tags"); owner.model.query = "bucket/"; owner.model.refilter(); try invoke("Delete all tags"); try await wait { answer != nil }
        try require(confirmation?.references.count == 2, "Filter ignored")
        let yes = answer; answer = nil; yes?.resume(returning: true); try await wait { !owner.model.busy }
        let remaining = try await repo.referenceBrowser(); try require(!remaining.references.contains { $0.name.browserIsFrom("refs/tags/bucket") } && remaining.references.contains { $0.name == "refs/tags/keep" } && remaining.references.contains { $0.name == "refs/tags/created-folder-tag" }, "Delete all removed undisplayed tags")
        owner.model.setFolder("refs/tags"); owner.model.query = "no-such-tag"; owner.model.refilter(); update(); try require(menu.items.first(where: { $0.title == "Delete all tags" })?.isEnabled == false, "Empty tag list enabled mutation")
        owner.model.query = ""; owner.model.refilter(); owner.model.setFolder("refs/heads"); owner.presentBranch = { _, _ in false }; try invoke("Create Branch…"); try await wait { !owner.model.busy }; try require(!owner.model.hasChild && owner.branchDialog == nil, "Rejected child retained owner")
        owner.model.setFolder("refs/tags"); owner.model.query = "keep"; owner.model.refilter(); try invoke("Delete all tags"); try await wait { answer != nil }; owner.close(); let late = answer; answer = nil; late?.resume(returning: true); try await Task.sleep(nanoseconds: 100_000_000)
        let afterLate = try await repo.referenceBrowser(); try require(afterLate.references.contains { $0.name == "refs/tags/keep" }, "Late folder Yes deleted tag")

        let picker = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/tags", preferences: prefs) { _ in }; defer { picker.close() }
        picker.model.load(); try await wait { !picker.model.busy && picker.model.snapshot != nil }; var pickerCount = 0
        picker.model.setFolder("refs/tags"); picker.model.confirmDeletion = { value in pickerCount = value.references.count; return false }; picker.model.deleteAllTags(); try await wait { !picker.model.busy }
        try require(pickerCount == 2 && picker.model.snapshot!.references.contains { $0.name == "refs/tags/keep" }, "Single picker delete-all lost displayed rows")
        picker.close()
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path]); let bareRepo = GitRepository(root: bareRoot, executable: repo.executable)
        let bare = ReferenceBrowserWindowController(repository: bareRepo, access: nil, initial: "refs/tags", preferences: prefs, picking: false) { _ in }; defer { bare.close() }
        bare.presentBranch = { _, _ in true }; bare.model.load(); try await wait { !bare.model.busy && bare.model.snapshot != nil }; bare.model.setFolder("refs/tags")
        bare.model.onCreateFolder?(true); guard let bareTag = bare.branchDialog else { throw Failure(message: "Bare folder creation blocked") }
        try await wait { !bareTag.model.busy && !bareTag.model.chooser.busy }; try require(bareTag.model.useHead && !bareTag.model.canSwitch, "Bare tag defaults")
        bareTag.model.options.name = "bare-folder-tag"; bareTag.model.create(); try await wait { bare.branchDialog == nil && !bare.model.busy }
        let bareHash = try await bareRepo.run(["rev-parse", "refs/tags/bare-folder-tag"]).text.trimmingCharacters(in: .newlines); try require(bareHash == headHash, "Bare folder tag base")
        bare.close()
        try require(head == Data(contentsOf: root.appendingPathComponent(".git/HEAD")) && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && file == Data(contentsOf: root.appendingPathComponent("file")), "Folder commands changed HEAD/index/worktree")
        try require(!NSApplication.shared.windows.contains { $0.isVisible }, "QA displayed a window")
        print("PASS native heads/tag folder menus/icons, HEAD creation, selected-leaf isolation, scoped/filtered tag deletion No/Yes/Refresh, empty/rejected/late gates, picker/bare creation and unchanged repository worktree")
    }
}
