import AppKit
import TurtleGitCore

struct MergeInPlaceVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitInPlace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite = "TurtleGit.InPlace." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine")
        let before = "head\r\nold1\r\nold2\r\ntail", after = "head\r\nnew1\r\nnew2\r\ntail"
        let originalBase = try ComparisonTextEncoding.utf16LEBOM.encode(before), originalMine = try ComparisonTextEncoding.utf8BOM.encode(after)
        try originalBase.write(to:base); try originalMine.write(to:mine)
        let owner = FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs), model = owner.model
        defer { owner.close() }; owner.window!.alphaValue = 0; owner.window!.orderFront(nil); model.load()
        try await TwoPaneEngineVerification.settled(model)
        let views = TwoPaneEngineVerification.editors(owner.window?.contentView), right = views.first { $0.string.contains("new1") }!, left = views.first { $0.string.contains("old1") }!
        model.activatePane(base:false); model.editingEnabled = true
        try await TwoPaneEngineVerification.wait { right.isEditable }
        let peer = left.string, rows = model.alignment!.rows.count
        let requests = MergeRegexOperations.activeRequests
        right.insertText("new1",replacementRange:(right.string as NSString).range(of:"new1"))
        try await TwoPaneEngineVerification.settled(model)
        try require(model.dirty && model.displayCells(base:false).contains { $0.displayText == "new1" && $0.state == .edited },"Same-byte typing lost Edited/modified state")
        model.undo(); try await TwoPaneEngineVerification.settled(model)
        try require(!model.dirty,"Undo did not restore same-byte edit savepoint")
        right.insertText("🐢\nx",replacementRange:(right.string as NSString).range(of:"new1"))
        try require(!model.filtering && MergeRegexOperations.activeRequests == requests,"Typing started a diff helper")
        try await TwoPaneEngineVerification.settled(model)
        let changed = "head\r\n🐢\r\nx\r\nnew2\r\ntail"
        try require(model.draftText(base:false) == changed && model.alignment!.rows.count == rows + 1 && model.alignment!.rows.filter { $0.base.state == .empty }.count == 1,"In-place insertion/alignment")
        try require(left.string.replacingOccurrences(of:"\n\n",with:"\n") == peer && model.alignment!.rows.map { $0.base.text }.joined() == before,"Opposite payload changed")
        let snapshot = model.displayCells(base:false).map { ($0.text,$0.state) }
        model.undo(); try await TwoPaneEngineVerification.settled(model)
        try require(!model.filtering && model.draftText(base:false) == after && model.alignment!.rows.count == rows,"Undo did not restore original rows")
        model.redo(); try await TwoPaneEngineVerification.settled(model)
        try require(model.displayCells(base:false).map(\.text) == snapshot.map { $0.0 } && model.displayCells(base:false).map(\.state) == snapshot.map { $0.1 },"Redo lost Edited states or rows")
        model.undo(); try await TwoPaneEngineVerification.settled(model)
        model.switchPaneMode(true); try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(owner.window?.contentView).count == 1 }
        let combined = TwoPaneEngineVerification.editors(owner.window?.contentView)[0]
        model.editingEnabled = true; try await TwoPaneEngineVerification.wait { combined.isEditable }
        let display = combined.string
        combined.insertText("EDIT",replacementRange:(combined.string as NSString).range(of:"old1"))
        try await TwoPaneEngineVerification.settled(model)
        let expected = "head\r\nEDIT\r\nnew1\r\nnew2\r\ntail"
        try require(!model.filtering && model.draftText(base:false) == expected && combined.string == display.replacingOccurrences(of:"old1",with:"EDIT"),"Edited removal regrouped or untouched removal lost")
        try require(model.combined!.cells.first { $0.displayText == "EDIT" }?.state == .edited && model.combined!.cells.first { $0.displayText == "old2" }?.state == .removed,"Combined Edited/Removed states")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("PASTE",forType:.string); combined.setSelectedRange((combined.string as NSString).range(of:"EDIT"))
        let menu = (combined as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board)
        let paste = menu.item(withTitle:"Paste")!; _ = NSApplication.shared.sendAction(paste.action!,to:paste.target,from:paste)
        try await TwoPaneEngineVerification.settled(model)
        try require(combined.string.contains("PASTE\nold2\nnew1") && !model.filtering,"Paste regrouped retained display rows")
        model.undo(); try await TwoPaneEngineVerification.settled(model); try require(model.draftText(base:false) == expected,"Paste Undo")
        model.undo(); try await TwoPaneEngineVerification.settled(model); try require(combined.string == display && model.draftText(base:false) == after,"Removal Undo did not restore exact source display")
        model.redo(); try await TwoPaneEngineVerification.settled(model)
        model.save(); try await TwoPaneEngineVerification.wait { !model.busy && !model.filtering && !model.dirty }
        try require(model.combined!.cells.contains { $0.displayText == "old2" && $0.state == .removed } && model.combined!.cells.contains { $0.displayText == "EDIT" && $0.state == .edited },"Save regenerated the retained view records")
        try require(try Data(contentsOf:mine) == ComparisonTextEncoding.utf8BOM.encode(expected) && Data(contentsOf:base) == originalBase,"In-place Save changed BOM/endings/Base")
        owner.close(); try await TwoPaneEngineVerification.wait { MergeRegexOperations.activeRequests == 0 }
        print("PASS: in-place native two-pane/combined typing and Paste, opposite gaps and bytes, retained Edited/Removed rows, exact Undo/Redo display, no typing diff helper, Save BOM/CRLF and owned cleanup")
    }
}
