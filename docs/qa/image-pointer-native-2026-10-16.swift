import AppKit
import SwiftUI
import TurtleGitCore

struct ImagePointerVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Image pointer timeout at line \(line)")
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    static func png(_ width:Int,_ height:Int,_ color:NSColor)->Data {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        color.setFill();NSRect(x:0,y:0,width:width,height:height).fill();NSColor.white.setFill();for x in stride(from:0,to:width,by:200) {for y in stride(from:0,to:height,by:200) {NSRect(x:x+50,y:y+50,width:75,height:75).fill()}}
        NSGraphicsContext.restoreGraphicsState();return bitmap.representation(using:.png,properties:[:])!
    }
    @MainActor static func mouse(_ type:NSEvent.EventType,_ canvas:NSView,_ point:CGPoint,_ flags:NSEvent.ModifierFlags = [])->NSEvent {
        NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:flags,timestamp:0,windowNumber:canvas.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    @MainActor static func drag(_ canvas:NSView,_ flags:NSEvent.ModifierFlags = []) {
        let origin=canvas.visibleRect.origin
        canvas.mouseDown(with:mouse(.leftMouseDown,canvas,CGPoint(x:origin.x+120,y:origin.y+120),flags))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,canvas,CGPoint(x:origin.x+80,y:origin.y+90),flags))
        canvas.mouseUp(with:mouse(.leftMouseUp,canvas,CGPoint(x:origin.x+80,y:origin.y+90),flags))
    }
    @MainActor static func render(_ canvas:NSView)->Data {
        let bitmap=canvas.bitmapImageRepForCachingDisplay(in:canvas.visibleRect)!
        canvas.cacheDisplay(in:canvas.visibleRect,to:bitmap)
        return bitmap.representation(using:.png,properties:[:])!
    }
    @MainActor static func wheel(_ scroll:ImageComparisonScrollView,_ flags:CGEventFlags,_ amount:Int32 = 1)->NSEvent {
        let event=CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:amount,wheel2:0,wheel3:0)!
        let point=scroll.contentView.convert(CGPoint(x:scroll.contentView.bounds.minX+80,y:scroll.contentView.bounds.minY+70),to:nil)
        let screen=scroll.window!.convertPoint(toScreen:point)
        event.location=CGPoint(x:screen.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-screen.y);event.flags=flags
        return NSEvent(cgEvent:event)!
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.ImagePointer."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        UserDefaults.standard.setVolatileDomain(["TurtleGit.DiffTools":try JSONEncoder().encode(DiffToolPreferences())],forName:"NSArgumentDomain")
        let left=root.appendingPathComponent("left.png"),right=root.appendingPathComponent("right.png"),a=png(1600,1200,.red),b=png(1200,1000,.blue)
        try a.write(to:left);try b.write(to:right)
        let owner=FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs)
        defer {owner.close()};let window=owner.window!,parent=owner.model,model=parent.imageViewerModel
        window.alphaValue=0;window.orderFront(nil);parent.load()
        func scrolls()->[ImageComparisonScrollView] {descendants(window.contentView!).compactMap{$0 as? ImageComparisonScrollView}}
        try await wait {window.contentView?.layoutSubtreeIfNeeded();return !parent.busy && parent.imageComparison != nil && scrolls().count==2 && scrolls().allSatisfy{$0.contentView.bounds.width>100}}
        model.originalSize();try await wait {scrolls().allSatisfy{($0.documentView?.frame.width ?? 0)>1000}}
        let first=scrolls().first{$0.documentView?.accessibilityLabel()=="Base image"}!,second=scrolls().first{$0 !== first}!
        first.contentView.scroll(to:CGPoint(x:200,y:150));model.didScroll(first,base:true)
        let before=model.displaySizing,origin=first.contentView.bounds.origin
        first.scrollWheel(with:wheel(first,.maskControl))
        try require(model.displaySizing.base.percent==120 && model.displaySizing.destination.percent==100,"Ctrl-wheel did not zoom only the addressed image")
        let expected=CGPoint(x:(origin.x+80)*1.2-80,y:(origin.y+70)*1.2-70)
        try require(abs(first.contentView.bounds.minX-expected.x)<2 && abs(first.contentView.bounds.minY-expected.y)<2,"Pointer pixel moved during zoom: \(first.contentView.bounds.origin), expected \(expected)")
        try require(second.contentView.bounds.origin==first.contentView.bounds.origin,"Linked zoom did not synchronize peer origin")
        try require(before.base.percent==100 && !model.fit,"Wheel did not freeze fit")
        let peer=second.contentView.bounds.origin;drag(first.documentView!)
        try require(first.contentView.bounds.minX>expected.x && second.contentView.bounds.origin==first.contentView.bounds.origin && peer != second.contentView.bounds.origin,"Linked drag failed")
        let preserved=second.contentView.bounds.origin;drag(first.documentView!,.shift)
        try require(second.contentView.bounds.origin==preserved,"Shift drag moved linked peer")
        model.linked=false
        first.contentView.scroll(to:CGPoint(x:240,y:230));second.contentView.scroll(to:CGPoint(x:205,y:205))
        model.pan(first,base:true,translation:CGPoint(x:30,y:20),start:first.contentView.bounds.origin,offsets:[:],modifiers:[])
        try require(first.contentView.bounds.origin==second.contentView.bounds.origin,"Unlinked border snap missing")
        let unlinked=second.contentView.bounds.origin;first.scrollWheel(with:wheel(first,.maskControl,-1))
        try require(model.displaySizing.base.percent==100 && second.contentView.bounds.origin==unlinked,"Unlinked zoom changed peer")
        model.overlay=true;try await wait {scrolls().count==1};let overlay=scrolls()[0]
        overlay.contentView.scroll(to:CGPoint(x:250,y:200));let shared=overlay.contentView.bounds.origin
        let beforePan=render(overlay.documentView!)
        drag(overlay.documentView!,.control)
        try require(beforePan != render(overlay.documentView!),"Independent second-image offset did not affect alpha rendering")
        try require(model.imageOffsets[false] != nil && model.imageOffsets[true]==nil && overlay.contentView.bounds.origin==shared,"Control drag did not isolate second overlay")
        let other=model.imageOffsets[false],beforeFirst=render(overlay.documentView!);drag(overlay.documentView!,.shift)
        try require(beforeFirst != render(overlay.documentView!),"Independent first-image offset did not affect alpha rendering")
        try require(model.imageOffsets[true] != nil && model.imageOffsets[false]==other,"Shift drag did not isolate first overlay")
        let offsets=model.imageOffsets;model.blendAlpha=false;overlay.updateCanvas()
        let canvas=overlay.documentView!,bitmap=canvas.bitmapImageRepForCachingDisplay(in:canvas.visibleRect)!
        canvas.cacheDisplay(in:canvas.visibleRect,to:bitmap)
        try require(bitmap.pixelsWide>0 && model.imageOffsets==offsets,"XOR rendering lost independent offsets")
        model.blendAlpha=true;overlay.scrollWheel(with:wheel(overlay,[.maskControl,.maskShift]))
        try require(model.alpha==0.25,"Overlay alpha wheel lost source priority")
        let old=model.displaySizing;overlay.scrollWheel(with:wheel(overlay,.maskControl))
        try require(model.displaySizing.base.percent>old.base.percent && model.displaySizing.base.percent==model.displaySizing.destination.percent,"Overlay wheel failed linked scale")
        // Busy/sheet/retired owners and replacement geometry cannot continue old drags.
        var allowed=true;model.commandsAllowed={allowed}
        let previous=model.displaySizing.base.percent;allowed=false
        overlay.scrollWheel(with:wheel(overlay,.maskControl));drag(canvas)
        try require(model.displaySizing.base.percent==previous && model.imageOffsets != [:],"Disabled pointer input changed zoom")
        allowed=true
        canvas.mouseDown(with:mouse(.leftMouseDown,canvas,canvas.visibleRect.origin))
        model.originalSize();overlay.updateCanvas();let stable=overlay.contentView.bounds.origin
        canvas.mouseDragged(with:mouse(.leftMouseDragged,canvas,CGPoint(x:20,y:20)))
        try require(overlay.contentView.bounds.origin==stable,"Stale drag survived replacement scale")
        model.overlay=false;try await wait {scrolls().count==2}
        try require(model.imageOffsets.isEmpty,"Overlay offsets leaked into separate panes")
        let retiredWheel=wheel(scrolls()[0],.maskControl)
        owner.close();let zoom=model.displaySizing.base.percent
        first.scrollWheel(with:retiredWheel);try require(model.displaySizing.base.percent==zoom,"Retired scroll changed model")
        try require(Data(contentsOf:left)==a && Data(contentsOf:right)==b,"Pointer navigation changed input files")
        print("PASS: actual image Ctrl-wheel pointer anchoring/per-side scale, linked and Shift pan, border snap, isolated overlay/XOR offsets, alpha priority, stale/disabled/retired guards and unchanged files")
    }
}
