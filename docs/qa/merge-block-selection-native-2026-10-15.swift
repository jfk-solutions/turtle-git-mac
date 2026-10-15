import AppKit
import TurtleGitCore

struct MergeBlockSelectionVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func invoke(_ title:String,menu:NSMenu) throws {
        guard let item=menu.items.first(where:{$0.title == title}),item.isEnabled,let action=item.action else {throw Failure(description:"Unavailable private clipboard command: "+title)}
        _=(item.target as? NSObject)?.perform(action,with:item)
    }
    @MainActor static func verify() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBlockSelection-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.BlockSelection."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        MergeComparisonOptions.exact.save(to:prefs)
        let base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt"),theirs=root.appendingPathComponent("theirs.txt")
        let before="head\nold one\nold two\ntail\n",after="head\nnew one\nnew two\ntail\n"
        try Data(before.utf8).write(to:base);try Data(before.utf8).write(to:theirs);try Data(after.utf8).write(to:mine)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs),model=owner.model
        defer{owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait{TwoPaneEngineVerification.editors(owner.window?.contentView).count == 2}
        let views=TwoPaneEngineVerification.editors(owner.window?.contentView),right=views.first{$0.string.contains("new one")}!,left=views.first{$0.string.contains("old one")}!
        owner.window!.makeFirstResponder(right);right.setSelectedRange(NSRange(location:0,length:0));await Task.yield();model.navigate(1)
        let selected=right as! MergeBlockSelecting
        try require(right.selectedRange() == NSRange(location:5,length:0) && selected.mergeSelectedBlockRange == NSRange(location:5,length:15),"Caret and block were not independent")
        try require((left as! MergeBlockSelecting).mergeSelectedBlockRange == NSRange(location:5,length:15) && model.transferRows == 1..<3,"Peer block/transfer selection lost")
        for name in [NSAppearance.Name.aqua,.darkAqua] {
            owner.window!.appearance=NSAppearance(named:name);right.displayIfNeeded()
            try require(selected.mergeBlockBoundaryRects.count == 2 && selected.mergeBlockBoundaryRects.allSatisfy{$0.width > 30 && $0.height == 2},"Source boundary highlight missing")
        }
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        try invoke("Copy",menu:(right as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board))
        try require(board.string(forType:.string) == "new one\nnew two","Block Copy used only caret or wrong rows")
        model.editingEnabled=true;try await TwoPaneEngineVerification.wait{right.isEditable}
        try invoke("Cut",menu:(right as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board))
        try require(model.draftText(base:false) == after && !model.dirty && !model.canUndo && board.string(forType:.string) == "new one\nnew two","Block-only Cut deleted text or created Undo")
        board.clearContents();board.setString("INSERT ",forType:.string)
        try invoke("Paste",menu:(right as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board))
        try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false) == "head\nINSERT new one\nnew two\ntail\n","Block-only Paste replaced the highlighted lines")
        try await TwoPaneEngineVerification.wait{views.allSatisfy{($0 as! MergeBlockSelecting).mergeSelectedBlockRange == nil}}
        model.undo();try await TwoPaneEngineVerification.settled(model);try require(model.draftText(base:false) == after,"Compare paste Undo")
        let merge=TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine.txt",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs),three=merge.model
        defer{merge.close()};merge.window!.alphaValue=0;merge.window!.orderFront(nil);three.load()
        try await ThreePaneEngineVerification.wait{!three.busy && three.document != nil && !three.resultFolding.projection.rows.isEmpty && ThreePaneEngineVerification.textViews(merge.window?.contentView).contains{$0.isEditable}}
        let result=ThreePaneEngineVerification.textViews(merge.window?.contentView).first{$0.isEditable}!
        try await ThreePaneEngineVerification.wait{result.string == after}
        merge.window!.makeFirstResponder(result);result.setSelectedRange(NSRange(location:0,length:0));await Task.yield();three.navigateBlock(1,conflictsOnly:false)
        let resultBlock=result as! MergeBlockSelecting,block=try resultBlock.mergeSelectedBlockRange.unwrap("Missing result block")
        try require(result.selectedRange() == NSRange(location:5,length:0) && (result.string as NSString).substring(with:block) == "new one\nnew two","Result caret and block")
        try invoke("Cut",menu:(result as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board))
        try require(three.result == after && !three.canUndo && board.string(forType:.string) == "new one\nnew two","Result block-only Cut changed text")
        board.clearContents();board.setString("INSERT ",forType:.string)
        try invoke("Paste",menu:(result as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board))
        try await ThreePaneEngineVerification.wait{three.result == "head\nINSERT new one\nnew two\ntail\n" && three.canUndo}
        three.undo();try await ThreePaneEngineVerification.wait{three.result == after}
        try require(resultBlock.mergeSelectedBlockRange == nil && result.selectedRange() == NSRange(location:5,length:0),"Result Undo retained a block or lost target caret")
        three.redo();try await ThreePaneEngineVerification.wait{three.result.contains("INSERT new one")};try require(resultBlock.mergeSelectedBlockRange == nil,"Result Redo retained stale block")
        try require(try String(contentsOf:base,encoding:.utf8) == before && String(contentsOf:mine,encoding:.utf8) == after && String(contentsOf:theirs,encoding:.utf8) == before,"Private block operations rewrote inputs")
        print("PASS: independent block boundaries/carets in both appearances, exact peer/transfer blocks, native Copy, block-only Cut no-op and Paste insertion, source Undo/Redo caret restoration and all-pane highlight clearing; owned windows closed")
    }
}
private extension Optional {
    func unwrap(_ message:String) throws -> Wrapped {guard let value=self else {throw MergeBlockSelectionVerification.Failure(description:message)};return value}
}
