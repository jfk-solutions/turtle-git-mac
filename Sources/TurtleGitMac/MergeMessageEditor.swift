// Adapts MergeDlg.cpp history insertion and SciEdit.cpp::InsertText (see NOTICE).
import AppKit
import SwiftUI
import TurtleGitCore

struct MergeMessageEditor: NSViewRepresentable {
    @ObservedObject var model: MergeWindowModel
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let editor = MergeMessageTextView(frame: .init(x: 0, y: 0, width: 600, height: 110))
        editor.isRichText = false; editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textContainerInset = .init(width: 5, height: 5)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Merge message"); editor.model = model; editor.delegate = context.coordinator
        scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? MergeMessageTextView else { return }
        editor.model = model; editor.isEditable = enabled
        editor.applyFont(MessageEditorFont.resolve(name: fontName, size: fontSize))
        if editor.string != model.message {
            let selection = editor.selectedRange()
            editor.string = model.message
            editor.setSelectedRange(.init(location: min(selection.location, (model.message as NSString).length), length: 0))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: MergeWindowModel
        init(_ model: MergeWindowModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { model.message = editor.string }
        }
    }
}

final class MergeMessageTextView: NSTextView {
    weak var model: MergeWindowModel?
    func applyFont(_ value: NSFont) {
        guard font != value else { return }
        let ranges = selectedRanges
        let undoEnabled = undoManager?.isUndoRegistrationEnabled == true
        if undoEnabled { undoManager?.disableUndoRegistration() }
        font = value; typingAttributes[.font] = value; selectedRanges = ranges
        if undoEnabled { undoManager?.enableUndoRegistration() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        appendHistoryItems(to: menu)
        return menu
    }
    func appendHistoryItems(to menu: NSMenu) {
        guard isEditable, model?.busy == false, model?.messageHistory.entries.isEmpty == false else { return }
        menu.addItem(.separator())
        for (title, action, icon) in [("Paste last message", #selector(pasteLastMessage), MenuIcon.copy), ("Recent messages…", #selector(recentMessages), MenuIcon.log)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.image = icon.contextImage(); menu.addItem(item)
        }
    }
    @objc func pasteLastMessage() {
        guard let text = model?.messageHistory.entries.first else { return }
        insertHistory(text, appendNewline: false)
    }
    @objc func recentMessages() {
        guard isEditable, model?.busy == false else { return }
        model?.showMessageHistory { [weak self] text in self?.insertHistory(text, appendNewline: true) }
    }
    func insertHistory(_ text: String, appendNewline: Bool) {
        guard isEditable, model?.busy == false else { return }
        let sentinel = string == MergeWindowModel.defaultMessage
        let range = sentinel ? NSRange(location: 0, length: (string as NSString).length) : selectedRange()
        let suffix = appendNewline && !sentinel && !string.isEmpty ? "\n" : ""
        insertText(text + suffix, replacementRange: range)
        model?.message = string
        window?.makeFirstResponder(self)
    }
}
