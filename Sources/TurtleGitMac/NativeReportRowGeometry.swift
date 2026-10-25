// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC

/// Opt-in geometry for compact, single-line report lists. Selection, delegates,
/// row identity and intercell spacing remain owned by the native table/caller.
/// Install from the consumer's deferred table configuration, not a row callback.
@MainActor enum NativeReportRowGeometry {
    private static var key:UInt8=0
    @MainActor private struct Original {
        let automatic:Bool
        let height:CGFloat
        let sizeStyle:NSTableView.RowSizeStyle
        init(_ table:NSTableView) {automatic=table.usesAutomaticRowHeights;height=table.rowHeight;sizeStyle=table.rowSizeStyle}
    }
    /// A shared line box accommodates the configured file font, bold group
    /// captions, native checkbox and icon. No measured cell/row is consulted.
    static func rowHeight(font:NSFont,groupFont:NSFont?=nil,minimumContentHeight:CGFloat=20,verticalPadding:CGFloat=4)->CGFloat {
        let metrics=NSLayoutManager()
        let line=max(metrics.defaultLineHeight(for:font),groupFont.map{metrics.defaultLineHeight(for:$0)} ?? 0)
        let minimum=minimumContentHeight.isFinite ? max(0,minimumContentHeight):20
        let padding=verticalPadding.isFinite ? max(0,verticalPadding):4
        return max(1,ceil(max(line,minimum)+padding))
    }
    static func install(on table:NSTableView,font:NSFont,groupFont:NSFont?=nil,minimumContentHeight:CGFloat=20,verticalPadding:CGFloat=4,client:AnyObject,rowIDs:(()->[Data]?)?=nil) {
        let previous=objc_getAssociatedObject(table,&key) as? Owner
        let owner:Owner
        if let previous,previous.accepts(client),!previous.retired {
            owner=previous
        } else {
            if let previous,previous.accepts(client),previous.retired {
                // Late updates from a closed window cannot revive its owner.
                // A deliberate reparenting to another native window can opt in.
                guard let window=table.window,window !== previous.retiredWindow else{return}
            }
            // Handoff carries the original native settings, rather than
            // recapturing the predecessor's temporary fixed row height.
            let original:Original
            if let previous,!previous.retired || previous.restoringBaseline {original=previous.original}
            else {original=Original(table)}
            previous?.retire(restoring:false)
            owner=Owner(table:table,client:client,original:original)
            objc_setAssociatedObject(table,&key,owner,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        owner.rowIDs=rowIDs
        owner.apply(height:rowHeight(font:font,groupFont:groupFont,minimumContentHeight:minimumContentHeight,verticalPadding:verticalPadding))
    }
    static func remove(from table:NSTableView,client:AnyObject) {
        guard let owner=objc_getAssociatedObject(table,&key) as? Owner,owner.accepts(client) else{return}
        owner.retire(restoring:true)
        if (objc_getAssociatedObject(table,&key) as? Owner) === owner {
            objc_setAssociatedObject(table,&key,nil,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    @MainActor private final class Owner {
        weak var table:NSTableView?
        private weak var client:AnyObject?
        private let clientIdentity:ObjectIdentifier
        let original:Original
        private(set) var retired=false
        private(set) var restoringBaseline=false
        private(set) weak var retiredWindow:NSWindow?
        private var closingObserver:NSObjectProtocol?
        private var geometryObservations:[NSKeyValueObservation]=[]
        private var desiredHeight:CGFloat?
        var rowIDs:(()->[Data]?)?
        private var configuration=UUID()
        private struct SelectionReceipt {
            let rows:[Data]
            let selected:IndexSet
            let delegate:ObjectIdentifier?
            let dataSource:ObjectIdentifier?
        }
        private var reconciliationPending=false
        private var reconciliationGeneration=UUID()
        init(table:NSTableView,client:AnyObject,original:Original) {
            self.table=table;self.client=client;clientIdentity=ObjectIdentifier(client);self.original=original
            // SwiftUI can restore its estimated height during a later table
            // update. Observe the public sizing properties and reconcile after
            // that update; never enter row construction from a KVO callback.
            geometryObservations = [
                table.observe(\.rowHeight,options:[.new]) { [weak self] _,_ in self?.geometryChanged() },
                table.observe(\.usesAutomaticRowHeights,options:[.new]) { [weak self] _,_ in self?.geometryChanged() },
                table.observe(\.rowSizeStyle,options:[.new]) { [weak self] _,_ in self?.geometryChanged() }
            ]
            closingObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:nil,queue:.main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self,let window=note.object as? NSWindow,window === self.table?.window else{return}
                    self.retire(restoring:true)
                }
            }
        }
        func accepts(_ client:AnyObject)->Bool {clientIdentity==ObjectIdentifier(client) && self.client === client}
        private var isCurrent:Bool {
            guard let table else{return false}
            return (objc_getAssociatedObject(table,&NativeReportRowGeometry.key) as? Owner) === self
        }
        nonisolated private func geometryChanged() {
            DispatchQueue.main.async { [weak self] in self?.scheduleReconciliation() }
        }
        private func scheduleReconciliation() {
            guard !retired,client != nil,isCurrent,!reconciliationPending,let table else{return}
            reconciliationPending=true
            let generation=reconciliationGeneration
            DispatchQueue.main.async { [weak self,weak table] in
                guard let self,self.reconciliationGeneration==generation else{return}
                self.reconciliationPending=false
                guard let table,self.table === table else{return}
                self.reconcile()
            }
        }
        private func identity(_ object:AnyObject?)->ObjectIdentifier? {object.map{ObjectIdentifier($0)}}
        private func captureSelection(_ table:NSTableView,current:()->Bool)->SelectionReceipt? {
            guard current() else{return nil}
            let selected=table.selectedRowIndexes,delegate=identity(table.delegate),source=identity(table.dataSource)
            guard !selected.isEmpty,let rows=rowIDs?(),current(),
                  table.selectedRowIndexes==selected,identity(table.delegate)==delegate,identity(table.dataSource)==source,
                  rows.count==table.numberOfRows,Set(rows).count==rows.count,
                  selected.allSatisfy({rows.indices.contains($0)}) else{return nil}
            return SelectionReceipt(rows:rows,selected:selected,delegate:delegate,dataSource:source)
        }
        private func restoreSelection(_ receipt:SelectionReceipt?,table:NSTableView,current:()->Bool) {
            // Native sizing can clear selection. Never infer identities from
            // indexes or overwrite a new nonempty selection made by a delegate.
            guard let receipt,current(),table.selectedRowIndexes.isEmpty,
                  identity(table.delegate)==receipt.delegate,identity(table.dataSource)==receipt.dataSource,
                  let rows=rowIDs?(),current(),rows==receipt.rows,table.numberOfRows==rows.count,
                  identity(table.delegate)==receipt.delegate,identity(table.dataSource)==receipt.dataSource,
                  table.selectedRowIndexes.isEmpty else{return}
            table.selectRowIndexes(receipt.selected,byExtendingSelection:false)
        }
        func apply(height:CGFloat) {
            guard !retired,client != nil,isCurrent else{return}
            configuration=UUID();desiredHeight=height
            reconcile();scheduleReconciliation()
        }
        private func reconcile() {
            guard !retired,client != nil,isCurrent,let table,let desiredHeight else{return}
            guard table.rowSizeStyle != .custom || table.usesAutomaticRowHeights || table.rowHeight != desiredHeight else{return}
            let accepted=configuration
            func current()->Bool {!retired && client != nil && isCurrent && configuration==accepted && self.desiredHeight==desiredHeight && self.table === table}
            let selection=captureSelection(table,current:current)
            guard current() else{return}
            // AppKit documents arbitrary rowHeight only for the custom style.
            // Assign only changed values so our notifications settle at once.
            if table.rowSizeStyle != .custom {table.rowSizeStyle = .custom}
            guard current() else{return}
            if table.usesAutomaticRowHeights {table.usesAutomaticRowHeights=false}
            guard current() else{return}
            if table.rowHeight != desiredHeight {table.rowHeight=desiredHeight}
            restoreSelection(selection,table:table,current:current)
        }
        func retire(restoring:Bool) {
            guard !retired else{return};retired=true;retiredWindow=table?.window
            reconciliationGeneration=UUID();reconciliationPending=false;desiredHeight=nil
            geometryObservations.forEach{$0.invalidate()};geometryObservations=[]
            if restoring,isCurrent,let table,
               table.rowSizeStyle != original.sizeStyle || table.rowHeight != original.height || table.usesAutomaticRowHeights != original.automatic {
                restoringBaseline=true
                defer{restoringBaseline=false}
                func current()->Bool {restoringBaseline && isCurrent && client != nil && self.table === table}
                let selection=captureSelection(table,current:current)
                if isCurrent,table.rowSizeStyle != .custom {table.rowSizeStyle = .custom}
                if isCurrent,table.rowHeight != original.height {table.rowHeight=original.height}
                if isCurrent,table.rowSizeStyle != original.sizeStyle {table.rowSizeStyle=original.sizeStyle}
                if isCurrent,table.usesAutomaticRowHeights != original.automatic {table.usesAutomaticRowHeights=original.automatic}
                restoreSelection(selection,table:table,current:current)
            }
            if let closingObserver {NotificationCenter.default.removeObserver(closingObserver);self.closingObserver=nil}
        }
        deinit {geometryObservations.forEach{$0.invalidate()};if let closingObserver {NotificationCenter.default.removeObserver(closingObserver)}}
    }
}
