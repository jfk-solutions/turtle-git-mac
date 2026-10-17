// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Native renamed artwork with the source WaterEffect animation. A closed,
/// occluded or Reduce Motion window has no repeating animation timer.
@MainActor final class AboutBannerView:NSView {
    private let tool:TurtleGitAboutTool
    private var water=AboutWaterEffect(width:468,height:64)!
    private var source=[UInt32](),pixels=[UInt32]()
    private var bitmap:NSBitmapImageRep?
    private var timer:Timer?
    private var observers=[NSObjectProtocol]()
    private var tracking:NSTrackingArea?
    private var ticks=0
    private(set) var retired=false
    private(set) var renderedFrames=0
    var reduceMotion:()->Bool = {NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    var visible:()->Bool = {true}
    var windowVisible:(NSWindow)->Bool = {$0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)}
    var animationRunning:Bool {timer != nil}
    init(tool:TurtleGitAboutTool) {
        self.tool=tool;super.init(frame:.init(x:0,y:0,width:468,height:64))
        setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel(tool.title+" animated banner")
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.updateAnimation()} })
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
    deinit {timer?.invalidate();for observer in observers {NotificationCenter.default.removeObserver(observer);NSWorkspace.shared.notificationCenter.removeObserver(observer)}}
    override var intrinsicContentSize:NSSize {.init(width:468,height:64)}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow();guard !retired else{return}
        // Workspace notifications are retained separately from window observers.
        while observers.count>1 {NotificationCenter.default.removeObserver(observers.removeLast())}
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.updateAnimation()} })
            }
            observers.append(NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.retire()} })
        }
        rebuild();updateAnimation()
    }
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();rebuild()}
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let tracking {removeTrackingArea(tracking)};tracking=nil
        guard !retired else{return}
        let area=NSTrackingArea(rect:.zero,options:[.activeInActiveApp,.mouseMoved,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);tracking=area
    }
    private var imageRect:NSRect {
        let scale=min(bounds.width/468,bounds.height/64)
        return .init(x:0,y:(bounds.height-64*scale)/2,width:468*scale,height:64*scale)
    }
    private func rebuild() {
        guard !retired,let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:468,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:468*4,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:image) else{return}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill();NSRect(x:0,y:0,width:468,height:64).fill()
            tool.artwork(size:48)?.draw(in:.init(x:4,y:8,width:48,height:48))
            (tool.title as NSString).draw(at:.init(x:66,y:24),withAttributes:[.font:NSFont.boldSystemFont(ofSize:27),.foregroundColor:NSColor.labelColor])
            ("A macOS fork of TortoiseGit" as NSString).draw(at:.init(x:67,y:8),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.secondaryLabelColor])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes=image.bitmapData else{return}
        source=Array(UnsafeBufferPointer(start:UnsafeRawPointer(bytes).assumingMemoryBound(to:UInt32.self),count:468*64));pixels=source;bitmap=image;water.clear();ticks=0;needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect);if bitmap==nil {rebuild()};bitmap?.draw(in:imageRect)
    }
    func updateAnimation() {
        if !retired,reduceMotion(),!source.isEmpty {
            water.clear();pixels=source
            if let bytes=bitmap?.bitmapData {pixels.withUnsafeBytes {raw in if let base=raw.baseAddress {memcpy(bytes,base,raw.count)}}}
            needsDisplay=true
        }
        guard !retired,let window,windowVisible(window),!isHiddenOrHasHiddenAncestor,!reduceMotion(),visible() else {timer?.invalidate();timer=nil;return}
        guard timer==nil else{return}
        let value=Timer(timeInterval:0.04,repeats:true) { [weak self] _ in MainActor.assumeIsolated {self?.advance()} }
        timer=value;RunLoop.main.add(value,forMode:.common)
    }
    func disturb(x:Int,y:Int,pressed:Bool) {
        guard !retired,!reduceMotion() else{return}
        water.blob(x:x,y:y,radius:pressed ? 10:5,strength:pressed ? 1600:50)
    }
    override func mouseMoved(with event:NSEvent) {pointer(event,pressed:false)}
    override func mouseDown(with event:NSEvent) {pointer(event,pressed:true)}
    override func mouseDragged(with event:NSEvent) {pointer(event,pressed:true)}
    private func pointer(_ event:NSEvent,pressed:Bool) {
        let point=convert(event.locationInWindow,from:nil),rect=imageRect
        guard rect.contains(point),rect.width>0 else{return}
        disturb(x:Int((point.x-rect.minX)*468/rect.width),y:Int((point.y-rect.minY)*64/rect.height),pressed:pressed)
    }
    func advance() {
        guard !retired,!reduceMotion(),visible() else {updateAnimation();return}
        if bitmap==nil {rebuild()};guard let bitmap,let bytes=bitmap.bitmapData else{return}
        ticks += 1
        if ticks%38==0 {water.blob(x:Int.random(in:12..<456),y:Int.random(in:12..<52),radius:tool == .merge ? 2:5,strength:tool == .merge ? 400:800)}
        water.render(source:source,destination:&pixels)
        pixels.withUnsafeBytes {raw in if let base=raw.baseAddress {memcpy(bytes,base,raw.count)}}
        renderedFrames += 1;needsDisplay=true
    }
    func retire() {
        guard !retired else{return};retired=true;timer?.invalidate();timer=nil
        for observer in observers {NotificationCenter.default.removeObserver(observer);NSWorkspace.shared.notificationCenter.removeObserver(observer)};observers=[]
        if let tracking {removeTrackingArea(tracking)};tracking=nil
    }
}
