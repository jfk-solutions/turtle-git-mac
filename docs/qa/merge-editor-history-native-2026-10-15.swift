import AppKit
import TurtleGitCore

struct MergeEditorHistoryVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func invoke(_ title:String,menu:NSMenu) throws {
        guard let item=menu.items.first(where:{$0.title == title}),item.isEnabled,let action=item.action else {throw Failure(description:"Disabled native command: "+title)}
        _=(item.target as? NSObject)?.perform(action,with:item)
    }
    @MainActor static func verify() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorHistory-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.EditorHistory."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs);MergeComparisonOptions.exact.save(to:prefs)
        let base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt")
        let before="head\nprefix old suffix remains\nprefix remove suffix remains\ntail\n",after="head\nprefix new suffix remains\nprefix add suffix remains\ntail\n"
        try Data(before.utf8).write(to:base);try Data(after.utf8).write(to:mine)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs),model=owner.model
        defer{owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait{TwoPaneEngineVerification.editors(owner.window?.contentView).count == 2}
        let views=TwoPaneEngineVerification.editors(owner.window?.contentView),right=views.first{$0.string.contains("prefix new")}!,left=views.first{$0.string.contains("prefix old")}!
        try await TwoPaneEngineVerification.wait{right.string.contains("prefix new") && model.alignment != nil}
        owner.window!.makeFirstResponder(right);right.setSelectedRange(NSRange(location:0,length:0));await Task.yield();model.setInlineDiff(true)
        let f7=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"\u{f70a}",charactersIgnoringModifiers:"\u{f70a}",isARepeat:false,keyCode:98)!
        try require(right.performKeyEquivalent(with:f7),"F7 not handled")
        let block=(right as! MergeBlockSelecting).mergeSelectedBlockRange
        try require(block != nil && right.selectedRange() == NSRange(location:12,length:0),"Next block did not advance to first inline boundary")
        let inline=right as! MergeInlineNavigationProviding
        try require(inline.canNavigateInline(forward:true),"Next inline boundary absent");inline.navigateInline(forward:true)
        try require(right.selectedRange() == NSRange(location:15,length:0) && (right as! MergeBlockSelecting).mergeSelectedBlockRange == block,"Explicit inline movement lost block")
        inline.navigateInline(forward:false);try require(right.selectedRange().location == 12,"Previous inline boundary")
        (left as! MergeBlockSelecting).selectContextBlock(at:12)
        try require(owner.window!.firstResponder === left && model.activeBase,"Existing peer block retained previous pane focus")
        (right as! MergeBlockSelecting).selectContextBlock(at:12)
        try require(owner.window!.firstResponder === right && !model.activeBase,"Context did not return focus to Mine")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        model.editingEnabled=true;try await TwoPaneEngineVerification.wait{right.isEditable}
        board.setString("INSERT",forType:.string)
        try invoke("Paste",menu:(right as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board))
        let pasted=(after as NSString).replacingCharacters(in:NSRange(location:12,length:0),with:"INSERT")
        try await TwoPaneEngineVerification.settled(model);try require(model.draftText(base:false) == pasted,"Inline caret Paste inserted at wrong position")
        let redoCaret=right.selectedRange()
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait{right.selectedRange() == NSRange(location:12,length:0)}
        try require(model.draftText(base:false) == after && views.allSatisfy{($0 as! MergeBlockSelecting).mergeSelectedBlockRange == nil && $0.selectedRange().length == 0},"Undo text/target caret/all-view clearing")
        let noCopy=(right as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board).items.first{$0.title == "Copy"}!
        try require(!noCopy.isEnabled,"Undo left an invisible block available to Copy")
        model.redo();try await TwoPaneEngineVerification.settled(model);try await TwoPaneEngineVerification.wait{right.selectedRange() == redoCaret}
        try require(model.draftText(base:false) == pasted && (left as! MergeBlockSelecting).mergeSelectedBlockRange == nil,"Redo text/caret or peer clearing")
        model.undo();try await TwoPaneEngineVerification.settled(model);try await TwoPaneEngineVerification.wait{right.selectedRange().location == 12}
        (right as! MergeBlockSelecting).selectContextBlock(at:0)
        try invoke("Copy",menu:(right as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board))
        try require(board.string(forType:.string) == "head","Normal context state block did not copy")
        (right as! MergeBlockSelecting).selectContextBlock(at:12)
        try require(right.selectedRange() == NSRange(location:5,length:0),"Context selection wrongly advanced inline caret")
        try invoke("Copy",menu:(right as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board))
        try require(board.string(forType:.string) == "prefix new suffix remains\nprefix add suffix remains","Context block did not use fixed source state")
        model.setInlineDiff(false);right.setSelectedRange(NSRange(location:0,length:0));await Task.yield();model.navigate(1)
        try require(right.selectedRange() == NSRange(location:5,length:0),"Disabled inline display still advanced caret")
        try require(try String(contentsOf:base,encoding:.utf8) == before && String(contentsOf:mine,encoding:.utf8) == after,"History/navigation rewrote inputs")
        print("PASS: F7 source block/automatic inline advance, explicit boundary navigation, native Paste at inline caret, authoritative Compare Undo/Redo caret restoration, all-pane selection clearing, no invisible Copy, Normal/changed context blocks and disabled-inline gate; owned window closed")
    }
}
