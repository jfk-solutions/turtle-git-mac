import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct CommitAuthorFieldVerification {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static func require(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        if !value() { throw Failure(description: "Requirement failed at \(file):\(line)") }
    }
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func authorField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityLabel() == "Author identity" { return field }
        for child in view.subviews { if let field = authorField(in: child) { return field } }
        return nil
    }
    @MainActor static func branchField(in view: NSView) -> CommitNewBranchField.Field? {
        if let field = view as? CommitNewBranchField.Field { return field }
        for child in view.subviews { if let field = branchField(in: child) { return field } }
        return nil
    }
    @MainActor static func waitAuthor(_ value: String, model: CommitWindowModel, host: NSView) async throws {
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if model.author == value && authorField(in: host)?.stringValue == value { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Author reseed did not complete: \(model.author), \(model.error ?? "no error")")
    }
    @MainActor static func main() async {
        do { try await verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.CommitAuthorField.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let clipboard = NSPasteboard(name: .init("TurtleGit.CommitAuthorField.QA." + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Configured 雪"])
        _ = try await repo.run(["config", "user.email", "configured@example.test"])
        let configured = "Configured 雪 <configured@example.test>"
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        model.branch = "main"; model.author = configured; model.message = "Preserved message"
        let host = NSHostingView(rootView: CommitDialog(model: model).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await settle(host)
        guard let field = authorField(in: host) else { throw Failure(description: "Author field missing") }
        try require(field.isEnabled && !field.isEditable && field.isSelectable)
        field.selectText(nil)
        guard let readonly = field.currentEditor() as? NSTextView else { throw Failure(description: "Author field editor missing: readonly") }
        try require(!readonly.isEditable && readonly.isSelectable)
        readonly.setSelectedRange(NSRange(location: 0, length: configured.utf16.count))
        try require(readonly.writeSelection(to: clipboard, types: readonly.writablePasteboardTypes))
        try require(clipboard.string(forType: .string) == configured)
        model.setAuthor = true; try await settle(host); try await waitAuthor(configured, model: model, host: host)
        try require(field.isEnabled && field.isEditable && field.isSelectable)
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { throw Failure(description: "Author field editor missing: editor") }
        try require(editor.isEditable)
        editor.insertText("Custom 😀 <custom@example.test>", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await settle(host)
        try require(model.author == "Custom 😀 <custom@example.test>")
        editor.setSelectedRange(NSRange(location: 7, length: 2))
        model.message = "Another message"; try await settle(host)
        try require(editor.selectedRange() == NSRange(location: 7, length: 2))
        model.setAuthor = false; try await settle(host); try await waitAuthor(configured, model: model, host: host)
        try require(field.isEnabled && !field.isEditable && field.isSelectable)
        field.selectText(nil)
        guard let restored = field.currentEditor() as? NSTextView else { throw Failure(description: "Author field editor missing: restored") }
        try require(!restored.isEditable && restored.string == configured)
        try require(restored.writeSelection(to: clipboard, types: restored.writablePasteboardTypes))
        try require(clipboard.string(forType: .string) == configured)
        model.busy = true; try await settle(host)
        try require(!field.isEnabled && !field.isEditable)
        model.busy = false; model.setAuthor = true; try await settle(host)
        try await waitAuthor(configured, model: model, host: host)
        try require(field.isEnabled && field.isEditable && model.message == "Another message")
        model.setAuthor = false; try await settle(host)
        try await waitAuthor(configured, model: model, host: host)
        model.newBranch = "feature/雪😀"; model.createBranch = true; try await settle(host)
        guard let branch = branchField(in: host), let branchEditor = branch.currentEditor() as? NSTextView else { throw Failure(description: "Branch field editor missing") }
        try require(window.firstResponder === branchEditor && branchEditor.selectedRange() == NSRange(location: 0, length: model.newBranch.utf16.count))
        model.createBranch = false; try await settle(host)
        field.selectText(nil)
        guard let afterBranch = field.currentEditor() as? NSTextView else { throw Failure(description: "Author field editor missing: afterBranch") }
        try require(!afterBranch.isEditable && afterBranch.writeSelection(to: clipboard, types: afterBranch.writablePasteboardTypes))
        try require(clipboard.string(forType: .string) == configured)
        try require(!window.isVisible && NSApplication.shared.activationPolicy() == .prohibited)
        print("PASS: full hidden Commit author remains selectable/copyable while read-only, native editing updates model, selection survives unrelated updates, unchecked author reseeds configured identity and disables editing, busy disables field; branch focus/select-all and subsequent read-only copy coexist; private pasteboard and no main app")
    }
}
