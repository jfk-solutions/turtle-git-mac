// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

/// Presentation only: the table remains the sole owner of selected indexes,
/// keyboard navigation, accessibility, context clicks and embedded controls.
@MainActor enum NativeListSelection {
    private static var key:UInt8=0
    private static var rowKey:UInt8=0
    private static var decoratedRowClasses=Set<ObjectIdentifier>()
    @MainActor private final class RowBinding {
        weak var owner:Owner?
        init(owner:Owner){self.owner=owner}
    }
    private static func usesLabelSelection(_ row:NSTableRowView)->Bool {
        guard let owner=(objc_getAssociatedObject(row,&rowKey) as? RowBinding)?.owner,
              let table=owner.table,owner.isCurrent(table),!owner.fullRow else{return false}
        var ancestor=row.superview
        while let view=ancestor {
            if let actual=view as? NSTableView{return actual === table}
            ancestor=view.superview
        }
        return false
    }
    private static func decorate(_ row:NSTableRowView,owner:Owner) {
        if let binding=objc_getAssociatedObject(row,&rowKey) as? RowBinding {binding.owner=owner;return}
        guard let base=object_getClass(row) else{return}
        if !decoratedRowClasses.contains(ObjectIdentifier(base)) {
            guard let draw=class_getInstanceMethod(base,#selector(NSTableRowView.drawSelection(in:))),
                  let style=class_getInstanceMethod(base,#selector(getter:NSTableRowView.interiorBackgroundStyle)) else{return}
            let originalDraw=method_getImplementation(draw),originalStyle=method_getImplementation(style)
            let drawBlock:@convention(block)(NSTableRowView,NSRect)->Void={view,rect in
                MainActor.assumeIsolated {
                    if !usesLabelSelection(view) {
                        typealias Draw=@convention(c)(AnyObject,Selector,NSRect)->Void
                        unsafeBitCast(originalDraw,to:Draw.self)(view,#selector(NSTableRowView.drawSelection(in:)),rect)
                    }
                }
            }
            let styleBlock:@convention(block)(NSTableRowView)->Int={view in
                MainActor.assumeIsolated {
                    if usesLabelSelection(view) {return NSView.BackgroundStyle.normal.rawValue}
                    typealias Style=@convention(c)(AnyObject,Selector)->Int
                    return unsafeBitCast(originalStyle,to:Style.self)(view,#selector(getter:NSTableRowView.interiorBackgroundStyle))
                }
            }
            // Keep AppKit/SwiftUI's actual row class and its native computed
            // property metadata. Changing isa breaks Swift array bridging and
            // AppKit's dynamic view properties during live environment updates.
            // Unbound rows always follow the captured original implementations.
            class_replaceMethod(base,#selector(NSTableRowView.drawSelection(in:)),imp_implementationWithBlock(drawBlock),method_getTypeEncoding(draw))
            class_replaceMethod(base,#selector(getter:NSTableRowView.interiorBackgroundStyle),imp_implementationWithBlock(styleBlock),method_getTypeEncoding(style))
            decoratedRowClasses.insert(ObjectIdentifier(base))
        }
        objc_setAssociatedObject(row,&rowKey,RowBinding(owner:owner),.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    private static func undecorate(_ row:NSTableRowView,owner:Owner) {
        guard let binding=objc_getAssociatedObject(row,&rowKey) as? RowBinding,binding.owner === owner else{return}
        objc_setAssociatedObject(row,&rowKey,nil,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func install(on table:NSTableView,preferences:UserDefaults,primaryColumn:NSTableColumn?,labelText:((Int)->String?)?=nil,font:NSFont?=nil,leadingInset:CGFloat=0,client:AnyObject?=nil) {
        // A closed owner's late SwiftUI update cannot revive its proxy. A
        // deliberate detach/remove permits a fresh attachment afterwards.
        if let previous=owner(table) {
            if !previous.accepts(client:client) {
                previous.retire()
                objc_setAssociatedObject(table,&key,nil,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else if previous.retired {
                guard let window=table.window,window !== previous.retiredWindow else{return}
                objc_setAssociatedObject(table,&key,nil,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else if !previous.delegateIsCurrent(table) {
                previous.retire()
                objc_setAssociatedObject(table,&key,nil,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
        let owner=(objc_getAssociatedObject(table,&key) as? Owner) ?? Owner(table:table,client:client)
        objc_setAssociatedObject(table,&key,owner,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        owner.preferences=preferences;owner.primaryColumn=primaryColumn;owner.labelText=labelText;owner.font=font;owner.leadingInset=leadingInset
        owner.bind();owner.invalidate()
    }
    static func remove(from table:NSTableView,client:AnyObject?=nil) {
        guard let owner=objc_getAssociatedObject(table,&key) as? Owner,owner.accepts(client:client) else{return}
        owner.retire();objc_setAssociatedObject(table,&key,nil,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    fileprivate static func owner(_ table:NSTableView)->Owner? {objc_getAssociatedObject(table,&key) as? Owner}
    /// Actual measured label bounds, in table coordinates; useful to consumers
    /// drawing additional adornments without assuming column width == text.
    static func labelRect(in table:NSTableView,row:Int)->NSRect? {owner(table)?.label(row:row)?.rect}
    static func labelTextRect(in table:NSTableView,row:Int)->NSRect? {owner(table)?.label(row:row)?.frame}
    /// Snapshot of the actual caption/font and drawing bounds in table
    /// coordinates. Marker captions draw their attributed text into these bounds;
    /// ordinary native cells retain their original cell drawing path.
    static func labelDrawing(in table:NSTableView,row:Int)->(cell:NSTextFieldCell,frame:NSRect)? {
        guard let label=owner(table)?.label(row:row),let cell=label.cell.copy() as? NSTextFieldCell else{return nil}
        return (cell,label.frame)
    }
    static func usesFullRowSelection(in table:NSTableView)->Bool? {guard let owner=owner(table),owner.isCurrent(table) else{return nil};return owner.fullRow}
    static func originalDelegate(of table:NSTableView)->NSTableViewDelegate? {
        guard let owner=owner(table),owner.isCurrent(table) else{return table.delegate}
        return owner.original
    }

    fileprivate struct Label {
        let rect:NSRect,frame:NSRect,cell:NSTextFieldCell
        var contentFrame=false
    }
    @MainActor fileprivate final class Owner:NSObject,NSTableViewDelegate {
        weak var table:NSTableView?
        weak var original:NSTableViewDelegate?
        private let observesOutline:Bool
        private var originalIdentity:ObjectIdentifier?
        private weak var observedClip:NSClipView?
        private var priorClipNotifications:Bool?
        weak var primaryColumn:NSTableColumn?
        private weak var client:AnyObject?
        private let clientIdentity:ObjectIdentifier?
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
        private var reconciliationPending=false
        private var reconciliationGeneration=UUID()
        private(set) var retired=false
        private(set) weak var retiredWindow:NSWindow?
        var fullRow:Bool {AdvancedListBehavior(defaults:preferences).fullRowSelect}
        func accepts(client:AnyObject?)->Bool {
            guard clientIdentity==client.map(ObjectIdentifier.init) else{return false}
            return clientIdentity==nil || self.client === client
        }
        init(table:NSTableView,client:AnyObject?) {
            self.table=table;self.client=client;clientIdentity=client.map(ObjectIdentifier.init)
            observesOutline=table is NSOutlineView
            original=table.delegate;originalIdentity=table.delegate.map(ObjectIdentifier.init)
            originalHighlightStyle=table.selectionHighlightStyle;super.init()
            for name in [NSTableView.selectionDidChangeNotification,NSOutlineView.selectionDidChangeNotification,NSTableView.columnDidResizeNotification,NSTableView.columnDidMoveNotification,NSView.boundsDidChangeNotification,UserDefaults.didChangeNotification,NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
                let center=name == NSWorkspace.accessibilityDisplayOptionsDidChangeNotification ? NSWorkspace.shared.notificationCenter:NotificationCenter.default
                observations.append(center.addObserver(forName:name,object:nil,queue:.main){[weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else{return}
                        if name == NSTableView.selectionDidChangeNotification || name == NSOutlineView.selectionDidChangeNotification || name == NSTableView.columnDidResizeNotification || name == NSTableView.columnDidMoveNotification {
                            guard let source=note.object as? NSTableView,source === self.table else{return}
                        } else if name == NSView.boundsDidChangeNotification {
                            guard self.observesOutline,let clip=note.object as? NSClipView,clip === self.table?.enclosingScrollView?.contentView else{return}
                        } else if name == NSWindow.didBecomeKeyNotification || name == NSWindow.didResignKeyNotification {
                            guard let source=note.object as? NSWindow,source === self.table?.window else{return}
                        }
                        self.invalidate()
                    }
                })
            }
            observations.append(NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:nil,queue:.main){[weak self] note in
                MainActor.assumeIsolated {guard let self,let window=note.object as? NSWindow,window === self.table?.window else{return};self.retire()}
            })
        }
        func bind() {
            guard !retired,let table else{return}
            // SwiftUI's outline-backed Table owns its native delegate and
            // selection binding. Preserve that outline delegate contract;
            // table-only optional-selector forwarding is not a substitute.
            // Decorate those rows through notifications and reconciliation.
            if !observesOutline,table.delegate !== self {
                original=table.delegate;originalIdentity=table.delegate.map(ObjectIdentifier.init);table.delegate=self
            }
            if observesOutline,let clip=table.enclosingScrollView?.contentView,clip !== observedClip {
                if let previous=observedClip,let priorClipNotifications {previous.postsBoundsChangedNotifications=priorClipNotifications}
                observedClip=clip;priorClipNotifications=clip.postsBoundsChangedNotifications
                clip.postsBoundsChangedNotifications=true
            }
            overlay.owner=self;overlay.frame=table.bounds;overlay.autoresizingMask=[.width,.height];overlay.setAccessibilityElement(false)
            // SwiftUI tables compose their cells into layers; a drawing-only
            // subview must participate above those layers too.
            overlay.wantsLayer=true;overlay.layer?.zPosition=1000
            scheduleReconciliation()
        }
        override func responds(to selector:Selector!)->Bool {super.responds(to:selector) || original?.responds(to:selector)==true}
        override func forwardingTarget(for selector:Selector!)->Any? {original?.responds(to:selector)==true ? original:super.forwardingTarget(for:selector)}
        func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {
            let supplied=original?.tableView?(tableView,rowViewForRow:row)
            let view=supplied ?? NativeListSelectionRowView()
            guard isCurrent(tableView) else{return view}
            configureRow(view);scheduleReconciliation();return view
        }
        func tableView(_ tableView:NSTableView,willDisplayCell cell:Any,for tableColumn:NSTableColumn?,row:Int) {
            original?.tableView?(tableView,willDisplayCell:cell,for:tableColumn,row:row)
            guard isCurrent(tableView) else{return}
            if !fullRow,let cell=cell as? NSCell {cell.isHighlighted=false;cell.backgroundStyle = .normal}
        }
        func tableView(_ tableView:NSTableView,didAdd rowView:NSTableRowView,forRow row:Int) {
            original?.tableView?(tableView,didAdd:rowView,forRow:row)
            guard isCurrent(tableView) else{return}
            configureRow(rowView);scheduleReconciliation()
        }
        // Row factories must not ask the table for cells, enumerate its rows or
        // change its subview hierarchy while AppKit is adding that same row.
        private func configureRow(_ row:NSTableRowView) {
            let previous:Owner?
            if let row=row as? NativeListSelectionRowView {previous=row.selectionOwner}
            else {previous=(objc_getAssociatedObject(row,&NativeListSelection.rowKey) as? RowBinding)?.owner}
            if let previous,previous !== self {previous.release(row)}
            if !rows.contains(where:{$0.value === row}) {
                rows.removeAll{$0.value==nil}
                let style = !fullRow && row.selectionHighlightStyle == .none ? originalHighlightStyle:row.selectionHighlightStyle
                rows.append(WeakRow(row,style:style))
            }
            if let saved=rows.first(where:{$0.value === row}) {
                let style:NSTableView.SelectionHighlightStyle=fullRow ? saved.originalStyle:.none
                if row.selectionHighlightStyle != style {row.selectionHighlightStyle=style}
            }
            if let row=row as? NativeListSelectionRowView {row.selectionOwner=self;row.needsDisplay=true}
            else {NativeListSelection.decorate(row,owner:self);row.needsDisplay=true}
        }
        private func owns(_ row:NSTableRowView)->Bool {
            if let row=row as? NativeListSelectionRowView {return row.selectionOwner === self}
            return (objc_getAssociatedObject(row,&NativeListSelection.rowKey) as? RowBinding)?.owner === self
        }
        fileprivate func delegateIsCurrent(_ table:NSTableView)->Bool {
            if !observesOutline {return table.delegate === self}
            guard let identity=originalIdentity else{return table.delegate == nil}
            guard let delegate=table.delegate,let original else{return false}
            return ObjectIdentifier(delegate)==identity && delegate === original
        }
        fileprivate func isCurrent(_ table:NSTableView)->Bool {
            !retired && self.table === table && (clientIdentity==nil || client != nil) &&
            NativeListSelection.owner(table) === self && delegateIsCurrent(table)
        }
        private func release(_ row:NSTableRowView) {
            guard owns(row) else{return}
            if let saved=rows.first(where:{$0.value === row}) {row.selectionHighlightStyle=saved.originalStyle}
            NativeListSelection.undecorate(row,owner:self)
            if let row=row as? NativeListSelectionRowView {row.selectionOwner=nil}
            row.needsDisplay=true
            rows.removeAll{$0.value==nil || $0.value === row}
        }
        func invalidate() {scheduleReconciliation()}
        private func scheduleReconciliation() {
            guard !reconciliationPending,let table,isCurrent(table) else{return}
            reconciliationPending=true
            let generation=reconciliationGeneration
            DispatchQueue.main.async { [weak self,weak table] in
                guard let self,self.reconciliationGeneration==generation else{return}
                self.reconciliationPending=false
                guard let table,self.isCurrent(table) else{return}
                self.reconcile(table)
            }
        }
        private func reconcile(_ table:NSTableView) {
            // All work uses the current row mapping, never an index captured by
            // a delegate callback before a reload, sort or native row reuse.
            var available:[(NSTableRowView,Int)]=[]
            table.enumerateAvailableRowViews {row,index in available.append((row,index))}
            guard isCurrent(table) else{return}
            let style:NSTableView.SelectionHighlightStyle=fullRow ? originalHighlightStyle:.none
            if table.selectionHighlightStyle != style {table.selectionHighlightStyle=style}
            for (row,index) in available {
                guard isCurrent(table) else{return}
                guard row.superview != nil,table.row(for:row)==index else{continue}
                configureRow(row)
                for column in table.tableColumns.indices {
                    guard isCurrent(table),owns(row),table.row(for:row)==index else{break}
                    let cell=table.view(atColumn:column,row:index,makeIfNecessary:false) as? NSTableCellView
                    guard isCurrent(table),owns(row),table.row(for:row)==index else{return}
                    cell?.backgroundStyle=row.interiorBackgroundStyle
                }
            }
            // Preserve the existing overlay, native row backgrounds and label
            // drawing. Reorder once per reconciliation, outside row delegates.
            guard isCurrent(table) else{return}
            if table.subviews.last !== overlay {table.addSubview(overlay,positioned:.above,relativeTo:nil)}
            table.needsDisplay=true
            overlay.frame=table.bounds;overlay.isHidden=fullRow;overlay.needsDisplay=true
        }
        func retire() {
            guard !retired else{return};retired=true
            if let observedClip,let priorClipNotifications {observedClip.postsBoundsChangedNotifications=priorClipNotifications}
            observedClip=nil;priorClipNotifications=nil
            retiredWindow=table?.window
            reconciliationGeneration=UUID();reconciliationPending=false
            if let table {
                table.selectionHighlightStyle=originalHighlightStyle
                if table.delegate === self {table.delegate=original}
                for row in rows.compactMap(\.value) {release(row)}
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
            guard !retired,let table,isCurrent(table),let column=primaryColumn,let index=table.tableColumns.firstIndex(where:{$0 === column}),row>=0,row<table.numberOfRows,!column.isHidden else{return nil}
            let bounds=table.frameOfCell(atColumn:index,row:row)
            guard bounds.width>0,bounds.height>0 else{return nil}
            func textField(_ view:NSView)->NSTextField? {
                if let field=view as? NSTextField{return field}
                if let cell=view as? NSTableCellView,let field=cell.textField{return field}
                return view.subviews.compactMap(textField).first
            }
            let nativeCell=table.view(atColumn:index,row:row,makeIfNecessary:false)
            func currentColumnFrame(_ rect:NSRect,from view:NSView)->NSRect {
                var converted=view.convert(rect,to:table)
                // Reordering retains the real column/cell binding before
                // AppKit moves that cell view's presentation frame. Measure
                // its actual label offset, but anchor it to the current
                // primary column rather than intersecting its old origin.
                if !observesOutline,let cell=nativeCell as? NSTableCellView,
                   table.row(for:cell)==row,
                   table.view(atColumn:index,row:row,makeIfNecessary:false) === cell {
                    let origin=cell.convert(cell.bounds,to:table).minX
                    converted.origin.x += bounds.minX-origin
                }
                return converted
            }
            func marker(_ view:NSView)->NativeListSelectionLabelMarker.Probe? {
                if let marker=view as? NativeListSelectionLabelMarker.Probe,!marker.retired {return marker}
                return view.subviews.compactMap(marker).first
            }
            if let marker=nativeCell.flatMap(marker) {
                let measured=currentColumnFrame(marker.bounds,from:marker)
                guard marker.window === table.window,measured.width>0,measured.height>0,
                      measured.intersects(bounds),
                      let text=labelText?(row) ?? (table.dataSource?.tableView?(table,objectValueFor:column,row:row) as? String) else{return nil}
                let cell=NSTextFieldCell(textCell:text)
                cell.font=font ?? table.font ?? .systemFont(ofSize:NSFont.systemFontSize)
                cell.lineBreakMode = .byTruncatingTail
                let paragraph=NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                paragraph.alignment = .left
                cell.attributedStringValue=NSAttributedString(string:text,attributes:[.font:cell.font!,.paragraphStyle:paragraph])
                let frame=measured.intersection(bounds)
                let rect=NSRect(x:frame.minX-2,y:bounds.minY,width:frame.width+4,height:bounds.height).intersection(bounds)
                return Label(rect:rect,frame:frame,cell:cell,contentFrame:true)
            }
            let field=nativeCell.flatMap(textField)
            if let field {
                // Let the native field editor render its own selection/caret.
                guard field.currentEditor()==nil else{return nil}
                guard let cell=field.cell?.copy() as? NSTextFieldCell else{return nil}
                let frame=currentColumnFrame(field.bounds,from:field)
                let drawing=currentColumnFrame(field.cell?.drawingRect(forBounds:field.bounds) ?? field.bounds,from:field)
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
            if label.contentFrame {
                // The marker is Text's drawable content, not a native control
                // frame. Draw the single-line attributed caption directly so
                // NSCell's additional layout cannot truncate a fitted caption.
                text.draw(with:frame,options:[.usesLineFragmentOrigin,.truncatesLastVisibleLine],context:nil)
            } else {label.cell.drawInterior(withFrame:frame,in:view)}
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
/// Measure the primary Text itself before a consumer expands its column frame.
/// This view supplies geometry only; input and accessibility stay with the Text.
@MainActor struct NativeListSelectionLabelMarker:NSViewRepresentable {
    func makeNSView(context:Context)->Probe {Probe()}
    func updateNSView(_ view:Probe,context:Context) {view.invalidateGeometry(force:true)}
    static func dismantleNSView(_ view:Probe,coordinator:()) {view.retire()}
    final class Probe:NSView {
        private(set) var retired=false
        private var lastFrame=NSRect.null
        private weak var lastTable:NSTableView?
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func isAccessibilityElement()->Bool {false}
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();invalidateGeometry()}
        override func viewDidMoveToSuperview(){super.viewDidMoveToSuperview();invalidateGeometry()}
        override func layout(){super.layout();invalidateGeometry()}
        func invalidateGeometry(force:Bool=false) {
            guard !retired else{return}
            var ancestor=superview
            while let view=ancestor {
                if let table=view as? NSTableView {
                    let frame=convert(bounds,to:table)
                    guard force || table !== lastTable || frame != lastFrame else{return}
                    lastTable=table;lastFrame=frame
                    NativeListSelection.owner(table)?.invalidate();return
                }
                ancestor=view.superview
            }
            lastTable=nil;lastFrame = .null
        }
        func retire(){retired=true;if let lastTable {NativeListSelection.owner(lastTable)?.invalidate()};lastTable=nil}
    }
}

/// Attach as the background of precisely one SwiftUI Table, not its enclosing
/// window. The column object is retained across native column reordering.
@MainActor struct NativeListSelectionProbe:NSViewRepresentable {
    var preferences:UserDefaults = .standard
    var primaryTitle:String?=nil
    var primaryColumnIndex:Int=0
    var labelText:((Int)->String?)?=nil
    var font:NSFont?=nil
    var leadingInset:CGFloat=0
    var uniformRowGeometry:FileListUniformRowGeometry?=nil
    var rowIDs:(()->[Data]?)?=nil
    func makeNSView(context:Context)->Probe {Probe()}
    func updateNSView(_ view:Probe,context:Context) {view.update(settings:self)}
    static func dismantleNSView(_ view:Probe,coordinator:()) {view.retire()}
    final class Probe:NSView {
        var settings:NativeListSelectionProbe?
        private weak var table:NSTableView?
        private weak var column:NSTableColumn?
        private var retired=false,pending=false
        private var closeObserver:NSObjectProtocol?
        private var lastBounds=NSRect.zero
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func viewDidMoveToWindow(){
            super.viewDidMoveToWindow()
            if let closeObserver{NotificationCenter.default.removeObserver(closeObserver);self.closeObserver=nil}
            guard !retired else{return}
            guard let window else{detach();return}
            closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in
                MainActor.assumeIsolated{self?.retire()}
            }
            schedule()
        }
        func update(settings:NativeListSelectionProbe){guard !retired else{return};self.settings=settings;schedule()}
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
            if let column,!next.tableColumns.contains(where:{$0 === column}) {self.column=nil}
            if column==nil {
                column=settings.primaryTitle.flatMap{title in next.tableColumns.first{$0.title==title || $0.title==NSLocalizedString(title,comment:"")}}
                if column==nil,next.tableColumns.indices.contains(settings.primaryColumnIndex) {column=next.tableColumns[settings.primaryColumnIndex]}
            }
            NativeListSelection.install(on:next,preferences:settings.preferences,primaryColumn:column,labelText:settings.labelText,font:settings.font,leadingInset:settings.leadingInset,client:self)
            if let geometry=settings.uniformRowGeometry {
                NativeReportRowGeometry.install(on:next,font:geometry.font,groupFont:geometry.groupFont,minimumContentHeight:geometry.minimumContentHeight,verticalPadding:geometry.verticalPadding,client:self,rowIDs:settings.rowIDs)
            } else {NativeReportRowGeometry.remove(from:next,client:self)}
        }
        private func detach(){if let table {NativeListSelection.remove(from:table,client:self);NativeReportRowGeometry.remove(from:table,client:self)};table=nil;column=nil}
        func retire(){
            guard !retired else{return};retired=true;detach();settings=nil
            if let closeObserver{NotificationCenter.default.removeObserver(closeObserver);self.closeObserver=nil}
        }
        deinit{if let closeObserver{NotificationCenter.default.removeObserver(closeObserver)}}
    }
}
