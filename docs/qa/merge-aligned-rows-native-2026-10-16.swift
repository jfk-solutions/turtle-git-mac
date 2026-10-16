import AppKit
import TurtleGitCore

struct MergeAlignedRowsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitAlignedRows-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite = "TurtleGit.AlignedRows." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        MergeComparisonOptions.exact.save(to:prefs); MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        prefs.set(false,forKey:"TurtleGitMerge.WrapLines")
        let prefix = (0..<60).map { "header \($0)\n" }.joined(), suffix = (0..<60).map { "tail \($0)\n" }.joined()
        let b = prefix + "old one\nold two\n" + suffix, m = prefix + "mine one\nmine two\n" + suffix, t = prefix + "theirs 🐢\ntheirs two\n" + suffix
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs")
        try Data(b.utf8).write(to:base); try Data(m.utf8).write(to:mine); try Data(t.utf8).write(to:theirs)
        let owner = TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs), model = owner.model
        defer { owner.close() }; owner.window!.alphaValue = 0; owner.window!.orderFront(nil); model.load()
        func wait(_ ready: () -> Bool, line: Int = #line) async throws {
            for _ in 0..<2000 { owner.window?.contentView?.layoutSubtreeIfNeeded(); if ready() && ThreePaneEngineVerification.textViews(owner.window?.contentView).compactMap { $0 as? MergeContextMenuProviding }.allSatisfy(\.mergeSourceRowsReady) { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(description:"Aligned rows wait at line \(line), error=\(String(describing:model.error))")
        }
        try await wait { !model.busy && !model.preparing && model.document != nil && ThreePaneEngineVerification.textViews(owner.window?.contentView).contains { $0.isEditable } }
        let views = ThreePaneEngineVerification.textViews(owner.window?.contentView), result = views.first { $0.isEditable }!, right = views.first { !$0.isEditable && $0.string.contains("mine one") }!
        try await wait { result.string == model.resultDisplayText }
        let initial = model.resultPresentation, count = model.sourceComparison!.rows.count
        try require(model.alignedResultProjection?.cells.count == count && model.locatorMap.lineCount == count && model.locatorMap.columns.allSatisfy { $0.first?.rows.lowerBound == 0 && $0.last?.rows.upperBound == count },"Locator columns use serialized marker line counts")
        try require(model.alignedResultStates.filter { $0 == .conflicted }.count == 2 && model.alignedResultStates.filter(\.isRemoval).count == 2,"Logical conflict/removal result counts differ")
        let sourceRow = model.sourceComparison!.rows.firstIndex { $0.mine.displayText == "mine one" }!, block = model.blocks[0]
        try require(model.alignedResultProjection!.sourceRows(intersecting:block.range) == [sourceRow,sourceRow + 1],"Serialized markers mapped to Base removals")
        let scroll = result.enclosingScrollView!, lines = MergeLineEndings.lineRanges(in:result.string), rawRow = sourceRow
        let layout = result.layoutManager!, container = result.textContainer!; layout.ensureLayout(for:container)
        let glyphs = layout.glyphRange(forCharacterRange:lines[rawRow],actualCharacterRange:nil), rect = layout.boundingRect(forGlyphRange:glyphs,in:container)
        let expectedY = max(0,rect.minY + result.textContainerOrigin.y - scroll.contentView.bounds.height / 2)
        model.scrollLocator(to:sourceRow)
        try require(abs(scroll.contentView.bounds.minY - expectedY) < 3,"Locator did not scroll to its aligned result row")
        model.selectConflict(0); model.choose(.mine)
        try await wait { model.blocks.isEmpty && model.result == m && result.string == model.resultDisplayText && model.canUndo }
        try require(model.resultPresentation.navigationMap.exactResultRange(sourceRows:sourceRow..<(sourceRow + 1)) != nil && model.resultPresentation.navigationMap.exactResultRange(sourceRows:(sourceRow + 1)..<(sourceRow + 2)) != nil,"Resolved group lost individual row mappings")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        func choose(_ choice: MergeBlockChoice, text: String, view: NSTextView) throws {
            model.clearNavigationBlockSelection(clearTextSelections:true); owner.window!.makeFirstResponder(view)
            let range = (view.string as NSString).range(of:text); try require(range.location != NSNotFound,"Missing choice text " + text)
            view.setSelectedRange(range)
            let menu = (view as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board)
            guard let item = menu.item(withTitle:choice.rawValue), item.isEnabled, item.image != nil else { throw Failure(description:"Partial-row choice disabled") }
            try require(NSApplication.shared.sendAction(item.action!,to:item.target,from:item),"Native partial-row dispatch")
        }
        try choose(.theirs,text:"mine one",view:right)
        let partial = prefix + "theirs 🐢\nmine two\n" + suffix
        try await wait { model.result == partial && result.string == model.resultDisplayText }
        try require(model.alignedResultProjection?.cells[sourceRow].displayText == "theirs 🐢" && model.alignedResultProjection?.cells[sourceRow + 1].displayText == "mine two","Partial source choice replaced its neighbor")
        model.undo(); try await wait { model.result == m && result.string == model.resultDisplayText }
        model.redo(); try await wait { model.result == partial && result.string == model.resultDisplayText }
        try choose(.theirs,text:"mine two",view:result)
        try await wait { model.result == t && result.string == model.resultDisplayText }
        try require(model.alignedResultProjection?.cells.count == count && model.alignedResultStates.filter { $0 == .resolved }.count == 2,"Result partial choice lost aligned metadata/colors")
        model.undo(); try await wait { model.result == partial }; model.undo(); try await wait { model.result == m }; model.undo(); try await wait { model.resultPresentation == initial }
        try require(model.alignedResultStates.filter { $0 == .conflicted }.count == 2 && model.locatorMap.columns[1].last?.rows.upperBound == count,"Undo lost original aligned conflict rows")
        try await wait { result.string == model.resultDisplayText }
        try require(!result.string.contains("<<<<<<<") && result.string.contains("old one\nold two"),"Result did not render blank conflict slots and removed Base records")
        owner.window!.makeFirstResponder(result)
        result.setSelectedRange(NSRange(location:model.alignedResultProjection!.displayRanges[sourceRow + 1].location,length:0))
        try await wait { model.resultLineNumber == 62 }
        let conflictOffset = model.alignedResultProjection!.displayRanges[sourceRow].location
        result.insertText("manual 🐢",replacementRange:NSRange(location:conflictOffset,length:0))
        try await wait { model.result.contains("manual 🐢\n<<<<<<< Mine") && result.string == model.resultDisplayText }
        try require(model.blocks.count == 1 && model.blocks[0].mine == "mine two\n" && model.blocks[0].theirs == "theirs two\n","Typing resolved or overwrote the neighboring conflict slot")
        try require(model.alignedResultStates[sourceRow] == .edited && model.alignedResultStates[sourceRow + 1] == .conflicted,"Typing lost per-slot conflict states")
        let output = root.appendingPathComponent("merged.txt")
        model.chooseStandaloneOutput = { _,_ in output }; model.confirmUnresolvedSave = { _ in true }
        let previousEncoding = model.encoding
        model.changeEncoding(.utf8)
        let saved = model.result
        model.save(markResolved:false); try await wait { !model.busy }
        try require(model.error == nil && String(contentsOf:output) == saved && !String(contentsOf:output).contains("old one"),"Save serialized removed records or lost remaining markers")
        if previousEncoding != .utf8 {
            model.undo(); try await wait { model.encoding == previousEncoding && model.result == saved }
        }
        model.undo(); try await wait { model.resultPresentation == initial && result.string == model.resultDisplayText }
        result.insertText("🐢\nnew line\n",replacementRange:NSRange(location:0,length:0))
        try await wait { model.sourceComparison?.rows.count == count + 2 && result.string == model.resultDisplayText && right.string.hasPrefix("header 0\n\n\nheader 1") }
        try require(model.sourceComparison!.rows[1..<3].allSatisfy { $0.mine.state == .empty && $0.theirs.state == .empty },"Multiline result insertion did not align source gaps")
        try require(model.alignedResultProjection?.cells.count == count + 2 && model.result.hasPrefix("🐢\nnew line\nheader 0"),"Pasted display newlines became extra serialized data")
        let pasted = model.resultPresentation
        model.undo(); try await wait { model.resultPresentation == initial && model.sourceComparison?.rows.count == count }
        model.redo(); try await wait { model.resultPresentation == pasted && model.sourceComparison?.rows.count == count + 2 }
        model.undo(); try await wait { model.resultPresentation == initial && result.string == model.resultDisplayText }
        let removed = (result.string as NSString).range(of:"old one")
        result.insertText("!",replacementRange:NSRange(location:NSMaxRange(removed),length:0))
        try await wait { model.result.contains("old one!\n<<<<<<< Mine") && result.string == model.resultDisplayText }
        try require(model.alignedResultProjection?.cells[sourceRow - 2].state == .edited,"Typing removed row did not make it writable")
        model.undo(); try await wait { model.resultPresentation == initial }
        try await wait { result.string == model.resultDisplayText }
        let matches = ["header 0","header 1"].map { (result.string as NSString).range(of:$0) }
        try require((result as! MergeFindProviding).replaceFindMatches(matches,with:"line 🐢\r\nline"),"Find replacement refused aligned records")
        try await wait { model.sourceComparison?.rows.count == count + 2 && result.string == model.resultDisplayText }
        try require(model.result.hasPrefix("line 🐢\nline\nline 🐢\nline\nheader 2"),"Find replacement serialized display gaps or wrong endings")
        let caret = result.selectedRange().location
        try require(caret >= 4 && (result.string as NSString).substring(with:NSRange(location:caret - 4,length:4)) == "line","Find caret used CRLF bytes instead of aligned display delta")
        model.undo(); try await wait { model.resultPresentation == initial && model.sourceComparison?.rows.count == count && result.string == model.resultDisplayText }
        try require(try String(contentsOf:base,encoding:.utf8) == b && String(contentsOf:mine,encoding:.utf8) == m && String(contentsOf:theirs,encoding:.utf8) == t,"Aligned row operations rewrote source files")
        owner.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
        print("PASS: initial aligned result records/counts/locator coordinates, marker-to-source mapping, footer single-side resolution, later native source/result one-row alternatives without neighbor replacement, aligned result rendering, conflict-slot/removed-row typing, multiline source gaps, exact Save and all-pane Undo/Redo metadata and unchanged inputs; owned window closed")
    }
}
