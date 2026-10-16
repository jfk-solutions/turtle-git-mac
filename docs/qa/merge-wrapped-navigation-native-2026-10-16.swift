import AppKit
import Combine
import TurtleGitCore

struct MergeWrappedNavigationVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Wrapped navigation did not settle at \(line)")
    }
    @MainActor static func rect(_ view: NSTextView, _ offset: Int) -> NSRect {
        let layout=view.layoutManager!,container=view.textContainer!;layout.ensureLayout(for:container)
        let glyph=layout.glyphIndexForCharacter(at:min(offset,max(0,view.string.utf16.count - 1)))
        return layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
    }
    @MainActor static func row(_ view: NSTextView, containing text: String) throws -> NSRange {
        let range=(view.string as NSString).range(of:text)
        try require(range.location != NSNotFound,"Missing fixture row \(text)")
        return MergeLineEndings.lineRanges(in:view.string).last { $0.location <= range.location }!
    }
    @MainActor static func atLastFragment(_ view: NSTextView, marker: String) throws -> Bool {
        let range=try row(view,containing:marker)
        // The input rows have one display LF. Compare actual glyph rectangles,
        // independently of the new wrapped-entry helper's fragment enumeration.
        let first=rect(view,range.location),last=rect(view,max(range.location,NSMaxRange(range) - 2))
        return last.minY > first.minY && abs(rect(view,view.selectedRange().location).minY - last.minY) < 0.5
    }
    @MainActor static func readingPosition(_ view: NSTextView, marker: String, next: String) throws -> CGFloat {
        let range=try row(view,containing:marker),following=try row(view,containing:next)
        let top=rect(view,range.location).minY,bottom=rect(view,following.location).minY
        return (view.enclosingScrollView!.contentView.bounds.minY - view.textContainerOrigin.y - top) / (bottom - top)
    }
    @MainActor static func readAt(_ view: NSTextView, marker: String, next: String, fraction: CGFloat) throws {
        (view as! MergeLineNavigationProviding).beginUserNavigation()
        let range=try row(view,containing:marker),following=try row(view,containing:next)
        let top=rect(view,range.location).minY,bottom=rect(view,following.location).minY,scroll=view.enclosingScrollView!
        var bounds=scroll.contentView.bounds;bounds.origin.y=top + (bottom - top) * fraction + view.textContainerOrigin.y
        scroll.contentView.scroll(to:scroll.contentView.constrainBoundsRect(bounds).origin);scroll.reflectScrolledClipView(scroll.contentView)
        (view as! MergeLineNavigationProviding).didNavigateViewport()
    }
    @MainActor static func verify() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitWrappedNavigation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.WrappedNavigation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root) }
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        MergeComparisonOptions.exact.save(to:prefs);prefs.set(true,forKey:"TurtleGitMerge.WrapLines")
        let base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt"),theirs=root.appendingPathComponent("theirs.txt")
        var old=(0..<130).map { String(format:"line %03d ",$0)+String(repeating:"common words\t",count:8) },new=old,incoming=old
        old[20]="OLD WRAPPED "+String(repeating:"base 雪🦎 words\t",count:55)
        new[20]="NEW WRAPPED "+String(repeating:"mine 雪🦎 words\t",count:85)
        incoming[20]="THEIRS WRAPPED "+String(repeating:"incoming 雪🦎 words\t",count:65)
        old[90]="OLD LATE "+String(repeating:"base 🦎 text\t",count:35)
        new[90]="NEW LATE "+String(repeating:"mine 🦎 text\t",count:75)
        incoming[90]="THEIRS LATE "+String(repeating:"incoming 🦎 text\t",count:45)
        let oldBytes=Data((old.joined(separator:"\n")+"\n").utf8),newBytes=Data((new.joined(separator:"\n")+"\n").utf8),theirBytes=Data((incoming.joined(separator:"\n")+"\n").utf8)
        try oldBytes.write(to:base);try newBytes.write(to:mine);try theirBytes.write(to:theirs)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs),model=owner.model
        defer { owner.close() }
        owner.window!.alphaValue=0;owner.window!.orderFront(nil);owner.window!.setContentSize(.init(width:1400,height:720))
        model.commentProfileURL=root.appendingPathComponent("comments.txt");model.load();try await TwoPaneEngineVerification.settled(model)
        try await wait { TwoPaneEngineVerification.editors(owner.window?.contentView).count==2 }
        let views=TwoPaneEngineVerification.editors(owner.window?.contentView)
        let right=views.first{$0.string.contains("NEW LATE")}!,left=views.first{$0.string.contains("OLD LATE")}!
        try await wait { views.allSatisfy{$0.textContainer?.widthTracksTextView==true} && !model.lineWrapping.alignedHeights.isEmpty }
        model.showInlineDiff=false;owner.window!.makeFirstResponder(right)
        try await wait {!model.lineWrapping.isGeometryPending}
        model.scrolled(right.enclosingScrollView!);model.updateSelection(right.selectedRange(),cells:model.displayCells(base:false))
        var repeatedPublications=0
        let observer=model.objectWillChange.sink{repeatedPublications += 1}
        for _ in 0..<3 {model.scrolled(right.enclosingScrollView!);model.updateSelection(right.selectedRange(),cells:model.displayCells(base:false))}
        observer.cancel()
        try require(repeatedPublications==0,"Identical viewport/selection caused a render feedback publication")
        let original=views.map(\.string),generation=model.alignmentGeneration
        right.setSelectedRange(.init(location:right.string.utf16.count - 1,length:0));await Task.yield();model.navigate(-1)
        try require(try atLastFragment(right,marker:"NEW LATE") && atLastFragment(left,marker:"OLD LATE"),"Reverse navigation missed last wrapped fragment/peer")
        try require((right as! MergeBlockSelecting).mergeSelectedBlockRange != nil && right.selectedRange().length==0,"Wrapped navigation lost independent block selection")
        model.navigate(-1)
        try require(try atLastFragment(right,marker:"NEW WRAPPED"),"Reverse traversal repeated or skipped the earlier block")
        model.navigate(1)
        let late=try row(right,containing:"NEW LATE")
        try require(abs(rect(right,right.selectedRange().location).minY - rect(right,late.location).minY)<0.5,"Forward navigation did not enter the first screen row")
        let clicked=late.location + late.length / 2,clickedY=rect(right,clicked).minY
        let existingCaret=right.selectedRange()
        (right as! MergeBlockSelecting).selectContextBlock(at:clicked)
        try require(right.selectedRange()==existingCaret,"Context inside an existing block changed its caret")
        model.clearNavigationBlockSelection()
        (right as! MergeBlockSelecting).selectContextBlock(at:clicked)
        try require(abs(rect(right,right.selectedRange().location).minY - clickedY)<0.5,"Context block moved away from clicked wrapped subline")
        try require(abs(right.enclosingScrollView!.contentView.bounds.minY - left.enclosingScrollView!.contentView.bounds.minY)<0.5,"Wrapped block centering desynchronized peers")

        let navigation=right as! MergeLineNavigationProviding
        var answer:CheckedContinuation<Int?,Never>?
        navigation.chooseNavigationLine={_,_ in await withCheckedContinuation{answer=$0}}
        _=right.perform(NSSelectorFromString("goToSourceLine:"),with:nil)
        try await wait {answer != nil}
        let heldCaret=right.selectedRange()
        let wheel=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-30,wheel2:0,wheel3:0)!
        right.scrollWheel(with:NSEvent(cgEvent:wheel)!)
        answer!.resume(returning:1);answer=nil
        try await wait {!navigation.navigationPending}
        try require(right.selectedRange()==heldCaret,"Wheel input allowed a stale Go to Line response")
        // Hold a source row and fractional reading position through width, font
        // and wrap reflow; literal pixel offsets are deliberately not retained.
        try readAt(right,marker:"line 060",next:"line 061",fraction:0.35);await Task.yield()
        try await wait {!model.lineWrapping.isGeometryPending}
        let before=try readingPosition(right,marker:"line 060",next:"line 061"),height=rect(right,(try row(right,containing:"line 061")).location).minY
        try require(abs(before - 0.35)<0.05,"Two-pane reading input was overwritten before resize")
        let selection=views.map{$0.selectedRange()}
        owner.window!.setContentSize(.init(width:900,height:720));owner.window!.contentView!.layoutSubtreeIfNeeded()
        try await wait { rect(right,(try! row(right,containing:"line 061")).location).minY > height + 10 }
        print("Two-pane resize diagnostic: before=\(before), after=\(try readingPosition(right,marker:"line 060",next:"line 061")), owner=\(model.lineWrapping.viewportDiagnostics)")
        try await wait { !model.lineWrapping.isGeometryPending && abs((try! readingPosition(right,marker:"line 060",next:"line 061")) - before)<0.05 }
        var general=MergeGeneralPreferences.load(from:prefs);general.fontName="Menlo";general.fontSize=16;general.save(to:prefs);model.refreshPreferences()
        try await wait { views.allSatisfy{$0.font?.pointSize==16} }
        try await wait { !model.lineWrapping.isGeometryPending && abs((try! readingPosition(right,marker:"line 060",next:"line 061")) - before)<0.05 }
        model.setWrapLines(false)
        try await wait { views.allSatisfy{$0.textContainer?.widthTracksTextView==false} }
        try await wait { !model.lineWrapping.isGeometryPending && abs((try! readingPosition(right,marker:"line 060",next:"line 061")) - before)<0.05 }
        try require(views.map(\.string)==original && views.map{$0.selectedRange()}==selection && model.alignmentGeneration==generation && !model.canUndo && !model.dirty,"Reflow changed text/caret/history/alignment")
        owner.close()

        var mergeLines=new;mergeLines.insert("NEW SAFE "+String(repeating:"unilateral 雪🦎 words\t",count:75),at:110)
        let mergeMine=root.appendingPathComponent("merge-mine.txt"),mergeBytes=Data((mergeLines.joined(separator:"\n")+"\n").utf8)
        try mergeBytes.write(to:mergeMine)
        let merge=TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"merge-mine.txt",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mergeMine),preferences:prefs)
        defer { merge.close() }
        merge.window!.alphaValue=0;merge.window!.orderFront(nil);merge.window!.setContentSize(.init(width:1400,height:800));merge.model.load()
        try await wait { !merge.model.busy && !merge.model.preparing && merge.model.document != nil }
        merge.model.setWrapLines(true)
        try await wait { ThreePaneEngineVerification.textViews(merge.window?.contentView).filter{!$0.isFieldEditor}.count==3 }
        let three=ThreePaneEngineVerification.textViews(merge.window?.contentView).filter{!$0.isFieldEditor},result=three.first{$0.isEditable}!
        try await wait { three.allSatisfy{$0.textContainer?.widthTracksTextView==true} && merge.model.lineWrapping.alignedHeights.count>100 && result.string==merge.model.resultDisplayText }
        let resultText=merge.model.result,threeText=three.map(\.string),resultRows=merge.model.resultPresentation,initialDirty=merge.model.dirty,initialUndo=merge.model.canUndo
        // Unresolved aligned result rows are intentionally empty; use a source
        // pane for conflict text, and a non-conflicting insertion for result text.
        let source=three.first{!$0.isEditable && $0.string.contains("NEW LATE")}!
        merge.window!.makeFirstResponder(source);source.setSelectedRange(.init(location:source.string.utf16.count - 1,length:0));await Task.yield()
        merge.model.navigateBlock(-1,conflictsOnly:true)
        try require(try atLastFragment(source,marker:"NEW LATE"),"Three-pane reverse source conflict ignored wrapped entry")
        try require(three.allSatisfy{($0 as! MergeBlockSelecting).mergeSelectedBlockRange != nil},"Three-pane wrapped peer block missing")
        merge.window!.makeFirstResponder(result);result.setSelectedRange(.init(location:result.string.utf16.count - 1,length:0));await Task.yield()
        merge.model.navigateBlock(-1,conflictsOnly:false)
        try require(try atLastFragment(result,marker:"NEW SAFE"),"Result reverse difference entry ignored wrapped screen row")
        try readAt(result,marker:"line 060",next:"line 061",fraction:0.3);await Task.yield()
        try await wait {!merge.model.lineWrapping.isGeometryPending}
        print("Three-pane before resize: \(merge.model.lineWrapping.viewportDiagnostics)")
        let threeBefore=try readingPosition(result,marker:"line 060",next:"line 061"),threeHeight=rect(result,(try row(result,containing:"line 061")).location).minY
        try require(abs(threeBefore - 0.3)<0.05,"Three-pane reading input was overwritten before resize")
        merge.window!.setContentSize(.init(width:1000,height:800));merge.window!.contentView!.layoutSubtreeIfNeeded()
        try await wait { rect(result,(try! row(result,containing:"line 061")).location).minY > threeHeight + 10 }
        print("Three-pane anchor diagnostic: before=\(threeBefore), after=\(try readingPosition(result,marker:"line 060",next:"line 061")), peers=\(three.map{$0.enclosingScrollView!.contentView.bounds.minY}), resultFocused=\(merge.window!.firstResponder === result), owner=\(merge.model.lineWrapping.viewportDiagnostics)")
        try await wait { !merge.model.lineWrapping.isGeometryPending && abs((try! readingPosition(result,marker:"line 060",next:"line 061")) - threeBefore)<0.05 }
        let peerY=three.map{$0.enclosingScrollView!.contentView.bounds.minY}
        try require((peerY.max()! - peerY.min()!)<1,"Three-pane reflow desynchronized linked viewports")
        try require(three.map(\.string)==threeText && merge.model.result==resultText && merge.model.resultPresentation==resultRows && merge.model.canUndo==initialUndo && merge.model.dirty==initialDirty,"Three-pane reflow changed result records/history")
        merge.model.setCollapsed(true)
        try await wait { merge.model.folding.collapsed }
        result.setSelectedRange(.init(location:result.string.utf16.count - 1,length:0));await Task.yield();merge.model.navigateBlock(-1,conflictsOnly:true)
        try require((result as! MergeBlockSelecting).mergeSelectedBlockRange != nil,"Folded wrapped navigation lost visible conflict")
        merge.model.setCollapsed(false)
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_WRAP_CAPTURE"] {
            merge.window!.alphaValue=1
            for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                merge.window!.appearance=NSAppearance(named:appearance);merge.window!.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                try await Task.sleep(nanoseconds:300_000_000)
                let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-o","-l",String(merge.window!.windowNumber),URL(fileURLWithPath:output).appendingPathComponent("merge-wrapped-navigation-"+name+".png").path]
                try process.run();process.waitUntilExit();try require(process.terminationStatus==0,"Owned wrapped-navigation capture failed")
            }
        }
        merge.close();let saved=prefs.bool(forKey:"TurtleGitMerge.WrapLines");merge.model.setWrapLines(!saved)
        try require(prefs.bool(forKey:"TurtleGitMerge.WrapLines")==saved,"Retired wrapping persisted a late choice")
        try require(try Data(contentsOf:base)==oldBytes && Data(contentsOf:mine)==newBytes && Data(contentsOf:theirs)==theirBytes && Data(contentsOf:mergeMine)==mergeBytes,"Navigation/reflow changed source files")
        print("PASS: wrapped reverse/forward/context caret and peers, source-row/fraction anchors across resize/font/wrap, three-pane aligned result reflow, folded conflict navigation, unchanged text/selection/history/files and retirement")
    }
}
