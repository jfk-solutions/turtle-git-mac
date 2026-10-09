import AppKit
import TurtleGitCore

@main struct ReferenceDescriptionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView) -> T? {
        if let result = view as? T, !(result is NSOutlineView) { return result }
        for child in view.subviews { if let result = find(type, child) { return result } }; return nil
    }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ReferenceDescription.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        print("PREFERENCES: " + suite)
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set("Menlo", forKey: "LogFontName"); prefs.set(14, forKey: "LogFontSize")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Description QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        _ = try await repo.run(["commit", "--allow-empty", "-m", "base"])
        _ = try await repo.run(["tag", "release"]); _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try await repo.updateBranchDescription("main", message: "first\nsecond 🐢")
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let browser = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/main", preferences: prefs, onChoose: { _ in })
        defer { browser.close() }
        browser.presentDescription = { parent, _ in parent.makeFirstResponder(nil); return true }
        browser.window?.contentView?.layoutSubtreeIfNeeded(); browser.model.load(); try await wait { !browser.model.busy && browser.model.snapshot != nil }
        guard let view = browser.window?.contentView, let table = find(NSTableView.self, view), let menu = table.menu else { throw Failure(description: "Native table/menu absent") }
        table.layoutSubtreeIfNeeded(); menu.delegate?.menuNeedsUpdate?(menu)
        guard let command = menu.items.first(where: { $0.title == "Edit description" }) else { throw Failure(description: "Description command absent") }
        try require(command.image != nil && command.isEnabled, "Original rename icon and command enabled")
        _ = (command.target as? NSObject)?.perform(command.action!)
        guard let child = browser.descriptionEditor, let window = child.window else { throw Failure(description: "Owned editor absent") }
        window.contentView?.layoutSubtreeIfNeeded(); child.focusEditor()
        try require(window.title == "Edit description" && child.editor.string == "first\nsecond 🐢", "Title and multiline prefill")
        try require(child.editor.selectedRange() == NSRange(location: child.editor.string.utf16.count, length: 0), "End caret")
        try require(window.firstResponder === child.editor, "Native editor focus")
        try require(child.editor.font?.pointSize == 14 && child.editor.undoManager?.canUndo != true, "Shared font and clean initial undo")
        try require(browser.model.hasChild && !browser.model.canAccept && !browser.windowShouldClose(browser.window!), "Parent locks")
        child.editor.string = "changed but cancelled"; child.cancel()
        try require(browser.descriptionEditor == nil && !browser.model.hasChild, "Cancel releases child")
        let unchanged = try await repo.run(["config", "--get", "branch.main.description"]).text
        try require(unchanged == "first\nsecond 🐢\n", "Cancel leaves config unchanged")
        browser.editDescription()
        guard let saved = browser.descriptionEditor else { throw Failure(description: "Second editor absent") }
        saved.editor.string = "  new\r\nmultiline  "
        guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: saved.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw Failure(description: "Key event absent") }
        saved.editor.keyDown(with: enter)
        try require(saved.busy && !saved.ok.isEnabled && !saved.cancelButton.isEnabled && !saved.windowShouldClose(saved.window!), "Write lock")
        try await wait { browser.descriptionEditor == nil && !browser.model.busy }
        try require(browser.model.chosen?.description == "new\nmultiline", "Successful write refreshes selection/catalog")
        browser.editDescription(); browser.descriptionEditor?.editor.string = " \r\n "; browser.descriptionEditor?.save()
        try await wait { browser.descriptionEditor == nil && !browser.model.busy }
        try require(browser.model.chosen?.description == "", "Empty description removal refresh")
        for reference in ["refs/tags/release", "refs/remotes/origin/main"] {
            browser.model.folder = "refs"; browser.model.selected = GitReferenceName(reference)
            try require(!browser.model.canEditDescription, "Non-local ref disabled")
            browser.editDescription(); try require(browser.descriptionEditor == nil, "Non-local editor rejected")
        }
        browser.model.selected = "refs/heads/main"
        browser.presentDescription = { _, _ in false }; browser.editDescription()
        try require(browser.descriptionEditor == nil && !browser.model.hasChild, "Rejected presentation releases child")
        browser.presentDescription = { parent, _ in parent.makeFirstResponder(nil); return true }; browser.editDescription()
        let forced = browser.descriptionEditor; browser.close()
        try require(browser.descriptionEditor == nil && forced?.window?.isVisible != true && browser.model.closed, "Forced parent cleanup")
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = ReferenceBrowserWindowController(repository: GitRepository(root: bareRoot, executable: repo.executable), access: nil, initial: "refs/heads/main", preferences: prefs, onChoose: { _ in })
        defer { bare.close() }
        bare.presentDescription = { parent, _ in parent.makeFirstResponder(nil); return true }
        bare.model.load(); try await wait { !bare.model.busy && bare.model.snapshot != nil }
        try require(bare.model.bare && bare.model.canEditDescription, "Bare branch command enabled")
        bare.editDescription(); bare.descriptionEditor?.editor.string = "bare value"; bare.descriptionEditor?.save()
        try await wait { bare.descriptionEditor == nil && !bare.model.busy }
        try require(bare.model.chosen?.description == "bare value", "Bare save and refresh")
        bare.close()
        var attempts = 0
        let retry = ReferenceDescriptionWindowController(text: "draft", preferences: prefs) { _, _ in attempts += 1; throw NSError(domain: "TurtleGit.Description.QA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected private failure"]) }
        defer { retry.close() }
        retry.save(); try await wait { !retry.busy }
        try require(attempts == 1 && retry.editor.string == "draft" && retry.errorLabel.stringValue.contains("Expected private failure") && retry.ok.isEnabled, "Failure retains retry draft")
        retry.cancel()
        let after = try await repo.run(["rev-parse", "HEAD"]).text; try require(head == after, "HEAD unchanged")
        try require(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "No displayed app windows")
        print("PASS: native branch-description menu, input, focus, cancel, Ctrl+Return, write/parent locks, refresh, clear, type gates, failure and cleanup")
    }
}
