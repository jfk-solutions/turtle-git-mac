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
@MainActor final class SubmoduleProgressTextView: NSTextView, NSTextViewDelegate {
    var clipboard: NSPasteboard = .general
    var preferences: UserDefaults = .standard
    var openLink: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private var baseFont: NSFont?
    private var renderedCompleted = false, renderedSuccess = false, renderedStyle = true
    private var renderedRange: NSRange?
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { _ = openLink(url) }
        else if let string = link as? String, let url = URL(string: string) { _ = openLink(url) }
        return true
    }
    static func color(error: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if error { return NSColor(srgbRed: dark ? 207.0/255 : 1, green: dark ? 47.0/255 : 0, blue: dark ? 47.0/255 : 0, alpha: 1) }
            return NSColor(srgbRed: dark ? 185.0/255 : 160.0/255, green: dark ? 185.0/255 : 160.0/255, blue: 0, alpha: 1)
        }
    }
    static var successColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbRed: 0, green: dark ? 178.0/255 : 0, blue: 1, alpha: 1)
        }
    }
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
    func present(_ text: String, completed: Bool = false, completionRange: NSRange? = nil, success: Bool = false) {
        let style = (preferences.object(forKey: "StyleGitOutput") as? NSNumber)?.boolValue ?? true
        guard string != text || renderedCompleted != completed || renderedRange != completionRange || renderedSuccess != success || renderedStyle != style else { return }
        renderedCompleted = completed; renderedRange = completionRange; renderedSuccess = success; renderedStyle = style
        let ranges = selectedRanges.map(\.rangeValue)
        let font = baseFont ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font:font, .foregroundColor:NSColor.textColor])
        let value = text as NSString
        if completed {
            if style {
                var offset = 0
                for line in text.components(separatedBy: "\n") {
                    for prefix in ["fatal: ", "error: ", "warning: "] where line.hasPrefix(prefix) {
                        let range = NSRange(location:offset,length:(prefix as NSString).length)
                        attributed.addAttributes([.font:NSFontManager.shared.convert(font, toHaveTrait:.boldFontMask), .foregroundColor:Self.color(error:prefix != "warning: ")],range:range)
                    }
                    offset += (line as NSString).length + 1
                }
            }
            for range in MessageURLFinder.ranges(in:text) {
                if let url = URL(string:MessageURLFinder.target(for:value.substring(with:range))) { attributed.addAttribute(.link,value:url,range:range) }
            }
            if let range = completionRange, range.location <= value.length, range.length <= value.length - range.location {
                let color = success ? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.textColor : Self.successColor : Self.color(error:true)
                attributed.addAttribute(.foregroundColor,value:color,range:range)
            }
        }
        textStorage?.setAttributedString(attributed)
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
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.delegate = text
        text.linkTextAttributes = [.foregroundColor:NSColor.linkColor, .underlineStyle:NSUnderlineStyle.single.rawValue]
        text.font = MessageEditorFont.resolve(name: preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName,
                                               size: (preferences.object(forKey: "LogFontSize") as? Int) ?? MessageEditorFont.defaultSize)
        text.baseFont = text.font
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
    var completed = false
    var completionRange: NSRange?
    var success = false
    func makeNSView(context: Context) -> NSScrollView { SubmoduleProgressTextView.scrollView() }
    func updateNSView(_ nsView: NSScrollView, context: Context) { (nsView.documentView as? SubmoduleProgressTextView)?.present(text, completed:completed, completionRange:completionRange, success:success) }
}
