import AppKit
import TurtleGitCore

struct ClipboardTargetNativeVerification {
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitClipboardTarget-" + UUID().uuidString).standardizedFileURL
        let child = root.appendingPathComponent("selected 雪\n")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("base\n".utf8).write(to: file)
        let patch = Data("--- file\n+++ file\n@@ -1 +1 @@\n-base\n+patched\n".utf8)
        let suite = "TurtleGit.ClipboardTarget.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init(suite)); defer { pasteboard.releaseGlobally() }
        let viewer = PatchWindowModel(repository: GitRepository(root: root), access: nil, appearancePreferences: preferences)
        let original = Data([0xff, 0, 1, 2, 3])
        viewer.setReadOnlyDiff(original); viewer.copyPatch(to: pasteboard)
        precondition(PatchClipboard.snapshot(from: pasteboard) == original)
        precondition(pasteboard.data(forType: PatchClipboard.legacyUnifiedDiff) == original)
        viewer.setReadOnlyDiff(patch); viewer.copyPatch(to: pasteboard)
        let app = RepositoryModel(); app.reviewPatchPreferences = preferences
        var review: WorkingTreePatchWindowController?, pickerReply: CheckedContinuation<URL?, Never>?, choices = 0
        app.reviewPatchPreparation = { workflow in
            workflow.chooseFile = { preconditionFailure("Clipboard review must not ask for a source file") }
            workflow.chooseTarget = { await withCheckedContinuation { pickerReply = $0 } }
            workflow.chooseBetterTarget = { selected, suggested in
                precondition(selected.path == child.path && suggested.path == root.path); choices += 1; return .suggested
            }
        }
        app.reviewPatchPresentation = { review = $0 }
        app.showClipboardPatch(from: pasteboard)
        for _ in 0..<100 { if pickerReply != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(pickerReply != nil)
        pasteboard.clearContents(); pasteboard.setString("changed clipboard", forType: .string)
        pickerReply?.resume(returning: child); pickerReply = nil
        for _ in 0..<1500 { if review != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard let controller = review else { preconditionFailure(app.error ?? "Clipboard review did not open") }
        try await ReviewPatchNativeVerification.idle(controller.model)
        precondition(choices == 1 && app.root == nil && controller.model.repository.root.path == root.path)
        precondition(controller.model.previewDocument.exportDocument.bytes == patch && controller.model.stripCount == 0 && controller.model.canApply)
        let before = try Data(contentsOf: file); precondition(before == Data("base\n".utf8))
        controller.model.apply(); try await ReviewPatchNativeVerification.idle(controller.model)
        let after = try Data(contentsOf: file); precondition(after == Data("patched\n".utf8))
        controller.window?.close(); review = nil
        // A Keep Selected response must not silently adopt the suggested root.
        let keep = ReviewPatchWorkflow(file: nil, target: child, executable: URL(fileURLWithPath: "/usr/bin/git"), preferences: preferences, clipboardBytes: patch)
        keep.chooseBetterTarget = { _, _ in .original }
        var kept: WorkingTreePatchWindowController?
        keep.presentation = { kept = $0 }; keep.start()
        for _ in 0..<1000 { if kept != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard let kept else { preconditionFailure("Keep Selected did not open review") }
        try await ReviewPatchNativeVerification.idle(kept.model)
        precondition(kept.model.repository.root.path == child.path && !kept.model.canApply); kept.window?.close()
        pasteboard.clearContents(); pasteboard.setString("ordinary text", forType: .string)
        precondition(PatchClipboard.snapshot(from: pasteboard) == nil)
        pasteboard.setString(String(decoding: patch, as: UTF8.self), forType: .string)
        precondition(PatchClipboard.snapshot(from: pasteboard) == patch)
        print("Clipboard/target native: raw byte formats, captured source across clipboard replacement, no source-file chooser, suggested/selected target choices, p0 plain review/application and private pasteboard cleanup verified.")
    }
}
