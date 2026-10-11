import AppKit
import Darwin
import TurtleGitCore

struct SynchronizationApplyVerification {
    @MainActor static func wait(_ predicate: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<4000 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Sync Apply fixture did not settle at line \(line)")
    }
    @MainActor static func run(root: URL, preferences: UserDefaults) async throws {
        let git = URL(fileURLWithPath: CommandLine.arguments[2]), directory = root.appendingPathComponent("qa-sync-apply-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = GitRepository(root: root, executable: git)
        _ = try await source.run(["clone", "--no-hardlinks", "--template=", "--", root.path, directory.path])
        let original = GitRepository(root: directory, executable: git)
        for (key, value) in [("user.name", "Sync Apply QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await original.run(["config", key, value]) }
        _ = try await original.run(["switch", "-c", "patch-source"])
        var files: [URL] = []
        for (index, name) in ["file", "new-file"].enumerated() {
            try Data("patch change \(index)\n".utf8).write(to: directory.appendingPathComponent(name))
            try await original.stage([name]); _ = try await original.commit(message: "Sync patch \(index)")
            let bytes = try await original.run(["format-patch", "--stdout", "HEAD^"]).stdout
            let file = directory.appendingPathComponent(".git/qa-\(index).patch"); try bytes.write(to: file); files.append(file)
        }
        _ = try await original.run(["switch", "main"])
        let shim = directory.appendingPathComponent(".git/apply-git"), marker = directory.appendingPathComponent(".git/apply-pid"), enable = directory.appendingPathComponent(".git/apply-stall")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let environment = GitRuntime.environment(executable: git).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        let script = "#!/bin/sh\n" + environment + "\nif [ -f " + quote(enable.path) + " ]; then\nfor argument; do\nif [ \"$argument\" = am ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\ndone\nfi\nexec " + quote(git.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let repo = GitRepository(root: directory, executable: shim)
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model; var notifications = 0
        model.onTransportFinished = { _ in notifications += 1 }
        try await wait { !model.busy && model.outgoing != nil }
        let oldHead = try await original.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        model.confirmingQuit = true; model.applyPatch(); precondition(owner.importPatchController == nil)
        model.confirmingQuit = false; model.applyPatch()
        try await wait { owner.importPatchController != nil }; let cancelled = owner.importPatchController!
        precondition(cancelled.window!.sheetParent === owner.window && cancelled.window!.alphaValue == 0 && model.importingPatches && model.hasBlockingChild)
        precondition(!owner.windowShouldClose(owner.window!)); model.applyPatch(); model.manageRemotes(); model.browseBranch(.local)
        precondition(owner.importPatchController === cancelled && owner.remoteSettingsController == nil && owner.branchPicker == nil)
        cancelled.model.requestClose(); try await wait { owner.importPatchController == nil }
        let afterCancel = try await original.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(afterCancel == oldHead && model.incomingCommits == nil && !model.busy && !model.importingPatches && notifications == 0)
        model.fetch(.fetch); try await wait { !model.busy && model.commandCompleted }
        try Data("external change before import\n".utf8).write(to: directory.appendingPathComponent("extra-before-import"))
        try await original.stage(["extra-before-import"]); _ = try await original.commit(message: "External change before importing")
        let preImportHead = try await original.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        model.force = true; model.applyPatch(); try await wait { owner.importPatchController != nil }
        let importer = owner.importPatchController!; importer.model.add(files); importer.model.apply()
        try await wait { !importer.model.busy }; precondition(importer.model.finished && importer.model.error == nil)
        importer.model.apply(); try await wait { owner.importPatchController == nil && !model.busy }
        precondition(model.incomingFromPatch && model.tab == 4 && model.incomingCommits?.count == 3 && !model.incomingUpToDate && model.force && notifications > 0)
        precondition(model.incomingComparison.snapshot?.from == .revision(preImportHead))
        let count = try await original.run(["rev-list", "--count", preImportHead + "..HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(model.incomingComparison.snapshot?.files.contains { $0.path == "extra-before-import" } == false)
        precondition(count == "2") // Modal return must never import a second time.
        let newHead = try await original.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(model.incomingComparison.snapshot?.to == .revision(newHead) && owner.window!.attachedSheet == nil && importer.model.closed)
        model.applyPatch(); try await wait { owner.importPatchController != nil }; let skipped = owner.importPatchController!
        skipped.model.add(files); for item in skipped.model.items { skipped.model.check(item.id, false) }
        skipped.model.apply(); try await wait { !skipped.model.busy }; precondition(skipped.model.finished)
        skipped.model.apply(); try await wait { owner.importPatchController == nil && !model.busy }
        precondition(model.incomingFromPatch && model.incomingUpToDate && model.incomingCommits?.isEmpty == true && model.tab == 4)
        model.applyPatch(); try await wait { owner.importPatchController != nil }; let blocked = owner.importPatchController!
        blocked.model.add([files[0]]); try Data().write(to: enable); blocked.model.apply()
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        let pid = pid_t(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!, beforeReplies = notifications
        owner.close(); try await wait { kill(pid, 0) == -1 && errno == ESRCH && kill(-pid, 0) == -1 && errno == ESRCH }
        precondition(model.closed && blocked.model.closed && !blocked.model.busy && !model.importingPatches && owner.importPatchController == nil)
        precondition(owner.window!.attachedSheet == nil && blocked.window!.sheetParent == nil && notifications == beforeReplies)
        model.applyPatch(); precondition(owner.importPatchController == nil)
        let empty = directory.appendingPathComponent("empty"), manager = FileManager.default
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        let emptyRepo = GitRepository(root: empty, executable: git); _ = try await emptyRepo.run(["init", "-b", "main", "--template="])
        let emptyOwner = SynchronizationWindowController(repository: emptyRepo, access: nil, preferences: preferences)
        emptyOwner.window!.alphaValue = 0; emptyOwner.showWindow(nil)
        defer { emptyOwner.close() }
        // Wait for onAppear's initial projection before starting a command.
        try await wait { !emptyOwner.model.busy && (emptyOwner.model.outgoing != nil || emptyOwner.model.error != nil) }
        emptyOwner.model.applyPatch(); try await wait { !emptyOwner.model.busy }
        precondition(emptyOwner.importPatchController == nil && emptyOwner.model.error != nil)
        print("PASS: native Sync Apply Patch owned importer, guards/Cancel, two real commits without reapplication, separate immediate-diff/previous-Fetch log baselines and outgoing refresh, skipped/no-change result, Force preservation and forced Git/group/sheet cleanup")
    }
}
