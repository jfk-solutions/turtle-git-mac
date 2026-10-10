import AppKit
import TurtleGitCore
import Darwin

@main struct LogFindVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(line: line)
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func key(_ window: NSWindow, text: String, modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 36) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await verify(); fflush(stdout); exit(0) }
            catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Log Find Test"])
        _ = try await repo.run(["config", "user.email", "find@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let path = "original 雪\n.txt", renamed = "renamed 雪\n.txt"
        try Data("root file\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "RootMarker")
        let rootHash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["notes", "add", "-m", "OnlyRootNote"])
        _ = try await repo.run(["tag", "-a", "root-tag", "-m", "RootAnnotation"])
        _ = try await repo.run(["mv", "--", path, renamed]); _ = try await repo.commit(message: "HeadMarker")
        let headHash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let tracked = [".git/HEAD", ".git/index", ".git/config", renamed, ".git/refs/heads/main", ".git/refs/notes/commits"]
        let before = try tracked.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.LogFind.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let controller = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false)
        let window = controller.window!; window.alphaValue = 0
        defer { controller.find?.close(); controller.model.invalidate(); window.close() }
        try await wait { !controller.model.busy }
        if controller.model.entries.filter({ !$0.hash.isEmpty }).count != 2 { print("Initial Log diagnostic:", controller.model.entries.count, controller.model.error ?? "no error") }
        try require(controller.model.entries.filter { !$0.hash.isEmpty }.count == 2)
        controller.model.select([headHash])
        try require(window.performKeyEquivalent(with: key(window, text: "f", modifiers: .command, code: 3)))
        let find = controller.find!, child = find.window!
        try require(find.searchIndex() == 0)
        try require(find.loadingReferences && !find.searchBox.isEnabled && child.parent == window && child.alphaValue == 0)
        find.searchBox.stringValue = "OnlyRootNote"; find.findNext()
        try require(!find.busy && controller.model.selected == [headHash])
        try await wait { !find.loadingReferences }
        try require(find.references.contains("refs/tags/root-tag") && find.references.contains("refs/heads/main"))
        try require(window.performKeyEquivalent(with: key(window, text: "f", modifiers: .command, code: 3)) && controller.find === find)
        find.searchBox.stringValue = "OnlyRootNote"; find.findNext(); try await wait { !find.busy }
        try require(controller.model.selected == [rootHash] && controller.model.scrollRevision == rootHash)
        find.findNext(); try await wait { !find.busy }
        try require(find.status.stringValue == "No further match in the displayed log.")
        find.searchBox.stringValue = "HeadMarker"; find.findNext(); try await wait { !find.busy }
        try require(controller.model.selected == [headHash] && find.status.stringValue.contains("beginning"))
        find.searchBox.stringValue = "OnlyRootNote"; child.sendEvent(key(child, text: "\r", modifiers: .shift))
        try await wait { !find.busy }
        try require(controller.model.selected == [headHash] && controller.model.scrollRevision == rootHash)
        find.searchReference("refs/tags/root-tag"); try await wait { !find.busy }
        try require(controller.model.selected == [rootHash])
        find.searchBox.stringValue = renamed; find.findNext(); try await wait { !find.busy }
        try require(controller.model.selected == [headHash])
        find.searchReference("refs/tags/root-tag"); try await wait { !find.busy }
        _ = try await repo.run(["tag", "-d", "root-tag"])
        find.searchReference("refs/tags/root-tag"); try await wait { child.attachedSheet != nil }
        let sheet = child.attachedSheet!
        try require(find.acknowledgingFailure && controller.model.findBlocked && !controller.windowShouldClose(window) && sheet.alphaValue == 0)
        find.cancelButton.performClick(nil); try require(!find.closed)
        sheet.sendEvent(key(sheet, text: "\r")); try await wait { child.attachedSheet == nil && !find.acknowledgingFailure }
        try require(!controller.model.findBlocked && find.searchBox.isEnabled)
        child.makeFirstResponder(find.searchBox)
        guard let editor = find.searchBox.currentEditor() as? NSTextView else { throw Failure(line: #line) }
        editor.selectAll(nil); editor.insertText("HeadMarker", replacementRange: editor.selectedRange())
        child.sendEvent(key(child, text: "\r")); try await wait { !find.busy }
        try require(controller.model.selected == [headHash])
        find.cancelButton.performClick(nil); try await wait { controller.find == nil }
        try require(find.closed && child.parent == nil)
        let retainedIndex = controller.model.findSearchIndex
        try require(controller.model.entries[retainedIndex].hash == headHash)
        // Ordinary selection does not reset the source-owned Find position.
        controller.model.select([rootHash])
        controller.showFind(); let reopened = controller.find!
        try await wait { !reopened.loadingReferences }
        try require(reopened.searchIndex() == retainedIndex)
        reopened.searchBox.stringValue = "HeadMarker"; reopened.findNext(); try await wait { !reopened.busy }
        try require(reopened.status.stringValue.contains("No further match") && controller.model.selected == [rootHash])
        reopened.searchBox.stringValue = "OnlyRootNote"; reopened.findNext(); try await wait { !reopened.busy }
        try require(controller.model.selected == [rootHash] && controller.model.entries[controller.model.findSearchIndex].hash == rootHash)
        let beforeReloadIndex = controller.model.findSearchIndex
        controller.model.reload(); try await wait { !controller.model.busy && !reopened.loadingReferences }
        try require(reopened.searchIndex() == beforeReloadIndex)
        // A shorter history must still terminate when the retained index is stale.
        controller.model.findSearchIndex = controller.model.entries.count + 10
        reopened.searchBox.stringValue = "no-such-cursor-match"; reopened.findNext(); try await wait { !reopened.busy }
        try require(reopened.status.stringValue.contains("No further match"))
        let historyTable = views(window.contentView!).compactMap { $0 as? HistoryTableView }.first!
        let headIndex = controller.model.entries.firstIndex { $0.hash == headHash }!
        historyTable.selectRowIndexes(IndexSet(integer: headIndex), byExtendingSelection: false)
        let menu = historyTable.menu!
        menu.delegate?.menuNeedsUpdate?(menu)
        try require(reopened.searchIndex() == headIndex)
        // Source Log Refresh also rebuilds an already-open Find reference list.
        reopened.referenceFilter.stringValue = "refs/tags/refresh-"; reopened.applyReferenceFilter()
        _ = try await repo.run(["tag", "refresh-first", rootHash])
        _ = try await repo.run(["tag", "refresh-10", rootHash])
        _ = try await repo.run(["tag", "refresh-2", rootHash])
        reopened.searchBox.stringValue = "OnlyRootNote"; reopened.findNext(); try require(reopened.busy)
        let retainedBeforeRefresh = controller.model.findSearchIndex
        controller.model.reload()
        try require(reopened.loadingReferences && !reopened.busy && reopened.references.isEmpty && !reopened.findButton.isEnabled)
        try await wait { !controller.model.busy && !reopened.loadingReferences }
        try require(reopened.visibleReferences == ["refs/tags/refresh-2", "refs/tags/refresh-10", "refs/tags/refresh-first"] && reopened.searchIndex() == retainedBeforeRefresh)
        _ = try await repo.run(["tag", "-d", "refresh-2", "refresh-10"])
        _ = try await repo.run(["tag", "refresh-literal-café", rootHash])
        controller.model.reload(); try await wait { !controller.model.busy && !reopened.loadingReferences }
        let literalRef = reopened.references.first { $0.hasPrefix("refs/tags/refresh-literal-caf") }!
        let composed = (literalRef as NSString).precomposedStringWithCanonicalMapping
        let decomposed = (literalRef as NSString).decomposedStringWithCanonicalMapping
        let otherSpelling = Array(literalRef.utf16) == Array(composed.utf16) ? decomposed : composed
        try require(Array(literalRef.utf16) != Array(otherSpelling.utf16))
        reopened.referenceFilter.stringValue = otherSpelling; reopened.applyReferenceFilter()
        try require(reopened.visibleReferences.isEmpty)
        reopened.referenceFilter.stringValue = literalRef; reopened.applyReferenceFilter()
        try require(reopened.visibleReferences == [literalRef])
        reopened.referenceFilter.stringValue = literalRef.uppercased(); reopened.applyReferenceFilter()
        try require(reopened.visibleReferences.isEmpty)
        _ = try await repo.run(["tag", "-d", String(literalRef.dropFirst("refs/tags/".count))])
        reopened.referenceFilter.stringValue = "refs/tags/refresh-"; reopened.applyReferenceFilter()
        try require(reopened.referenceFilter.stringValue == "refs/tags/refresh-" && reopened.searchBox.stringValue == "OnlyRootNote")
        // A newer refresh supersedes an in-flight read; only its list may publish.
        reopened.loadReferences(); try require(reopened.loadingReferences)
        _ = try await repo.run(["tag", "-d", "refresh-first"])
        _ = try await repo.run(["tag", "refresh-latest", rootHash])
        controller.model.reload(); controller.model.reload()
        try await wait { !controller.model.busy && !reopened.loadingReferences }
        try require(reopened.visibleReferences == ["refs/tags/refresh-latest"] && !reopened.references.contains("refs/tags/refresh-first"))
        reopened.searchReference("refs/tags/refresh-latest"); try await wait { !reopened.busy }
        try require(controller.model.selected == [rootHash])
        var deletionFailure: String?
        controller.model.confirmReferenceDeletion = { request in request.name == "refs/tags/refresh-latest" ? .delete : .abort }
        controller.model.acknowledgeReferenceDeletionFailure = { deletionFailure = $0 }
        controller.model.deleteReferences([LogReferenceMenuTarget(hash: rootHash, name: "refs/tags/refresh-latest")])
        try require(controller.model.busy)
        try await wait { !controller.model.busy && !reopened.loadingReferences }
        try require(deletionFailure == nil && reopened.visibleReferences.isEmpty && !reopened.references.contains("refs/tags/refresh-latest"))
        reopened.searchReference("refs/tags/refresh-latest"); try await wait { reopened.window?.attachedSheet != nil }
        // A Log refresh during acknowledgment waits for the critical sheet.
        _ = try await repo.run(["tag", "refresh-after-error", rootHash])
        controller.model.reload(); try require(reopened.acknowledgingFailure && !reopened.loadingReferences)
        let refreshSheet = reopened.window!.attachedSheet!
        refreshSheet.sendEvent(key(refreshSheet, text: "\r"))
        try await wait { !reopened.acknowledgingFailure && !reopened.loadingReferences && !controller.model.busy }
        try require(reopened.visibleReferences == ["refs/tags/refresh-after-error"])
        _ = try await repo.run(["tag", "-d", "refresh-after-error"])
        // Closing cancels a pending reference read and rejects its late reply.
        reopened.loadReferences(); try require(reopened.loadingReferences)
        window.close(); try await wait { controller.find == nil && controller.model.isInvalidated }
        let after = try tracked.map { try Data(contentsOf: root.appendingPathComponent($0)) }; try require(after == before)
        print("PASS: Native Log Find Command-F reuse, initialization exclusion, full-text notes/paths, wrap, reference navigation, Shift/plain Return, critical Return recovery, Cancel, parent-owned numeric cursor across reopen/reload, stale-index termination and Log context-menu positioning and parent-close cleanup; Log refresh replaces naturally sorted refs with literal UTF-16/case-sensitive filtering, supersedes reads/searches, follows actual Log tag deletion, defers behind critical sheets and cancels on close; listed repository bytes unchanged (owned error tags removed). No installed Finder, physical gestures or signed acceptance.")
    }
}
