// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

final class LFSLocksNativeTable: NativeWatermarkTable {
    var prepareContext: (Int, Int) -> Void = { _,_ in }
    var focusRow: (Int) -> Void = { _ in }
    override func mouseDown(with event: NSEvent) {
        let index = row(at:convert(event.locationInWindow,from:nil)); super.mouseDown(with:event)
        if index >= 0 { focusRow(index) }
    }
    var toggleChecks: () -> Void = {}
    var copyRows: (Bool) -> Void = { _ in }
    var refreshRows: () -> Void = {}
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil), index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        if !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        prepareContext(index, column(at: point)); return super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection([.command,.control,.option]).isEmpty { toggleChecks(); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.specialKey == .f5 { refreshRows(); return true }
        if event.charactersIgnoringModifiers?.lowercased() == "c", event.modifierFlags.intersection([.command,.control,.option]) == .command { copyRows(event.modifierFlags.contains(.shift)); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class LFSLocksHeader: NSTableHeaderView {
    weak var owner: LFSLocksTable.Coordinator?
    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.headerColumn = column(at: convert(event.locationInWindow, from: nil))
        return owner?.columnMenu()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            _ = owner?.fitColumn(atNativeIndex: column(at: convert(event.locationInWindow, from: nil)), useDefault: event.modifierFlags.contains(.option)); return
        }
        super.mouseDown(with: event)
    }
}

struct LFSLocksTable: NSViewRepresentable {
    @ObservedObject var model: LFSLocksWindowModel
    @ObservedObject private var colors = StatusColorUpdates.shared
    @AppStorage("ShowListBackgroundImage") private var background = true
    @AppStorage("LogFontForFileListCtrl") private var fileFont = false
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    @AppStorage("ShowListFullPathTooltip") private var tooltip = 1
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.make() }
    func updateNSView(_ view: NSScrollView, context: Context) { _ = background; _ = fileFont; _ = fontName; _ = fontSize; _ = tooltip; context.coordinator.refresh() }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelListPosition();NativeListSelection.remove(from:coordinator.table)
        coordinator.table.delegate=nil;coordinator.table.dataSource=nil;coordinator.table.menu?.delegate=nil
        coordinator.table.prepareContext={_,_ in};coordinator.table.focusRow={_ in};coordinator.table.toggleChecks={};coordinator.table.copyRows={_ in};coordinator.table.refreshRows={}
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: LFSLocksWindowModel
        let table: LFSLocksNativeTable
        private var displayedRows: [LFSListRow] = []
        private var updating = false
        private var position: (NSPoint,Int?,Int?)?
        private var mark: String?
        var focusedID: String? { get { mark } set { mark = newValue } }
        var headerColumn = -1
        var contextColumn: StatusListColumn?
        private var resetAlert: NSAlert?
        private var resetReply: ((Bool) -> Void)?
        private let widths: [StatusListColumn: Double] = [.path:420,.fileName:180,.fileExtension:75,.lastModified:170,.fileSize:100,.lfsOwner:160]
        var nativeColumns: [StatusListColumn] { LFSLocksWindowModel.columns }
        var itemIDs: [String]? { displayedRows.map(\.id) }
        var enabled: Bool { !model.retired && !model.busy && !model.confirmingQuit && !model.showingProgress }
        lazy var confirmResetColumns: (NSWindow) async -> Bool = { [weak self] window in
            guard let self, !self.model.retired, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Are you sure to reset columns?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); self.resetAlert = alert
            return await withCheckedContinuation { reply in
                self.resetReply = { reply.resume(returning: $0) }
                alert.beginSheetModal(for: window) { [weak self] response in self?.finishReset(response == .alertFirstButtonReturn) }
            }
        }
        init(model: LFSLocksWindowModel) { self.model = model; table = LFSLocksNativeTable(icon: .lockBackdrop, defaults: model.presentationPreferences) }
        func make() -> NSScrollView {
            updating = true
            table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true; table.rowHeight = 22
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.setAccessibilityLabel("LFS locked files")
            let check = NSTableColumn(identifier: .init("check")); check.title = ""; check.width = 26; check.minWidth = 26; check.maxWidth = 26; check.resizingMask = []; table.addTableColumn(check)
            for definition in nativeColumns {
                let column = NSTableColumn(identifier: .init(definition.rawValue)); column.title = FileListLabels.caption(definition.rawValue)
                column.width = widths[definition] ?? 100; column.minWidth = definition == .path ? 120 : 40
                column.sortDescriptorPrototype = NSSortDescriptor(key: definition.rawValue, ascending: true); table.addTableColumn(column)
            }
            let header = LFSLocksHeader(frame:NSRect(x:0,y:0,width:760,height:24)); header.owner = self; header.menu = columnMenu(); table.headerView = header
            table.menu = NSMenu(); table.menu?.autoenablesItems = false; table.menu?.delegate = self
            table.prepareContext = { [weak self] row, column in
                guard let self else { return }; self.mark = self.displayedRows.indices.contains(row) ? self.displayedRows[row].id : nil
                self.contextColumn = self.columnDefinition(atNativeIndex: column)
            }
            table.focusRow = { [weak self] row in guard let self, self.enabled, self.displayedRows.indices.contains(row) else {return}; self.mark = self.displayedRows[row].id }
            table.toggleChecks = { [weak self] in
                guard let self, self.enabled, let mark = self.mark.flatMap({ self.model.selection.contains($0) ? $0 : nil }) ?? self.model.selection.sorted().first else { return }
                self.model.toggleChecks(self.displayedRows.filter { self.model.selection.contains($0.id) }.map(\.id), mark: mark)
            }
            table.copyRows = { [weak self] status in guard let self else { return }; self.model.copy(self.model.selection, information: status ? .pathsAndStatus : .relativePaths) }
            table.refreshRows = { [weak model] in Task { await model?.refresh() } }
            model.captureListPosition = { [weak self] in self?.storeListPosition() }
            model.cancelListPosition = { [weak self] in self?.cancelListPosition() }
            model.restoreListPosition = { [weak self] ids, remember in self?.restoreListPosition(ids: ids, enabled: remember) }
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
            updating = false; refresh(); return scroll
        }
        func refresh() {
            guard !updating else { return }; updating = true; defer { updating = false }
            let preferences=model.presentationPreferences
            let font:NSFont=preferences.bool(forKey:"LogFontForFileListCtrl") ? MessageEditorFont.resolve(name:preferences.string(forKey:"LogFontName") ?? MessageEditorFont.defaultName,size:preferences.object(forKey:"LogFontSize") as? Int ?? MessageEditorFont.defaultSize):.systemFont(ofSize:NSFont.systemFontSize)
            NativeListSelection.install(on:table,preferences:preferences,primaryColumn:table.tableColumns.first(where:{$0.identifier.rawValue==StatusListColumn.path.rawValue}),labelText:{[weak self] row in guard let self,self.displayedRows.indices.contains(row) else{return nil};return self.displayedRows[row].text(.path)},font:font,leadingInset:22)
            let order = model.fileColumns.order.filter { nativeColumns.contains($0) }
            for (offset, definition) in order.enumerated() {
                let index = table.column(withIdentifier: .init(definition.rawValue))
                if index >= 0, index != offset + 1 { table.moveColumn(index, toColumn: offset + 1) }
            }
            for column in table.tableColumns {
                guard let definition = StatusListColumn(rawValue: column.identifier.rawValue) else { continue }
                column.isHidden = !model.fileColumns.visible.contains(definition)
                let width = CGFloat(model.fileColumns.widths[definition] ?? widths[definition] ?? 100)
                if abs(column.width - width) > 0.5 { column.width = width }
            }
            if let sort = model.sortOrder.first { table.sortDescriptors = [NSSortDescriptor(key: sort.column.rawValue, ascending: sort.order == .forward)] }
            displayedRows = model.rows; table.reloadData()
            table.selectRowIndexes(IndexSet(displayedRows.enumerated().compactMap { model.selection.contains($0.element.id) ? $0.offset : nil }), byExtendingSelection: false)
            table.needsDisplay = true
        }
        func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }
        private final class Check: NSButton { var rowID = "" }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row index: Int) -> NSView? {
            guard displayedRows.indices.contains(index) else { return nil }; let row = displayedRows[index]
            if column?.identifier.rawValue == "check" {
                let check = Check(); check.rowID = row.id; check.title = ""; check.setButtonType(.switch)
                check.state = model.checked.contains(row.id) ? .on : .off; check.isEnabled = enabled; check.target = self; check.action = #selector(checkRow(_:)); check.setAccessibilityLabel("Select " + model.pathHelp(row.path)); return check
            }
            guard let column, let definition = StatusListColumn(rawValue: column.identifier.rawValue) else { return nil }
            let text = NSTextField(labelWithString: row.text(definition)); text.lineBreakMode = .byTruncatingMiddle
            if model.presentationPreferences.bool(forKey: "LogFontForFileListCtrl") { text.font = MessageEditorFont.resolve(name: model.presentationPreferences.string(forKey:"LogFontName") ?? MessageEditorFont.defaultName, size: model.presentationPreferences.object(forKey:"LogFontSize") as? Int ?? MessageEditorFont.defaultSize) }
            guard definition == .path else { return text }
            let view = NSView(frame: NSRect(x:0,y:0,width:column.width,height:22))
            let icon = NSImageView(frame:NSRect(x:2,y:3,width:16,height:16)); icon.image = MenuIcon.lock.image(); view.addSubview(icon)
            text.frame = NSRect(x:22,y:2,width:max(0,column.width-24),height:18); text.autoresizingMask = [.width]; view.addSubview(text)
            let tooltip = RepositoryPresentationSettings(defaults:model.presentationPreferences).fileTooltip(repository:model.repository.root,path:row.path)
            let help = model.pathHelp(row.path); view.toolTip = GitReferenceName.equal(help,row.path) ? tooltip : [tooltip,help].compactMap { $0 }.joined(separator:"\n"); text.setAccessibilityHelp(help); return view
        }
        @objc private func checkRow(_ sender: Check) { model.checkClicked(sender.rowID,value:sender.state == .on); refresh() }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating else { return }; guard enabled else { refresh(); return }
            model.selection = GitPathSet(table.selectedRowIndexes.compactMap { displayedRows.indices.contains($0) ? displayedRows[$0].id : nil })
            if let row = table.selectedRowIndexes.first, displayedRows.indices.contains(row), mark == nil || !model.selection.contains(mark!) { mark = displayedRows[row].id }
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, enabled, let sort = table.sortDescriptors.first, let key = sort.key, let definition = StatusListColumn(rawValue:key) else { return }
            model.setSortOrder([LFSFileSort(column:definition,order:sort.ascending ? .forward : .reverse)]); refresh()
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { enabled }
        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool { enabled && columnIndex > 0 && newColumnIndex > 0 }
        func tableViewColumnDidMove(_ notification: Notification) { rememberNativeColumnLayout() }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
            rememberNativeColumnLayout(adjustedColumn:StatusListColumn(rawValue:column.identifier.rawValue))
        }
        func columnDefinition(atNativeIndex index: Int) -> StatusListColumn? { table.tableColumns.indices.contains(index) ? StatusListColumn(rawValue:table.tableColumns[index].identifier.rawValue) : nil }
        func rememberNativeColumnLayout(adjustedColumn: StatusListColumn? = nil) {
            guard !updating, enabled else { return }
            var saved = model.fileColumns.widths
            if let adjustedColumn, let column = table.tableColumns.first(where:{$0.identifier.rawValue == adjustedColumn.rawValue}) { saved[adjustedColumn] = column.width }
            _ = model.saveColumnLayout(order:table.tableColumns.compactMap{StatusListColumn(rawValue:$0.identifier.rawValue)},widths:saved)
        }
        @discardableResult func fitColumn(atNativeIndex index: Int, useDefault: Bool) -> Bool {
            guard enabled, let definition = columnDefinition(atNativeIndex:index) else { return false }
            var saved = model.fileColumns.widths
            if useDefault { saved.removeValue(forKey:definition) }
            else {
                let font = NSFont.systemFont(ofSize:NSFont.systemFontSize)
                let width = ([FileListLabels.caption(definition.rawValue)] + displayedRows.map{$0.text(definition)}).map { ($0 as NSString).size(withAttributes:[.font:font]).width }.max() ?? 100
                saved[definition] = min(1500,max(40,width + (definition == .path ? 30 : 16)))
            }
            _ = model.saveColumnLayout(order:model.fileColumns.order,widths:saved); refresh(); return true
        }
        private final class Item: NSMenuItem {
            private let invoke: () -> Void
            init(_ title: String, icon: NSImage? = nil, invoke: @escaping () -> Void) {
                self.invoke = invoke; super.init(title:NSLocalizedString(title,comment:""),action:#selector(run),keyEquivalent:""); target = self; image = icon
            }
            required init(coder:NSCoder) { fatalError("init(coder:) is not supported") }
            @objc private func run() { invoke() }
        }
        func columnMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            let reset = Item("Reset columns") { [weak self] in self?.resetColumns() }; reset.isEnabled = enabled; menu.addItem(reset); menu.addItem(.separator())
            if let definition = columnDefinition(atNativeIndex:headerColumn) {
                let index = headerColumn
                for (title, original) in [("Size column to fit",false),("Restore default width",true)] {
                    let item = Item(title) { [weak self] in guard self?.columnDefinition(atNativeIndex:index) == definition else { return }; _ = self?.fitColumn(atNativeIndex:index,useDefault:original) }; item.isEnabled = enabled; menu.addItem(item)
                }
                menu.addItem(.separator())
            }
            for definition in nativeColumns {
                let item = Item(FileListLabels.caption(definition.rawValue)) { [weak model] in guard let model else { return }; model.setColumn(definition,visible:!model.fileColumns.visible.contains(definition)) }
                item.state = model.fileColumns.visible.contains(definition) ? .on : .off; item.isEnabled = enabled && definition != .path; menu.addItem(item)
            }
            return menu
        }
        private func resetColumns() {
            guard enabled, let window = table.window else { return }
            model.requestResetColumns(choose:{ [weak self,weak window] in guard let self,let window else {return false};return await self.confirmResetColumns(window) },onAccepted:{ [weak self] in self?.refresh() })
        }
        private func finishReset(_ accepted:Bool) {
            let reply = resetReply; resetReply = nil
            if let alert = resetAlert { resetAlert = nil; alert.window.sheetParent?.endSheet(alert.window,returnCode:.abort); alert.window.orderOut(nil) }
            reply?(accepted)
        }
        func storeListPosition() { position = (table.enclosingScrollView?.contentView.bounds.origin ?? .zero,table.selectedRowIndexes.first,mark.flatMap { id in displayedRows.firstIndex { GitReferenceName.equal($0.id,id) } }) }
        func cancelListPosition() { position = nil; finishReset(false) }
        func restoreListPosition(ids:[String],enabled remember:Bool) {
            refresh(); let saved = position; position = nil
            let row = remember ? saved?.1 : nil
            model.selection = row.flatMap { ids.indices.contains($0) ? GitPathSet([ids[$0]]) : nil } ?? []
            mark = remember ? saved?.2.flatMap { ids.indices.contains($0) ? ids[$0] : nil } : nil
            refresh()
            if let scroll = table.enclosingScrollView {
                scroll.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
                let origin = remember ? saved?.0 ?? .zero : .zero
                scroll.contentView.scroll(to:scroll.contentView.constrainBoundsRect(NSRect(origin:origin,size:scroll.contentView.bounds.size)).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        func menuNeedsUpdate(_ menu:NSMenu) {
            menu.removeAllItems()
            guard enabled, let target = model.menuTarget(model.selection) else { return }
            for action in target.actions {
                menu.addItem(Item(action.rawValue,icon:(action == .lock ? MenuIcon.lock : .unlock).contextImage(defaults:model.presentationPreferences)) { [weak model] in Task { await model?.setSelectionLocked(target,locked:action == .lock) } })
            }
            if !target.actions.isEmpty { menu.addItem(.separator()) }
            let copy = NSMenuItem(title:NSLocalizedString("Copy to Clipboard",comment:""),action:nil,keyEquivalent:""); copy.image = MenuIcon.copy.contextImage(defaults:model.presentationPreferences)
            let child = NSMenu(); child.autoenablesItems = false
            let choices: [(String,StatusListCopy)] = [("Full paths",.fullPaths),("Relative paths",.relativePaths),("File/folder names",.names),("Copy all information to clipboard",.all)] + (contextColumn.map{[("column '\(FileListLabels.caption($0.rawValue))'",.column($0))]} ?? [])
            for (title,information) in choices { child.addItem(Item(title,icon:MenuIcon.copy.contextImage(defaults:model.presentationPreferences)) { [weak model] in model?.copy(target,information:information) }) }
            copy.submenu = child; menu.addItem(copy)
        }
    }
}
