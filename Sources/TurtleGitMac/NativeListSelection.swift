// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

/// Presentation only: the table remains the sole owner of selected indexes,
/// keyboard navigation, accessibility, context clicks and embedded controls.
@MainActor enum NativeListSelection {
    private static var key:UInt8=0
    private static var rowKey:UInt8=0
    private static var rowClasses:[ObjectIdentifier:AnyClass]=[:]
    @MainActor private final class RowBinding {
        weak var owner:Owner?
        let originalClass:AnyClass
        let decoratedClass:AnyClass
        init(owner:Owner,originalClass:AnyClass,decoratedClass:AnyClass){self.owner=owner;self.originalClass=originalClass;self.decoratedClass=decoratedClass}
    }
    private static func decorate(_ row:NSTableRowView,owner:Owner) {
        if let binding=objc_getAssociatedObject(row,&rowKey) as? RowBinding {binding.owner=owner;return}
        guard let base=object_getClass(row) else{return}
        let cls:AnyClass
        if let existing=rowClasses[ObjectIdentifier(base)] {cls=existing}
        else {
            guard let created=objc_allocateClassPair(base,"TurtleGitLabelSelectionRow_\(rowClasses.count)",0),
                  let draw=class_getInstanceMethod(base,#selector(NSTableRowView.drawSelection(in:))),
                  let style=class_getInstanceMethod(base,#selector(getter:NSTableRowView.interiorBackgroundStyle)) else{return}
            let originalDraw=method_getImplementation(draw),originalStyle=method_getImplementation(style)
            let drawBlock:@convention(block)(NSTableRowView,NSRect)->Void={view,rect in
                MainActor.assumeIsolated {
                    if (objc_getAssociatedObject(view,&rowKey) as? RowBinding)?.owner?.fullRow != false {
                        typealias Draw=@convention(c)(AnyObject,Selector,NSRect)->Void
                        unsafeBitCast(originalDraw,to:Draw.self)(view,#selector(NSTableRowView.drawSelection(in:)),rect)
                    }
                }
            }
            let styleBlock:@convention(block)(NSTableRowView)->Int={view in
                MainActor.assumeIsolated {
                    if (objc_getAssociatedObject(view,&rowKey) as? RowBinding)?.owner?.fullRow == false {return NSView.BackgroundStyle.normal.rawValue}
                    typealias Style=@convention(c)(AnyObject,Selector)->Int
                    return unsafeBitCast(originalStyle,to:Style.self)(view,#selector(getter:NSTableRowView.interiorBackgroundStyle))
                }
            }
            class_addMethod(created,#selector(NSTableRowView.drawSelection(in:)),imp_implementationWithBlock(drawBlock),method_getTypeEncoding(draw))
            class_addMethod(created,#selector(getter:NSTableRowView.interiorBackgroundStyle),imp_implementationWithBlock(styleBlock),method_getTypeEncoding(style))
            objc_registerClassPair(created);rowClasses[ObjectIdentifier(base)]=created;cls=created
        }
        objc_setAssociatedObject(row,&rowKey,RowBinding(owner:owner,originalClass:base,decoratedClass:cls),.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        object_setClass(row,cls)
    }
    private static func undecorate(_ row:NSTableRowView,owner:Owner) {
        guard let binding=objc_getAssociatedObject(row,&rowKey) as? RowBinding,binding.owner === owner else{return}
        if object_getClass(row).map(ObjectIdentifier.init) == ObjectIdentifier(binding.decoratedClass) {object_setClass(row,binding.originalClass)}
        objc_setAssociatedObject(row,&rowKey,nil,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func install(on table:NSTableView,preferences:UserDefaults,primaryColumn:NSTableColumn?,labelText:((Int)->String?)?=nil,font:NSFont?=nil,leadingInset:CGFloat=0) {
        let owner=(objc_getAssociatedObject(table,&key) as? Owner) ?? Owner(table:table)
        objc_setAssociatedObject(table,&key,owner,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        owner.preferences=preferences;owner.primaryColumn=primaryColumn;owner.labelText=labelText;owner.font=font;owner.leadingInset=leadingInset
        owner.bind();owner.invalidate()
    }
    static func remove(from table:NSTableView) {
        guard let owner=objc_getAssociatedObject(table,&key) as? Owner else{return}
        owner.retire();objc_setAssociatedObject(table,&key,nil,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    fileprivate static func owner(_ table:NSTableView)->Owner? {objc_getAssociatedObject(table,&key) as? Owner}
    /// Actual measured label bounds, in table coordinates; useful to consumers
    /// drawing additional adornments without assuming column width == text.
    static func labelRect(in table:NSTableView,row:Int)->NSRect? {owner(table)?.label(row:row)?.rect}
    static func labelTextRect(in table:NSTableView,row:Int)->NSRect? {owner(table)?.label(row:row)?.frame}
    static func usesFullRowSelection(in table:NSTableView)->Bool? {guard let owner=owner(table),!owner.retired else{return nil};return owner.fullRow}
    static func originalDelegate(of table:NSTableView)->NSTableViewDelegate? {owner(table)?.original ?? table.delegate}

    fileprivate struct Label {
        let rect:NSRect,frame:NSRect,cell:NSTextFieldCell
    }
    @MainActor fileprivate final class Owner:NSObject,NSTableViewDelegate {
        weak var table:NSTableView?
        weak var original:NSTableViewDelegate?
        weak var primaryColumn:NSTableColumn?
        var preferences:UserDefaults = .standard
        var labelText:((Int)->String?)?,font:NSFont?,leadingInset:CGFloat=0
        private var observations:[NSObjectProtocol]=[]
        private let overlay=NativeListSelectionTableOverlay()
        private let originalHighlightStyle:NSTableView.SelectionHighlightStyle
        @MainActor private final class WeakRow {
            weak var value:NSTableRowView?
            let originalStyle:NSTableView.SelectionHighlightStyle
            init(_ value:NSTableRowView,style:NSTableView.SelectionHighlightStyle){self.value=value;originalStyle=style}
        }
        private var rows:[WeakRow]=[]
        private(set) var retired=false
        var fullRow:Bool {AdvancedListBehavior(defaults:preferences).fullRowSelect}
        init(table:NSTableView) {
            self.table=table;originalHighlightStyle=table.selectionHighlightStyle;super.init()
            for name in [NSTableView.selectionDidChangeNotification,NSTableView.columnDidResizeNotification,NSTableView.columnDidMoveNotification,UserDefaults.didChangeNotification,NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
                let center=name == NSWorkspace.accessibilityDisplayOptionsDidChangeNotification ? NSWorkspace.shared.notificationCenter:NotificationCenter.default
                observations.append(center.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.invalidate()}})
            }
            observations.append(NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:nil,queue:.main){[weak self] note in
                MainActor.assumeIsolated {guard let self,let window=note.object as? NSWindow,window === self.table?.window else{return};self.retire()}
            })
        }
        func bind() {
            guard !retired,let table else{return}
            if table.delegate !== self {original=table.delegate;table.delegate=self}
            // Existing visible native rows predate the proxy on SwiftUI tables.
            table.enumerateAvailableRowViews {row,index in self.configure(row,index:index)}
            overlay.owner=self;overlay.frame=table.bounds;overlay.autoresizingMask=[.width,.height];overlay.setAccessibilityElement(false)
            // SwiftUI tables compose their cells into layers; a drawing-only
            // subview must participate above those layers too.
            overlay.wantsLayer=true;overlay.layer?.zPosition=1000
            table.addSubview(overlay,positioned:.above,relativeTo:nil)
        }
        override func responds(to selector:Selector!)->Bool {super.responds(to:selector) || original?.responds(to:selector)==true}
        override func forwardingTarget(for selector:Selector!)->Any? {original?.responds(to:selector)==true ? original:super.forwardingTarget(for:selector)}
        func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {
            let supplied=original?.tableView?(tableView,rowViewForRow:row)
            let view=supplied ?? NativeListSelectionRowView()
            configure(view,index:row);return view
        }
        func tableView(_ tableView:NSTableView,willDisplayCell cell:Any,for tableColumn:NSTableColumn?,row:Int) {
            original?.tableView?(tableView,willDisplayCell:cell,for:tableColumn,row:row)
            if !fullRow,let cell=cell as? NSCell {cell.isHighlighted=false;cell.backgroundStyle = .normal}
        }
        func tableView(_ tableView:NSTableView,didAdd rowView:NSTableRowView,forRow row:Int) {
            original?.tableView?(tableView,didAdd:rowView,forRow:row)
            configure(rowView,index:row)
        }
        private func configure(_ row:NSTableRowView,index:Int) {
            if !rows.contains(where:{$0.value === row}) {
                rows.removeAll{$0.value==nil}
                let style = !fullRow && row.selectionHighlightStyle == .none ? originalHighlightStyle:row.selectionHighlightStyle
                rows.append(WeakRow(row,style:style))
            }
            if let saved=rows.first(where:{$0.value === row}) {row.selectionHighlightStyle=fullRow ? saved.originalStyle:.none}
            if let row=row as? NativeListSelectionRowView {row.selectionOwner=self;row.needsDisplay=true}
            else {NativeListSelection.decorate(row,owner:self);row.needsDisplay=true}
            if let table {
                for column in table.tableColumns.indices {
                    (table.view(atColumn:column,row:index,makeIfNecessary:false) as? NSTableCellView)?.backgroundStyle=row.interiorBackgroundStyle
                }
                table.addSubview(overlay,positioned:.above,relativeTo:nil)
            }
        }
        func invalidate() {
            guard !retired,let table else{return}
            // Private SwiftUI rows may paint selection without calling the
            // public drawSelection hook. Disable the native full-row style,
            // retaining the table's semantic selected indexes and controls.
            table.selectionHighlightStyle=fullRow ? originalHighlightStyle:.none
            table.enumerateAvailableRowViews{row,index in self.configure(row,index:index)}
            table.needsDisplay=true
            overlay.frame=table.bounds;overlay.isHidden=fullRow;overlay.needsDisplay=true
        }
        func retire() {
            guard !retired else{return};retired=true
            if let table {
                table.selectionHighlightStyle=originalHighlightStyle
                if table.delegate === self {table.delegate=original}
                for saved in rows {
                    guard let row=saved.value else{continue}
                    row.selectionHighlightStyle=saved.originalStyle
                    NativeListSelection.undecorate(row,owner:self)
                    if let row=row as? NativeListSelectionRowView {row.selectionOwner=nil;row.needsDisplay=true}
                }
                table.needsDisplay=true
            }
            observations.forEach {NotificationCenter.default.removeObserver($0);NSWorkspace.shared.notificationCenter.removeObserver($0)};observations=[]
            overlay.removeFromSuperview();overlay.owner=nil
            rows=[]
        }
        deinit {observations.forEach{NotificationCenter.default.removeObserver($0);NSWorkspace.shared.notificationCenter.removeObserver($0)}}
        var emphasized:Bool {
            guard let table,table.window?.isKeyWindow==true,let responder=table.window?.firstResponder else{return false}
            if responder === table{return true}
            return (responder as? NSView)?.isDescendant(of:table)==true
        }
        var background:NSColor {emphasized ? .selectedContentBackgroundColor:.unemphasizedSelectedContentBackgroundColor}
        var foreground:NSColor {emphasized ? .alternateSelectedControlTextColor:.unemphasizedSelectedTextColor}
        func label(row:Int)->Label? {
            guard !retired,let table,let column=primaryColumn,let index=table.tableColumns.firstIndex(where:{$0 === column}),row>=0,row<table.numberOfRows,!column.isHidden else{return nil}
            let bounds=table.frameOfCell(atColumn:index,row:row)
            guard bounds.width>0,bounds.height>0 else{return nil}
            func textField(_ view:NSView)->NSTextField? {
                if let field=view as? NSTextField{return field}
                if let cell=view as? NSTableCellView,let field=cell.textField{return field}
                return view.subviews.compactMap(textField).first
            }
            let field=table.view(atColumn:index,row:row,makeIfNecessary:false).flatMap(textField)
            if let field {
                // Let the native field editor render its own selection/caret.
                guard field.currentEditor()==nil else{return nil}
                guard let cell=field.cell?.copy() as? NSTextFieldCell else{return nil}
                let frame=field.convert(field.bounds,to:table)
                let drawing=field.convert(field.cell?.drawingRect(forBounds:field.bounds) ?? field.bounds,to:table)
                let measured=cell.cellSize(forBounds:NSRect(x:0,y:0,width:CGFloat.greatestFiniteMagnitude,height:drawing.height)).width
                let width=min(drawing.width,max(0,measured))
                let x:CGFloat
                switch cell.alignment {case .right:x=drawing.maxX-width;case .center:x=drawing.midX-width/2;default:x=drawing.minX}
                let rect=NSRect(x:x-2,y:bounds.minY,width:width+4,height:bounds.height).intersection(bounds)
                return Label(rect:rect,frame:frame,cell:cell)
            }
            let text=labelText?(row) ?? (table.dataSource?.tableView?(table,objectValueFor:column,row:row) as? String)
            guard let text else{return nil}
            let cell=NSTextFieldCell(textCell:text);cell.font=font ?? table.font ?? .systemFont(ofSize:NSFont.systemFontSize);cell.lineBreakMode = .byTruncatingTail
            let width=min(max(0,bounds.width-leadingInset),(text as NSString).size(withAttributes:[.font:cell.font!]).width+4)
            let availableWidth=max(0,bounds.width-leadingInset-2)
            let textHeight=min(bounds.height,cell.cellSize(forBounds:NSRect(x:0,y:0,width:availableWidth,height:bounds.height)).height)
            let frame=NSRect(x:bounds.minX+leadingInset,y:bounds.midY-textHeight/2,width:availableWidth,height:textHeight)
            return Label(rect:NSRect(x:frame.minX,y:bounds.minY,width:width,height:bounds.height),frame:frame,cell:cell)
        }
        func draw(row:Int,in view:NSView,clip:NSRect) {
            guard !fullRow,let table,table.isRowSelected(row),let label=label(row:row) else{return}
            let rect=view.convert(label.rect,from:table),frame=view.convert(label.frame,from:table)
            guard rect.intersects(clip) else{return}
            NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
            NSBezierPath(rect:rect.intersection(clip)).addClip();background.setFill();rect.fill()
            label.cell.backgroundStyle = .normal;label.cell.textColor=foreground
            let text=NSMutableAttributedString(attributedString:label.cell.attributedStringValue)
            text.addAttribute(.foregroundColor,value:foreground,range:NSRange(location:0,length:text.length));label.cell.attributedStringValue=text
            label.cell.drawInterior(withFrame:frame,in:view)
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {foreground.setStroke();let edge=NSBezierPath(rect:rect.insetBy(dx:0.5,dy:0.5));edge.lineWidth=1;edge.stroke()}
        }
    }
}

/// Custom row factories can subclass this without giving up background colors
/// or drawing. Ordinary full-row mode follows AppKit unchanged.
@MainActor class NativeListSelectionRowView:NSTableRowView {
    fileprivate weak var selectionOwner:NativeListSelection.Owner?
    override var interiorBackgroundStyle:NSView.BackgroundStyle {selectionOwner?.fullRow == false ? .normal:super.interiorBackgroundStyle}
    override func drawSelection(in dirtyRect:NSRect) {if selectionOwner?.fullRow != false {super.drawSelection(in:dirtyRect)}}
}

/// Cell-based source lists use the same label geometry without changing their
/// objectValue/delegate, native selection semantics or embedded cell actions.
@MainActor class NativeListSelectionTableView:NSTableView {
    override func highlightSelection(inClipRect clipRect:NSRect) {
        guard let owner=NativeListSelection.owner(self),!owner.fullRow else{super.highlightSelection(inClipRect:clipRect);return}
        // Drawing is completed after native cells below, so their selected text
        // cannot turn unrelated columns white outside the primary label.
    }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        guard let owner=NativeListSelection.owner(self),!owner.fullRow else{return}
        for row in selectedRowIndexes {owner.draw(row:row,in:self,clip:dirtyRect)}
    }
}

@MainActor private final class NativeListSelectionTableOverlay:NSView {
    weak var owner:NativeListSelection.Owner?
    override var isFlipped:Bool {true}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func isAccessibilityElement()->Bool {false}
    override func draw(_ dirtyRect:NSRect) {
        guard let owner,let table=owner.table else{return}
        for row in table.selectedRowIndexes {owner.draw(row:row,in:self,clip:dirtyRect)}
    }
}

import SwiftUI
/// Attach as the background of precisely one SwiftUI Table, not its enclosing
/// window. The column object is retained across native column reordering.
@MainActor struct NativeListSelectionProbe:NSViewRepresentable {
    var preferences:UserDefaults = .standard
    var primaryTitle:String?=nil
    var primaryColumnIndex:Int=0
    var labelText:((Int)->String?)?=nil
    var font:NSFont?=nil
    var leadingInset:CGFloat=0
    func makeNSView(context:Context)->Probe {Probe()}
    func updateNSView(_ view:Probe,context:Context) {view.settings=self;view.schedule()}
    static func dismantleNSView(_ view:Probe,coordinator:()) {view.retire()}
    final class Probe:NSView {
        var settings:NativeListSelectionProbe?
        private weak var table:NSTableView?
        private weak var column:NSTableColumn?
        private var retired=false,pending=false
        private var lastBounds=NSRect.zero
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if window==nil {detach()} else{schedule()}}
        override func layout(){super.layout();if bounds != lastBounds {lastBounds=bounds;schedule()}}
        func schedule() {
            guard !retired,!pending else{return};pending=true
            DispatchQueue.main.async{[weak self] in guard let self else{return};self.pending=false;self.configure()}
        }
        private func configure() {
            guard !retired,let settings,let root=window?.contentView,bounds.width>0,bounds.height>0 else{return}
            let area=convert(bounds,to:root)
            func find(_ view:NSView)->[NSTableView] {
                if let table=view as? NSTableView {
                    let rect=table.convert(table.visibleRect,to:root),overlap=area.intersection(rect)
                    return !overlap.isNull && overlap.width>0 && overlap.height>0 && overlap.width*overlap.height >= rect.width*rect.height*0.8 ? [table]:[]
                }
                return view.subviews.flatMap(find)
            }
            let candidates=find(root)
            guard candidates.count==1,let next=candidates.first else{return}
            if table !== next {detach();table=next;column=nil}
            if column==nil {
                column=settings.primaryTitle.flatMap{title in next.tableColumns.first{$0.title==title || $0.title==NSLocalizedString(title,comment:"")}}
                if column==nil,next.tableColumns.indices.contains(settings.primaryColumnIndex) {column=next.tableColumns[settings.primaryColumnIndex]}
            }
            NativeListSelection.install(on:next,preferences:settings.preferences,primaryColumn:column,labelText:settings.labelText,font:settings.font,leadingInset:settings.leadingInset)
        }
        private func detach(){if let table {NativeListSelection.remove(from:table)};table=nil;column=nil}
        func retire(){guard !retired else{return};retired=true;detach();settings=nil}
    }
}
