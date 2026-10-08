import AppKit
import SwiftUI
import TurtleGitCore

@main struct DialogGeometryVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.DialogGeometry.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        DialogGeometry.install(preferences: prefs)
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        let store = WindowGeometryStore(preferences: prefs)
        let reference = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 700, height: 450), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        reference.isReleasedWhenClosed = false
        DialogGeometry.attach(reference, identifier: "Receiver")
        reference.setFrame(NSRect(x: 90, y: 120, width: 780, height: 510), display: false); reference.close()
        let saved = store.load("Receiver")!; precondition(saved.width == 780 && saved.height == 510)
        let reopened = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        reopened.isReleasedWhenClosed = false; DialogGeometry.attach(reopened, identifier: "Receiver")
        if !NSScreen.screens.isEmpty { precondition(reopened.frame.width == saved.width && reopened.frame.height == saved.height) }
        reopened.close()
        // The real Commit controller must restore after its default size and center.
        store.save(.init(x: 40, y: 100, width: 1040, height: 820), identifier: "CommitWindowController")
        let commit = CommitWindowController(repository: repo, access: nil); commit.window?.contentViewController = nil
        if let screen = commit.window!.screen?.visibleFrame { precondition(commit.window!.frame.width == min(1040, screen.width) && commit.window!.frame.height == min(820, screen.height)) }
        commit.close()
        // Fixed dialogs retain their current content dimensions.
        let fixed = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        fixed.isReleasedWhenClosed = false; let expected = fixed.frame.size
        store.save(.init(x: 30, y: 40, width: 1000, height: 800), identifier: "Fixed")
        DialogGeometry.attach(fixed, identifier: "Fixed"); precondition(fixed.frame.size == expected); fixed.close()
        let settings = SavedDataSettingsModel(store: ActionLogStore(storageURL: root.appendingPathComponent("logfile.txt")), preferences: prefs, showFile: { _ in true })
        precondition(settings.summaries[.dialogGeometry]?.histories == 3)
        prefs.set(2, forKey: "AutoCloseGitProgress"); settings.clear(.dialogGeometry)
        precondition(settings.summaries[.dialogGeometry]?.available == false && prefs.integer(forKey: "AutoCloseGitProgress") == 2)
        let next = CommitWindowController(repository: repo, access: nil); next.window?.contentViewController = nil
        precondition(next.window!.contentRect(forFrameRect: next.window!.frame).size.width == 1000); next.close()
        let host = NSHostingView(rootView: SavedDataSettingsPage()); host.frame = .init(x: 0, y: 0, width: 760, height: 700); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        print("PASS: actual hidden resize/close/reopen, Commit restores after defaults, fixed-size preservation and Saved Data reset with ordinary options preserved; no main app")
    }
}
