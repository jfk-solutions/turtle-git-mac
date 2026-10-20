// SPDX-License-Identifier: GPL-2.0-or-later
// SyncIn/SyncOut CGitLogList adaptation.
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

enum SynchronizationHistoryColumns {
    // GitLogListBase::InsertGitColumn, shared by upstream SyncIn and SyncOut.
    static let definitions: [(id: String, title: String, width: Double, visible: Bool)] = [
        ("graph", "Graph", 65, true), ("hash", "SHA-1", 110, false), ("actions", "Actions", 90, true),
        ("message", "Message", 450, true), ("author", "Author", 150, true), ("date", "Date", 180, true),
        ("email", "Email", 200, false), ("committer", "Commit Name", 150, false),
        ("committerEmail", "Commit Email", 200, false), ("committerDate", "Commit Date", 180, false),
        ("bugs", "Bug-ID", 110, true), ("svn", "SVN Rev",100,true)
    ]
    static func key(incoming: Bool, id: String) -> String { "TurtleGit.Sync." + (incoming ? "In" : "Out") + ".Column.Visible." + id }
    static func visible(_ id: String, incoming: Bool, preferences: UserDefaults) -> Bool {
        if id == "graph" {return true}
        guard let definition = definitions.first(where: { $0.id == id }) else { return false }
        return (preferences.object(forKey: key(incoming: incoming, id: id)) as? NSNumber)?.boolValue ?? definition.visible
    }
}

struct SynchronizationHistoryTable: NSViewRepresentable {
    @ObservedObject var model: SynchronizationWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView();table.identifier = .init(context.coordinator.sourceTab==4 ? "Synchronization.InCommits":"Synchronization.OutCommits");table.allowsColumnReordering=true;table.allowsColumnResizing=true; table.rowHeight = context.coordinator.rowHeight; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.allowsMultipleSelection = true
        table.menu = NSMenu(); table.menu?.delegate = context.coordinator
        for definition in SynchronizationHistoryColumns.definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.id)); column.title = NSLocalizedString(definition.title,comment:""); column.width = definition.width;column.minWidth=24;column.maxWidth=CGFloat.greatestFiniteMagnitude
            column.isHidden = !SynchronizationHistoryColumns.visible(definition.id, incoming: model.tab == 4, preferences: model.preferences) || !context.coordinator.columnAvailable(definition.id)
            table.addTableColumn(column)
        }
        // Import the former AppKit-only layout once, only for its original
        // standard preferences owner. Private dialogs never read that domain.
        if model.preferences === UserDefaults.standard,model.preferences.object(forKey:context.coordinator.layoutKey)==nil {
            table.autosaveName=model.tab==4 ? "TurtleGit.SyncIn.RevisionColumns.v2":"TurtleGit.SyncOut.RevisionColumns.v2"
            table.autosaveTableColumns=true
            table.autosaveTableColumns=false
        }
        context.coordinator.restoreLayout(table)
        let header = SynchronizationReferenceHeader()
        header.makeMenu = { [weak coordinator = context.coordinator] in coordinator?.headerMenu() }
        table.headerView = header; context.coordinator.table = table; context.coordinator.entryHashes = model.historyEntries.map(\.hash)
        context.coordinator.saveLayout()
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.activateRevision)
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.activateParentComparison() ?? false }
        table.contextMenuAvailable = { [weak coordinator=context.coordinator] in coordinator?.revisionActionAvailable ?? false }
        table.onFind = { [weak coordinator = context.coordinator] in coordinator?.findHistory() ?? false }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        context.coordinator.configureSelection(table)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.sourceTab == model.tab, let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.configureSelection(table)
        table.rowHeight=context.coordinator.rowHeight
        if let column = table.tableColumns.first(where: { $0.identifier.rawValue == "graph" }) {
            // GraphCell uses three quarters of the row height per lane. Keep a
            // compact single-lane column, expanding enough to show all lanes.
            column.minWidth = max(65, CGFloat(model.historyGraph.map(\.width).max() ?? 1) * floor(table.rowHeight * 3 / 4) + 24)
            column.width = max(column.width, column.minWidth)
        }
        for column in table.tableColumns {
            let id = column.identifier.rawValue
            column.isHidden = !SynchronizationHistoryColumns.visible(id, incoming: context.coordinator.sourceTab == 4, preferences: model.preferences) || !context.coordinator.columnAvailable(id)
        }
        let previousHashes = context.coordinator.entryHashes
        let selectedHashes = Set(table.selectedRowIndexes.compactMap { previousHashes.indices.contains($0) ? previousHashes[$0] : nil })
        let hashes = model.historyEntries.map(\.hash)
        context.coordinator.entryHashes = hashes
        context.coordinator.refreshing=true
        defer {context.coordinator.refreshing=false}
        table.reloadData()
        let selection = IndexSet(hashes.enumerated().compactMap { selectedHashes.contains($0.element) ? $0.offset : nil })
        if table.selectedRowIndexes != selection { table.selectRowIndexes(selection, byExtendingSelection: false) }
        if let navigation = model.historyNavigation[model.tab], model.handledHistoryNavigation[model.tab] != navigation.id {
            model.handledHistoryNavigation[model.tab] = navigation.id
            if let row = hashes.firstIndex(of: navigation.hash) {
                if navigation.select { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                table.scrollRowToVisible(row)
            }
        }
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {coordinator.retire()}
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: SynchronizationWindowModel
        weak var table: NSTableView?
        var entryHashes: [String] = []
        let sourceTab: Int
        private var parentMenuTask: Task<Void, Never>?
        private var revertMenuTask: Task<Void, Never>?
        private var combineMenuTask: Task<Void, Never>?
        private var combineMenuCancellation: OperationCancellation?
        var refreshing=false
        private var selection=IndexSet(),observation:AnyCancellable?
        private(set) var retired=false
        private var epoch=UUID(),identity=UUID()
        private var rowMenuEpoch:UUID?
        private final class HeaderDelegate:NSObject,NSMenuDelegate {
            weak var owner:Coordinator?
            let epoch:UUID
            init(_ owner:Coordinator,epoch:UUID){self.owner=owner;self.epoch=epoch}
            func menuDidClose(_ menu:NSMenu){owner?.retireMenu(epoch)}
        }
        private var headerDelegate:HeaderDelegate?
        private func retireMenu(_ captured:UUID) {
            DispatchQueue.main.async {[weak self] in if self?.epoch==captured {self?.epoch=UUID()}}
        }
        private(set) var hasPendingQuestion=false
        private var question:NSAlert?,questionReply:((NSApplication.ModalResponse)->Void)?
        var presentQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Void = {window,alert,reply in alert.beginSheetModal(for:window,completionHandler:reply)}
        var layoutKey:String {sourceTab==4 ? "TurtleGit.SyncInloglist.Columns":"TurtleGit.SyncOutloglist.Columns"}
        var rowHeight:CGFloat {let font=logFont;return max(24,ceil(font.ascender-font.descender+font.leading)+6)}
        private var logFont:NSFont {
            guard model.preferences.bool(forKey:"LogFontForLogCtrl") else{return .systemFont(ofSize:12)}
            return MessageEditorFont.resolve(name:model.preferences.string(forKey:"LogFontName") ?? MessageEditorFont.defaultName,size:(model.preferences.object(forKey:"LogFontSize") as? NSNumber)?.intValue ?? MessageEditorFont.defaultSize)
        }
        init(_ model: SynchronizationWindowModel) {
            self.model=model;sourceTab=model.tab;super.init()
            model.historyListRetirements[identity] = {[weak self] in self?.retire()}
            observation=model.objectWillChange.sink {[weak self] _ in
                DispatchQueue.main.async {[weak self] in
                    guard let self,let question=self.question else{return}
                    if self.model.closed || self.model.confirmingQuit || self.model.busy || self.model.tab != self.sourceTab {
                        if let parent=question.window.sheetParent {parent.endSheet(question.window,returnCode:.abort);question.window.orderOut(nil)}
                        self.questionReply?(.abort)
                    }
                }
            }
        }
        func columnAvailable(_ id:String)->Bool {id=="bugs" ? model.historyIssueProperties.showsBugIDColumn:id=="svn" ? model.hasGitSVN:true}
        func restoreLayout(_ table:NSTableView) {
            let saved=model.preferences.dictionary(forKey:layoutKey) ?? [:]
            let order=saved["order"] as? [String] ?? []
            let ordered=["graph"]+order.filter {$0 != "graph"}
            for (index,id) in ordered.enumerated() where index<table.numberOfColumns {
                if let column=table.tableColumn(withIdentifier:.init(id)),let current=table.tableColumns.firstIndex(of:column) {table.moveColumn(current,toColumn:index)}
            }
            for column in table.tableColumns {
                if let width=(saved["widths"] as? [String:Double])?[column.identifier.rawValue],width.isFinite,width>=24,width<=4000 {column.width=width}
            }
        }
        func configureSelection(_ table:NSTableView) {
            NativeListSelection.install(on:table,preferences:model.preferences,primaryColumn:table.tableColumn(withIdentifier:.init("message")),font:logFont,leadingInset:3)
        }
        func saveLayout() {
            guard !retired,let table else{return}
            let order=table.tableColumns.map {$0.identifier.rawValue}
            let widths=Dictionary(uniqueKeysWithValues:table.tableColumns.map {($0.identifier.rawValue,Double($0.width))})
            model.preferences.set(["order":order,"widths":widths] as [String:Any],forKey:layoutKey)
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !refreshing,let table else{return}
            if selection != table.selectedRowIndexes {selection=table.selectedRowIndexes;epoch=UUID()}
        }
        func tableViewColumnDidResize(_ notification:Notification){saveLayout()}
        func tableViewColumnDidMove(_ notification:Notification){
            guard let table else{return}
            if let graph=table.tableColumn(withIdentifier:.init("graph")),let index=table.tableColumns.firstIndex(of:graph),index != 0 {table.moveColumn(index,toColumn:0)}
            saveLayout()
        }
        final class Receipt {
            let epoch:UUID,generation:UUID,hashes:[String],selection:IndexSet
            var used=false
            init(epoch:UUID,generation:UUID,hashes:[String],selection:IndexSet){self.epoch=epoch;self.generation=generation;self.hashes=hashes;self.selection=selection}
        }
        private final class Captured:NSObject {
            let receipt:Receipt,action:Selector,payload:Any?
            init(_ receipt:Receipt,_ action:Selector,_ payload:Any?){self.receipt=receipt;self.action=action;self.payload=payload}
        }
        func capture()->Receipt? {guard revisionActionAvailable,let table,entryHashes==model.historyEntries.map(\.hash) else{return nil};return Receipt(epoch:epoch,generation:model.resultGeneration,hashes:entryHashes,selection:table.selectedRowIndexes)}
        private func valid(_ receipt:Receipt)->Bool {revisionActionAvailable && !receipt.used && receipt.epoch==epoch && receipt.generation==model.resultGeneration && receipt.hashes==model.historyEntries.map(\.hash) && receipt.selection==table?.selectedRowIndexes}
        private func wrap(_ menu:NSMenu,receipt:Receipt) {
            for item in menu.items {
                if let submenu=item.submenu {wrap(submenu,receipt:receipt)}
                if let action=item.action,item.target === self {item.representedObject=Captured(receipt,action,item.representedObject);item.action=#selector(invokeCaptured(_:))}
            }
        }
        @objc func invokeCaptured(_ item:NSMenuItem) {
            guard let captured=item.representedObject as? Captured,valid(captured.receipt) else{return}
            captured.receipt.used=true
            item.representedObject=captured.payload
            defer {item.representedObject=captured}
            NSApp.sendAction(captured.action,to:self,from:item)
        }
        func retire() {
            guard !retired else{return};saveLayout();retired=true;epoch=UUID();observation=nil;headerDelegate=nil
            parentMenuTask?.cancel();revertMenuTask?.cancel();combineMenuTask?.cancel();combineMenuCancellation?.cancel()
            if let question,let parent=question.window.sheetParent {parent.endSheet(question.window,returnCode:.abort);question.window.orderOut(nil)}
            questionReply?(.abort)
            if let table=table as? HistoryTableView {table.onReturn=nil;table.onFind=nil;table.contextMenuAvailable={false};table.target=nil;table.doubleAction=nil;table.menu?.delegate=nil;table.menu=nil;table.delegate=nil;table.dataSource=nil;(table.headerView as? SynchronizationReferenceHeader)?.makeMenu={nil};NativeListSelection.remove(from:table)}
            model.historyListRetirements.removeValue(forKey:identity)
        }
        private func ask(_ message:String,detail:String="",yesNo:Bool=false,accepted:@escaping()->Void={}) {
            guard revisionActionAvailable,let window=model.window else{return}
            let generation=model.resultGeneration
            let alert=NSAlert();alert.messageText=message;alert.informativeText=detail;alert.addButton(withTitle:yesNo ? "Yes":"OK");if yesNo {alert.addButton(withTitle:"No")};alert.window.alphaValue=window.alphaValue
            hasPendingQuestion=true;question=alert;model.beginHistoryQuestion()
            let reply:(NSApplication.ModalResponse)->Void = {[self] response in
                guard question === alert,questionReply != nil else{return};questionReply=nil
                Task { [self,alert] in
                    while alert.window.sheetParent != nil {try? await Task.sleep(nanoseconds:5_000_000)}
                    defer {self.question=nil;self.hasPendingQuestion=false;self.model.endHistoryQuestion()}
                    guard response == .alertFirstButtonReturn,!self.retired,!self.model.closed,!self.model.confirmingQuit,!self.model.busy,self.model.tab==self.sourceTab,self.model.resultGeneration==generation else{return}
                    accepted()
                }
            }
            questionReply=reply;presentQuestion(window,alert,reply)
        }
        private final class CopyTarget: NSObject {
            let entries: [LogEntry], kind: SynchronizationHistoryCopy, reference: String?
            init(entries: [LogEntry], kind: SynchronizationHistoryCopy, reference: String?) { self.entries = entries; self.kind = kind; self.reference = reference }
        }
        private final class ComparisonTarget: NSObject {
            let from: ComparisonRevision, to: ComparisonRevision
            init(from: ComparisonRevision, to: ComparisonRevision) { self.from = from; self.to = to }
        }
        private final class RevisionTarget: NSObject {
            let revision: String, isTag: Bool, sourceTab: Int?
            init(_ revision: String, isTag: Bool = false, sourceTab: Int? = nil) { self.revision = revision; self.isTag = isTag; self.sourceTab = sourceTab }
        }
        var revisionActionAvailable: Bool {
            !retired && sourceTab==model.tab && !hasPendingQuestion && NSApp.modalWindow==nil && !model.closed && !model.busy && !model.confirmingQuit && !model.confirmingCancellation && !model.hasBlockingChild && model.window?.attachedSheet == nil
        }
        func findHistory() -> Bool {
            guard sourceTab == model.tab, revisionActionAvailable, let action = model.onHistoryFind, table != nil else { return false }
            action(sourceTab, nil); return true
        }
        private final class FindTarget: NSObject {
            let tab: Int, index: Int
            init(tab: Int, index: Int) { self.tab = tab; self.index = index }
        }
        @objc func historyFind(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? FindTarget else { return }
            model.onHistoryFind?(target.tab, target.index)
        }
        @objc func historyExport(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            model.onHistoryExport?(target.revision)
        }
        private final class OperationTarget: NSObject {
            let action: SynchronizationHistoryOperation
            init(_ action: SynchronizationHistoryOperation) { self.action = action }
        }
        private final class BisectTarget: NSObject {
            let request: LogBisectRequest
            let entries: [LogEntry]
            init(_ request: LogBisectRequest, entries: [LogEntry]) { self.request = request; self.entries = entries }
        }
        private final class DeleteTarget: NSObject {
            let names: [String], revision: String
            init(_ names: [String], revision: String) { self.names = names; self.revision = revision }
        }
        @objc func historyDelete(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? DeleteTarget else { return }
            model.deleteHistoryReferences(target.names, revision: target.revision)
        }
        private final class PushTarget: NSObject {
            let revision: String, preserveAllBranches: Bool
            init(_ revision: String, preserveAllBranches: Bool) { self.revision = revision; self.preserveAllBranches = preserveAllBranches }
        }
        @objc func historyPush(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? PushTarget else { return }
            model.onHistoryPush?(target.revision, target.preserveAllBranches)
        }
        @objc func historyPull(_ sender: NSMenuItem) { guard revisionActionAvailable else { return }; model.onHistoryPull?() }
        private final class PatchTarget: NSObject {
            let preset: FormatPatchPreset
            init(_ preset: FormatPatchPreset) { self.preset = preset }
        }
        @objc func historyBisect(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? BisectTarget else { return }
            model.requestHistoryBisect(target.request, entries: target.entries)
        }
        @objc func historyFormatPatch(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? PatchTarget else { return }
            model.onHistoryFormatPatch?(target.preset)
        }
        private final class ReplayTarget: NSObject {
            let upstream: String?, commits: [String]?
            init(upstream: String? = nil, commits: [String]? = nil) { self.upstream = upstream; self.commits = commits }
        }
        @objc func historyOperation(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? OperationTarget else { return }
            model.onHistoryOperation?(target.action)
        }
        @objc func historyReplay(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? ReplayTarget else { return }
            model.replayHistory(upstream: target.upstream, commits: target.commits)
        }
        private final class RangeTarget: NSObject {
            let range: HistoryRevisionRange
            init(_ range: HistoryRevisionRange) { self.range = range }
        }
        @objc func historyRangeLog(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RangeTarget else { return }
            model.onHistoryLogRange?(target.range)
        }
        @objc func historyContainingReferences(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            if let tab = target.sourceTab { model.onHistoryContainingReferences?(target.revision, tab) }
        }
        @objc func historyLog(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            model.onHistoryLog?(target.revision)
        }
        @objc func browseHistory(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            model.onHistoryBrowseRepository?(target.revision)
        }
        @objc func createHistoryReference(_ sender: NSMenuItem) {
            guard revisionActionAvailable, let target = sender.representedObject as? RevisionTarget else { return }
            model.onHistoryCreateReference?(target.isTag, target.revision)
        }
        private final class DiffTarget: NSObject {
            let diff: SynchronizationHistoryDiff
            init(_ diff: SynchronizationHistoryDiff) { self.diff = diff }
        }
        @objc func compareChangeSets(_ sender: NSMenuItem) {
            guard revisionActionAvailable,let target = sender.representedObject as? ComparisonTarget,
                  case .revision(let first) = target.from, case .revision(let second) = target.to else { return }
            model.compareHistoryChangeSets(first: first, second: second)
        }
        @objc func historyDiff(_ sender: NSMenuItem) {
            guard revisionActionAvailable,let target = sender.representedObject as? DiffTarget else { return }
            model.showHistoryDiff(target.diff, alternate: NSEvent.modifierFlags.contains(.shift))
        }
        @objc func compareHistory(_ sender: NSMenuItem) {
            guard !model.closed, !model.busy, !model.confirmingQuit, !model.confirmingCancellation,
                  !model.hasBlockingChild, model.window?.attachedSheet == nil,
                  let target = sender.representedObject as? ComparisonTarget else { return }
            let alternate=ComparisonToolInvocation.capture
            ComparisonToolInvocation.$alternate.withValue(alternate) {model.onHistoryCompare?(target.from,target.to)}
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            parentMenuTask?.cancel(); parentMenuTask = nil; revertMenuTask?.cancel(); revertMenuTask = nil; combineMenuTask?.cancel(); combineMenuTask = nil; combineMenuCancellation?.cancel(); combineMenuCancellation = nil
            menu.removeAllItems(); menu.autoenablesItems = false
            epoch=UUID();rowMenuEpoch=epoch
            guard let receipt=capture(), let table else { return }
            defer {wrap(menu,receipt:receipt)}
            let entries = table.selectedRowIndexes.compactMap { model.historyEntries.indices.contains($0) ? model.historyEntries[$0] : nil }
            guard !entries.isEmpty else { return }
            model.historyFindIndex[sourceTab] = max(0, table.selectedRow)
            let clipboard = NSMenu(title: "Copy to clipboard"); clipboard.autoenablesItems = false
            let available = !model.closed && !model.busy && !model.confirmingQuit && !model.hasBlockingChild
            let pointed = (table as? HistoryTableView)?.contextReference
            func comparisonItem(_ title: String, from: ComparisonRevision, to: ComparisonRevision, in targetMenu: NSMenu) {
                let item = NSMenuItem(title: title, action: #selector(compareHistory(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = available && !model.confirmingCancellation && model.window?.attachedSheet == nil && model.onHistoryCompare != nil
                item.image = MenuIcon.compare.contextImage(defaults: model.preferences)
                item.representedObject = ComparisonTarget(from: from, to: to)
                targetMenu.addItem(item)
            }
            func diffItem(_ title: String, diff: SynchronizationHistoryDiff, in targetMenu: NSMenu) {
                let item = NSMenuItem(title: title, action: #selector(historyDiff(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = available && !model.confirmingCancellation && model.window?.attachedSheet == nil
                item.image = MenuIcon.compare.contextImage(defaults: model.preferences)
                item.representedObject = DiffTarget(diff); targetMenu.addItem(item)
            }
            func operationItem(_ title: String, _ action: SynchronizationHistoryOperation, _ icon: MenuIcon, in targetMenu: NSMenu) {
                let item = NSMenuItem(title: title, action: #selector(historyOperation(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryOperation != nil
                item.image = icon.contextImage(defaults: model.preferences); item.representedObject = OperationTarget(action); targetMenu.addItem(item)
            }
            func replayItem(_ title: String, _ target: ReplayTarget, _ icon: MenuIcon) {
                let item = NSMenuItem(title: title, action: #selector(historyReplay(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.runHistoryReplay != nil
                item.image = icon.contextImage(defaults: model.preferences); item.representedObject = target; menu.addItem(item)
            }
            func bisectItem(_ command: LogBisectCommand) {
                let request: LogBisectRequest
                if command == .start {
                    request = LogBisectRequest(good: entries.last!.references.first?.name ?? entries.last!.hash, bad: entries.first!.references.first?.name ?? entries.first!.hash, operation: nil, revisions: [])
                } else { request = LogBisectRequest(good: nil, bad: nil, operation: command.operation, revisions: entries.map(\.hash)) }
                let item = NSMenuItem(title: command.title, action: #selector(historyBisect(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryBisect != nil
                item.image = command.icon.contextImage(defaults: model.preferences); item.representedObject = BisectTarget(request, entries: entries); menu.addItem(item)
            }
            if entries.count == 1, let entry = entries.first {
                comparisonItem("Compare with working tree", from: .revision(entry.hash), to: .workingTree, in: menu)
                if entry.parents.count == 1, let parent = entry.parents.first {
                    diffItem("Show changes as unified diff", diff: .revisions(parent, entry.hash), in: menu)
                    comparisonItem("Compare with previous revision", from: .revision(parent), to: .revision(entry.hash), in: menu)
                } else if entry.parents.count > 1 {
                    let unified = NSMenu(); unified.autoenablesItems = false
                    for diff in [SynchronizationHistoryDiff.allParents(entry.hash), .mergedFiles(entry.hash), .extraChanges(entry.hash)] {
                        diffItem(diff.title, diff: diff, in: unified)
                    }
                    for (index, hash) in entry.parents.enumerated() {
                        diffItem(model.historyParentTitle(hash, index: index), diff: .revisions(hash, entry.hash), in: unified)
                    }
                    let unifiedItem = NSMenuItem(title: "Unified diff with", action: nil, keyEquivalent: "")
                    unifiedItem.image = MenuIcon.compare.contextImage(defaults: model.preferences); unifiedItem.submenu = unified; menu.addItem(unifiedItem)
                    let parentItem = NSMenuItem(title: "Compare with previous revision", action: nil, keyEquivalent: "")
                    parentItem.image = MenuIcon.compare.contextImage(defaults: model.preferences)
                    let parents = NSMenu(); parents.autoenablesItems = false
                    for (index, hash) in entry.parents.enumerated() {
                        comparisonItem(model.historyParentTitle(hash, index: index), from: .revision(hash), to: .revision(entry.hash), in: parents)
                    }
                    parentItem.submenu = parents; menu.addItem(parentItem)
                    let model = model
                    parentMenuTask = Task { [weak parents, weak unified] in
                        await model.loadHistoryParentSubjects(entry)
                        guard !Task.isCancelled,self.valid(receipt),let parents else{return}
                        for (index, item) in parents.items.enumerated() where entry.parents.indices.contains(index) {
                            item.title = model.historyParentTitle(entry.parents[index], index: index)
                        }
                        if let unified {
                            for (index, item) in unified.items.dropFirst(3).enumerated() where entry.parents.indices.contains(index) {
                                item.title = model.historyParentTitle(entry.parents[index], index: index)
                            }
                        }
                    }
                }
            } else if entries.count == 2 || table.selectedRowIndexes.last! - table.selectedRowIndexes.first! + 1 == entries.count {
                comparisonItem("Compare revisions", from: .revision(entries.last!.hash), to: .revision(entries.first!.hash), in: menu)
                if entries.count == 2 { diffItem("Show changes as unified diff", diff: .revisions(entries.last!.hash, entries.first!.hash), in: menu) }
            }
            if entries.count == 2 {
                let first = entries[0].hash, last = entries[1].hash
                let ranges = [HistoryRevisionRange(from: last, to: first), HistoryRevisionRange(from: first, to: last), HistoryRevisionRange(from: last, to: first, kind: .symmetricDifference)]
                for range in ranges {
                    let title = "Show log of " + range.from.prefix(8) + range.separator + range.to.prefix(8)
                    let item = NSMenuItem(title: title, action: #selector(historyRangeLog(_:)), keyEquivalent: "")
                    item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryLogRange != nil
                    item.image = MenuIcon.log.contextImage(defaults: model.preferences); item.representedObject = RangeTarget(range); menu.addItem(item)
                }
                let changes = NSMenuItem(title: "Compare change sets", action: #selector(compareChangeSets(_:)), keyEquivalent: "")
                changes.target = self; changes.isEnabled = revisionActionAvailable
                changes.image = MenuIcon.compare.contextImage(defaults: model.preferences)
                changes.representedObject = ComparisonTarget(from: .revision(entries[0].hash), to: .revision(entries[1].hash)); menu.addItem(changes)
            }
            if !model.historyBare, model.historyBisectActive, entries.count == 1,
               !entries[0].references.contains(where: { $0.name.hasPrefix("refs/bisect/") }) {
                for command in [LogBisectCommand.good, .bad, .skip] { bisectItem(command) }
                menu.addItem(.separator())
            }
            if entries.count == 1, let entry = entries.first {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let stash = entry.references.contains { $0.name == "refs/stash" }
                if !stash && !entry.references.isEmpty || (table as? HistoryTableView)?.contextExtendedMenu == true {
                    let log = NSMenuItem(title: "Show log", action: #selector(historyLog(_:)), keyEquivalent: "")
                    log.target = self; log.isEnabled = revisionActionAvailable && model.onHistoryLog != nil
                    log.image = MenuIcon.log.contextImage(defaults: model.preferences); log.representedObject = RevisionTarget(entry.hash); menu.addItem(log)
                }
                let browse = NSMenuItem(title: "Browse repository", action: #selector(browseHistory(_:)), keyEquivalent: "")
                browse.target = self; browse.isEnabled = revisionActionAvailable && model.onHistoryBrowseRepository != nil
                browse.image = MenuIcon.repositoryBrowser.contextImage(defaults: model.preferences); browse.representedObject = RevisionTarget(entry.hash); menu.addItem(browse)
                if !stash && !model.historyBare {
                    let isHead = entry.hash == model.historyHead
                    if !isHead && !model.historyMergeActive {
                        operationItem("Merge to \"" + model.historyCurrentBranch + "\"…", .merge(pointed?.name ?? entry.references.first?.name ?? entry.hash), .merge, in: menu)
                    }
                    operationItem("Reset \"" + model.historyCurrentBranch + "\" to this…", .reset(entry.hash), .reset, in: menu)
                    let branches = (pointed.map { [$0.name] } ?? entry.references.map(\.name)).filter { $0.hasPrefix("refs/heads/") && $0 != "refs/heads/" + model.historyCurrentBranch }
                    if branches.count == 1 {
                        let reference = branches[0], short = String(reference.dropFirst("refs/heads/".count))
                        operationItem("Switch/Checkout to \"" + short + "\"", .switchBranch(short), .checkout, in: menu)
                    } else if branches.count > 1 {
                        let submenu = NSMenu(); submenu.autoenablesItems = false
                        for reference in branches {
                            let short = String(reference.dropFirst("refs/heads/".count))
                            operationItem(short, .switchBranch(short), .checkout, in: submenu)
                            submenu.items.last?.image = nil
                        }
                        let item = NSMenuItem(title: "Switch/Checkout to", action: nil, keyEquivalent: "")
                        item.image = MenuIcon.checkout.contextImage(defaults: model.preferences); item.submenu = submenu; menu.addItem(item)
                    }
                    if !isHead {
                        operationItem("Switch/Checkout to this…", .checkout(pointed?.name ?? entry.references.first { $0.name.hasPrefix("refs/remotes/") }?.name ?? entry.hash), .checkout, in: menu)
                    }
                }
                if !entry.references.contains(where: { $0.name == "refs/stash" }) {
                    let remote = entry.references.first { $0.name.hasPrefix("refs/remotes/") }?.name
                    for isTag in [false, true] {
                        // Source only uses a pointed remote label for branch creation;
                        // otherwise both commands prefer the first remote for tracking.
                        let pointedRemote = !isTag ? pointed?.name : nil
                        let revision = pointedRemote.flatMap { name in entry.references.contains { $0.name == name && name.hasPrefix("refs/remotes/") } ? name : nil } ?? remote ?? entry.hash
                        let item = NSMenuItem(title: isTag ? "Create tag at this version…" : "Create branch at this version…", action: #selector(createHistoryReference(_:)), keyEquivalent: "")
                        item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryCreateReference != nil
                        item.image = (isTag ? MenuIcon.tag : .branch).contextImage(defaults: model.preferences)
                        item.representedObject = RevisionTarget(revision, isTag: isTag); menu.addItem(item)
                    }
                }
                if !stash && !model.historyBare && !model.historyMergeActive && entry.hash != model.historyHead {
                    let upstream = entry.references.first { $0.name.hasPrefix("refs/heads/") }.map { String($0.name.dropFirst("refs/heads/".count)) } ?? entry.references.first?.name ?? entry.hash
                    replayItem("Rebase \"" + model.historyCurrentBranch + "\" onto this…", ReplayTarget(upstream: upstream), .rebase)
                }
                let export = NSMenuItem(title: "Export this version…", action: #selector(historyExport(_:)), keyEquivalent: "")
                export.target = self; export.isEnabled = revisionActionAvailable && model.onHistoryExport != nil
                export.image = MenuIcon.export.contextImage(defaults: model.preferences)
                export.representedObject = RevisionTarget(entry.references.first { $0.name.hasPrefix("refs/tags/") }?.name ?? entry.hash)
                menu.addItem(export)
                if !stash && !model.historyBare && !model.historyMergeActive {
                    if entry.parents.count == 1 {
                        operationItem("Revert change by this commit", .revert([entry], nil), .revert, in: menu)
                    } else if entry.parents.count > 1 {
                        let parents = NSMenu(); parents.autoenablesItems = false
                        for (index, hash) in entry.parents.enumerated() {
                            operationItem(model.historyParentTitle(hash, index: index), .revert([entry], index + 1), .revert, in: parents)
                            parents.items.last?.image = nil
                        }
                        let item = NSMenuItem(title: "Revert change by this commit", action: nil, keyEquivalent: "")
                        item.image = MenuIcon.revert.contextImage(defaults: model.preferences); item.submenu = parents; menu.addItem(item)
                        // Parent captions share the compare/unified menu's owned metadata read.
                        revertMenuTask = Task { [weak parents] in
                            await model.loadHistoryParentSubjects(entry)
                            guard !Task.isCancelled,self.valid(receipt),let parents else{return}
                            for (index, item) in parents.items.enumerated() { item.title = model.historyParentTitle(entry.parents[index], index: index) }
                        }
                    }
                }
                if !stash { operationItem("Edit Notes", .editNotes(entry.hash), .rebaseEdit, in: menu) }
            }
            if entries.count > 1, !model.historyBare, !model.historyMergeActive {
                operationItem("Revert changes by these commits", .revert(entries, nil), .revert, in: menu)
            }
            if entries.count > 1, !model.historyBare, model.historyBisectActive,
               !entries[0].references.contains(where: { $0.name.hasPrefix("refs/bisect/") }) { bisectItem(.skip); menu.addItem(.separator()) }
            if entries.count > 1, !model.historyBare, !model.historyMergeActive,
               table.selectedRowIndexes.last! - table.selectedRowIndexes.first! + 1 == entries.count,
               let headRow = model.historyEntries.firstIndex(where: { $0.hash == model.historyHead }), table.selectedRowIndexes.first! >= headRow {
                let offset = table.selectedRowIndexes.first! - headRow, expectedHead = model.historyHead
                operationItem("Combine to one commit", .combine(entries, offset, expectedHead), .combine, in: menu)
                let item = menu.items.last!; item.isHidden = true; item.isEnabled = false
                let request = OperationCancellation(); combineMenuCancellation = request
                let repository = model.repository
                combineMenuTask = Task { [weak item, weak self] in
                    do {
                        guard let self else { return }
                        try await self.model.validateCombineSelection(entries,offset:offset,head:expectedHead,token:request)
                        guard !request.isCancelled,!Task.isCancelled,self.valid(receipt),let table=self.table,
                              table.selectedRowIndexes.compactMap({ self.model.historyEntries.indices.contains($0) ? self.model.historyEntries[$0].hash:nil }) == entries.map(\.hash) else { return }
                        item?.isHidden = false; item?.isEnabled = self.revisionActionAvailable
                    } catch { /* Source omits Combine when ancestry cannot be resolved. */ }
                }
            }
            if !model.historyBare && !model.historyMergeActive && entries.first?.hash != model.historyHead {
                replayItem(entries.count > 1 ? "Cherry Pick selected commits…" : "Cherry Pick this commit…", ReplayTarget(commits: entries.map(\.hash)), .cherryPick)
            }
            if let preset = FormatPatchPreset.logSelection(orderedHashes: model.historyEntries.map(\.hash), selected: Set(entries.map(\.hash))) {
                let item = NSMenuItem(title: "Format Patch…", action: #selector(historyFormatPatch(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryFormatPatch != nil
                item.image = MenuIcon.patch.contextImage(defaults: model.preferences); item.representedObject = PatchTarget(preset); menu.addItem(item)
            }
            if entries.count == 2, !model.historyBare, !model.historyMergeActive, !model.historyBisectActive,
               !entries[0].references.contains(where: { $0.name == "refs/stash" }) { menu.addItem(.separator()); bisectItem(.start) }
            if entries.count == 1, let entry = entries.first {
                let extended = (table as? HistoryTableView)?.contextExtendedMenu == true
                let stash = entry.references.contains { $0.name == "refs/stash" }
                let local = entry.references.contains { $0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/tags/") }
                if (!stash && local) || extended {
                    let pointedLocal = pointed?.name.hasPrefix("refs/heads/") == true || pointed?.name.hasPrefix("refs/tags/") == true ? pointed?.name : nil
                    let pointedTarget = pointed?.name.hasPrefix("refs/remotes/") == false ? pointed?.name : nil
                    let target = pointedTarget ?? entry.references.first { $0.name.hasPrefix("refs/heads/") }?.name ?? entry.references.first { $0.name.hasPrefix("refs/tags/") }?.name ?? entry.hash
                    let title = pointedLocal.map { "Push \"" + (GitReferenceName.removingPrefix("refs/heads/", from: $0) ?? GitReferenceName.removingPrefix("refs/tags/", from: $0) ?? $0) + "\"…" } ?? "Push…"
                    let item = NSMenuItem(title: title, action: #selector(historyPush(_:)), keyEquivalent: "")
                    item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryPush != nil
                    item.image = MenuIcon.push.contextImage(defaults: model.preferences); item.representedObject = PushTarget(GitReferenceName.removingSuffix("^{}", from: target) ?? target, preserveAllBranches: pointedTarget == nil); menu.addItem(item)
                }
                if entry.hash == model.historyHead, !model.historyBare, !model.historyMergeActive {
                    let item = NSMenuItem(title: "Pull…", action: #selector(historyPull(_:)), keyEquivalent: "")
                    item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryPull != nil
                    item.image = MenuIcon.pull.contextImage(defaults: model.preferences); menu.addItem(item)
                }
                let candidates = (pointed.map { [$0.name] } ?? entry.references.map(\.name)).filter { $0 != "refs/heads/" + model.historyCurrentBranch }
                func deletionItem(_ title: String, names: [String], in targetMenu: NSMenu, icon: Bool) {
                    let item = NSMenuItem(title: title, action: #selector(historyDelete(_:)), keyEquivalent: "")
                    item.target = self; item.isEnabled = revisionActionAvailable
                    if icon { item.image = MenuIcon.remove.contextImage(defaults: model.preferences) }
                    item.representedObject = DeleteTarget(names, revision: entry.hash); targetMenu.addItem(item)
                }
                if candidates.count == 1 { deletionItem("Delete " + candidates[0], names: candidates, in: menu, icon: true) }
                else if candidates.count > 1 {
                    let submenu = NSMenu(); submenu.autoenablesItems = false
                    for name in candidates { deletionItem(name, names: [name], in: submenu, icon: false) }
                    deletionItem("All", names: candidates, in: submenu, icon: false)
                    let item = NSMenuItem(title: "Delete branch/tag", action: nil, keyEquivalent: "")
                    item.image = MenuIcon.remove.contextImage(defaults: model.preferences); item.submenu = submenu; menu.addItem(item)
                }
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for kind in SynchronizationHistoryCopy.allCases {
                if kind == .referenceNames && (entries.count != 1 || entries[0].references.isEmpty) { continue }
                let item = NSMenuItem(title: kind.rawValue, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = available
                item.image = MenuIcon.copy.contextImage(defaults: model.preferences)
                item.representedObject = CopyTarget(entries: entries, kind: kind, reference: kind == .referenceNames ? pointed?.name : nil)
                clipboard.addItem(item)
            }
            let parent = NSMenuItem(title: "Copy to clipboard", action: nil, keyEquivalent: "")
            parent.image = MenuIcon.copy.contextImage(defaults: model.preferences); parent.submenu = clipboard; menu.addItem(parent)
            let find = NSMenuItem(title: "Find", action: #selector(historyFind(_:)), keyEquivalent: "")
            find.target = self; find.isEnabled = revisionActionAvailable && model.onHistoryFind != nil
            find.image = MenuIcon.historyFind.contextImage(defaults: model.preferences)
            find.representedObject = FindTarget(tab: sourceTab, index: max(0, table.selectedRow)); menu.addItem(find)
            if entries.count == 1, let entry = entries.first {
                let item = NSMenuItem(title: "Show branches this commit is on", action: #selector(historyContainingReferences(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = revisionActionAvailable && model.onHistoryContainingReferences != nil
                item.image = MenuIcon.showBranches.contextImage(defaults: model.preferences)
                item.representedObject = RevisionTarget(entry.hash, sourceTab: model.tab); menu.addItem(item)
            }
        }
        func menuDidClose(_ menu: NSMenu) { if let rowMenuEpoch {retireMenu(rowMenuEpoch)};parentMenuTask?.cancel(); parentMenuTask = nil; revertMenuTask?.cancel(); revertMenuTask = nil; combineMenuTask?.cancel(); combineMenuTask = nil; combineMenuCancellation?.cancel(); combineMenuCancellation = nil; (table as? HistoryTableView)?.contextReference = nil; (table as? HistoryTableView)?.contextExtendedMenu = false }
        @objc func copyHistory(_ sender: NSMenuItem) {
            guard revisionActionAvailable,let target = sender.representedObject as? CopyTarget else { return }
            model.copyHistory(target.entries, kind: target.kind, pointedReference: target.reference)
        }
        func headerMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            epoch=UUID();headerDelegate=HeaderDelegate(self,epoch:epoch);menu.delegate=headerDelegate
            guard let receipt=capture() else{return menu}
            defer {wrap(menu,receipt:receipt)}
            let reset = NSMenuItem(title: "Reset columns", action: #selector(resetColumns), keyEquivalent: ""); reset.target = self; menu.addItem(reset); menu.addItem(.separator())
            for definition in SynchronizationHistoryColumns.definitions where definition.id != "graph" && columnAvailable(definition.id) {
                let item = NSMenuItem(title: definition.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = definition.id
                item.state = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id))?.isHidden == false ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
        @objc func toggleColumn(_ item: NSMenuItem) {
            guard revisionActionAvailable,let id = item.representedObject as? String,id != "graph",columnAvailable(id), let column = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
            column.isHidden.toggle()
            model.preferences.set(!column.isHidden, forKey: SynchronizationHistoryColumns.key(incoming: sourceTab == 4, id: id))
        }
        @objc func resetColumns() {
            ask("Reset column order",detail:"Are you sure you want to reset the column order?",yesNo:true) {[weak self] in
                guard let self,let table=self.table else{return}
                self.epoch=UUID();self.model.preferences.removeObject(forKey:self.layoutKey)
                for (index,definition) in SynchronizationHistoryColumns.definitions.enumerated() {
                    self.model.preferences.removeObject(forKey:SynchronizationHistoryColumns.key(incoming:self.sourceTab==4,id:definition.id))
                    guard let column=table.tableColumn(withIdentifier:.init(definition.id)),let old=table.tableColumns.firstIndex(of:column) else{continue}
                    table.moveColumn(old,toColumn:index)
                    let font=NSFont.systemFont(ofSize:NSFont.systemFontSize)
                    let header=(column.title as NSString).size(withAttributes:[.font:font]).width+20
                    var width=header
                    if definition.id=="actions" {width=max(width,86)}
                    else if definition.id != "graph" {
                        for row in self.model.historyEntries.indices {
                            if let cell=self.tableView(table,viewFor:column,row:row) as? NSTableCellView,let field=cell.textField {
                                width=max(width,field.attributedStringValue.size().width+14)
                            }
                        }
                    }
                    column.width=definition.id=="graph" ? max(65,max(column.minWidth,header)):ceil(width)
                    column.isHidden = !definition.visible || !self.columnAvailable(definition.id)
                }
                self.saveLayout()
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { !retired && sourceTab==model.tab ? model.historyEntries.count:0 }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard !retired,sourceTab==model.tab,entryHashes==model.historyEntries.map(\.hash) else{return nil}
            let entries = model.historyEntries
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            if column?.identifier.rawValue == "graph" {
                let cell = GraphCell(); cell.preferences = model.preferences; cell.parentCount = entry.parents.count
                if model.historyGraph.indices.contains(row) { cell.graph = model.historyGraph[row] }; return cell
            }
            if column?.identifier.rawValue == "actions" {
                model.requestHistoryActions(entry)
                let cell = NSTableCellView()
                let slots: [(LogRevisionActions, MenuIcon, String)] = [(.modified, .actionModified, "Modified"), (.added, .actionAdded, "Added/copied"), (.deleted, .actionDeleted, "Deleted"), (.replaced, .actionReplaced, "Replaced/renamed"), (.conflicted, .actionConflicted, "Conflicted")]
                var images: [NSView] = [], labels: [String] = []
                if let actions = model.historyActions[entry.hash] {
                    for (flag, icon, title) in slots {
                        let image = NSImageView(); image.image = actions.contains(flag) ? icon.image() : nil
                        images.append(image); if actions.contains(flag) { labels.append(title) }
                    }
                    if labels.isEmpty { labels = ["No changed files"] }
                } else {
                    let failed = model.historyActionFailures.contains(entry.hash)
                    images = [NSImageView(image: (failed ? MenuIcon.actionError : .actionFetching).image() ?? NSImage())]
                    labels = [failed ? "Could not read changed files" : "Reading changed files"]
                }
                for image in images { image.translatesAutoresizingMaskIntoConstraints = false; image.widthAnchor.constraint(equalToConstant: 16).isActive = true; image.heightAnchor.constraint(equalToConstant: 16).isActive = true }
                let stack = NSStackView(views: images); stack.orientation = .horizontal; stack.spacing = 0; stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                cell.toolTip = labels.joined(separator: ", "); cell.setAccessibilityLabel(cell.toolTip); return cell
            }
            let dates = HistoryDateSettings.load(defaults: model.preferences)
            let text = NSTextField(labelWithString: ""); text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1
            if column?.identifier.rawValue == "message" {
                let painter = LogReferenceTextCell(textCell: ""); painter.isEditable = false; painter.isSelectable = false; painter.isBordered = false; painter.drawsBackground = false; text.cell = painter
            }
            text.font = .systemFont(ofSize: 12, weight: entry.isHead ? .bold : .regular)
            if model.preferences.bool(forKey: "LogFontForLogCtrl") {
                let size = (model.preferences.object(forKey: "LogFontSize") as? NSNumber)?.intValue ?? MessageEditorFont.defaultSize
                let font = MessageEditorFont.resolve(name: model.preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName, size: size)
                text.font = entry.isHead ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            }
            if model.historyHighlights[sourceTab] == entry.hash, let font = text.font {
                text.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            switch column?.identifier.rawValue {
            case "hash": text.stringValue = entry.hash
            case "author": text.stringValue = entry.author
            case "date": text.stringValue = dates.format(entry.date); text.toolTip = dates.relative ? dates.format(entry.date, absolute: true) : nil
            case "email": text.stringValue = entry.email
            case "committer": text.stringValue = entry.committer
            case "committerEmail": text.stringValue = entry.committerEmail
            case "committerDate": text.stringValue = dates.format(entry.committerDate); text.toolTip = dates.relative ? dates.format(entry.committerDate, absolute: true) : nil
            case "svn": text.stringValue=model.historySVNRevisions[entry.hash] ?? ""
            case "bugs": text.stringValue = entry.issueIDs
            default:
                let badges = NSMutableAttributedString()
                let badgeFont = model.preferences.bool(forKey: "LogFontForLogCtrl") ? text.font! : NSFont.systemFont(ofSize: 11, weight: .medium)
                let font = model.historyHighlights[sourceTab] == entry.hash ? NSFontManager.shared.convert(badgeFont, toHaveTrait: .italicFontMask) : badgeFont
                for badge in model.historyReferenceContext.labels(entry.references, symbolize: model.preferences.bool(forKey: "SymbolizeRefNames")) {
                    let color = LogPalette.native(LogColorRole.reference(badge.reference), preferences: model.preferences)
                    let foreground = NSColor(name: nil) { _ in LogPalette.foreground(background: color) }
                    let attributes: [NSAttributedString.Key: Any] = [.backgroundColor: color, .foregroundColor: foreground, .font: font]
                    let start = badges.length; badges.append(NSAttributedString(string: " ", attributes: attributes))
                    if badge.singleRemote {
                        let marker = NSMutableAttributedString(attachment: LogUpstreamMarker.attachment(foreground: foreground, font: font, isHead: entry.isHead))
                        marker.addAttributes(attributes, range: NSRange(location: 0, length: marker.length)); badges.append(marker)
                    }
                    badges.append(NSAttributedString(string: badge.text + " ", attributes: attributes))
                    badges.addAttribute(.logReference, value: LogReferenceStyle(badge, color: color), range: NSRange(location: start, length: badges.length - start))
                    let space = (" " as NSString).size(withAttributes: [.font: font]).width
                    badges.addAttribute(.kern, value: 4 - space, range: NSRange(location: start, length: 1))
                    badges.addAttribute(.kern, value: 4 - space + (badge.kind == .annotatedTag ? 8 : 0), range: NSRange(location: badges.length - 1, length: 1))
                    badges.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: 1 - space]))
                }
                let label = NSMutableAttributedString(), message = NSAttributedString(string: Self.display(entry.logLine(fullMessage: model.preferences.bool(forKey: "FullCommitMessageOnLogLine"))), attributes: [.font: text.font!])
                if model.preferences.bool(forKey: "DrawTagsBranchesOnRightSide") { label.append(message); if badges.length > 0 { label.append(NSAttributedString(string: " ", attributes: [.font: text.font!])); label.append(badges) } }
                else { label.append(badges); label.append(message) }
                text.attributedStringValue = label; text.toolTip = entry.historySubject
            }
            if text.toolTip == nil {text.toolTip=text.stringValue}
            if column?.identifier.rawValue != "message" {text.stringValue=Self.display(text.stringValue)}
            text.usesSingleLineMode=true;text.cell?.wraps=false;text.cell?.isScrollable=true
            let cell = NSTableCellView(); cell.addSubview(text); cell.textField = text; text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        private static func display(_ value:String)->String {
            var value=value.replacingOccurrences(of:"\r\n",with:"↵")
            for separator in ["\r","\n","\u{0085}","\u{2028}","\u{2029}","\u{000B}","\u{000C}"] {value=value.replacingOccurrences(of:separator,with:"↵")}
            return value.replacingOccurrences(of:"\t",with:"⇥")
        }
        func activateParentComparison() -> Bool {
            guard model.preferences.bool(forKey: "DiffByDoubleClickInLog") else { return false }
            guard revisionActionAvailable, let table,
                  let index=table.selectedRowIndexes.first,model.historyEntries.indices.contains(index) else{return true}
            let entry=model.historyEntries[index]
            guard let parent=entry.parents.first else{ask("No previous version.");return true}
            let alternate=ComparisonToolInvocation.capture
            ComparisonToolInvocation.$alternate.withValue(alternate) {model.onHistoryCompare?(.revision(parent),.revision(entry.hash))}
            return true
        }
        @objc func activateRevision(_ sender: Any?) { _ = activateParentComparison() }
    }
}

private final class SynchronizationReferenceHeader: NSTableHeaderView {
    var makeMenu: () -> NSMenu? = { nil }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
}
