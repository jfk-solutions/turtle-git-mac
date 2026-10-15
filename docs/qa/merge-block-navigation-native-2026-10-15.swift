import AppKit
import TurtleGitCore

struct MergeBlockNavigationVerification {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message:message) } }
    @MainActor static func verify() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBlockNavigation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.BlockNavigation."+UUID().uuidString, prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        prefs.set(true,forKey:"TurtleGitMerge.OnePane");MergeComparisonOptions.exact.save(to:prefs)
        let base=root.appendingPathComponent("base.txt"), mine=root.appendingPathComponent("mine.txt")
        let old="head\nversion 1\nkeep\nold one\nold two\nlast", new="head\nversion 2\nkeep\nnew one\nnew two\nlast"
        try Data(old.utf8).write(to:base);try Data(new.utf8).write(to:mine)
        let filter=MergeRegexFilter(name:"Version",expression:"[0-9]+",replacement:"")
        try MergeRegexFilters.save([filter],defaults:prefs)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs), model=owner.model
        defer{owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil)
        model.regexDefaults=prefs;model.refreshRegexFilters();model.load();try await TwoPaneEngineVerification.settled(model)
        model.selectRegexFilter(filter.name);try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait{TwoPaneEngineVerification.editors(owner.window?.contentView).count == 1}
        let view=TwoPaneEngineVerification.editors(owner.window?.contentView)[0]
        try await TwoPaneEngineVerification.wait{view.string.contains("version 1") && view.string.contains("new two")}
        owner.window!.makeFirstResponder(view);view.setSelectedRange(NSRange(location:0,length:0));await Task.yield()
        try require(model.canNavigateDifference(1) && !model.canNavigateDifference(-1),"First-row availability")
        model.navigate(1)
        try require((view.string as NSString).substring(with:view.selectedRange()) == "version 1","Neutral Base row skipped")
        let nextKey=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.control,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"\u{f701}",charactersIgnoringModifiers:"\u{f701}",isARepeat:false,keyCode:125)!
        try require(view.performKeyEquivalent(with:nextKey),"Control-Down not handled")
        try require((view.string as NSString).substring(with:view.selectedRange()) == "version 2","Neutral Mine row skipped")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        let menu=(view as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board)
        guard let next=menu.items.first(where:{$0.title == "Next difference"}) else {throw Failure(message:"Missing navigation context menu")}
        try require(next.isEnabled && next.image != nil,"Navigation context menu disabled or missing source icon")
        _=(next.target as? NSObject)?.perform(next.action,with:next)
        try require((view.string as NSString).substring(with:view.selectedRange()) == "old one\nold two","Removed block not selected")
        try require(model.transferRows?.count == 2,"Navigation did not supply transfer block")
        model.navigate(1)
        try require((view.string as NSString).substring(with:view.selectedRange()) == "new one\nnew two" && !model.canNavigateDifference(1),"Added block/end boundary")
        let boundary=view.selectedRange();model.navigate(1);try require(view.selectedRange() == boundary,"Navigation wrapped at end")
        model.navigate(-1);try require((view.string as NSString).substring(with:view.selectedRange()) == "old one\nold two","Reverse block selection")
        model.navigate(-1);try require((view.string as NSString).substring(with:view.selectedRange()) == "version 2","Backward caret repeated block")
        model.navigate(-1);try require((view.string as NSString).substring(with:view.selectedRange()) == "version 1" && !model.canNavigateDifference(-1),"Reverse neutral Base/boundary")
        model.setComparisonOptions(.init(whitespace:.ignoreChanges));try await TwoPaneEngineVerification.settled(model)
        view.setSelectedRange((view.string as NSString).range(of:"old one"));await Task.yield()
        model.setCollapsed(true)
        let visible=model.folding.projection.rows.map(\.sourceRow)
        let expected=MergeBlockNavigation.target(states:model.displayCells(base:false).map(\.state),visibleRows:visible,caret:0,direction:1)
        view.setSelectedRange(NSRange(location:0,length:0));await Task.yield()
        let visibility=model.folding.folding.visibility
        model.navigate(1)
        try require(expected != nil && model.folding.folding.visibility == visibility,"Block navigation expanded hidden rows")
        let expectedText=model.displayCells(base:false)[expected!.rows].map(\.displayText).joined(separator:"\n")
        try require((view.string as NSString).substring(with:view.selectedRange()) == expectedText,"Folded navigation did not follow visible states")
        model.setCollapsed(false);model.setComparisonOptions(.exact);try await TwoPaneEngineVerification.settled(model)
        model.switchPaneMode(false);try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait{TwoPaneEngineVerification.editors(owner.window?.contentView).count == 2}
        let editors=TwoPaneEngineVerification.editors(owner.window?.contentView)
        try await TwoPaneEngineVerification.wait{editors.allSatisfy{$0.string.contains("version")}}
        let left=editors.first{$0.string.contains("old one")}!, right=editors.first{$0.string.contains("new one")}!
        owner.window!.makeFirstResponder(left);left.setSelectedRange(NSRange(location:0,length:0));await Task.yield();model.navigate(1)
        try require((left.string as NSString).substring(with:left.selectedRange()) == "old one\nold two","Two-pane filtered row became difference")
        try require((right.string as NSString).substring(with:right.selectedRange()) == "new one\nnew two","Peer block selection missing")
        owner.window!.makeFirstResponder(right);right.setSelectedRange(NSRange(location:0,length:0));await Task.yield()
        try require(model.canNavigateDifference(1),"Active right pane did not own navigation")
        model.navigate(1);try require((right.string as NSString).substring(with:right.selectedRange()) == "new one\nnew two","Right-pane navigation")
        model.confirmingQuit=true;try require(!model.canNavigateDifference(-1),"Quit confirmation did not gate navigation");let held=right.selectedRange();model.navigate(-1);try require(right.selectedRange() == held,"Quit confirmation accepted navigation");model.confirmingQuit=false
        try require(try String(contentsOf:base,encoding:.utf8) == old && String(contentsOf:mine,encoding:.utf8) == new,"Navigation modified input")
        print("PASS: active-pane neutral/real blocks, reverse caret, peer selection, no wrap, filtered exclusions and Quit guard; owned window closed")
    }
}
