import AppKit
import TurtleGitCore

@main struct AddDropVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timed out at \(line)")
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS Add drop/lifetime: native file-URL pasteboard target, read-only scoped files/folders/ignored defaults/reset checks, preserved unchecked rows/index/HEAD/bytes, foreign-root rejection, busy/confirmation gates, cancelled/retired reads and drops/late replies/Quit accounting and stale Delete confirmation") }
        catch { fputs("FAIL Add drop: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repository.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Add Drop QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repository.run(["config",key,value]) }
        try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore")); try await repository.stage([".gitignore"]); _ = try await repository.run(["commit","-m","base"])
        let a = "first.txt", b = "new 雪\n.txt", ignored = "skip.ignored", folder = root.appendingPathComponent("folder")
        for path in [a,b,ignored] { try Data(path.utf8).write(to: root.appendingPathComponent(path)) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try Data("child".utf8).write(to: folder.appendingPathComponent("child.txt"))
        let owner = AddWindowController(repository: repository, access: nil), model = owner.model
        defer { owner.close() }
        model.setScope([a]); model.reload(); try await wait { model.canReceiveFileDrop && AddWindowModel.activeOperations == 0 }
        model.checked.remove(a)
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repository.run(["rev-parse","HEAD"]).stdout
        let coordinator = AddFileTable.Coordinator(model: model), scroll = coordinator.make()
        owner.window?.contentView?.addSubview(scroll)
        let board = NSPasteboard(name: .init("TurtleGit.AddDrop.QA." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.writeObjects([root.appendingPathComponent(b) as NSURL])
        try require(coordinator.validateDrop(board) && coordinator.acceptDrop(board), "Native registered file-URL target")
        try require(!coordinator.validateDrop(board) && !model.addDropped([root.appendingPathComponent(b)]), "Busy / competing drops")
        try await wait { model.canReceiveFileDrop && AddWindowModel.activeOperations == 0 }
        try require(model.scopePaths.contains(b) && model.checked.contains(b) && !model.checked.contains(a), "Scope extension preserves unrelated checkbox")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == before, "Add drop does not stage")
        try require(model.addDropped([folder]), "Folder drop")
        try await wait { model.canReceiveFileDrop && AddWindowModel.activeOperations == 0 }
        try require(model.entries.contains { $0.path == "folder/child.txt" } && model.checked.contains("folder/child.txt"), "Folder scope and checks")
        model.setScope(["."]); model.includeIgnored = true; model.reload(); try await wait { model.canReceiveFileDrop && AddWindowModel.activeOperations == 0 }
        model.checked.insert(ignored); model.checked.remove(a)
        try require(model.addDropped([root.appendingPathComponent(ignored)]), "Existing ignored drop")
        try await wait { model.canReceiveFileDrop && AddWindowModel.activeOperations == 0 }
        try require(!model.checked.contains(ignored) && !model.checked.contains(a), "Reset uses ignored default without checking unrelated rows")
        try require(model.addDropped([root.appendingPathComponent(a)]), "Existing untracked drop")
        try await wait { model.canReceiveFileDrop && AddWindowModel.activeOperations == 0 }
        try require(model.checked.contains(a), "Reset restores automatic untracked check")
        model.confirmingQuit = true; try require(!coordinator.validateDrop(board), "Confirmation gate"); model.confirmingQuit = false
        let foreign = root.appendingPathExtension("foreign"); try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: foreign) }
        _ = try await GitRepository(root: foreign, executable: repository.executable).run(["init","-b","main"])
        try Data("foreign".utf8).write(to: foreign.appendingPathComponent("file"))
        let scope = model.scopePaths, checks = model.checked
        try require(model.addDropped([foreign.appendingPathComponent("file")]), "Foreign drop resolved asynchronously")
        try await wait { model.canReceiveFileDrop && AddWindowModel.activeOperations == 0 }
        try require(model.scopePaths == scope && model.checked == checks && model.error == nil, "Foreign root ignored")

        let snapshot = try await repository.addDialogSelection(paths: ["."], includeIgnored: true)
        var readContinuation: CheckedContinuation<Void,Never>?, token: OperationCancellation?
        let held = AddWindowController(repository: repository, access: nil)
        held.model.querySelection = { _,_, request in token = request; await withCheckedContinuation { readContinuation = $0 }; return snapshot }
        held.model.reload(); try await wait { readContinuation != nil }; held.close()
        try require(token?.isCancelled == true && AddWindowModel.activeOperations == 1, "Retired read remains counted")
        readContinuation?.resume(); readContinuation = nil; try await wait { AddWindowModel.activeOperations == 0 }
        try require(held.model.entries.isEmpty && held.model.retired && !held.model.canApply && held.model.error == nil, "Late read cannot restore form")

        let resolved = try await repository.resolveWorkingFileDrops([root.appendingPathComponent(b)])
        var dropContinuation: CheckedContinuation<Void,Never>?
        model.queryDroppedItems = { _, request in token = request; await withCheckedContinuation { dropContinuation = $0 }; return resolved }
        try require(model.addDropped([root.appendingPathComponent(b)]), "Held drop accepted")
        try await wait { dropContinuation != nil }; model.cancel()
        try require(token?.isCancelled == true && AddWindowModel.activeOperations == 1, "Cancelled drop waits for ownership")
        dropContinuation?.resume(); dropContinuation = nil; try await wait { AddWindowModel.activeOperations == 0 }
        try require(model.retired && model.scopePaths == scope && model.error == nil && !coordinator.validateDrop(board), "Cancel closes without late scope/UI changes")

        let stale = AddWindowController(repository: repository, access: nil)
        stale.model.setScope([a]); stale.model.reload(); try await wait { stale.model.canReceiveFileDrop && AddWindowModel.activeOperations == 0 }
        guard let row = stale.model.entries.first else { throw Failure(message: "Stale-confirmation fixture missing") }
        try require(stale.model.beginDeleteConfirmation([row.status], permanently: true), "Delete confirmation started")
        stale.close()
        try require(stale.model.finishDeleteConfirmation(accepted: true) == nil && FileManager.default.fileExists(atPath: root.appendingPathComponent(a).path), "Late Yes cannot delete after close")
        let finalHead = try await repository.run(["rev-parse","HEAD"]).stdout
        try require(finalHead == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == before && (try Data(contentsOf: root.appendingPathComponent(b))) == Data(b.utf8), "Read/drop and retirement retain HEAD/index/working bytes")
    }
}
