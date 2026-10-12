import AppKit
import TurtleGitCore

private struct MergeOpenCheckFailure: Error { let line: Int }
struct MergeOpenNativeVerification {
    @MainActor static func require(_ value: @autoclosure () -> Bool, line: Int = #line) throws { if !value() { throw MergeOpenCheckFailure(line: line) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw MergeOpenCheckFailure(line: #line)
    }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergeOpenNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
        let suite = "TurtleGit.MergeOpen.Native." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        let pasteboard = NSPasteboard(name:NSPasteboard.Name("TurtleGitMergeOpen-" + UUID().uuidString))
        defer { prefs.removePersistentDomain(forName:suite); pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at:root) }
        let base = root.appendingPathComponent("base.txt"), theirs = root.appendingPathComponent("theirs.txt"), mine = root.appendingPathComponent("mine.txt")
        for (url,text) in [(base,"a\nb\nc\n"),(theirs,"a\nb\nC\n"),(mine,"a\nB\nc\n")] { try Data(text.utf8).write(to:url) }
        let dropBoard = NSPasteboard(name:NSPasteboard.Name("TurtleGitMergeOpenDrop-" + UUID().uuidString))
        defer { dropBoard.releaseGlobally() }
        let paths = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { paths.close() }
        paths.setMode(.merging)
        dropBoard.writeObjects([mine as NSURL]); try require(paths.mine.acceptDrop(from:dropBoard) && paths.mine.stringValue == mine.path)
        try require(!paths.directory.acceptDrop(from:dropBoard))
        paths.setMode(.applyUnifiedDiff)
        dropBoard.clearContents(); dropBoard.writeObjects([root as NSURL])
        try require(paths.directory.acceptDrop(from:dropBoard) && paths.directory.stringValue == root.path)
        try require(!paths.diff.acceptDrop(from:dropBoard))
        let candidates = paths.completionCandidates(for:root.path + "/mi")
        try require(candidates == [mine.path])
        try require(paths.completionCandidates(for:root.path + "/mi",directoryOnly:true).isEmpty)
        let ungranted = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { ungranted.close() }; ungranted.requiresScopes = true
        try require(ungranted.completionCandidates(for:root.path + "/mi").isEmpty)
        paths.pollClipboard(); try require(!paths.clipboard.isEnabled)
        pasteboard.setData(Data("diff --git a/a b/a\n".utf8),forType:PatchClipboard.unifiedDiff)
        paths.pollClipboard(); try require(paths.clipboard.isEnabled)
        paths.clipboard.state = .on
        pasteboard.clearContents(); paths.pollClipboard(); try require(paths.clipboard.isEnabled && !paths.diff.isEnabled)
        paths.clipboard.state = .off; paths.updateGates(); try require(!paths.clipboard.isEnabled && paths.diff.isEnabled)
        paths.close(); try require(paths.completionCandidates(for:root.path + "/mi").isEmpty)
        let parent = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed = false; defer { parent.close() }
        let watched = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { watched.close() }; watched.setMode(.applyUnifiedDiff); watched.present(parent:parent)
        parent.orderOut(nil); watched.window?.orderOut(nil)
        try require(watched.monitoringClipboard && watched.window?.sheetParent === parent)
        pasteboard.setData(Data("diff --git a/a b/a\n".utf8),forType:PatchClipboard.unifiedDiff)
        try await wait { watched.clipboard.isEnabled }
        parent.close(); try require(!watched.monitoringClipboard && watched.window?.sheetParent == nil)
        pasteboard.clearContents()
        let opener = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { opener.close() }
        try require(opener.mode == .merging && opener.base.isEnabled && !opener.diff.isEnabled && !opener.clipboard.isEnabled)
        opener.setMode(.applyUnifiedDiff)
        try require(!opener.base.isEnabled && opener.diff.isEnabled && opener.directory.isEnabled)
        let patch = Data("--- a/mine.txt\n+++ b/mine.txt\n@@ -1,3 +1,3 @@\n a\n-B\n+PATCH\n c\n".utf8)
        pasteboard.setData(patch,forType:PatchClipboard.unifiedDiff); opener.updateGates()
        try require(opener.clipboard.isEnabled)
        opener.clipboard.state = .on; opener.updateGates(); try require(!opener.diff.isEnabled && opener.directory.isEnabled)
        opener.directory.stringValue = root.path; opener.base.stringValue = "/not-used"
        var captured: MergeOpenRequest?
        opener.onAccepted = { request,_ in captured = request }; opener.accept()
        guard case .patch(nil,let target,let bytes) = captured else { throw MergeOpenCheckFailure(line:#line) }
        try require(target?.path == root.path && bytes == patch && prefs.integer(forKey:"TurtleGitMerge.OpenRadio") == 1)
        // Radio Cancel retains preference; missing paths retain the window and error.
        let invalid = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard); defer { invalid.close() }
        invalid.setMode(.merging); invalid.base.stringValue = root.appendingPathComponent("missing").path
        var acceptedInvalid = false; invalid.onAccepted = { _,_ in acceptedInvalid = true }; invalid.accept()
        try require(!acceptedInvalid && !invalid.status.stringValue.isEmpty); invalid.close()
        try require(prefs.integer(forKey:"TurtleGitMerge.OpenRadio") == 1)
        // Captured picker result expires after its owning Open window closes.
        let late = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard); defer { late.close() }
        var continuation: CheckedContinuation<URL?,Never>?
        late.choosePath = { _,_ in await withCheckedContinuation { continuation = $0 } }
        late.browse(.diff); try await wait { continuation != nil }; try require(late.busy && !late.ok.isEnabled)
        late.close(); continuation?.resume(returning:base); try await Task.sleep(nanoseconds:20_000_000)
        try require(late.diff.stringValue.isEmpty)
        // Open-created standalone three-pane model owns exact result and guarded Save.
        let working = try WorkingTextMerge(base:base,theirs:theirs,mine:mine)
        let context = GitRepository(root:root,executable:URL(fileURLWithPath:"/usr/bin/git"))
        let merge = TextConflictWindowController(repository:context,access:nil,path:mine.lastPathComponent,workingMerge:working)
        defer { merge.window?.close() }
        merge.model.comparisonDefaults = prefs; merge.model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); merge.model.load()
        try await wait { !merge.model.busy && merge.model.document != nil }
        try require(merge.model.result == "a\nB\nC\n" && merge.model.dirty)
        merge.model.save(markResolved:true); try require(!merge.model.busy) // No index resolution in standalone mode.
        merge.model.chooseStandaloneOutput = { _,_ in nil }
        merge.model.save(markResolved:false); try await wait { !merge.model.busy }
        try require(merge.model.workingMergeOutput == nil && merge.model.dirty)
        let resultFile = root.appendingPathComponent("result.txt")
        merge.model.chooseStandaloneOutput = { _,_ in resultFile }
        merge.model.save(markResolved:false); try await wait { !merge.model.busy }
        let saved = try Data(contentsOf:resultFile)
        try require(saved == Data("a\nB\nC\n".utf8) && !merge.model.dirty && merge.model.error == nil)
        let unchangedMine = try Data(contentsOf: mine)
        try require(unchangedMine == Data("a\nB\nc\n".utf8) && merge.model.workingMergeOutput == resultFile)
        try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent(".git").path))
        merge.model.chooseStandaloneOutput = { _,_ in nil }; merge.model.export()
        try await wait { !merge.model.busy }
        try require(merge.model.workingMergeOutput == resultFile)
        merge.model.chooseStandaloneOutput = { _,_ in mine }; merge.model.export()
        try await wait { !merge.model.busy }
        try require(merge.model.workingMergeOutput == mine && merge.model.error == nil)
        merge.model.result = "another result\n"; merge.model.save(markResolved:false)
        try await wait { !merge.model.busy }
        let aliasSaved = try Data(contentsOf:mine)
        try require(aliasSaved == Data("another result\n".utf8) && !merge.model.dirty && merge.model.error == nil)
        merge.window?.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
        print("Merge Open: native source radio/field/clipboard gates, captured private patch, mode Apply/Cancel, invalid path, expired picker, standalone three-pane load/save/dirty and no Git initialization passed. All owned windows closed.")
    }
}
