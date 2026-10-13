import AppKit
import Darwin
import TurtleGitCore

@main struct PatchReviewLifecycleVerification {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Owned operation did not settle")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run(); print("PASS Review Patch owned cancellation/retirement, draft/export fences and Quit accounting") }
        catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repository = GitRepository(root: root, executable: git), file = root.appendingPathComponent("file.txt")
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Review QA"), ("user.email", "review@example.invalid"), ("core.hooksPath", "/dev/null"), ("commit.gpgsign", "false")] { _ = try await repository.run(["config", key, value]) }
        let before = Data("before\n".utf8); try before.write(to: file)
        try await repository.stage(["file.txt"]); _ = try await repository.commit(message: "base")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let bytes = Data("diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n".utf8)
        let suite = "TurtleGit.ReviewLifecycle.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var controllers: [WorkingTreePatchWindowController] = []
        defer { controllers.forEach { $0.close() } }
        for (number, phase) in ["--stat", "--check", "hash-object"].enumerated() {
            for forced in [false, true] {
                let wrapper = root.appendingPathComponent("held-\(number)-\(forced)"), gate = URL(fileURLWithPath: wrapper.path + ".hold"), ready = URL(fileURLWithPath: wrapper.path + ".ready")
                let quoted = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                let script = """
                #!/bin/sh
                if [ -f "$0.hold" ]; then
                  phase=$(/bin/cat "$0.hold")
                  for arg in "$@"; do
                    if [ "$arg" = "$phase" ]; then
                      /bin/sleep 30 & child=$!
                      printf '%s %s\\n' "$$" "$child" > "$0.ready"
                      wait "$child"
                      break
                    fi
                  done
                fi
                exec \(quoted) "$@"
                """
                try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
                if number == 0 { try Data(phase.utf8).write(to: gate) }
                let slow = GitRepository(root: root, executable: wrapper)
                let controller = WorkingTreePatchWindowController(repository: slow, access: nil, fileAccess: nil, bytes: bytes, title: "fixture", preferences: prefs)
                controllers.append(controller)
                let model = controller.model
                var changed = 0, stopped = 0
                model.onChanged = { _ in changed += 1 }; model.onMutationStopped = { stopped += 1 }
                if number != 0 {
                    try await wait { !model.busy }
                    try require(model.comparison != nil, "Initial comparison unavailable")
                    try Data(phase.utf8).write(to: gate)
                    if number == 1 { model.apply() }
                    else { model.setEditing(true); model.editor!.updateDraft("edited\n", base: false); model.saveDraft() }
                }
                try await wait { FileManager.default.fileExists(atPath: ready.path) }
                let pids = try String(contentsOf: ready).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored active patch work")
                if forced { controller.close() } else { model.cancelOperation() }
                try await wait { !model.busy && pids.allSatisfy { kill($0, 0) != 0 } }
                try require(changed == 0 && stopped == (number == 0 ? 0 : 1), "Cancellation reported success or lost mutation settlement")
                try require((try Data(contentsOf: file)) == before && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Canceled command changed working/index bytes")
                if number == 0 && forced { try require(model.review == nil && model.retired, "Retired read published a review") }
                if number == 2 && !forced { try require(model.dirty && model.canSaveDraft, "Canceled save lost draft retry") }
                controller.close()
            }
        }
        let promptOwner = WorkingTreePatchWindowController(repository: repository, access: nil, fileAccess: nil, bytes: bytes, title: "prompt", preferences: prefs)
        controllers.append(promptOwner); try await wait { !promptOwner.model.busy }
        promptOwner.model.setEditing(true); promptOwner.model.editor!.updateDraft("draft\n", base: false)
        var draftReply: CheckedContinuation<WorkingTreePatchWindowModel.DraftChoice, Never>?
        promptOwner.model.chooseDraft = { await withCheckedContinuation { draftReply = $0 } }
        let decision = Task { await promptOwner.model.resolveDraft() }
        try await wait { draftReply != nil }; promptOwner.close()
        let heldQuit = TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel
        draftReply?.resume(returning: .save)
        let accepted = await decision.value
        try require(heldQuit && !accepted && (try Data(contentsOf: file)) == before, "Retired draft reply saved or lost Quit ownership")
        let exportOwner = WorkingTreePatchWindowController(repository: repository, access: nil, fileAccess: nil, bytes: bytes, title: "export", preferences: prefs)
        controllers.append(exportOwner); try await wait { !exportOwner.model.busy }
        let exporter = exportOwner.model.editor!, exportFile = root.appendingPathComponent("late-export.txt")
        var exportReply: CheckedContinuation<URL?, Never>?
        exporter.chooseExportLocation = { _, _, _ in await withCheckedContinuation { exportReply = $0 } }
        exporter.export(base: false); try await wait { exportReply != nil }; exportOwner.close()
        let exportQuit = TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel
        exportReply?.resume(returning: exportFile); try await wait { !exporter.exporting }
        try require(exportQuit && !FileManager.default.fileExists(atPath: exportFile.path), "Retired export wrote a file or lost Quit ownership")
        let queuedOwner = WorkingTreePatchWindowController(repository: repository, access: nil, fileAccess: nil, bytes: bytes, title: "queued export", preferences: prefs)
        controllers.append(queuedOwner); try await wait { !queuedOwner.model.busy }
        let queuedExporter = queuedOwner.model.editor!; var lateChoices = 0
        queuedExporter.chooseExportLocation = { _, _, _ in lateChoices += 1; return nil }
        queuedExporter.export(base: false); queuedOwner.close()
        try await wait { !queuedExporter.exporting }
        try require(lateChoices == 0, "Retired queued export opened a chooser")
        try require(WorkingTreePatchWindowModel.activeOperations == 0 && FileComparisonWindowModel.activePaneExports == 0, "Operation counts did not balance")
        try require(!NSApp.windows.contains { $0.isVisible }, "Receiver displayed a window")
    }
}
