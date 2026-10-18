import AppKit
import UniformTypeIdentifiers
import TurtleGitCore

@main struct FileDropTransferVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func provider(_ url: URL) -> NSItemProvider { NSItemProvider(item: url.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier) }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Drop transfer timeout at line \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Drop transfer failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Drop QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let source = root.appendingPathComponent("file 雪\n.txt"), second = root.appendingPathComponent("second.txt"), folder = root.appendingPathComponent("destination", isDirectory: true)
        try Data("base".utf8).write(to: source); try Data("second".utf8).write(to: second); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await repo.stage([source.lastPathComponent, second.lastPathComponent]); _ = try await repo.commit(message: "base")
        try Data("staged".utf8).write(to: source); try await repo.stage([source.lastPathComponent]); try Data("working".utf8).write(to: source)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).text
        let suite = "TurtleGit.DropTransfer." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "ConfirmKillProcess"); defer { prefs.removePersistentDomain(forName: suite) }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false); owner.isReleasedWhenClosed = false; owner.alphaValue = 0; defer { owner.close() }
        let drop = FileDropTransferWindowController(repository: repo, access: nil, preferences: prefs); defer { drop.close() }
        try require(drop.present(owner: owner), "Owned drop sheet absent")
        drop.model.load([provider(source)]); try await wait { !drop.model.busy }
        try require(drop.model.choices == [.move, .moveRename] && drop.model.sources == [source] && !drop.model.canChoose(.copyAdd), "Active upstream single-source choices differ")
        drop.model.prepare(folder: root.appendingPathComponent(".git")); try await wait { !drop.model.busy }
        try require(drop.model.error != nil && drop.model.choices.isEmpty, "Administrative destination accepted")
        drop.model.prepare(folder: folder); try await wait { !drop.model.busy }
        try require(drop.model.folder == folder && drop.model.canChoose(.moveRename) && index == Data(contentsOf: root.appendingPathComponent(".git/index")), "Preparation mutated index or lost destination")
        drop.close(); try await wait { owner.attachedSheet == nil && FileDropTransferWindowController.activeReleases == 0 }; try require(owner.attachedSheet == nil && drop.model.retired, "Owned sheet not retired")
        let multiple = FileDropTransferModel(repository: repo, access: nil, preferences: prefs); multiple.load([provider(source), provider(second), provider(source)]); try await wait { !multiple.busy }
        try require(multiple.sources.count == 2 && multiple.choices == [.move], "Multi-source duplicate/order/rename gate differs"); multiple.retire()
        // Use the production captured-repository handoff, while the workspace has no active repository.
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in false }); workspace.fileComparisonPreferences = prefs; workspace.requiresRepositoryScope = false; workspace.movePresentation = { $0.window?.alphaValue = 0 }; workspace.copyPresentation = { $0.window?.alphaValue = 0 }; defer { workspace.closeRepository() }; var choice: FileDropTransferWindowController?
        workspace.configureDropTransfer = { choice = $0 }
        try require(workspace.receiveTransferDrop([provider(source)], repository: repo, owner: owner), "Production transfer route refused captured repository")
        guard let choice else { throw Failure(description: "Production drop chooser missing") }
        defer { choice.close() }
        try await wait { !choice.model.busy }; choice.model.prepare(folder: folder); try await wait { !choice.model.busy }
        choice.model.accept(.moveRename)
        try await wait { NSApp.windows.compactMap({ $0.delegate as? FileMoveWindowController }).contains(where: { $0.model.repository.root == root && !$0.model.retired }) }
        guard let moving = NSApp.windows.compactMap({ $0.delegate as? FileMoveWindowController }).first(where: { $0.model.repository.root == root && !$0.model.retired }) else { throw Failure(description: "Move/Rename handoff missing") }
        defer { moving.close() }; try await wait { !moving.model.busy }
        try require(moving.model.renameFirst && moving.model.folder == folder && moving.model.paths == [source.lastPathComponent] && workspace.root == nil, "Handoff lost captured context/rename choice")
        moving.model.move(); try await wait { moving.namePicker != nil }
        moving.namePicker!.nameField.stringValue = "renamed.txt"; moving.namePicker!.accept(); try await wait { !moving.model.busy }
        let staged = try await repo.run(["show", ":destination/renamed.txt"]).text
        try require(moving.model.moved == 1 && staged == "staged" && String(contentsOf: folder.appendingPathComponent("renamed.txt")) == "working", "Actual dropped Move/Rename lost index/working bytes"); moving.close()
        let outside = root.deletingLastPathComponent().appendingPathComponent("external-" + UUID().uuidString + ".txt"); try Data("external".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        var external: FileDropTransferWindowController?; workspace.configureDropTransfer = { external = $0 }
        try require(workspace.receiveTransferDrop([provider(outside)], repository: repo, owner: owner), "External drop rejected")
        guard let external else { throw Failure(description: "External chooser missing") }; defer { external.close() }; try await wait { !external.model.busy }
        try require(external.model.choices == [.copyAdd] && !external.model.canChoose(.move), "External sources incorrectly move eligible")
        external.model.accept(.copyAdd)
        try await wait { NSApp.windows.compactMap({ $0.delegate as? FileCopyWindowController }).contains(where: { $0.model.sources == [outside] && !$0.model.retired }) }
        guard let copying = NSApp.windows.compactMap({ $0.delegate as? FileCopyWindowController }).first(where: { $0.model.sources == [outside] && !$0.model.retired }) else { throw Failure(description: "Copy/Add handoff missing") }
        defer { copying.close() }; copying.model.run(); try await wait { !copying.model.busy }
        let copied = try await repo.run(["show", ":" + outside.lastPathComponent]).text
        try require(!copying.model.failed && copying.model.copied == 1 && copied == "external" && String(contentsOf: outside) == "external", "Drop Copy/Add failed or moved external source"); copying.close()
        // Deliberately held provider reply must retain lifetime after owner retirement.
        let late = FileDropTransferWindowController(repository: repo, access: nil, preferences: prefs); defer { late.close() }
        var release: CheckedContinuation<URL, Never>?, accepted = false
        late.model.readURL = { _ in await withCheckedContinuation { release = $0 } }; late.onAccepted = { _, _, _ in accepted = true }
        try require(late.present(owner: owner), "Late sheet absent"); late.model.load([provider(second)]); try await wait { release != nil }; late.close()
        try require(FileDropTransferModel.activePreparations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired provider lost counter/Quit lifetime")
        release?.resume(returning: second); release = nil; try await wait { FileDropTransferModel.activePreparations == 0 && FileDropTransferWindowController.activeReleases == 0 }
        try require(late.model.sources.isEmpty && !accepted && late.model.retired, "Late provider published or handed off")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).text; try require(head == finalHead, "Drop operations committed unexpectedly")
        try require(!workspace.receiveTransferDrop([], repository: repo, owner: owner) && !workspace.receiveTransferDrop([NSItemProvider(object: "text" as NSString)], repository: repo, owner: owner), "Empty/text drops accepted")
        print("PASS drop transfers: captured URL/order/duplicates, source menu choices and administrative destination guards, actual production Move/Rename and external Copy/Add effects, no unintended commit, retained provider retirement/Quit and owned sheet cleanup")
    }
}
