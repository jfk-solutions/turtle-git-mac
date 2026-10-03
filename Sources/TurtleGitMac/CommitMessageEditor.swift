import AppKit
import SwiftUI
import TurtleGitCore

struct CommitMessageEditor: NSViewRepresentable {
    @ObservedObject var model: CommitWindowModel
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let editor = MessageTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        editor.isRichText = false; editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Commit message")
        editor.delegate = context.coordinator; editor.model = model
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? MessageTextView else { return }
        editor.isEditable = enabled; editor.model = model
        if editor.string != model.message {
            let range = editor.selectedRange()
            editor.string = model.message
            editor.setSelectedRange(NSRange(location: min(range.location, (model.message as NSString).length), length: 0))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: CommitWindowModel
        init(_ model: CommitWindowModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { model.message = editor.string }
        }
    }
}

private final class MessageTextView: NSTextView {
    weak var model: CommitWindowModel?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event), isEditable else { return super.menu(for: event) }
        menu.addItem(.separator())
        let fileList = NSMenuItem(title: "Paste file list", action: #selector(pasteFileList), keyEquivalent: "")
        fileList.target = self; fileList.image = MenuIcon.copy.image(); menu.addItem(fileList)
        if model?.messageHistory?.entries.isEmpty == false {
            for (title, action) in [("Paste last message", #selector(pasteLastMessage)), ("Recent messages…", #selector(recentMessages))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.image = (title == "Paste last message" ? MenuIcon.copy : MenuIcon.log).image(); menu.addItem(item)
            }
        }
        return menu
    }
    @objc private func pasteFileList() { if let model { insertText(model.checkedFileList, replacementRange: selectedRange()) } }
    @objc private func pasteLastMessage() {
        if let text = model?.messageHistory?.entries.first { insertText(text, replacementRange: selectedRange()) }
    }
    @objc private func recentMessages() {
        model?.showMessageHistory { [weak self] message in
            guard let self, let model = self.model else { return }
            if !self.string.hasPrefix(message) {
                if self.string == model.messageTemplate {
                    self.insertText(message, replacementRange: NSRange(location: 0, length: (self.string as NSString).length))
                } else { self.insertText(message + (self.string.isEmpty ? "" : "\n"), replacementRange: self.selectedRange()) }
            }
            self.window?.makeFirstResponder(self)
        }
    }
}

struct CommitMessageHistoryDialog: View {
    let history: CommitMessageHistory
    let finish: (String?) -> Void
    @State private var entries: [String]
    @State private var selection = Set<String>()
    init(history: CommitMessageHistory, finish: @escaping (String?) -> Void) {
        self.history = history; self.finish = finish; _entries = State(initialValue: history.entries)
    }
    var body: some View {
        VStack {
            CommitHistoryList(entries: entries, selection: $selection, accept: finish) { index in
                history.remove([entries[index]]); entries = history.entries
                selection = entries.isEmpty ? [] : [entries[min(index, entries.count - 1)]]
            }
            HStack { Spacer()
                Button("OK") { finish(entries.filter { selection.contains($0) }.joined(separator: "\n\n")) }.keyboardShortcut(.defaultAction)
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
            }
        }.padding(12).frame(minWidth: 400, minHeight: 230)
    }
}

private struct CommitHistoryList: NSViewRepresentable {
    let entries: [String]
    @Binding var selection: Set<String>
    let accept: (String?) -> Void
    let delete: (Int) -> Void
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        let table = HistoryTable(); table.headerView = nil; table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.rowHeight = 22
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message")))
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.acceptRow(_:))
        table.setAccessibilityLabel("Recent commit messages")
        scroll.documentView = table; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? HistoryTable else { return }
        let coordinator = context.coordinator
        coordinator.parent = self; coordinator.updating = true
        if coordinator.entries != entries { coordinator.entries = entries; table.reloadData() }
        let width = entries.map { ($0.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width }.max() ?? 0
        let columnWidth = max(380, width + 15)
        table.tableColumns.first?.maxWidth = CGFloat.greatestFiniteMagnitude
        table.tableColumns.first?.width = columnWidth
        // sizeToFit() fits columns to the table's initial zero-width frame and collapses
        // the message column. Keep the document width large enough for the full text.
        table.setFrameSize(NSSize(width: columnWidth, height: max(22, CGFloat(entries.count) * table.rowHeight)))
        table.selectRowIndexes(IndexSet(entries.indices.filter { selection.contains(entries[$0]) }), byExtendingSelection: false)
        table.deleteRow = delete; coordinator.updating = false
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: CommitHistoryList
        var entries: [String] = []
        var updating = false
        init(_ parent: CommitHistoryList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let text = NSTextField(labelWithString: entries[row].replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " "))
            text.font = .systemFont(ofSize: NSFont.systemFontSize); text.toolTip = entries[row]
            return text
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil })
        }
        @objc func acceptRow(_ table: NSTableView) {
            if entries.indices.contains(table.clickedRow) { parent.accept(entries[table.clickedRow]) }
        }
    }
    private final class HistoryTable: NSTableView {
        var deleteRow: (Int) -> Void = { _ in }
        override func keyDown(with event: NSEvent) {
            if (event.keyCode == 51 || event.keyCode == 117), selectedRow >= 0 { deleteRow(selectedRow) }
            else { super.keyDown(with: event) }
        }
    }
}
