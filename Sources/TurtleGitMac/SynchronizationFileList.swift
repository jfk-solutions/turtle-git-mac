// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SyncDlg's InSyncDlg/OutSyncDlg GitStatusListCtrl.
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class SynchronizationFileListState:ObservableObject {
    final class Receipt {
        fileprivate let epoch:UUID,generation:UUID,tab:Int
        fileprivate let child:RevisionComparisonWindowModel.FileMenuContext
        let files:[CommitFile]
        fileprivate init(epoch:UUID,generation:UUID,tab:Int,child:RevisionComparisonWindowModel.FileMenuContext,files:[CommitFile]) {self.epoch=epoch;self.generation=generation;self.tab=tab;self.child=child;self.files=files}
    }
    private weak var owner:SynchronizationWindowModel?
    let incoming:Bool
    let preferences:UserDefaults
    let columnsKey:String
    static let availableColumns=StatusListColumn.defaultColumns
    @Published var selection=GitPathSet() {didSet {if selection != oldValue {epoch=UUID();owner?.objectWillChange.send()}}}
    @Published private(set) var columns:StatusListColumnSettings
    @Published private(set) var sortColumn:StatusListColumn?
    @Published private(set) var ascending=true
    @Published private(set) var resettingColumns=false
    @Published private(set) var autoFitGeneration=UUID()
    private(set) var hasPendingQuestion=false
    var menuEpoch:UUID {epoch}
    private var epoch=UUID(),observation:AnyCancellable?,childObservation:AnyCancellable?
    private var resetRequest:UUID?,resetAlert:NSAlert?,resetReply:((NSApplication.ModalResponse)->Void)?
    private var retired=false
    var clipboard:NSPasteboard = .general
    var presentResetQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Void = {window,alert,reply in alert.beginSheetModal(for:window,completionHandler:reply)}
    var comparison:RevisionComparisonWindowModel? {incoming ? owner?.incomingComparison:owner?.comparison}
    var tab:Int {incoming ? 5:1}
    var available:Bool {
        guard !retired,let owner,let child=comparison else{return false}
        return owner.tab==tab && !owner.closed && !owner.busy && !owner.confirmingQuit && !owner.confirmingCancellation && !owner.hasBlockingChild && NSApp.modalWindow==nil && owner.window?.attachedSheet==nil && !child.closed && !child.busy && !child.confirmingQuit && !resettingColumns
    }
    init(owner:SynchronizationWindowModel,incoming:Bool) {
        self.owner=owner;self.incoming=incoming;preferences=owner.preferences
        columnsKey="TurtleGit."+(incoming ? "InSyncDlg":"OutSyncDlg")+".Columns"
        columns=StatusListColumnSettings.load(from:owner.preferences,key:columnsKey)
        observation=owner.objectWillChange.sink{[weak self] _ in self?.epoch=UUID()}
        childObservation=(incoming ? owner.incomingComparison:owner.comparison).objectWillChange.sink{[weak self,weak owner] _ in self?.epoch=UUID();owner?.objectWillChange.send()}
    }
    var rows:[CommitFile] {
        let files=comparison?.snapshot?.files ?? []
        guard let column=sortColumn else{return files}
        return files.sorted {a,b in
            let result=compare(a,b,column:column)
            return ascending ? result == .orderedAscending:result == .orderedDescending
        }
    }
    private func compare(_ a:CommitFile,_ b:CommitFile,column:StatusListColumn)->ComparisonResult {
        func text(_ a:String,_ b:String,numeric:Bool=true)->ComparisonResult {a.compare(b,options:numeric ? [.caseInsensitive,.numeric]:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))}
        var result:ComparisonResult
        switch column {
        case .fileExtension:result=text(StatusListClipboard.fileExtension(a.path,isDirectory:a.isSubmodule),StatusListClipboard.fileExtension(b.path,isDirectory:b.isSubmodule))
        case .status:result=text(FileListLabels.caption(a.status),FileListLabels.caption(b.status),numeric:false)
        case .added,.removed:
            let x=(column == .added ? a.added:a.removed) ?? 0,y=(column == .added ? b.added:b.removed) ?? 0
            result=x<y ? .orderedAscending:x>y ? .orderedDescending:.orderedSame
        default:result=text(a.path,b.path)
        }
        if result == .orderedSame {result=text(a.path,b.path)}
        if result == .orderedSame,!a.path.utf8.elementsEqual(b.path.utf8) {result=a.path.utf8.lexicographicallyPrecedes(b.path.utf8) ? .orderedAscending:.orderedDescending}
        return result
    }
    func sort(by column:StatusListColumn,ascending:Bool) {
        guard available,Self.availableColumns.contains(column) else{return}
        epoch=UUID();sortColumn=column;self.ascending=ascending
    }
    private func rawText(_ file:CommitFile,column:StatusListColumn)->String {
        switch column {
        case .path:return StatusListClipboard.displayedPath(file,abbreviate:preferences.bool(forKey:"AbbreviateRenamings"))
        case .fileExtension:return StatusListClipboard.fileExtension(file.path,isDirectory:file.isSubmodule)
        case .status:return FileListLabels.caption(file.status)
        case .added:return file.hasStatistics ? file.added.map(String.init) ?? "-":""
        case .removed:return file.hasStatistics ? file.removed.map(String.init) ?? "-":""
        default:return ""
        }
    }
    /// Native text and selection overlays must remain one physical line even
    /// for literal Git names containing line separators. Only display escapes;
    /// identity, tooltips and every clipboard format keep the original bytes.
    func text(_ file:CommitFile,column:StatusListColumn)->String {
        var value=rawText(file,column:column).replacingOccurrences(of:"\r\n",with:"↵")
        for separator in ["\r","\n","\u{0085}","\u{2028}","\u{2029}","\u{000B}","\u{000C}"] {value=value.replacingOccurrences(of:separator,with:"↵")}
        return value.replacingOccurrences(of:"\t",with:"⇥")
    }
    func capture(_ paths:GitPathSet)->Receipt? {
        guard available,let owner,let child=comparison,let captured=child.captureFileMenu(paths) else{return nil}
        let files=rows.filter {paths.contains($0.path)}
        guard !files.isEmpty else{return nil}
        return Receipt(epoch:epoch,generation:owner.fileListGeneration,tab:tab,child:captured,files:files)
    }
    private func claim(_ receipt:Receipt)->Bool {
        guard available,let owner,receipt.epoch==epoch,receipt.generation==owner.fileListGeneration,receipt.tab==owner.tab,let child=comparison else{return false}
        return child.claimFileMenu(receipt.child)
    }
    /// Capture all highlighted native rows, including text-only occurrences.
    /// Sync installs Rev1=new/Rev2=old: its transfer endpoint is the immutable
    /// base, unlike the selected-child revision in Log's changed-file list.
    func captureFileDrag(_ orderedPaths:[String],epoch captured:UUID)->FileListSelectionDrag? {
        guard available,epoch==captured,!orderedPaths.isEmpty,GitPathSet(orderedPaths).count==orderedPaths.count,
              let child=comparison,!child.hasOwnedPreparation,let snapshot=child.snapshot else{return nil}
        let lookup=GitPathMap(uniqueKeysWithValues:rows.map{($0.path,$0)})
        let files=orderedPaths.compactMap{lookup[$0]}
        guard files.count==orderedPaths.count,orderedPaths.allSatisfy({selection.contains($0)}) else{return nil}
        return FileListSelectionDrag(repository:child.repository,access:child.access,files:files,revision:snapshot.from,backend:child.materializationBackend())
    }
    /// Sync's status list sets Rev1=new and Rev2=old; drag-out uses Rev2.
    func dragWriter(_ file:CommitFile,epoch captured:UUID)->NSPasteboardWriting? {
        guard available,epoch==captured,let child=comparison,!child.hasOwnedPreparation,
              let snapshot=child.snapshot,rows.contains(file),
              let plan=try? FileListDragPlan(root:child.repository.root,revision:snapshot.from,files:[file],backend:child.materializationBackend()),
              !plan.items.isEmpty else{return nil}
        return FileListDrag.itemWriter(repository:child.repository,access:child.access,plan:plan,itemAt:0)
    }
    func compare(_ receipt:Receipt,unified:Bool,alternate:Bool) {
        guard claim(receipt),let child=comparison else{return}
        child.error=nil
        let paths=receipt.files.map(\.path)
        ComparisonToolInvocation.$alternate.withValue(alternate) {
            if unified {child.showPatch(paths,alternate:alternate,orderedPaths:paths)}
            else {child.compare(paths,orderedPaths:paths)}
        }
    }
    func copy(_ receipt:Receipt,information:StatusListCopy) {
        guard claim(receipt),let owner else{return}
        let statuses=GitPathMap(receipt.files.map {($0.id,$0.status)},uniquingKeysWith:{first,_ in first})
        let visible=columns.order.filter {Self.availableColumns.contains($0) && columns.visible.contains($0)}
        let value:String
        switch information {
        case .all:
            value=StatusListClipboard.heading(copy:.all,columns:visible,label:FileListLabels.caption)+receipt.files.map {file in visible.map {self.rawText(file,column:$0)}.joined(separator:"\t")}.joined(separator:"\n")+"\n"
        case .column(let column):value=receipt.files.map {rawText($0,column:column)}.joined(separator:"\n")+"\n"
        default:value=StatusListClipboard.text(receipt.files,root:owner.repository.root,statuses:statuses,copy:information,visibleColumns:visible,label:FileListLabels.caption)
        }
        clipboard.clearContents();clipboard.setString(value,forType:.string)
    }
    func setColumn(_ column:StatusListColumn,visible:Bool) {
        guard available,Self.availableColumns.contains(column),column != .path else{return}
        epoch=UUID();if visible {columns.visible.insert(column)} else {columns.visible.remove(column)}
        columns.save(to:preferences,key:columnsKey)
    }
    func saveLayout(order:[StatusListColumn],widths:[StatusListColumn:Double]) {
        guard available else{return}
        let allowed=Set(Self.availableColumns)
        let value=StatusListColumnSettings(visible:columns.visible.intersection(allowed),order:order,widths:widths.filter {allowed.contains($0.key)})
        if columns != value {epoch=UUID();columns=value;value.save(to:preferences,key:columnsKey)}
    }
    func resetColumns() {
        guard available,let owner,let window=owner.window,let child=comparison else{return}
        let request=UUID(),generation=owner.fileListGeneration,childEpoch=child.fileMenuEpoch
        resetRequest=request;resettingColumns=true;hasPendingQuestion=true;owner.beginFileListQuestion();owner.objectWillChange.send()
        let alert=NSAlert();alert.messageText="Reset column order";alert.informativeText="Are you sure you want to reset the column order?"
        alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No");alert.window.alphaValue=window.alphaValue;resetAlert=alert
        let reply:(NSApplication.ModalResponse)->Void = { [weak self,weak owner] response in
            guard let self,let owner,self.resetRequest==request else{return}
            self.resetRequest=nil;self.resetReply=nil
            Task { [self,owner,alert] in
                while alert.window.sheetParent != nil {try? await Task.sleep(nanoseconds:5_000_000)}
                defer {self.resetAlert=nil;self.resettingColumns=false;self.hasPendingQuestion=false;owner.endFileListQuestion();owner.objectWillChange.send()}
                guard response == .alertFirstButtonReturn,!self.retired,!owner.closed,!owner.confirmingQuit,!owner.busy,owner.tab==self.tab,owner.fileListGeneration==generation,child.fileMenuEpoch==childEpoch else{return}
                self.epoch=UUID();self.columns=StatusListColumnSettings();self.autoFitGeneration=UUID();self.columns.save(to:self.preferences,key:self.columnsKey)
            }
        }
        resetReply=reply;presentResetQuestion(window,alert,reply)
    }
    func retire() {
        guard !retired else{return};retired=true;epoch=UUID();observation=nil;childObservation=nil
        if let alert=resetAlert,let parent=alert.window.sheetParent {parent.endSheet(alert.window,returnCode:.abort);alert.window.orderOut(nil)}
        resetReply?(.abort)
    }
}

@MainActor final class SynchronizationFileNativeTable:NSTableView {
    var onCompare:(_ unified:Bool,_ alternate:Bool)->Void = {_,_ in}
    var onCopy:(_ extended:Bool)->Void = {_ in}
    var makeRowMenu:(_ row:Int,_ column:Int)->NSMenu? = {_,_ in nil}
    var clickedRowQuery:(NSTableView)->Int = {$0.clickedRow}
    private(set) var retired=false
    var keyOwnerQuery:(NSWindow)->Bool = {$0.isKeyWindow}
    private var keyboardOwnerAvailable:Bool {guard !retired,let window else{return false};return window.firstResponder === self && keyOwnerQuery(window) && window.attachedSheet==nil && NSApp.modalWindow==nil}
    override func menu(for event:NSEvent)->NSMenu? {
        guard !retired else{return nil}
        let point=convert(event.locationInWindow,from:nil),row=row(at:point),column=column(at:point)
        if row>=0,!selectedRowIndexes.contains(row) {selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
        return makeRowMenu(row,column)
    }
    override func keyDown(with event:NSEvent) {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if [36,76].contains(event.keyCode),flags.isEmpty || flags == .shift {if keyboardOwnerAvailable {onCompare(false,flags.contains(.shift))};return}
        super.keyDown(with:event)
    }
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if keyboardOwnerAvailable,event.charactersIgnoringModifiers?.lowercased()=="c",flags == .command || flags == [.command,.shift] {onCopy(flags.contains(.shift));return true}
        return super.performKeyEquivalent(with:event)
    }
    func retire(){retired=true;onCompare={_,_ in};onCopy={_ in};makeRowMenu={_,_ in nil};target=nil;action=nil;doubleAction=nil;menu=nil}
}

private final class SynchronizationFileMenuItem:NSMenuItem {
    private var invokeAction:(()->Void)?,used=false
    init(_ title:String,id:String,icon:MenuIcon?=nil,preferences:UserDefaults,enabled:Bool=true,action:@escaping()->Void) {
        super.init(title:NSLocalizedString(title,comment:""),action:nil,keyEquivalent:"")
        identifier = .init("Sync.Files."+id);isEnabled=enabled;invokeAction=action;target=self;self.action=#selector(invoke)
        if let icon {image=icon.contextImage(defaults:preferences)}
    }
    required init(coder:NSCoder){fatalError("init(coder:) is not supported")}
    @objc private func invoke(){guard isEnabled,!used else{return};used=true;invokeAction?();invokeAction=nil}
}
private final class SynchronizationFileEmptyLabel:NSTextField {override func hitTest(_ point:NSPoint)->NSView? {nil}}
private final class SynchronizationFileHeader:NSTableHeaderView {
    var makeMenu:()->NSMenu = {NSMenu()}
    override func menu(for event:NSEvent)->NSMenu? {makeMenu()}
}

struct SynchronizationFiles:NSViewRepresentable {
    @ObservedObject var model:SynchronizationWindowModel
    @ObservedObject private var colors=StatusColorUpdates.shared
    func makeCoordinator()->Coordinator {Coordinator(model)}
    func makeNSView(context:Context)->NSScrollView {context.coordinator.make()}
    func updateNSView(_ scroll:NSScrollView,context:Context){context.coordinator.refresh()}
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator){coordinator.retire()}
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSDraggingSource {
        let model:SynchronizationWindowModel
        let state:SynchronizationFileListState
        weak var table:SynchronizationFileNativeTable?
        private var currentRows:[CommitFile]=[],updating=false,retired=false
        private var renderedEpoch=UUID()
        private struct DragPress {let point:NSPoint,row:Int,files:[CommitFile],generation:UUID,from:ComparisonRevision,to:ComparisonRevision}
        private var dragPress:DragPress?,dragMonitor:Any?
        private(set) var activeDrag:FileListSelectionDrag?
        private var dragOwner:Coordinator?
        func captureDrag(rows indexes:IndexSet)->FileListSelectionDrag? {
            guard !retired,activeDrag==nil,let table,let window=table.window,window === model.window,
                  window.attachedSheet==nil,NSApp.modalWindow==nil,!indexes.isEmpty,
                  table.numberOfRows==currentRows.count,currentRows==state.rows,
                  indexes.allSatisfy({currentRows.indices.contains($0) && table.selectedRowIndexes.contains($0)}) else{return nil}
            return state.captureFileDrag(indexes.map{currentRows[$0].path},epoch:state.menuEpoch)
        }
        func observeDrag(_ event:NSEvent)->NSEvent? {
            guard !retired,let table,let window=table.window,event.window===window else{return event}
            if event.type == .leftMouseUp || event.type == .rightMouseDown || event.type == .keyDown {dragPress=nil;return event}
            if event.type == .leftMouseDown {
                dragPress=nil
                guard activeDrag==nil else{return event}
                let point=table.convert(event.locationInWindow,from:nil),row=table.row(at:point),column=table.column(at:point)
                if event.clickCount==1,state.available,table.visibleRect.contains(point),column>=0,currentRows.indices.contains(row),let snapshot=state.comparison?.snapshot {
                    dragPress = .init(point:event.locationInWindow,row:row,files:currentRows,generation:model.fileListGeneration,from:snapshot.from,to:snapshot.to)
                }
                return event
            }
            guard event.type == .leftMouseDragged,let press=dragPress,
                  hypot(event.locationInWindow.x-press.point.x,event.locationInWindow.y-press.point.y)>=4,
                  press.generation==model.fileListGeneration,press.files==currentRows,
                  state.comparison?.snapshot?.from==press.from,state.comparison?.snapshot?.to==press.to,
                  table.selectedRowIndexes.contains(press.row),let drag=captureDrag(rows:table.selectedRowIndexes) else{return event}
            dragPress=nil;activeDrag=drag;dragOwner=self
            let point=table.convert(event.locationInWindow,from:nil)
            let items=drag.writers.enumerated().map{index,writer in
                let item=NSDraggingItem(pasteboardWriter:writer)
                let image=drag.fileURLs.indices.contains(index-1) ? NSWorkspace.shared.icon(forFile:drag.fileURLs[index-1].path):MenuIcon.copy.image()
                item.setDraggingFrame(NSRect(x:point.x+CGFloat(index)*3,y:point.y+CGFloat(index)*3,width:24,height:24),contents:image)
                return item
            }
            table.beginDraggingSession(with:items,event:event,source:self)
            return nil
        }
        func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation {activeDrag?.operationMask ?? .copy}
        func ignoreModifierKeys(for session:NSDraggingSession)->Bool {false}
        func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation){activeDrag=nil;dragPress=nil;dragOwner=nil}
        private weak var emptyLabel:NSTextField?
        private var fittedGeneration:UUID?,fittedRows=0,fittedWidths:[StatusListColumn:CGFloat]=[:]
        private var stateChanges:AnyCancellable?,childChanges:AnyCancellable?,closeObserver:NSObjectProtocol?
        init(_ model:SynchronizationWindowModel){self.model=model;state=model.displayedFileList;super.init()}
        private var font:NSFont {
            if model.preferences.bool(forKey:"LogFontForFileListCtrl") {return MessageEditorFont.resolve(name:model.preferences.string(forKey:"LogFontName") ?? MessageEditorFont.defaultName,size:model.preferences.integer(forKey:"LogFontSize")==0 ? MessageEditorFont.defaultSize:model.preferences.integer(forKey:"LogFontSize"))}
            return .systemFont(ofSize:NSFont.systemFontSize)
        }
        func make()->NSScrollView {
            let table=SynchronizationFileNativeTable();self.table=table
            table.identifier = .init("TurtleGit.Sync.Files."+(state.incoming ? "In":"Out"));table.setAccessibilityLabel(state.incoming ? "In Changelist":"Out Changelist")
            table.setDraggingSourceOperationMask(.copy,forLocal:false);table.setDraggingSourceOperationMask(.copy,forLocal:true)
            table.allowsMultipleSelection=true;table.allowsColumnReordering=true;table.columnAutoresizingStyle = .noColumnAutoresizing
            for column in SynchronizationFileListState.availableColumns {
                let value=NSTableColumn(identifier:.init(column.rawValue));value.title=NSLocalizedString(column.rawValue,comment:"");value.width=column == .path ? 450:90;value.minWidth=40
                value.sortDescriptorPrototype=NSSortDescriptor(key:column.rawValue,ascending:true);table.addTableColumn(value)
            }
            if let sort=state.sortColumn {table.sortDescriptors=[NSSortDescriptor(key:sort.rawValue,ascending:state.ascending)]}
            let header=SynchronizationFileHeader();header.makeMenu={ [weak self] in self?.headerMenu() ?? NSMenu() };table.headerView=header
            table.delegate=self;table.dataSource=self;table.target=self;table.doubleAction=#selector(doubleClick(_:))
            dragMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp,.rightMouseDown,.keyDown]){[weak self] event in guard let self else{return event};return self.observeDrag(event)}
            table.onCompare={ [weak self] unified,alternate in self?.activate(unified:unified,alternate:alternate) }
            table.onCopy={ [weak self] extended in self?.copySelection(extended:extended) }
            table.makeRowMenu={ [weak self] row,column in self?.rowMenu(row:row,column:column) }
            stateChanges=state.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {self?.refresh()} }
            childChanges=state.comparison?.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {self?.refresh()} }
            if let window=model.window {closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in MainActor.assumeIsolated {self?.retire()}}}
            let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.documentView=table
            let empty=SynchronizationFileEmptyLabel(labelWithString:"");empty.textColor = .secondaryLabelColor;empty.alignment = .center;empty.translatesAutoresizingMaskIntoConstraints=false;scroll.addSubview(empty);emptyLabel=empty
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo:scroll.centerXAnchor),empty.centerYAnchor.constraint(equalTo:scroll.centerYAnchor),empty.widthAnchor.constraint(lessThanOrEqualTo:scroll.widthAnchor,constant:-24)])
            refresh();return scroll
        }
        func refresh() {
            guard !retired,let table else{return};updating=true;defer{updating=false}
            currentRows=state.rows
            emptyLabel?.isHidden = !currentRows.isEmpty
            emptyLabel?.stringValue = model.busy ? NSLocalizedString("Please wait…",comment:""):model.error ?? NSLocalizedString("No differences found!",comment:"")
            if fittedGeneration != state.autoFitGeneration || state.columns.widths.isEmpty && fittedRows != currentRows.count {
                fittedGeneration=state.autoFitGeneration;fittedRows=currentRows.count
                let width=max(320,model.window?.contentView?.bounds.width ?? 900)
                for column in SynchronizationFileListState.availableColumns {
                    let strings=[NSLocalizedString(column.rawValue,comment:"")]+currentRows.prefix(2048).map {state.text($0,column:column)}
                    let measured=strings.map {($0 as NSString).size(withAttributes:[.font:font]).width}.max() ?? 40
                    fittedWidths[column]=min(column == .path ? width*0.65:width*0.25,max(column == .path ? 220:60,ceil(measured)+(column == .path ? 34:20)))
                }
            }
            let retained=state.selection.intersection(currentRows.map(\.path))
            if retained != state.selection {state.selection=retained}
            let allowed=Set(SynchronizationFileListState.availableColumns)
            let order=state.columns.order.filter {allowed.contains($0)}
            for (index,column) in order.enumerated() {
                guard let actual=table.tableColumn(withIdentifier:.init(column.rawValue)),let old=table.tableColumns.firstIndex(of:actual) else{continue}
                if old != index {table.moveColumn(old,toColumn:index)}
                actual.isHidden = !state.columns.visible.contains(column)
                let desired=state.columns.widths[column].map {CGFloat($0)} ?? fittedWidths[column] ?? (column == .path ? 450:90)
                if abs(actual.width-desired)>0.5 {actual.width=desired}
            }
            renderedEpoch=state.menuEpoch
            table.rowHeight=max(24,ceil(font.ascender-font.descender+font.leading)+5);table.reloadData()
            table.selectRowIndexes(IndexSet(currentRows.indices.filter {state.selection.contains(currentRows[$0].path)}),byExtendingSelection:false)
            NativeListSelection.install(on:table,preferences:model.preferences,primaryColumn:table.tableColumn(withIdentifier:.init(StatusListColumn.path.rawValue)),labelText:{[weak self] row in guard let self,self.currentRows.indices.contains(row) else{return nil};return self.state.text(self.currentRows[row],column:.path)},font:font,leadingInset:23)
        }
        func retire(){guard !retired else{return};retired=true;dragPress=nil;if let dragMonitor{NSEvent.removeMonitor(dragMonitor);self.dragMonitor=nil};stateChanges=nil;childChanges=nil;if let closeObserver {NotificationCenter.default.removeObserver(closeObserver)};closeObserver=nil;if let table {NativeListSelection.remove(from:table);table.retire();table.delegate=nil;table.dataSource=nil}}
        // The aggregate monitor owns the complete multi-item session. AppKit's
        // row-at-a-time route must not race it and omit the aggregate text item.
        func tableView(_ tableView:NSTableView,canDragRowsWith rowIndexes:IndexSet,at point:NSPoint)->Bool {false}
        func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int)->NSPasteboardWriting? {
            guard !retired,table === tableView,currentRows.indices.contains(row) else{return nil}
            return state.dragWriter(currentRows[row],epoch:renderedEpoch)
        }
        func numberOfRows(in tableView:NSTableView)->Int {currentRows.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard currentRows.indices.contains(row),let raw=tableColumn?.identifier.rawValue,let column=StatusListColumn(rawValue:raw) else{return nil}
            let file=currentRows[row],cell=NSTableCellView(),label=NSTextField(labelWithString:state.text(file,column:column))
            label.font=font;label.maximumNumberOfLines=1;label.usesSingleLineMode=true;label.cell?.wraps=false;label.cell?.isScrollable=true;label.lineBreakMode = .byTruncatingMiddle;label.textColor=NSColor(file.statusTextColor(selected:state.selection.contains(file.path),preferences:model.preferences));label.alignment=[.added,.removed].contains(column) ? .right:.left
            label.toolTip=column == .path ? file.path+(file.oldPath.map {"\nRenamed from "+$0} ?? ""):label.stringValue
            cell.addSubview(label);cell.textField=label;label.translatesAutoresizingMaskIntoConstraints=false
            var leading:CGFloat=4
            if column == .path {
                let image=NSImageView();image.image=file.isSubmodule ? NSWorkspace.shared.icon(for:UTType.folder):NSWorkspace.shared.icon(forFileType:(file.path as NSString).pathExtension)
                cell.addSubview(image);image.translatesAutoresizingMaskIntoConstraints=false;NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:3),image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),image.widthAnchor.constraint(equalToConstant:16),image.heightAnchor.constraint(equalToConstant:16)]);leading=23
            }
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:leading),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updating,!retired,let table,state.available else{return}
            let selected=GitPathSet(table.selectedRowIndexes.compactMap {currentRows.indices.contains($0) ? currentRows[$0].path:nil})
            if selected != state.selection {state.selection=selected}
            table.reloadData()
        }
        func tableView(_ tableView:NSTableView,sortDescriptorsDidChange oldDescriptors:[NSSortDescriptor]) {
            guard !updating,let sort=tableView.sortDescriptors.first,let key=sort.key,let column=StatusListColumn(rawValue:key) else{return}
            state.sort(by:column,ascending:sort.ascending);refresh()
        }
        func tableViewColumnDidMove(_ notification:Notification){saveLayout()}
        func tableViewColumnDidResize(_ notification:Notification){saveLayout()}
        private func saveLayout(){guard !updating,!retired,let table else{return};state.saveLayout(order:table.tableColumns.compactMap {StatusListColumn(rawValue:$0.identifier.rawValue)},widths:Dictionary(uniqueKeysWithValues:table.tableColumns.compactMap {column in StatusListColumn(rawValue:column.identifier.rawValue).map {($0,Double(column.width))}}))}
        func activate(unified:Bool=false,alternate:Bool=false) {guard let receipt=state.capture(state.selection) else{return};state.compare(receipt,unified:unified,alternate:alternate)}
        @objc func doubleClick(_ sender:NSTableView) {guard let table,sender===table else{return};let row=table.clickedRowQuery(table);guard currentRows.indices.contains(row),let receipt=state.capture([currentRows[row].path]) else{return};state.compare(receipt,unified:false,alternate:ComparisonToolInvocation.capture)}
        func copySelection(extended:Bool) {guard let receipt=state.capture(state.selection) else{return};state.copy(receipt,information:extended ? .pathsAndStatus:.relativePaths)}
        func rowMenu(row:Int,column:Int)->NSMenu {
            let menu=NSMenu();menu.autoenablesItems=false
            guard currentRows.indices.contains(row),let table else{return menu}
            let paths=state.selection.contains(currentRows[row].path) ? state.selection:GitPathSet([currentRows[row].path])
            let receipt=state.capture(paths)
            func add(_ title:String,_ id:String,_ icon:MenuIcon,_ operation:@escaping(SynchronizationFileListState.Receipt)->Void,in target:NSMenu) {
                target.addItem(SynchronizationFileMenuItem(title,id:id,icon:icon,preferences:model.preferences,enabled:receipt != nil){if let receipt {operation(receipt)}})
            }
            add("Compare two revisions","compare",.compare,{[weak state] in state?.compare($0,unified:false,alternate:ComparisonToolInvocation.capture)},in:menu)
            add("Show unified diff","unified",.compare,{[weak state] in state?.compare($0,unified:true,alternate:ComparisonToolInvocation.capture)},in:menu)
            menu.addItem(.separator());let copy=NSMenuItem(title:NSLocalizedString("Copy to clipboard",comment:""),action:nil,keyEquivalent:""),sub=NSMenu();copy.submenu=sub;copy.image=MenuIcon.copy.contextImage(defaults:model.preferences);sub.autoenablesItems=false;menu.addItem(copy)
            for (title,id,information) in [("Full paths","fullPaths",StatusListCopy.fullPaths),("Relative paths","relativePaths",.relativePaths),("File names","names",.names),("Copy all information to clipboard","all",.all)] {add(title,"copy."+id,.copy,{[weak state] in state?.copy($0,information:information)},in:sub)}
            if table.tableColumns.indices.contains(column),let field=StatusListColumn(rawValue:table.tableColumns[column].identifier.rawValue) {add("Copy "+NSLocalizedString(field.rawValue,comment:""),"copy.column",.copy,{[weak state] in state?.copy($0,information:.column(field))},in:sub)}
            return menu
        }
        func headerMenu()->NSMenu {
            let menu=NSMenu();menu.autoenablesItems=false
            let captured=state.menuEpoch
            for column in SynchronizationFileListState.availableColumns {
                let visible=state.columns.visible.contains(column)
                let item=SynchronizationFileMenuItem(column.rawValue,id:"column."+column.rawValue,preferences:model.preferences,enabled:state.available && column != .path){[weak state] in guard let state,state.menuEpoch==captured else{return};state.setColumn(column,visible:!visible)}
                item.state=visible ? .on:.off;menu.addItem(item)
            }
            menu.addItem(.separator());menu.addItem(SynchronizationFileMenuItem("Reset column order",id:"columns.reset",preferences:model.preferences,enabled:state.available){[weak state] in guard let state,state.menuEpoch==captured else{return};state.resetColumns()});return menu
        }
    }
}
