// Native replacement for RepositoryBrowser.cpp's list, ColumnManager and drag menu.
// GPL-2.0-or-later; Copyright (C) 2009-2026 TortoiseGit; 2003-2013 TortoiseSVN.
import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

struct RepositoryBrowserContentsTable: NSViewRepresentable {
    @ObservedObject var model:RepositoryBrowserWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model:model) }
    func makeNSView(context:Context) -> NSScrollView { context.coordinator.makeView() }
    func updateNSView(_ view:NSScrollView,context:Context) { context.coordinator.model=model;context.coordinator.update() }
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator) {
        coordinator.retired = true
        if let table=coordinator.table {NativeListSelection.remove(from:table)}
        coordinator.table?.delegate = nil;coordinator.table?.dataSource = nil;coordinator.table?.menu?.delegate = nil
        (coordinator.table as? RepositoryBrowserNativeTable)?.contentsAttached={_ in}
        (coordinator.table?.headerView as? RepositoryBrowserColumnHeader)?.buildMenu = {nil}
        (coordinator.table?.headerView as? RepositoryBrowserColumnHeader)?.fit = {_,_ in}
    }
    @MainActor final class Coordinator:NSObject,NSTableViewDelegate,NSTableViewDataSource,NSMenuDelegate {
        static let definitions:[(String,String,CGFloat)]=[("name","Name",310),("extension","Extension",100),("size","Size",100)]
        var model:RepositoryBrowserWindowModel
        weak var table:NSTableView?
        var retired=false
        private var columnMenuSession = UUID()
        private var updating=false
        private var rows:[RepositoryBrowserEntry]=[]
        private var layout:RepositoryBrowserColumns?
        init(model:RepositoryBrowserWindowModel) { self.model=model }
        var available:Bool { !retired && model.canEditColumns && table?.window?.attachedSheet == nil }
        func makeView() -> NSScrollView {
            let table=RepositoryBrowserNativeTable();table.style = .plain
            table.contentsAttached={ [weak model] table in model?.contentsTableAttached(table) }
            table.delegate=self;table.dataSource=self;table.target=self;table.doubleAction=#selector(open)
            table.rowHeight=24;table.intercellSpacing=NSSize(width:4,height:0);table.allowsMultipleSelection=true
            table.columnAutoresizingStyle = .noColumnAutoresizing;table.allowsColumnResizing=true;table.allowsColumnReordering=true
            table.setAccessibilityLabel("Repository contents")
            for (id,title,width) in Self.definitions {
                let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title=title;column.width=width;column.minWidth=24;column.maxWidth=10000
                column.sortDescriptorPrototype=NSSortDescriptor(key:id,ascending:true)
                if id=="size" { column.headerCell.alignment = .right }
                table.addTableColumn(column)
            }
            let header=RepositoryBrowserColumnHeader(frame:NSRect(x:0,y:0,width:510,height:24))
            header.buildMenu={ [weak self] in self?.columnMenu() };header.fit={ [weak self] index,headers in self?.fit(index,headers:headers) };table.headerView=header
            let menu=NSMenu();menu.autoenablesItems=false;menu.delegate=self;table.menu=menu
            table.setDraggingSourceOperationMask(.copy,forLocal:false);table.setDraggingSourceOperationMask(.copy,forLocal:true)
            self.table=table
            let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true
            update();return scroll
        }
        func update() {
            guard !retired,let table else { return };updating=true;defer { updating=false }
            if rows != model.entries { rows=model.entries;table.reloadData() }
            if layout != model.columns {
                let next=model.columns
                for (index,id) in next.order.enumerated() {
                    if let current=table.tableColumns.firstIndex(where: { $0.identifier.rawValue==id }),current != index { table.moveColumn(current,toColumn:index) }
                }
                for column in table.tableColumns {
                    let id=column.identifier.rawValue;column.isHidden = !next.visible.contains(id)
                    column.width=CGFloat(next.widths[id] ?? Double(Self.definitions.first { $0.0==id }!.2))
                }
                layout=next
            }
            let ids=IndexSet(rows.enumerated().compactMap { model.selection.contains($0.element.id) ? $0.offset : nil })
            if table.selectedRowIndexes != ids { table.selectRowIndexes(ids,byExtendingSelection:false) }
            let sort=model.sortOrder.first
            let key=sort?.keyPath == \RepositoryBrowserEntry.fileExtension ? "extension" : sort?.keyPath == \RepositoryBrowserEntry.sizeSort ? "size" : "name"
            let descriptor=NSSortDescriptor(key:key,ascending:sort?.order != .reverse)
            if table.sortDescriptors != [descriptor] { table.sortDescriptors=[descriptor] }
            NativeListSelection.install(on:table,preferences:model.preferences,primaryColumn:table.tableColumns.first{$0.identifier.rawValue=="name"},labelText:{[weak self] row in
                guard let self,self.rows.indices.contains(row) else{return nil};return self.rows[row].name
            },font:.systemFont(ofSize:12),leadingInset:25)
            table.isEnabled=available;table.allowsColumnResizing=available;table.allowsColumnReordering=available
            if table.window != nil{model.contentsTableAttached(table)}
        }
        func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
        func value(_ id:String,_ entry:RepositoryBrowserEntry) -> String {
            switch id { case "name":return entry.name;case "extension":return entry.fileExtension;case "size":return model.sizeText(entry);default:return "" }
        }
        func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
            guard rows.indices.contains(row),let column else { return nil }
            let entry=rows[row],id=column.identifier.rawValue,label=NSTextField(labelWithString:value(column.identifier.rawValue,rows[row]))
            label.font = .systemFont(ofSize:12);label.lineBreakMode = .byTruncatingTail;label.maximumNumberOfLines=1;label.toolTip=entry.path+"\n"+entry.objectID
            if id=="size" { label.alignment = .right };guard id=="name" else { return label }
            let cell=NSTableCellView();cell.textField=label;let icon=NSImageView()
            icon.image=[.directory,.submodule].contains(entry.kind) ? NSWorkspace.shared.icon(for:.folder) : NSWorkspace.shared.icon(for:UTType(filenameExtension:(entry.name as NSString).pathExtension) ?? .data)
            cell.imageView=icon;cell.addSubview(icon);cell.addSubview(label);icon.translatesAutoresizingMaskIntoConstraints=false;label.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:3),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:16),icon.heightAnchor.constraint(equalToConstant:16),label.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:6),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-3),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            let overlay:MenuIcon?=entry.kind == .executable ? .executableOverlay : entry.kind == .symlink ? .symlinkOverlay : entry.kind == .submodule ? .externalOverlay : nil
            if let image=overlay?.image() { let badge=NSImageView(image:image);badge.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(badge);NSLayoutConstraint.activate([badge.leadingAnchor.constraint(equalTo:icon.leadingAnchor),badge.topAnchor.constraint(equalTo:icon.topAnchor),badge.widthAnchor.constraint(equalToConstant:16),badge.heightAnchor.constraint(equalToConstant:16)]) }
            return cell
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !updating,available,let table else { return };model.selection=Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        }
        func tableView(_ tableView:NSTableView,sortDescriptorsDidChange oldDescriptors:[NSSortDescriptor]) {
            guard !updating,available,let descriptor=tableView.sortDescriptors.first else { return }
            let order:SortOrder=descriptor.ascending ? .forward : .reverse
            if descriptor.key=="extension" { model.sortOrder=[KeyPathComparator(\RepositoryBrowserEntry.fileExtension,order:order)] }
            else if descriptor.key=="size" { model.sortOrder=[KeyPathComparator(\RepositoryBrowserEntry.sizeSort,order:order)] }
            else { model.sortOrder=[KeyPathComparator(\RepositoryBrowserEntry.name,order:order)] }
        }
        func tableViewColumnDidMove(_ notification:Notification) { saveLayout() }
        func tableViewColumnDidResize(_ notification:Notification) { saveLayout() }
        func saveLayout() {
            guard !updating,available,let table else { return }
            model.saveColumns(RepositoryBrowserColumns(visible:Set(table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }),order:table.tableColumns.map { $0.identifier.rawValue },widths:Dictionary(uniqueKeysWithValues:table.tableColumns.map { ($0.identifier.rawValue,Double($0.width)) })))
        }
        func fitted(_ column:NSTableColumn,headers:Bool) -> CGFloat {
            let font=NSFont.systemFont(ofSize:12),id=column.identifier.rawValue
            let content=rows.map { (value(id,$0) as NSString).size(withAttributes:[.font:font]).width+(id=="name" ? 32 : 14) }.max() ?? 24
            let title=headers ? (column.title as NSString).size(withAttributes:[.font:font]).width+20 : 0
            return min(10000,max(24,content,title))
        }
        func tableView(_ tableView:NSTableView,sizeToFitWidthOfColumn column:Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 24 };return fitted(tableView.tableColumns[column],headers:NSEvent.modifierFlags.contains(.shift))
        }
        func fit(_ index:Int,headers:Bool) {
            guard available,let table,table.tableColumns.indices.contains(index) else { return };updating=true
            table.tableColumns[index].width=fitted(table.tableColumns[index],headers:headers);updating=false;saveLayout()
        }
        func columnMenu() -> NSMenu {
            let menu = NSMenu();menu.autoenablesItems = false
            columnMenuSession = UUID()
            let session = columnMenuSession,revision = model.columnsRevision,generation = model.generation
            func add(_ title:String,state:NSControl.StateValue = .off,action:@escaping (Coordinator)->Void) {
                let command = RepositoryBrowserColumnCommand { [weak self] in
                    guard let self,self.available,self.columnMenuSession == session,self.model.columnsRevision == revision,self.model.generation == generation else {return}
                    self.columnMenuSession = UUID();action(self)
                }
                let item = NSMenuItem(title:title,action:#selector(RepositoryBrowserColumnCommand.invoke(_:)),keyEquivalent:"")
                item.target = command;item.representedObject = command;item.isEnabled = available;item.state = state;menu.addItem(item)
            }
            add("Reset column order") {$0.model.requestResetColumns()};menu.addItem(.separator())
            for (id,title,_) in Self.definitions where id != "name" {
                add(title,state:model.columns.visible.contains(id) ? .on:.off) {coordinator in
                    var columns = coordinator.model.columns
                    if columns.visible.contains(id) {columns.visible.remove(id)} else {columns.visible.insert(id)}
                    coordinator.model.saveColumns(columns)
                }
            }
            return menu
        }
        var selected:[RepositoryBrowserEntry] { rows.filter { model.selection.contains($0.id) } }
        func menuNeedsUpdate(_ menu:NSMenu) {
            model.prepareComparisonMenu()
            menu.removeAllItems();let values=selected
            func item(_ title:String,_ action:Selector,_ icon:MenuIcon,enabled:Bool=true) {
                let entry=NSMenuItem(title:title,action:#selector(invokeBrowserMenu(_:)),keyEquivalent:"");entry.target=self;entry.image=icon.contextImage(defaults:model.preferences)
                if let target=model.menuTarget(values) { entry.representedObject=MenuInvocation(target:target,command:action) }
                entry.isEnabled=available && enabled && entry.representedObject != nil;menu.addItem(entry)
            }
            if values.count==1,let entry=values.first,model.snapshot?.objectID != nil {
                item("Open",#selector(open),.open)
                if entry.kind != .directory { item("Open With…",#selector(openWith),.open);item("View revision with alternative editor",#selector(alternativeEditor),.editor) }
                menu.addItem(.separator())
                if entry.kind != .directory && model.snapshot?.bare==false { item("Compare with working tree",#selector(compare),.compare);menu.addItem(.separator()) }
                item("Show log",#selector(log),.log)
                if entry.kind == .submodule { item("Show submodule log",#selector(submoduleLog),.log) }
                if ![.directory,.submodule].contains(entry.kind) {
                    if model.snapshot?.bare==false { item("Blame",#selector(blame),.blame) }
                    menu.addItem(.separator());item("Save revision to…",#selector(save),.saveAs)
                };menu.addItem(.separator())
            }
            if !values.isEmpty && model.snapshot?.bare==false && values.allSatisfy({ ![.directory,.submodule].contains($0.kind) }) { item("Revert to this revision",#selector(revert),.revert);menu.addItem(.separator()) }
            if values.count==1,let entry=values.first,![.directory,.submodule].contains(entry.kind) {
                item("Mark for comparison",#selector(mark),.compare)
                if let mark=model.comparisonMark { item("Compare with "+mark.label(for:entry.path),#selector(compareMarked),.compare,enabled:model.onPreparedFileCompare != nil) };menu.addItem(.separator())
            }
            if !values.isEmpty { item("Copy to clipboard",#selector(copyNames),.copy);item("Copy hash",#selector(copyHashes),.copy) }
        }
        private final class MenuInvocation: NSObject {
            let target: RepositoryBrowserWindowModel.MenuTarget
            let command: Selector
            var used=false
            init(target: RepositoryBrowserWindowModel.MenuTarget, command: Selector) { self.target=target; self.command=command }
        }
        @objc func invokeBrowserMenu(_ sender: NSMenuItem) {
            guard available, let invocation=sender.representedObject as? MenuInvocation,!invocation.used, model.acceptsMenu(invocation.target) else { return }
            invocation.used=true
            let entries=invocation.target.entries
            if invocation.command == #selector(compareMarked),!model.acceptsComparisonMark(invocation.target){return}
            if invocation.command == #selector(revert) { model.revert(entries); return }
            if invocation.command == #selector(copyNames) { model.copy(entries:entries); return }
            if invocation.command == #selector(copyHashes) { model.copy(hashes:true,entries:entries); return }
            guard entries.count == 1, let entry=entries.first else { return }
            switch invocation.command {
            case #selector(open): model.open(entry)
            case #selector(openWith): model.open(entry,action:.openWith)
            case #selector(alternativeEditor): model.open(entry,action:.alternativeEditor)
            case #selector(save): model.open(entry,action:.save)
            case #selector(compare): model.compareEntryToWorkingTree(entry)
            case #selector(log): model.showEntryLog(entry)
            case #selector(blame): model.showEntryBlame(entry)
            case #selector(submoduleLog): model.showSubmoduleLog(entry)
            case #selector(mark): model.markForComparison(entry)
            case #selector(compareMarked): model.compareWithMarkedFile(entry,capturedMark:invocation.target.comparisonMark)
            default: break
            }
        }
        private func one(_ operation:(RepositoryBrowserEntry)->Void) { guard available,selected.count==1,let entry=selected.first else { return };operation(entry) }
        @objc func open() { one { model.open($0) } }
        @objc func openWith() { one { model.open($0,action:.openWith) } }
        @objc func alternativeEditor() { one { model.open($0,action:.alternativeEditor) } }
        @objc func save() { one { model.open($0,action:.save) } }
        @objc func compare() { one { model.compareEntryToWorkingTree($0) } }
        @objc func log() { one { model.showEntryLog($0) } }
        @objc func blame() { one { model.showEntryBlame($0) } }
        @objc func submoduleLog() { one { model.showSubmoduleLog($0) } }
        @objc func revert() { guard available else { return };model.revert(selected) }
        @objc func mark() { one { model.markForComparison($0) } }
        @objc func compareMarked() { one { model.compareWithMarkedFile($0) } }
        @objc func copyNames() { guard available else { return };model.copy() }
        @objc func copyHashes() { guard available else { return };model.copy(hashes:true) }
        func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int) -> NSPasteboardWriting? {
            guard available,rows.indices.contains(row),let snapshot=model.snapshot,rows[row].kind != .submodule else { return nil }
            return RepositoryBrowserFilePromise(repository:model.repository,access:model.access,snapshot:snapshot,entry:rows[row],backend:model.materializationBackend()).provider()
        }
    }
}

final class RepositoryBrowserNativeTable:NSTableView {
    var contentsAttached:(NSTableView)->Void={_ in}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if window != nil{contentsAttached(self)}}
    override func menu(for event:NSEvent) -> NSMenu? {
        guard isEnabled else { return nil };let clicked=row(at:convert(event.locationInWindow,from:nil))
        if clicked>=0 && !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer:clicked),byExtendingSelection:false) }
        menu?.update();return menu
    }
}
final class RepositoryBrowserColumnHeader:NSTableHeaderView {
    var buildMenu:()->NSMenu? = { nil }
    var fit:(Int,Bool)->Void = { _,_ in }
    override func menu(for event:NSEvent) -> NSMenu? { buildMenu() }
    override func mouseDown(with event:NSEvent) {
        if event.clickCount==2,let table=tableView {
            let point=convert(event.locationInWindow,from:nil)
            for (index,column) in table.tableColumns.enumerated() where !column.isHidden {
                if abs(point.x-headerRect(ofColumn:index).maxX)<=4 { fit(index,event.modifierFlags.contains(.shift));return }
            }
        };super.mouseDown(with:event)
    }
}

@MainActor private final class RepositoryBrowserColumnCommand:NSObject {
    private var action:(()->Void)?
    init(_ action:@escaping ()->Void) {self.action = action}
    @objc func invoke(_ sender:Any?) {let run = action;action = nil;run?()}
}
