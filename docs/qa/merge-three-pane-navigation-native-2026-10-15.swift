import AppKit
import TurtleGitCore

struct MergeThreePaneNavigationVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ condition:Bool,_ message:String) throws {if !condition {throw Failure(description:message)}}
    @MainActor static func verify() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitThreePaneNavigation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.ThreePaneNavigation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        MergeComparisonOptions.exact.save(to:prefs)
        let base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt"),theirs=root.appendingPathComponent("theirs.txt")
        let original="head 🦎\nbase1\nsepA\nbase2\nsepB\nbase3\ntail\n"
        let my="head 🦎\nmine1a\nmine1b\nsepA\nmine2\nsepB\nbase3\ntail\n",their="head 🦎\ntheirs1\nsepA\ntheirs2\nsepB\ntheirs3\ntail\n"
        try Data(original.utf8).write(to:base);try Data(my.utf8).write(to:mine);try Data(their.utf8).write(to:theirs)
        let owner=TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine.txt",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs),model=owner.model
        defer{owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.load()
        try await ThreePaneEngineVerification.wait{!model.busy && !model.preparing && model.document != nil}
        try require(model.error == nil && model.blocks.count == 2,"Engine load or conflict groups")
        try await ThreePaneEngineVerification.wait{ThreePaneEngineVerification.textViews(owner.window?.contentView).filter{!$0.isFieldEditor}.count >= 3}
        let views=ThreePaneEngineVerification.textViews(owner.window?.contentView)
        let result=views.first{$0.isEditable}!,left=views.first{!$0.isEditable && $0.string.contains("theirs1")}!,right=views.first{!$0.isEditable && $0.string.contains("mine1a")}!
        try await ThreePaneEngineVerification.wait{result.string == model.result && !model.folding.projection.rows.isEmpty && !model.resultFolding.projection.rows.isEmpty}
        owner.window!.makeFirstResponder(right);right.setSelectedRange(NSRange(location:0,length:0));await Task.yield()
        model.navigateBlock(1,conflictsOnly:true)
        try require((right.string as NSString).substring(with:(right as! MergeBlockSelecting).mergeSelectedBlockRange!) == "mine1a\nmine1b","Source conflict grouping/padding")
        try require(right.selectedRange().length == 0 && result.selectedRange().length == 0,"Navigation installed ordinary text selection")
        try require((left.string as NSString).substring(with:(left as! MergeBlockSelecting).mergeSelectedBlockRange!).hasPrefix("theirs1"),"Source peer selection")
        try require((result as! MergeBlockSelecting).mergeSelectedBlockRange == NSRange(location:model.blocks[0].range.location,length:(MergeSourceComparison.navigationRanges(text:(result.string as NSString).substring(with:model.blocks[0].range)).last.map(NSMaxRange) ?? 0)) && model.selectedConflict == 0 && model.canChooseConflict,"Source-to-marker mapping")
        try require(owner.window!.firstResponder === right,"Navigation moved active source focus")
        let f8=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"\u{f70b}",charactersIgnoringModifiers:"\u{f70b}",isARepeat:false,keyCode:100)!
        try require(right.performKeyEquivalent(with:f8),"F8 not handled")
        try require((right.string as NSString).substring(with:(right as! MergeBlockSelecting).mergeSelectedBlockRange!) == "mine2" && (result as! MergeBlockSelecting).mergeSelectedBlockRange == NSRange(location:model.blocks[1].range.location,length:(MergeSourceComparison.navigationRanges(text:(result.string as NSString).substring(with:model.blocks[1].range)).last.map(NSMaxRange) ?? 0)) && model.selectedConflict == 1,"Next source conflict mapped wrong result")
        try require(!model.canNavigateBlock(1,conflictsOnly:true),"Source conflict boundary wrapped")
        let before=model.result,beforeMap=model.resultPresentation.navigationMap
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        let menu=(right as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board)
        guard let choose=menu.items.first(where:{$0.title == MergeBlockChoice.theirs.rawValue}) else {throw Failure(description:"Missing source block choice")}
        try require(choose.isEnabled && choose.image != nil,"Source block choice missing icon or disabled")
        let chosen=model.blocks[1],expected=(before as NSString).replacingCharacters(in:chosen.range,with:chosen.replacement(.theirs))
        _=(choose.target as? NSObject)?.perform(choose.action,with:choose)
        try await ThreePaneEngineVerification.wait{model.result == expected && model.canUndo}
        try require(model.blocks.count == 1 && model.result.contains("theirs2") && model.result.contains("<<<<<<< Mine"),"Choice resolved wrong conflict")
        model.undo();try await ThreePaneEngineVerification.wait{model.result == before && model.blocks.count == 2}
        try require(model.resultPresentation.navigationMap == beforeMap,"Undo lost engine navigation relationships")
        await Task.yield()
        try require(model.selectionRequest == nil && views.compactMap{$0 as? MergeBlockSelecting}.allSatisfy{$0.mergeSelectedBlockRange == nil},"Undo replayed a queued conflict selection")
        model.redo();try await ThreePaneEngineVerification.wait{model.result == expected && model.blocks.count == 1}
        model.undo();try await ThreePaneEngineVerification.wait{model.result == before && model.blocks.count == 2}
        owner.window!.makeFirstResponder(result);result.setSelectedRange(NSRange(location:0,length:0));await Task.yield()
        model.navigateBlock(1,conflictsOnly:true);try require(model.selectedConflict == 0 && result.selectedRange().length == 0 && (result as! MergeBlockSelecting).mergeSelectedBlockRange != nil,"Result next conflict")
        model.navigateBlock(1,conflictsOnly:true);try require(model.selectedConflict == 1,"Result conflict search ignored caret")
        model.navigateBlock(-1,conflictsOnly:true);try require(model.selectedConflict == 0,"Result reverse conflict search")
        let selection=result.selectedRange();model.navigateBlock(-1,conflictsOnly:true);try require(result.selectedRange() == selection,"Result previous wrapped")
        owner.window!.makeFirstResponder(right);right.setSelectedRange(NSRange(location:0,length:0));await Task.yield()
        model.navigateBlock(1,conflictsOnly:false)
        try require((right.string as NSString).substring(with:(right as! MergeBlockSelecting).mergeSelectedBlockRange!) == "base1","Difference search skipped removed Base state")
        owner.window!.makeFirstResponder(result);result.setSelectedRange(NSRange(location:0,length:0));await Task.yield()
        // Manual common-line selection must not resolve the previous conflict.
        try await ThreePaneEngineVerification.wait{!model.canChooseConflict}
        let unchanged=model.result;model.choose(.mine);try require(model.result == unchanged,"Unrelated current selection resolved stale conflict")
        model.confirmingQuit=true;try require(!model.canNavigateBlock(1,conflictsOnly:true),"Quit gate missing");model.navigateBlock(1,conflictsOnly:true);try require(result.selectedRange().location == 0,"Navigation during Quit confirmation");model.confirmingQuit=false
        try require(try String(contentsOf:base,encoding:.utf8) == original && String(contentsOf:mine,encoding:.utf8) == my && String(contentsOf:theirs,encoding:.utf8) == their,"Navigation/choices rewrote input files")
        print("PASS: three-pane active source/result difference and conflict navigation, exact engine peer mapping, F8, native source menu choice, Undo/Redo mapping, stale-choice and Quit guards; owned window closed")
    }
}
