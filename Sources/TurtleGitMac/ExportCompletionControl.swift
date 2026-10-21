// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class ExportNativeCompletionControl:NSSegmentedControl {
    let lifetime=TransportControlLifetime()
    private weak var owner:NSWindow?
    private var bound=false
    var invoke:(()->Void)?
    var ownsWindow:Bool {bound && owner != nil && window===owner && !lifetime.retired}
    override var acceptsFirstResponder:Bool {isEnabled && ownsWindow}
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow()
        if let window {if bound,owner !== window{invoke=nil;lifetime.retire();isEnabled=false;return};if !bound{owner=window;bound=true}}
        lifetime.observe(self)
    }
    @discardableResult func showActionMenu()->Bool {
        guard isEnabled,ownsWindow,window?.attachedSheet==nil,let menu=menu(forSegment:1) else{return false}
        return menu.popUp(positioning:nil,at:NSPoint(x:bounds.maxX,y:bounds.minY),in:self)
    }
    override func accessibilityPerformShowMenu()->Bool {showActionMenu()}
    override func keyDown(with event:NSEvent){
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==118 && flags.isEmpty || event.keyCode==125 && flags == .option || event.keyCode==109 && flags == .shift{_ = showActionMenu();return}
        if [36,76,49].contains(event.keyCode),flags.isEmpty,event.window===window,isEnabled,ownsWindow{invoke?();return}
        super.keyDown(with:event)
    }
}
struct ExportCompletionControl:NSViewRepresentable {
    @ObservedObject var model:ExportProgressWindowModel
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->ExportNativeCompletionControl {
        let control=ExportNativeCompletionControl(labels:["",""],trackingMode:.momentary,target:context.coordinator,action:#selector(Coordinator.clicked(_:)))
        control.segmentStyle = .rounded;control.identifier = .init("Export completion action")
        control.setAccessibilityLabel(NSLocalizedString("Export post-actions",comment:""));context.coordinator.control=control
        control.invoke={ [weak coordinator=context.coordinator] in coordinator?.primary() }
        control.lifetime.onRetire={ [weak control,weak coordinator=context.coordinator] in control?.invoke=nil;coordinator?.retire() }
        return control
    }
    func updateNSView(_ control:ExportNativeCompletionControl,context:Context){
        guard !control.lifetime.retired else{control.isEnabled=false;return}
        let coordinator=context.coordinator;coordinator.bind(model);coordinator.receipt=model.actionReceipt
        let title=NSLocalizedString("Show in Finder",comment:"")
        control.setLabel(title,forSegment:0);control.setImage(MenuIcon.explore.contextImage(defaults:model.presentationPreferences),forSegment:0)
        control.setWidth(min(260,max(125,ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width)+42)),forSegment:0)
        control.setWidth(24,forSegment:1);control.setShowsMenuIndicator(true,forSegment:1);control.toolTip=title;control.cell?.lineBreakMode = .byTruncatingMiddle
        control.isEnabled=enabled && model.canExplore
        let menu=NSMenu();menu.autoenablesItems=false;menu.delegate=coordinator
        let item=NSMenuItem(title:title,action:#selector(Coordinator.chosen(_:)),keyEquivalent:"");item.target=coordinator;item.image=MenuIcon.explore.contextImage(defaults:model.presentationPreferences);item.isEnabled=control.isEnabled;item.representedObject=Receipt(model.actionReceipt);menu.addItem(item);control.setMenu(menu,forSegment:1)
    }
    static func dismantleNSView(_ control:ExportNativeCompletionControl,coordinator:Coordinator){control.invoke=nil;control.lifetime.retire();coordinator.retire();control.menu(forSegment:1)?.delegate=nil;control.setMenu(nil,forSegment:1);control.target=nil;control.action=nil;control.isEnabled=false}
    private final class Receipt {let value:ExportProgressWindowModel.ActionReceipt;init(_ value:ExportProgressWindowModel.ActionReceipt){self.value=value}}
    @MainActor final class Coordinator:NSObject,NSMenuDelegate {
        weak var control:ExportNativeCompletionControl?
        private weak var model:ExportProgressWindowModel?
        var receipt:ExportProgressWindowModel.ActionReceipt?
        private var menuReceipt:ExportProgressWindowModel.ActionReceipt?,observation:AnyCancellable?
        private var retired=false,menuEpoch=UUID()
        func bind(_ model:ExportProgressWindowModel){guard !retired,self.model !== model else{return};self.model=model;observation=model.objectWillChange.sink{[weak self] _ in self?.menuReceipt=nil;self?.menuEpoch=UUID()}}
        func retire(){retired=true;model=nil;receipt=nil;menuReceipt=nil;observation=nil}
        private var ready:Bool { !retired && control?.isEnabled==true && control?.ownsWindow==true && control?.window?.attachedSheet==nil && model?.canExplore==true }
        func primary(){guard ready,let model,let receipt,receipt==model.actionReceipt else{return};self.receipt=nil;menuReceipt=nil;model.explore(receipt:receipt)}
        @objc func clicked(_ sender:NSSegmentedControl){guard sender===control,sender.selectedSegment==0 else{return};primary()}
        func menuWillOpen(_ menu:NSMenu){menuReceipt=nil;menuEpoch=UUID();guard ready,menu===control?.menu(forSegment:1),let model else{menu.items.forEach{$0.isEnabled=false};return};menuReceipt=model.actionReceipt;menu.items.forEach{$0.isEnabled=($0.representedObject as? Receipt)?.value==model.actionReceipt}}
        func menuDidClose(_ menu:NSMenu){let epoch=menuEpoch;DispatchQueue.main.async{[weak self] in guard let self,self.menuEpoch==epoch else{return};self.menuReceipt=nil}}
        @objc func chosen(_ item:NSMenuItem){guard ready,item.menu===control?.menu(forSegment:1),item.isEnabled,let captured=item.representedObject as? Receipt,menuReceipt==captured.value,let model,model.actionReceipt==captured.value else{return};receipt=nil;menuReceipt=nil;model.explore(receipt:captured.value)}
    }
}
