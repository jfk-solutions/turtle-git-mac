import AppKit
import TurtleGitCore

struct MergeSourceBlocksVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSourceBlocks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite = "TurtleGit.SourceBlocks." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        MergeComparisonOptions.exact.save(to:prefs)
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs")
        let original = "head 🐢\nold1\nold2\ntail\n", modified = "head 🐢\nnew1\nnew2\ntail\n"
        try Data(original.utf8).write(to:base); try Data(modified.utf8).write(to:mine); try Data(original.utf8).write(to:theirs)
        let owner = TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs), model = owner.model
        defer { owner.close() }; model.chooseReload = { .discard }; owner.window!.alphaValue = 0; owner.window!.orderFront(nil); model.load()
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<2000 { owner.window?.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(description:"Timed out waiting for source block operation")
        }
        try await wait { !model.busy && !model.preparing && model.document != nil && ThreePaneEngineVerification.textViews(owner.window?.contentView).filter { !$0.isFieldEditor }.count >= 3 }
        let views = ThreePaneEngineVerification.textViews(owner.window?.contentView), result = views.first { $0.isEditable }!, right = views.first { !$0.isEditable && $0.string.contains("new1") }!, left = views.first { !$0.isEditable && !$0.string.contains("new1") }!
        try await wait { result.string == model.result && right.string.contains("new1") }
        try require(model.error == nil && model.blocks.isEmpty && model.result == modified,"Nonconflicting merge load")
        let initial = model.resultPresentation
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        func select(_ text: String, in view: NSTextView) throws {
            let range = (view.string as NSString).range(of:text)
            try require(range.location != NSNotFound,"Missing native source text " + text)
            (view as? MergeLineNavigationProviding)?.beginUserNavigation()
            model.clearNavigationBlockSelection(clearTextSelections:true)
            owner.window!.makeFirstResponder(view); view.setSelectedRange(range)
        }
        func entry(_ choice: MergeBlockChoice, in view: NSTextView) throws -> NSMenuItem {
            let menu = (view as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board)
            guard let item = menu.item(withTitle:choice.rawValue), item.isEnabled, item.image != nil else { throw Failure(description:"Missing enabled source choice " + choice.rawValue) }; return item
        }
        func invoke(_ item: NSMenuItem) throws { try require(NSApplication.shared.sendAction(item.action!,to:item.target,from:item),"Native block dispatch") }
        func undoInitial() async throws { model.undo(); try await wait { model.resultPresentation == initial && result.string == initial.text } }
        // Selecting one addition must leave its adjacent addition intact.
        for choice in MergeBlockChoice.allCases {
            try select("new1",in:right); let item = try entry(choice,in:right)
            try select("tail",in:right); try invoke(item)
            let expected = choice == .theirs ? "head 🐢\nnew2\ntail\n" : modified
            try await wait { model.result == expected && model.canUndo }
            try require(model.result.contains("new2\n") && model.dirty,"Neighbor addition overwritten or explicit choice lost modified state")
            try await undoInitial()
        }
        // The normal side of a removed Base row inserts at its zero-byte anchor.
        try select("old1",in:left); try invoke(entry(.theirs,in:left))
        try await wait { model.result == "head 🐢\nold1\nnew1\nnew2\ntail\n" }
        try require(model.resultPresentation.navigationMap.exactResultRange(sourceRows:0..<model.sourceComparison!.rows.count) != nil,"Insertion lost adjacent mappings")
        try await undoInitial()
        // Both ordering commands are available for ordinary common rows too.
        for choice in [MergeBlockChoice.mineThenTheirs,.theirsThenMine] {
            try select("head 🐢",in:right); try invoke(entry(choice,in:right))
            try await wait { model.result == "head 🐢\n" + modified }
            try await undoInitial()
        }
        // Result context commands resolve through exact source mappings as well.
        try select("new1",in:result); try invoke(entry(.theirs,in:result))
        try await wait { model.result == "head 🐢\nnew2\ntail\n" }
        try select("new1",in:right); try invoke(entry(.mine,in:right))
        try await wait { model.result == modified }
        model.undo(); try await wait { model.result == "head 🐢\nnew2\ntail\n" }; try await undoInitial()
        model.redo(); try await wait { model.result == "head 🐢\nnew2\ntail\n" }; try await undoInitial()
        // Captured choices cannot overwrite a later edit or run during a sheet.
        try select("new1",in:right); let stale = try entry(.theirs,in:right)
        result.insertText("typed ",replacementRange:NSRange(location:0,length:0))
        try await wait { model.result.hasPrefix("typed ") }; let edited = model.result; try invoke(stale); try require(model.result == edited,"Stale menu overwrote typing")
        try await undoInitial()
        try select("new1",in:right); let blocked = try entry(.theirs,in:right)
        model.confirmingQuit = true; try invoke(blocked); try require(model.resultPresentation == initial,"Quit gate failed"); model.confirmingQuit = false
        let rows = model.sourceComparison!.rows.firstIndex { $0.mine.displayText == "new1" }!
        let command = model.sourceBlockCommand(rows:rows..<(rows + 1),choice:.theirs)!
        model.load(); try await wait { !model.busy && !model.preparing }; model.performSourceBlock(command)
        try require(model.result == modified,"Reload revived a stale source command")
        owner.close(); model.performSourceBlock(command); try require(model.result == modified,"Closed source owner changed result")
        try require(try String(contentsOf:base,encoding:.utf8) == original && String(contentsOf:mine,encoding:.utf8) == modified && String(contentsOf:theirs,encoding:.utf8) == original,"Source block commands rewrote input files")
        print("PASS: ordinary/changed source and result block menus, captured selection, all four choices, exact removed-row insertion, neighboring rows, repeated alternatives, Undo/Redo mapping, stale edits/reload/Quit/closed gates and unchanged inputs; owned window closed")
    }
}
