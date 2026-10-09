// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleProgressNativeWindow: NSWindow {
    var escapeAction: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { escapeAction(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Native adaptation of ProgressDlg's read-only RichEdit and icon copy menu.
@MainActor final class SubmoduleProgressTextView: NSTextView {
    var clipboard: NSPasteboard = .general
    var preferences: UserDefaults = .standard
    override func menu(for event: NSEvent) -> NSMenu? { outputMenu() }
    func outputMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        copy.target = self; copy.isEnabled = selectedRange().length > 0
        let all = NSMenuItem(title: "Copy all information to clipboard", action: #selector(copyAllInformation(_:)), keyEquivalent: "")
        all.target = self
        let icons = MenuPresentationSettings.applicationContextIcons(defaults: preferences)
        copy.image = icons ? MenuIcon.copy.image() : nil; all.image = icons ? MenuIcon.copy.image() : nil
        menu.addItem(copy); menu.addItem(.separator()); menu.addItem(all); return menu
    }
    @objc func copySelection(_ sender: Any?) { copy(sender) }
    override func copy(_ sender: Any?) {
        let range = selectedRange(), value = string as NSString
        guard range.length > 0, range.location <= value.length, range.length <= value.length - range.location else { return }
        clipboard.clearContents(); clipboard.setString(value.substring(with: range), forType: .string)
    }
    @objc func copyAllInformation(_ sender: Any?) {
        // No temporary selection: keep both the user's selection and viewport.
        clipboard.clearContents(); clipboard.setString(string, forType: .string)
    }
    func present(_ text: String) {
        guard string != text else { return }
        let ranges = selectedRanges.map(\.rangeValue)
        string = text
        let length = (text as NSString).length
        selectedRanges = ranges.map { range in
            let start = min(range.location, length)
            return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
        }
        if let manager = layoutManager, let container = textContainer { manager.ensureLayout(for: container) }
        // Source progress updates scroll to the latest output without changing selection.
        if let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    static func scrollView(preferences: UserDefaults = .standard, clipboard: NSPasteboard = .general) -> NSScrollView {
        let text = SubmoduleProgressTextView(frame: .zero)
        text.preferences = preferences; text.clipboard = clipboard
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = MessageEditorFont.resolve(name: preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName,
                                               size: (preferences.object(forKey: "LogFontSize") as? Int) ?? MessageEditorFont.defaultSize)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = text
        return scroll
    }
}

struct SubmoduleProgressOutputView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView { SubmoduleProgressTextView.scrollView() }
    func updateNSView(_ nsView: NSScrollView, context: Context) { (nsView.documentView as? SubmoduleProgressTextView)?.present(text) }
}
