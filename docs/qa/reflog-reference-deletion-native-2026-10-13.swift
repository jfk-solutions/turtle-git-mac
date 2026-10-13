import AppKit
import TurtleGitCore

@main struct RefLogReferenceDeletionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func table(_ view: NSView) -> ReferenceLogTableView? {
        if let value = view as? ReferenceLogTableView { return value }
        return view.subviews.compactMap(table).first
    }
    @MainActor static var phase = "initial"
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "RefLog deletion did not settle at " + phase)
    }
    @MainActor static func settle(_ owner: ReferenceLogWindowController) async throws {
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); return !owner.model.busy && table(owner.window!.contentView!) != nil }
        try await Task.sleep(nanoseconds: 40_000_000)
        try await wait { !owner.model.busy }
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        table(owner.window!.contentView!)!.owner!.update(model: owner.model, dates: .load(defaults: owner.model.preferences))
    }
    @MainActor static func invoke(_ item: NSMenuItem) throws {
        try require(item.isEnabled && item.action != nil, "Disabled item: " + item.title)
        try require(NSApp.sendAction(item.action!, to: item.target, from: item), "Action dispatch failed")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("RefLog reference deletion failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.RefLogReferences.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Deletion QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        _ = try await repo.run(["branch","a"]); _ = try await repo.run(["branch","b"])
        _ = try await repo.run(["-c","tag.gpgsign=false","tag","-a","release","-m","annotated"])
        phase = "initial load"; print("Phase:", phase)
        let owner = ReferenceLogWindowController(repository: repo, access: nil, reference: "HEAD", preferences: prefs)
        defer { owner.close() }
        let model = owner.model
        var failures: [String] = []
        model.acknowledgeReferenceDeletionFailure = { failures.append($0) }
        model.reload(); try await settle(owner)
        let native = table(owner.window!.contentView!)!; native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let ids = model.selection, names = model.referenceDeletionCandidates(ids)
        try require(names == ["refs/heads/a","refs/heads/b","refs/tags/release"], "Current branch or peeled duplicates included")
        let menu = native.owner!.menu(), deletion = menu.item(withTitle: "Delete branch/tag")!.submenu!
        try require(deletion.items.map(\.title) == names + ["All"] && deletion.items.allSatisfy { $0.image != nil }, "Source submenu/icons/All missing")
        let prepared = try await repo.prepareHistoryReferenceDeletion("refs/heads/a")
        let alert = HistoryReferenceDeletionPresentation.alert(prepared)
        try require(alert.buttons.map(\.title) == ["Delete","Abort"] && alert.buttons[1].keyEquivalent == "\r" && alert.window.defaultButtonCell === alert.buttons[1].cell, "Shared confirmation lost Abort default")
        phase = "Abort"; print("Phase:", phase)
        var prompts: [String] = [], changes = 0
        model.onChanged = { _ in changes += 1 }
        model.confirmReferenceDeletion = { prompts.append($0.name); return .abort }
        try invoke(deletion.item(withTitle: names[0])!); try await settle(owner)
        try require(prompts == [names[0]] && changes == 0, "Abort changed references")
        phase = "partial All"; print("Phase:", phase)
        model.confirmReferenceDeletion = { prompts.append($0.name); return $0.name == "refs/heads/b" ? .abort : .delete }
        prompts = []; try invoke(deletion.item(withTitle: "All")!); try await settle(owner)
        try require(prompts == ["refs/heads/a","refs/heads/b"] && changes == 1, "All did not stop on Abort or refresh partial deletion")
        let afterAbort = try await repo.run(["show-ref"]).text
        try require(!afterAbort.contains("refs/heads/a") && afterAbort.contains("refs/heads/b") && afterAbort.contains("refs/tags/release"), "All Abort deleted later names")
        native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        model.confirmReferenceDeletion = { _ in .delete }
        phase = "annotated tag"; print("Phase:", phase)
        model.deleteNamedReferences(["refs/tags/release"], ids: ids); try await settle(owner)
        let deletedTag = try await repo.run(["show-ref","--verify","--quiet","refs/tags/release"], successfulExitCodes: 0...1)
        try require(deletedTag.exitCode == 1, "Annotated tag not deleted")
        try require((try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Local named deletion changed index")
        // A name moving while its prompt is open is rejected by the shared engine.
        model.confirmReferenceDeletion = { _ in
            _ = try? await repo.run(["update-ref","refs/heads/b", "HEAD~0"])
            _ = try? await repo.run(["commit","--allow-empty","-m","moved"])
            _ = try? await repo.run(["branch","-f","b","HEAD"])
            return .delete
        }
        phase = "moved ref"; print("Phase:", phase)
        model.deleteNamedReferences(["refs/heads/b"], ids: ids); try await settle(owner)
        try require(!failures.isEmpty, "Moved reference not rejected")
        let bStillThere = try await repo.run(["show-ref","--verify","--quiet","refs/heads/b"], successfulExitCodes: 0...1)
        try require(bStillThere.exitCode == 0, "Moved reference was deleted")
        model.error = nil; model.reload(); try await settle(owner)
        native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        phase = "remote setup"; print("Phase:", phase)
        let server = root.appendingPathComponent("server.git")
        _ = try await repo.run(["init","--bare",server.path]); _ = try await repo.run(["remote","add","origin",server.path]); _ = try await repo.run(["push","origin","HEAD:refs/heads/topic"])
        model.reload(); try await settle(owner); native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var remoteChoices = false
        model.confirmReferenceDeletion = { request in
            remoteChoices = request.choices.count == 3
            return .remoteAndLocal
        }
        phase = "remote deletion"; print("Phase:", phase)
        model.deleteNamedReferences(["refs/remotes/origin/topic"], ids: model.selection); try await settle(owner)
        let remoteAfter = try await repo.run(["--git-dir=" + server.path,"show-ref","--verify","--quiet","refs/heads/topic"], successfulExitCodes: 0...1)
        try require(remoteChoices && remoteAfter.exitCode == 1, "Private remote deletion failed")
        phase = "stash setup"; print("Phase:", phase)
        for number in 1...2 {
            try Data("stash \(number)\n".utf8).write(to: root.appendingPathComponent("file"))
            _ = try await repo.run(["stash","push","-m","stash \(number)"])
        }
        model.reference = "refs/stash"; model.reload(); try await settle(owner)
        native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var stashChoices = false
        model.confirmReferenceDeletion = { request in stashChoices = request.choices.map(\.title) == ["Delete","Drop one stash","Abort"]; return .stashOne }
        phase = "stash drop"; print("Phase:", phase)
        model.deleteNamedReferences(["refs/stash"], ids: model.selection); try await settle(owner)
        try require(stashChoices && model.entries.count == 1, "Drop one stash did not retain older stash")
        native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        phase = "stash clear"; print("Phase:", phase)
        model.confirmReferenceDeletion = { _ in .stashAll }
        print("Before clear:", model.reference, model.busy, model.selection, model.referenceDeletionCandidates(model.selection), model.error ?? "no error")
        model.deleteNamedReferences(["refs/stash"], ids: model.selection); try await settle(owner)
        print("After clear:", model.reference, model.busy, model.selection, model.entries.count, model.error ?? "no error", try await repo.run(["stash","list"]).text)
        try require(model.entries.isEmpty, "Delete all stash did not refresh to empty")
        model.reference = "HEAD"
        let beforeCloseIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        // Closing during confirmation must cancel the mutation and retain Quit accounting.
        model.reload(); try await settle(owner); native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        phase = "close confirmation"; print("Phase:", phase)
        var held: CheckedContinuation<HistoryReferenceDeleteChoice, Never>?
        model.confirmReferenceDeletion = { _ in await withCheckedContinuation { held = $0 } }
        model.deleteNamedReferences(["refs/heads/b"], ids: model.selection)
        try await wait { held != nil }
        owner.window!.close()
        try require(ReferenceLogWindowModel.activeRevisionReads > 0, "Pending deletion lost Quit ownership")
        phase = "close settle"; print("Phase:", phase)
        held!.resume(returning: .delete); held = nil
        try await wait { ReferenceLogWindowModel.activeRevisionReads == 0 }
        let retained = try await repo.run(["show-ref","--verify","--quiet","refs/heads/b"], successfulExitCodes: 0...1)
        try require(retained.exitCode == 0 && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == beforeCloseIndex && (try Data(contentsOf: root.appendingPathComponent("file"))) == Data("base\n".utf8), "Close mutated retained branch/index/worktree")
        try require(head != (try await repo.run(["rev-parse","HEAD"]).stdout), "Explicit stale-reference fixture did not move HEAD")
        print("RefLog named-reference deletion: current exclusion, annotated tags, original submenu/All icons, Abort default, partial All Abort, moved-reference refusal, private remote execution and forced-close cancellation/accounting passed. Owned windows closed.")
    }
}
