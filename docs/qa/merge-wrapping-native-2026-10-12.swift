import AppKit
import TurtleGitCore

struct MergeWrappingVerification {
    @MainActor static func verify() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "MergeWrapping", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        func wait(_ ready: () -> Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw NSError(domain: "Wrapping geometry did not settle", code: 1) }
        func y(_ view: NSTextView, row: Int) -> CGFloat {
            guard let layout=view.layoutManager,let container=view.textContainer else {return -1}
            let lines=MergeLineEndings.lineRanges(in:view.string);guard lines.indices.contains(row) else{return -1}
            layout.ensureLayout(for:container)
            let glyph=layout.glyphRange(forCharacterRange:NSRange(location:lines[row].location,length:1),actualCharacterRange:nil)
            return layout.lineFragmentRect(forGlyphAt:glyph.location,effectiveRange:nil).minY
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitWrapNative-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.WrapNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        let base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine"),theirs=root.appendingPathComponent("theirs")
        let old="first\r\nold short\r\nlast",new="first\r\n"+String(repeating:"new 雪🦎 word\t",count:80)+"\r\nlast"
        try Data(old.utf8).write(to:base);try Data(new.utf8).write(to:mine);try Data(old.utf8).write(to:theirs)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs)
        defer {owner.window?.close()}
        let model=owner.model;model.commentProfileURL=root.appendingPathComponent("ignorecomments.txt");model.load();try await TwoPaneEngineVerification.settled(model)
        owner.window?.contentView?.layoutSubtreeIfNeeded();try await wait {TwoPaneEngineVerification.editors(owner.window?.contentView).count==2}
        let views=TwoPaneEngineVerification.editors(owner.window?.contentView),strings=views.map(\.string),ranges=views.map{$0.selectedRange()},generation=model.alignmentGeneration
        let plain=y(views[1],row:2)
        try check(!model.wrapLines,"Source wrap default is not false")
        model.setWrapLines(true)
        try await wait {views.allSatisfy{$0.textContainer?.widthTracksTextView==true && $0.enclosingScrollView?.hasHorizontalScroller==false} && y(views[1],row:2)>plain+20 && abs(y(views[0],row:2)-y(views[1],row:2))<1}
        try check(prefs.bool(forKey:"TurtleGitMerge.WrapLines") && model.lineWrapping.alignedHeights.count==3,"Wrap persistence/shared row heights missing")
        let beforeResize=y(views[1],row:2);owner.window?.setContentSize(NSSize(width:900,height:720));owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait {y(views[1],row:2)>beforeResize && abs(y(views[0],row:2)-y(views[1],row:2))<1}
        try check(views.map(\.string)==strings && views.map{$0.selectedRange()}==ranges && !model.dirty && !model.canUndo && model.alignmentGeneration==generation,"Wrap/resize changed text/selection/history/alignment")
        model.setWrapLines(false)
        try await wait {views.allSatisfy{$0.textContainer?.widthTracksTextView==false && $0.enclosingScrollView?.hasHorizontalScroller==true} && abs(y(views[1],row:2)-plain)<1}
        try check(!prefs.bool(forKey:"TurtleGitMerge.WrapLines"),"Unwrap did not persist")
        model.switchPaneMode(true);try await TwoPaneEngineVerification.settled(model);try await wait {TwoPaneEngineVerification.editors(owner.window?.contentView).count==1}
        model.setWrapLines(true);try await wait {TwoPaneEngineVerification.editors(owner.window?.contentView).allSatisfy{$0.textContainer?.widthTracksTextView==true}}
        let merge=TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs)
        defer {merge.window?.close()}
        merge.model.commentProfileURL=root.appendingPathComponent("ignorecomments.txt");merge.model.load()
        try await wait {!merge.model.busy && merge.model.document != nil}
        merge.window?.contentView?.layoutSubtreeIfNeeded();try await wait {TwoPaneEngineVerification.editors(merge.window?.contentView).count==3}
        let three=TwoPaneEngineVerification.editors(merge.window?.contentView),before=three.map(\.string)
        try await wait {three.allSatisfy{$0.textContainer?.widthTracksTextView==true}}
        merge.model.setWrapLines(false);try await wait {three.allSatisfy{$0.textContainer?.widthTracksTextView==false}}
        try check(three.map(\.string)==before && !merge.model.canUndo,"Three-pane wrap changed content/history")
        model.retireImageLoader();let preference=prefs.bool(forKey:"TurtleGitMerge.WrapLines");model.setWrapLines(!preference)
        try check(prefs.bool(forKey:"TurtleGitMerge.WrapLines")==preference,"Retired wrap action persisted")
        let finalBase=try Data(contentsOf:base),finalMine=try Data(contentsOf:mine)
        try check(finalBase==Data(old.utf8) && finalMine==Data(new.utf8),"Wrapping changed saved bytes")
        print("Wrapping: source default/persistence, actual TextKit word wrapping/horizontal scrollbar gates, paired-row height alignment and resize reflow, unchanged Unicode text/selection/history/alignment/files, combined and three-pane wrapping plus retired guard passed. Owned windows/helpers closed.")
    }
}
