import AppKit
import SwiftUI
import TurtleGitCore

@main struct CommitBranchFocusVerification {
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func branchField(in view: NSView) -> CommitNewBranchField.Field? {
        if let field = view as? CommitNewBranchField.Field { return field }
        for child in view.subviews { if let field = branchField(in: child) { return field } }
        return nil
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.CommitBranchFocus.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        model.branch = "main"; model.newBranch = "feature/雪😀"; model.message = "Preserved draft"
        let host = NSHostingView(rootView: CommitDialog(model: model).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await settle(host)
        precondition(branchField(in: host) == nil)
        model.createBranch = true; try await settle(host)
        let field = branchField(in: host)!
        let editor = field.currentEditor() as! NSTextView
        precondition(window.firstResponder === editor)
        precondition(editor.selectedRange() == NSRange(location: 0, length: model.newBranch.utf16.count))
        precondition(field.accessibilityLabel() == "New branch name")
        precondition(field.isBezeled && field.drawsBackground && field.isEditable && field.isSelectable)
        editor.insertText("feature/replacement", replacementRange: editor.selectedRange())
        try await settle(host)
        precondition(model.newBranch == "feature/replacement")
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        model.message = "Another message update"; try await settle(host)
        precondition(field.currentEditor() === editor && editor.selectedRange() == NSRange(location: 8, length: 0))
        model.createBranch = false; try await settle(host)
        precondition(branchField(in: host) == nil && model.newBranch == "feature/replacement")
        model.createBranch = true; try await settle(host)
        let again = branchField(in: host)!, againEditor = again.currentEditor() as! NSTextView
        precondition(window.firstResponder === againEditor)
        precondition(againEditor.selectedRange() == NSRange(location: 0, length: model.newBranch.utf16.count))
        precondition(model.message == "Another message update")
        model.createBranch = false; try await settle(host)
        // A disabled insertion must not acquire the window's field editor.
        model.busy = true; model.createBranch = true; try await settle(host)
        let disabled = branchField(in: host)!
        precondition(!disabled.isEnabled && disabled.currentEditor() == nil)
        model.busy = false; try await settle(host)
        precondition(disabled.currentEditor() == nil)
        precondition(!window.isVisible && NSApplication.shared.activationPolicy() == .prohibited)
        print("PASS: actual hidden Commit dialog focuses/selects the UTF-16 branch draft on enable, native typing updates the model, ordinary updates preserve caret, off/on preserves and reselects the draft, disabled insertion does not steal focus; no main app")
    }
}
