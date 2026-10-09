import AppKit
import SwiftUI

/// IDD_SUBMODULE_UPDATE uses LBS_MULTIPLESEL: ordinary clicks toggle rows.
@MainActor final class SubmoduleUpdatePathTable: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var paths: [String] = []
    private(set) var focusedRow = -1
    var interactionEnabled = true
    var selectionChanged: (Set<String>) -> Void = { _ in }
    private var configuring = false
    private var contentWidth: CGFloat = 280
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        headerView = nil; allowsMultipleSelection = true; allowsEmptySelection = true
        columnAutoresizingStyle = .noColumnAutoresizing; rowHeight = 22; intercellSpacing = NSSize(width:0,height:1)
        backgroundColor = .textBackgroundColor; dataSource = self; delegate = self
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("path")); column.maxWidth = .greatestFiniteMagnitude; column.width = 280; addTableColumn(column)
        setAccessibilityLabel("Submodule paths")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(paths next: [String], selection: Set<String>) {
        configuring = true; defer { configuring = false }
        let focusedPath = paths.indices.contains(focusedRow) ? paths[focusedRow] : nil
        if paths != next { paths = next; reloadData() }
        focusedRow = focusedPath.flatMap { paths.firstIndex(of:$0) } ?? (paths.isEmpty ? -1 : 0)
        let indices = IndexSet(paths.indices.filter { selection.contains(paths[$0]) })
        if selectedRowIndexes != indices { selectRowIndexes(indices,byExtendingSelection:false) }
        let font = NSFont.systemFont(ofSize:NSFont.systemFontSize)
        contentWidth = paths.map { (display($0) as NSString).size(withAttributes:[.font:font]).width+16 }.max() ?? 280
        fitViewport(enclosingScrollView?.contentSize ?? .zero)
        needsDisplay = true
    }
    func fitViewport(_ viewport:NSSize) {
        let width = max(280,contentWidth,viewport.width)
        if tableColumns[0].width != width { tableColumns[0].width = width }
        let size = NSSize(width:width,height:max(CGFloat(paths.count)*(rowHeight+intercellSpacing.height),viewport.height))
        if frame.size != size { setFrameSize(size) }
    }
    private func display(_ path: String) -> String { path.replacingOccurrences(of:"\r",with:"␍").replacingOccurrences(of:"\n",with:"↵") }
    func numberOfRows(in tableView:NSTableView) -> Int { paths.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard paths.indices.contains(row) else { return nil }
        let cell = NSTextField(labelWithString:display(paths[row])); cell.font = .systemFont(ofSize:NSFont.systemFontSize)
        cell.lineBreakMode = .byClipping; cell.toolTip = paths[row]; return cell
    }
    func selectionShouldChange(in tableView:NSTableView) -> Bool { configuring || interactionEnabled }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !configuring,interactionEnabled else { return }
        selectionChanged(Set(selectedRowIndexes.compactMap { paths.indices.contains($0) ? paths[$0] : nil }))
    }
    override func mouseDown(with event:NSEvent) {
        guard interactionEnabled else { return }
        let row = self.row(at:convert(event.locationInWindow,from:nil))
        guard paths.indices.contains(row) else { return }
        window?.makeFirstResponder(self); focusedRow = row; toggleFocusedRow()
    }
    private func toggleFocusedRow() {
        guard paths.indices.contains(focusedRow) else { return }
        var rows = selectedRowIndexes
        if rows.contains(focusedRow) { rows.remove(focusedRow) } else { rows.insert(focusedRow) }
        selectRowIndexes(rows,byExtendingSelection:false); needsDisplay = true
    }
    override func keyDown(with event:NSEvent) {
        guard interactionEnabled else { return }
        if event.keyCode == 49 { toggleFocusedRow(); return }
        if event.keyCode == 125 || event.keyCode == 126 {
            guard !paths.isEmpty else { return }
            focusedRow = min(paths.count-1,max(0,focusedRow+(event.keyCode == 125 ? 1 : -1)))
            scrollRowToVisible(focusedRow); needsDisplay = true; return
        }
        super.keyDown(with:event)
    }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        guard window?.firstResponder === self,paths.indices.contains(focusedRow) else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(rect:rect(ofRow:focusedRow).insetBy(dx:1,dy:1)); ring.lineWidth = 1; ring.stroke()
    }
}

@MainActor final class SubmoduleUpdatePathScroll: NSScrollView {
    private var fitting = false
    override func tile() {
        super.tile()
        guard !fitting,let table = documentView as? SubmoduleUpdatePathTable else { return }
        fitting = true; defer { fitting = false }; table.fitViewport(contentSize)
    }
}

struct SubmoduleUpdatePathList: NSViewRepresentable {
    @ObservedObject var model:SubmoduleUpdateWindowModel
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context:Context) -> NSScrollView {
        let scroll = SubmoduleUpdatePathScroll(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        scroll.documentView = SubmoduleUpdatePathTable(frame:.zero); return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let table = scroll.documentView as? SubmoduleUpdatePathTable else { return }
        table.interactionEnabled = enabled
        table.selectionChanged = { [weak model] selected in model?.setSelectedPaths(selected) }
        table.configure(paths:model.paths,selection:model.selection)
    }
}
