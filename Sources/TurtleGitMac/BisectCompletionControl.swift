// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

/// CProgressDlg post-command button, including its native menu and icon order.
@MainActor final class BisectNativeCompletionControl:NSSegmentedControl {
    let lifetime=TransportControlLifetime()
    private weak var originalOwner:NSWindow?
    private var boundOwner=false
    var ownsCurrentWindow:Bool {boundOwner && originalOwner != nil && window===originalOwner && !lifetime.retired}
    var primaryKeyAction:(()->Void)?
    override var acceptsFirstResponder:Bool {isEnabled && !lifetime.retired}
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow()
        if let window {
            if boundOwner,originalOwner !== window {primaryKeyAction=nil;lifetime.retire();isEnabled=false;return}
            if !boundOwner {originalOwner=window;boundOwner=true}
        }
        lifetime.observe(self)
    }
    @discardableResult func showActionMenu()->Bool {
        guard isEnabled,ownsCurrentWindow,let window,window.attachedSheet==nil,let menu=menu(forSegment:1) else{return false}
        return menu.popUp(positioning:nil,at:NSPoint(x:bounds.maxX,y:bounds.minY),in:self)
    }
    override func accessibilityPerformShowMenu()->Bool {showActionMenu()}
    override func keyDown(with event:NSEvent) {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==118 && flags.isEmpty || event.keyCode==125 && flags == .option || event.keyCode==109 && flags == .shift {_=showActionMenu();return}
        if [36,76,49].contains(event.keyCode),flags.isEmpty,isEnabled,ownsCurrentWindow,event.window===window {primaryKeyAction?();return}
        super.keyDown(with:event)
    }
}
struct BisectCompletionControl:NSViewRepresentable {
    @ObservedObject var model:BisectWindowModel
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->BisectNativeCompletionControl {
        let control=BisectNativeCompletionControl(labels:["",""],trackingMode:.momentary,target:context.coordinator,action:#selector(Coordinator.clicked(_:)))
        control.segmentStyle = .rounded;control.identifier = .init("Bisect completion action")
        control.setAccessibilityLabel(NSLocalizedString("Bisect post-actions",comment:""))
        context.coordinator.control=control
        control.primaryKeyAction={ [weak coordinator=context.coordinator] in coordinator?.invokePrimary() }
        control.lifetime.onRetire={ [weak control,weak coordinator=context.coordinator] in control?.primaryKeyAction=nil;coordinator?.retire() }
        return control
    }
    func updateNSView(_ control:BisectNativeCompletionControl,context:Context) {
        guard !control.lifetime.retired else{control.isEnabled=false;return}
        let coordinator=context.coordinator;coordinator.bind(model)
        let receipt=model.formContext,actions=model.postActions
        coordinator.updatePrimary(actions.first,context:receipt)
        control.isEnabled=enabled && !model.retired && !model.activeReview && !model.hasPendingWork && model.presentationAvailable() && !actions.isEmpty
        if let action=coordinator.primary,actions.contains(action) {
            let title=model.title(action)
            control.setLabel(title,forSegment:0);control.toolTip=title
            control.setImage(model.icon(action).contextImage(defaults:model.preferences),forSegment:0)
            control.setWidth(min(260,max(110,ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width)+46)),forSegment:0)
            control.cell?.lineBreakMode = .byTruncatingMiddle
        }
        control.setWidth(24,forSegment:1);control.setShowsMenuIndicator(true,forSegment:1)
        let menu=NSMenu();menu.delegate=coordinator;menu.autoenablesItems=false
        for action in actions {
            let item=NSMenuItem(title:model.title(action),action:#selector(Coordinator.chosen(_:)),keyEquivalent:"")
            item.target=coordinator;item.representedObject=Action(action:action,context:receipt)
            item.image=model.icon(action).contextImage(defaults:model.preferences);item.state=action==coordinator.primary ? .on:.off
            item.isEnabled=control.isEnabled;menu.addItem(item)
        }
        control.setMenu(menu,forSegment:1);control.invalidateIntrinsicContentSize()
    }
    static func dismantleNSView(_ control:BisectNativeCompletionControl,coordinator:Coordinator) {
        control.primaryKeyAction=nil;control.lifetime.retire();coordinator.retire();control.menu(forSegment:1)?.delegate=nil;control.setMenu(nil,forSegment:1)
        control.target=nil;control.action=nil;control.isEnabled=false
    }
    private final class Action {
        let action:BisectPostAction,context:BisectWindowModel.FormContext
        init(action:BisectPostAction,context:BisectWindowModel.FormContext){self.action=action;self.context=context}
    }
    @MainActor final class Coordinator:NSObject,NSMenuDelegate {
        weak var control:BisectNativeCompletionControl?
        private weak var model:BisectWindowModel?
        private var observation:AnyCancellable?,menuContext:BisectWindowModel.FormContext?
        private var primaryContext:BisectWindowModel.FormContext?
        private(set) var primary:BisectPostAction?
        private var retired=false,menuEpoch=UUID()
        func bind(_ model:BisectWindowModel) {
            guard !retired,self.model !== model else{return};self.model=model
            observation=model.objectWillChange.sink{[weak self] _ in self?.menuContext=nil;self?.menuEpoch=UUID()}
        }
        func updatePrimary(_ first:BisectPostAction?,context:BisectWindowModel.FormContext) {
            if primaryContext != context {primaryContext=context;primary=first}
        }
        func retire(){retired=true;menuContext=nil;observation=nil;model=nil;primary=nil}
        private var ready:Bool {
            guard !retired,let control,control.isEnabled,control.ownsCurrentWindow,let window=control.window,let model else{return false}
            return !model.retired && !model.activeReview && !model.hasPendingWork && model.presentationAvailable() && window.attachedSheet==nil
        }
        func invokePrimary() {
            guard ready,let model,let action=primary,let context=primaryContext,context==model.formContext else{return}
            // Retire this receipt before calling a model which publishes or
            // transfers ownership synchronously (Submodule Update in particular).
            primaryContext=nil;menuContext=nil
            model.perform(action,context:context)
        }
        @objc func clicked(_ sender:NSSegmentedControl){guard sender===control,sender.selectedSegment==0 else{return};invokePrimary()}
        func menuWillOpen(_ menu:NSMenu) {
            menuContext=nil;menuEpoch=UUID()
            guard ready,let control,control.menu(forSegment:1)===menu,let model else{for item in menu.items{item.isEnabled=false};return}
            menuContext=model.formContext
            for item in menu.items {item.isEnabled=(item.representedObject as? Action)?.context==model.formContext}
        }
        func menuDidClose(_ menu:NSMenu){let epoch=menuEpoch;DispatchQueue.main.async{[weak self] in guard let self,self.menuEpoch==epoch else{return};self.menuContext=nil}}
        @objc func chosen(_ item:NSMenuItem) {
            guard ready,let control,item.menu===control.menu(forSegment:1),item.isEnabled,let model,
                  let receipt=item.representedObject as? Action,menuContext==receipt.context,receipt.context==model.formContext,
                  model.postActions.contains(receipt.action) else{return}
            primary=receipt.action;primaryContext=nil;menuContext=nil
            model.perform(receipt.action,context:receipt.context)
        }
    }
}
