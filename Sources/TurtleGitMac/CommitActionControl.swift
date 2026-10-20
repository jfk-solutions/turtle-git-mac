// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

/// One native split control, like CommitDlg's CSplitButton. The primary segment
/// repeats the remembered completion action; the arrow keeps the source order.
@MainActor final class CommitNativeActionControl:NSSegmentedControl {
    let lifetime=TransportControlLifetime()
    var primaryKeyAction:(()->Void)?
    override var acceptsFirstResponder:Bool {isEnabled && !lifetime.retired}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();lifetime.observe(self)}
    @discardableResult func showActionMenu()->Bool {
        guard isEnabled,!lifetime.retired,segmentCount==2,let window,window.attachedSheet==nil,let menu=menu(forSegment:1) else{return false}
        return menu.popUp(positioning:nil,at:NSPoint(x:bounds.maxX,y:bounds.minY),in:self)
    }
    override func accessibilityPerformShowMenu()->Bool {showActionMenu()}
    override func keyDown(with event:NSEvent) {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==118 && flags.isEmpty || event.keyCode==125 && flags == .option || event.keyCode==109 && flags == .shift { _=showActionMenu();return }
        if [36,76,49].contains(event.keyCode),flags.isEmpty,isEnabled,!lifetime.retired {
            primaryKeyAction?();return
        }
        super.keyDown(with:event)
    }
}
struct CommitActionControl:NSViewRepresentable {
    @ObservedObject var model:CommitWindowModel
    @Environment(\.isEnabled) private var environmentEnabled
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->CommitNativeActionControl {
        let control=CommitNativeActionControl(labels:["Commit",""],trackingMode:.momentary,target:context.coordinator,action:#selector(Coordinator.clicked(_:)))
        control.segmentStyle = .rounded;control.setWidth(24,forSegment:1);control.setShowsMenuIndicator(true,forSegment:1)
        control.identifier = .init("TurtleGit.Commit.Action");control.setAccessibilityLabel(NSLocalizedString("Commit actions",comment:""))
        context.coordinator.control=control
        control.primaryKeyAction={ [weak coordinator=context.coordinator] in coordinator?.invokePrimary() }
        control.lifetime.onRetire={ [weak coordinator=context.coordinator,weak control] in control?.primaryKeyAction=nil;coordinator?.retire() }
        return control
    }
    func updateNSView(_ control:CommitNativeActionControl,context:Context) {
        let coordinator=context.coordinator
        guard !control.lifetime.retired else {control.isEnabled=false;return}
        coordinator.bind(model)
        let split=model.replaySplit==nil && model.historyCombine==nil
        let count=split ? 2:1
        if control.segmentCount != count {control.segmentCount=count}
        control.isEnabled=environmentEnabled && model.canCommit && !model.inputsBlocked
        let title=NSLocalizedString(model.currentCompletionAction.rawValue,comment:"")
        control.setLabel(title,forSegment:0)
        let width=ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width)+30
        control.setWidth(max(90,width),forSegment:0)
        control.toolTip=title
        if split {
            control.setWidth(24,forSegment:1);control.setShowsMenuIndicator(true,forSegment:1)
            let menu=control.menu(forSegment:1) ?? NSMenu()
            if menu.numberOfItems==0 {
                menu.delegate=coordinator;menu.autoenablesItems=false
                for action in CommitWindowModel.CompletionAction.allCases {
                    let item=NSMenuItem(title:NSLocalizedString(action.rawValue,comment:""),action:#selector(Coordinator.chosen(_:)),keyEquivalent:"")
                    item.target=coordinator;item.representedObject=action.rawValue;menu.addItem(item)
                }
                control.setMenu(menu,forSegment:1)
            }
            for item in menu.items {
                let action=(item.representedObject as? String).flatMap(CommitWindowModel.CompletionAction.init(rawValue:))
                item.state=action==model.currentCompletionAction ? .on:.off;item.isEnabled=control.isEnabled
                item.image=(action == .push ? MenuIcon.push:MenuIcon.commit).contextImage(defaults:model.messageEditorPreferences)
            }
        }
        control.invalidateIntrinsicContentSize()
    }
    static func dismantleNSView(_ control:CommitNativeActionControl,coordinator:Coordinator) {
        control.primaryKeyAction=nil;control.lifetime.retire();coordinator.retire()
        if control.segmentCount>1 {control.menu(forSegment:1)?.delegate=nil;control.setMenu(nil,forSegment:1)}
        control.target=nil;control.action=nil;control.isEnabled=false
    }
    @MainActor final class Coordinator:NSObject,NSMenuDelegate {
        weak var control:CommitNativeActionControl?
        private weak var model:CommitWindowModel?
        private var observation:AnyCancellable?,invoke:((CommitWindowModel.CompletionAction)->Void)?
        private var retired=false,receipt=UUID()
        func bind(_ model:CommitWindowModel) {
            guard !retired,self.model !== model else{return};self.model=model;invoke=nil
            observation=model.objectWillChange.sink{[weak self] _ in self?.invoke=nil;self?.receipt=UUID()}
        }
        func retire(){retired=true;invoke=nil;observation=nil;model=nil}
        private var ready:Bool {
            guard !retired,let model,let control,control.isEnabled,!control.lifetime.retired,let window=control.window else{return false}
            return model.messageFocusAvailable && model.canCommit && !model.inputsBlocked && model.comparisonWindow === window && window.attachedSheet==nil
        }
        func invokePrimary(){guard ready else{return};model?.commitCurrentAction()}
        @objc func clicked(_ sender:NSSegmentedControl) {guard sender===control,sender.selectedSegment==0 else{return};invokePrimary()}
        func menuWillOpen(_ menu:NSMenu) {
            invoke=nil;receipt=UUID()
            for item in menu.items {item.isEnabled=ready}
            guard ready,let control,control.segmentCount==2,control.menu(forSegment:1)===menu,let model else{return}
            invoke={ [weak self,weak model] action in guard let self,self.ready,let model,model.replaySplit==nil,model.historyCombine==nil else{return};model.commit(action)}
            for item in menu.items {item.isEnabled=true}
        }
        func menuDidClose(_ menu:NSMenu){let captured=receipt;DispatchQueue.main.async{[weak self] in guard let self,self.receipt==captured else{return};self.invoke=nil}}
        @objc func chosen(_ item:NSMenuItem) {
            guard ready,let control,control.segmentCount==2,item.menu===control.menu(forSegment:1),item.isEnabled,
                  let raw=item.representedObject as? String,let action=CommitWindowModel.CompletionAction(rawValue:raw),let invoke else{return}
            self.invoke=nil;invoke(action)
        }
    }
}
