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
        defer{NativeOwnedWindowCleanup.close([owner.window!],returnCode:.abort)};owner.window!.alphaValue=0;owner.window!.setFrameOrigin(.init(x:-24000,y:-24000));owner.window!.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
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
        defer{NativeOwnedWindowCleanup.close([merge.window!],returnCode:.abort)};ThreePaneEngineVerification.mount(merge);three.load()
        func currentResult()->NSTextView? {
            guard three.nativeEditorReady,three.sourceMutationsAllowed else{return nil}
            return ThreePaneEngineVerification.textViews(merge.window?.contentView).first {
                $0.window === merge.window && !$0.isHiddenOrHasHiddenAncestor && $0.enclosingScrollView?.documentView === $0 &&
                    ($0 as? MergeContextMenuProviding)?.mergeSourceRowsReady == true && ($0 as? MergeResultHistoryProviding)?.historyAllowed == true
            }
        }
        func diagnostic()->String {
            ThreePaneEngineVerification.snapshot(merge)+"; serialized="+String(reflecting:three.result)+"; display="+String(reflecting:three.resultDisplayText)+"; current="+String(reflecting:currentResult()?.string)
        }
        try await ThreePaneEngineVerification.wait(phase:"current block-selection result",diagnostic:diagnostic){
            merge.window?.contentView?.layoutSubtreeIfNeeded()
            return !three.busy && three.document != nil && !three.resultFolding.projection.rows.isEmpty && currentResult() != nil
        }
        // Aligned native rows include view-only cells. Verify the unchanged
        // serialized file oracle separately from its exact native presentation.
        try require(three.result == after,"Initial block-selection file text differs: "+diagnostic())
        try await ThreePaneEngineVerification.wait(phase:"block-selection native presentation",diagnostic:diagnostic){currentResult()?.string == three.resultDisplayText}
        guard let result=currentResult() else {throw Failure(description:"Current block-selection result disappeared: "+diagnostic())}
        merge.window!.makeFirstResponder(result);result.setSelectedRange(NSRange(location:0,length:0));await Task.yield();three.navigateBlock(1,conflictsOnly:false)
        let resultBlock=result as! MergeBlockSelecting
        let removed=try resultBlock.mergeSelectedBlockRange.unwrap("Missing removed result display block: "+diagnostic())
        try require(result.selectedRange() == NSRange(location:5,length:0) && (result.string as NSString).substring(with:removed) == "old one\nold two","Removed result display block: "+diagnostic())
        try require(three.result == after,"Navigating removed display rows changed serialized result")
        // Native aligned results retain the removed Base rows before the added
        // Mine rows. Next Difference must visit each state block separately.
        three.navigateBlock(1,conflictsOnly:false)
        let block=try resultBlock.mergeSelectedBlockRange.unwrap("Missing added result block: "+diagnostic())
        let addedCaret=NSRange(location:21,length:0)
        try require(result.selectedRange() == addedCaret && three.caret == NSRange(location:5,length:0) && (result.string as NSString).substring(with:block) == "new one\nnew two","Added result display/serialized caret and block: "+diagnostic())
        try invoke("Cut",menu:(result as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board))
        try require(three.result == after && !three.canUndo && board.string(forType:.string) == "new one\nnew two","Result block-only Cut changed text")
        board.clearContents();board.setString("INSERT ",forType:.string)
        try invoke("Paste",menu:(result as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board))
        try await ThreePaneEngineVerification.wait(phase:"block Paste serialized result",diagnostic:diagnostic){three.result == "head\nINSERT new one\nnew two\ntail\n" && three.canUndo}
        three.undo();try await ThreePaneEngineVerification.wait(phase:"block Paste Undo presentation",diagnostic:diagnostic){three.result == after && currentResult()?.string == three.resultDisplayText && result.selectedRange() == addedCaret}
        try require(resultBlock.mergeSelectedBlockRange == nil && three.caret == NSRange(location:5,length:0),"Result Undo retained a block or lost serialized target caret: "+diagnostic())
        three.redo();try await ThreePaneEngineVerification.wait(phase:"block Paste Redo",diagnostic:diagnostic){three.result.contains("INSERT new one")};try require(resultBlock.mergeSelectedBlockRange == nil,"Result Redo retained stale block")
        try require(try String(contentsOf:base,encoding:.utf8) == before && String(contentsOf:mine,encoding:.utf8) == after && String(contentsOf:theirs,encoding:.utf8) == before,"Private block operations rewrote inputs")
        print("PASS: independent block boundaries/carets in both appearances, exact peer/transfer blocks, native Copy, block-only Cut no-op and Paste insertion, source Undo/Redo caret restoration and all-pane highlight clearing; owned windows closed")
    }
}
private extension Optional {
    func unwrap(_ message:String) throws -> Wrapped {guard let value=self else {throw MergeBlockSelectionVerification.Failure(description:message)};return value}
}
