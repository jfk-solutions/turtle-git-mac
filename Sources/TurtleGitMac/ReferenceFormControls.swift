// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class ReferenceFormNativeWindow:NSWindow {
    weak var formCommands:ReferenceFormCommandRouter?
    // NSHostingController recomputes native size limits as its root changes.
    // Retain the dialog's declared usability floor across those publications.
    var referenceMinimumContentSize=NSSize.zero {
        didSet {super.contentMinSize=bounded(super.contentMinSize,by:referenceMinimumContentSize);super.minSize=bounded(super.minSize,by:referenceMinimumFrameSize)}
    }
    var referenceMinimumFrameSize:NSSize {
        get {frameRect(forContentRect:NSRect(origin:.zero,size:referenceMinimumContentSize)).size}
        set {referenceMinimumContentSize=contentRect(forFrameRect:NSRect(origin:.zero,size:newValue)).size}
    }
    private func bounded(_ size:NSSize,by floor:NSSize)->NSSize {NSSize(width:max(size.width,floor.width),height:max(size.height,floor.height))}
    override var contentMinSize:NSSize {
        get {bounded(super.contentMinSize,by:referenceMinimumContentSize)}
        set {super.contentMinSize=bounded(newValue,by:referenceMinimumContentSize)}
    }
    override var minSize:NSSize {
        get {bounded(super.minSize,by:referenceMinimumFrameSize)}
        set {super.minSize=bounded(newValue,by:referenceMinimumFrameSize)}
    }
    override func performKeyEquivalent(with event:NSEvent)->Bool {formCommands?.performKeyEquivalent(event)==true || super.performKeyEquivalent(with:event)}
}
struct ReferenceFormCommand {
    let id:String,title:String,key:String
    var sourceKey:String?=nil
    var icon:MenuIcon = .settings
    var enabled=true
    var focus:String?=nil
    let action:()->Void
}
/// Each owning form has its own menu, current publication and focus request.
/// No queued picker or retained menu action can target a replacement form.
@MainActor final class ReferenceFormCommandRouter:NSObject,NSMenuDelegate {
    private final class Invocation {let id:String,epoch:UUID;init(_ id:String,_ epoch:UUID){self.id=id;self.epoch=epoch}}
    private weak var window:ReferenceFormNativeWindow?,installedMenu:NSMenu?
    private var root:NSMenuItem?,entries:[ReferenceFormCommand]=[],epoch=UUID(),ready=false,retired=false,tracking=false
    private var preferences=UserDefaults.standard
    private var available:()->Bool={false},observers:[NSObjectProtocol]=[],observation:AnyCancellable?,pendingFocus:String?
    var applicationMenu:()->NSMenu?={NSApp.mainMenu}
    var keyWindow:()->NSWindow?={NSApp.keyWindow}
    var menu:NSMenu? {root?.submenu}
    func attach(_ window:ReferenceFormNativeWindow) {
        guard !retired,self.window !== window else{return};detach();self.window=window;window.formCommands=self
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main){[weak self] note in MainActor.assumeIsolated {
                guard let self else{return}
                if note.name == NSWindow.willCloseNotification {self.retire()}
                else if note.name == NSWindow.didBecomeKeyNotification {self.install()}
                else {self.removeMenu()}
            }})
        }
        install()
    }
    func update(_ entries:[ReferenceFormCommand],preferences:UserDefaults,available:@escaping()->Bool,changes:AnyPublisher<Void,Never>) {
        guard !retired else{return};self.entries=entries;self.preferences=preferences;self.available=available;epoch=UUID();ready=true
        observation=changes.sink{[weak self] _ in self?.invalidate()}
        install();restoreFocus()
    }
    private var active:Bool {!retired && ready && window != nil && keyWindow() === window && window?.attachedSheet==nil && available()}
    private func invalidate(){epoch=UUID();ready=false;for item in menu?.items ?? [] {item.isEnabled=false}}
    func install() {
        guard !retired,!tracking,let window,keyWindow() === window,let main=applicationMenu() else{return}
        if installedMenu !== main || root?.menu !== main {
            removeMenu();installedMenu=main
            for old in main.items where old.identifier?.rawValue == "TurtleGit.ReferenceForm.Commands" {main.removeItem(old)}
            let item=NSMenuItem(title:NSLocalizedString("Form",comment:""),action:nil,keyEquivalent:"")
            item.identifier = .init("TurtleGit.ReferenceForm.Commands");item.submenu=NSMenu(title:item.title);item.submenu?.delegate=self;item.submenu?.autoenablesItems=false;root=item
            let index=main.items.firstIndex{item in item.submenu === NSApp.windowsMenu || item.submenu === NSApp.helpMenu} ?? main.numberOfItems
            main.insertItem(item,at:index)
        }
        guard let menu else{return};menu.removeAllItems()
        for entry in entries {
            let item=NSMenuItem(title:NSLocalizedString(entry.title,comment:""),action:#selector(invoke(_:)),keyEquivalent:entry.key)
            item.keyEquivalentModifierMask=[.command,.option];item.target=self;item.identifier = .init("TurtleGit.ReferenceForm."+entry.id)
            item.representedObject=Invocation(entry.id,epoch);item.isEnabled=active && entry.enabled;item.image=entry.icon.contextImage(defaults:preferences);menu.addItem(item)
        }
    }
    private func removeMenu(){if let root,let menu=root.menu {menu.removeItem(root)};root=nil;installedMenu=nil;tracking=false}
    private func detach(){for observer in observers{NotificationCenter.default.removeObserver(observer)};observers=[];if window?.formCommands === self {window?.formCommands=nil};window=nil;removeMenu()}
    func retire(){guard !retired else{return};retired=true;invalidate();pendingFocus=nil;observation=nil;entries=[];available={false};detach()}
    @objc func invoke(_ item:NSMenuItem) {
        guard active,item.menu === menu,item.isEnabled,let invocation=item.representedObject as? Invocation,invocation.epoch==epoch,
              let entry=entries.first(where:{$0.id==invocation.id}),entry.enabled else{return}
        perform(entry)
    }
    private func perform(_ entry:ReferenceFormCommand) {guard active,entry.enabled else{return};epoch=UUID();for item in menu?.items ?? [] {item.isEnabled=false};pendingFocus=entry.focus;entry.action();DispatchQueue.main.async{[weak self] in self?.restoreFocus()}}
    private func restoreFocus() {
        guard active,let id=pendingFocus,let window,let root=window.contentView else{return}
        @MainActor func textEditor(_ view:NSView)->NSTextView? {if let text=view as? NSTextView,text.isEditable{return text};for child in view.subviews{if let text=textEditor(child){return text}};return nil}
        @MainActor func find(_ view:NSView)->NSView? {
            let matches=view.identifier?.rawValue==id || view.accessibilityLabel()==id || (view as? NSTextField)?.placeholderString==id
            if matches {
                if let control=view as? NSControl,!control.isEnabled{return nil}
                return textEditor(view) ?? view
            }
            for child in view.subviews {if let found=find(child){return found}};return nil
        }
        if let control=find(root),window.makeFirstResponder(control){pendingFocus=nil}
    }
    func performKeyEquivalent(_ event:NSEvent)->Bool {
        guard active else{return false}
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        guard flags == [.command,.option] || flags == .option,
              let key=event.charactersIgnoringModifiers?.lowercased(),let entry=entries.first(where:{flags == .option ? $0.sourceKey==key:$0.key==key}) else{return false}
        if flags == .option,(window?.firstResponder as? NSTextView)?.isEditable == true {return false}
        if entry.enabled {perform(entry)};return true
    }
    func menuNeedsUpdate(_ menu:NSMenu){if !tracking{install()}}
    func menuWillOpen(_ menu:NSMenu){tracking=true;for item in menu.items {let receipt=item.representedObject as? Invocation;item.isEnabled=active && receipt?.epoch==epoch && entries.contains(where:{$0.id==receipt?.id && $0.enabled})}}
    func menuDidClose(_ menu:NSMenu){tracking=false;DispatchQueue.main.async{[weak self] in self?.install()}}
}
struct ReferenceFormCommands:NSViewRepresentable {
    let entries:[ReferenceFormCommand]
    let preferences:UserDefaults
    let available:()->Bool
    let changes:AnyPublisher<Void,Never>
    func makeNSView(context:Context)->Probe {Probe()}
    func updateNSView(_ view:Probe,context:Context){view.router.update(entries,preferences:preferences,available:available,changes:changes);view.connect()}
    static func dismantleNSView(_ view:Probe,coordinator:()){view.router.retire()}
    final class Probe:NSView {
        let router=ReferenceFormCommandRouter()
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();connect()}
        func connect(){if let window=window as? ReferenceFormNativeWindow {router.attach(window)}}
        override func hitTest(_ point:NSPoint)->NSView? {nil}
    }
}
/// Reference names are unbounded user data. Their intrinsic text width must
/// never become a form's minimum width; the surrounding row owns that width.
func referenceFormControlSize(_ proposal:ProposedViewSize,height:CGFloat)->CGSize {
    let width=proposal.width.flatMap {$0.isFinite ? max(0,$0):nil} ?? 320
    return CGSize(width:width,height:height)
}
/// Read-only source reference captions remain copyable without making their
/// unbounded names expand or wrap the dialog's command groups.
struct ReferenceFormCaption:NSViewRepresentable {
    let value:String,label:String
    var emphasized=true
    func makeNSView(context:Context)->NSTextField {
        let field=NSTextField(labelWithString:value);field.isSelectable=true;field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        field.setAccessibilityLabel(NSLocalizedString(label,comment:""));field.identifier = .init(label);return field
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSTextField,context:Context)->CGSize? {referenceFormControlSize(proposal,height:22)}
    func updateNSView(_ field:NSTextField,context:Context){if !field.stringValue.utf8.elementsEqual(value.utf8){field.stringValue=value};field.toolTip=value;field.textColor=emphasized ? .linkColor:.labelColor;field.isSelectable=true}
}
