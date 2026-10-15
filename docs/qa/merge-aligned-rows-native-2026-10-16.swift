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
            for _ in 0..<2000 { owner.window?.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(description:"Aligned rows wait at line \(line), error=\(String(describing:model.error))")
        }
        try await wait { !model.busy && !model.preparing && model.document != nil && ThreePaneEngineVerification.textViews(owner.window?.contentView).contains { $0.isEditable } }
        let views = ThreePaneEngineVerification.textViews(owner.window?.contentView), result = views.first { $0.isEditable }!, right = views.first { !$0.isEditable && $0.string.contains("mine one") }!
        try await wait { result.string == model.result }
        let initial = model.resultPresentation, count = model.sourceComparison!.rows.count
        try require(model.alignedResultProjection?.cells.count == count && model.locatorMap.lineCount == count && model.locatorMap.columns.allSatisfy { $0.first?.rows.lowerBound == 0 && $0.last?.rows.upperBound == count },"Locator columns use serialized marker line counts")
        try require(model.alignedResultStates.filter { $0 == .conflicted }.count == 2 && model.alignedResultStates.filter(\.isRemoval).count == 2,"Logical conflict/removal result counts differ")
        let sourceRow = model.sourceComparison!.rows.firstIndex { $0.mine.displayText == "mine one" }!, block = model.blocks[0]
        try require(model.alignedResultProjection!.sourceRows(intersecting:block.range) == [sourceRow,sourceRow + 1],"Serialized markers mapped to Base removals")
        let scroll = result.enclosingScrollView!, lines = MergeLineEndings.lineRanges(in:model.result), rawRow = MergeLineEndings.lineNumber(in:model.result,utf16Offset:block.range.location) - 1
        let layout = result.layoutManager!, container = result.textContainer!; layout.ensureLayout(for:container)
        let glyphs = layout.glyphRange(forCharacterRange:lines[rawRow],actualCharacterRange:nil), rect = layout.boundingRect(forGlyphRange:glyphs,in:container)
        let expectedY = max(0,rect.minY + result.textContainerOrigin.y - scroll.contentView.bounds.height / 2)
        model.scrollLocator(to:sourceRow)
        try require(abs(scroll.contentView.bounds.minY - expectedY) < 3,"Locator used aligned row as raw marker-line offset")
        model.selectConflict(0); model.choose(.mine)
        try await wait { model.blocks.isEmpty && model.result == m && result.string == m && model.canUndo }
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
        try await wait { model.result == partial && result.string == partial }
        try require(model.alignedResultProjection?.cells[sourceRow].displayText == "theirs 🐢" && model.alignedResultProjection?.cells[sourceRow + 1].displayText == "mine two","Partial source choice replaced its neighbor")
        model.undo(); try await wait { model.result == m && result.string == m }
        model.redo(); try await wait { model.result == partial && result.string == partial }
        try choose(.theirs,text:"mine two",view:result)
        try await wait { model.result == t && result.string == t }
        try require(model.alignedResultProjection?.cells.count == count && model.alignedResultStates.filter { $0 == .resolved }.count == 2,"Result partial choice lost aligned metadata/colors")
        model.undo(); try await wait { model.result == partial }; model.undo(); try await wait { model.result == m }; model.undo(); try await wait { model.resultPresentation == initial }
        try require(model.alignedResultStates.filter { $0 == .conflicted }.count == 2 && model.locatorMap.columns[1].last?.rows.upperBound == count,"Undo lost original aligned conflict rows")
        try require(try String(contentsOf:base,encoding:.utf8) == b && String(contentsOf:mine,encoding:.utf8) == m && String(contentsOf:theirs,encoding:.utf8) == t,"Aligned row operations rewrote source files")
        owner.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
        print("PASS: initial aligned result records/counts/locator coordinates, marker-to-source mapping, footer single-side resolution, later native source/result one-row alternatives without neighbor replacement, Undo/Redo metadata and unchanged files; owned window closed")
    }
}
