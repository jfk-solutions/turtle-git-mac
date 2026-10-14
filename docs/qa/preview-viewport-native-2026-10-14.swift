import AppKit
import TurtleGitCore

@main struct PreviewViewportVerification {
    enum Failure: Error { case assertion(String), timeout(UInt) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure.assertion(message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure.timeout(line)
    }
    @MainActor static func main() async {
        do { try await verify(); print("PASS: Commit source preview initial placement/sticky follow/detach/mode reuse/close, unwrapped patch extent/reset and delayed comparison viewport navigation") }
        catch { fputs("Preview viewport failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]), askpass: nil)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Preview QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("file.txt"); try Data("before\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        try Data("after\n".utf8).write(to: file)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: file)
        let suite = "TurtleGit.PreviewViewport." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = CommitWindowController(repository: repo, access: nil, defaults: prefs); defer { owner.close() }
        owner.partialPlacementScreens = { [NSRect(x: -1000, y: -1000, width: 5000, height: 3000)] }
        owner.window!.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 800), display: false)
        owner.model.reload(); try await wait { !owner.model.busy }
        owner.model.showViewPatch(); try await wait { owner.partial?.model.busy == false }
        guard let preview = owner.partial, let child = preview.window else { throw Failure.assertion("Preview missing") }
        try require(child.parent == nil && child.frame.minX == owner.window!.frame.maxX + LogPatchPlacement.gap && child.frame.height == owner.window!.frame.height, "Initial companion placement")
        let movedParent = owner.window!.frame.offsetBy(dx: 35, dy: 20); owner.window!.setFrame(movedParent, display: false)
        try require(child.frame.minX == movedParent.maxX + LogPatchPlacement.gap && child.frame.minY == movedParent.minY, "Docked preview failed to follow")
        var detached = child.frame; detached.origin.x += 70; detached.origin.y += 45; child.setFrame(detached, display: false)
        owner.window!.setFrame(movedParent.offsetBy(dx: 40, dy: 20), display: false)
        try require(child.frame == detached, "Detached preview was forcibly realigned")
        var near = detached; near.origin.x = owner.window!.frame.maxX + LogPatchPlacement.gap + 3; child.setFrame(near, display: false)
        try require(child.frame.minX == owner.window!.frame.maxX + LogPatchPlacement.gap, "Preview failed to snap")
        let savedFrame = child.frame
        owner.model.showPartial(false); try await wait { !preview.model.busy }
        try require(owner.partial === preview && child.frame == savedFrame && !preview.model.readOnly, "Mode switch replaced or recentered preview")
        child.close(); try require(owner.partial == nil && owner.model.partialMode == nil, "Preview close retained ownership")

        let patch = PatchWindowController(repository: repo, access: nil, preferences: prefs); defer { patch.close() }
        patch.model.readOnly = true
        let long = String(repeating: "wide🐢", count: 200)
        patch.model.setReadOnlyDiff(Data(("diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -0,0 +1,80 @@\n" + (0..<80).map { "+\($0) " + long }.joined(separator: "\n") + "\n").utf8))
        patch.window!.setContentSize(NSSize(width: 500, height: 520)); patch.window!.contentView?.layoutSubtreeIfNeeded()
        func descendant<T: NSView>(_ view: NSView?, _ type: T.Type) -> T? { guard let view else { return nil }; if let result = view as? T { return result }; for child in view.subviews { if let result = descendant(child, type) { return result } }; return nil }
        try await wait { descendant(patch.window?.contentView, PatchScrollView.self)?.documentView is NSTextView }
        let scroll = descendant(patch.window?.contentView, PatchScrollView.self)!, text = scroll.documentView as! NSTextView
        scroll.updateDocumentExtent()
        try require(text.frame.width > scroll.contentSize.width * 2 && text.frame.height > scroll.contentSize.height, "Patch long lines/rows clipped")
        scroll.contentView.scroll(to: NSPoint(x: 150, y: 200)); scroll.reflectScrolledClipView(scroll.contentView)
        patch.model.setReadOnlyDiff(Data("diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-before\n+after\n".utf8))
        try await wait { text.string.contains("+after") && scroll.contentView.bounds.origin == .zero }
        try require(text.selectedRange().location == 0, "Replacement patch did not reset source position")
        let first = root.appendingPathComponent("left.txt"), second = root.appendingPathComponent("right.txt")
        let lines = (0..<200).map { "line \($0)" }; var modified = lines; modified[150] = "changed line 150"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: first); try Data((modified.joined(separator: "\n") + "\n").utf8).write(to: second)
        let comparison = FileComparisonWindowController(comparison: try WorkingFileComparison(base: first, destination: second), permissions: [], preferences: prefs); defer { comparison.close() }
        var panes: [Bool: NSScrollView] = [:]; comparison.model.onRegisterScroll = { panes[$1] = $0 }
        comparison.window!.setContentSize(NSSize(width: 1000, height: 620)); comparison.window!.contentView?.layoutSubtreeIfNeeded()
        comparison.model.load(); try await wait { !comparison.model.busy && !comparison.model.filtering && comparison.model.alignment != nil && panes.count == 2 }
        comparison.window!.contentView?.layoutSubtreeIfNeeded()
        try await wait { comparison.model.alignmentSelections.isEmpty && panes.values.allSatisfy { $0.contentView.bounds.minY > 100 } }
        try require(panes.values.allSatisfy { $0.contentSize.width > 32 && $0.contentSize.height > 32 }, "Comparison consumed navigation before viewport existed")
        comparison.window!.setContentSize(NSSize(width: 840, height: 500)); comparison.window!.contentView?.layoutSubtreeIfNeeded(); await Task.yield()
        try require(panes.values.allSatisfy { $0.contentView.bounds.minY > 100 }, "Resize lost initial navigation")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterBytes = try Data(contentsOf: file)
        try require(head == afterHead && index == afterIndex && bytes == afterBytes, "Preview changed repository data")
    }
}
