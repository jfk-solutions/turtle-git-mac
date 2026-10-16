// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import TurtleGitCore

@MainActor enum MergeEditorChrome {
    static func visible(_ part: String, defaults: UserDefaults) -> Bool {
        let key = "TurtleGitMerge." + part + "Visible"
        return defaults.object(forKey:key) == nil || defaults.bool(forKey:key)
    }
}

enum MergeToolbarCommand: String, CaseIterable {
    case open, save, saveAs, reload, undo, redo, previousDifference, nextDifference, previousConflict, nextConflict
    case useLeft, useTheirs, useMine, theirsThenMine, mineThenTheirs, resolved, find, patch, compareSources, showBase
    case whitespace, wrap, inline, inlineWord, onePane, collapsed, help
    case saveLeft, saveRight, saveMerged, continueResolving, compareTheirs, compareMine, switchSides
    var title: String {
        switch self {
        case .open: return "Open"; case .save: return "Save"; case .saveAs: return "Save As"
        case .reload: return "Reload"; case .undo: return "Undo"; case .redo: return "Redo"
        case .previousDifference: return "Previous difference"; case .nextDifference: return "Next difference"
        case .previousConflict: return "Previous conflict"; case .nextConflict: return "Next conflict"
        case .useLeft: return "Use left block"; case .useTheirs: return "Use Theirs block"; case .useMine: return "Use Mine block"
        case .theirsThenMine: return "Use Theirs before Mine"; case .mineThenTheirs: return "Use Mine before Theirs"
        case .resolved: return "Mark as resolved"; case .find: return "Find"; case .patch: return "Create patch file"
        case .compareSources: return "Compare sources"; case .showBase: return "Show Base"
        case .whitespace: return "Show whitespace"; case .wrap: return "Wrap long lines"; case .inline: return "Inline diff"
        case .inlineWord: return "Inline word diff"; case .onePane: return "One-pane view"; case .collapsed: return "Collapse unchanged lines"
        case .help: return "Help"; case .saveLeft: return "Save left pane as…"; case .saveRight: return "Save right pane as…"
        case .saveMerged: return "Save merged result as…"; case .continueResolving: return "Continue resolving conflicts"
        case .compareTheirs: return "Compare Theirs with Base"; case .compareMine: return "Compare Mine with Base"
        case .switchSides: return "Switch left and right view"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .open: return .mergeOpen; case .save: return .mergeSave
        case .saveAs, .saveLeft, .saveRight, .saveMerged: return .mergeSaveAs
        case .reload: return .mergeReload; case .undo: return .mergeUndo; case .redo: return .mergeRedo
        case .previousDifference: return .mergePreviousDifference; case .nextDifference: return .mergeNextDifference
        case .previousConflict: return .mergePreviousConflict; case .nextConflict, .continueResolving: return .mergeNextConflict
        case .useLeft, .useTheirs: return .mergeUseTheirs; case .useMine: return .mergeUseMine
        case .theirsThenMine: return .mergeTheirsThenMine; case .mineThenTheirs: return .mergeMineThenTheirs
        case .resolved: return .mergeResolved; case .find: return .mergeFind; case .patch: return .patch
        case .compareSources, .compareTheirs, .compareMine, .showBase: return .compare
        case .whitespace: return .mergeWhitespace; case .wrap: return .mergeWrap
        case .inline: return .mergeInline; case .inlineWord: return .mergeInlineWord
        case .switchSides: return .mergeSwitch
        case .onePane: return .mergeOnePane; case .collapsed: return .mergeCollapse; case .help: return .help
        }
    }
    var toggle: Bool { [.showBase, .whitespace, .wrap, .inline, .inlineWord, .onePane, .collapsed].contains(self) }
    var identifier: NSToolbarItem.Identifier { .init("TurtleGit.Merge." + rawValue) }
}
struct MergeToolbarState {
    var enabled: Bool
    var checked = false
}

/// AppKit supplies customization and overflow, while every dispatch asks the
/// owning live model again. Retained toolbar/overflow items cannot revive it.
@MainActor final class MergeEditorToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    let toolbar: NSToolbar
    private weak var window: NSWindow?
    private var observer: AnyCancellable?
    private var queued = false, retired = false
    private var restoring = true, configurationChanged = false
    private let preferences: UserDefaults
    let profileKey: String
    private var displayObservation: NSKeyValueObservation?
    private var visibilityObservation: NSKeyValueObservation?
    private var applyingVisibility = false
    private var toolbarShown: () -> Bool
    private var changedVisibility: (Bool) -> Void
    private var states: (MergeToolbarCommand) -> MergeToolbarState?
    private var action: (MergeToolbarCommand) -> Void
    private var visible: () -> Bool
    private var installed: (Bool) -> Void
    private let commands: [MergeToolbarCommand]
    private let defaults: [MergeToolbarCommand]
    private var menus: [MergeToolbarCommand: [MergeToolbarCommand]]
    init(window: NSWindow, identifier: String, commands: [MergeToolbarCommand], defaults: [MergeToolbarCommand], menus: [MergeToolbarCommand: [MergeToolbarCommand]], changes: ObservableObjectPublisher,
         preferences: UserDefaults, visible: @escaping () -> Bool, toolbarShown: @escaping () -> Bool, changedVisibility: @escaping (Bool) -> Void, installed: @escaping (Bool) -> Void,
         state: @escaping (MergeToolbarCommand) -> MergeToolbarState?, action: @escaping (MergeToolbarCommand) -> Void) {
        self.window = window; self.commands = commands; self.defaults = defaults; self.menus = menus
        self.states = state; self.action = action; self.visible = visible; self.installed = installed
        self.toolbarShown = toolbarShown; self.changedVisibility = changedVisibility
        self.preferences = preferences; profileKey = identifier + ".ToolbarConfiguration"
        // AppKit synchronizes items/targets for equal identifiers. Keep native
        // instances unique and persist only layout, independently of ownership.
        toolbar = NSToolbar(identifier: NSToolbar.Identifier(identifier + "." + UUID().uuidString))
        super.init(); toolbar.delegate = self; toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = false
        window.toolbarStyle = .expanded
        observer = changes.sink { [weak self] _ in self?.scheduleRefresh() }
        refresh()
        restoreConfiguration()
        restoring = false
        displayObservation = toolbar.observe(\.displayMode, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changedConfiguration() }
        }
        visibilityObservation = toolbar.observe(\.isVisible,options:[.new]) { [weak self] toolbar,_ in
            MainActor.assumeIsolated {
                guard let self,!self.retired,!self.applyingVisibility,self.window?.toolbar === toolbar else { return }
                self.changedVisibility(toolbar.isVisible)
            }
        }
    }
    private func restoreConfiguration() {
        guard let saved = preferences.dictionary(forKey: profileKey) else { return }
        if let identifiers = saved["items"] as? [String] {
            let allowed = Set(commands.map { $0.identifier.rawValue } + [NSToolbarItem.Identifier.space.rawValue, NSToolbarItem.Identifier.flexibleSpace.rawValue])
            var seen = Set<String>()
            let items = identifiers.prefix(64).filter { allowed.contains($0) && ([$0].contains(NSToolbarItem.Identifier.space.rawValue) || $0 == NSToolbarItem.Identifier.flexibleSpace.rawValue || seen.insert($0).inserted) }
            for index in toolbar.items.indices.reversed() { toolbar.removeItem(at: index) }
            for (index, item) in items.enumerated() { toolbar.insertItem(withItemIdentifier: .init(item), at: index) }
        }
        if let mode = saved["displayMode"] as? Int, (0...3).contains(mode), let value = NSToolbar.DisplayMode(rawValue: UInt(mode)) { toolbar.displayMode = value }
    }
    private func changedConfiguration() {
        guard !restoring, !retired else { return }
        configurationChanged = true
        DispatchQueue.main.async { [weak self] in self?.saveConfiguration() }
    }
    private func saveConfiguration() {
        guard configurationChanged, !restoring else { return }; configurationChanged = false
        preferences.set(["items": toolbar.items.map { $0.itemIdentifier.rawValue }, "displayMode": Int(toolbar.displayMode.rawValue)], forKey: profileKey)
    }
    func toolbarWillAddItem(_ notification: Notification) { changedConfiguration() }
    func toolbarDidRemoveItem(_ notification: Notification) { changedConfiguration() }
    private func scheduleRefresh() {
        guard !retired, !queued else { return }; queued = true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.queued = false; self.refresh() }
    }
    func refresh() {
        guard !retired, let window else { return }
        let show = visible()
        if show && window.toolbar !== toolbar { window.toolbar = toolbar; installed(true) }
        else if !show && window.toolbar === toolbar { window.toolbar = nil; installed(false) }
        if show,window.toolbar === toolbar,toolbar.isVisible != toolbarShown() {
            applyingVisibility = true;toolbar.isVisible = toolbarShown();applyingVisibility = false
        }
        for item in toolbar.items { update(item) }
    }
    func retire() {
        guard !retired else { return }; saveConfiguration(); retired = true; observer = nil; displayObservation = nil; visibilityObservation = nil
        for item in toolbar.items { item.isEnabled = false; (item.view as? NSButton)?.isEnabled = false }
        if window?.toolbar === toolbar { window?.toolbar = nil }
        installed(false); action = { _ in }; states = { _ in nil }; visible = { false }; toolbarShown = { false };changedVisibility = { _ in }; installed = { _ in }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { defaults.map(\.identifier) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { commands.map(\.identifier) + [.flexibleSpace, .space] }
    private func command(_ identifier: NSToolbarItem.Identifier) -> MergeToolbarCommand? { MergeToolbarCommand.allCases.first { $0.identifier == identifier } }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard !retired, let command = command(identifier), commands.contains(command) else { return nil }
        let item: NSToolbarItem = menus[command] == nil ? NSToolbarItem(itemIdentifier: identifier) : NSMenuToolbarItem(itemIdentifier: identifier)
        item.autovalidates = false
        item.label = command.title; item.paletteLabel = command.title; item.toolTip = command.title
        item.image = command.icon.image(size: 20); item.target = self; item.action = #selector(invoke(_:))
        item.tag = MergeToolbarCommand.allCases.firstIndex(of: command)!
        if command.toggle {
            let button = NSButton(image: command.icon.image(size: 20) ?? NSImage(), target: self, action: #selector(invoke(_:)))
            button.tag = item.tag; button.setButtonType(.pushOnPushOff); button.bezelStyle = .texturedRounded
            button.toolTip = command.title; button.setAccessibilityLabel(command.title); item.view = button
        }
        update(item); return item
    }
    private func menu(_ commands: [MergeToolbarCommand]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for command in commands where states(command) != nil {
            let item = NSMenuItem(title: command.title, action: #selector(invoke(_:)), keyEquivalent: "")
            item.target = self; item.tag = MergeToolbarCommand.allCases.firstIndex(of: command)!
            item.image = command.icon.image(); item.isEnabled = !retired && states(command)?.enabled == true
            item.state = states(command)?.checked == true ? .on : .off; menu.addItem(item)
        }
        return menu
    }
    private func update(_ item: NSToolbarItem) {
        guard let command = command(item.itemIdentifier) else { return }
        let state = states(command); item.isEnabled = !retired && state?.enabled == true
        if let button = item.view as? NSButton { button.isEnabled = item.isEnabled; button.state = state?.checked == true ? .on : .off }
        if let group = item as? NSMenuToolbarItem, let choices = menus[command] { group.menu = menu(choices) }
        let overflow = NSMenuItem(title: command.title, action: #selector(invoke(_:)), keyEquivalent: "")
        overflow.target = self; overflow.tag = item.tag; overflow.image = command.icon.image(); overflow.isEnabled = item.isEnabled
        overflow.state = state?.checked == true ? .on : .off
        if let choices = menus[command] { overflow.submenu = menu(choices) }
        item.menuFormRepresentation = overflow
    }
    @objc private func invoke(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? (sender as? NSToolbarItem)?.tag ?? -1
        guard MergeToolbarCommand.allCases.indices.contains(tag) else { return }
        perform(MergeToolbarCommand.allCases[tag])
    }
    func perform(_ command: MergeToolbarCommand) {
        guard !retired, window?.toolbar === toolbar, visible(), states(command)?.enabled == true else { return }
        action(command); refresh()
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard !retired, window?.toolbar === toolbar, visible(), let command = command(item.itemIdentifier) else { return false }
        return states(command)?.enabled == true
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard !retired, MergeToolbarCommand.allCases.indices.contains(item.tag) else { return false }
        return window?.toolbar === toolbar && visible() && states(MergeToolbarCommand.allCases[item.tag])?.enabled == true
    }
}

extension MergeEditorToolbar {
    static func comparison(_ owner: FileComparisonWindowController) -> MergeEditorToolbar? {
        guard let window = owner.window else { return nil }; let model = owner.model
        let commands: [MergeToolbarCommand] = [.open, .save, .saveAs, .reload, .undo, .redo, .previousDifference, .nextDifference, .useLeft, .whitespace, .wrap, .inline, .inlineWord, .onePane, .collapsed, .switchSides, .find, .patch, .help]
        return MergeEditorToolbar(window: window, identifier: "TurtleGit.Merge.Comparison", commands: commands,
            defaults: [.open, .save, .saveAs, .reload, .undo, .redo, .previousDifference, .nextDifference, .useLeft, .wrap, .inline, .collapsed, .find, .patch, .help],
            menus: [.saveAs: [.saveLeft, .saveRight]], changes: model.objectWillChange, preferences: model.comparisonDefaults,
            visible: { [weak model] in model?.imageComparison == nil }, toolbarShown:{ [weak model] in model?.showToolbar == true }, changedVisibility:{ [weak model] in model?.setToolbarVisible($0) }, installed: { [weak model] installed in if model?.nativeToolbarInstalled != installed { model?.nativeToolbarInstalled = installed } },
            state: { [weak model, weak owner] command in
                guard let model, let owner else { return nil }
                let ready = model.contextCommandsAllowed && !model.filtering && owner.editorOpenWorkflow == nil && !owner.preparingReplacement
                let text = ready && model.alignment != nil
                switch command {
                case .open, .reload, .help: return .init(enabled: ready)
                case .save: return .init(enabled: ready && model.activeDirty)
                case .saveAs, .saveRight: return .init(enabled: ready && model.canSavePaneAs)
                case .saveLeft: return model.onePaneActive ? nil : .init(enabled: ready && model.canSavePaneAs)
                case .undo: return .init(enabled: ready && model.canUndo)
                case .redo: return .init(enabled: ready && model.canRedo)
                case .previousDifference: return .init(enabled: text && model.canNavigateDifference(-1))
                case .nextDifference: return .init(enabled: text && model.canNavigateDifference(1))
                case .useLeft: return .init(enabled: text && model.oppositeViewCommandsAllowed && model.canTransfer(toBase: false) && model.transferRows != nil)
                case .find: return .init(enabled: text)
                case .patch: return .init(enabled: ready && model.canCreateUnifiedPatch)
                case .whitespace: return .init(enabled: text, checked: model.whitespaceDisplay.visible)
                case .wrap: return .init(enabled: text, checked: model.wrapLines)
                case .inline: return .init(enabled: text && !model.singleFileMode, checked: model.showInlineDiff)
                case .inlineWord: return .init(enabled: text && !model.singleFileMode && model.showInlineDiff, checked: model.inlineWordDiff)
                case .onePane: return .init(enabled: text && !model.singleFileMode, checked: model.onePaneMode)
                case .switchSides: return .init(enabled: text && model.canSwitchSides)
                case .collapsed: return .init(enabled: text, checked: model.folding.collapsed)
                default: return nil
                }
            }, action: { [weak model, weak owner] command in
                guard let model, let owner else { return }
                switch command {
                case .open: owner.openMergeDocument(nil)
                case .reload: owner.reloadEditor(nil)
                case .save: model.save()
                case .saveLeft: model.saveAs(base: true)
                case .saveRight: model.saveAs(base: false)
                case .undo: model.undo(); case .redo: model.redo()
                case .previousDifference: model.navigate(-1); case .nextDifference: model.navigate(1)
                case .useLeft: model.useOtherBlock(targetBase: false)
                case .find: model.find(.showFindInterface)
                case .patch: model.createUnifiedPatch()
                case .whitespace: var next = model.whitespaceDisplay; next.visible.toggle(); model.setWhitespaceDisplay(next)
                case .wrap: model.setWrapLines(!model.wrapLines)
                case .inline: model.setInlineDiff(!model.showInlineDiff)
                case .inlineWord: model.setInlineWordDiff(!model.inlineWordDiff)
                case .onePane: model.switchPaneMode(!model.onePaneMode)
                case .switchSides: model.switchSides()
                case .collapsed: model.setCollapsed(!model.folding.collapsed)
                case .help: owner.showEditorHelp()
                default: break
                }
            })
    }
    static func conflict(_ owner: TextConflictWindowController) -> MergeEditorToolbar? {
        guard let window = owner.window else { return nil }; let model = owner.model
        let commands: [MergeToolbarCommand] = [.open, .save, .saveAs, .reload, .undo, .redo, .previousDifference, .nextDifference, .previousConflict, .nextConflict, .useTheirs, .useMine, .theirsThenMine, .mineThenTheirs, .resolved, .whitespace, .wrap, .inline, .inlineWord, .collapsed, .find, .compareSources, .showBase, .help]
        return MergeEditorToolbar(window: window, identifier: "TurtleGit.Merge.Conflict", commands: commands,
            defaults: [.open, .save, .saveAs, .reload, .undo, .redo, .previousDifference, .nextDifference, .previousConflict, .nextConflict, .useTheirs, .useMine, .theirsThenMine, .mineThenTheirs, .resolved, .wrap, .find, .compareSources, .showBase, .help],
            menus: [.saveAs: [.saveLeft, .saveRight, .saveMerged, .continueResolving], .compareSources: [.compareTheirs, .compareMine]],
            changes: model.objectWillChange, preferences: model.comparisonDefaults,
            visible: { [weak model] in model?.retired == false }, toolbarShown:{ [weak model] in model?.showToolbar == true }, changedVisibility:{ [weak model] in model?.setToolbarVisible($0) }, installed: { [weak model] installed in if model?.nativeToolbarInstalled != installed { model?.nativeToolbarInstalled = installed } },
            state: { [weak model, weak owner] command in
                guard let model, let owner else { return nil }
                let ready = !model.retired && !model.busy && !model.preparing && !model.exportingSource && !model.formatPending && !model.confirmingQuit && window.attachedSheet == nil && owner.editorOpenWorkflow == nil && !owner.preparingReplacement
                let text = ready && model.document != nil
                switch command {
                case .open, .reload, .help: return .init(enabled: ready)
                case .save: return .init(enabled: text)
                case .saveAs, .saveLeft, .saveRight, .saveMerged, .compareSources, .compareTheirs, .compareMine: return .init(enabled: text && model.sourceToolsAllowed)
                case .continueResolving: return .init(enabled: text && !model.blocks.isEmpty)
                case .undo: return .init(enabled: text && model.canUndo)
                case .redo: return .init(enabled: text && model.canRedo)
                case .previousDifference: return .init(enabled: text && model.canNavigateBlock(-1,conflictsOnly:false))
                case .nextDifference: return .init(enabled: text && model.canNavigateBlock(1,conflictsOnly:false))
                case .previousConflict: return .init(enabled: text && model.canNavigateBlock(-1,conflictsOnly:true))
                case .nextConflict: return .init(enabled: text && model.canNavigateBlock(1,conflictsOnly:true))
                case .useTheirs, .useMine, .theirsThenMine, .mineThenTheirs: return .init(enabled: text && model.canChooseConflict)
                case .resolved: return .init(enabled: text && model.workingMerge == nil && !model.hasUnresolvedConflicts)
                case .find: return .init(enabled: text)
                case .showBase: return .init(enabled: text, checked: model.showBase)
                case .whitespace: return .init(enabled: text, checked: model.whitespaceDisplay.visible)
                case .wrap: return .init(enabled: text, checked: model.wrapLines)
                case .inline: return .init(enabled: text && model.sourceComparison != nil, checked: model.showInlineDiff)
                case .inlineWord: return .init(enabled: text && model.sourceComparison != nil && model.showInlineDiff, checked: model.inlineWordDiff)
                case .collapsed: return .init(enabled: text, checked: model.folding.collapsed)
                default: return nil
                }
            }, action: { [weak model, weak owner] command in
                guard let model, let owner else { return }
                switch command {
                case .open: owner.openMergeDocument(nil); case .reload: owner.reloadEditor(nil)
                case .save: model.save(markResolved: false)
                case .saveLeft: model.exportSource(mine: false); case .saveRight: model.exportSource(mine: true)
                case .saveMerged: model.export(); case .continueResolving: model.continueResolving()
                case .compareTheirs: model.compareSourceWithBase(mine: false); case .compareMine: model.compareSourceWithBase(mine: true)
                case .undo: model.undo(); case .redo: model.redo()
                case .previousDifference: model.navigateBlock(-1,conflictsOnly:false); case .nextDifference: model.navigateBlock(1,conflictsOnly:false)
                case .previousConflict: model.navigateBlock(-1,conflictsOnly:true); case .nextConflict: model.navigateBlock(1,conflictsOnly:true)
                case .useTheirs: model.choose(.theirs); case .useMine: model.choose(.mine)
                case .theirsThenMine: model.choose(.theirsThenMine); case .mineThenTheirs: model.choose(.mineThenTheirs)
                case .resolved: model.save(markResolved: true)
                case .find: (owner.window as? TextConflictNSWindow)?.find(.showFindInterface)
                case .showBase: model.showBase.toggle()
                case .whitespace: var next = model.whitespaceDisplay; next.visible.toggle(); model.setWhitespaceDisplay(next)
                case .wrap: model.setWrapLines(!model.wrapLines)
                case .inline: model.setInlineDiff(!model.showInlineDiff)
                case .inlineWord: model.setInlineWordDiff(!model.inlineWordDiff)
                case .collapsed: model.setCollapsed(!model.folding.collapsed)
                case .help: owner.showEditorHelp()
                default: break
                }
            })
    }
}
