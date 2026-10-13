import AppKit
import TurtleGitCore

actor RefLogOperationGate {
    var continuation: CheckedContinuation<[LogEntry], Error>?
    var token: OperationCancellation?
    func read(_ token: OperationCancellation) async throws -> [LogEntry] { self.token = token; return try await withCheckedThrowingContinuation { continuation = $0 } }
    func release(_ value: [LogEntry]) { continuation?.resume(returning: value); continuation = nil }
}
@main struct RefLogOperationVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(description: "RefLog operation did not settle") }
    @MainActor static func table(_ view: NSView) -> ReferenceLogTableView? { (view as? ReferenceLogTableView) ?? view.subviews.compactMap(table).first }
    @MainActor static func invoke(_ item: NSMenuItem) throws { guard item.isEnabled, let action = item.action else { throw Failure(description: "Operation item disabled") }; try require(NSApp.sendAction(action, to: item.target, from: item), "Operation dispatch failed") }
    @MainActor static func main() async { do { try await verify() } catch { fputs("RefLog operations failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.RefLogOperations.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Operation QA"),("user.email","operations@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        let file = root.appendingPathComponent("file")
        try Data("base\n".utf8).write(to:file); try await repo.stage(["file"]); _ = try await repo.commit(message:"Base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["branch","side"])
        try Data("main\n".utf8).write(to:file); try await repo.stage(["file"]); _ = try await repo.commit(message:"Main")
        let middle = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["branch","alias",middle])
        _ = try await repo.run(["checkout","side"])
        try Data("side\n".utf8).write(to:root.appendingPathComponent("side")); try await repo.stage(["side"]); _ = try await repo.commit(message:"Side")
        _ = try await repo.run(["checkout","main"]); _ = try await repo.run(["merge","--no-ff","side","-m","Merged"])
        let head = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines), index = try Data(contentsOf:root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf:file)
        let owner = ReferenceLogWindowController(repository:repo,access:nil,reference:"HEAD",preferences:prefs); defer { owner.close() }
        var merge = "", rebase = "", picks: [String] = [], reverted: [LogEntry] = [], mainline: Int?
        owner.model.onMergeRevision = { merge = $0 }; owner.model.onRebaseRevision = { rebase = $0 }
        owner.model.onCherryPick = { picks = $0 }; owner.model.onRevertRevisions = { reverted = $0; mainline = $1 }
        owner.model.reload()
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); return !owner.model.busy && table(owner.window!.contentView!) != nil && owner.model.entries.contains { $0.hash == middle } }
        let native = table(owner.window!.contentView!)!, model = owner.model
        func select(_ hash: String) throws -> Set<String> {
            guard let row = model.entries.firstIndex(where: { $0.hash == hash }) else { throw Failure(description:"Missing reflog hash") }
            native.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); return [model.entries[row].id]
        }
        let middleIDs = try select(middle)
        model.requestDiffParents(model.entries.first { middleIDs.contains($0.id) }!)
        try await wait { model.diffParents[middle] != nil }
        let menu = native.owner!.menu()
        let mergeItem = menu.items.first { $0.title.hasPrefix("Merge into") }!, rebaseItem = menu.items.first { $0.title.hasPrefix("Rebase ") }!, pickItem = menu.items.first { $0.title.hasPrefix("Cherry pick") }!
        try require([mergeItem,rebaseItem,pickItem].allSatisfy { $0.image != nil }, "Source operation icons missing")
        try invoke(mergeItem); try require(merge == middle, "Merge target changed")
        try invoke(rebaseItem); try require(rebase == "refs/heads/alias", "Rebase did not prefer a local reference")
        try invoke(pickItem); try await wait { !model.busy && !picks.isEmpty }
        try require(picks == [middle], "Cherry Pick target changed")
        let headIDs = try select(head); model.requestDiffParents(model.entries.first { headIDs.contains($0.id) }!)
        try await wait { model.diffParents[head]?.count == 2 }
        try require(!model.operationAvailable(.cherryPick,ids:headIDs) && !model.operationAvailable(.merge,ids:headIDs), "HEAD operation gates ignored")
        let revert = native.owner!.menu().items.first { $0.title.hasPrefix("Revert change") }!
        try require(revert.submenu?.items.count == 2, "Merge Revert lost parent choice")
        try invoke(revert.submenu!.items[1]); try await wait { !model.busy && !reverted.isEmpty }
        try require(reverted.map(\.hash) == [head] && mainline == 2 && reverted[0].parents.count == 2, "Revert lost immutable metadata/mainline")
        let rootIDs = try select(base); model.requestDiffParents(model.entries.first { rootIDs.contains($0.id) }!)
        try await wait { model.diffParents[base] != nil }
        try require(!model.operationAvailable(.revert,ids:rootIDs), "Source root Revert should be absent")
        try Data((head+"\n").utf8).write(to:root.appendingPathComponent(".git/MERGE_HEAD")); model.reload(); try await wait { !model.busy }
        try require(model.mergeActive && !model.operationAvailable(.cherryPick,ids:middleIDs), "Active merge did not block operation family")
        try FileManager.default.removeItem(at:root.appendingPathComponent(".git/MERGE_HEAD")); model.reload(); try await wait { !model.busy }
        let capturedRows = model.entries.filter { middleIDs.contains($0.id) }
        let metadata = try await repo.referenceLogOperationEntries(snapshot:capturedRows,selected:middleIDs)
        let gate = RefLogOperationGate(); model.readOperationEntries = { _,_,token in try await gate.read(token) }
        picks = []; model.performOperation(.cherryPick,ids:middleIDs)
        try await wait { model.busy && ReferenceLogWindowModel.activeRevisionReads > 0 }
        while await gate.continuation == nil { try await Task.sleep(nanoseconds:1_000_000) }
        owner.window!.close()
        try require(await gate.token?.isCancelled == true, "Forced close did not cancel owned metadata read")
        try require(ReferenceLogWindowModel.activeRevisionReads > 0, "Retired reader disappeared from Quit accounting")
        await gate.release(metadata); try await wait { ReferenceLogWindowModel.activeRevisionReads == 0 }
        try require(picks.isEmpty, "Retired RefLog launched a late Cherry Pick")
        let after = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(after == head && (try Data(contentsOf:root.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf:file)) == bytes, "Review routing changed repository state")
        print("RefLog operations: native Merge/Rebase/Cherry Pick routing/icons, local-ref default, HEAD/root/active-merge gates, merge-parent Revert metadata, forced-close cancellation and retained Quit accounting passed. Workflows reviewed without submitting Git mutations; owned window closed.")
    }
}
