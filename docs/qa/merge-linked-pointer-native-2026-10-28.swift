// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Local NSEvents enter the actual scroll-view override; no system event posting,
/// Accessibility pointer injection or user pasteboard is involved.
@MainActor enum MergeLinkedPointerVerification {
    typealias Base=MergePaneInputVerification
    typealias Viewport=MergeViewportVerification
    static func require(_ value:Bool,_ message:String)throws{try Base.require(value,message)}
    static func wheel(x:Int32=0,y:Int32=0,flags:CGEventFlags=[],precise:Bool=true,phase:Int64=0,momentum:Int64=0)throws->NSEvent {
        guard let cg=CGEvent(scrollWheelEvent2Source:nil,units:precise ? .pixel:.line,wheelCount:2,wheel1:y,wheel2:x,wheel3:0) else {throw Base.Failure(description:"Private wheel CGEvent unavailable")}
        cg.flags=flags
        cg.setIntegerValueField(.scrollWheelEventScrollPhase,value:phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase,value:momentum)
        guard let event=NSEvent(cgEvent:cg) else {throw Base.Failure(description:"Private wheel NSEvent unavailable")}
        try require(event.type == .scrollWheel,"Private event is not a native scroll wheel")
        try require(event.hasPreciseScrollingDeltas==precise,"Native event precision differs from requested units")
        return event
    }
    static func close(_ a:CGFloat,_ b:CGFloat)->Bool{abs(a-b)<=0.5}
    static func expect(_ scrolls:[NSScrollView],_ expected:[CGPoint],_ message:String)throws {
        let actual=scrolls.map{$0.contentView.bounds.origin}
        try require(actual.count==expected.count && zip(actual,expected).allSatisfy{pair in close(pair.0.x,pair.1.x) && close(pair.0.y,pair.1.y)},message+" expected=\(expected) actual=\(actual)")
    }
    static func constrained(_ scroll:NSScrollView,_ value:CGPoint)->CGPoint {
        scroll.contentView.constrainBoundsRect(NSRect(origin:value,size:scroll.contentView.bounds.size)).origin
    }
    static func leading(_ scroll:NSScrollView)->CGFloat {constrained(scroll,CGPoint(x:-1_000_000,y:scroll.contentView.bounds.minY)).x}
    static func set(_ scroll:NSScrollView,_ value:CGPoint) {
        scroll.contentView.scroll(to:constrained(scroll,value));scroll.reflectScrolledClipView(scroll.contentView)
    }
    static func prepare(_ panes:[NSTextView],origins:[CGPoint]) {
        // Set origins without notification delivery: intentionally divergent
        // peers distinguish relative wheel movement from absolute thumb sync.
        let scrolls=panes.compactMap{$0.enclosingScrollView}
        for scroll in scrolls {scroll.contentView.postsBoundsChangedNotifications=false}
        for (scroll,origin) in zip(scrolls,origins){set(scroll,origin)}
        for scroll in scrolls {MergePointerScrolling.captureOrigin(scroll);scroll.contentView.postsBoundsChangedNotifications=true}
    }
    static func expectedWheel(_ event:NSEvent,panes:[NSTextView],before:[CGPoint],wrapped:Bool)->[CGPoint] {
        let swapped = !event.modifierFlags.intersection([.shift,.control]).isEmpty
        let dx=swapped ? event.scrollingDeltaY:event.scrollingDeltaX
        let dy=swapped ? -event.scrollingDeltaX:event.scrollingDeltaY
        return zip(panes,before).map{view,origin in
            let font=view.font!,line=view.layoutManager!.defaultLineHeight(for:font)
            let cell=("X" as NSString).size(withAttributes:[.font:font]).width
            let x=wrapped ? origin.x:origin.x-dx*(event.hasPreciseScrollingDeltas ? 1:max(1,cell))
            let y=origin.y-dy*(event.hasPreciseScrollingDeltas ? 1:max(1,line))
            return constrained(view.enclosingScrollView!,CGPoint(x:x,y:y))
        }
    }
    static func exercise(_ window:NSWindow,ready:()->Bool,dirty:()->Bool,wrapped:Bool,refreshAssertions:([NSTextView])throws->Void)async throws {
        try await Base.wait{ready()}
        let panes=Viewport.views(window).sorted{(($0 as? MergeFindProviding)?.mergeFindPaneID ?? 0) < (($1 as? MergeFindProviding)?.mergeFindPaneID ?? 0)},scrolls=panes.compactMap{$0.enclosingScrollView}
        try require(panes.count>=2 && scrolls.count==panes.count,"Pointer family lacks actual peer editor clips")
        try require(scrolls.allSatisfy{$0 is MergePointerScrollView},"Actual editor did not install managed pointer scroll view")
        for pane in panes {pane.layoutManager?.ensureLayout(for:pane.textContainer!);pane.setSelectedRange(NSRange(location:2,length:0))}
        window.makeFirstResponder(panes.last)
        let snapshot=Viewport.Snapshot(panes,window:window),wasDirty=dirty()
        let origins=scrolls.indices.map{CGPoint(x:40+CGFloat($0)*25,y:90+CGFloat($0)*35)}
        for event in [try wheel(y:-17),try wheel(x:-11),try wheel(x:-7,y:-13),try wheel(y:-15,flags:.maskShift),try wheel(y:-15,flags:.maskControl),try wheel(x:-15,flags:.maskControl),try wheel(y:-15,flags:[.maskShift,.maskControl]),try wheel(x:-1,y:-1,precise:false)] {
            prepare(panes,origins:origins)
            let before=scrolls.map{$0.contentView.bounds.origin},expected=expectedWheel(event,panes:panes,before:before,wrapped:wrapped)
            scrolls[0].scrollWheel(with:event)
            try expect(scrolls,expected,"Relative wheel failed own-origin/clamp or applied peer feedback twice")
            try snapshot.assertUnchanged(panes,window:window);try require(dirty()==wasDirty,"Pointer wheel dirtied document")
            try refreshAssertions(panes)
            await Task.yield()
            try expect(scrolls,expected,"Deferred clip notification repeated managed wheel movement")
        }
        prepare(panes,origins:origins)
        let horizontalControl=try wheel(x:-8,flags:.maskControl),directionBefore=scrolls.map{$0.contentView.bounds.origin}
        scrolls[0].scrollWheel(with:horizontalControl)
        try require(horizontalControl.scrollingDeltaX<0 && horizontalControl.scrollingDeltaY==0,"Directional fixture did not deliver a rightward native horizontal wheel")
        for (scroll,origin) in zip(scrolls,directionBefore) {
            try require(scroll.contentView.bounds.minY<origin.y && close(scroll.contentView.bounds.minX,origin.x),"Control-horizontal wheel used the opposite source vertical direction or also moved X")
        }
        prepare(panes,origins:origins)
        let textEvent=try wheel(x:-6,y:-8),textBefore=scrolls.map{$0.contentView.bounds.origin}
        panes[0].scrollWheel(with:textEvent)
        try expect(scrolls,expectedWheel(textEvent,panes:panes,before:textBefore,wrapped:wrapped),"Native text responder forwarded wheel twice or bypassed linked route")
        try snapshot.assertUnchanged(panes,window:window)
        // Momentum belongs to a stream admitted by a real began event. An
        // unknown continuation must not acquire a current editor by itself.
        prepare(panes,origins:origins)
        var phasedBefore=scrolls.map{$0.contentView.bounds.origin}
        scrolls[0].scrollWheel(with:try wheel(y:-7,momentum:1))
        try expect(scrolls,phasedBefore,"Unknown momentum began without an admitted gesture")
        for event in [try wheel(y:-4,phase:1),try wheel(y:-5,phase:2),try wheel(phase:4),try wheel(y:-7,momentum:1),try wheel(momentum:3)] {
            phasedBefore=scrolls.map{$0.contentView.bounds.origin}
            scrolls[0].scrollWheel(with:event)
            try expect(scrolls,expectedWheel(event,panes:panes,before:phasedBefore,wrapped:wrapped),"Admitted native gesture/momentum did not move each peer exactly once")
        }
        phasedBefore=scrolls.map{$0.contentView.bounds.origin}
        scrolls[0].scrollWheel(with:try wheel(y:-8,phase:2))
        try expect(scrolls,phasedBefore,"Ended momentum stream accepted a late continuation")
        // Local wheel at an exhausted source still advances a peer which has
        // room, preserving relative movement rather than copying source bounds.
        let maxY=constrained(scrolls[0],CGPoint(x:60,y:1_000_000)).y
        prepare(panes,origins:[CGPoint(x:60,y:maxY)]+scrolls.dropFirst().map{_ in CGPoint(x:80,y:60)})
        let event=try wheel(y:-19),before=scrolls.map{$0.contentView.bounds.origin}
        scrolls[0].scrollWheel(with:event)
        try expect(scrolls,expectedWheel(event,panes:panes,before:before,wrapped:wrapped),"Clamped source prevented peer wheel progress")
        // Native thumb/clip movement is absolute on Y and, when unwrapped,
        // on logical character X. This is an actual notification, not the model
        // callback invoked directly by the fixture.
        prepare(panes,origins:origins)
        let thumbBefore=scrolls.map{$0.contentView.bounds.origin}
        let source=scrolls[0],sourceView=panes[0]
        let old=source.contentView.bounds.origin
        let target=constrained(source,CGPoint(x:wrapped ? old.x:old.x+24,y:old.y+31))
        set(source,target)
        NotificationCenter.default.post(name:NSView.boundsDidChangeNotification,object:source.contentView)
        let sourceCell=max(1,("X" as NSString).size(withAttributes:[.font:sourceView.font!]).width)
        let expected=panes.enumerated().map{index,pane->CGPoint in
            if index==0{return target}
            let scroll=scrolls[index],cell=max(1,("X" as NSString).size(withAttributes:[.font:pane.font!]).width)
            return constrained(scroll,CGPoint(x:wrapped ? thumbBefore[index].x:leading(scroll)+(target.x-leading(source))/sourceCell*cell,y:target.y))
        }
        try expect(scrolls,expected,"Native thumb clip observer failed absolute peer coupling")
        await Task.yield();try expect(scrolls,expected,"Absolute clip feedback drifted peer bounds")
        try snapshot.assertUnchanged(panes,window:window);try require(dirty()==wasDirty,"Thumb movement changed document")
        try refreshAssertions(panes)
        // Hidden peer panes do not take part in relative movement.
        let peer=panes[1],peerScroll=scrolls[1],hiddenBefore=peerScroll.contentView.bounds.origin
        peer.isHidden=true
        defer{peer.isHidden=false}
        let hiddenEvent=try wheel(x:-9,y:-9)
        source.scrollWheel(with:hiddenEvent)
        try require(peerScroll.contentView.bounds.origin==hiddenBefore,"Hidden pane accepted linked pointer movement")
    }
    static func blocked(_ window:NSWindow,ready:()->Bool,setBusy:(Bool)->Void,setQuit:(Bool)->Void,foreign:(NSEvent,NSScrollView)->Void)async throws {
        try await Base.wait{ready()}
        let panes=Viewport.views(window),scrolls=panes.compactMap{$0.enclosingScrollView},event=try wheel(x:-7,y:-9)
        try require(!scrolls.isEmpty,"Pointer ownership fixture has no live view")
        for kind in 0..<3 {
            let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:180,height:80),styleMask:.titled,backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false
            if kind==0{setBusy(true)}else if kind==1{setQuit(true)}else{window.beginSheet(sheet,completionHandler:{_ in})}
            let before=scrolls.map{$0.contentView.bounds.origin}
            scrolls[0].scrollWheel(with:event)
            try expect(scrolls,before,"Busy/Quit/sheet owner accepted pointer wheel")
            if kind==0{setBusy(false)}else if kind==1{setQuit(false)}else{window.endSheet(sheet,returnCode:.cancel);sheet.close();try await Base.wait{window.attachedSheet==nil}}
            try await Base.wait{ready()}
        }
        // No event arrives during the blocked interval. A generation receipt,
        // rather than merely checking current busy/sheet state, must retire it.
        for sheetInterval in [false,true] {
            scrolls[0].scrollWheel(with:try wheel(y:-4,phase:1))
            if sheetInterval {
                let child=NSWindow(contentRect:NSRect(x:0,y:0,width:180,height:80),styleMask:.titled,backing:.buffered,defer:false);child.isReleasedWhenClosed=false
                window.beginSheet(child,completionHandler:{_ in});window.endSheet(child,returnCode:.cancel);child.close()
                try await Base.wait{window.attachedSheet==nil && child.sheetParent==nil}
            }else{setBusy(true);setBusy(false)}
            try await Base.wait{ready()}
            let retiredOrigin=scrolls.map{$0.contentView.bounds.origin}
            scrolls[0].scrollWheel(with:try wheel(y:-12,momentum:2))
            try expect(scrolls,retiredOrigin,"Gesture revived after busy/sheet interval with no intervening pointer event")
            let begin=try wheel(y:-4,phase:1)
            scrolls[0].scrollWheel(with:begin)
            try expect(scrolls,expectedWheel(begin,panes:panes,before:retiredOrigin,wrapped:false),"Fresh gesture failed to recover after owner gate retired old stream")
        }
        let before=scrolls.map{$0.contentView.bounds.origin}
        foreign(event,MergePointerScrollView())
        try expect(scrolls,before,"Unregistered source drove current linked peers")
    }
    static func independentVertical(_ source:NSScrollView,panes:[NSTextView],window:NSWindow)async throws->Bool {
        let scrolls=panes.compactMap{$0.enclosingScrollView}
        try require(scrolls.count>=3 && scrolls.contains(where:{$0 === source}),"Unmapped pane missing from actual peer set")
        for pane in panes {pane.layoutManager?.ensureLayout(for:pane.textContainer!)}
        let snapshot=Viewport.Snapshot(panes,window:window)
        let origins=scrolls.indices.map{CGPoint(x:35+CGFloat($0)*12,y:70+CGFloat($0)*17)}
        prepare(panes,origins:origins)
        // Production identity preparation may drain a queued reflow and restore
        // its old reading anchors. Finish that setup before capturing the input
        // baseline, then establish the intentional independent test origins.
        guard let native=source as? MergePointerScrollView,let sourceIdentity=native.pointerIdentity?() else{throw Base.Failure(description:"Independent pane is not currently eligible after native geometry preparation")}
        prepare(panes,origins:origins)
        let before=scrolls.map{$0.contentView.bounds.origin},event=try wheel(x:-9,y:-15)
        source.scrollWheel(with:event)
        let expected=scrolls.enumerated().map{index,scroll in constrained(scroll,CGPoint(x:before[index].x-event.scrollingDeltaX,y:before[index].y-(scroll === source ? event.scrollingDeltaY:0)))}
        try expect(scrolls,expected,"Raw/Base/P4 wheel imposed an unsupported vertical row map or lost horizontal linkage; sourceIdentity=\(String(describing:sourceIdentity)),sourceAttached=\(source.window === window),sourceHidden=\(source.isHiddenOrHasHiddenAncestor)")
        let old=scrolls.map{$0.contentView.bounds.origin},target=constrained(source,CGPoint(x:source.contentView.bounds.minX+21,y:source.contentView.bounds.minY+23))
        let horizontalMoved=target.x != source.contentView.bounds.minX
        set(source,target);NotificationCenter.default.post(name:NSView.boundsDidChangeNotification,object:source.contentView)
        let font=(source.documentView as! NSTextView).font!,cell=max(1,("X" as NSString).size(withAttributes:[.font:font]).width)
        let thumb=scrolls.enumerated().map{index,scroll->CGPoint in
            if scroll === source{return target}
            let peerFont=(scroll.documentView as! NSTextView).font!,peerCell=max(1,("X" as NSString).size(withAttributes:[.font:peerFont]).width)
            return constrained(scroll,CGPoint(x:horizontalMoved ? leading(scroll)+(target.x-leading(source))/cell*peerCell:old[index].x,y:old[index].y))
        }
        try expect(scrolls,thumb,"Unmapped pane thumb invented absolute Y coupling or omitted logical X coupling")
        await Task.yield();try expect(scrolls,thumb,"Unmapped pane scroll notification fed back")
        try snapshot.assertUnchanged(panes,window:window)
        return horizontalMoved
    }
    static func differingMetrics(_ window:NSWindow,settle:()->Void,ready:()->Bool) throws {
        let panes=Viewport.views(window),scrolls=panes.compactMap{$0.enclosingScrollView}
        guard panes.count>=2,let oldFont=panes[1].font else{throw Base.Failure(description:"Metric comparison panes missing")}
        let snapshot=Viewport.Snapshot(panes,window:window)
        let oldInsets=scrolls[1].contentView.contentInsets
        defer {panes[1].font=oldFont;scrolls[1].contentView.contentInsets=oldInsets}
        panes[1].font=NSFont.monospacedSystemFont(ofSize:oldFont.pointSize+4,weight:.regular)
        var inset=oldInsets;inset.left+=13;scrolls[1].contentView.contentInsets=inset
        panes[1].layoutManager?.ensureLayout(for:panes[1].textContainer!)
        // Font assignment edits NSTextStorage and queues real wrap geometry.
        // Drain that setup before attempting an eligible native thumb input.
        settle();try require(ready(),"Metric fixture attempted thumb input before native geometry settled")
        prepare(panes,origins:scrolls.map{CGPoint(x:leading($0)+35,y:80)})
        let source=scrolls[0],target=constrained(source,CGPoint(x:leading(source)+53,y:80))
        try require(!close(leading(source),leading(scrolls[1])),"Asymmetric inset fixture did not produce different native leading origins")
        set(source,target);NotificationCenter.default.post(name:NSView.boundsDidChangeNotification,object:source.contentView)
        let sourceCell=max(1,("X" as NSString).size(withAttributes:[.font:panes[0].font!]).width)
        for (pane,scroll) in zip(panes,scrolls) {
            let cell=max(1,("X" as NSString).size(withAttributes:[.font:pane.font!]).width)
            let expected=constrained(scroll,CGPoint(x:leading(scroll)+(target.x-leading(source))/sourceCell*cell,y:target.y))
            try require(close(scroll.contentView.bounds.minX,expected.x),"Absolute horizontal coupling counted gutter/inset as text or ignored peer font metrics: actual=\(scroll.contentView.bounds),expected=\(expected),leading=\(leading(scroll)),source=\(source.contentView.bounds),sourceLeading=\(leading(source)),font=\(pane.font!.pointSize),ready=\(ready())")
        }
        prepare(panes,origins:scrolls.map{CGPoint(x:leading($0),y:80)})
        let before=scrolls.map{$0.contentView.bounds.origin}
        scrolls[0].scrollWheel(with:try wheel(x:30))
        try expect(scrolls,before,"Linked horizontal wheel scrolled before per-pane leading inset")
        try snapshot.assertUnchanged(panes,window:window)
    }
    static func replacePane(_ owner:FileComparisonWindowController)async throws {
        guard let window=owner.window else{throw Base.Failure(description:"Replacement owner unavailable")}
        let beforePanes=Viewport.views(window),retained=beforePanes.compactMap{$0.enclosingScrollView}
        try require(retained.count==2,"Replacement fixture needs initial two panes")
        // A real phased stream is admitted before changing the presentation.
        let begin=try wheel(y:-9,phase:1)
        try require(begin.phase.contains(.began),"Private wheel did not retain native began phase")
        retained[0].scrollWheel(with:begin)
        owner.model.switchPaneMode(true)
        try await Base.wait{owner.model.onePaneActive && owner.model.canScrollViewport && Viewport.views(window).count==1}
        let live=Viewport.views(window).compactMap{$0.enclosingScrollView}
        let all=retained+live,settled=all.map{$0.contentView.bounds.origin}
        let momentum=try wheel(y:-15,momentum:1)
        try require(momentum.momentumPhase.contains(.began),"Private wheel did not retain native momentum phase")
        retained[0].scrollWheel(with:momentum)
        try expect(all,settled,"Replaced pane's momentum stream drove old or current peers")
        owner.model.switchPaneMode(false)
        try await Base.wait{!owner.model.onePaneActive && owner.model.canScrollViewport && Viewport.views(window).count==2}
        let current=Viewport.views(window).compactMap{$0.enclosingScrollView},origin=current.map{$0.contentView.bounds.origin}
        // A continuation without a new begin cannot attach to the new views.
        current[0].scrollWheel(with:try wheel(y:-12,phase:2))
        try expect(current,origin,"Unknown changed phase was admitted after pane replacement")
    }
    static func comparePresentation(_ model:FileComparisonWindowModel,_ panes:[NSTextView])throws {
        for pane in panes {
            let side=(pane as? MergeFindProviding)?.mergeFindPaneID == 1
            try require(model.previewHorizontalOffsets[side]==pane.enclosingScrollView?.contentView.bounds.minX,"Compare line-preview offset did not follow linked horizontal movement")
        }
        let primary=panes.first{($0 as? MergeFindProviding)?.mergeFindPaneID==1}
        try require(model.locatorViewport==MergeLocatorScrolling.viewport(primary?.enclosingScrollView),"Compare locator viewport is stale after linked movement")
    }
    static func mergePresentation(_ model:TextConflictWindowModel,_ panes:[NSTextView])throws {
        for pane in panes {
            let id=(pane as? MergeFindProviding)?.mergeFindPaneID ?? 0
            if id==1 || id==2 {
                try require(model.previewHorizontalOffsets[id==2]==pane.enclosingScrollView?.contentView.bounds.minX,"Merge line-preview offset did not follow linked horizontal movement")
            }
        }
        let primary=panes.first{($0 as? MergeFindProviding)?.mergeFindPaneID==1}
        try require(model.locatorViewport==MergeLocatorScrolling.viewport(primary?.enclosingScrollView),"Merge locator viewport is stale after linked movement")
    }
    static func verify()async throws {
        let fixture=try Base.Fixture()
        do {
            let text=Base.contents(),pair=try await fixture.pair("pointer-pair",text.0,text.1)
            guard let pairWindow=pair.window else{throw Base.Failure(description:"Compare pointer window missing")}
            try await exercise(pairWindow,ready:{pair.model.canScrollViewport},dirty:{pair.model.dirty},wrapped:false,refreshAssertions:{try comparePresentation(pair.model,$0)})
            try differingMetrics(pairWindow,settle:{pair.model.lineWrapping.prepareForInput()},ready:{pair.model.canScrollViewport})
            try await blocked(pairWindow,ready:{pair.model.canScrollViewport},setBusy:{pair.model.busy=$0},setQuit:{pair.model.confirmingQuit=$0},foreign:{pair.model.scrollPointer($0,from:$1)})
            try await replacePane(pair)
            pair.model.setWrapLines(true)
            try await Base.wait{pair.model.canScrollViewport && Base.wrapReady(Viewport.views(pairWindow),wrapped:true)}
            try await exercise(pairWindow,ready:{pair.model.canScrollViewport},dirty:{pair.model.dirty},wrapped:true,refreshAssertions:{try comparePresentation(pair.model,$0)})
            let merge=try await fixture.merge("pointer-merge",text.0,text.1)
            guard let mergeWindow=merge.window else{throw Base.Failure(description:"Merge pointer window missing")}
            try await exercise(mergeWindow,ready:{merge.model.canScrollViewport},dirty:{merge.model.dirty},wrapped:false,refreshAssertions:{try mergePresentation(merge.model,$0)})
            try await blocked(mergeWindow,ready:{merge.model.canScrollViewport},setBusy:{merge.model.busy=$0},setQuit:{merge.model.confirmingQuit=$0},foreign:{merge.model.scrollPointer($0,from:$1)})
            merge.model.setWrapLines(true)
            try await Base.wait{merge.model.canScrollViewport && Base.wrapReady(Viewport.views(mergeWindow),wrapped:true)}
            try await exercise(mergeWindow,ready:{merge.model.canScrollViewport},dirty:{merge.model.dirty},wrapped:true,refreshAssertions:{try mergePresentation(merge.model,$0)})
            merge.model.setWrapLines(false)
            try await Base.wait{merge.model.canScrollViewport && Base.wrapReady(Viewport.views(mergeWindow),wrapped:false)}
            merge.model.showBase=true
            try await Base.wait{MergeMarkedWordInterface.panes(in:mergeWindow.contentView).filter{!$0.isHiddenOrHasHiddenAncestor}.count==4 && merge.model.canScrollViewport}
            let classic=MergeMarkedWordInterface.panes(in:mergeWindow.contentView).filter{!$0.isHiddenOrHasHiddenAncestor}
            guard let base=merge.model.p4Scroll(.base),let baseView=base.documentView as? NSTextView,classic.contains(where:{$0 === baseView}) else{throw Base.Failure(description:"Classic Base is not the registered native Base presentation")}
            _ = try await independentVertical(base,panes:classic,window:mergeWindow)
            let baseOrigin=base.contentView.bounds.origin
            merge.model.showBase=false
            base.scrollWheel(with:try wheel(y:-17))
            try require(base.contentView.bounds.origin==baseOrigin,"Immediately hidden Base accepted pointer input")
            fixture.prefs.set(true,forKey:"TurtleGit.Comparison.CurvedInterface");merge.model.objectWillChange.send()
            try await Base.wait{P4MergePane.allCases.allSatisfy{pane in guard let scroll=merge.model.p4Scroll(pane) as? MergePointerScrollView else{return false};return scroll.window === mergeWindow && scroll.borderType == .noBorder && scroll.pointerIdentity?() != nil} && merge.model.canScrollViewport}
            let p4=P4MergePane.allCases.compactMap{merge.model.p4Scroll($0)?.documentView as? NSTextView}
            try require(p4.count==4,"P4 pointer fixture lacks four native panes")
            var coupledSources=Set<P4MergePane>()
            for pane in P4MergePane.allCases {
                guard let source=merge.model.p4Scroll(pane) else{throw Base.Failure(description:"P4 source unavailable")}
                if try await independentVertical(source,panes:p4,window:mergeWindow) {coupledSources.insert(pane)}
            }
            try require([P4MergePane.base,.theirs,.mine].allSatisfy{coupledSources.contains($0)},"Long P4 source panes did not actually exercise absolute horizontal coupling")
            let retained=Viewport.views(pairWindow).compactMap{$0.enclosingScrollView}
            pair.close();try await Base.wait{pairWindow.isVisible==false}
            let before=retained.map{$0.contentView.bounds.origin}
            retained.first?.scrollWheel(with:try wheel(y:-25))
            try expect(retained,before,"Retired Compare pointer callback revived old clips")
            try await fixture.cleanup()
        }catch{let error=error;try await fixture.cleanup();throw error}
        print("PASS: linked pointer scroll relative/absolute routing, clamps, wrap, ownership and unchanged document state")
    }
}
