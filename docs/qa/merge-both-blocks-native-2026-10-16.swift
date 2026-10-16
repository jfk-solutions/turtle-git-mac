import AppKit
import TurtleGitCore

struct MergeBothBlocksVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBothBlocks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite = "TurtleGit.BothBlocks." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        MergeComparisonOptions.exact.save(to:prefs); MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let b = "head 🐢\nold\ntail\n", m = "head 🐢\nmine1\nmine2\ntail\n", t = "head 🐢\ntheirs\ntail\n"
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs"), output = root.appendingPathComponent("result")
        for (url,text) in [(base,b),(mine,m),(theirs,t)] { try Data(text.utf8).write(to:url) }
        let owner = TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs), model = owner.model
        defer { owner.close() }; owner.window!.alphaValue = 0; owner.window!.orderFront(nil); model.load()
        func views() -> [NSTextView] { ThreePaneEngineVerification.textViews(owner.window?.contentView).filter { !$0.isFieldEditor } }
        func ready() -> Bool { views().compactMap { $0 as? MergeContextMenuProviding }.allSatisfy(\.mergeSourceRowsReady) }
        func wait(_ condition:()->Bool,line:Int = #line) async throws {
            for _ in 0..<2000 { owner.window?.contentView?.layoutSubtreeIfNeeded(); if condition() && ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(description:"Both-block wait at line \(line), error=\(String(describing:model.error))")
        }
        try await wait { !model.busy && !model.preparing && model.document != nil && views().filter { $0.isEditable }.count == 1 }
        let result = views().first { $0.isEditable }!, right = views().first { !$0.isEditable && $0.string.contains("mine1") }!, left = views().first { !$0.isEditable && $0.string.contains("theirs") }!
        try await wait { result.string == model.resultDisplayText }
        func cells(_ view:NSTextView) -> [MergeSourceCell] { (view as! MergeLineNavigationProviding).navigationCells! }
        let initial = model.resultPresentation, count = model.sourceComparison!.rows.count
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        func menu(_ view:NSTextView,_ choice:MergeBlockChoice,text:String? = nil,offset:Int? = nil) throws -> NSMenuItem {
            model.clearNavigationBlockSelection(clearTextSelections:true); owner.window!.makeFirstResponder(view)
            let range = text.map { (view.string as NSString).range(of:$0) } ?? NSRange(location:offset!,length:0)
            try require(range.location != NSNotFound,"Missing menu row")
            view.setSelectedRange(range)
            let menu = (view as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board)
            guard let item = menu.item(withTitle:choice.rawValue), item.isEnabled, item.image != nil else { throw Failure(description:"Disabled both-block action " + choice.rawValue) }
            return item
        }
        func invoke(_ item:NSMenuItem) throws { try require(NSApplication.shared.sendAction(item.action!,to:item.target,from:item),"Block dispatch") }
        for choice in [MergeBlockChoice.mineThenTheirs,.theirsThenMine] {
            let stale = try menu(right,.theirs,text:"mine1")
            model.selectConflict(0); model.choose(choice)
            let expected = choice == .mineThenTheirs ? "head 🐢\nmine1\nmine2\ntheirs\ntail\n" : "head 🐢\ntheirs\nmine1\nmine2\ntail\n"
            try await wait { model.result == expected && model.blocks.isEmpty && model.sourceComparison?.rows.count == count + 2 && result.string == model.resultDisplayText }
            try require(model.alignedResultProjection != nil && !result.string.contains("<<<<<<<"),"Both-order operation fell back to serialized editor")
            try require(cells(right).filter(\.hasSourceCoordinate).map(\.text).joined() == m && cells(left).filter(\.hasSourceCoordinate).map(\.text).joined() == t,"Both-order copy changed source payload or original numbers")
            try require(cells(result).filter { $0.state == .resolvedEmpty }.count == 1 && cells(result).first { $0.state == .resolvedEmpty }?.lineNumber == nil,"Resolved empty slot became a saved/numbered line")
            try require(model.sourceComparison!.rows.contains { $0.mine.state == .yoursAdded || $0.theirs.state == .yoursAdded } && model.sourceComparison!.rows.contains { $0.mine.state == .theirsAdded || $0.theirs.state == .theirsAdded },"Source copy states missing")
            try invoke(stale); try require(model.result == expected,"Pre-expansion context command changed the new layout")
            model.chooseStandaloneOutput = { _,_ in output }; model.changeEncoding(.utf8); model.save(markResolved:false)
            try await wait { !model.busy }
            try require(model.error == nil && String(contentsOf:output) == expected,"Both-order Save added a gap or removed a copy")
            let firstText = choice == .mineThenTheirs ? "mine1" : "theirs", other:MergeBlockChoice = choice == .mineThenTheirs ? .theirs : .mine
            try invoke(menu(result,other,text:firstText))
            let partial = choice == .mineThenTheirs ? "head 🐢\nmine2\ntheirs\ntail\n" : "head 🐢\nmine1\nmine2\ntail\n"
            try await wait { model.result == partial && model.alignedResultProjection != nil }
            model.undo(); try await wait { model.result == expected && model.sourceComparison?.rows.count == count + 2 }
            model.redo(); try await wait { model.result == partial }
            model.undo(); try await wait { model.result == expected }
            model.undo(); try await wait { model.resultPresentation == initial && model.sourceComparison?.rows.count == count && result.string == model.resultDisplayText }
            try invoke(stale); try require(model.resultPresentation == initial,"Undo revived a context command from an earlier source layout revision")
        }
        // An individual source selection resolves only that conflict slot.
        try invoke(menu(right,.mine,text:"mine1"))
        try await wait { model.blocks.count == 1 && model.blocks[0].mine == "mine2\n" && model.result.contains("mine1\n<<<<<<< Mine") }
        let slot = model.alignedResultProjection!.cells.firstIndex { $0.state == .conflicted }!, offset = model.alignedResultProjection!.displayRanges[slot].location
        try invoke(menu(result,.theirs,offset:offset))
        try await wait { model.blocks.isEmpty && model.result == "head 🐢\nmine1\ntail\n" }
        try require(cells(result)[slot].state == .resolvedEmpty && cells(result)[slot].lineNumber == nil,"ConflictEmpty choice lost resolved-empty identity")
        model.undo(); try await wait { model.blocks.count == 1 }; model.undo(); try await wait { model.resultPresentation == initial }
        // Choosing a source gap cleans a row only when every pane is empty.
        let headEnd = "head 🐢".utf16.count
        result.insertText("\ninserted",replacementRange:NSRange(location:headEnd,length:0))
        try await wait { model.sourceComparison?.rows.count == count + 1 && result.string.contains("inserted") }
        let pasted = model.resultPresentation
        try invoke(menu(right,.mine,offset:headEnd + 1))
        try await wait { model.sourceComparison?.rows.count == count && model.result == initial.text && model.alignedResultProjection != nil }
        model.undo(); try await wait { model.resultPresentation == pasted && model.sourceComparison?.rows.count == count + 1 }
        model.undo(); try await wait { model.resultPresentation == initial && model.sourceComparison?.rows.count == count }
        try require(try String(contentsOf:base,encoding:.utf8) == b && String(contentsOf:mine,encoding:.utf8) == m && String(contentsOf:theirs,encoding:.utf8) == t,"Block layouts rewrote an input file")
        owner.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
        print("PASS: both-order footer and native result alternatives, exact all-pane source gaps/states/numbers, retained alignment, UTF-8 Save, partial source resolution, resolved-empty identity, all-pane empty cleanup, source-layout command ownership and complete Undo/Redo; owned window closed")
    }
}
