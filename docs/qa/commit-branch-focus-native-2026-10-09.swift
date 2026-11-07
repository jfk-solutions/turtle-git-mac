import AppKit
import SwiftUI
import TurtleGitCore

@MainActor private final class CommitFocusHiddenWindow:NSWindow {
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?)->NSRect {frameRect}
}

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
        _ = try await repo.run(["config", "user.name", "Private Branch Focus QA"])
        _ = try await repo.run(["config", "user.email", "focus@example.invalid"])
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        model.branch = "main"; model.newBranch = "feature/雪😀"; model.message = "Preserved draft"
        defer { model.invalidateForClose() }
        model.reload()
        for _ in 0..<3000 { if !model.busy { break }; try await Task.sleep(nanoseconds:10_000_000) }
        precondition(model.commitIdentityPrepared && !model.busy && model.error == nil, "Branch fixture must complete real identity preparation")
        let host = NSHostingView(rootView: CommitDialog(model: model).defaultAppStorage(prefs))
        let window = CommitFocusHiddenWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000))
        defer { window.close() }
        try await settle(host)
        precondition(branchField(in: host) == nil)
        model.createBranch = true; try await settle(host)
        precondition(branchField(in:host)?.currentEditor()==nil,"Unpresented branch field acquired focus")
        window.orderFront(nil);try await settle(host)
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
        // Revoked insertion intent cannot revive when its owner is shown later.
        model.createBranch=false;try await settle(host);window.orderOut(nil)
        model.createBranch=true;try await settle(host)
        let pending=branchField(in:host)!
        model.supersedeFocusIntent();window.orderFront(nil);try await settle(host)
        precondition(pending.currentEditor()==nil,"Superseded pending focus stole responder")
        precondition(window.alphaValue==0 && window.frame.maxX<0 && NSApplication.shared.activationPolicy() == .prohibited)
        print("PASS: actual hidden Commit dialog focuses/selects the UTF-16 branch draft on enable, native typing updates the model, ordinary updates preserve caret, off/on preserves and reselects the draft, disabled insertion does not steal focus; no main app")
    }
}
