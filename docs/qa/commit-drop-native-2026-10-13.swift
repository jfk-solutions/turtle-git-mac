import AppKit
import UniformTypeIdentifiers
import TurtleGitCore

@main struct CommitDropVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timed out at \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func provider(_ url: URL) -> NSItemProvider { NSItemProvider(item: url.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier) }
    @MainActor static func main() async {
        do { try await run(); print("PASS Commit drop: file-URL decoding, grouped native row/header gates, real scoped Add/check refresh, directory batches, staging mode, retained unrelated index/HEAD/working bytes, busy/message-only gates and Cancel/forced-close late-result/Quit fences") }
        catch { fputs("FAIL Commit drop: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repository.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Drop QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repository.run(["config",key,value]) }
        for path in ["tracked.txt","other.txt"] { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repository.stage(["tracked.txt","other.txt"]); _ = try await repository.run(["commit","-m","base"])
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("tracked.txt")); try Data("retained staged\n".utf8).write(to: root.appendingPathComponent("other.txt")); try await repository.stage(["other.txt"])
        let literal = ":(glob)雪,\nnew.txt", url = root.appendingPathComponent(literal)
        try Data("dropped bytes\n".utf8).write(to: url)
        let decoded = try await CommitFileURLReader.read(provider(url)); try require(decoded.path.utf8.elementsEqual(url.path.utf8), "Exact file-URL byte decoding")
        _ = try await repository.assignChangelist(paths: ["tracked.txt"], name: "Alpha")
        let head = try await repository.run(["rev-parse","HEAD"]).stdout, retained = try await repository.run(["ls-files","--stage","-z","--","other.txt"]).stdout
        let suite = "TurtleGit.CommitDrop.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = CommitWindowController(repository: repository, access: nil, defaults: prefs)
        defer { owner.close() }
        let model = owner.model
        model.reload(paths: ["tracked.txt"]); try await wait { !model.busy && model.canReceiveFileDrop }
        try require(!model.visibleEntries.contains(where: { $0.path == literal }), "Dropped file initially outside scope")
        model.checked.remove("tracked.txt")
        owner.window!.alphaValue = 0; owner.showWindow(nil)
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        try await wait { descendants(owner.window!.contentView!).contains { ($0 as? CommitFileInteraction.Probe)?.rows.contains(where: { $0.group != nil }) == true } }
        guard let probe = descendants(owner.window!.contentView!).compactMap({ $0 as? CommitFileInteraction.Probe }).first,
              let table = descendants(owner.window!.contentView!).compactMap({ $0 as? NSTableView }).first else { throw Failure(message: "Native table/probe missing") }
        table.layoutSubtreeIfNeeded()
        func location(_ row: Int) -> CGPoint {
            let rect = table.rect(ofRow: row), point = probe.convert(NSPoint(x: rect.midX, y: rect.midY), from: table)
            return CGPoint(x: point.x, y: probe.isFlipped ? point.y : probe.bounds.height - point.y)
        }
        guard let header = probe.rows.firstIndex(where: { $0.group != nil }), let file = probe.rows.firstIndex(where: { $0.entry != nil }) else { throw Failure(message: "Native grouped rows missing") }
        try await wait { probe.acceptsFileDrop(at: location(file)) }
        try require(!probe.acceptsFileDrop(at: location(header)), "Group heading rejects drop")
        try require(model.receiveFileDrop([provider(url)]), "Drop accepted")
        try require(!model.receiveFileDrop([provider(url)]) && !model.canReceiveFileDrop, "Competing drop rejected")
        try await wait { !model.busy && CommitWindowModel.activeFileDrops == 0 }
        try require(model.scopePaths.contains(literal) && !model.showWholeProject && model.checked.contains(literal) && !model.checked.contains("tracked.txt"), "Source scope extension / dropped check reset preserves other choices")
        let blob = try await repository.run(["show",":" + literal]).stdout
        try require(blob == Data("dropped bytes\n".utf8) && model.message.isEmpty, "Ordinary add / message retained")
        let folder = root.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("folder bytes\n".utf8).write(to: folder.appendingPathComponent("item.txt"))
        model.stagingEnabled = true
        try require(model.receiveFileDrop([provider(folder)]), "Directory drop in staging mode")
        try await wait { !model.busy && CommitWindowModel.activeFileDrops == 0 }
        try require(model.scopePaths.contains("folder") && model.stagedEntries.contains(where: { $0.path == "folder/item.txt" }), "Staging mode shows dropped descendants")
        model.messageOnly = true; try require(!model.receiveFileDrop([provider(url)]), "Message-only gate"); model.messageOnly = false
        model.confirmingQuit = true; try require(!model.receiveFileDrop([provider(url)]), "Quit-confirmation gate"); model.confirmingQuit = false

        var continuation: CheckedContinuation<URL,Never>?, writes = 0
        model.readDroppedURL = { _ in await withCheckedContinuation { continuation = $0 } }
        model.applyDroppedURLs = { _, _ in writes += 1; return [] }
        prefs.set(true, forKey: "Commit.SkipCancelConfirmation")
        try require(model.receiveFileDrop([provider(url)]), "Held drop accepted")
        var cancelled = false
        try await wait { continuation != nil }; model.cancel(closeWindow: false, completion: { cancelled = $0 })
        continuation?.resume(returning: url); continuation = nil
        try await wait { cancelled && model.canReceiveFileDrop && CommitWindowModel.activeFileDrops == 0 }
        try require(writes == 0 && model.messageFocusAvailable, "Cancel fences decoder before mutation")
        try require(model.receiveFileDrop([provider(url)]), "Second held drop accepted")
        try await wait { continuation != nil }; owner.close()
        try require(CommitWindowModel.activeFileDrops == 1, "Retired held request remains counted")
        continuation?.resume(returning: url); continuation = nil
        try await wait { CommitWindowModel.activeFileDrops == 0 }
        try require(writes == 0 && !model.messageFocusAvailable && !model.busy, "Forced close fences late drop")
        let lateURL = root.appendingPathComponent("late.txt"); try Data("accepted late bytes".utf8).write(to: lateURL)
        let late = CommitWindowModel(repository: repository, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        late.reload(paths: ["tracked.txt"]); try await wait { late.canReceiveFileDrop }
        var backend: CheckedContinuation<Void,Never>?
        let originalScope = late.scopePaths, originalChecks = late.checked
        late.applyDroppedURLs = { urls, _ in
            await withCheckedContinuation { backend = $0 }
            // Deliberately ignores cancellation to model an already authorized write.
            return try await repository.addDroppedCommitFiles(urls)
        }
        try require(late.receiveFileDrop([provider(lateURL)]), "Held backend accepted")
        try await wait { backend != nil }; late.invalidateForClose()
        try require(CommitWindowModel.activeFileDrops == 1, "Retired backend remains counted")
        backend?.resume(); backend = nil; try await wait { CommitWindowModel.activeFileDrops == 0 }
        try require(late.scopePaths == originalScope && late.checked == originalChecks && late.error == nil && !late.busy, "Late backend cannot publish or refresh retired form")
        let lateBlob = try await repository.run(["show",":late.txt"]).stdout
        try require(lateBlob == Data("accepted late bytes".utf8), "Accepted write may settle after owner closure")
        let finalHead = try await repository.run(["rev-parse","HEAD"]).stdout, finalRetained = try await repository.run(["ls-files","--stage","-z","--","other.txt"]).stdout
        try require(finalHead == head && finalRetained == retained && (try Data(contentsOf: url)) == Data("dropped bytes\n".utf8) && (try Data(contentsOf: folder.appendingPathComponent("item.txt"))) == Data("folder bytes\n".utf8), "Unrelated index/HEAD/working bytes retained")
    }
}
