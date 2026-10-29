import AppKit
import TurtleGitCore
import SwiftUI

/// Persist the native replay table columns while preserving occurrence selection
/// and the existing Rebase keyboard and drag dispatcher.
struct RebaseColumnLayout: NSViewRepresentable {
    let model: RebaseWindowModel
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? { CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height) }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.model = model; view.configure() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.retire() }
    @MainActor final class Probe: NSView, NSMenuDelegate {
        static let names = ["REBASE", "ID", "SHA-1", "Message", "Author", "Date", "Email", "Commit Name", "Commit Email", "Commit Date", "Bug-ID", "SVN Rev"]
        weak var model: RebaseWindowModel?
        weak var table: NSTableView?
        private var columns: [NSTableColumn] = []
        private var tokens: [NSObjectProtocol] = []
        private var adjusting = false, retired = false, trackingHeader = false
        private var monitor: Any?
        var available: Bool { !retired && model?.revisionMenuLog.isInvalidated == false && model?.busy == false && window != nil && window?.attachedSheet == nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            guard window != nil else { return }
            configure()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .leftMouseDown, self.available, let header = self.table?.headerView {
                    self.trackingHeader = header.bounds.contains(header.convert(event.locationInWindow, from: nil))
                } else if event.type == .leftMouseUp, self.trackingHeader {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }; self.persistLayout(); self.trackingHeader = false; self.configure()
                    }
                }
                return event
            }
        }
        override func layout() { super.layout(); configure() }
        func retire() { retired = true; if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; tokens.forEach(NotificationCenter.default.removeObserver); tokens = []; table = nil; columns = [] }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) }; tokens.forEach(NotificationCenter.default.removeObserver) }
        private func contains(_ candidate: NSTableView) -> Bool {
            convert(bounds, to: nil).intersects(candidate.convert(candidate.visibleRect, to: nil))
        }
        private func columnAvailable(_ index: Int) -> Bool { index != 10 && index != 11 || index == 10 && model?.showsIssueColumn == true || index == 11 && model?.hasGitSVN == true }
        private func defaultVisible(_ index: Int) -> Bool { index < 6 || index >= 10 }
        func configure() {
            guard !retired, !adjusting, !trackingHeader, let content = window?.contentView, let model else { return }
            func find(_ view: NSView) -> NSTableView? {
                if let value = view as? NSTableView, value.tableColumns.count == Self.names.count, contains(value) { return value }
                return view.subviews.compactMap(find).first
            }
            guard let native = find(content) else { return }
            if table !== native {
                tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
                table = native; columns = Self.names.compactMap { name in native.tableColumns.first { $0.identifier.rawValue == name } }
                guard columns.count == Self.names.count else { table = nil; columns = []; return }
                for name in [NSTableView.columnDidMoveNotification, NSTableView.columnDidResizeNotification] {
                    tokens.append(NotificationCenter.default.addObserver(forName: name, object: native, queue: .main) { [weak self] _ in
                        guard self?.trackingHeader == true else { return }
                        self?.persistLayout()
                    })
                }
            }
            adjusting = true; defer { adjusting = false }
            native.allowsColumnReordering = available; native.allowsColumnResizing = available
            native.columnAutoresizingStyle = .noColumnAutoresizing
            let defaults = model.columnPreferences
            let saved = defaults.stringArray(forKey: "Rebase.Columns.Order") ?? []
            var order: [Int] = [], seen = Set<Int>()
            for name in saved { if let index = Self.names.firstIndex(of: name), seen.insert(index).inserted { order.append(index) } }
            order += columns.indices.filter { !seen.contains($0) }
            let widths = defaults.dictionary(forKey: "Rebase.Columns.Widths") ?? [:]
            for (destination,index) in order.enumerated() {
                let column = columns[index]
                column.minWidth = index == 3 ? 100 : 30; column.maxWidth = 10000
                if let current = native.tableColumns.firstIndex(where: { $0 === column }), current != destination { native.moveColumn(current,toColumn:destination) }
                let key = "Rebase.Columns.Visible." + Self.names[index]
                column.isHidden = !columnAvailable(index) || !(defaults.object(forKey:key) as? Bool ?? defaultVisible(index))
                if let value = widths[Self.names[index]] as? NSNumber, value.doubleValue.isFinite, (30...10000).contains(value.doubleValue) { column.width = max(column.minWidth,min(column.maxWidth,CGFloat(value.doubleValue))) }
            }
            if native.tableColumns.allSatisfy(\.isHidden) { columns[3].isHidden = false }
            native.headerView?.menu = headerMenu()
        }
        func persistLayout() {
            guard available, !adjusting, let table, let model else { return }
            let order = table.tableColumns.compactMap { column in columns.firstIndex(where: { $0 === column }).map { Self.names[$0] } }
            model.columnPreferences.set(order,forKey:"Rebase.Columns.Order")
            model.columnPreferences.set(Dictionary(uniqueKeysWithValues: columns.enumerated().map { (Self.names[$0.offset],Double($0.element.width)) }),forKey:"Rebase.Columns.Widths")
        }
        func headerMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
            let reset = NSMenuItem(title:"Reset columns",action:#selector(requestReset(_:)),keyEquivalent:""); reset.image=MenuIcon.reset.contextImage(defaults:model?.columnPreferences ?? .standard); reset.target = self; reset.isEnabled = available; menu.addItem(reset); menu.addItem(.separator())
            for (index,name) in Self.names.enumerated() where columnAvailable(index) {
                let item = NSMenuItem(title:name,action:#selector(toggle(_:)),keyEquivalent:""); item.target = self; item.tag = index; item.image=MenuIcon.settingsDialogs.contextImage(defaults:model?.columnPreferences ?? .standard)
                item.state = columns.indices.contains(index) && !columns[index].isHidden ? .on : .off
                item.isEnabled = available && (item.state == .off || columns.filter { !$0.isHidden }.count > 1)
                menu.addItem(item)
            }
            return menu
        }
        func menuNeedsUpdate(_ menu:NSMenu) {
            let preferences=model?.columnPreferences ?? .standard
            for item in menu.items where !item.isSeparatorItem {
                item.image=(item.action == #selector(requestReset(_:)) ? MenuIcon.reset:.settingsDialogs).contextImage(defaults:preferences)
            }
        }
        @objc func toggle(_ sender: NSMenuItem) {
            guard available, columns.indices.contains(sender.tag), columnAvailable(sender.tag), let model else { return }
            let column = columns[sender.tag]
            guard column.isHidden || columns.filter({ !$0.isHidden }).count > 1 else { return }
            let key = "Rebase.Columns.Visible." + Self.names[sender.tag]
            let visible = model.columnPreferences.object(forKey:key) as? Bool ?? defaultVisible(sender.tag)
            model.columnPreferences.set(!visible,forKey:key); configure()
        }
        @objc func requestReset(_ sender: NSMenuItem) {
            guard available, let window else { return }
            let alert = NSAlert(); alert.messageText = "Are you sure to reset columns?"
            alert.addButton(withTitle:"Yes").keyEquivalent = "\r"; alert.addButton(withTitle:"No").keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for:window) { [weak self] response in if response == .alertFirstButtonReturn { self?.resetLayout() } }
        }
        func resetLayout() {
            guard available, let model else { return }
            model.columnPreferences.removeObject(forKey:"Rebase.Columns.Order"); model.columnPreferences.removeObject(forKey:"Rebase.Columns.Widths")
            for name in Self.names { model.columnPreferences.removeObject(forKey:"Rebase.Columns.Visible." + name) }
            // Restore declared widths as well as visibility/order.
            let widths: [Double] = [90,40,95,420,130,150,200,130,200,150,110,100]
            model.columnPreferences.set(Dictionary(uniqueKeysWithValues: zip(Self.names,widths)),forKey:"Rebase.Columns.Widths")
            configure(); persistLayout()
        }
    }
}
