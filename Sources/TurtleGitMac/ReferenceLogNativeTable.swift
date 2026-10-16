import AppKit
import SwiftUI
import TurtleGitCore

/// Native CRefLogList report control. Reflog order is semantic; header sorting
/// is intentionally absent so selector positions and deletion order stay intact.
struct ReferenceLogNativeTable: NSViewRepresentable {
    @ObservedObject var model: ReferenceLogWindowModel
    let dates: HistoryDateSettings
    @AppStorage("LogFontForLogCtrl") private var useLogFont = false
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    private var configuredFont: NSFont? { useLogFont ? MessageEditorFont.resolve(name: fontName, size: fontSize) : nil }
    func makeCoordinator() -> Coordinator { Coordinator(model: model, dates: dates) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = ReferenceLogTableView()
        table.owner = context.coordinator
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.allowsColumnReordering = true; table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 22
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.activate(_:))
        table.setAccessibilityLabel("Reference log entries")
        let names = ["Hash", "Ref", "Action", "Message", "Date"], widths: [CGFloat] = [120,145,100,360,175]
        for (name, width) in zip(names, widths) {
            let column = NSTableColumn(identifier: .init(name)); column.title = name
            column.width = width; column.minWidth = 40; column.maxWidth = 10000
            table.addTableColumn(column)
        }
        let header = ReferenceLogTableHeader(frame: NSRect(x: 0, y: 0, width: 0, height: 24)); header.owner = context.coordinator; table.headerView = header
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        context.coordinator.table = table; context.coordinator.restoreColumns(); context.coordinator.update(model: model, dates: dates, font: configuredFont)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(model: model, dates: dates, font: configuredFont) }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.retire(); coordinator.table?.owner = nil; coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: ReferenceLogWindowModel
        var dates: HistoryDateSettings
        weak var table: ReferenceLogTableView?
        var retired = false, synchronizing = false
        private var popupEpoch=UUID(),layoutRevision=0
        func retire() {retired=true;popupEpoch=UUID()}
        private var font: NSFont?
        private var entries: [ReferenceLogEntry] = []
        init(model: ReferenceLogWindowModel, dates: HistoryDateSettings) { self.model = model; self.dates = dates }
        var available: Bool { !retired && model.commandSurfaceAvailable && !model.unifiedViewerBusy && table?.window != nil && table?.window?.attachedSheet == nil }
        var selectedIDs: Set<String> { Set(table?.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil } ?? []) }
        func update(model: ReferenceLogWindowModel, dates: HistoryDateSettings, font: NSFont? = nil) {
            guard !retired, let table else { return }
            let reload = entries != model.entries || self.dates != dates || self.font != font
            self.font = font
            table.rowHeight = max(22, (font?.ascender ?? 0) - (font?.descender ?? 0) + (font?.leading ?? 0) + 6)
            self.model = model; self.dates = dates; entries = model.entries
            synchronizing = true
            if reload { table.reloadData() }
            let indices = IndexSet(entries.indices.filter { model.selection.contains(entries[$0].id) })
            if indices != table.selectedRowIndexes {
                table.selectRowIndexes(indices, byExtendingSelection: false)
                if let row = indices.first { table.scrollRowToVisible(row) }
            }
            table.isEnabled = model.commandSurfaceAvailable
            synchronizing = false
        }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard entries.indices.contains(row), let column = tableColumn else { return nil }
            let entry = entries[row], field = column.identifier.rawValue
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView) ?? {
                let cell = NSTableCellView(); cell.identifier = column.identifier
                let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingTail; cell.addSubview(text); cell.textField = text
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                return cell
            }()
            let value: String
            switch field { case "Hash": value = entry.hash; case "Ref": value = entry.selector; case "Action": value = entry.action; case "Message": value = entry.message; default: value = ReferenceLogWindowModel.dateText(entry, dates: dates) }
            cell.textField?.stringValue = value; cell.textField?.textColor = .labelColor
            cell.textField?.font = font ?? (field == "Hash" ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13))
            cell.toolTip = field == "Message" ? entry.subject : value
            model.requestDiffParents(entry)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) { if !synchronizing, !retired { model.selection = selectedIDs } }
        @objc func activate(_ sender: Any?) { guard available else { return }; model.activateRows(selectedIDs) }
        func accept() { guard available else { return }; model.accept() }
        func copy(to pasteboard: NSPasteboard = .general) { guard available else { return }; model.copy(selectedIDs, pasteboard: pasteboard) }
        func selectAll() { guard available, let table else { return }; table.selectAll(nil) }
        func tableViewColumnDidResize(_ notification: Notification) { saveColumns() }
        func tableViewColumnDidMove(_ notification: Notification) { saveColumns() }
        func saveColumns() {
            guard available, !synchronizing, let table else { return }
            layoutRevision &+= 1
            model.preferences.set(table.tableColumns.map { $0.identifier.rawValue }, forKey: "RefLog.Columns.Order")
            model.preferences.set(Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, Double($0.width)) }), forKey: "RefLog.Columns.Widths")
            model.preferences.set(table.tableColumns.filter(\.isHidden).map { $0.identifier.rawValue }, forKey: "RefLog.Columns.Hidden")
        }
        func restoreColumns() {
            guard let table else { return }; synchronizing = true
            let order = model.preferences.stringArray(forKey: "RefLog.Columns.Order") ?? []
            var used = Set<String>(), destination = 0
            for id in order where used.insert(id).inserted {
                if let source = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) { table.moveColumn(source, toColumn: destination); destination += 1 }
            }
            let widths = model.preferences.dictionary(forKey: "RefLog.Columns.Widths") ?? [:], hidden = Set(model.preferences.stringArray(forKey: "RefLog.Columns.Hidden") ?? [])
            for column in table.tableColumns {
                if let width = widths[column.identifier.rawValue] as? NSNumber, width.doubleValue.isFinite, (40...10000).contains(width.doubleValue) { column.width = CGFloat(width.doubleValue) }
                column.isHidden = column.identifier.rawValue != "Hash" && hidden.contains(column.identifier.rawValue)
            }
            if table.tableColumns.allSatisfy(\.isHidden) { table.tableColumns.first?.isHidden = false }
            synchronizing = false
        }
        func headerMenu() -> NSMenu {
            popupEpoch=UUID();let epoch=popupEpoch,revision=layoutRevision,generation=model.generation
            let menu=NSMenu();menu.autoenablesItems=false
            guard let table else {return menu}
            var consumed=false
            let live:() -> Bool = { [weak self] in
                guard let self else {return false}
                return !consumed && self.available && self.popupEpoch==epoch && self.layoutRevision==revision && self.model.generation==generation
            }
            func add(_ title:String,state:NSControl.StateValue = .off,action:@escaping () -> Void) {
                let target=ReferenceLogTableCommand(allowed:live) {consumed=true;action()}
                let item=NSMenuItem(title:title,action:#selector(ReferenceLogTableCommand.invokeCommand(_:)),keyEquivalent:"")
                item.target=target;item.representedObject=target;item.state=state;item.isEnabled=live();menu.addItem(item)
            }
            add("Reset column order") { [weak self] in
                guard let self else {return}
                self.model.requestColumnReset { [weak self] in
                    guard let self,!self.retired,self.layoutRevision==revision,let table=self.table,table.window != nil else {return}
                    let origin=table.enclosingScrollView?.contentView.bounds.origin,selection=table.selectedRowIndexes
                    self.synchronizing=true
                    for (index,name) in ["Hash","Ref","Action","Message","Date"].enumerated() {
                        if let source=table.tableColumns.firstIndex(where:{$0.identifier.rawValue==name}) {table.moveColumn(source,toColumn:index)}
                    }
                    for (column,width) in zip(table.tableColumns,[CGFloat(120),145,100,360,175]) {column.isHidden=false;column.width=width}
                    table.selectRowIndexes(selection,byExtendingSelection:false);table.layoutSubtreeIfNeeded()
                    if let origin,let scroll=table.enclosingScrollView {scroll.contentView.scroll(to:scroll.contentView.constrainBoundsRect(NSRect(origin:origin,size:scroll.contentView.bounds.size)).origin);scroll.reflectScrolledClipView(scroll.contentView)}
                    self.synchronizing=false;self.saveColumns()
                }
            }
            menu.addItem(.separator())
            // ColumnManager excludes logical column zero (Hash) from hiding.
            for name in ["Ref","Action","Message","Date"] {
                guard let column=table.tableColumn(withIdentifier:.init(name)) else {continue}
                add(column.title,state:column.isHidden ? .off:.on) { [weak self,weak column] in
                    guard let self,let column else {return};column.isHidden.toggle();self.saveColumns()
                }
            }
            return menu
        }
        func menu(pasteboard: NSPasteboard = .general, extended: Bool = false) -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            popupEpoch=UUID();let epoch=popupEpoch,generation=model.generation;var consumed=false
            let ids = selectedIDs, reference = model.reference, snapshot = entries.filter { ids.contains($0.id) }
            let live: () -> Bool = { [weak self] in
                guard let self,!consumed,self.popupEpoch==epoch,self.model.generation==generation,self.available,self.model.reference == reference else { return false }
                return self.model.entries.filter { ids.contains($0.id) } == snapshot
            }
            func add(_ title: String, _ icon: MenuIcon, to parent: NSMenu? = nil, enabled: Bool = true, action: @escaping () -> Void) {
                let target = ReferenceLogTableCommand(allowed: {live() && enabled}) {consumed=true;action()}
                let item = NSMenuItem(title: title, action: #selector(ReferenceLogTableCommand.invokeCommand(_:)), keyEquivalent: "")
                item.target = target; item.representedObject = target; item.image = icon.contextImage(defaults: model.preferences)
                item.isEnabled = live() && enabled; (parent ?? menu).addItem(item)
            }
            func submenu(_ title: String, _ icon: MenuIcon) -> NSMenu {
                let child = NSMenu(title: title); child.autoenablesItems = false
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = child; item.image = icon.contextImage(defaults: model.preferences); item.isEnabled = live(); menu.addItem(item); return child
            }
            let model = self.model
            if ids.count == 1 {
                add(ReferenceLogComparisonCommand.workingTree.title, .compare, enabled: model.canCompare(.workingTree, ids: ids)) { model.compare(.workingTree, ids: ids) }
                if let entry = snapshot.first, let parents = model.diffParents[entry.hash] {
                    if model.hasWorkingTree, parents.count > 1 {
                        let child = submenu("Unified diff with", .unifiedDiff)
                        for (title, mode) in [("All Parents", ReferenceLogDiffMode.allParents), ("Only Merged Files", .onlyMergedFiles), ("Show extra changes after merge", .extraChanges)] {
                            add(title, .unifiedDiff, to: child, enabled: model.canInspect(ids, mode: mode)) { model.inspect(ids, mode: mode, alternate: extended) }
                        }
                        for parent in parents { add(parent.title, .unifiedDiff, to: child, enabled: model.canInspect(ids, mode: .parent(parent.number))) { model.inspect(ids, mode: .parent(parent.number), alternate: extended) } }
                    } else if model.hasWorkingTree, parents.count == 1 {
                        add("Show changes as unified diff", .unifiedDiff, enabled: model.canInspect(ids)) { model.inspect(ids, alternate: extended) }
                    }
                    if parents.count > 1 {
                        let child = submenu("Compare with previous revision", .compare)
                        for parent in parents { add(parent.title, .compare, to: child, enabled: model.canCompareParent(ids, number: parent.number)) { model.compareParent(ids, number: parent.number) } }
                    } else if parents.count == 1 { add("Compare with previous revision", .compare, enabled: model.canCompareParent(ids)) { model.compareParent(ids) } }
                }
                menu.addItem(.separator())
            }
            for command in [LogBisectCommand.good, .bad, .skip] where ids.count == 1 && model.bisectAvailable(command, ids: ids) {
                add(command.title, command.icon) { model.bisect(command, ids: ids) }
            }
            add("Show log", .log, enabled: ids.count == 1 && model.onLog != nil) { model.showLog(ids) }
            add(ReferenceLogRevisionCommand.browseRepository.title, .repositoryBrowser, enabled: model.canPerform(.browseRepository, ids: ids)) { model.perform(.browseRepository, ids: ids) }
            func operation(_ command: ReferenceLogRevisionOperation) {
                if model.operationAvailable(command, ids: ids) {
                    add(command.title(branch: model.currentBranch, count: ids.count), command.icon) { model.performOperation(command, ids: ids) }
                }
            }
            if ids.count == 1 { operation(.merge) }
            if !model.selecting, model.hasWorkingTree, ids.count == 1 {
                add(ReferenceLogHistoryCommand.reset.title(branch: model.currentBranch), .reset, enabled: model.canPerformHistory(.reset, ids: ids)) { model.performHistory(.reset, ids: ids) }
                let branches = model.switchBranches(ids)
                if branches.count == 1, let ref = branches.first { add("Switch branch \"" + ref.dropFirst(11) + "\"", .checkout, enabled: model.onSwitchBranch != nil) { model.switchBranch(ref, ids: ids) } }
                else if branches.count > 1 {
                    let child = submenu("Switch branch", .checkout)
                    for ref in branches { add(String(ref.dropFirst(11)), .checkout, to: child, enabled: model.onSwitchBranch != nil) { model.switchBranch(ref, ids: ids) } }
                }
                add(ReferenceLogHistoryCommand.checkout.title(branch: model.currentBranch), .checkout, enabled: model.canPerformHistory(.checkout, ids: ids)) { model.performHistory(.checkout, ids: ids) }
            }
            for command in [ReferenceLogRevisionCommand.createBranch, .createTag] { add(command.title, command.icon, enabled: model.canPerform(command, ids: ids)) { model.perform(command, ids: ids) } }
            if ids.count == 1 { operation(.rebase) }
            add(ReferenceLogRevisionCommand.export.title, .export, enabled: model.canPerform(.export, ids: ids)) { model.perform(.export, ids: ids) }
            if !model.selecting {
                if ids.count == 1, let entry = snapshot.first, let parents = model.diffParents[entry.hash], parents.count > 1 {
                    if parents.contains(where: { model.operationAvailable(.revert, ids: ids, mainline: $0.number) }) {
                        let child = submenu(ReferenceLogRevisionOperation.revert.title(branch: model.currentBranch, count: 1), .revert)
                        for parent in parents { add(parent.title, .revert, to: child, enabled: model.operationAvailable(.revert, ids: ids, mainline: parent.number)) { model.performOperation(.revert, ids: ids, mainline: parent.number) } }
                    }
                } else if ids.count == 1, model.operationAvailable(.revert, ids: ids) {
                    add(ReferenceLogRevisionOperation.revert.title(branch: model.currentBranch, count: ids.count), .revert) { model.performOperation(.revert, ids: ids) }
                }
                if ids.count == 1 { operation(.editNotes) }
            }
            menu.addItem(.separator())
            if !model.selecting { add("Delete", .deleted, enabled: !ids.isEmpty) { model.delete(ids) } }
            if !model.selecting, model.reference == "refs/stash" { add("Stash apply", .stashPop, enabled: ids.count == 1) { model.apply(ids) } }
            menu.addItem(.separator())
            if ids.count >= 2 {
                add(ReferenceLogComparisonCommand.revisions.title, .compare, enabled: model.canCompare(.revisions, ids: ids)) { model.compare(.revisions, ids: ids) }
                if model.combineAvailable(ids) { add("Combine to one commit", .combine) { model.combine(ids) } }
                if ids.count == 2 {
                    if model.hasWorkingTree { add("Show changes as unified diff", .unifiedDiff, enabled: model.canInspect(ids)) { model.inspect(ids, alternate: extended) } }
                    for command in ReferenceLogRangeCommand.allCases {
                        if let range = model.logRange(command, ids: ids) { add("Show log of " + range.from.prefix(7) + range.separator + range.to.prefix(7), .log, enabled: model.onLogRange != nil) { model.showLogRange(command, ids: ids) } }
                    }
                }
                menu.addItem(.separator())
            }
            if !model.selecting, !ids.isEmpty {
                for operation in [ReferenceLogRevisionOperation.cherryPick, .formatPatch] {
                    if model.operationAvailable(operation, ids: ids) {
                        add(operation.title(branch: model.currentBranch, count: ids.count), operation.icon) { model.performOperation(operation, ids: ids) }
                    }
                }
                if ids.count > 1 { operation(.revert) }
                menu.addItem(.separator())
            }
            if model.bisectAvailable(.start, ids: ids) { add(LogBisectCommand.start.title, .bisect) { model.bisect(.start, ids: ids) }; menu.addItem(.separator()) }
            if ids.count == 1 {
                var hasTransport = false
                for (command, title, icon) in [(ReferenceLogTransportCommand.push, "Push…", MenuIcon.push), (.svnDCommit, "SVN DCommit…", .commit), (.pull, "Pull…", .pull)] {
                    if model.transportAvailable(command, ids: ids, extended: extended) {
                        add(title, icon) { model.transport(command, ids: ids, extended: extended) }; hasTransport = true
                    }
                }
                if hasTransport { menu.addItem(.separator()) }
            }
            let deletable = model.referenceDeletionCandidates(ids)
            if deletable.count == 1 {
                add("Delete " + deletable[0], .remove) { model.deleteNamedReferences(deletable, ids: ids) }
                menu.addItem(.separator())
            } else if deletable.count > 1 {
                let child = submenu("Delete branch/tag", .remove)
                for name in deletable { add(name, .remove, to: child) { model.deleteNamedReferences([name], ids: ids) } }
                add("All", .remove, to: child) { model.deleteNamedReferences(deletable, ids: ids) }
                menu.addItem(.separator())
            }
            let clipboard = submenu("Copy to clipboard", .copy)
            menu.items.last?.isEnabled = live() && !ids.isEmpty
            for (title, format) in [("Full data", ReferenceLogCopyFormat.full), ("SHA-1", .hashes), ("Messages", .messages)] { add(title, .copy, to: clipboard, enabled: !ids.isEmpty) { model.copy(ids, format: format, pasteboard: pasteboard) } }
            return menu
        }
    }
}
@MainActor final class ReferenceLogTableView: NSTableView, NSMenuItemValidation {
    weak var owner: ReferenceLogNativeTable.Coordinator?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard owner?.available == true else { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return owner?.menu(pasteboard:pasteboard,extended: event.modifierFlags.contains(.shift))
    }
    var presentContextMenu:((NSMenu,NSPoint,NSView)->Void)?
    var pasteboard:NSPasteboard = .general
    func showSelectedContextMenu(extended:Bool = false)->Bool {
        guard owner?.available==true,let window,window.isVisible,selectedRow>=0,selectedRow<numberOfRows else {return false}
        scrollRowToVisible(selectedRow);layoutSubtreeIfNeeded()
        let rect=rect(ofRow:selectedRow),point=NSPoint(x:visibleRect.minX + min(40,visibleRect.width / 2),y:rect.midY)
        guard let menu=owner?.menu(pasteboard:pasteboard,extended:extended),!menu.items.isEmpty else {return false}
        if let presentContextMenu {presentContextMenu(menu,point,self)} else {menu.popUp(positioning:nil,at:point,in:self)}
        return true
    }
    override func accessibilityPerformShowMenu()->Bool {showSelectedContextMenu()}
    func handleTableKey(_ event:NSEvent)->Bool {
        guard let window,event.window === window,(window as? ReferenceLogNativeWindow)?.commandKeyWindow() === window,
              window.firstResponder === self,owner?.available==true else {return false}
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==109,flags == .shift {return showSelectedContextMenu()}
        if event.keyCode==0,flags == .command || flags == .control {owner?.selectAll();return true}
        if event.keyCode==8,flags == .command || flags == .control {owner?.copy(to:pasteboard);return true}
        if flags.isEmpty,event.keyCode==36 || event.keyCode==76 {owner?.accept();return true}
        return false
    }
    @objc func copy(_ sender: Any?) {owner?.copy(to:pasteboard)}
    override func selectAll(_ sender: Any?) {guard owner?.available == true else {return};super.selectAll(sender)}
    override func performKeyEquivalent(with event:NSEvent)->Bool {handleTableKey(event) || super.performKeyEquivalent(with:event)}
    override func keyDown(with event:NSEvent) {if !handleTableKey(event) {super.keyDown(with:event)}}
    func validateMenuItem(_ item: NSMenuItem) -> Bool { owner?.available == true && (item.action != NSSelectorFromString("copy:") || !selectedRowIndexes.isEmpty) }
}
@MainActor private final class ReferenceLogTableHeader: NSTableHeaderView {
    weak var owner: ReferenceLogNativeTable.Coordinator?
    override func menu(for event: NSEvent) -> NSMenu? { owner?.headerMenu() }
}
@MainActor private final class ReferenceLogTableCommand: NSObject {
    private let allowed: () -> Bool, action: () -> Void
    init(allowed: @escaping () -> Bool, action: @escaping () -> Void) { self.allowed = allowed; self.action = action }
    @objc func invokeCommand(_ sender: Any?) { if allowed() { action() } }
}
