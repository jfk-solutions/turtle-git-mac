import AppKit
import TurtleGitCore

struct ReviewPatchNativeVerification {
    @MainActor static func idle(_ model: WorkingTreePatchWindowModel) async throws {
        for _ in 0..<1500 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Patch review did not become idle")
    }
    static func expect(_ file: URL, _ bytes: Data) throws {
        let actual = try Data(contentsOf: file); precondition(actual == bytes)
    }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitReviewNative-" + UUID().uuidString)
        let target = root.appendingPathComponent("plain target 雪\n"), file = root.appendingPathComponent("single 雪\n.patch")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("before\n".utf8).write(to: target.appendingPathComponent("tracked.txt"))
        let bytes = Data("diff --git a/tracked.txt b/tracked.txt\n--- a/tracked.txt\n+++ b/tracked.txt\n@@ -1 +1 @@\n-before\n+after\ndiff --git a/added.txt b/added.txt\nnew file mode 100644\n--- /dev/null\n+++ b/added.txt\n@@ -0,0 +1 @@\n+new\n".utf8)
        try bytes.write(to: file)
        let suite = "TurtleGit.ReviewPatch.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let app = RepositoryModel(); app.reviewPatchPreferences = preferences
        var captured: WorkingTreePatchWindowController?, launches = 0
        app.reviewPatchPreparation = { workflow in
            workflow.chooseTarget = { target }; launches += 1
        }
        app.reviewPatchPresentation = { captured = $0 }
        app.handle(FinderRequest(action: .reviewPatch, paths: [file]).url!)
        for _ in 0..<1500 {
            if captured != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let controller = captured else { preconditionFailure(app.error ?? "Finder review handoff failed") }
        let model = controller.model
        try await idle(model)
        precondition(launches == 1 && app.root == nil && app.error == nil)
        precondition(model.directoryMode && !model.isGitWorkingTree && model.canApply)
        precondition(model.comparison != nil && model.editor != nil)
        try expect(target.appendingPathComponent("tracked.txt"), Data("before\n".utf8))
        let added = model.review!.files.first { $0.path == "added.txt" }!
        model.check(added.id, false); try await idle(model)
        precondition(model.canApply); model.apply(); try await idle(model)
        try expect(target.appendingPathComponent("tracked.txt"), Data("after\n".utf8))
        precondition(!FileManager.default.fileExists(atPath: target.appendingPathComponent("added.txt").path))
        model.focusFile(added.id); try await idle(model)
        precondition(model.canEditResult); model.setEditing(true)
        model.editor!.updateDraft("edited plain result\n", base: false)
        precondition(model.dirty && !controller.windowShouldClose(controller.window!))
        model.saveDraft(); try await idle(model)
        precondition(!model.dirty)
        try expect(target.appendingPathComponent("added.txt"), Data("edited plain result\n".utf8))
        precondition(!FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path))
        try expect(file, bytes)
        controller.window?.close(); captured = nil
        // A delayed owned picker must not launch a review after forced closure.
        let late = ReviewPatchWorkflow(file: file, target: nil, executable: URL(fileURLWithPath: "/usr/bin/git"), preferences: preferences)
        var continuation: CheckedContinuation<URL?, Never>?, finished = 0, targetPrompts = 0
        late.chooseTarget = { targetPrompts += 1; return await withCheckedContinuation { continuation = $0 } }
        late.presentation = { _ in preconditionFailure("Late target response opened a window") }
        late.onFinished = { finished += 1 }; late.start(); late.start()
        for _ in 0..<100 { if continuation != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(continuation != nil && targetPrompts == 1)
        late.window?.close(); continuation?.resume(returning: target); continuation = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(finished == 1 && ReviewPatchWorkflow.activeLoads == 0)
        print("Native Finder single-patch handoff: plain-folder before/after, checked subset, edited save, no Git initialization, immutable source, guarded dirty close and expired picker reply verified.")
    }
}
