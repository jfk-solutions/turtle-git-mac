// SPDX-License-Identifier: GPL-2.0-or-later
// Adapts GitRefCompareList and GitTagCompareList, pinned TortoiseGit.
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

enum SynchronizationResultPresentation {
    // CGit::GetShortHASHLength, Git.cpp:3011, is a constant in the pinned source.
    static func shortHash(_ value:String)->String {String(value.prefix(8))}
    static func singleLine(_ value:String)->String {
        var result=value.replacingOccurrences(of:"\r\n",with:"↵")
        for separator in ["\r","\n","\u{0085}","\u{2028}","\u{2029}","\u{000B}","\u{000C}"] {result=result.replacingOccurrences(of:separator,with:"↵")}
        return result.replacingOccurrences(of:"\t",with:"⇥")
    }
    static func compare(_ lhs:String,_ rhs:String,logical:Bool)->ComparisonResult {
        if logical {return lhs.compare(rhs,options:[.numeric,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))}
        let a=Array(lhs.utf16),b=Array(rhs.utf16)
        return a==b ? .orderedSame:a.lexicographicallyPrecedes(b) ? .orderedAscending:.orderedDescending
    }
}

enum SynchronizationResultKind {case references,tags
    var tab:Int {self == .references ? 3:7}
    var titles:[String] {self == .references ? ["Reference","Type","Change","Old hash","Old message","New hash","New message"]:["Tag","Status","Local hash","Local message","Remote hash","Remote message"]}
    var hashColumns:Set<Int> {self == .references ? [3,5]:[2,4]}
    var logicalColumns:Set<Int> {self == .references ? [0,4,6]:[0,3,5]}
}

@MainActor final class SynchronizationResultTable:NSTableView {
    var makeMenu:()->NSMenu? = {nil}
    var contextMenuAvailable:()->Bool = {false}
    var keyOwnerQuery:(NSWindow)->Bool = {$0.isKeyWindow}
    var presentContextMenu:(NSMenu,NSPoint,NSView)->Void = {menu,point,view in menu.popUp(positioning:nil,at:point,in:view)}
    private(set) var retired=false
    override func menu(for event:NSEvent)->NSMenu? {
        guard !retired else{return nil}
        let row=row(at:convert(event.locationInWindow,from:nil))
        if row>=0 {selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
        return makeMenu()
    }
    @discardableResult func showKeyboardContextMenu()->Bool {
        guard !retired,let window,window.firstResponder === self,keyOwnerQuery(window),window.attachedSheet==nil,contextMenuAvailable(),selectedRow>=0,selectedRow<numberOfRows,let menu=makeMenu(),!menu.items.isEmpty else{return false}
        let row=rect(ofRow:selectedRow),point=NSPoint(x:max(visibleRect.minX+4,min(row.minX+20,visibleRect.maxX-4)),y:max(visibleRect.minY,min(row.maxY,visibleRect.maxY)))
        presentContextMenu(menu,point,self);return true
    }
    override func accessibilityPerformShowMenu()->Bool {showKeyboardContextMenu()}
    override func keyDown(with event:NSEvent) {
        if event.keyCode==109,event.modifierFlags.intersection([.command,.control,.option,.shift]) == .shift,showKeyboardContextMenu(){return}
        super.keyDown(with:event)
    }
    func retire(){retired=true;makeMenu={nil};contextMenuAvailable={false};presentContextMenu={_,_,_ in};target=nil;action=nil;doubleAction=nil;menu=nil}
}
private final class SynchronizationResultHeader:NSTableHeaderView {
    var makeMenu:()->NSMenu = {NSMenu()}
    override func menu(for event:NSEvent)->NSMenu? {makeMenu()}
}
private final class SynchronizationResultEmptyLabel:NSTextField {override func hitTest(_ point:NSPoint)->NSView? {nil}}
private final class SynchronizationResultMenuItem:NSMenuItem {
    private var invokeAction:(()->Void)?,consumed=false
    init(title:String,id:String,icon:MenuIcon?=nil,preferences:UserDefaults,enabled:Bool,action:@escaping()->Void) {
        super.init(title:title,action:nil,keyEquivalent:"");identifier = .init("Sync.Results."+id)
        isEnabled=enabled;invokeAction=action;target=self;self.action=#selector(invoke)
        if let icon {image=icon.contextImage(defaults:preferences)}
    }
    required init(coder:NSCoder){fatalError("init(coder:) is not supported")}
    @objc private func invoke(){guard !consumed,isEnabled else{return};consumed=true;let action=invokeAction;invokeAction=nil;action?()}
}

struct SynchronizationReferenceTable:View {
    @ObservedObject var model:SynchronizationWindowModel
    var body:some View {SynchronizationReferenceResults(model:model,kind:.references)}
}
struct SynchronizationTagTable:View {
    @ObservedObject var model:SynchronizationWindowModel
    var body:some View {SynchronizationReferenceResults(model:model,kind:.tags)}
}
struct SynchronizationReferenceResults:NSViewRepresentable {
    @ObservedObject var model:SynchronizationWindowModel
    let kind:SynchronizationResultKind
    func makeCoordinator()->Coordinator {Coordinator(model,kind:kind)}
    func makeNSView(context:Context)->NSScrollView {context.coordinator.make()}
    func updateNSView(_ scroll:NSScrollView,context:Context){context.coordinator.reload()}
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator){coordinator.retire()}
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        let model:SynchronizationWindowModel,kind:SynchronizationResultKind
        weak var table:SynchronizationResultTable?
        private(set) var referenceRows:[SynchronizationReferenceChange]=[],tagRows:[SynchronizationTagRow]=[]
        private var epoch=UUID(),retired=false,reloading=false,initialWidths=true
        private var observation:AnyCancellable?,closeObserver:NSObjectProtocol?
        private weak var emptyLabel:NSTextField?
        init(_ model:SynchronizationWindowModel,kind:SynchronizationResultKind){self.model=model;self.kind=kind;super.init()}
        private var available:Bool {
            guard !retired,model.tab==kind.tab,!model.closed,!model.busy,!model.confirmingQuit,!model.confirmingCancellation,!model.hasBlockingChild,NSApp.modalWindow==nil,let window=model.window,table?.window === window,window.attachedSheet==nil else{return false}
            if kind == .references {return true}
            guard model.comparingTags else{return false}
            return model.tagSnapshot.map {GitReferenceName(model.remote)==GitReferenceName($0.remote)} ?? true
        }
        func make()->NSScrollView {
            let table=SynchronizationResultTable();self.table=table
            table.identifier = .init(kind == .references ? "TurtleGit.Sync.ReferenceResults":"TurtleGit.Sync.TagResults")
            table.setAccessibilityLabel(kind == .references ? "Ref List":"Compare tags")
            table.rowHeight=24;table.allowsMultipleSelection=false;table.allowsColumnReordering=false;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            for (index,title) in kind.titles.enumerated() {
                let column=NSTableColumn(identifier:.init(String(index)));column.title=NSLocalizedString(title,comment:"")
                column.minWidth=45;column.width=index==0 ? 130:100;column.sortDescriptorPrototype=NSSortDescriptor(key:String(index),ascending:true);table.addTableColumn(column)
            }
            if kind == .tags,model.preferences.bool(forKey:"SortTagsReversed") {table.sortDescriptors=[NSSortDescriptor(key:"0",ascending:false)]}
            table.dataSource=self;table.delegate=self
            let header=SynchronizationResultHeader();header.makeMenu={ [weak self] in self?.headerMenu() ?? NSMenu() };table.headerView=header
            table.makeMenu={ [weak self,weak table] in self?.rowMenu(table?.selectedRow ?? -1) }
            table.contextMenuAvailable={ [weak self] in self?.available==true }
            observation=model.objectWillChange.sink { [weak self] _ in self?.epoch=UUID() }
            if let window=model.window {closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in MainActor.assumeIsolated {self?.retire()}}}
            let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.documentView=table
            let empty=SynchronizationResultEmptyLabel(labelWithString:"");empty.textColor = .secondaryLabelColor;empty.alignment = .center;empty.translatesAutoresizingMaskIntoConstraints=false
            scroll.addSubview(empty);emptyLabel=empty
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo:scroll.centerXAnchor),empty.centerYAnchor.constraint(equalTo:scroll.centerYAnchor),empty.widthAnchor.constraint(lessThanOrEqualTo:scroll.widthAnchor,constant:-24)])
            reload();return scroll
        }
        func retire(){guard !retired else{return};retired=true;epoch=UUID();observation=nil;if let closeObserver {NotificationCenter.default.removeObserver(closeObserver)};closeObserver=nil;if let table {NativeListSelection.remove(from:table);(table.headerView as? SynchronizationResultHeader)?.makeMenu={NSMenu()};table.retire();table.delegate=nil;table.dataSource=nil}}
        private func rawField(_ index:Int,column:Int)->String {
            if kind == .references {
                guard referenceRows.indices.contains(index) else{return ""};let row=referenceRows[index]
                switch column {case 0:return row.shortName;case 1:return FileListLabels.caption(row.typeName);case 2:return row.change;case 3:return row.oldHash ?? "";case 4:return row.oldMessage;case 5:return row.newHash ?? "";default:return row.newMessage}
            }
            guard tagRows.indices.contains(index) else{return ""};let row=tagRows[index]
            switch column {case 0:return row.name.rawValue;case 1:return row.kind.title;case 2:return row.localHash ?? "";case 3:return row.localMessage;case 4:return row.remoteHash ?? "";default:return row.remoteMessage}
        }
        private func displayField(_ index:Int,column:Int)->String {
            let value=rawField(index,column:column)
            return SynchronizationResultPresentation.singleLine(kind.hashColumns.contains(column) ? SynchronizationResultPresentation.shortHash(value):value)
        }
        private var count:Int {kind == .references ? referenceRows.count:tagRows.count}
        func reload() {
            guard !retired,let table else{return};reloading=true;defer{reloading=false}
            let selected:GitReferenceName? = {if kind == .references {return referenceRows.indices.contains(table.selectedRow) ? referenceRows[table.selectedRow].id:nil};return tagRows.indices.contains(table.selectedRow) ? tagRows[table.selectedRow].id:nil}()
            referenceRows=kind == .references ? model.referenceRows:[];tagRows=kind == .tags ? model.tagRows:[]
            let descriptor=table.sortDescriptors.first
            if let column=Int(descriptor?.key ?? ""),kind.titles.indices.contains(column) {
                let logical = !model.preferences.bool(forKey:"NoStrCmpLogical") && kind.logicalColumns.contains(column)
                let indices=Array(0..<count).sorted {a,b in
                    let lhs=kind == .references && kind.hashColumns.contains(column) ? SynchronizationResultPresentation.shortHash(rawField(a,column:column)):rawField(a,column:column)
                    let rhs=kind == .references && kind.hashColumns.contains(column) ? SynchronizationResultPresentation.shortHash(rawField(b,column:column)):rawField(b,column:column)
                    let result=SynchronizationResultPresentation.compare(lhs,rhs,logical:logical)
                    if result == .orderedSame {return a<b}
                    return descriptor?.ascending==false ? result == .orderedDescending:result == .orderedAscending
                }
                if kind == .references {referenceRows=indices.map {referenceRows[$0]}} else {tagRows=indices.map {tagRows[$0]}}
            }
            if kind == .tags,descriptor==nil {
                let logical = !model.preferences.bool(forKey:"NoStrCmpLogical")
                tagRows=tagRows.enumerated().sorted {a,b in
                    let result=SynchronizationResultPresentation.compare(a.element.name.rawValue,b.element.name.rawValue,logical:logical)
                    return result == .orderedSame ? a.offset<b.offset:result == .orderedAscending
                }.map(\.element)
            }
            table.reloadData()
            let ids=kind == .references ? referenceRows.map(\.id):tagRows.map(\.id)
            if let selected,let row=ids.firstIndex(of:selected) {table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)} else {table.deselectAll(nil)}
            if kind == .tags || initialWidths {
                let nativeWidth=table.enclosingScrollView?.contentSize.width ?? 0
                let width=nativeWidth>0 ? nativeWidth:max(320,model.window?.contentView?.bounds.width ?? 1000)
                let font=NSFont.systemFont(ofSize:NSFont.systemFontSize)
                var used:CGFloat=0
                for (index,column) in table.tableColumns.enumerated() {
                    let measured=(column.title as NSString).size(withAttributes:[.font:font]).width
                    let fitted:CGFloat=kind == .references && index==0 ? 130:max(55,ceil(measured)+20)
                    column.width=index==table.tableColumns.count-1 ? max(fitted,width-used):fitted
                    used += column.width
                }
                initialWidths=false
            }
            emptyLabel?.isHidden=count>0;emptyLabel?.stringValue=model.busy ? NSLocalizedString("Please wait…",comment:""):model.error ?? NSLocalizedString("No differences found!",comment:"")
            NativeListSelection.install(on:table,preferences:model.preferences,primaryColumn:table.tableColumn(withIdentifier:.init("0")),labelText:{[weak self] row in self?.displayField(row,column:0)},leadingInset:kind == .references ? 23:4)
        }
        func numberOfRows(in tableView:NSTableView)->Int {count}
        func tableView(_ tableView:NSTableView,sortDescriptorsDidChange oldDescriptors:[NSSortDescriptor]) {epoch=UUID();reload()}
        func tableViewSelectionDidChange(_ notification:Notification){if !reloading {epoch=UUID()}}
        func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
            guard (0..<count).contains(row),let index=Int(column?.identifier.rawValue ?? ""),kind.titles.indices.contains(index) else{return nil}
            let text=NSTextField(labelWithString:displayField(row,column:index)),cell=NSTableCellView()
            text.font = .systemFont(ofSize:NSFont.systemFontSize);text.maximumNumberOfLines=1;text.usesSingleLineMode=true;text.cell?.wraps=false;text.cell?.isScrollable=true;text.lineBreakMode = .byTruncatingTail
            text.toolTip=kind == .references && index==0 ? referenceRows[row].name.rawValue:rawField(row,column:index)
            text.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(text);cell.textField=text;var leading:CGFloat=4
            if kind == .references,index==0,let icon=ReferenceTypeIcon(referenceName:referenceRows[row].name.rawValue)?.image() {
                let image=NSImageView(image:icon);image.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(image)
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:3),image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),image.widthAnchor.constraint(equalToConstant:16),image.heightAnchor.constraint(equalToConstant:16)]);leading=23
            }
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:leading),text.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),text.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        private struct Receipt {let epoch:UUID,generation:UUID;let snapshot:SynchronizationTagSnapshot?}
        private func receipt()->Receipt? {guard available else{return nil};return Receipt(epoch:epoch,generation:model.resultGeneration,snapshot:kind == .tags ? model.tagSnapshot:nil)}
        private func claim(_ captured:Receipt)->Bool {
            guard available,captured.epoch==epoch,captured.generation==model.resultGeneration else{return false}
            if kind == .tags {
                switch (captured.snapshot,model.tagSnapshot) {
                case (nil,nil):break // Empty/read-error header; rows require a snapshot.
                case let (original?,current?):guard GitReferenceName(original.remote)==GitReferenceName(current.remote),original.rows==current.rows else{return false}
                default:return false
                }
            }
            epoch=UUID();return true
        }
        func headerMenu()->NSMenu {
            let menu=NSMenu();menu.autoenablesItems=false;let captured=receipt()
            let hide=kind == .references ? model.hideUnchangedReferences:model.hideEqualTags
            let item=SynchronizationResultMenuItem(title:NSLocalizedString(kind == .references ? "Hide unchanged refs":"Hide unchanged",comment:""),id:"hideUnchanged",icon:.settingsDialogs,preferences:model.preferences,enabled:captured != nil){[weak self] in
                guard let self,let captured,self.claim(captured) else{return}
                if self.kind == .references {self.model.hideUnchangedReferences.toggle()} else {self.model.hideEqualTags.toggle()}
            };item.state=hide ? .on:.off;menu.addItem(item);return menu
        }
        func rowMenu(_ index:Int)->NSMenu? {
            guard (0..<count).contains(index) else{return nil}
            if kind == .references {
                let row=referenceRows[index]
                guard model.referenceRows.contains(where:{$0.name==row.name && $0.oldHash==row.oldHash && $0.newHash==row.newHash && $0.kind==row.kind && $0.count==row.count && GitReferenceName.equal($0.oldMessage,row.oldMessage) && GitReferenceName.equal($0.newMessage,row.newMessage)}) else{return nil}
            } else {guard model.tagSnapshot != nil,model.tagRows.contains(tagRows[index]) else{return nil}}
            let menu=NSMenu();menu.autoenablesItems=false;let captured=receipt()
            func add(_ title:String,_ id:String,_ icon:MenuIcon,_ action:@escaping()->Void) {
                menu.addItem(SynchronizationResultMenuItem(title:title,id:id,icon:icon,preferences:model.preferences,enabled:captured != nil){[weak self] in guard let self,let captured,self.claim(captured) else{return};action()})
            }
            func logTitle(_ hash:String)->String {NSLocalizedString("Show log of",comment:"")+" "+SynchronizationResultPresentation.shortHash(hash)}
            if kind == .references {
                let row=referenceRows[index]
                if let old=row.oldHash {add(logTitle(old),"log.old",.log){[weak self] in guard let self else{return};(self.model.onResultLog ?? self.model.onLog)(old)}}
                if let new=row.newHash,row.oldHash != new {add(logTitle(new),"log.new",.log){[weak self] in guard let self else{return};(self.model.onResultLog ?? self.model.onLog)(new)}}
                if let old=row.oldHash,let new=row.newHash,old != new {add(NSLocalizedString("Compare revisions",comment:""),"compare",.compare){[weak self] in ComparisonToolInvocation.$alternate.withValue(ComparisonToolInvocation.capture){self?.model.onReferenceCompare(old,new)}}}
                add(NSLocalizedString("Reflog",comment:""),"reflog",.log){[weak self] in self?.model.onReferenceLog(row.name.rawValue)}
            } else {
                let row=tagRows[index]
                if let local=row.localHash {add(logTitle(local),"log.local",.log){[weak self] in guard let self else{return};if let custom=self.model.onTagLog {custom(local)} else {(self.model.onResultLog ?? self.model.onLog)(local)}}}
                if row.kind != .same {
                    if let remote=row.remoteHash {add(logTitle(remote),"log.remote",.log){[weak self] in guard let self else{return};if let custom=self.model.onTagLog {custom(remote)} else {(self.model.onResultLog ?? self.model.onLog)(remote)}}}
                    if let local=row.localHash,let remote=row.remoteHash {add(NSLocalizedString("Compare with previous revision",comment:""),"compare",.compare){[weak self] in ComparisonToolInvocation.$alternate.withValue(ComparisonToolInvocation.capture){self?.model.onReferenceCompare(local,remote)}}}
                    if !menu.items.isEmpty {menu.addItem(.separator())}
                    if row.allows(.fetch) {add(NSLocalizedString("Fetch",comment:""),"fetch",.fetch){[weak self] in self?.model.performTag(.fetch,row:row)}}
                    if row.allows(.push) {add(NSLocalizedString("Push",comment:""),"push",.commit){[weak self] in self?.model.performTag(.push,row:row)}}
                }
                if !menu.items.isEmpty {menu.addItem(.separator())}
                if row.allows(.deleteLocal) {add(NSLocalizedString("Delete local tag",comment:""),"deleteLocal",.remove){[weak self] in self?.model.performTag(.deleteLocal,row:row)}}
                if row.allows(.deleteRemote) {add(NSLocalizedString("Delete tag on remote",comment:""),"deleteRemote",.remove){[weak self] in self?.model.performTag(.deleteRemote,row:row)}}
            }
            return menu
        }
    }
}
