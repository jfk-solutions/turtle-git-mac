// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct UnifiedHandoffsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "UDiff handoff did not settle")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async throws { try await verify() }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: engine)
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","UDiff Handoff QA"),("user.email","handoff@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let working = root.appendingPathComponent("file.txt"), patchFile = root.appendingPathComponent("saved.patch")
        try Data("before\n".utf8).write(to: working); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "baseline")
        try Data("after\n".utf8).write(to: working)
        let patch = try await repo.run(["diff", "--binary", "--", "file.txt"]).stdout
        try patch.write(to: patchFile); try Data("before\n".utf8).write(to: working)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.UnifiedHandoffs.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = PatchWindowController(repository: repo, access: nil, preferences: prefs), model = owner.model, session = owner.documentSession!, window = owner.window!
        defer { owner.close() }
        window.alphaValue = 0; window.title = "original"; window.contentView?.layoutSubtreeIfNeeded()
        owner.presentDocument(patch, title: "original", comparison: "A", information: "A info", paths: ["file.txt"], file: patchFile)
        model.editDocument(model.document.text + "#unsaved\n")
        let edited = model.document.text, originalIdentity = session.documentIdentity
        var asked = 0, answer: ((PatchDocumentSession.Decision) -> Void)?
        session.askChanges = { _, reply in asked += 1; answer = reply }
        var refreshed = ""
        owner.presentDocument(Data("B\n".utf8), title: "B", comparison: "B compare", information: "B info", paths: ["b"], refreshAvailable: true, refresh: { refreshed = "B" })
        try await wait { answer != nil }
        owner.presentDocument(Data("C\n".utf8), title: "C", comparison: "C compare", information: "C info", paths: ["c"], refreshAvailable: true, refresh: { refreshed = "C" })
        try require(window.title == "original" && model.paths == ["file.txt"] && model.comparisonTitle == "A" && model.readOnlyInformation == "A info" && model.document.text == edited, "Queued comparison changed fields before decision")
        answer?(.cancel); answer = nil; try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(asked == 1 && session.documentIdentity == originalIdentity && session.fileURL == patchFile && model.document.text == edited, "Cancelled replacement lost source identity or edits")
        owner.presentDocument(Data("B\n".utf8), title: "B", comparison: "B compare", information: "B info", paths: ["b"])
        try await wait { answer != nil }
        owner.presentDocument(Data("C\n".utf8), title: "C", comparison: "C compare", information: "C info", paths: ["c"], refreshAvailable: true, refresh: { refreshed = "C" })
        answer?(.discard); answer = nil; try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(window.title == "C" && model.paths == ["c"] && model.comparisonTitle == "C compare" && model.readOnlyInformation == "C info" && model.document.text == "C\n" && session.fileURL == nil, "Accepted replacement split bytes/metadata or kept old save target")
        model.customRefresh?(); try require(refreshed == "C", "Old refresh callback survived accepted replacement")
        // A cancelled Save in the replacement question keeps all current context.
        model.editDocument("C edited\n"); session.askChanges = { _, reply in reply(.save) }; session.chooseSave = { _, _, reply in reply(nil) }
        let cIdentity = session.documentIdentity
        owner.presentDocument(Data("D\n".utf8), title: "D", comparison: "D compare", information: "D info", paths: ["d"])
        try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(window.title == "C" && model.document.text == "C edited\n" && model.documentDirty && session.documentIdentity == cIdentity, "Cancelled replacement Save changed the document")
        // Settings goes directly to the owning UDiff page and blocks document commands.
        var focus: NSWindow? = window
        let menu = PatchMenuContext(keyWindow: { focus })
        try await wait { menu.documentAvailable }
        menu.showSettings(); try await wait { session.settingsNavigation != nil }
        try require(session.settingsNavigation?.selected == .unifiedDiff && session.settingsNavigation?.globalOnly == true && model.busy && !owner.windowShouldClose(window), "Settings lost initial page or owner lock")
        try await wait { menu.documentVisible && !menu.documentAvailable }
        session.settingsWindow?.contentView?.layoutSubtreeIfNeeded()
        try require(descendants(session.settingsWindow!.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Unified Diff" }, "Settings heading did not display UDiff page")
        owner.presentDocument(Data("queued after settings\n".utf8), title: "queued", comparison: "queued", information: "queued")
        try require(window.title == "C" && model.document.text == "C edited\n", "Settings allowed queued replacement publication")
        session.settingsWindow?.close(); try await wait { session.settingsWindow == nil && !model.busy && PatchDocumentSession.activeOperations == 0 }
        try require(model.document.text == "C edited\n" && model.documentDirty && prefs.dictionaryRepresentation()["UDiffTabSize"] == nil, "Settings dismissal rewrote the patch or preferences")
        // A saved file is the Apply Patch input even while editor text is unsaved.
        session.askChanges = { _, reply in reply(.discard) }
        owner.presentDocument(patch, title: "saved file", comparison: "saved", information: "saved patch", paths: ["file.txt"], file: patchFile)
        try await wait { PatchDocumentSession.activeOperations == 0 && session.fileURL == patchFile }
        model.editDocument(model.document.text.replacingOccurrences(of: "+after", with: "+UNSAVED"))
        var child: WorkingTreePatchWindowController?, reviewRequests = 0
        session.presentReview = { _ in }
        session.configureReview = { workflow in
            reviewRequests += 1
            workflow.chooseTarget = { root }
            workflow.preparedPresentation = { child = $0 }
        }
        focus = nil; menu.applyPatch(); try require(reviewRequests == 0, "Background Apply Patch ran")
        focus = window; menu.applyPatch()
        try await wait { child != nil && !model.busy && ReviewPatchWorkflow.activeLoads == 0 }
        try require(child?.model.previewDocument.exportDocument.bytes == patch && model.documentDirty && model.document.text.contains("+UNSAVED"), "Apply Patch substituted unsaved editor bytes")
        try require(try Data(contentsOf: working) == Data("before\n".utf8), "Opening Apply Patch mutated the target")
        try require(child?.model.canApply == true, "Saved patch was not prepared for target")
        child?.model.apply(); try await wait { child?.model.busy == false && WorkingTreePatchWindowModel.activeOperations == 0 }
        try require(try Data(contentsOf: working) == Data("after\n".utf8), "Review/apply handoff did not apply saved patch")
        child?.close(); child = nil; try Data("before\n".utf8).write(to: working)
        // Context actions expire when the document identity changes.
        window.contentView?.layoutSubtreeIfNeeded()
        func source() -> PatchTextView.PatchText? { descendants(window.contentView!).compactMap { $0 as? PatchTextView.PatchText }.first }
        try await wait { source() != nil }
        let text = source()!, stale = NSMenuItem()
        stale.representedObject = session.documentIdentity.uuidString
        owner.presentDocument(Data("next\n".utf8), title: "next", comparison: "next", information: "next")
        try await wait { !model.documentDirty && PatchDocumentSession.activeOperations == 0 }
        text.applyPatchFile(stale); try require(reviewRequests == 1 && session.reviewWorkflow == nil, "Stale Apply Patch context ran on another document")
        // Generated comparisons retain the source temporary patch as immutable bytes.
        owner.presentDocument(patch, title: "generated", comparison: "generated", information: "generated snapshot")
        model.editDocument(model.document.text.replacingOccurrences(of: "+after", with: "+UNSAVED"))
        var chooseCalls = 0
        session.configureReview = { workflow in
            workflow.chooseFile = { chooseCalls += 1; return patchFile }; workflow.chooseTarget = { root }
            workflow.preparedPresentation = { child = $0 }
        }
        menu.applyPatch(); try await wait { child != nil && !model.busy && ReviewPatchWorkflow.activeLoads == 0 }
        try require(chooseCalls == 0 && child?.model.previewDocument.exportDocument.bytes == patch && model.documentDirty, "Generated Apply Patch lost loaded snapshot or substituted edits")
        child?.close(); child = nil
        owner.presentDocument(Data(), title: "unnamed", comparison: "unnamed", information: "empty patch")
        try await wait { !model.documentDirty && PatchDocumentSession.activeOperations == 0 }
        menu.applyPatch(); try await wait { child != nil && !model.busy && ReviewPatchWorkflow.activeLoads == 0 }
        try require(chooseCalls == 1 && child?.model.previewDocument.exportDocument.bytes == patch, "Empty unnamed Apply Patch bypassed file chooser")
        child?.close(); child = nil
        // Forced closure while a target chooser awaits a reply cannot publish a review.
        var reply: CheckedContinuation<URL?, Never>?, returned = false, latePresentation = false
        session.configureReview = { workflow in
            workflow.chooseFile = { patchFile }
            workflow.chooseTarget = { let result = await withCheckedContinuation { reply = $0 }; returned = true; return result }
            workflow.preparedPresentation = { _ in latePresentation = true }
        }
        menu.applyPatch(); try await wait { reply != nil }
        try require(!owner.windowShouldClose(window), "Active Apply Patch allowed parent close")
        owner.close(); reply?.resume(returning: root)
        try await wait { returned && PatchDocumentSession.activeOperations == 0 && ReviewPatchWorkflow.activeLoads == 0 }
        try require(!latePresentation && model.retired && session.reviewWorkflow == nil, "Cancelled handoff published after retirement")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(head == after && Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: patchFile) == patch && Data(contentsOf: working) == Data("before\n".utf8), "Handoff changed HEAD/index/source bytes")
        print("PASS: UDiff transactional replacement/latest metadata, Save/Cancel, owning Settings page, saved-file and unnamed Apply Patch review/apply, focused/stale commands and retirement")
    }
}
