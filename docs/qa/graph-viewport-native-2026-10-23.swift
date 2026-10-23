// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func graphViewportHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(NSPoint(x:-20000,y:-20000));graphViewportHiddenOrder(place,relativeTo:number)
    }
}

@MainActor @main enum GraphViewportVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {
        if !condition {throw Failure(description:"Graph viewport line \(line): \(message)")}
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func wait(_ ready:()->Bool,line:Int = #line)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Graph viewport readiness timeout at \(line)")
    }
    static func close(_ a:CGFloat,_ b:CGFloat)->Bool {abs(a-b)<1}
    static func same(_ a:NSPoint,_ b:NSPoint)->Bool {close(a.x,b.x) && close(a.y,b.y)}
    static func drained()->Bool {
        RevisionGraphWindowModel.activeOperations==0 && RevisionGraphWindowController.activeExportOperations==0 &&
        RevisionGraphWindowController.activeRetirements==0 && RevisionGraphFindController.activeOperations==0 &&
        RevisionGraphFilterController.activeOperations==0
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),layout=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.GraphViewport."+UUID().uuidString
        let preferences:UserDefaults
        var owners:[RevisionGraphWindowController]=[],sheets:[NSWindow]=[]
        var baselineIndex=Data(),baselineHead=Data(),baselineRefs=Data(),baselineConfig=Data()
        var repository:GitRepository {GitRepository(root:root.appendingPathComponent("repository"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(false,forKey:"UseLibgit2");preferences.set(true,forKey:"ShowRevGraphOverview")}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repository.root,withIntermediateDirectories:true)
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Viewport QA"),("user.email","viewport@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
            try Data("private graph viewport\n".utf8).write(to:repository.root.appendingPathComponent("file.txt"));try await repository.stage(["file.txt"])
            for index in 0..<12 {
                _=try await repository.run(["commit","--allow-empty","-m","Viewport \(index)"])
                _=try await repository.run(["tag","viewport-\(index)"])
            }
            _=try await repository.run(["branch","viewport/"+String(repeating:"wide-label-",count:12)])
            baselineIndex=try Data(contentsOf:repository.root.appendingPathComponent(".git/index"))
            baselineConfig=try Data(contentsOf:repository.root.appendingPathComponent(".git/config"))
            baselineHead=try await repository.run(["rev-parse","HEAD"]).stdout
            baselineRefs=try await repository.run(["show-ref"]).stdout
        }
        func owner()async throws->RevisionGraphWindowController {
            let owner=RevisionGraphWindowController(repository:repository,access:RepositoryAccessLease(url:repository.root),preferences:preferences,layoutExecutable:layout,automaticallyLoad:false)
            owners.append(owner);let window=try unwrap(owner.window,"Actual graph window missing")
            window.setContentSize(NSSize(width:740,height:500));window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
            owner.model.load();try await wait{!owner.model.busy && !owner.model.hasPendingWork}
            try require(owner.model.error==nil && owner.model.nodes.count>=12,"Real private graph failed: \(owner.model.error ?? "missing nodes")")
            owner.update();window.contentView?.layoutSubtreeIfNeeded();owner.update()
            try require(owner.canvas.setZoom(2),"Actual loaded graph rejected initial zoom")
            try require(owner.canvas.bounds.width>owner.scroll.contentSize.width+200 && owner.canvas.bounds.height>owner.scroll.contentSize.height+300,"Authored real graph lacks two-dimensional scroll range")
            try require(window.makeFirstResponder(owner.canvas),"Actual graph canvas refused first responder")
            return owner
        }
        func preserved()async throws {
            let head=try await repository.run(["rev-parse","HEAD"]).stdout,refs=try await repository.run(["show-ref"]).stdout
            let index=try Data(contentsOf:repository.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:repository.root.appendingPathComponent(".git/config"))
            try require(head==baselineHead && refs==baselineRefs && index==baselineIndex && config==baselineConfig,"Viewport interaction changed repository HEAD/refs/index/config")
        }
        func cleanup()async {
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil);sheet.close()}
            for owner in owners {owner.model.cancel();owner.close()}
            for _ in 0..<3000 {if drained() && owners.allSatisfy({!$0.hasPendingWork}){break};try? await Task.sleep(nanoseconds:10_000_000)}
            for window in NSApp.windows {if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil);sheet.close()};window.orderOut(nil);window.close()}
            preferences.removePersistentDomain(forName:suite)
        }
    }
    static func position(_ owner:RevisionGraphWindowController,_ point:NSPoint) {
        let clip=owner.scroll.contentView
        clip.scroll(to:clip.constrainBoundsRect(NSRect(origin:point,size:clip.bounds.size)).origin);owner.scroll.reflectScrolledClipView(clip)
    }
    static func mouse(_ type:NSEvent.EventType,in view:NSView,at point:NSPoint,flags:NSEvent.ModifierFlags=[])->NSEvent {
        NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:flags,timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
    }
    static func key(_ code:UInt16,in window:NSWindow,flags:NSEvent.ModifierFlags=[])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:code==53 ? "\u{1b}":"",charactersIgnoringModifiers:code==53 ? "\u{1b}":"",isARepeat:false,keyCode:code)!
    }
    static func wheel(_ delta:Int32,flags:CGEventFlags)->NSEvent {
        let cg=CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:delta,wheel2:0,wheel3:0)!;cg.flags=flags
        return NSEvent(cgEvent:cg)!
    }
    static func emptyPoint(_ owner:RevisionGraphWindowController)throws->NSPoint {
        let visible=owner.scroll.documentVisibleRect
        for row in 1..<30 {for column in 1..<8 {
            let point=NSPoint(x:visible.minX+CGFloat(column)*visible.width/8,y:visible.minY+CGFloat(row)*visible.height/30)
            if owner.canvas.hit(point)==nil{return point}
        }}
        throw Failure(description:"Authored graph has no visible empty pan surface")
    }
    static func press(_ owner:RevisionGraphWindowController)throws->NSEvent {
        let event=mouse(.leftMouseDown,in:owner.canvas,at:try emptyPoint(owner));owner.canvas.mouseDown(with:event)
        try require(owner.canvas.hasPointerGesture && owner.canvas.pointerCursor == NSCursor.closedHand,"Accepted empty-surface press did not own pan/closed-hand cursor")
        return event
    }
    static func drag(_ owner:RevisionGraphWindowController,from event:NSEvent,dx:CGFloat = -40,dy:CGFloat = 30)->NSEvent {
        NSEvent.mouseEvent(with:.leftMouseDragged,location:NSPoint(x:event.locationInWindow.x+dx,y:event.locationInWindow.y+dy),modifierFlags:[],timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!
    }
    static func zoom(_ c:Context)async throws {
        let owner=try await c.owner(),clip=owner.scroll.contentView,window=owner.window!
        position(owner,NSPoint(x:100,y:300));let before=clip.bounds.origin
        owner.zoomBox.stringValue="150%";owner.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:owner.zoomBox))
        try require(abs(owner.model.zoom-1.5)<0.00001 && same(clip.bounds.origin,NSPoint(x:before.x*0.75,y:before.y*0.75)),"Editable actual combo failed source proportional-origin zoom")
        let buttonOrigin=clip.bounds.origin;owner.perform("zoomOut")
        try require(abs(owner.model.zoom-1.35)<0.00001 && same(clip.bounds.origin,NSPoint(x:buttonOrigin.x*0.9,y:buttonOrigin.y*0.9)),"Toolbar zoom changed top-left instead of scaling the accepted origin")
        let wheelOrigin=clip.bounds.origin;owner.canvas.scrollWheel(with:wheel(1,flags:.maskControl))
        try require(abs(owner.model.zoom-1.5)<0.00001 && same(clip.bounds.origin,NSPoint(x:wheelOrigin.x/0.9,y:wheelOrigin.y/0.9)),"Modifier wheel did not use the same viewport zoom origin")
        let accepted=owner.model.zoom,origin=clip.bounds.origin
        owner.zoomBox.stringValue="not a percentage";owner.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:owner.zoomBox))
        try require(owner.model.zoom==accepted && same(clip.bounds.origin,origin),"Invalid custom zoom changed actual graph viewport")
        _=owner.canvas.setZoom(2);position(owner,NSPoint(x:100,y:400));window.makeFirstResponder(owner.canvas)
        let modifiers:NSEvent.ModifierFlags=[.command,.control,.option,.shift]
        for(code,dx,dy)in[(UInt16(124),CGFloat(20),CGFloat(0)),(123,-20,0),(125,0,20),(126,0,-20),(121,0,clip.bounds.height/2),(116,0,-clip.bounds.height/2)] {
            let old=clip.bounds.origin
            try require(owner.canvas.performNavigationKey(key(code,in:window,flags:modifiers)),"Focused canvas did not consume source navigation key")
            try require(same(clip.bounds.origin,NSPoint(x:old.x+dx,y:old.y+dy)),"Source arrow/half-page key distance changed")
        }
        window.makeFirstResponder(owner.zoomBox);let fieldOrigin=clip.bounds.origin
        try require(!owner.canvas.performNavigationKey(key(125,in:window)) && same(clip.bounds.origin,fieldOrigin),"Graph stole arrow navigation from the actual zoom field")
        window.makeFirstResponder(owner.canvas)
        position(owner,NSPoint(x:100,y:300));let cmdOrigin=clip.bounds.origin
        owner.canvas.scrollWheel(with:wheel(-1,flags:.maskCommand))
        try require(abs(owner.model.zoom-1.8)<0.00001 && same(clip.bounds.origin,NSPoint(x:cmdOrigin.x*0.9,y:cmdOrigin.y*0.9)),"Command wheel origin differs from Control wheel")
        owner.perform("fit");try require(owner.model.zoom>0 && owner.model.zoom<=2,"Fit did not use guarded zoom bounds")
    }
    static func gestures(_ c:Context)async throws {
        let owner=try await c.owner(),clip=owner.scroll.contentView,window=owner.window!,overview=owner.overview
        position(owner,NSPoint(x:100,y:300));let before=clip.bounds.origin,event=try press(owner)
        let moved=drag(owner,from:event);owner.canvas.mouseDragged(with:moved)
        try require(same(clip.bounds.origin,NSPoint(x:before.x+40,y:before.y+30)),"Accepted canvas pan failed source window-coordinate displacement")
        owner.canvas.mouseUp(with:moved);let released=clip.bounds.origin
        owner.canvas.mouseDragged(with:event)
        try require(!owner.canvas.hasPointerGesture && owner.canvas.pointerCursor == NSCursor.arrow && same(clip.bounds.origin,released),"Orphan canvas drag moved graph or retained closed hand")
        _=try press(owner);try require(window.performKeyEquivalent(with:key(53,in:window)),"Actual window Escape did not cancel accepted canvas pan")
        try require(!owner.canvas.hasPointerGesture && owner.canvas.pointerCursor == NSCursor.arrow,"Escape retained canvas gesture/cursor")
        owner.canvas.mouseDragged(with:moved);try require(same(clip.bounds.origin,released),"Delayed post-Escape canvas drag revived")
        owner.update();try require(!overview.isHidden && overview.bounds.width>0 && overview.pointerCursor == NSCursor.openHand,"Actual overview is unavailable or has incorrect available cursor")
        let point=NSPoint(x:overview.bounds.width*0.65,y:overview.bounds.height*0.6)
        let orphan=mouse(.leftMouseDragged,in:overview,at:point);let beforeOrphan=clip.bounds.origin
        overview.mouseDragged(with:orphan);try require(same(clip.bounds.origin,beforeOrphan) && !overview.hasPointerGesture,"Orphan overview drag recentered graph")
        let down=mouse(.leftMouseDown,in:overview,at:point);overview.mouseDown(with:down)
        try require(overview.hasPointerGesture && overview.pointerCursor == NSCursor.closedHand,"Overview press did not own drag cursor")
        let marker=overview.viewportRect
        try require(close(marker.midX,point.x) && close(marker.midY,point.y),"Overview press failed inverse viewport mapping including native graph margin")
        let dragPoint=NSPoint(x:overview.bounds.width*0.55,y:overview.bounds.height*0.5),beforeOverviewDrag=clip.bounds.origin
        overview.mouseDragged(with:mouse(.leftMouseDragged,in:overview,at:dragPoint))
        try require(!same(clip.bounds.origin,beforeOverviewDrag) && close(overview.viewportRect.midX,dragPoint.x) && close(overview.viewportRect.midY,dragPoint.y),"Accepted overview drag failed actual viewport mapping")
        window.makeFirstResponder(owner.canvas);_=try press(owner)
        try require(!overview.hasPointerGesture && owner.canvas.hasPointerGesture,"Cross-view canvas press kept the old overview gesture")
        overview.mouseDown(with:down)
        try require(!owner.canvas.hasPointerGesture && overview.hasPointerGesture,"Cross-view overview press kept the old canvas gesture")
        window.makeFirstResponder(owner.zoomBox)
        try require(window.performKeyEquivalent(with:key(53,in:window)),"Window Escape while field-focused did not cancel overview drag")
        try require(!overview.hasPointerGesture && overview.pointerCursor == NSCursor.openHand,"Overview Escape kept closed hand")
        let stopped=clip.bounds.origin;overview.mouseDragged(with:orphan)
        try require(same(clip.bounds.origin,stopped),"Post-Escape overview event revived old receipt")
        overview.mouseDown(with:down);let accepted=clip.bounds.origin
        owner.model.confirmingQuit=true;owner.update();overview.mouseDragged(with:orphan)
        try require(!overview.hasPointerGesture && overview.pointerCursor == NSCursor.arrow && same(clip.bounds.origin,accepted),"Quit modal fence retained overview drag")
        owner.model.confirmingQuit=false;owner.update();overview.mouseDragged(with:orphan)
        try require(same(clip.bounds.origin,accepted),"Cancelled Quit revived stale overview drag")
        window.makeFirstResponder(owner.canvas);_=try press(owner);owner.perform("zoomOut");let zoomed=clip.bounds.origin
        owner.canvas.mouseDragged(with:moved);try require(!owner.canvas.hasPointerGesture && same(clip.bounds.origin,zoomed),"Zoom replacement revived a stale canvas receipt")
    }
    static func retirement(_ c:Context)async throws {
        let owner=try await c.owner(),window=owner.window!,clip=owner.scroll.contentView,overview=owner.overview
        position(owner,NSPoint(x:100,y:300));let down=try press(owner),late=drag(owner,from:down)
        let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:160,height:80),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;c.sheets.append(sheet)
        window.beginSheet(sheet,completionHandler:{_ in});owner.canvas.mouseDragged(with:late)
        try require(!owner.canvas.hasPointerGesture && owner.canvas.pointerCursor == NSCursor.arrow,"Real attached sheet did not cancel canvas pan")
        let modalOrigin=clip.bounds.origin;window.makeFirstResponder(owner.canvas)
        try require(window.firstResponder === owner.canvas,"Actual sheet test lost the parent canvas responder")
        owner.canvas.keyDown(with:key(125,in:window));owner.canvas.keyDown(with:key(121,in:window))
        try require(same(clip.bounds.origin,modalOrigin),"Blocked canvas keyDown fell through to native scroll view behind actual sheet")
        let modalZoom=owner.model.zoom
        owner.perform("zoomOut");owner.zoomBox.stringValue="50%";owner.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:owner.zoomBox));owner.canvas.scrollWheel(with:wheel(-1,flags:.maskControl))
        try require(owner.model.zoom==modalZoom && same(clip.bounds.origin,modalOrigin),"Actual modal sheet allowed button/combo/wheel viewport mutation")
        window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil);try await wait{sheet.sheetParent==nil && window.attachedSheet==nil};owner.update()
        let afterSheet=clip.bounds.origin;owner.canvas.mouseDragged(with:late)
        try require(same(clip.bounds.origin,afterSheet),"Closed actual modal sheet revived the old pan receipt")
        _=try press(owner);window.setContentSize(NSSize(width:800,height:540));window.contentView?.layoutSubtreeIfNeeded();owner.windowDidResize(Notification(name:NSWindow.didResizeNotification,object:window))
        let resized=clip.bounds.origin;owner.canvas.mouseDragged(with:late)
        try require(!owner.canvas.hasPointerGesture && same(clip.bounds.origin,resized),"Viewport resize accepted old pan dimensions")
        owner.update();let overviewPoint=NSPoint(x:overview.bounds.midX,y:overview.bounds.midY)
        let overviewDown=mouse(.leftMouseDown,in:overview,at:overviewPoint),overviewLate=mouse(.leftMouseDragged,in:overview,at:NSPoint(x:overviewPoint.x+4,y:overviewPoint.y+4))
        overview.mouseDown(with:overviewDown);try require(overview.hasPointerGesture,"Replacement test never accepted overview gesture")
        let generation=owner.model.generation;owner.model.load();try await wait{!owner.model.busy && !owner.model.hasPendingWork}
        try require(owner.model.generation != generation && owner.model.error==nil,"Real graph reload did not replace the generation")
        let replaced=clip.bounds.origin;overview.mouseDragged(with:overviewLate)
        try require(!overview.hasPointerGesture && same(clip.bounds.origin,replaced),"Actual graph replacement revived stale overview drag")
        window.makeFirstResponder(owner.canvas);_=try press(owner)
        var closed=0;owner.onClosed={closed+=1};owner.close();try await wait{closed==1 && !owner.hasPendingWork}
        let finalOrigin=clip.bounds.origin
        owner.canvas.mouseDragged(with:late);overview.mouseDragged(with:overviewLate)
        let oldZoom=owner.model.zoom
        try require(!owner.canvas.setZoom(1.5) && owner.model.zoom==oldZoom && !owner.canvas.hasPointerGesture && !overview.hasPointerGesture && same(clip.bounds.origin,finalOrigin),"Retired graph accepted late viewport callbacks")
        try require(owner.canvas.pointerCursor == NSCursor.arrow && overview.pointerCursor == NSCursor.arrow,"Closed owner retained a hand cursor")
    }
    static func main()async {
        let oldCursor=NSCursor.current;defer{oldCursor.set()}
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        if let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.graphViewportHiddenOrder(_:relativeTo:))){method_exchangeImplementations(original,hidden)}
        let context=Context(),kind=CommandLine.arguments[4]
        do {
            try await context.seed()
            switch kind {case "zoom":try await zoom(context);case "gestures":try await gestures(context);case "retirement":try await retirement(context);default:throw Failure(description:"Unknown viewport case")}
            try await context.preserved();await context.cleanup()
            try require(drained() && context.owners.allSatisfy({!$0.hasPendingWork}) && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil}),"Owned viewport windows/helpers did not drain")
            print("PASS: Graph viewport family "+kind);fflush(stdout)
        } catch {await context.cleanup();oldCursor.set();fputs("Graph viewport failed: \(error)\n",stderr);fflush(stderr);exit(1)}
    }
}
