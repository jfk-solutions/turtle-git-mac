// SPDX-License-Identifier: GPL-2.0-or-later
// Native TextKit geometry and owner-routed events; no desktop event injection.
import AppKit
import CryptoKit
import Darwin
import ObjectiveC
import PDFKit
import TurtleGitCore

private extension NSWindow {
    @objc func gutterPrivateOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;gutterPrivateOrder(mode,relativeTo:number)
    }
}
@MainActor
@main struct UnifiedGutterVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {
        if !value {throw Failure(description:"line \(line): \(message)")}
    }
    static func phase(_ message:String){print("UDiff gutter: "+message);fflush(stdout)}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1200 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"State did not settle at line \(line)")
    }
    static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let suite="TurtleGit.Gutter.QA."+UUID().uuidString
        let preferences:UserDefaults
        let board=NSPasteboard.withUniqueName()
        var owners:[PatchWindowController]=[]
        var sheets:[NSWindow]=[]
        init(){preferences=UserDefaults(suiteName:suite)!}
        func owner(repository:GitRepository?=nil)->PatchWindowController {
            let value=PatchWindowController(repository:repository,access:nil,preferences:preferences,documentDirectory:root)
            owners.append(value);value.window?.isReleasedWhenClosed=false;value.window?.alphaValue=0
            value.window?.setFrame(NSRect(x:80,y:80,width:820,height:680),display:false)
            value.showWindow(nil);return value
        }
        func clean()async throws {
            for sheet in sheets {
                sheet.sheetParent?.endSheet(sheet,returnCode:.abort)
                try await UnifiedGutterVerification.wait {sheet.sheetParent==nil}
                sheet.close()
            }
            for owner in owners {owner.model.busy=false;owner.model.confirmingQuit=false;owner.close()}
            try await UnifiedGutterVerification.wait {PatchWindowModel.activeOperations==0}
            try UnifiedGutterVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil} && sheets.allSatisfy{!$0.isVisible && $0.sheetParent==nil},"Owned windows/sheets survived cleanup")
            preferences.removePersistentDomain(forName:suite);board.releaseGlobally()
            UnifiedGutterVerification.phase("owned windows closed; Git workers drained")
        }
    }
    @MainActor struct Surface {
        let owner:PatchWindowController,text:PatchTextView.PatchText,scroll:PatchScrollView,gutter:PatchLineNumberGutter,host:PatchTextHost
        var model:PatchWindowModel {owner.model}
        var window:NSWindow {owner.window!}
    }
    static func surface(_ owner:PatchWindowController)async throws->Surface {
        try await wait {owner.window?.contentView.map{descendants($0).contains{$0 is PatchTextView.PatchText}} == true}
        let text=descendants(owner.window!.contentView!).compactMap{$0 as? PatchTextView.PatchText}.first!
        guard let scroll=text.enclosingScrollView as? PatchScrollView,let gutter=scroll.lineNumberGutter,let host=scroll.superview as? PatchTextHost else {throw Failure(description:"Missing actual hosted ruler")}
        return Surface(owner:owner,text:text,scroll:scroll,gutter:gutter,host:host)
    }
    static func load(_ s:Surface,_ text:String)async throws {
        s.model.setReadOnlyDiff(Data(text.utf8),discardingEdits:true)
        try await wait {s.text.string.utf16.elementsEqual(text.utf16) && s.gutter.lineIndex.utf16Length==(text as NSString).length}
        s.window.contentView?.layoutSubtreeIfNeeded();s.scroll.updateDocumentExtent();s.scroll.layoutSubtreeIfNeeded()
    }
    static func point(_ s:Surface,_ line:Int)throws->NSPoint {
        guard let rect=s.gutter.rect(forLine:line) else {throw Failure(description:"Missing line rectangle \(line)")}
        return .init(x:s.gutter.ruleThickness/2,y:rect.midY)
    }
    static func event(_ s:Surface,_ type:NSEvent.EventType,_ point:NSPoint,_ flags:NSEvent.ModifierFlags=[])->NSEvent {
        NSEvent.mouseEvent(with:type,location:s.gutter.convert(point,to:nil),modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    }
    static func click(_ s:Surface,line:Int,flags:NSEvent.ModifierFlags=[],dragTo:Int?=nil)throws {
        let start=try point(s,line),end=try point(s,dragTo ?? line)
        // Queue only this private window's receipts. Native mouseDown consumes
        // them through its real eventTracking path, without CGEvent/desktop input.
        if !flags.contains(.command) {
            NSApp.postEvent(event(s,.leftMouseUp,end,flags),atStart:true)
            if dragTo != nil {NSApp.postEvent(event(s,.leftMouseDragged,end,flags),atStart:true)}
        }
        s.gutter.mouseDown(with:event(s,.leftMouseDown,start,flags))
    }
    static func nativeLayout(_ s:Surface,line:Int = #line)throws {
        s.window.contentView?.layoutSubtreeIfNeeded();s.host.layoutSubtreeIfNeeded();s.scroll.layoutSubtreeIfNeeded()
        let clipInHost=s.scroll.convert(s.scroll.contentView.frame,to:s.host)
        let gutterInHost=s.gutter.convert(s.gutter.bounds,to:s.host)
        try require(s.scroll.superview === s.host && s.gutter.superview === s.host && clipInHost.minX >= gutterInHost.maxX-0.5,
            "Text viewport overlaps sibling ruler: clipInHost \(clipInHost), rulerInHost \(gutterInHost)",line:line)
        try require(s.text.bounds.width >= s.scroll.contentView.bounds.width-0.5 && s.text.bounds.height >= s.scroll.contentView.bounds.height-0.5,
            "Document does not cover actual clip viewport: document \(s.text.bounds), frame \(s.text.frame), minSize \(s.text.minSize), maxSize \(s.text.maxSize), clip \(s.scroll.contentView.bounds), clipFrame \(s.scroll.contentView.frame), nativeContentSize \(s.scroll.contentSize), ruler \(s.gutter.frame)",line:line)
        try require(s.scroll.contentView.bounds.minX >= -0.5,"Artificial negative horizontal origin: \(s.scroll.contentView.bounds)",line:line)
    }
    static func width(_ s:Surface,_ columns:Int)->CGFloat {
        let font=(s.text.textStorage?.length ?? 0)>0 ? s.text.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont : s.text.font
        return ceil(("8" as NSString).size(withAttributes:[.font:font!]).width*CGFloat(columns))
    }
    static func geometry(_ c:Context,_ s:Surface)async throws {
        phase("logical numbering, actual font metrics and exact Unicode edits")
        try require(!s.scroll.hasVerticalRuler && !s.scroll.rulersVisible && !s.gutter.isHidden && s.scroll.lineNumberGutter === s.gutter && s.gutter.accessibilityIdentifier()=="UnifiedDiff.LineNumberGutter","Ruler not installed/accessibly identified")
        for count in [1,9,10,99,100] {
            let text=(0..<count).map{"logical \($0)"}.joined(separator:"\n")
            try await load(s,text)
            try nativeLayout(s)
            try require(s.gutter.lineIndex.lineCount==count && s.gutter.ruleThickness==width(s,String(count).count+2),"Wrong line count/digit-based margin at \(count)")
        }
        try await load(s,"");try require(s.gutter.lineIndex.lineCount==1,"Empty document lost line 1")
        try await load(s,"one\n");try require(s.gutter.lineIndex.lineCount==2 && s.gutter.rect(forLine:1) != nil,"Final empty logical line missing")
        var settings=UnifiedDiffAppearance.load(from:c.preferences);settings.fontName="Menlo";settings.fontSize=19;settings.save(to:c.preferences)
        NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.preferences)
        try await wait {s.gutter.ruleThickness==width(s,3) && (s.text.typingAttributes[.font] as? NSFont)?.pointSize==19}
        try nativeLayout(s)
        let before=s.gutter.ruleThickness
        settings.fontName="Helvetica";settings.fontSize=13;settings.save(to:c.preferences)
        NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.preferences)
        try await wait {s.gutter.ruleThickness==width(s,3) && s.gutter.ruleThickness != before}
        try nativeLayout(s)
        s.window.setContentSize(NSSize(width:900,height:700));try nativeLayout(s)
        try await load(s,"e\u{301}\nsecond")
        let p=try point(s,0);try require(s.gutter.beginSelection(at:p,modifiers:[]),"Exact-edit gesture refused")
        s.model.allowsDocumentEditing=true
        try await wait {s.text.isEditable}
        s.text.insertText("é",replacementRange:NSRange(location:0,length:2))
        try await wait {s.gutter.lineIndex.utf16Length==8 && s.model.document.text.utf16.elementsEqual("é\nsecond".utf16)}
        try nativeLayout(s)
        try require(!s.gutter.isSelecting && s.gutter.lineIndex.lineStarts==[0,2],"Canonically equal native edit retained stale UTF16 index/gesture")
    }
    static func selection(_ s:Surface)async throws {
        phase("native clicks, directional Shift, drag, Command, cancel and denial")
        try await load(s,"alpha\nbeta\ngamma\ndelta\nend")
        let raw=s.model.exportDocument.bytes
        try click(s,line:1);try require(s.text.selectedRange()==NSRange(location:6,length:5),"Native click omitted whole line/terminator")
        try click(s,line:3,flags:.shift);try require(s.text.selectedRange()==NSRange(location:6,length:17),"Forward Shift anchor incorrect")
        try click(s,line:0,flags:.shift);try require(s.text.selectedRange()==NSRange(location:0,length:11) && s.text.selectionAffinity == .upstream,"Reverse Shift anchor/affinity incorrect")
        try click(s,line:2,dragTo:0);try require(s.text.selectedRange()==NSRange(location:0,length:17),"Native drag failed whole-line reverse range")
        try click(s,line:1,flags:.command);try require(s.text.selectedRange()==NSRange(location:0,length:(s.text.string as NSString).length),"Command margin did not select all")
        let saved=NSRange(location:2,length:2);s.text.setSelectedRange(saved)
        try require(s.gutter.beginSelection(at:point(s,1),modifiers:[]),"Cancel begin refused")
        _=s.gutter.continueSelection(at:try point(s,3));s.gutter.cancelSelection()
        try require(s.text.selectedRange()==saved && !s.gutter.isSelecting,"Cancel did not restore exact pre-gesture range")
        try require(!s.gutter.beginSelection(at:point(s,1),modifiers:.control),"Control context click selected text")
        try require(s.gutter.beginSelection(at:point(s,1),modifiers:[]),"Pre-busy gesture refused")
        s.model.busy=true;try require(!s.gutter.continueSelection(at:point(s,2)) && !s.gutter.isSelecting,"Busy owner retained pending gesture")
        try require(!s.gutter.beginSelection(at:point(s,1),modifiers:[]),"Busy owner accepted gutter gesture");s.model.busy=false
        try require(s.model.exportDocument.bytes==raw,"Selection changed raw document bytes")
    }
    static func scrolling(_ s:Surface)async throws {
        phase("wrapped logical fragments and horizontal-preserving autoscroll")
        let long=String(repeating:"wrapped words ",count:30)
        try await load(s,long+"\nnext logical line\nlast")
        s.text.isHorizontallyResizable=false;s.text.textContainer?.widthTracksTextView=true
        s.text.setFrameSize(NSSize(width:240,height:2000));s.text.textContainer?.containerSize=NSSize(width:220,height:CGFloat.greatestFiniteMagnitude)
        s.text.layoutManager?.ensureLayout(for:s.text.textContainer!);s.gutter.documentChanged()
        let first=s.gutter.rect(forLine:0)!,second=s.gutter.rect(forLine:1)!
        try require(second.minY>first.maxY*2 && s.gutter.visibleLabels().filter{$0.line==0}.count==1,"Wrapped fragments acquired extra logical labels")
        let continuation=NSPoint(x:first.midX,y:first.maxY+first.height/2)
        try require(s.gutter.beginSelection(at:continuation,modifiers:[]),"Wrapped continuation click refused");s.gutter.endSelection()
        try require(s.text.selectedRange()==NSRange(location:0,length:(long as NSString).length+1),"Wrapped continuation selected visual fragment")
        s.text.isHorizontallyResizable=true;s.text.textContainer?.widthTracksTextView=false
        s.text.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        try await load(s,(0..<180).map{"line \($0) "+String(repeating:"x",count:180)}.joined(separator:"\n"))
        let initial=s.gutter.rect(forLine:30)!.minY
        s.scroll.contentView.scroll(to:NSPoint(x:65,y:220));s.scroll.reflectScrolledClipView(s.scroll.contentView)
        let moved=s.gutter.rect(forLine:30)!.minY
        try require(abs((initial-moved)-220)<1 && (s.gutter.visibleLabels().first?.line ?? 0)>0,"Gutter did not follow vertical viewport")
        let visible=s.gutter.visibleLabels();try require(!visible.isEmpty,"Scrolled gutter lost labels")
        try require(s.gutter.beginSelection(at:point(s,visible[0].line),modifiers:[]),"Scroll gesture refused")
        let origin=s.scroll.contentView.bounds.origin
        _=s.gutter.continueSelection(at:NSPoint(x:5,y:s.gutter.bounds.maxY+80));s.gutter.autoscrollSelection()
        try require(s.scroll.contentView.bounds.minY>origin.y && abs(s.scroll.contentView.bounds.minX-origin.x)<0.5,"Autoscroll changed horizontal origin or failed vertical movement")
        s.gutter.cancelSelection()
    }
    static func partial(_ c:Context,_ repo:GitRepository)async throws {
        phase("real Git packet consumer and retained partial-staging menu gates")
        let s=try await surface(c.owner(repository:repo));s.model.reload(paths:["file.txt"],staged:false)
        try await wait {!s.model.busy && s.text.string==s.model.document.text && !s.model.document.files.isEmpty}
        guard let line=s.model.document.lines.firstIndex(of:"+new selected") else {throw Failure(description:"Private changed line missing")}
        s.window.contentView?.layoutSubtreeIfNeeded();s.scroll.updateDocumentExtent()
        try click(s,line:line)
        let menu=PatchMenuContext(keyWindow:{s.window})
        try await wait {s.model.selectedLines==[line] && menu.stageLinesAvailable && menu.stageHunksAvailable}
        try require(!menu.unstageLinesAvailable && s.model.canApplyLines && s.model.canApplyHunks,"Gutter bypassed stage/unstage gates")
        let packet=try s.model.document.selectedPatchData(lines:s.model.selectedLines,entireHunks:false,reverse:false)
        _=try await repo.run(["apply","--cached","--check","--unidiff-zero","-"],input:packet)
        let bytes=s.model.exportDocument.bytes;s.model.copyPatch(to:c.board)
        try require(PatchClipboard.snapshot(from:c.board)==bytes,"Copy after gutter selection lost raw bytes")
        s.model.readOnly=true
        try await wait {!menu.stageLinesAvailable && !menu.stageHunksAvailable}
        try require(!s.model.canApplyLines && !s.model.canApplyHunks && s.text.isEditable==false,"Read-only preview acquired mutation controls")
        let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:120,height:80),styleMask:.borderless,backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;c.sheets.append(sheet)
        s.window.beginSheet(sheet,completionHandler:nil)
        try require(!s.gutter.beginSelection(at:point(s,line),modifiers:[]),"Attached sheet failed to fence gesture")
        s.window.endSheet(sheet);sheet.orderOut(nil)
        try await wait {s.window.attachedSheet==nil}
    }
    static func capture(_ c:Context,_ s:Surface)async throws {
        phase("light/dark native content captures, including three-digit labels")
        let folder=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
        var rows=["diff --git a/Sources/Turtle.swift b/Sources/Turtle.swift","index 1234567..89abcde 100644","--- a/Sources/Turtle.swift","+++ b/Sources/Turtle.swift","@@ -1,130 +1,130 @@"]
        for line in 1...135 {rows.append(line%9==0 ? "-    return oldValue // line \(line)" : line%9==1 ? "+    return turtle.status // line \(line)" : "     // repository status \(line)")}
        try await load(s,rows.joined(separator:"\n")+"\n")
        var records:[[String:Any]]=[]
        for dark in [false,true] {
            s.owner.setDarkMode(dark)
            try await wait {s.model.darkMode==dark}
            // A scheduling turn lets SwiftUI's environment and TextKit styles
            // settle; readiness still checks actual text background.
            try await wait {guard let color=s.text.backgroundColor.usingColorSpace(.deviceRGB) else{return false};return dark ? color.redComponent<0.4 : color.redComponent>0.6}
            s.window.contentView?.layoutSubtreeIfNeeded();s.scroll.updateDocumentExtent()
            let y=s.gutter.rect(forLine:93)!.minY+s.scroll.contentView.bounds.minY
            s.scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,y-20)));s.scroll.reflectScrolledClipView(s.scroll.contentView)
            s.text.setSelectedRange(NSRange(location:0,length:0));s.scroll.displayIfNeeded();s.gutter.displayIfNeeded()
            try require(s.gutter.visibleLabels().contains{$0.line>=99},"Capture omitted three-digit labels")
            try nativeLayout(s)
            let stem=dark ? "dark":"light"
            // Preserve the parent-cache limitation independently. AppKit omits
            // this hosted text child from NSScrollView.cacheDisplay even though
            // directly caching the actual NSTextView renders its real glyphs.
            guard let parentBitmap=s.host.bitmapImageRepForCachingDisplay(in:s.host.bounds) else {throw Failure(description:"Native parent cache failed")}
            s.host.cacheDisplay(in:s.host.bounds,to:parentBitmap)
            guard let parentPNG=parentBitmap.representation(using:.png,properties:[:]),
                  let textBitmap=s.text.bitmapImageRepForCachingDisplay(in:s.text.visibleRect) else {throw Failure(description:"Native document cache allocation failed")}
            try parentPNG.write(to:folder.appendingPathComponent(stem+"-parent-cache.png"))
            s.text.cacheDisplay(in:s.text.visibleRect,to:textBitmap)
            guard let textPNG=textBitmap.representation(using:.png,properties:[:]) else {throw Failure(description:"Native text PNG failed")}
            try textPNG.write(to:folder.appendingPathComponent(stem+"-text-cache.png"))
            // Native NSView PDF output captures the complete existing hierarchy;
            // PDFKit rasterizes that output without rebuilding layout or glyphs.
            let pdf=s.host.dataWithPDF(inside:s.host.bounds)
            try pdf.write(to:folder.appendingPathComponent(stem+".pdf"))
            guard let document=PDFDocument(data:pdf),let page=document.page(at:0),
                  let tiff=page.thumbnail(of:NSSize(width:s.host.bounds.width*2,height:s.host.bounds.height*2),for:.mediaBox).tiffRepresentation,
                  let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {throw Failure(description:"Native hierarchy PDF raster failed")}
            let name=stem+".png";try png.write(to:folder.appendingPathComponent(name))
            let background=s.text.backgroundColor.usingColorSpace(.deviceRGB)!
            func samples(_ image:NSBitmapImageRep,_ x0:Int,_ x1:Int)->(Int,Int) {
                var ink=0,colored=0
                for y in stride(from:8,to:image.pixelsHigh-8,by:3) {
                    for x in stride(from:max(0,x0),to:min(image.pixelsWide-1,x1),by:3) {
                        guard let pixel=image.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),pixel.alphaComponent>0.9 else {continue}
                        let r=pixel.redComponent,g=pixel.greenComponent,b=pixel.blueComponent
                        if max(abs(r-background.redComponent),abs(g-background.greenComponent),abs(b-background.blueComponent))>0.35 {ink += 1}
                        if max(r,g,b)-min(r,g,b)>0.08 {colored += 1}
                    }
                }
                return (ink,colored)
            }
            let scale=CGFloat(bitmap.pixelsWide)/s.host.bounds.width
            let clipInHost=s.scroll.convert(s.scroll.contentView.frame,to:s.host)
            let (ink,colored)=samples(bitmap,Int((clipInHost.minX+5)*scale),Int((clipInHost.minX+min(s.scroll.contentView.bounds.width-5,400))*scale))
            let (directInk,directColored)=samples(textBitmap,8,min(textBitmap.pixelsWide-8,800))
            try require(directInk>100 && directColored>100,"Direct actual NSTextView cache lost text/color ink: \(directInk), \(directColored)")
            try require(ink>100 && colored>100,"Actual native hierarchy PDF lost document text/color ink: ink \(ink), color \(colored)")
            records.append(["file":name,"rawPDF":stem+".pdf","rawPDFSHA256":SHA256.hash(data:pdf).map{String(format:"%02x",$0)}.joined(),"directTextCache":stem+"-text-cache.png","directTextSHA256":SHA256.hash(data:textPNG).map{String(format:"%02x",$0)}.joined(),"directTextInkSamples":directInk,"directTextColoredSamples":directColored,"parentCache":stem+"-parent-cache.png","parentCacheSHA256":SHA256.hash(data:parentPNG).map{String(format:"%02x",$0)}.joined(),"parentCacheLimitation":"Native ancestor cache retained as diagnostic; acceptance uses hierarchy PDF plus direct NSTextView cache (earlier NSScrollView cache omitted text child)","sha256":SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined(),"width":bitmap.pixelsWide,"height":bitmap.pixelsHigh,"appearance":dark ? "darkAqua":"aqua","visibleLabels":s.gutter.visibleLabels().map{$0.label},"alpha":s.window.alphaValue,"nativeDocumentInkSamples":ink,"nativeColoredSamples":colored,"geometry":["hostFrame":NSStringFromRect(s.host.frame),"hostBounds":NSStringFromRect(s.host.bounds),"clipFrameInHost":NSStringFromRect(clipInHost),"rulerFrame":NSStringFromRect(s.gutter.frame),"rulerBounds":NSStringFromRect(s.gutter.bounds),"ruleThickness":s.gutter.ruleThickness,"rulersVisible":s.scroll.rulersVisible,"hasVerticalRuler":s.scroll.hasVerticalRuler,"hasHorizontalRuler":s.scroll.hasHorizontalRuler,"rulerHidden":s.gutter.isHidden,"textUsesRuler":s.text.usesRuler,"automaticInsets":s.scroll.automaticallyAdjustsContentInsets,"contentInsets":[s.scroll.contentInsets.top,s.scroll.contentInsets.left,s.scroll.contentInsets.bottom,s.scroll.contentInsets.right],"textFirstResponder":s.window.firstResponder===s.text,"clipFrame":NSStringFromRect(s.scroll.contentView.frame),"clipBounds":NSStringFromRect(s.scroll.contentView.bounds),"textFrame":NSStringFromRect(s.text.frame),"textBounds":NSStringFromRect(s.text.bounds),"textMinSize":NSStringFromSize(s.text.minSize),"textVisibleRect":NSStringFromRect(s.text.visibleRect),"textContainerOrigin":NSStringFromPoint(s.text.textContainerOrigin),"usedRect":NSStringFromRect(s.text.layoutManager!.usedRect(for:s.text.textContainer!)),"scrollFrame":NSStringFromRect(s.scroll.frame),"scrollBounds":NSStringFromRect(s.scroll.bounds),"nativeTextLength":(s.text.string as NSString).length,"nativeGlyphCount":s.text.layoutManager!.numberOfGlyphs,"textLayerBacked":s.text.wantsLayer,"scrollLayerBacked":s.scroll.wantsLayer],"source":"actual hosted PatchTextHost sibling gutter+scroll NSView.dataWithPDF hierarchy output rasterized by PDFKit; independent direct NSTextView.cacheDisplay ink assertion; alpha0 native window; native content render, not physical screenshot"])
        }
        try JSONSerialization.data(withJSONObject:["captures":records,"pid":getpid(),"git":CommandLine.arguments[2]],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("manifest.json"))
    }
    static func lifetime(_ c:Context,_ s:Surface)async throws {
        phase("replacement, detached ruler, owner close and stale gesture fences")
        try await load(s,"old\nsecond\nthird")
        try require(s.gutter.beginSelection(at:point(s,1),modifiers:[]),"Replacement gesture refused")
        try await load(s,"replacement\ndocument")
        try require(!s.gutter.continueSelection(at:point(s,0)) && !s.gutter.isSelecting,"Replacement retained stale gesture")
        let held=s.gutter;s.window.contentView=NSView(frame:s.window.contentView!.frame)
        try await wait {!s.model.sourceAttached()}
        try require(!held.beginSelection(at:.init(x:2,y:2),modifiers:[]),"Detached ruler routed to former owner")
        let other=try await surface(c.owner());try await load(other,"close\nowned")
        other.owner.close();try await wait {other.model.retired}
        try require(!other.gutter.beginSelection(at:.init(x:2,y:2),modifiers:[]),"Closed owner accepted stale gutter command")
    }
    static func main()async {
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.gutterPrivateOrder(_:relativeTo:)))!
        method_exchangeImplementations(order,replacement)
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            if CommandLine.arguments.contains("--geometry-only") {
                let s=try await surface(c.owner())
                try await geometry(c,s)
                try await scrolling(s);try await capture(c,s);try await c.clean()
                phase("PASS Unified Diff gutter geometry only: extent/font/wrapping/scroll/capture; all owned windows closed");return
            }
            if CommandLine.arguments.contains("--capture-only") {
                let s=try await surface(c.owner());try await capture(c,s);try await c.clean()
                phase("PASS Unified Diff gutter capture only: actual geometry recorded; all owned windows closed");return
            }
            let repo=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Gutter QA"),("user.email","gutter@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\ntail\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"baseline")
            try Data("base\nnew selected\ntail\n".utf8).write(to:file)
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:c.root.appendingPathComponent(".git/config")),working=try Data(contentsOf:file)
            let s=try await surface(c.owner())
            try await geometry(c,s);try await selection(s);try await scrolling(s);try await partial(c,repo);try await capture(c,s);try await lifetime(c,s)
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(finalHead==head && Data(contentsOf:file)==working && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:c.root.appendingPathComponent(".git/config"))==config,"Native selection/check changed Git HEAD/index/config/worktree")
            try await c.clean();phase("PASS Unified Diff gutter: geometry/events/wrapping/scroll/appearance/partial Git/lifetime; all owned windows closed")
        } catch {try? await c.clean();fputs("Unified Diff gutter failed: \(error)\n",stderr);fflush(stderr);exit(1)}
    }
}
