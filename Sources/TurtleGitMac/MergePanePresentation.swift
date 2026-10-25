// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// BaseView::DrawHeader and MainFrm's focused-column/marked-word indicators.
/// Raw titles and paths remain in tooltips; separators are visible only in the
/// bounded single-line caption, never rewritten in the document or its paths.
@MainActor enum MergePanePresentation {
    static func display(_ raw:String)->String {
        var text=raw.replacingOccurrences(of:"\r\n",with:"↵")
        for separator in ["\r","\n","\u{0085}","\u{2028}","\u{2029}","\u{000B}","\u{000C}"]{text=text.replacingOccurrences(of:separator,with:"↵")}
        return text.replacingOccurrences(of:"\t",with:"⇥")
    }
    /// Source caret view coordinates count UTF-16 characters in the logical
    /// line. Wrapping and expanded tab widths do not change this column.
    static func column(in view:NSTextView?)->Int {
        guard let view else{return 1}
        let text=view.string as NSString,selection=view.selectedRange()
        guard selection.location<=text.length,selection.length<=text.length-selection.location else{return 1}
        let caret=view.selectionAffinity == .upstream ? NSMaxRange(selection):selection.location
        let offset=min(max(0,caret),text.length)
        let start=text.lineRange(for:NSRange(location:offset,length:0)).location
        return offset-start+1
    }
    static func marked(label:String,in view:NSTextView?)->MergePaneMarkCount {
        .init(label:label,count:(view as? MergeFindProviding)?.mergeFindHighlights.markedRanges.count ?? 0)
    }
}

struct MergePaneMarkCount:Equatable {let label:String;let count:Int}

/// Captured pane commands keep the model's identity/permission checks at dispatch,
/// including actions retained by an open context menu or accessibility client.
@MainActor final class MergePaneHeaderCommand {
    let title:String,icon:MenuIcon
    private let isAvailable:()->Bool,perform:()->Void
    private var consumed=false
    init(title:String,icon:MenuIcon,available:@escaping()->Bool,perform:@escaping()->Void) {
        self.title=title;self.icon=icon;isAvailable=available;self.perform=perform
    }
    func available()->Bool {!consumed && isAvailable()}
    func fresh()->MergePaneHeaderCommand {.init(title:title,icon:icon,available:isAvailable,perform:perform)}
    @discardableResult func invoke()->Bool {guard available() else{return false};consumed=true;perform();return true}
}

struct MergePaneHeaderIdentity:Hashable {
    let owner:ObjectIdentifier,epoch:UUID,generation:Int,role:String
    let location:Data
    var layout:Int=0
    var presentation:Int=0
    var pane:ObjectIdentifier?=nil
}
@MainActor struct MergePaneHeaderActions {
    let identity:MergePaneHeaderIdentity
    let commands:[MergePaneHeaderCommand]
}


struct MergePaneHeader:NSViewRepresentable {
    enum Kind:Equatable {case removed,added,neutral}
    var title:String,location:String
    var modified:Bool,active:Bool
    var kind:Kind
    var font:NSFont
    var enabled:Bool
    var preferences:UserDefaults
    var activate:()->Void
    var actions:MergePaneHeaderActions? = nil
    var compact=false
    func makeNSView(context:Context)->MergePaneHeaderView{MergePaneHeaderView()}
    func updateNSView(_ view:MergePaneHeaderView,context:Context){
        view.configure(title:title,location:location,modified:modified,active:active,kind:kind,font:font,enabled:enabled,preferences:preferences,activate:activate,actions:actions,compact:compact)
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:MergePaneHeaderView,context:Context)->CGSize? {
        .init(width:max(0,proposal.width ?? 320),height:max(compact ? 20:27,ceil(font.ascender-font.descender+font.leading)+(compact ? 4:12)))
    }
    static func dismantleNSView(_ view:MergePaneHeaderView,coordinator:()){view.retire()}
}

@MainActor final class MergePaneHeaderView:NSView {
    let titleField=NSTextField(labelWithString:"")
    private weak var originalWindow:NSWindow?
    private var closeObserver:NSObjectProtocol?
    private var bound=false,retired=false,enabled=false,active=false
    private var activate:()->Void={}
    private var actions:MergePaneHeaderActions?
    private var actionRevision=0
    private var compact=false
    private var leadingInset:NSLayoutConstraint?
    private var trailingInset:NSLayoutConstraint?
    override var acceptsFirstResponder:Bool {true}
    @MainActor private final class CommandTarget:NSObject {
        weak var view:MergePaneHeaderView?
        let revision:Int,command:MergePaneHeaderCommand
        private var consumed=false
        init(view:MergePaneHeaderView,revision:Int,command:MergePaneHeaderCommand){self.view=view;self.revision=revision;self.command=command}
        @objc func invoke(_ sender:Any?){_ = perform()}
        func perform()->Bool {
            guard !consumed,let view,view.actionRevision==revision,view.canPerformHeaderAction,command.available() else{return false}
            consumed=true
            return command.invoke()
        }
    }
    private var canPerformHeaderAction:Bool {
        !retired && enabled && window != nil && window === originalWindow && window?.attachedSheet==nil && NSApp.modalWindow==nil
    }
    /// A fresh menu owns its exact action receipts; later role/configuration
    /// changes invalidate retained rows without retargeting them.
    func contextMenu()->NSMenu {
        let menu=NSMenu();menu.autoenablesItems=false
        guard canPerformHeaderAction else{return menu}
        for original in actions?.commands ?? [] {
            let command=original.fresh()
            let target=CommandTarget(view:self,revision:actionRevision,command:command)
            let item=NSMenuItem(title:NSLocalizedString(command.title,comment:""),action:#selector(CommandTarget.invoke(_:)),keyEquivalent:"")
            item.target=target;item.representedObject=target;item.isEnabled=command.available()
            item.image=MenuPresentationSettings.applicationContextIcons(defaults:actionPreferences) ? command.icon.image():nil
            menu.addItem(item)
        }
        MenuImageVisibility.apply(to:menu);return menu
    }
    private var actionPreferences:UserDefaults = .standard
    override func menu(for event:NSEvent)->NSMenu? {contextMenu()}
    override func keyDown(with event:NSEvent) {
        if event.keyCode==109,event.modifierFlags.intersection([.shift,.control,.option,.command]) == .shift {
            _ = accessibilityPerformShowMenu();return
        }
        super.keyDown(with:event)
    }
    override func accessibilityPerformShowMenu()->Bool {
        let menu=contextMenu();guard !menu.items.isEmpty else{return false}
        menu.popUp(positioning:nil,at:NSPoint(x:bounds.midX,y:bounds.maxY),in:self);return true
    }
    override func accessibilityCustomActions()->[NSAccessibilityCustomAction]? {
        guard canPerformHeaderAction else{return nil}
        return (actions?.commands ?? []).filter{$0.available()}.map {original in
            let command=original.fresh()
            let target=CommandTarget(view:self,revision:actionRevision,command:command)
            return NSAccessibilityCustomAction(name:NSLocalizedString(command.title,comment:""),handler:{target.perform()})
        }
    }
    private var fill=NSColor.controlBackgroundColor
    override init(frame:NSRect){
        super.init(frame:frame);identifier = .init("Merge.Pane.Header");titleField.isSelectable=false;titleField.maximumNumberOfLines=1;titleField.usesSingleLineMode=true
        titleField.lineBreakMode = .byTruncatingMiddle;titleField.cell?.wraps=false;titleField.cell?.isScrollable=true
        titleField.alignment = .center;titleField.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints=false;addSubview(titleField)
        let leading=titleField.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),trailing=titleField.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8)
        leadingInset=leading;trailingInset=trailing
        NSLayoutConstraint.activate([leading,trailing,titleField.centerYAnchor.constraint(equalTo:centerYAnchor)])
        // NSView is otherwise ignored and AppKit exposes only the visual
        // NSTextField as static text, hiding the owning menu/action receipts.
        setAccessibilityElement(true);setAccessibilityRole(.button)
        titleField.setAccessibilityElement(false);setAccessibilityChildren([])
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    deinit {if let closeObserver {NotificationCenter.default.removeObserver(closeObserver)}}
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow()
        if window == nil {actionRevision &+= 1}
        if let window{if !bound{
            bound=true;originalWindow=window
            closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.retire()}}
        }else if window !== originalWindow{retire()}}
    }
    func configure(title:String,location:String,modified:Bool,active:Bool,kind:MergePaneHeader.Kind,font:NSFont,enabled:Bool,preferences:UserDefaults,activate:@escaping()->Void,actions:MergePaneHeaderActions?=nil,compact:Bool=false){
        guard !retired else{return};self.active=active;self.enabled=enabled;self.activate=activate
        if self.actions?.identity != actions?.identity {actionRevision &+= 1}
        self.actions=actions;actionPreferences=preferences;self.compact=compact
        leadingInset?.constant=compact ? 0:8;trailingInset?.constant=compact ? 0:-8
        titleField.alignment=compact ? .left:.center
        titleField.stringValue=(modified ? "* ":"")+MergePanePresentation.display(title)
        titleField.font=compact ? font:NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask)
        let state=kind == .neutral ? MergeSourceState.normal:kind == .removed ? .removed:.added
        let palette=MergeColorPreferences.load(from:preferences),applied=preferences.data(forKey:"TurtleGitMerge.Colors") != nil
        func color(foreground:Bool)->NSColor {NSColor(name:nil){appearance in
            let pair=palette.stateColors(state,dark:appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,applied:applied)
            let rgb=foreground ? pair.foreground:pair.background
            return NSColor(srgbRed:CGFloat((rgb >> 16)&255)/255,green:CGFloat((rgb >> 8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
        }}
        fill=kind == .neutral ? .controlBackgroundColor:color(foreground:false)
        titleField.textColor=color(foreground:true)
        let raw=[title,location].filter{!$0.isEmpty}.joined(separator:"\n")
        toolTip=raw;titleField.toolTip=raw;titleField.setAccessibilityLabel(title);setAccessibilityLabel(title)
        setAccessibilityValue(modified ? NSLocalizedString("Modified",comment:""):"")
        setAccessibilityHelp(location);setAccessibilityEnabled(enabled);needsDisplay=true
    }
    private func performActivation()->Bool {
        guard !retired,enabled,let window,window === originalWindow,window.attachedSheet==nil,NSApp.modalWindow==nil else{return false}
        activate();return true
    }
    override func accessibilityPerformPress()->Bool{performActivation()}
    override func hitTest(_ point:NSPoint)->NSView? {super.hitTest(point) == nil ? nil:self}
    override func mouseDown(with event:NSEvent){_ = performActivation()}
    override func draw(_ dirtyRect:NSRect){
        fill.setFill();bounds.fill()
        guard !compact else{return}
        (active ? NSColor.controlAccentColor:NSColor.separatorColor).setStroke()
        let border=NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5));border.lineWidth=active ? 2:1;border.stroke()
    }
    func retire(){retired=true;enabled=false;setAccessibilityEnabled(false);activate={};actions=nil;actionRevision &+= 1;originalWindow=nil;if let closeObserver {NotificationCenter.default.removeObserver(closeObserver)};closeObserver=nil}
}

/// Native fields keep the status observable without depending on SwiftUI's
/// virtual accessibility hierarchy in offscreen receiver checks.
struct MergePaneStatus:NSViewRepresentable {
    var column:Int
    var marked:[MergePaneMarkCount]
    func makeNSView(context:Context)->NSStackView{
        let stack=NSStackView();stack.orientation = .horizontal;stack.spacing=12
        stack.setContentHuggingPriority(.required,for:.vertical)
        for id in ["Merge.Status.Column","Merge.Status.MarkedWords"]{
            let field=NSTextField(labelWithString:"");field.identifier = .init(id);field.font = .systemFont(ofSize:NSFont.smallSystemFontSize)
            field.maximumNumberOfLines=1;field.usesSingleLineMode=true;field.lineBreakMode = .byTruncatingTail;field.isSelectable=true
            field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);stack.addArrangedSubview(field)
        };return stack
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSStackView,context:Context)->CGSize? {
        let width=proposal.width.flatMap{$0.isFinite ? $0:nil} ?? nsView.fittingSize.width
        let height=max(18,nsView.arrangedSubviews.map{$0.fittingSize.height}.max() ?? 18)
        return .init(width:max(0,width),height:height)
    }
    func updateNSView(_ view:NSStackView,context:Context){
        guard let columnField=view.arrangedSubviews.first as? NSTextField,let counts=view.arrangedSubviews.last as? NSTextField else{return}
        columnField.stringValue=String(format:NSLocalizedString("Column: %d",comment:""),max(1,column))
        let text=marked.filter{$0.count>0}.map{"\($0.label): \($0.count)"}.joined(separator:" | ")
        counts.stringValue=text.isEmpty ? "":NSLocalizedString("Marked words:",comment:"")+" "+text
        counts.isHidden=text.isEmpty;counts.toolTip=counts.stringValue
    }
}
