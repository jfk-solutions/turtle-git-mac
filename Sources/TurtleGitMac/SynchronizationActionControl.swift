// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

/// SyncDlg's four CSplitButtons: the main segment repeats the remembered
/// operation, while the arrow exposes the complete ordered source menu.
enum SynchronizationActionGroup:String,CaseIterable {
    case pull,push,submodule,stash
    var label:String {switch self {case .pull:return "Pull actions";case .push:return "Push actions";case .submodule:return "Submodule actions";case .stash:return "Stash actions"}}
    var titles:[String] {
        switch self {
        case .pull:return ["Pull","Fetch","Fetch & Rebase","Fetch All","Remote Update","Cleanup stale remote branches","Compare Tags"]
        case .push:return ["Push","Push tags","Push notes"]
        case .submodule:return SynchronizationSubmoduleAction.allCases.map(\.title)
        case .stash:return SynchronizationStashAction.allCases.map(\.title)
        }
    }
    var icons:[MenuIcon] {
        switch self {
        case .pull:return [.pull,.fetch,.rebase,.fetch,.fetch,.clean,.tag]
        case .push:return [.push,.tag,.push]
        case .submodule:return SynchronizationSubmoduleAction.allCases.map(\.icon)
        case .stash:return SynchronizationStashAction.allCases.map(\.icon)
        }
    }
    @MainActor func selectedIndex(_ model:SynchronizationWindowModel)->Int {
        switch self {
        case .pull:
            if model.compareTagsSelected{return 6}
            let actions:[SynchronizationTransportAction]=[.pull,.fetch,.fetchAndRebase,.fetchAllBranches,.remoteUpdate,.prune];return actions.firstIndex(of:model.pullAction) ?? 0
        case .push:let actions:[SynchronizationTransportAction]=[.push,.pushTags,.pushNotes];return actions.firstIndex(of:model.pushAction) ?? 0
        case .submodule:return SynchronizationSubmoduleAction.allCases.firstIndex(of:model.submoduleAction) ?? 0
        case .stash:return SynchronizationStashAction.allCases.firstIndex(of:model.stashAction) ?? 0
        }
    }
    @MainActor func perform(_ index:Int,model:SynchronizationWindowModel,shift:Bool) {
        guard titles.indices.contains(index),model.canUseActionControl else{return}
        switch self {
        case .pull:
            if index==6 {model.compareTags(shift:shift)}
            else {let actions:[SynchronizationTransportAction]=[.pull,.fetch,.fetchAndRebase,.fetchAllBranches,.remoteUpdate,.prune];model.performPullAction(actions[index],shift:shift)}
        case .push:
            let actions:[SynchronizationTransportAction]=[.push,.pushTags,.pushNotes];model.push(actions[index],shift:shift)
        case .submodule:model.submodule(SynchronizationSubmoduleAction.allCases[index],shift:shift)
        case .stash:model.stash(SynchronizationStashAction.allCases[index],shift:shift)
        }
    }
}

@MainActor final class SynchronizationNativeActionControl:NSSegmentedControl {
    let lifetime=TransportControlLifetime()
    var primaryKeyAction:((Bool)->Void)?
    override var acceptsFirstResponder:Bool {isEnabled && !lifetime.retired}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();lifetime.observe(self)}
    @discardableResult func showActionMenu()->Bool {
        guard isEnabled,!lifetime.retired,let window,window.attachedSheet==nil,NSApp.modalWindow==nil,let menu=menu(forSegment:1) else{return false}
        return menu.popUp(positioning:nil,at:NSPoint(x:bounds.maxX,y:bounds.minY),in:self)
    }
    override func accessibilityPerformShowMenu()->Bool {showActionMenu()}
    override func keyDown(with event:NSEvent) {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==118 && flags.isEmpty || event.keyCode==125 && flags == .option || event.keyCode==109 && flags == .shift {_=showActionMenu();return}
        if [36,76,49].contains(event.keyCode),flags.isEmpty || flags == .shift {primaryKeyAction?(flags.contains(.shift));return}
        super.keyDown(with:event)
    }
}

struct SynchronizationActionControl:NSViewRepresentable {
    @ObservedObject var model:SynchronizationWindowModel
    let group:SynchronizationActionGroup
    @Environment(\.isEnabled) private var environmentEnabled
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->SynchronizationNativeActionControl {
        let control=SynchronizationNativeActionControl(labels:["",""],trackingMode:.momentary,target:context.coordinator,action:#selector(Coordinator.clicked(_:)))
        control.segmentStyle = .rounded;control.setWidth(24,forSegment:1);control.setShowsMenuIndicator(true,forSegment:1)
        control.identifier = .init("TurtleGit.Sync.Action."+group.rawValue)
        control.setAccessibilityLabel(NSLocalizedString(group.label,comment:""))
        context.coordinator.control=control
        control.primaryKeyAction={ [weak coordinator=context.coordinator] shift in coordinator?.invokePrimary(shift:shift) }
        control.lifetime.onRetire={ [weak coordinator=context.coordinator,weak control] in control?.primaryKeyAction=nil;coordinator?.retire() }
        return control
    }
    func updateNSView(_ control:SynchronizationNativeActionControl,context:Context) {
        guard !control.lifetime.retired else {control.isEnabled=false;return}
        let coordinator=context.coordinator;coordinator.bind(model,group:group)
        control.isEnabled=environmentEnabled && model.canUseActionControl
        let selected=group.selectedIndex(model),title=NSLocalizedString(group.titles[selected],comment:"")
        control.setLabel(title,forSegment:0);control.setImage(group.icons[selected].contextImage(defaults:model.preferences),forSegment:0)
        let width=ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width)+56
        control.setWidth(max(90,width),forSegment:0);control.toolTip=title
        let menu=control.menu(forSegment:1) ?? NSMenu()
        if menu.numberOfItems==0 {
            menu.autoenablesItems=false;menu.delegate=coordinator
            for (index,title) in group.titles.enumerated() {
                let item=NSMenuItem(title:NSLocalizedString(title,comment:""),action:#selector(Coordinator.chosen(_:)),keyEquivalent:"")
                item.target=coordinator;item.representedObject=index;menu.addItem(item)
            }
            control.setMenu(menu,forSegment:1)
        }
        for (index,item) in menu.items.enumerated() {
            item.state=index==selected ? .on:.off;item.isEnabled=control.isEnabled
            item.image=group.icons[index].contextImage(defaults:model.preferences)
        }
        control.invalidateIntrinsicContentSize()
    }
    static func dismantleNSView(_ control:SynchronizationNativeActionControl,coordinator:Coordinator) {
        control.primaryKeyAction=nil;control.lifetime.retire();coordinator.retire()
        control.menu(forSegment:1)?.delegate=nil;control.setMenu(nil,forSegment:1)
        control.target=nil;control.action=nil;control.isEnabled=false
    }
    @MainActor final class Coordinator:NSObject,NSMenuDelegate {
        weak var control:SynchronizationNativeActionControl?
        private weak var model:SynchronizationWindowModel?
        private var group:SynchronizationActionGroup = .pull
        private var observation:AnyCancellable?,invoke:((Int,Bool)->Void)?
        private var retired=false,receipt=UUID()
        func bind(_ model:SynchronizationWindowModel,group:SynchronizationActionGroup) {
            guard !retired else{return}
            guard self.model !== model || self.group != group else{return}
            self.model=model;self.group=group;invoke=nil
            observation=model.objectWillChange.sink { [weak self] _ in self?.invoke=nil;self?.receipt=UUID() }
        }
        func retire(){retired=true;invoke=nil;observation=nil;model=nil}
        private var ready:Bool {
            guard !retired,let model,let control,control.isEnabled,!control.lifetime.retired,let window=control.window else{return false}
            return model.canUseActionControl && model.window === window && window.attachedSheet==nil && NSApp.modalWindow==nil
        }
        func invokePrimary(shift:Bool?=nil) {
            guard ready,let model else{return}
            group.perform(group.selectedIndex(model),model:model,shift:shift ?? NSEvent.modifierFlags.contains(.shift))
        }
        @objc func clicked(_ sender:NSSegmentedControl) {guard sender===control,sender.selectedSegment==0 else{return};invokePrimary()}
        func menuWillOpen(_ menu:NSMenu) {
            invoke=nil;receipt=UUID();for item in menu.items {item.isEnabled=ready}
            guard ready,let model,let control,control.menu(forSegment:1)===menu else{return}
            let captured=model.formContext,group=self.group
            invoke={ [weak self,weak model] index,shift in
                guard let self,self.ready,let model,model.acceptsForm(captured) else{return}
                group.perform(index,model:model,shift:shift)
            }
        }
        func menuDidClose(_ menu:NSMenu) {let captured=receipt;DispatchQueue.main.async { [weak self] in guard let self,self.receipt==captured else{return};self.invoke=nil }}
        @objc func chosen(_ item:NSMenuItem) {
            guard ready,let control,item.menu===control.menu(forSegment:1),item.isEnabled,let index=item.representedObject as? Int,group.titles.indices.contains(index),let invoke else{return}
            self.invoke=nil;invoke(index,NSEvent.modifierFlags.contains(.shift))
        }
    }
}
