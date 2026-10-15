// Native hotspot dispatch for SciEdit/Log message views. SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum SourceMessageLinkURL {
    /// Preserve the source's literal target and percent escapes. Do not infer a
    /// remote from a relative bugtraq URL: the pinned Log root is never assigned.
    static func url(_ target: String) -> URL? {
        guard !target.isEmpty, !target.contains("\0") else { return nil }
        return URL(string: target)
    }
}
@MainActor final class MessageLinkMenuItem: NSMenuItem, NSMenuItemValidation {
    private let invoke: () -> Void
    private let available: () -> Bool
    init(title: String, icon: MenuIcon, defaults: UserDefaults = .standard, available: @escaping () -> Bool = { true }, invoke: @escaping () -> Void) {
        self.invoke = invoke; self.available = available
        super.init(title:title, action:#selector(invokeMessageAction), keyEquivalent:"")
        target = self; image = icon.contextImage(defaults:defaults); isEnabled = available()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { available() }
    @objc func invokeMessageAction() { guard available() else { return }; invoke() }
}
@MainActor final class SourceMessageLinkInteraction {
    struct Snapshot {
        fileprivate let generation: UUID
        fileprivate let owner: ObjectIdentifier
        fileprivate let text: String
        let range: NSRange
        let target: String
    }
    private weak var editor: NSTextView?
    private var generation = UUID(), retired = false
    private var closeObserver: NSObjectProtocol?
    var canInteract: () -> Bool = { true }
    var preferences: () -> UserDefaults = { .standard }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var writeClipboard: (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType:.string) }
    init(editor: NSTextView) { self.editor = editor }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    func invalidate() { generation = UUID() }
    func attachOwner() {
        invalidate(); if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }; closeObserver = nil
        guard let window = editor?.window else { retired = true; return }
        retired = false
        closeObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification, object:window, queue:nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.retire() }
        }
    }
    func retire() {
        retired = true; invalidate()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }; closeObserver = nil
    }
    private func target(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? URL { return value.absoluteString }
        return nil
    }
    func snapshot(at index: Int) -> Snapshot? {
        guard !retired, let editor, let window = editor.window, let storage = editor.textStorage, index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        guard let target = target(storage.attribute(.link,at:index,effectiveRange:&range)), SourceMessageLinkURL.url(target) != nil else { return nil }
        return Snapshot(generation:generation, owner:ObjectIdentifier(window), text:editor.string, range:range, target:target)
    }
    func current(_ snapshot: Snapshot) -> Bool {
        guard !retired, generation == snapshot.generation, let editor, let window = editor.window,
              ObjectIdentifier(window) == snapshot.owner, editor.string.utf8.elementsEqual(snapshot.text.utf8),
              let storage = editor.textStorage, snapshot.range.location < storage.length else { return false }
        var range = NSRange()
        return target(storage.attribute(.link,at:snapshot.range.location,effectiveRange:&range)) == snapshot.target && range == snapshot.range
    }
    func available(_ snapshot: Snapshot) -> Bool { current(snapshot) && canInteract() && editor?.window?.attachedSheet == nil }
    func activate(_ snapshot: Snapshot) {
        guard available(snapshot), editor?.selectedRanges.allSatisfy({ $0.rangeValue.length == 0 }) == true,
              let url = SourceMessageLinkURL.url(snapshot.target) else { return }
        openURL(url)
    }
    func clicked(_ value: Any, at index: Int) {
        guard let snapshot = snapshot(at:index), target(value) == snapshot.target else { return }; activate(snapshot)
    }
    func copy(_ snapshot: Snapshot) { guard available(snapshot) else { return }; writeClipboard(snapshot.target) }
    func prepareMenu(_ menu: NSMenu, at index: Int) {
        removeInheritedLinks(menu)
        decorateEditingItems(menu)
        guard let snapshot = snapshot(at:index) else { return }
        let open = MessageLinkMenuItem(title:"Open link",icon:.open,defaults:preferences(),available:{ [weak self] in
            self?.available(snapshot) == true && self?.editor?.selectedRanges.allSatisfy({ $0.rangeValue.length == 0 }) == true
        }) { [weak self] in self?.activate(snapshot) }
        let copy = MessageLinkMenuItem(title:"Copy link address",icon:.copy,defaults:preferences(),available:{ [weak self] in self?.available(snapshot) == true }) { [weak self] in self?.copy(snapshot) }
        open.representedObject = "TurtleGit.MessageLink"; copy.representedObject = "TurtleGit.MessageLink"
        menu.insertItem(copy,at:0); menu.insertItem(open,at:0)
        if menu.items.count > 2 && !menu.items[2].isSeparatorItem { menu.insertItem(.separator(),at:2) }
    }
    private func removeInheritedLinks(_ menu: NSMenu) {
        // Match actions, not localized titles. Default AppKit link actions would
        // otherwise bypass the captured text/owner checks above.
        for item in menu.items {
            if let submenu = item.submenu { removeInheritedLinks(submenu) }
            let action = item.action.map(NSStringFromSelector) ?? ""
            if item.representedObject as? String == "TurtleGit.MessageLink" || action.localizedCaseInsensitiveContains("link") { menu.removeItem(item) }
        }
    }
    private func decorateEditingItems(_ menu: NSMenu) {
        let enabled = MenuPresentationSettings.applicationContextIcons(defaults:preferences())
        for item in menu.items {
            if let submenu = item.submenu { decorateEditingItems(submenu) }
            switch item.action.map(NSStringFromSelector) {
            case "copy:": item.image = MenuIcon.copy.contextImage(defaults:preferences())
            case "paste:", "pasteAsPlainText:": item.image = MenuIcon.mergePaste.contextImage(defaults:preferences())
            case "undo:": item.image = MenuIcon.mergeUndo.contextImage(defaults:preferences())
            case "redo:": item.image = MenuIcon.mergeRedo.contextImage(defaults:preferences())
            case "delete:": item.image = MenuIcon.remove.contextImage(defaults:preferences())
            case "cut:": item.image = enabled ? NSImage(systemSymbolName:"scissors",accessibilityDescription:"Cut") : nil
            default: break
            }
        }
    }
}
