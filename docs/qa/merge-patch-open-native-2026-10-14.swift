import AppKit
import Darwin
import TurtleGitCore

struct MergePatchOpenNativeVerification {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPatchOpen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "TurtleGit.PatchOpen." + UUID().uuidString, prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = folder.appendingPathComponent("base.cpp"), mine = folder.appendingPathComponent("mine.cpp"), patchFile = folder.appendingPathComponent("change.patch")
        let baseBytes = Data("head\nbase\ntail\n".utf8), mineBytes = Data("head\nmine\ntail\n".utf8)
        try baseBytes.write(to: base); try mineBytes.write(to: mine)
        let patch = Data("diff --git a/base.cpp b/base.cpp\n--- a/base.cpp\n+++ b/base.cpp\n@@ -1,3 +1,3 @@\n head\n-base\n+patched\n tail\n".utf8)
        try patch.write(to: patchFile)
        let root = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        let window = root.window!, frame = window.frame
        let owner = MergeEditorReplacementOwner(onClosed: {})
        root.replacementOwner = owner
        defer { owner.pendingPatch?.cancel(); (owner.current ?? root).close() }
        root.model.load(); try await TwoPaneEngineVerification.settled(root.model)
        let original = root.model.document
        let broken = folder.appendingPathComponent("bad.patch"); try Data("not a patch\n".utf8).write(to: broken)
        try root.replaceEditor(.patch(file: broken, directory: folder, clipboard: nil), permissions: [])
        try await TwoPaneEngineVerification.wait { owner.pendingPatch?.error != nil }
        try require(root.window === window && root.model.document?.base.bytes == original?.base.bytes && owner.current == nil, "Invalid patch retired original editor")
        owner.pendingPatch?.cancel(); try await TwoPaneEngineVerification.wait { owner.pendingPatch == nil }

        let helper = folder.appendingPathComponent("held-git"), ready = folder.appendingPathComponent("ready")
        try Data("#!/bin/sh\nfor argument in \"$@\"; do\nif [ \"$argument\" = --is-inside-work-tree ]; then : > \"$TG_PATCH_READY\"; /bin/sleep 30; break; fi\ndone\nexec \"$TG_PATCH_GIT\" \"$@\"\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("TG_PATCH_READY", ready.path, 1); setenv("TG_PATCH_GIT", try GitRuntime.executable().path, 1)
        defer { unsetenv("TG_PATCH_READY"); unsetenv("TG_PATCH_GIT") }
        owner.makePatchWorkflow = { file, target, bytes, grants, defaults in ReviewPatchWorkflow(file: file, target: target, grants: grants, executable: helper, preferences: defaults, clipboardBytes: bytes) }
        try root.replaceEditor(.patch(file: patchFile, directory: folder, clipboard: nil), permissions: [])
        try await TwoPaneEngineVerification.wait { FileManager.default.fileExists(atPath: ready.path) }
        try require(root.window === window && owner.current == nil && !root.windowShouldClose(window), "Pending patch did not preserve/guard original editor")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Pending patch allowed Quit")
        owner.pendingPatch?.cancel()
        try await TwoPaneEngineVerification.wait { owner.pendingPatch == nil && ReviewPatchWorkflow.activeLoads == 0 }
        try require(root.window === window, "Canceled preparation replaced original")
        owner.makePatchWorkflow = { file, target, bytes, grants, defaults in ReviewPatchWorkflow(file: file, target: target, grants: grants, executable: try GitRuntime.executable(), preferences: defaults, clipboardBytes: bytes) }
        root.openMergeDocument(nil)
        guard let open = root.editorOpenWorkflow?.opener else { throw Failure(message: "Missing File/Open") }
        open.setMode(.applyUnifiedDiff); open.diff.stringValue = patchFile.path; open.directory.stringValue = folder.path; open.accept()
        try await TwoPaneEngineVerification.wait { owner.current is WorkingTreePatchWindowController && owner.pendingPatch == nil }
        guard let review = owner.current as? WorkingTreePatchWindowController else { throw Failure(message: "Missing adopted Review/Apply") }
        try require(review.window === window && root.window == nil && window.frame == frame && window.delegate === review, "Patch adoption changed native window/frame/delegate")
        try require(review.model.review?.files.count == 1 && !review.model.busy, "Patch adopted before checked model was ready")
        review.openMergeDocument(nil)
        guard let returnOpen = review.editorOpenWorkflow?.opener else { throw Failure(message: "Patch viewer could not reopen text comparison") }
        returnOpen.setMode(.merging); returnOpen.base.stringValue = base.path; returnOpen.mine.stringValue = mine.path; returnOpen.accept()
        guard let pair = owner.current as? FileComparisonWindowController else { throw Failure(message: "Patch→text transition failed") }
        try await TwoPaneEngineVerification.settled(pair.model)
        try require(pair.window === window && review.window == nil && window.frame == frame, "Return to text lost native window geometry")
        try require(try Data(contentsOf: base) == baseBytes && Data(contentsOf: mine) == mineBytes && Data(contentsOf: patchFile) == patch, "Preparation/replacement mutated input files")
        print("PASS: invalid patch and actual Git preparation cancellation preserve original; Close/Quit fences; checked text→patch→text adoption in same native window/frame; input bytes preserved")
    }
}
