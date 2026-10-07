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
        editor.isAutomaticLinkDetectionEnabled = false
        editor.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
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
        model.prepareMessageCompletions()
        if editor.string != model.message {
            let range = editor.selectedRange()
            editor.string = model.message
            editor.setSelectedRange(NSRange(location: min(range.location, (model.message as NSString).length), length: 0))
        }
        editor.applyIssueStyles(model.issueMessageStyles)
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: CommitWindowModel
        init(_ model: CommitWindowModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { model.message = editor.string }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let value = link as? String, let url = URL(string: value) else { return true }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

private final class MessageTextView: NSTextView {
    weak var model: CommitWindowModel?
    private let completionPopup = CommitCompletionPopup()
    private var completionRange: NSRange?
    private var processingTypedKey = false
    private var insertedTypedText = false
    override func keyDown(with event: NSEvent) {
        if completionPopup.isShown {
            if event.keyCode == 53 { completionPopup.close(); return }
            if event.keyCode == 125 || event.keyCode == 126 { completionPopup.move(event.keyCode == 125 ? 1 : -1); return }
            if event.keyCode == 36 || event.keyCode == 48 { completionPopup.choose(); return }
        }
        let modifiers = event.modifierFlags.intersection([.control, .option, .command])
        if modifiers == .control && event.keyCode == 49 { showCompletions(minimum: 1); return }
        if modifiers == .option && event.keyCode == 53 { showCompletions(minimum: 1); return }
        completionPopup.close()
        if event.keyCode == 48 && !modifiers.contains(.control) && !modifiers.contains(.command) {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        processingTypedKey = modifiers.isEmpty
        insertedTypedText = false
        super.keyDown(with: event)
        processingTypedKey = false
        if insertedTypedText { showCompletions(minimum: UserDefaults.standard.object(forKey: "AutoCompleteMinChars") as? Int ?? 3) }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        if processingTypedKey && !text.isEmpty { insertedTypedText = true }
    }
    override func complete(_ sender: Any?) { showCompletions(minimum: 1) }
    private func showCompletions(minimum: Int) {
        guard isEditable, let model else { return }
        guard UserDefaults.standard.object(forKey: "Autocompletion") as? Bool ?? true else { completionPopup.close(); return }
        let snippets = model.messageSnippets
        let catalog = model.messageCompletionCatalog
        let candidates = catalog.candidates
        guard let request = MessageCompletion.request(message: string, selection: selectedRange(), candidates: candidates, minimum: minimum, styling: model.formattingEnabled) else { completionPopup.close(); return }
        completionRange = request.range
        completionPopup.accept = { [weak self] value in
            guard let self, let prefixRange = self.completionRange, prefixRange.location <= (self.string as NSString).length, prefixRange.length <= (self.string as NSString).length - prefixRange.location else { return }
            self.breakUndoCoalescing()
            let expansion = snippets.expansion(for: value)
            let range = expansion == nil ? prefixRange : MessageCompletion.wordRange(message: self.string, selection: self.selectedRange(), styling: model.formattingEnabled) ?? prefixRange
            self.insertText(expansion ?? value, replacementRange: range)
            self.breakUndoCoalescing()
            self.window?.makeFirstResponder(self)
        }
        completionPopup.show(request.candidates, catalog: catalog, in: self)
    }
    override func resignFirstResponder() -> Bool { completionPopup.close(); return super.resignFirstResponder() }
    private var appliedStyles: [IssueMessageStyle] = []
    private var styledText = ""
    func applyIssueStyles(_ styles: [IssueMessageStyle]) {
        guard styles != appliedStyles || string != styledText, let storage = textStorage else { return }
        appliedStyles = styles; styledText = string
        let base = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let selection = selectedRanges
        let undoEnabled = undoManager?.isUndoRegistrationEnabled == true
        if undoEnabled { undoManager?.disableUndoRegistration() }
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        for key in [NSAttributedString.Key.link, .toolTip, .underlineStyle] { storage.removeAttribute(key, range: whole) }
        storage.addAttributes([.font: base, .foregroundColor: NSColor.textColor], range: whole)
        for style in styles where style.range.location >= 0 && style.range.location <= storage.length && style.range.length <= storage.length - style.range.location {
            var styledFont = base
            if [.context, .identifier, .bold].contains(style.kind) { styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .boldFontMask) }
            if [.identifier, .italic].contains(style.kind) { styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .italicFontMask) }
            let color = [.bold, .italic, .underlined].contains(style.kind) ? NSColor.textColor : NSColor.linkColor
            var attributes: [NSAttributedString.Key: Any] = [.font: styledFont, .foregroundColor: color]
            if style.kind == .underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let url = style.url { attributes[.link] = url; attributes[.toolTip] = url }
            storage.addAttributes(attributes, range: style.range)
        }
        storage.endEditing()
        if undoEnabled { undoManager?.enableUndoRegistration() }
        selectedRanges = selection
        typingAttributes = [.font: base, .foregroundColor: NSColor.textColor]
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event), isEditable else { return super.menu(for: event) }
        menu.addItem(.separator())
        for (title, action) in [("Pick commit hash…", #selector(pickHash)), ("Pick commit message…", #selector(pickMessage))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.image = MenuIcon.log.contextImage(); menu.addItem(item)
        }
        let fileList = NSMenuItem(title: "Paste file list", action: #selector(pasteFileList), keyEquivalent: "")
        fileList.target = self; fileList.image = MenuIcon.copy.contextImage(); menu.addItem(fileList)
        if model?.messageHistory?.entries.isEmpty == false {
            for (title, action) in [("Paste last message", #selector(pasteLastMessage)), ("Recent messages…", #selector(recentMessages))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.image = (title == "Paste last message" ? MenuIcon.copy : MenuIcon.log).contextImage(); menu.addItem(item)
            }
        }
        return menu
    }
    private func pick(_ message: Bool) {
        model?.pickRevision(message) { [weak self] text in
            guard let self else { return }
            self.insertText(text, replacementRange: self.selectedRange())
            self.window?.makeFirstResponder(self)
        }
    }
    @objc private func pickHash() { pick(false) }
    @objc private func pickMessage() { pick(true) }
    @objc private func pasteFileList() { if let model { insertText(model.checkedFileList, replacementRange: selectedRange()) } }
    @objc private func pasteLastMessage() {
        if let text = model?.messageHistory?.entries.first { insertText(text, replacementRange: selectedRange()) }
    }
    @objc private func recentMessages() {
        model?.showMessageHistory { [weak self] message in
            guard let self, let model = self.model else { return }
            if !self.string.utf16.starts(with: message.utf16) {
                if self.string == model.messageTemplate {
                    self.insertText(message, replacementRange: NSRange(location: 0, length: (self.string as NSString).length))
                } else { self.insertText(message + (self.string.isEmpty ? "" : "\n"), replacementRange: self.selectedRange()) }
                model.updateIssueFromHistory(message, insertedInto: self.string)
            }
            self.window?.makeFirstResponder(self)
        }
    }
}

struct CommitEditorSettings: View {
    @AppStorage("SelectFilesForCommit") private var selectFiles = true
    @AppStorage("AutoselectMissingFiles") private var noMissing = false
    @AppStorage("Commit.MaxHistoryItems") private var historyLimit = 25
    @AppStorage("AutocompleteParseTimeout") private var parseTimeout = 5
    @AppStorage("StyleCommitMessages") private var styleMessages = true
    @AppStorage("AutoCompleteMinChars") private var completionMinimum = 3
    @AppStorage("Autocompletion") private var autocompletion = true
    @AppStorage("AutocompleteRemovesExtensions") private var removeExtensions = false
    var body: some View {
        Form {
            Toggle("Style commit messages", isOn: $styleMessages)
            Text(verbatim: "Use *bold*, ^italic^ and _underlined_ text. Markers remain in the commit message. Issue and URL links stay enabled.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use auto-completion of file paths and keywords", isOn: $autocompletion)
            Stepper("Timeout in seconds to stop the auto-completion parsing: \(parseTimeout)", value: $parseTimeout, in: 1...100).disabled(!autocompletion)
            Stepper("Max. items to keep in the log message history: \(historyLimit)", value: $historyLimit, in: 1...100)
            Toggle("Select items automatically", isOn: $selectFiles)
            Toggle("Do not auto-select \"missing\" files (deleted, but unstaged)", isOn: $noMissing)
            Stepper("Complete after \(completionMinimum) characters", value: $completionMinimum, in: 1...100).disabled(!autocompletion)
            Toggle("Include file names without extensions", isOn: $removeExtensions).disabled(!autocompletion)
            Text("File and code completions come from the displayed changes. Press Ctrl-Space or Option-Escape to request them after one character.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
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
