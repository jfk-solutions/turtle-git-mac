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
    init(window: NSWindow, selection: Bool, changes: [AnyPublisher<Void, Never>],
         visible: @escaping () -> Bool, state: @escaping (ImageEditorCommand) -> ImageEditorCommandState?,
         action: @escaping (ImageEditorCommand) -> Void, installed: @escaping (Bool) -> Void, preferences:UserDefaults = .standard) {
        self.preferences=preferences;self.window = window; self.visible = visible; self.state = state; self.action = action; self.installed = installed
        let common: [ImageEditorCommand] = [.fit, .original, .zoomIn, .zoomOut, .info, .vertical]
        commands = (selection ? [] : [.overlay, .blend, .link, .widths, .heights]) + common + (selection ? [.reload] : [.open, .reload]) + [.transparentColor, .dark, .fileMenu, .viewMenu]
        defaults = (selection ? [] : [ImageEditorCommand.overlay.identifier, ImageEditorCommand.blend.identifier, .space, ImageEditorCommand.link.identifier, ImageEditorCommand.widths.identifier, ImageEditorCommand.heights.identifier, .space]) + common.prefix(4).map(\.identifier) + [.space] + common.suffix(2).map(\.identifier) + [.flexibleSpace, ImageEditorCommand.fileMenu.identifier, ImageEditorCommand.viewMenu.identifier]
        toolbar = NSToolbar(identifier: "TurtleGit.Image." + (selection ? "Selection." : "Comparison.") + UUID().uuidString)
        super.init(); toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        for publisher in changes { observations.append(publisher.sink { [weak self] in self?.scheduleRefresh() }) }
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
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
    }
    func retire() {
        guard !retired else { return }; retired = true; observations = []
        for item in toolbar.items { item.isEnabled = false; (item.view as? NSControl)?.isEnabled = false }
        if window?.toolbar === toolbar { window?.toolbar = nil }
        installed(false)
    }
    private var active: Bool { !retired && visible() && window?.toolbar === toolbar }
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
            let contents = menu(command); contents.insertItem(withTitle: command.title, action: nil, keyEquivalent: "", at: 0)
            popup.menu = contents; popup.title = command.title; popup.bezelStyle = .texturedRounded
            popup.setAccessibilityLabel("Image " + command.title + " menu"); popup.sizeToFit(); item.view = popup
        } else {
            item = NSToolbarItem(itemIdentifier: identifier)
            if command.toggle {
                let button = NSButton(image: command.icon?.image(size: 24) ?? NSImage(), target: self, action: #selector(invoke(_:)))
                button.setButtonType(.pushOnPushOff); button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly
                button.tag = ImageEditorCommand.allCases.firstIndex(of: command)!; button.toolTip = command.title
                button.setAccessibilityLabel(command.title); item.view = button
            }
            item.image = command.icon?.image(size: 24); item.target = self; item.action = #selector(invoke(_:))
        }
        item.autovalidates = false
        item.label = command.title; item.paletteLabel = command.title; item.toolTip = command.title
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
        let item = NSMenuItem(title: command.title, action: #selector(invoke(_:)), keyEquivalent: "")
        item.target = self; item.tag = ImageEditorCommand.allCases.firstIndex(of: command)!; item.image = command.icon?.contextImage(defaults:preferences)
        item.isEnabled = active && state(command)?.enabled == true; item.state = state(command)?.checked == true ? .on : .off
        return item
    }
    private func menu(_ command: ImageEditorCommand) -> NSMenu {
        let menu = NSMenu(title: command.title); menu.delegate = self
        let order: [ImageEditorCommand?] = command == .fileMenu ? [.open, .reload] : [.overlay, .blend, .link, .widths, .heights, .fit, .original, .transparentColor, nil, .zoomOut, .zoomIn, nil, .info, .vertical, nil, .dark]
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
    static func conflict(_ owner: ImageConflictWindowController) -> ImageEditorToolbar? {
        guard let window = owner.window else { return nil }; let model = owner.model
        return ImageEditorToolbar(window: window, selection: true, changes: [model.objectWillChange.eraseToAnyPublisher(), model.presentation.objectWillChange.eraseToAnyPublisher()],
            visible: { [weak model] in model?.retired == false }, state: { [weak model] in model?.commandState($0) },
            action: { [weak model] in model?.perform($0) }, installed: { [weak model] value in if model?.nativeToolbarInstalled != value { model?.nativeToolbarInstalled = value } },preferences:model.presentationPreferences)
    }
}
