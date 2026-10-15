import AppKit
import TurtleGitCore

struct MergeInitialNavigationVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func goToLine(_ view:NSTextView) { _=view.perform(NSSelectorFromString("goToSourceLine:"),with:nil) }
    @MainActor static func verify() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitInitialNavigation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.InitialNavigation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        MergeGeneralPreferences(firstDifference:true,firstConflict:false).save(to:prefs);MergeComparisonOptions.exact.save(to:prefs)
        let base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt")
        let old="head\nprefix old suffix remains\ntail\n",new="head\nprefix new suffix remains\ntail\n"
        try Data(old.utf8).write(to:base);try Data(new.utf8).write(to:mine)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs),model=owner.model
        defer{owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        let views=TwoPaneEngineVerification.editors(owner.window?.contentView),right=views.first{$0.string.contains("prefix new")}!,left=views.first{$0.string.contains("prefix old")}!
        let selected=right as! MergeBlockSelecting
        try require(selected.mergeSelectedBlockRange == NSRange(location:5,length:25) && right.selectedRange() == NSRange(location:12,length:0),"Initial source block/inline entry caret")
        try require((left as! MergeBlockSelecting).mergeSelectedBlockRange != nil && model.transferRows == 1..<2,"Initial peer block/transfer rows")
        let navigation=right as! MergeLineNavigationProviding
        navigation.beginUserNavigation();right.setSelectedRange(NSRange(location:0,length:0));await Task.yield()
        right.setSelectedRange(NSRange(location:12,length:0));await Task.yield()
        try await TwoPaneEngineVerification.wait{model.difference == 0 && model.transferRows == nil}
        model.editingEnabled=true;try await TwoPaneEngineVerification.wait{right.isEditable}
        model.useOtherBlock();try require(model.draftText(base:false) == new && !model.dirty,"Unselected engine region transferred")
        selected.selectContextBlock(at:12);model.useOtherBlock();try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false) == old && model.canUndo,"Explicit context block transfer failed")
        model.undo()
        // Undo restores its retained view records; later user intent still wins
        // over the queued layout/caret restoration without another diff helper.
        try require(!model.filtering,"Undo unnecessarily regenerated the diff")
        navigation.beginUserNavigation();right.setSelectedRange(NSRange(location:0,length:0))
        try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false) == new && right.selectedRange() == NSRange(location:0,length:0),"Deferred Undo caret overrode later input")
        var answer:CheckedContinuation<Int?,Never>?
        navigation.chooseNavigationLine={_,_ in await withCheckedContinuation{answer=$0}}
        goToLine(right);try await TwoPaneEngineVerification.wait{answer != nil}
        navigation.beginUserNavigation();right.setSelectedRange(NSRange(location:0,length:0))
        answer!.resume(returning:2);answer=nil
        try await TwoPaneEngineVerification.wait{!navigation.navigationPending}
        try require(right.selectedRange() == NSRange(location:0,length:0),"Stale Go to Line answer moved caret without a text change")
        navigation.chooseNavigationLine={_,_ in 2};goToLine(right)
        try await TwoPaneEngineVerification.wait{!navigation.navigationPending && right.selectedRange().location == 5}
        try require(right.selectedRange().length > 0,"Fresh Go to Line was discarded")
        owner.close()
        // Neutral combined states precede the engine's real changed region.
        prefs.set(true,forKey:"TurtleGitMerge.OnePane")
        let a=root.appendingPathComponent("neutral-base.txt"),b=root.appendingPathComponent("neutral-mine.txt")
        try Data("head\nversion 1\nkeep\nold\ntail\n".utf8).write(to:a);try Data("head\nversion 2\nkeep\nnew\ntail\n".utf8).write(to:b)
        let filter=MergeRegexFilter(name:"Versions",expression:"[0-9]+",replacement:"");try MergeRegexFilters.save([filter],defaults:prefs)
        let combined=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs,deferInitialLoad:true),one=combined.model
        defer{combined.close()};combined.window!.alphaValue=0;combined.window!.orderFront(nil)
        one.regexDefaults=prefs;one.refreshRegexFilters();one.selectRegexFilter(filter.name);one.beginTransferredDocument();try await TwoPaneEngineVerification.settled(one)
        let view=TwoPaneEngineVerification.editors(combined.window?.contentView)[0]
        let range=(view as! MergeBlockSelecting).mergeSelectedBlockRange
        try require(range != nil && (view.string as NSString).substring(with:range!) == "version 1" && one.difference == -1,"Initial combined navigation: mode=\(one.onePaneActive), range=\(String(describing:range)), payload=\(range.map{(view.string as NSString).substring(with:$0)} ?? "nil"), diff=\(one.difference), filter=\(one.regexFilterName ?? "nil"), states=\(one.displayCells(base:false).map(\.state))")
        one.navigate(1);try require((view.string as NSString).substring(with:(view as! MergeBlockSelecting).mergeSelectedBlockRange!) == "version 2","Neutral next state navigation")
        combined.close()
        let merge=TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine.txt",workingMerge:try WorkingTextMerge(base:base,theirs:base,mine:mine),preferences:prefs),three=merge.model
        defer{merge.close()};merge.window!.alphaValue=0;merge.window!.orderFront(nil);three.load()
        try await ThreePaneEngineVerification.wait{!three.busy && three.document != nil && ThreePaneEngineVerification.editableView(merge.window?.contentView) != nil}
        let result=ThreePaneEngineVerification.editableView(merge.window?.contentView)!,resultNavigation=result as! MergeLineNavigationProviding
        merge.window!.makeFirstResponder(result);resultNavigation.beginUserNavigation();result.setSelectedRange(NSRange(location:0,length:0))
        var resultAnswer:CheckedContinuation<Int?,Never>?
        resultNavigation.chooseNavigationLine={_,_ in await withCheckedContinuation{resultAnswer=$0}}
        goToLine(result);try await ThreePaneEngineVerification.wait{resultAnswer != nil}
        resultNavigation.beginUserNavigation();result.setSelectedRange(NSRange(location:0,length:0));resultAnswer!.resume(returning:2);resultAnswer=nil
        try await ThreePaneEngineVerification.wait{!resultNavigation.navigationPending}
        try require(result.selectedRange() == NSRange(location:0,length:0),"Stale result Go to Line answer moved caret")
        merge.close()
        try require(!resultNavigation.navigationAllowed,"Retired result still permits line navigation")
        try require(try String(contentsOf:base,encoding:.utf8) == old && String(contentsOf:mine,encoding:.utf8) == new,"Selection/transfer/Undo rewrote inputs")
        print("PASS: ready initial source/peer block and inline caret, explicit-only transfer, later input revokes pending Undo restoration, versioned stale/fresh Go to Line, initial neutral combined block and unchanged inputs; owned windows closed")
    }
}
