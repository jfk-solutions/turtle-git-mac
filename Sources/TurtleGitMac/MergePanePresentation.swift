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

struct MergePaneHeader:NSViewRepresentable {
    enum Kind:Equatable {case removed,added,neutral}
    var title:String,location:String
    var modified:Bool,active:Bool
    var kind:Kind
    var font:NSFont
    var enabled:Bool
    var preferences:UserDefaults
    var activate:()->Void
    func makeNSView(context:Context)->MergePaneHeaderView{MergePaneHeaderView()}
    func updateNSView(_ view:MergePaneHeaderView,context:Context){
        view.configure(title:title,location:location,modified:modified,active:active,kind:kind,font:font,enabled:enabled,preferences:preferences,activate:activate)
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:MergePaneHeaderView,context:Context)->CGSize? {
        .init(width:max(0,proposal.width ?? 320),height:max(27,ceil(font.ascender-font.descender+font.leading)+12))
    }
    static func dismantleNSView(_ view:MergePaneHeaderView,coordinator:()){view.retire()}
}

@MainActor final class MergePaneHeaderView:NSView {
    let titleField=NSTextField(labelWithString:"")
    private weak var originalWindow:NSWindow?
    private var closeObserver:NSObjectProtocol?
    private var bound=false,retired=false,enabled=false,active=false
    private var activate:()->Void={}
    private var fill=NSColor.controlBackgroundColor
    override init(frame:NSRect){
        super.init(frame:frame);identifier = .init("Merge.Pane.Header");titleField.isSelectable=false;titleField.maximumNumberOfLines=1;titleField.usesSingleLineMode=true
        titleField.lineBreakMode = .byTruncatingMiddle;titleField.cell?.wraps=false;titleField.cell?.isScrollable=true
        titleField.alignment = .center;titleField.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints=false;addSubview(titleField)
        NSLayoutConstraint.activate([titleField.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),titleField.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),titleField.centerYAnchor.constraint(equalTo:centerYAnchor)])
        setAccessibilityRole(.button)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    deinit {if let closeObserver {NotificationCenter.default.removeObserver(closeObserver)}}
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow()
        if let window{if !bound{
            bound=true;originalWindow=window
            closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.retire()}}
        }else if window !== originalWindow{retire()}}
    }
    func configure(title:String,location:String,modified:Bool,active:Bool,kind:MergePaneHeader.Kind,font:NSFont,enabled:Bool,preferences:UserDefaults,activate:@escaping()->Void){
        guard !retired else{return};self.active=active;self.enabled=enabled;self.activate=activate
        titleField.stringValue=(modified ? "* ":"")+MergePanePresentation.display(title)
        titleField.font=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask)
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
        setAccessibilityValue(modified ? NSLocalizedString("Modified",comment:""):"");needsDisplay=true
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
        (active ? NSColor.controlAccentColor:NSColor.separatorColor).setStroke()
        let border=NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5));border.lineWidth=active ? 2:1;border.stroke()
    }
    func retire(){retired=true;enabled=false;activate={};originalWindow=nil;if let closeObserver {NotificationCenter.default.removeObserver(closeObserver)};closeObserver=nil}
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
