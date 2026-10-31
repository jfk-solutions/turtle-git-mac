// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import TurtleGitCore

enum ImageEditorCommand: String, CaseIterable {
    case overlay, blend, link, widths, heights, fit, original, zoomIn, zoomOut, info, vertical
    case open, reload, transparentColor, dark, fileMenu, viewMenu
    var title: String {
        switch self {
        case .overlay: return "Overlay images"; case .blend: return "Blend alpha"; case .link: return "Link image positions"
        case .widths: return "Fit image widths"; case .heights: return "Fit image heights"; case .fit: return "Fit images in window"
        case .original: return "Original size"; case .zoomIn: return "Zoom in"; case .zoomOut: return "Zoom out"
        case .info: return "Image info"; case .vertical: return "Arrange vertical"; case .open: return "Open…"
        case .reload: return "Reload"; case .transparentColor: return "Transparent color…"; case .dark: return "Dark Mode"
        case .fileMenu: return "File"; case .viewMenu: return "View"
        }
    }
    var icon: MenuIcon? {
        switch self {
        case .overlay: return .imageOverlay; case .blend: return .imageBlend; case .link: return .imageLink
        case .widths: return .imageFitWidths; case .heights: return .imageFitHeights; case .fit: return .imageFit
        case .original: return .imageOriginal; case .zoomIn: return .imageZoomIn; case .zoomOut: return .imageZoomOut
        case .info: return .imageInfo; case .vertical: return .imageVertical
        case .open: return .open; case .reload: return .refresh
        case .transparentColor: return .imageAlphaToggle; case .dark: return .settingsColors
        case .fileMenu: return .open; case .viewMenu: return .imageInfo
        }
    }
    var caption: String { Bundle.main.localizedString(forKey: title, value: title, table: nil) }
    /// Pinned IDC_TORTOISEIDIFF/IDC_TORTOISEIDIFF2; Reload is a native extension.
    static func menuCommands(_ menu: ImageEditorCommand, selection: Bool) -> [ImageEditorCommand?] {
        if menu == .fileMenu { return selection ? [.reload] : [.open, .reload] }
        let comparison: [ImageEditorCommand?] = selection ? [] : [.overlay, .blend, .link, .widths, .heights]
        return comparison + [.fit, .original, .transparentColor, nil, .zoomOut, .zoomIn, nil, .info, .vertical, nil, .dark]
    }
    var menuKey: (String, NSEvent.ModifierFlags) {
        switch self {
        case .open: return ("o", .command); case .vertical: return ("v", .command)
        case .overlay: return ("o", []); case .widths: return ("w", []); case .heights: return ("h", [])
        case .fit: return ("f", []); case .original: return ("s", []); case .info: return ("i", [])
        case .dark: return ("d", []); case .zoomOut: return ("-", []); case .zoomIn: return ("+", [])
        default: return ("", [])
        }
    }
    var toggle: Bool { [.overlay, .blend, .link, .widths, .heights, .info, .vertical, .dark].contains(self) }
    var identifier: NSToolbarItem.Identifier { .init("TurtleGit.Image." + rawValue) }
    static func key(_ event: NSEvent) -> ImageEditorCommand? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command { return key == "o" ? .open : key == "v" ? .vertical : nil }
        guard flags.isEmpty || flags == .shift else { return nil }
        switch key {
        case "d": return .dark; case "o": return .overlay; case "f": return .fit; case "s": return .original
        case "w": return .widths; case "h": return .heights; case "i": return .info
        case "+", "=": return .zoomIn; case "-": return .zoomOut
        default: return nil
        }
    }
}
struct ImageEditorCommandState { var enabled: Bool; var checked = false }

/// The source has different fixed toolbars for two-image and selection modes.
/// AppKit supplies native overflow; every item/menu dispatch rechecks its owner.
@MainActor final class ImageEditorToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation, NSMenuDelegate {
    let toolbar: NSToolbar
    private(set) var commandMenu: ImageEditorCommandMenu!
    private weak var window: NSWindow?
    private let commands: [ImageEditorCommand]
    private let defaults: [NSToolbarItem.Identifier]
    private let visible: () -> Bool
    private let state: (ImageEditorCommand) -> ImageEditorCommandState?
    private let action: (ImageEditorCommand) -> Void
    private let installed: (Bool) -> Void
    private let preferences:UserDefaults
    private var observations: [AnyCancellable] = []
    private var retired = false, queued = false
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    init(window: NSWindow, selection: Bool, changes: [AnyPublisher<Void, Never>],
         visible: @escaping () -> Bool, state: @escaping (ImageEditorCommand) -> ImageEditorCommandState?,
         action: @escaping (ImageEditorCommand) -> Void, installed: @escaping (Bool) -> Void, preferences:UserDefaults = .standard) {
        self.preferences=preferences;self.window = window; self.visible = visible; self.state = state; self.action = action; self.installed = installed
        let common: [ImageEditorCommand] = [.fit, .original, .zoomIn, .zoomOut, .info, .vertical]
        commands = (selection ? [] : [.overlay, .blend, .link, .widths, .heights]) + common + (selection ? [.reload] : [.open, .reload]) + [.transparentColor, .dark, .fileMenu, .viewMenu]
        defaults = (selection ? [] : [ImageEditorCommand.overlay.identifier, ImageEditorCommand.blend.identifier, .space, ImageEditorCommand.link.identifier, ImageEditorCommand.widths.identifier, ImageEditorCommand.heights.identifier, .space]) + common.prefix(4).map(\.identifier) + [.space] + common.suffix(2).map(\.identifier) + [.flexibleSpace, ImageEditorCommand.fileMenu.identifier, ImageEditorCommand.viewMenu.identifier]
        toolbar = NSToolbar(identifier: "TurtleGit.Image." + (selection ? "Selection." : "Comparison.") + UUID().uuidString)
        super.init(); toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        commandMenu = ImageEditorCommandMenu(window: window, selection: selection, available: visible, state: state, action: action, preferences: preferences)
        for publisher in changes { observations.append(publisher.sink { [weak self] in self?.scheduleRefresh() }) }
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observations.append(NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in self?.scheduleRefresh() })
        }
        refresh()
    }
    private func scheduleRefresh() {
        guard !retired, !queued else { return }; queued = true
        DispatchQueue.main.async { [weak self] in self?.queued = false; self?.refresh() }
    }
    func refresh() {
        guard !retired, let window else { return }
        let show = visible()
        if show && window.toolbar !== toolbar { window.toolbarStyle = .expanded; window.toolbar = toolbar; installed(true) }
        else if !show { if window.toolbar === toolbar { window.toolbar = nil }; installed(false) }
        for item in toolbar.items { update(item) }
        commandMenu.refresh()
    }
    func installMainMenu() { commandMenu.install() }
    func removeMainMenu() { commandMenu.remove() }
    func retire() {
        guard !retired else { return }; retired = true; observations = []; commandMenu.retire()
        for item in toolbar.items { item.isEnabled = false; (item.view as? NSControl)?.isEnabled = false }
        if window?.toolbar === toolbar { window?.toolbar = nil }
        installed(false)
    }
    private var active: Bool {
        !retired && visible() && window?.toolbar === toolbar && keyWindow() === window && window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
    private func command(_ tag: Int) -> ImageEditorCommand? { ImageEditorCommand.allCases.indices.contains(tag) ? ImageEditorCommand.allCases[tag] : nil }
    private func command(_ identifier: NSToolbarItem.Identifier) -> ImageEditorCommand? { commands.first { $0.identifier == identifier } }
    func perform(_ command: ImageEditorCommand) {
        guard active, commands.contains(command), state(command)?.enabled == true else { return }
        action(command); refresh()
    }
    @objc private func invoke(_ sender: AnyObject) {
        let tag = (sender as? NSControl)?.tag ?? (sender as? NSMenuItem)?.tag ?? (sender as? NSToolbarItem)?.tag ?? -1
        if let command = command(tag) { perform(command) }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { defaults }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { commands.map(\.identifier) + [.space, .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard !retired, let command = command(identifier) else { return nil }
        let item: NSToolbarItem
        if command == .fileMenu || command == .viewMenu {
            item = NSToolbarItem(itemIdentifier: identifier)
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            let contents = menu(command); contents.insertItem(withTitle: command.caption, action: nil, keyEquivalent: "", at: 0)
            popup.menu = contents; popup.title = command.caption; popup.bezelStyle = .texturedRounded
            popup.setAccessibilityLabel("Image " + command.caption + " menu"); popup.sizeToFit(); item.view = popup
        } else {
            item = NSToolbarItem(itemIdentifier: identifier)
            if command.toggle {
                let button = NSButton(image: command.icon?.image(size: 24) ?? NSImage(), target: self, action: #selector(invoke(_:)))
                button.setButtonType(.pushOnPushOff); button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly
                button.tag = ImageEditorCommand.allCases.firstIndex(of: command)!; button.toolTip = command.caption
                button.setAccessibilityLabel(command.caption); item.view = button
            }
            item.image = command.icon?.image(size: 24); item.target = self; item.action = #selector(invoke(_:))
        }
        item.autovalidates = false
        item.label = command.caption; item.paletteLabel = command.caption; item.toolTip = command.caption
        item.tag = ImageEditorCommand.allCases.firstIndex(of: command)!; update(item); return item
    }
    private func update(_ item: NSToolbarItem) {
        guard let command = command(item.itemIdentifier) else { return }
        let value = state(command), enabled = active && value?.enabled == true
        item.isEnabled = enabled
        (item.view as? NSControl)?.isEnabled = enabled
        if let popup = item.view as? NSPopUpButton, let contents = popup.menu { menuNeedsUpdate(contents) }
        if let button = item.view as? NSButton, !(button is NSPopUpButton) { button.isEnabled = enabled; button.state = value?.checked == true ? .on : .off; button.setAccessibilityValue(value?.checked == true ? "On" : "Off") }
        let overflow = leaf(command); overflow.isEnabled = enabled
        if command == .fileMenu || command == .viewMenu { overflow.submenu = menu(command) }
        item.menuFormRepresentation = overflow
    }
    private func leaf(_ command: ImageEditorCommand) -> NSMenuItem {
        let item = NSMenuItem(title: command.caption, action: #selector(invoke(_:)), keyEquivalent: "")
        item.target = self; item.tag = ImageEditorCommand.allCases.firstIndex(of: command)!; item.image = command.icon?.contextImage(defaults:preferences)
        item.isEnabled = active && state(command)?.enabled == true; item.state = state(command)?.checked == true ? .on : .off
        return item
    }
    private func menu(_ command: ImageEditorCommand) -> NSMenu {
        let menu = NSMenu(title: command.caption); menu.delegate = self
        let order = ImageEditorCommand.menuCommands(command, selection: !commands.contains(.open))
        for command in order {
            if let command { if commands.contains(command) { menu.addItem(leaf(command)) } }
            else if !menu.items.isEmpty && menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
        }
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem && item.action != nil {
            guard let command = command(item.tag) else { continue }
            item.image=command.icon?.contextImage(defaults:preferences)
            item.isEnabled = active && state(command)?.enabled == true; item.state = state(command)?.checked == true ? .on : .off
        }
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { active && command(item.itemIdentifier).flatMap(state)?.enabled == true }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = command(item.tag) else { return false }
        let value = state(command); item.state = value?.checked == true ? .on : .off
        return active && value?.enabled == true
    }
}

extension ImageEditorToolbar {
    static func comparison(_ owner: FileComparisonWindowController) -> ImageEditorToolbar? {
        guard let window = owner.window else { return nil }
        let model = owner.model, image = model.imageViewerModel
        image.commandsAllowed = { [weak model, weak owner] in
            guard let model, let owner else { return false }
            return model.imageCommandsAllowed && owner.editorOpenWorkflow == nil && !owner.preparingReplacement
        }
        return ImageEditorToolbar(window: window, selection: false, changes: [model.objectWillChange.eraseToAnyPublisher(), image.objectWillChange.eraseToAnyPublisher()],
            visible: { [weak model] in model?.imageComparison != nil },
            state: { [weak image] command in image?.commandState(command) }, action: { [weak image] command in
                image?.perform(command)
            }, installed: { [weak image, weak owner] value in
                if image?.nativeToolbarInstalled != value {
                    image?.nativeToolbarInstalled = value
                    if owner?.window?.isKeyWindow == true { owner?.refreshScopedFileMenu() }
                }
            },preferences:model.comparisonDefaults)
    }
    static func selection(_ owner:ImageSelectionWindowController)->ImageEditorToolbar? {
        guard let window=owner.window else{return nil};let model=owner.model
        return ImageEditorToolbar(window:window,selection:true,changes:[model.objectWillChange.eraseToAnyPublisher(),model.presentation.objectWillChange.eraseToAnyPublisher()],visible:{[weak model] in model?.retired==false},state:{[weak model] in model?.commandState($0)},action:{[weak model] in model?.perform($0)},installed:{[weak model] value in if model?.nativeToolbarInstalled != value {model?.nativeToolbarInstalled=value}},preferences:model.presentationPreferences)
    }
    static func conflict(_ owner: ImageConflictWindowController) -> ImageEditorToolbar? {
        guard let window = owner.window else { return nil }; let model = owner.model
        return ImageEditorToolbar(window: window, selection: true, changes: [model.objectWillChange.eraseToAnyPublisher(), model.presentation.objectWillChange.eraseToAnyPublisher()],
            visible: { [weak model] in model?.retired == false }, state: { [weak model] in model?.commandState($0) },
            action: { [weak model] in model?.perform($0) }, installed: { [weak model] value in if model?.nativeToolbarInstalled != value { model?.nativeToolbarInstalled = value } },preferences:model.presentationPreferences)
    }
}

/// Contributions belong to one key image owner. Native File/Close, Window,
/// application Quit and Help retain their existing responders and placement.
/// Shared exact-owner shortcut custody for native image/text command menus.
/// Restore only the same item in the same menu with unchanged target/action,
/// modifiers and our still-empty key. A host edit relinquishes that receipt.
@MainActor final class NativeMenuShortcutCustody {
    private final class Lease {
        weak var item: NSMenuItem?
        weak var parent: NSMenu?
        let key: String, mask: NSEvent.ModifierFlags, action: Selector?, target: ObjectIdentifier?
        var suppressed = false, relinquished = false
        init(_ item: NSMenuItem) {
            self.item = item; parent = item.menu; key = item.keyEquivalent
            mask = item.keyEquivalentModifierMask; action = item.action
            target = item.target.map { ObjectIdentifier($0) }
        }
        var unchangedOwner: Bool {
            guard let item else { return false }
            return item.menu === parent && parent != nil && item.action == action &&
                item.target.map { ObjectIdentifier($0) } == target && item.keyEquivalentModifierMask == mask
        }
        func suppress() {
            guard !relinquished, !suppressed, let item else { return }
            guard unchangedOwner, item.keyEquivalent == key else { relinquished = true; return }
            item.keyEquivalent = ""; suppressed = true
        }
        func restore() {
            guard suppressed, let item else { return }; suppressed = false
            guard unchangedOwner, item.keyEquivalent.isEmpty else { relinquished = true; return }
            item.keyEquivalent = key
        }
    }
    private var leases: [Lease] = []
    private func descendants(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(descendants) ?? []) }
    }
    func capture(in main: NSMenu, excluding owned: Set<ObjectIdentifier>, chords: [(String,NSEvent.ModifierFlags)], suppress: Bool) {
        let items = descendants(main), flags: NSEvent.ModifierFlags = [.command,.control,.option,.shift]
        // Clearing one AppKit winner may expose another item with the same key.
        for _ in 0...items.count {
            var discovered = false
            for item in items where !owned.contains(ObjectIdentifier(item)) && !leases.contains(where: { $0.item === item }) {
                guard chords.contains(where: { $0.0 == item.keyEquivalent && $0.1.intersection(flags) == item.keyEquivalentModifierMask.intersection(flags) }) else { continue }
                let lease = Lease(item); leases.append(lease); discovered = true
                if suppress { lease.suppress() }
            }
            if !suppress || !discovered { break }
        }
    }
    func suppress() { for lease in leases { lease.suppress() } }
    func restore() { for lease in leases { lease.restore() } }
    func remove() { restore(); leases = [] }
}

@MainActor final class ImageEditorCommandMenu: NSObject, NSMenuItemValidation {
    private final class Invocation {
        let command: ImageEditorCommand, epoch: UUID
        init(_ command: ImageEditorCommand, _ epoch: UUID) { self.command = command; self.epoch = epoch }
    }
    private let shortcutCustody = NativeMenuShortcutCustody()
    private var shortcutsClaimed = false
    private weak var window: NSWindow?
    private weak var mainMenu: NSMenu?
    private var contributed: [NSMenuItem] = [], createdRoots: [NSMenuItem] = []
    private var epoch = UUID(), retired = false, queued = false
    private var observations: [AnyCancellable] = []
    private var tracked = Set<ObjectIdentifier>()
    private let selection: Bool, preferences: UserDefaults
    private var available: () -> Bool
    private var state: (ImageEditorCommand) -> ImageEditorCommandState?
    private var action: (ImageEditorCommand) -> Void
    var applicationMenu: () -> NSMenu? = { NSApp.mainMenu }
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    init(window: NSWindow, selection: Bool, available: @escaping () -> Bool,
         state: @escaping (ImageEditorCommand) -> ImageEditorCommandState?, action: @escaping (ImageEditorCommand) -> Void,
         preferences: UserDefaults) {
        self.window = window; self.selection = selection; self.available = available; self.state = state; self.action = action; self.preferences = preferences
        super.init()
        observations.append(NotificationCenter.default.publisher(for: NSApplication.didUpdateNotification).sink { [weak self] _ in
            guard let self, self.needsSynchronization || self.shortcutsClaimed != self.shouldClaimShortcuts else { return }; self.scheduleRefresh()
        })
        for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
            observations.append(NotificationCenter.default.publisher(for: name).sink { [weak self] note in
                guard let self, (note.object as? NSView)?.window === self.window else { return }; self.scheduleRefresh()
            })
        }
        observations.append(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification).sink { [weak self] note in
            guard let self, let menu = note.object as? NSMenu, self.belongs(menu) else { return }; self.tracked.insert(ObjectIdentifier(menu))
        })
        observations.append(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification).sink { [weak self] note in
            guard let self, let menu = note.object as? NSMenu else { return }; self.tracked.remove(ObjectIdentifier(menu)); self.scheduleRefresh()
        })
    }
    private var ownsWindow: Bool { !retired && window != nil && keyWindow() === window && available() }
    private var active: Bool {
        ownsWindow && mainMenu != nil && mainMenu === applicationMenu() && window?.attachedSheet == nil && NSApp.modalWindow == nil &&
        (window?.firstResponder as? NSTextView)?.isFieldEditor != true
    }
    private var shouldClaimShortcuts: Bool {
        ownsWindow && window?.attachedSheet == nil && NSApp.modalWindow == nil &&
        (window?.firstResponder as? NSTextView)?.isFieldEditor != true
    }
    private var sourceChords: [(String, NSEvent.ModifierFlags)] {
        [ImageEditorCommand.fileMenu, .viewMenu].flatMap { ImageEditorCommand.menuCommands($0, selection: selection).compactMap { $0 } }
            .filter { state($0) != nil }.map(\.menuKey).filter { !$0.0.isEmpty }
    }
    private func captureHostShortcuts(in main: NSMenu, suppress: Bool) {
        shortcutCustody.capture(in: main, excluding: Set(contributed.map(ObjectIdentifier.init)), chords: sourceChords, suppress: suppress)
    }
    private func reconcileShortcuts() {
        guard let mainMenu else { return }
        let claim = shouldClaimShortcuts
        if !claim {
            // Release our exact chords first so AppKit exposes the restored
            // native Open/Paste keys instead of suppressing their public value.
            for item in contributed where item.representedObject is Invocation { item.keyEquivalent = "" }
            shortcutCustody.restore()
        } else {
            shortcutCustody.suppress()
            captureHostShortcuts(in: mainMenu, suppress: true)
            for item in contributed {
                guard let invocation = item.representedObject as? Invocation, invocation.epoch == epoch else { continue }
                let key = invocation.command.menuKey
                if item.keyEquivalentModifierMask != key.1 { item.keyEquivalentModifierMask = key.1 }
                if item.keyEquivalent != key.0 { item.keyEquivalent = key.0 }
            }
        }
        shortcutsClaimed = claim
    }
    private func belongs(_ menu: NSMenu) -> Bool {
        var current: NSMenu? = menu, seen = Set<ObjectIdentifier>()
        while let candidate = current, seen.insert(ObjectIdentifier(candidate)).inserted {
            if candidate === mainMenu { return true }; current = candidate.supermenu
        }
        return false
    }
    private var needsSynchronization: Bool {
        ownsWindow && (mainMenu !== applicationMenu() || contributed.isEmpty || contributed.contains { $0.menu.map { !belongs($0) } ?? true })
    }
    private func scheduleRefresh() {
        guard !queued, !retired else { return }; queued = true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.queued = false; self.refresh() }
    }
    func refresh() {
        guard !retired else { return }
        guard ownsWindow else { remove(); return }
        if needsSynchronization, tracked.isEmpty { install(); return }
        reconcileShortcuts()
        for item in contributed where !item.isSeparatorItem { _ = validateMenuItem(item) }
    }
    func install(in main: NSMenu? = nil) {
        guard !retired, ownsWindow, tracked.isEmpty, let main = main ?? applicationMenu() else { return }
        remove(); mainMenu = main
        // Resolve semantic roots before temporarily clearing native chords;
        // SwiftUI may expose a standard File role through its shortcut alone.
        let recipes: [(NSMenu, [ImageEditorCommand?])] = [ImageEditorCommand.fileMenu, .viewMenu].compactMap { role in
            let commands = ImageEditorCommand.menuCommands(role, selection: selection)
            guard commands.compactMap({ $0 }).contains(where: { state($0) != nil }) else { return nil }
            return (root(role, in: main), commands)
        }
        captureHostShortcuts(in: main, suppress: shouldClaimShortcuts)
        for (menu, commands) in recipes {
            if !menu.items.isEmpty { let separator = NSMenuItem.separator(); menu.addItem(separator); contributed.append(separator) }
            for command in commands {
                guard let command else {
                    if menu.items.last?.isSeparatorItem != true { let item = NSMenuItem.separator(); menu.addItem(item); contributed.append(item) }; continue
                }
                guard state(command) != nil else { continue }
                let key = command.menuKey
                let item = NSMenuItem(title: command.caption, action: #selector(invoke(_:)), keyEquivalent: "")
                item.keyEquivalentModifierMask = key.1; item.target = self
                item.identifier = .init(command.identifier.rawValue)
                item.representedObject = Invocation(command, epoch)
                item.image = command.icon?.contextImage(defaults: preferences)
                menu.addItem(item); contributed.append(item); _ = validateMenuItem(item)
            }
        }
        reconcileShortcuts()
    }
    private func root(_ role: ImageEditorCommand, in main: NSMenu) -> NSMenu {
        let name = role == .fileMenu ? "file" : "view", identifier = NSUserInterfaceItemIdentifier("org.turtlegit.merge.menu." + name)
        let selectors: Set<String> = role == .fileMenu ? ["openDocument:", "saveDocument:", "saveDocumentAs:", "saveAllDocuments:", "performClose:"] : ["toggleToolbarShown:", "toggleFullScreen:", "toggleSidebar:"]
        let semantic = main.items.first { root in root.submenu?.items.contains { item in
            if let action = item.action, selectors.contains(NSStringFromSelector(action)) { return true }
            let flags = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
            return role == .fileMenu && ["o", "w", "s"].contains(item.keyEquivalent.lowercased()) && flags.contains(.command) && !flags.contains(.control)
        } == true }
        let existing = main.items.first { $0.identifier == identifier } ?? semantic ?? scaffold(role, in: main)
        if let existing, let menu = existing.submenu { if existing.identifier == nil { existing.identifier = identifier }; return menu }
        let item = NSMenuItem(title: role.caption, action: nil, keyEquivalent: ""); item.identifier = identifier; item.submenu = NSMenu(title: role.caption)
        let following = main.items.firstIndex { candidate in
            candidate.submenu === NSApp.windowsMenu || candidate.submenu === NSApp.helpMenu ||
            (role == .fileMenu && candidate.identifier == .init("org.turtlegit.merge.menu.view"))
        } ?? main.items.count
        main.insertItem(item, at: following); createdRoots.append(item); return item.submenu!
    }
    private func scaffold(_ role: ImageEditorCommand, in main: NSMenu) -> NSMenuItem? {
        guard let windows = NSApp.windowsMenu, let help = NSApp.helpMenu,
              let app = main.items.firstIndex(where: { $0.submenu?.items.contains { item in
                  item.action.map(NSStringFromSelector) == "terminate:" || item.keyEquivalent == "q" && item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == .command
              } == true }),
              let end = main.items.firstIndex(where: { $0.submenu === windows }), app < end,
              main.items.contains(where: { $0.submenu === help }) else { return nil }
        let standard = main.items[(app + 1)..<end].filter { $0.submenu != nil && $0.identifier != .init("org.turtlegit.merge.menu.navigate") }
        guard standard.count >= 3 else { return nil }; return standard[role == .fileMenu ? 0 : 2]
    }
    func remove() {
        epoch = UUID()
        for item in contributed { item.isEnabled = false; item.keyEquivalent = ""; item.menu?.removeItem(item) }
        shortcutCustody.restore()
        shortcutCustody.remove(); shortcutsClaimed = false
        if let mainMenu { for root in createdRoots where root.submenu?.items.isEmpty == true && mainMenu.items.contains(root) { mainMenu.removeItem(root) } }
        contributed = []; createdRoots = []; mainMenu = nil; tracked.removeAll()
    }
    func retire() { remove(); retired = true; observations = []; available = { false }; state = { _ in nil }; action = { _ in }; applicationMenu = { nil }; keyWindow = { nil } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let invocation = item.representedObject as? Invocation, invocation.epoch == epoch,
              item.menu.map(belongs) == true else { item.isEnabled = false; return false }
        let value = state(invocation.command)
        item.state = value?.checked == true ? .on : .off
        item.image = invocation.command.icon?.contextImage(defaults: preferences)
        item.isEnabled = active && value?.enabled == true; return item.isEnabled
    }
    @objc private func invoke(_ item: NSMenuItem) {
        guard validateMenuItem(item), let invocation = item.representedObject as? Invocation else { return }
        action(invocation.command); refresh()
    }
}
