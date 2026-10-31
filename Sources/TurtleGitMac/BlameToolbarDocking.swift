// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

struct BlameToolbarDockDrag {
    let barID:UUID
    let generation:UUID
    var placement:BlameToolbarPlacement
    var point:NSPoint
}
@MainActor final class BlameToolbarWeakStrip {weak var view:BlameToolbarStrip?;init(_ view:BlameToolbarStrip){self.view=view}}

@MainActor extension BlameToolbarController {
    func installPlacementGrip(){
        guard let window=owner?.window else{return}
        let accessory=NSTitlebarAccessoryViewController();accessory.layoutAttribute = .left
        accessory.view=BlameToolbarGrip(chrome:self,barID:BlameToolbarConfiguration.standardID,frame:NSRect(x:0,y:0,width:22,height:24))
        titlebarGrip=accessory;window.addTitlebarAccessoryViewController(accessory)
    }
    func removePlacementGrip(){
        if let window=owner?.window,let accessory=titlebarGrip,let index=window.titlebarAccessoryViewControllers.firstIndex(where:{$0 === accessory}){window.removeTitlebarAccessoryViewController(at:index)}
        titlebarGrip=nil
    }
    var usesNativeStandard:Bool {configuration.standard.placement == .top && configuration.standard.dockOrder==0}
    func authenticatedGrip(_ grip:BlameToolbarGrip)->Bool {
        guard available,grip.window != nil else{return false}
        if titlebarGrip?.view === grip {return usesNativeStandard && configuration.standard.isVisible}
        return grip.generation==configuration.generation && stripHosts.values.contains{$0.view?.ownsGrip(grip)==true}
    }
    func bars(at placement:BlameToolbarPlacement)->[BlameToolbarBar] {
        configuration.allBars.enumerated().filter{$0.element.isVisible && $0.element.placement==placement && !($0.element.id==BlameToolbarConfiguration.standardID && usesNativeStandard)}.sorted{a,b in a.element.dockOrder==b.element.dockOrder ? a.offset<b.offset:a.element.dockOrder<b.element.dockOrder}.map(\.element)
    }
    func setPlacement(barID:UUID,placement:BlameToolbarPlacement){
        guard canConfigure(nil),var bar=store.load().allBars.first(where:{$0.id==barID}) else{return}
        if placement == .floating,bar.placement != .floating{bar.lastDockPlacement=bar.placement;bar.lastDockOrder=bar.dockOrder}
        bar.placement=placement
        if placement != .floating {bar.dockOrder=placement==bar.lastDockPlacement ? bar.lastDockOrder:0;bar.lastDockPlacement=placement;bar.lastDockOrder=bar.dockOrder}
        update(bar)
    }
    func toggleFloating(barID:UUID){
        guard let bar=store.load().allBars.first(where:{$0.id==barID}) else{return}
        setPlacement(barID:barID,placement:bar.placement == .floating ? bar.lastDockPlacement:.floating)
    }
    @discardableResult func beginDockDrag(barID:UUID)->Bool {
        guard canConfigure(nil),dockDrag==nil,commandDrag==nil,let bar=configuration.allBars.first(where:{$0.id==barID && $0.isVisible}) else{return false}
        dockDrag=BlameToolbarDockDrag(barID:barID,generation:configuration.generation,placement:bar.placement,point:NSEvent.mouseLocation)
        dockingPreview=bar.placement;return true
    }
    func placement(at point:NSPoint)->BlameToolbarPlacement {
        guard let window=owner?.window,let content=window.contentView else{return .floating}
        let rect=window.convertToScreen(content.convert(content.bounds,to:nil))
        guard rect.insetBy(dx:-24,dy:-24).contains(point) else{return .floating}
        let distances:[(BlameToolbarPlacement,CGFloat)]=[(.top,abs(rect.maxY-point.y)),(.bottom,abs(rect.minY-point.y)),(.left,abs(rect.minX-point.x)),(.right,abs(rect.maxX-point.x))]
        guard let nearest=distances.min(by:{$0.1<$1.1}),nearest.1<=72 else{return .floating}
        return nearest.0
    }
    func updateDockDrag(point:NSPoint){
        guard var drag=dockDrag,live else{return};drag.point=point;drag.placement=placement(at:point);dockDrag=drag;dockingPreview=drag.placement
    }
    @discardableResult func finishDockDrag(point:NSPoint)->Bool {
        guard let drag=dockDrag else{return false};updateDockDrag(point:point)
        let target=dockDrag?.placement ?? .floating
        defer{cancelDockDrag()}
        guard canConfigure(nil),store.load().generation==drag.generation,var bar=configuration.allBars.first(where:{$0.id==drag.barID}) else{return false}
        if target == .floating,bar.placement != .floating {bar.lastDockPlacement=bar.placement;bar.lastDockOrder=bar.dockOrder}
        bar.placement=target
        if target != .floating {
            var peers=configuration.allBars.enumerated().filter{$0.element.id != bar.id && $0.element.isVisible && $0.element.placement==target}.sorted{a,b in a.element.dockOrder==b.element.dockOrder ? a.offset<b.offset:a.element.dockOrder<b.element.dockOrder}.map(\.element)
            let insertion=peers.firstIndex {peer in
                let view:NSView?=peer.id==BlameToolbarConfiguration.standardID && usesNativeStandard ? titlebarGrip?.view:stripHosts.values.compactMap(\.view).first{$0.barID==peer.id}
                guard let view,let window=view.window else{return false}
                let rect=window.convertToScreen(view.convert(view.bounds,to:nil))
                return target == .left || target == .right ? point.x<rect.midX:point.y>rect.midY
            } ?? peers.count
            peers.insert(bar,at:insertion)
            var latest=store.load()
            latest.updateBar(bar);_ = latest.reorderDockBars(peers.map(\.id),at:target)
            installCommandTransfer(latest);return true
        }
        if target == .floating {let rect=clampedFrame(NSRect(x:point.x-90,y:point.y-30,width:360,height:72));bar.floatingRect = .init(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height)}
        update(bar);return true
    }
    func cancelDockDrag(){dockDrag=nil;dockingPreview=nil;resumeDeferredPreferences()}
    @discardableResult func beginCommandDrag(barID:UUID,index:Int)->Bool {
        guard canConfigure(nil),dockDrag==nil,commandDrag==nil,let bar=configuration.allBars.first(where:{$0.id==barID && $0.isVisible}),bar.items.indices.contains(index) else{return false}
        commandDrag=configuration.captureItem(barID:barID,index:index);return commandDrag != nil
    }
    @discardableResult func finishCommandDrag(destinationID:UUID?,index:Int)->Bool {
        guard let receipt=commandDrag else{return false};defer{cancelCommandDrag()}
        var source=store.load()
        guard canConfigure(nil),let destinationID,source.generation==receipt.generation,
              source.allBars.contains(where:{$0.id==destinationID && $0.isVisible}),source.transfer(receipt,to:destinationID,at:index,copy:false) else{return false}
        // Both bar edits use the same validated transfer snapshot. No cross-owner
        // drag payload is accepted; target hit-testing is this controller's only.
        installCommandTransfer(source)
        return true
    }
    func cancelCommandDrag(){commandDrag=nil;resumeDeferredPreferences()}
    func commandDropTarget(at point:NSPoint)->(UUID,Int)? {
        guard live else{return nil}
        for host in stripHosts.values {
            guard let strip=host.view,let window=strip.window,!strip.isHiddenOrHasHiddenAncestor,window.isVisible else{continue}
            let local=strip.convert(window.convertPoint(fromScreen:point),from:nil)
            if strip.bounds.contains(local),let barID=strip.barID{return(barID,strip.insertionIndex(at:local))}
        }
        if usesNativeStandard,toolbar.isVisible,let window=owner?.window {
            for (index,item) in toolbar.items.enumerated(){
                guard let view=item.view else{continue};let local=view.convert(window.convertPoint(fromScreen:point),from:nil)
                if view.bounds.insetBy(dx:-8,dy:-8).contains(local){return(BlameToolbarConfiguration.standardID,index+(local.x>view.bounds.midX ? 1:0))}
            }
        }
        return nil
    }
    func clampedFrame(_ input:NSRect)->NSRect {
        func valid(_ rect:NSRect)->Bool {[rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) && rect.width>0 && rect.height>0}
        let screens=screenFrames().filter(valid)
        let fallback=NSRect(x:0,y:0,width:360,height:72),candidate=valid(input) ? input:fallback
        guard let screen=screens.first(where:{$0.intersects(candidate)}) ?? screens.first else{return candidate}
        let size=NSSize(width:min(max(candidate.width,160),screen.width),height:min(max(candidate.height,56),screen.height))
        return NSRect(x:min(max(candidate.minX,screen.minX),screen.maxX-size.width),y:min(max(candidate.minY,screen.minY),screen.maxY-size.height),width:size.width,height:size.height)
    }
    func refreshFloatingPanels(){
        guard live,let ownerWindow=owner?.window else{return}
        let desired=configuration.allBars.filter{$0.isVisible && $0.placement == .floating}
        let ids=Set(desired.map(\.id))
        for id in Array(floatingPanels.keys) where !ids.contains(id){floatingPanels.removeValue(forKey:id)?.retire()}
        for bar in desired {
            if let panel=floatingPanels[bar.id] {panel.refresh(bar:bar,owner:ownerWindow)}
            else {
                let controller=BlameToolbarFloatingController(chrome:self,bar:bar,owner:ownerWindow);floatingPanels[bar.id]=controller
                if let panel=controller.window as? NSPanel,ownerWindow.isVisible,!ownerWindow.isMiniaturized {presentFloating(panel)}
            }
        }
    }
    func retireFloatingPanels(){let panels=Array(floatingPanels.values);floatingPanels=[:];panels.forEach{$0.retire()};stripHosts=[:]}
    func captureFloatingFrame(barID:UUID,frame:NSRect){
        guard canConfigure(nil),var bar=store.load().allBars.first(where:{$0.id==barID && $0.placement == .floating}) else{return}
        let rect=clampedFrame(frame),saved=BlameToolbarFloatingRect(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height);guard bar.floatingRect != saved else{return};bar.floatingRect=saved;update(bar)
    }
    func hideBar(_ barID:UUID){guard var bar=store.load().allBars.first(where:{$0.id==barID}) else{return};bar.isVisible=false;update(bar)}
    func contextMenu(barID:UUID)->NSMenu {
        let menu=NSMenu();menu.autoenablesItems=false
        func item(_ title:String,_ action:String,_ checked:Bool=false){let entry=NSMenuItem(title:NSLocalizedString(title,comment:""),action:#selector(toolbarContextAction(_:)),keyEquivalent:"");entry.target=self;entry.representedObject=BlameToolbarContextReceipt(barID:barID,generation:configuration.generation,action:action);entry.isEnabled=available;entry.state=checked ? .on:.off;menu.addItem(entry)}
        item("Customize Toolbar…","customize");item("Manage Toolbars…","manage");item("Reset All Toolbars","reset");menu.addItem(.separator())
        for placement in BlameToolbarPlacement.allCases {item(placement.title,"place."+placement.rawValue,configuration.allBars.first{$0.id==barID}?.placement==placement)}
        menu.addItem(.separator());item("Hide Toolbar","hide");return menu
    }
    @objc private func toolbarContextAction(_ sender:NSMenuItem){
        guard let receipt=sender.representedObject as? BlameToolbarContextReceipt,receipt.generation==configuration.generation,available else{return}
        switch receipt.action {case "customize":customize();case "manage":edit();case "reset":reset();case "hide":hideBar(receipt.barID)
        default:if receipt.action.hasPrefix("place."),let placement=BlameToolbarPlacement(rawValue:String(receipt.action.dropFirst(6))){setPlacement(barID:receipt.barID,placement:placement)}}
    }
}
private final class BlameToolbarContextReceipt:NSObject {let barID:UUID,generation:UUID;let action:String;init(barID:UUID,generation:UUID,action:String){self.barID=barID;self.generation=generation;self.action=action}}

/// A real native handle provides pointer dragging and a menu/accessibility
/// alternative. Dragging only updates a preview until mouse-up; Escape discards.
@MainActor final class BlameToolbarGrip:NSView {
    weak var chrome:BlameToolbarController?
    let barID:UUID
    let generation:UUID
    init(chrome:BlameToolbarController,barID:UUID,frame:NSRect){self.chrome=chrome;self.barID=barID;generation=chrome.configuration.generation;super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.button);setAccessibilityLabel(NSLocalizedString("Move toolbar",comment:""));setAccessibilityIdentifier("TurtleGit.Blame.ToolbarGrip."+barID.uuidString)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    override func draw(_ dirtyRect:NSRect){NSColor.secondaryLabelColor.setFill();for y in stride(from:bounds.midY-6,through:bounds.midY+6,by:4){NSBezierPath(ovalIn:NSRect(x:bounds.midX-3,y:y,width:2,height:2)).fill();NSBezierPath(ovalIn:NSRect(x:bounds.midX+1,y:y,width:2,height:2)).fill()}}
    override func menu(for event:NSEvent)->NSMenu? {guard let chrome,chrome.authenticatedGrip(self) else{return nil};return chrome.contextMenu(barID:barID)}
    override func accessibilityPerformPress()->Bool {guard let chrome,let window,chrome.available,chrome.authenticatedGrip(self) else{return false};chrome.contextMenu(barID:barID).popUp(positioning:nil,at:bounds.origin,in:self);window.makeFirstResponder(self);return true}
    override func mouseDown(with event:NSEvent){
        guard let chrome,window != nil,chrome.authenticatedGrip(self) else{return}
        if event.clickCount==2 {chrome.toggleFloating(barID:barID);return}
        guard chrome.beginDockDrag(barID:barID) else{return}
        BlameToolbarTracking.track(view:self,event:event,update:{chrome.updateDockDrag(point:$0)},finish:{_ = chrome.finishDockDrag(point:$0)},cancel:{chrome.cancelDockDrag()})
    }
}
@MainActor enum BlameToolbarTracking {
    static func track(view:NSView,event:NSEvent,update:(NSPoint)->Void,finish:(NSPoint)->Void,cancel:()->Void){
        guard let window=view.window else{cancel();return}
        while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp,.keyDown]) {
            if next.type == .keyDown {if next.keyCode==53{cancel();return};continue}
            let point=(next.window ?? window).convertPoint(toScreen:next.locationInWindow)
            if next.type == .leftMouseUp{finish(point);return};update(point)
        }
        cancel()
    }
}

@MainActor final class BlameToolbarFloatingController:NSWindowController,NSWindowDelegate {
    let barID:UUID
    private weak var chrome:BlameToolbarController?
    private var applying=false,retired=false,hiddenForMinimize=false
    private var frameTask:Task<Void,Never>?
    private var lastStored:BlameToolbarFloatingRect?
    private let strip=BlameToolbarStrip()
    init(chrome:BlameToolbarController,bar:BlameToolbarBar,owner:NSWindow){
        self.chrome=chrome;barID=bar.id;lastStored=bar.floatingRect
        let stored=bar.floatingRect.map{NSRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height)} ?? NSRect(x:owner.frame.minX+40,y:owner.frame.maxY-100,width:360,height:72)
        let panel=BlameToolbarPanel(contentRect:NSRect(x:0,y:0,width:360,height:72),styleMask:[.titled,.closable,.resizable,.utilityWindow],backing:.buffered,defer:false)
        panel.setFrame(chrome.clampedFrame(stored),display:false)
        panel.isReleasedWhenClosed=false;panel.minSize=NSSize(width:160,height:56);panel.hidesOnDeactivate=false;panel.blameOwner=chrome.owner
        super.init(window:panel);panel.delegate=self;panel.contentView=strip;owner.addChildWindow(panel,ordered:.above);refresh(bar:bar,owner:owner)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func refresh(bar:BlameToolbarBar,owner:NSWindow){
        guard !retired,let window,let chrome else{return};if window.title != bar.name{window.title=bar.name};if window.appearance !== owner.appearance{window.appearance=owner.appearance};if window.alphaValue != owner.alphaValue{window.alphaValue=owner.alphaValue};strip.configure(chrome:chrome,bar:bar)
        if bar.floatingRect != lastStored,let stored=bar.floatingRect {
            let restored=chrome.clampedFrame(NSRect(x:stored.x,y:stored.y,width:stored.width,height:stored.height));if restored != window.frame{applying=true;window.setFrame(restored,display:false);applying=false};lastStored=stored
        }
        let fitted=chrome.clampedFrame(window.frame)
        if fitted != window.frame {applying=true;window.setFrame(fitted,display:false);applying=false}
        if owner.isMiniaturized || !owner.isVisible{hiddenForMinimize=true;if window.isVisible{window.orderOut(nil)}}else if hiddenForMinimize{hiddenForMinimize=false;if let panel=window as? NSPanel{chrome.presentFloating(panel)}}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {chrome?.hideBar(barID);return false}
    func windowDidMove(_ notification:Notification){saveFrame()}
    func windowDidResize(_ notification:Notification){saveFrame()}
    private func saveFrame(){guard !applying,!retired else{return};frameTask?.cancel();frameTask=Task{[weak self] in try? await Task.sleep(nanoseconds:180_000_000);guard let self,!Task.isCancelled,!retired,let frame=window?.frame else{return};chrome?.captureFloatingFrame(barID:barID,frame:frame)}}
    func retire(){guard !retired else{return};retired=true;frameTask?.cancel();frameTask=nil;strip.clear();window?.delegate=nil;window?.parent?.removeChildWindow(window!);window?.close();chrome=nil}
}
@MainActor private final class BlameToolbarPanel:NSPanel {
    weak var blameOwner:BlameWindowController?
    override var canBecomeKey:Bool {true}
    override func performKeyEquivalent(with event:NSEvent)->Bool {BlameWindowController.routeCommandKey(event,from:self) || super.performKeyEquivalent(with:event)}
}

@MainActor final class BlameToolbarSpacer:NSView {
    weak var chrome:BlameToolbarController?;let barID:UUID,index:Int
    init(chrome:BlameToolbarController,barID:UUID,index:Int){self.chrome=chrome;self.barID=barID;self.index=index;super.init(frame:NSRect(x:0,y:0,width:12,height:24));setAccessibilityLabel(NSLocalizedString("Toolbar space",comment:""));setAccessibilityIdentifier("TurtleGit.Blame.ToolbarSpacer."+barID.uuidString+"."+String(index))}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    override func mouseDown(with event:NSEvent){guard window != nil,(superview as? BlameToolbarStrip)?.ownsSpacer(self,index:index)==true,event.modifierFlags.contains(.option),let chrome,chrome.beginCommandDrag(barID:barID,index:index) else{return};BlameToolbarTracking.track(view:self,event:event,update:{_ in},finish:{point in let destination=chrome.commandDropTarget(at:point);_ = chrome.finishCommandDrag(destinationID:destination?.0,index:destination?.1 ?? 0)},cancel:{chrome.cancelCommandDrag()})}
}
