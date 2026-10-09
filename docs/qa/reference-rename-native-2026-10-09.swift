import AppKit
import TurtleGitCore

@main struct ReferenceRenameVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String? = nil) -> T? {
        if let result = view as? T, label == nil || result.accessibilityLabel() == label { return result }
        for child in view.subviews { if let result = find(type, child, label: label) { return result } }; return nil
    }
    @MainActor static func wait(_ window: NSWindow, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { window.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ReferenceRename.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        print("PREFERENCES: " + suite)
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Rename QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.run(["commit", "-m", "base"])
        _ = try await repo.run(["branch", "nested/topic"]); _ = try await repo.run(["branch", "nested/neighbor"]); _ = try await repo.run(["branch", "else/refs/heads/nested/topic"]); _ = try await repo.run(["branch", "existing"])
        _ = try await repo.run(["tag", "release"]); _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try await repo.updateBranchDescription("nested/topic", message: "description")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let browser = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/nested/topic", preferences: prefs, onChoose: { _ in })
        defer { browser.close() }
        let window = browser.window!; browser.model.load()
        try await wait(window) { !browser.model.busy && browser.model.snapshot != nil }
        guard let table = find(NSTableView.self, window.contentView!, label: "References"), let menu = table.menu else { throw Failure(description: "Native table absent") }
        func choose(_ name: GitReferenceName, folder: GitReferenceName) async throws {
            browser.model.folder = folder; browser.model.selected = name
            try await wait(window) { table.selectedRow >= 0 && (table.view(atColumn: table.column(withIdentifier: .init("name")), row: table.selectedRow, makeIfNecessary: true) as? NSTableCellView)?.textField?.toolTip == name.rawValue }
        }
        func start() throws -> NSTextField {
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let item = menu.items.first(where: { $0.title == "Rename" }) else { throw Failure(description: "Rename menu absent") }
            try require(item.isEnabled && item.image != nil, "Original rename icon/enabled")
            _ = (item.target as? NSObject)?.perform(item.action!)
            guard let field = find(NSTextField.self, window.contentView!, label: "Rename branch") else { throw Failure(description: "Inline name field absent") }
            return field
        }
        func command(_ field: NSTextField, _ selector: String) throws {
            guard let editor = field.currentEditor() as? NSTextView else { throw Failure(description: "Nonnil native field editor required") }
            try require(field.delegate?.control?(field, textView: editor, doCommandBy: NSSelectorFromString(selector)) == true, "Native edit command route")
        }
        try await choose("refs/heads/nested/topic", folder: "refs/heads/nested")
        let cancelled = try start()
        try require(cancelled.stringValue == "topic", "Folder-relative label")
        try require((cancelled.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 5), "Inline select-all")
        try require(!browser.model.canAccept && !browser.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Selection/close lock")
        let token = browser.model.renameReference; browser.model.load(); browser.model.currentBranch()
        try require(browser.model.renameReference == token && !browser.model.busy, "F5/current branch blocked while editing")
        try command(cancelled, "cancelOperation:")
        try await wait(window) { browser.model.renameReference == nil }
        let unchanged = try await repo.referenceBrowser(); try require(unchanged.references.contains { $0.name == "refs/heads/nested/topic" }, "Escape no mutation")
        try await choose("refs/heads/nested/topic", folder: "refs/heads")
        let renamed = try start(); try require(renamed.stringValue == "nested/topic", "Nested row relative to heads")
        renamed.stringValue = "other/renamed"; try command(renamed, "insertNewline:")
        try require(browser.model.busy && browser.model.renameReference != nil, "Write lock")
        try await wait(window) { !browser.model.busy && browser.model.renameReference == nil }
        try require(browser.model.snapshot?.references.first { $0.name == "refs/heads/other/renamed" }?.description == "description", "Rename config and refreshed catalog")
        try require(browser.model.folder == "refs/heads/nested" && browser.model.selected == nil, "Source refresh falls back after old selection removed")
        try await choose("refs/heads/other/renamed", folder: "refs/heads")
        // F2 runs the same native inline route.
        let f2 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 120)!
        table.keyDown(with: f2)
        guard let failed = find(NSTextField.self, window.contentView!, label: "Rename branch") else { throw Failure(description: "F2 field absent") }
        failed.stringValue = "existing"; try command(failed, "insertNewline:")
        try await wait(window) { !browser.model.busy && browser.model.renameReference == nil }
        try require(browser.model.error != nil && browser.model.snapshot?.references.contains { $0.name == "refs/heads/other/renamed" } == true, "Git collision failure keeps original row")
        for name in [GitReferenceName("refs/tags/release"), GitReferenceName("refs/remotes/origin/main")] {
            try await choose(name, folder: "refs")
            try require(!browser.model.canRename && browser.model.beginRename() == nil, "Non-local gate")
        }
        try await choose("refs/heads/main", folder: "refs")
        let current = try start(); try require(current.stringValue == "heads/main", "Root-relative inline label")
        current.stringValue = "heads/current"; try command(current, "insertNewline:")
        try await wait(window) { !browser.model.busy && browser.model.renameReference == nil }
        try require(browser.model.snapshot?.currentBranch == "refs/heads/current", "Current branch/HEAD refresh")
        try await choose("refs/heads/current", folder: "refs/heads")
        let focus = try start(); focus.stringValue = "focus-renamed"
        try require(window.makeFirstResponder(table), "Native focus handoff")
        try await wait(window) { !browser.model.busy && browser.model.renameReference == nil }
        try require(browser.model.snapshot?.currentBranch == "refs/heads/focus-renamed", "Native end-edit notification accepts on focus change")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; try require(head == after && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && file == Data(contentsOf: root.appendingPathComponent("file")), "No checkout/index/worktree mutation")
        try await choose("refs/heads/focus-renamed", folder: "refs/heads"); _ = try start(); browser.close()
        try require(browser.model.closed && browser.model.renameReference == nil, "Forced edit cleanup")
        try require(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "No displayed windows")
        print("PASS: inline menu/F2 rename, native edit selection/Return/Escape, relative namespaces, locks, refresh/config/current HEAD, collision/type gates and cleanup")
    }
}
