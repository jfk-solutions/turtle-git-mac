import AppKit
import TurtleGitCore

@main struct FilePatchesVerification {
    @MainActor static func main() async {
        do { try await run(); print("PASS File patches: highlighted versus checked selection, ordered Patch all continuation/error status, failed-file retry, stale menu refusal, retired command refusal and unchanged HEAD/index") }
        catch { fputs("FAIL File patches: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repository = GitRepository(root: root, executable: git, askpass: nil)
        _ = try await repository.run(["init", "-b", "main"])
        for (key,value) in [("user.name","File patch QA"),("user.email","patch@example.invalid"),("commit.gpgsign","false")] { _ = try await repository.run(["config",key,value]) }
        let paths = ["a.txt","middle.txt","z.txt"]
        for path in paths { try Data("before\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repository.stage(paths); _ = try await repository.commit(message: "base")
        for path in paths { try Data("after\n".utf8).write(to: root.appendingPathComponent(path)) }
        let bytes = try await repository.run(["diff","--binary","--"]).stdout
        for path in paths { try Data("before\n".utf8).write(to: root.appendingPathComponent(path)) }
        try Data("conflict\n".utf8).write(to: root.appendingPathComponent("middle.txt"))
        let head = try await repository.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.FilePatches.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = WorkingTreePatchWindowController(repository: repository, access: nil, fileAccess: nil, bytes: bytes, title: "File patches QA", preferences: preferences)
        defer { controller.close() }
        let model = controller.model
        func wait() async throws {
            for _ in 0..<1000 { if !model.busy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            model.cancelOperation(); throw NSError(domain: "File patch timeout", code: 1)
        }
        try await wait()
        guard let review = model.review else { throw NSError(domain: "Review missing", code: 1) }
        precondition(!model.canApply && model.canPatchFiles && review.files.count == 3)
        let all = Set(review.files.map(\.id)), first = review.files[0].id
        model.highlightFiles([first]); try await wait()
        precondition(model.highlightedFiles == [first] && model.selected == all)
        do {
            guard let editor = model.editor else { throw NSError(domain: "Comparison editor missing", code: 1) }
            for _ in 0..<1000 { if !editor.filtering { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let alignment = editor.alignment
            guard alignment != nil else { throw NSError(domain: "Text engine unavailable in native fixture", code: 1) }
            editor.error = "Fixture save error"
            precondition(model.comparisonPresentation == .text)
            editor.alignment = nil; editor.error = "Fixture comparison engine unavailable"
            precondition(model.comparisonPresentation == .failure("Fixture comparison engine unavailable"))
            editor.error = nil
            precondition(model.comparisonPresentation != .binary)
            editor.alignment = alignment
        }
        let stale = model.fileListGeneration
        model.refresh(); try await wait(); model.patchFiles(all, generation: stale); precondition(!model.busy && model.appliedPaths.isEmpty)
        model.patchFiles(all, generation: model.fileListGeneration); precondition(model.busy)
        try await wait()
        precondition(model.appliedPaths == Set([Data("a.txt".utf8),Data("z.txt".utf8)]))
        precondition(model.fileResults[Data("middle.txt".utf8)]?.success == false && model.output.contains("Error: middle.txt"))
        let shown = model.focusedFile
        model.focusFile(review.files[2].id)
        precondition(!model.busy && model.focusedFile == shown)
        model.focusFile(review.files[1].id);try await wait()
        for _ in 0..<1000 {if model.conflictEditor?.busy == false && model.conflictEditor?.document != nil {break};try await Task.sleep(nanoseconds:10_000_000)}
        precondition(model.focusedFile == review.files[1].id && model.conflictEditor?.document != nil && model.fileResults[Data("middle.txt".utf8)]?.requiresMerge == true)
        for path in ["a.txt","z.txt"] { let value = try String(contentsOf: root.appendingPathComponent(path)); precondition(value == "after\n") }
        try Data("before\n".utf8).write(to: root.appendingPathComponent("middle.txt"))
        model.patchFiles(all, generation: model.fileListGeneration); try await wait()
        precondition(model.appliedPaths.count == 3 && !model.canPatchFiles && model.fileResults[Data("middle.txt".utf8)]?.success == true)
        let afterHead = try await repository.run(["rev-parse","HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(head == afterHead && index == afterIndex)
        model.retire(); model.patchFiles(all, generation: model.fileListGeneration); precondition(!model.busy)
        precondition(WorkingTreePatchWindowModel.activeOperations == 0 && !NSApp.windows.contains { $0.isVisible })
    }
}
