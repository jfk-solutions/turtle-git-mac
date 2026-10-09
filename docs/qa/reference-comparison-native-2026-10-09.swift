import AppKit
import TurtleGitCore

@main struct ReferenceComparisonVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(message: "Timeout") }
    @MainActor static func table(_ view: NSView) -> NSTableView? { if let table = view as? NSTableView, table.accessibilityLabel() == "References" { return table }; for child in view.subviews { if let value = table(child) { return value } }; return nil }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Comparison QA failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.ReferenceComparison.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Comparison QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("first\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "first"); _ = try await repo.run(["branch", "a-old"])
        try Data("second\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "second"); _ = try await repo.run(["branch", "z-new"])
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let owner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "HEAD", preferences: prefs, picking: false) { _ in }; defer { owner.close() }
        owner.model.load(); try await wait { !owner.model.busy && owner.model.snapshot != nil }
        owner.model.setFolder("refs/heads"); owner.model.select(["refs/heads/a-old", "refs/heads/z-new"], last: "refs/heads/a-old")
        owner.window!.contentView!.layoutSubtreeIfNeeded(); try await wait { table(owner.window!.contentView!)?.selectedRowIndexes.count == 2 }
        guard let native = table(owner.window!.contentView!), let menu = native.menu else { throw Failure(message: "Native table/menu missing") }
        menu.delegate?.menuNeedsUpdate?(menu)
        try require(Array(menu.items.prefix(4)).map(\.title) == ["Compare selected refs", "Show changes as unified diff", "Show log of z-new..a-old", "Show log of z-new...a-old"], "Source order/log direction")
        for item in menu.items.prefix(2) { try require(item.isEnabled && item.image?.name() == MenuIcon.unifiedDiff.contextImage(defaults: prefs)?.name(), "Source diff icon") }
        func invoke(_ title: String) throws { menu.delegate?.menuNeedsUpdate?(menu); guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { throw Failure(message: "Missing command") }; try require(NSApplication.shared.sendAction(action, to: item.target, from: item), "Native dispatch") }
        var configured = false, presented = false
        owner.model.configureComparison = { _ in configured = true }
        owner.presentComparison = { _, _ in presented = true; return true }
        try invoke("Compare selected refs")
        guard let child = owner.comparisonDialog else { throw Failure(message: "No owned comparison") }
        try require(configured && presented && owner.model.hasChild && child.model.from == "refs/heads/a-old" && child.model.to == "refs/heads/z-new", "Names/order/owned configuration")
        try require(!owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Child close/Quit gates")
        owner.model.load(); owner.model.accept(); owner.model.comparePair(unified: false)
        try require(owner.comparisonDialog === child && owner.model.hasChild, "Duplicate/refresh escaped child")
        try await wait { !child.model.busy && child.model.snapshot != nil }
        try require(child.model.snapshot!.files.contains { $0.path == "file" && $0.added == 1 && $0.removed == 1 }, "Actual changed-file backend")
        child.close(); try require(owner.comparisonDialog == nil && !owner.model.hasChild && child.model.closed, "Child ownership release")
        let pair = owner.model.comparisonPair!, expected = try await repo.referenceBrowserUnifiedDiff(pair)
        _ = try await repo.run(["update-ref", "refs/heads/z-new", pair.fromHash])
        var bytes: Data?, shift: Bool?, title: String?, continuation: CheckedContinuation<Void, Never>?
        owner.presentUnified = { data, alternate, label in bytes = data; shift = alternate; title = label; await withCheckedContinuation { continuation = $0 } }
        try invoke("Show changes as unified diff"); try await wait { continuation != nil }
        try require(bytes == expected && shift == false && title == "refs/heads/a-old:refs/heads/z-new", "Captured hashes/viewer request")
        try require(owner.model.busy && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Unified close/Quit gates")
        owner.model.load(); owner.model.comparePair(unified: true)
        let done = continuation; continuation = nil; done?.resume(); try await wait { !owner.model.busy }
        owner.model.comparePair(unified: true, alternate: true); try await wait { continuation != nil }; try require(shift == true && bytes == expected, "Shift alternative viewer")
        owner.close(); let late = continuation; continuation = nil; late?.resume(); try await Task.sleep(nanoseconds: 100_000_000)
        try require(owner.model.closed && owner.comparisonDialog == nil && owner.model.error == nil, "Late viewer completion")

        for stage in ["rev-parse", "diff-tree"] {
            let helper = root.appendingPathComponent("slow-" + stage), marker = URL(fileURLWithPath: helper.path + ".started"), pause = URL(fileURLWithPath: helper.path + ".pause")
            let quoted = "'" + repo.executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = """
            #!/bin/sh
            task_match=false
            for task_argument in "$@"; do
              if [ "$task_argument" = '\(stage)' ]; then task_match=true; fi
            done
            if [ "$task_match" = true ] && [ -f "$0.pause" ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              wait "$task_child"
            fi
            exec \(quoted) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let closing = ReferenceBrowserWindowController(repository: GitRepository(root: root, executable: helper), access: nil, initial: "refs", preferences: prefs, picking: false) { _ in }
            var ids: [Int32] = []; defer { closing.close(); for pid in ids where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) } }
            closing.presentComparison = { _, _ in true }; var published = false; closing.presentUnified = { _, _, _ in published = true }
            closing.model.load(); try await wait { !closing.model.busy && closing.model.snapshot != nil }
            closing.model.select(["refs/heads/a-old", "refs/heads/z-new"], last: "refs/heads/a-old")
            try Data().write(to: pause); closing.model.comparePair(unified: stage == "diff-tree")
            let pendingChild = closing.comparisonDialog
            try await wait { FileManager.default.fileExists(atPath: marker.path) }
            ids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            try require(ids.count == 2 && ids.allSatisfy { kill($0, 0) == 0 }, "Owned comparison process absent")
            closing.close(); try await wait { ids.allSatisfy { kill($0, 0) != 0 } }; try await Task.sleep(nanoseconds: 100_000_000)
            try require(closing.model.closed && !closing.model.busy && closing.comparisonDialog == nil && !published && closing.model.error == nil, "Forced comparison continued")
            if let pendingChild { try require(pendingChild.model.closed && pendingChild.model.snapshot == nil && pendingChild.model.error == nil, "Late child result") }
            print("PASS comparison forced cleanup: " + stage)
        }
        try require(head == Data(contentsOf: root.appendingPathComponent(".git/HEAD")) && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && file == Data(contentsOf: root.appendingPathComponent("file")), "Repository changed by comparison")
        try require(!NSApplication.shared.windows.contains { $0.isVisible }, "QA ordered a window")
        print("PASS source two-reference menu/icons, names vs captured hashes, list vs Log direction, owned changed-file backend, viewer/Shift, duplicate/F5/close/Quit and late completion")
    }
}
