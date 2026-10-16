import AppKit
import TurtleGitCore

struct MergeMarginSelectionVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Margin selection timeout at line \(line)")
    }
    @MainActor static func ruler(_ view:NSTextView)->MergeLineRuler {view.enclosingScrollView!.verticalRulerView as! MergeLineRuler}
    @MainActor static func event(_ view:NSTextView,_ row:Int,_ type:NSEvent.EventType = .leftMouseDown,shift:Bool = false,clicks:Int = 1,fragment:Int = 0,outside:Bool = false)->NSEvent {
        let ranges=MergeSourceComparison.navigationRanges(text:view.string),layout=view.layoutManager!,container=view.textContainer!
        layout.ensureLayout(for:container)
        let offsets=MergeWrappedCaret.starts(in:view,row:ranges[row]),offset=offsets[min(fragment,offsets.count-1)]
        let glyph=layout.glyphIndexForCharacter(at:min(offset,view.string.utf16.count-1))
        let frame=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        let y=outside ? view.visibleRect.maxY+40:frame.midY+view.textContainerOrigin.y
        let r=ruler(view),local=r.convert(NSPoint(x:0,y:y),from:view)
        let point=r.convert(NSPoint(x:5,y:local.y),to:nil)
        return NSEvent.mouseEvent(with:type,location:point,modifierFlags:shift ? .shift:[],timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:0,clickCount:clicks,pressure:1)!
    }
    @MainActor static func click(_ view:NSTextView,_ row:Int,shift:Bool = false,clicks:Int = 1,fragment:Int = 0) {
        ruler(view).mouseDown(with:event(view,row,shift:shift,clicks:clicks,fragment:fragment));ruler(view).mouseUp(with:event(view,row,.leftMouseUp))
    }
    @MainActor static func blockRows(_ view:NSTextView)->Range<Int>? {
        guard let range=(view as? MergeBlockSelecting)?.mergeSelectedBlockRange else {return nil}
        let ranges=MergeSourceComparison.navigationRanges(text:view.string)
        guard let start=ranges.lastIndex(where:{$0.location<=range.location}),let end=ranges.lastIndex(where:{$0.location<=NSMaxRange(range)}) else {return nil}
        return start..<(end+1)
    }
    @MainActor static func copy(_ view:NSTextView,_ prefs:UserDefaults,_ board:NSPasteboard)throws->String? {
        let menu=(view as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:board)
        guard let copy=menu.item(withTitle:"Copy"),copy.isEnabled,let target=copy.target as? NSObject,let action=copy.action else {throw Failure(description:"Native Copy unavailable")}
        _=target.perform(action,with:copy);return board.string(forType:.string)
    }
    @MainActor static func verify()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMarginSelection-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.MarginSelection."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,board=NSPasteboard.withUniqueName()
        defer {prefs.removePersistentDomain(forName:suite);board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs);MergeComparisonOptions.exact.save(to:prefs)
        MergeEditorPreferences(showLineNumbers:true).save(to:prefs)
        var lines=(0..<100).map {"record \($0) 🐢"};lines[2]=String(repeating:"wrapped value 🐢 ",count:32)
        let a=root.appendingPathComponent("before.txt"),b=root.appendingPathComponent("after.txt")
        let old=Data(lines.joined(separator:"\r\n").appending("\r\n").utf8);lines[5]="changed record 5 🐢"
        let new=Data(lines.joined(separator:"\r\n").appending("\r\n").utf8);try old.write(to:a);try new.write(to:b)
        let pair=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=pair.model
        defer {pair.close()};pair.window!.alphaValue=0;pair.window!.setContentSize(.init(width:1150,height:700));pair.window!.orderFront(nil)
        model.commentProfileURL=root.appendingPathComponent("comments.txt");model.load();try await TwoPaneEngineVerification.settled(model)
        func editors()->[NSTextView] {TwoPaneEngineVerification.editors(pair.window?.contentView).filter {$0 is ComparisonContextMenuProviding}}
        try await wait {editors().count==2 && editors().allSatisfy {ruler($0).presentation.symbols.count==101}}
        let left=editors().first {$0.string.contains("record 5 🐢")==true && !$0.string.contains("changed record")}!,right=editors().first {$0 !== left}!
        let ranges=MergeSourceComparison.navigationRanges(text:right.string)
        click(right,1)
        try require(right.selectedRange()==ranges[1] && blockRows(right)==1..<2 && blockRows(left)==1..<2 && pair.window!.firstResponder === right,"Single gutter click did not select text/peer row/focus")
        try require(try copy(right,prefs,board)=="record 1 🐢","Gutter Copy added an ending or lost Unicode")
        click(right,4,shift:true)
        try require(right.selectedRange()==NSRange(location:ranges[1].location,length:ranges[4].location-ranges[1].location) && blockRows(left)==1..<5 && model.transferRows==1..<5,"Shift gutter did not extend from original anchor through endpoint row")
        let expected=(right.string as NSString).substring(with:right.selectedRange())
        try require(try copy(right,prefs,board)==expected,"Shift gutter Copy ignored explicit selection")
        click(right,6,shift:true);click(right,0,shift:true)
        try require(right.selectedRange()==NSRange(location:ranges[0].location,length:ranges[1].location) && blockRows(left)==0..<2,"Reversing Shift selection lost fixed anchor")
        let rr=ruler(right)
        rr.mouseDown(with:event(right,5));rr.mouseDragged(with:event(right,3,.leftMouseDragged));rr.mouseUp(with:event(right,3,.leftMouseUp))
        try require(right.selectedRange()==NSRange(location:ranges[3].location,length:ranges[5].location-ranges[3].location) && blockRows(left)==3..<6 && !rr.marginDragging,"Upward drag selected wrong source span or left capture")
        // Gutter text selection feeds the ordinary editable path and Undo.
        model.activatePane(base:false);model.editingEnabled=true;try await wait {right.isEditable}
        rr.mouseDown(with:event(right,5));right.insertText("replacement 🐢",replacementRange:right.selectedRange())
        try await wait {model.draftText(base:false).contains("replacement 🐢")}
        try require(model.draftText(base:false).contains("record 4 🐢\r\nreplacement 🐢\r\nrecord 6 🐢"),"Replacing gutter line damaged neighboring contents/endings")
        rr.mouseDragged(with:event(right,7,.leftMouseDragged));try require(!rr.marginDragging,"Late drag after text edit revived old gesture")
        model.undo();try await wait {!model.dirty}
        // An owned sheet rejects input before any selection/anchor change.
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:100,height:60),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false
        pair.window!.beginSheet(sheet,completionHandler:{_ in});let before=right.selectedRange();click(right,1)
        try require(right.selectedRange()==before && !rr.marginDragging,"Owned sheet accepted gutter input")
        pair.window!.endSheet(sheet);sheet.orderOut(nil);sheet.close();try await wait {pair.window?.attachedSheet==nil}
        model.setWrapLines(true);try await wait {!model.lineWrapping.isGeometryPending && MergeWrappedCaret.starts(in:right,row:ranges[2]).count>2}
        click(right,2,fragment:1)
        try require(right.selectedRange()==ranges[2] && blockRows(left)==2..<3,"Wrapped fragment click selected only a screen fragment")
        let anchor=MergeWrappedCaret.starts(in:right,row:ranges[2])[1]
        click(right,4,shift:true)
        try require(right.selectedRange()==NSRange(location:anchor,length:ranges[4].location-anchor),"Wrapped Shift origin did not retain clicked fragment start")
        model.setWrapLines(false);try await wait {!model.lineWrapping.isGeometryPending}
        model.setCollapsed(true);try await wait {model.folding.projection.rows.contains {if case .marker = $0{return true};return false}}
        let marker=model.folding.projection.rows.compactMap {row->Int? in if case .marker(let span)=row{return span.lowerBound};return nil}.last!
        try await wait {right.textStorage?.attribute(.mergeFoldMarker,at:ranges[marker].location,effectiveRange:nil) != nil && !model.lineWrapping.isGeometryPending}
        let layout=right.layoutManager!,container=right.textContainer!,clip=right.enclosingScrollView!.contentView
        layout.ensureLayout(for:container)
        let glyph=layout.glyphIndexForCharacter(at:ranges[marker].location),frame=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        clip.scroll(to:clip.constrainBoundsRect(NSRect(origin:NSPoint(x:0,y:frame.minY+right.textContainerOrigin.y),size:clip.bounds.size)).origin)
        right.enclosingScrollView!.reflectScrolledClipView(clip)
        let count=model.folding.projection.rows.count;click(right,marker,clicks:2)
        try await wait {model.folding.projection.rows.count>count}
        model.setCollapsed(false)
        try await wait {!model.lineWrapping.isGeometryPending && right.textStorage?.attribute(.mergeFoldHidden,at:ranges[50].location,effectiveRange:nil)==nil && right.textStorage?.attribute(.mergeFoldMarker,at:ranges[marker].location,effectiveRange:nil)==nil}
        right.scrollRangeToVisible(NSRange(location:0,length:0))
        // Autoscroll retains capture only during the actual owned drag.
        rr.mouseDown(with:event(right,1));let y=right.visibleRect.minY
        rr.mouseDragged(with:event(right,1,.leftMouseDragged,outside:true))
        do {try await wait {right.visibleRect.minY>y && rr.marginAutoScrolling}}
        catch {print("Autoscroll state: before=\(y), after=\(right.visibleRect), dragging=\(rr.marginDragging), timer=\(rr.marginAutoScrolling), size=\(right.enclosingScrollView!.contentSize), frame=\(right.frame), geometryPending=\(model.lineWrapping.isGeometryPending)");throw error}
        rr.mouseUp(with:event(right,1,.leftMouseUp));try require(!rr.marginDragging && !rr.marginAutoScrolling,"Mouse Up left autoscroll running")
        right.scrollRangeToVisible(NSRange(location:0,length:0));rr.mouseDown(with:event(right,1));rr.mouseDragged(with:event(right,1,.leftMouseDragged,outside:true))
        pair.close();try require(!rr.marginDragging && !rr.marginAutoScrolling,"Owner Close retained margin tracking/timer")
        // Three-pane sources and marker-free result share row boundaries.
        let base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt"),theirs=root.appendingPathComponent("theirs.txt")
        for (url,text) in [(base,"head\nbase\nfoot\n"),(mine,"head\nmine\nfoot\n"),(theirs,"head\ntheirs\nfoot\n")] {try Data(text.utf8).write(to:url)}
        let owner=TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine.txt",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs),merge=owner.model
        defer {owner.close()};owner.window!.alphaValue=0;owner.window!.setContentSize(.init(width:1200,height:800));owner.window!.orderFront(nil);merge.load()
        func panes()->[NSTextView] {ThreePaneEngineVerification.textViews(owner.window?.contentView).filter {$0 is MergeContextMenuProviding}}
        try await wait {!merge.busy && !merge.preparing && panes().count==3 && panes().allSatisfy {ruler($0).presentation.symbols.count==4}}
        let result=panes().first {$0.isEditable}!,source=panes().first {!$0.isEditable}!
        click(source,2)
        try require(panes().allSatisfy {blockRows($0)==2..<3} && source.selectedRange().length>0 && result.selectedRange().length==0,"Three-pane source gutter did not preserve distinct peer selection")
        click(result,1);board.clearContents();try require(result.writeSelection(to:board,type:.string) && board.string(forType:.string)=="base","Removed result record gutter Copy lost display payload")
        let baseline=merge.resultPresentation
        click(result,0);result.insertText("new head",replacementRange:result.selectedRange());try await wait {merge.result.hasPrefix("new head\n")}
        merge.undo();try await wait {merge.resultPresentation==baseline}
        click(result,2);try require(blockRows(result)==2..<3 && result.selectedRange().length==0,"Blank conflict slot lost row block")
        if ProcessInfo.processInfo.environment["TURTLEGIT_WRAP_CAPTURE"] != nil {try await MergeMarginVerification.capture(owner.window!,"merge-margin-selection")}
        let snapshot=result.selectedRange(),retiredEvent=event(result,0);owner.close();ruler(result).mouseDown(with:retiredEvent)
        try require(result.selectedRange()==snapshot && !ruler(result).marginDragging,"Retired owner accepted a gutter selection")
        try require(try Data(contentsOf:a)==old && Data(contentsOf:b)==new && String(contentsOf:mine)=="head\nmine\nfoot\n","Gutter selection/history modified input files")
        print("PASS: native margin click/Shift/reverse/drag, peer row boundaries vs active text, Unicode private Copy and exact CRLF edit/Undo, wrapped fragment anchors, fold expansion, autoscroll/Mouse Up/Close, sheet/stale/retired refusal and three-pane removed/conflict slots; owned windows closed")
    }
}
