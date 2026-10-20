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
        // A replacement may inherit a hidden toolbar. Set that state before
        // attachment, rather than attach-visible then start a hide transition
        // on the native frame that is about to receive another toolbar owner.
        applyingVisibility = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0;context.allowsImplicitAnimation = false
            if show && window.toolbar !== toolbar {
                toolbar.isVisible = toolbarShown();window.toolbar = toolbar;installed(true)
            } else if !show && window.toolbar === toolbar { window.toolbar = nil;installed(false) }
            if show,window.toolbar === toolbar,toolbar.isVisible != toolbarShown() { toolbar.isVisible = toolbarShown() }
        }
        applyingVisibility = false
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
    func commandState(_ command: MergeToolbarCommand) -> MergeToolbarState? {
        guard !retired,window?.toolbar === toolbar,visible() else { return nil }
        return states(command)
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
        guard let window = owner.window else { return nil }
        return conflict(model:owner.model,window:window,ownerReady:{ [weak owner] in owner != nil && owner?.editorOpenWorkflow == nil && owner?.preparingReplacement == false },open:{ [weak owner] in owner?.openMergeDocument(nil) },reload:{ [weak owner] in owner?.reloadEditor(nil) },help:{ [weak owner] in owner?.showEditorHelp() })
    }
    static func conflict(model:TextConflictWindowModel,window:NSWindow,ownerReady:@escaping ()->Bool,open:@escaping ()->Void,reload:@escaping ()->Void,help:@escaping ()->Void) -> MergeEditorToolbar {
        let commands: [MergeToolbarCommand] = [.open, .save, .saveAs, .reload, .undo, .redo, .previousDifference, .nextDifference, .previousConflict, .nextConflict, .useTheirs, .useMine, .theirsThenMine, .mineThenTheirs, .resolved, .whitespace, .wrap, .inline, .inlineWord, .collapsed, .find, .compareSources, .showBase, .help]
        return MergeEditorToolbar(window: window, identifier: "TurtleGit.Merge.Conflict", commands: commands,
            defaults: [.open, .save, .saveAs, .reload, .undo, .redo, .previousDifference, .nextDifference, .previousConflict, .nextConflict, .useTheirs, .useMine, .theirsThenMine, .mineThenTheirs, .resolved, .wrap, .find, .compareSources, .showBase, .help],
            menus: [.saveAs: [.saveLeft, .saveRight, .saveMerged, .continueResolving], .compareSources: [.compareTheirs, .compareMine]],
            changes: model.objectWillChange, preferences: model.comparisonDefaults,
            visible: { [weak model] in model?.retired == false }, toolbarShown:{ [weak model] in model?.showToolbar == true }, changedVisibility:{ [weak model] in model?.setToolbarVisible($0) }, installed: { [weak model] installed in if model?.nativeToolbarInstalled != installed { model?.nativeToolbarInstalled = installed } },
            state: { [weak model] command in
                guard let model else { return nil }
                let ready = !model.retired && !model.busy && !model.preparing && !model.exportingSource && !model.formatPending && !model.confirmingQuit && !model.externalReloadBlocksCommands && !model.preservingSourceCopies && window.attachedSheet == nil && ownerReady()
                let text = ready && model.sourceToolsAllowed
                switch command {
                case .open, .reload, .help: return .init(enabled: ready)
                case .save: return .init(enabled: text && model.sourceMutationsAllowed && !model.patchResultCompleted)
                case .saveAs, .saveLeft, .saveRight, .saveMerged: return .init(enabled: text && model.sourceMutationsAllowed)
                case .compareSources, .compareTheirs, .compareMine: return .init(enabled: text)
                case .continueResolving: return .init(enabled: text && !model.blocks.isEmpty)
                case .undo: return .init(enabled: text && model.sourceMutationsAllowed && model.canUndo)
                case .redo: return .init(enabled: text && model.sourceMutationsAllowed && model.canRedo)
                case .previousDifference: return .init(enabled: text && model.canNavigateBlock(-1,conflictsOnly:false))
                case .nextDifference: return .init(enabled: text && model.canNavigateBlock(1,conflictsOnly:false))
                case .previousConflict: return .init(enabled: text && model.canNavigateBlock(-1,conflictsOnly:true))
                case .nextConflict: return .init(enabled: text && model.canNavigateBlock(1,conflictsOnly:true))
                case .useTheirs, .useMine, .theirsThenMine, .mineThenTheirs: return .init(enabled: text && model.canChooseConflict)
                case .resolved: return .init(enabled: text && model.repositoryResolutionAllowed && !model.hasUnresolvedConflicts)
                case .find: return .init(enabled: text)
                case .showBase: return .init(enabled: text, checked: model.showBase)
                case .whitespace: return .init(enabled: text, checked: model.whitespaceDisplay.visible)
                case .wrap: return .init(enabled: text, checked: model.wrapLines)
                case .inline: return .init(enabled: text && model.sourceComparison != nil, checked: model.showInlineDiff)
                case .inlineWord: return .init(enabled: text && model.sourceComparison != nil && model.showInlineDiff, checked: model.inlineWordDiff)
                case .collapsed: return .init(enabled: text, checked: model.folding.collapsed)
                default: return nil
                }
            }, action: { [weak model] command in
                guard let model else { return }
                switch command {
                case .open: open(); case .reload: reload()
                case .save: model.saveRetainedEditorWork()
                case .saveLeft: model.exportSource(mine: false); case .saveRight: model.exportSource(mine: true)
                case .saveMerged: model.export(); case .continueResolving: model.continueResolving()
                case .compareTheirs: model.compareSourceWithBase(mine: false); case .compareMine: model.compareSourceWithBase(mine: true)
                case .undo: model.undo(); case .redo: model.redo()
                case .previousDifference: model.navigateBlock(-1,conflictsOnly:false); case .nextDifference: model.navigateBlock(1,conflictsOnly:false)
                case .previousConflict: model.navigateBlock(-1,conflictsOnly:true); case .nextConflict: model.navigateBlock(1,conflictsOnly:true)
                case .useTheirs: model.choose(.theirs); case .useMine: model.choose(.mine)
                case .theirsThenMine: model.choose(.theirsThenMine); case .mineThenTheirs: model.choose(.mineThenTheirs)
                case .resolved: model.save(markResolved: true)
                case .find: (window as? TextConflictNSWindow)?.find(.showFindInterface)
                case .showBase: model.showBase.toggle()
                case .whitespace: var next = model.whitespaceDisplay; next.visible.toggle(); model.setWhitespaceDisplay(next)
                case .wrap: model.setWrapLines(!model.wrapLines)
                case .inline: model.setInlineDiff(!model.showInlineDiff)
                case .inlineWord: model.setInlineWordDiff(!model.inlineWordDiff)
                case .collapsed: model.setCollapsed(!model.folding.collapsed)
                case .help: help()
                default: break
                }
            })
    }
}

/// Native menu contributions have a focus lifetime independent of the editor.
/// A previously retained item never becomes live again on a later focus cycle.
@MainActor final class MergeEditorCommandMenu: NSObject, NSMenuItemValidation {
    enum Command: Hashable {
        case toolbar(MergeToolbarCommand), saveAs, enableEdit, useFile, useBothFirst, useBothLast
        case nextInline, previousInline, nextPane, previousPane, gotoLine, findNext, findPrevious, findSelectionNext, findSelectionPrevious, clearSearch
        case patchPreview, patchSelected, patchAll, patchFileList, patchKeepCurrent, patchUsePatched
        case overwrite, cycleEnding, markBlock
        case toolbarVisible, statusVisible, lineDiff, lineNumbers, moved, locator, fishEye
        case whitespace(MergeWhitespaceComparison), ignoreEndings, ignoreCase, ignoreComments
        case regex(String?), configureRegex, settings, about
    }
    private final class Invocation {
        let command: Command, epoch: UUID
        init(_ command: Command, _ epoch: UUID) { self.command = command;self.epoch = epoch }
    }
    private weak var window: NSWindow?
    private weak var mainMenu: NSMenu?
    private var contributed: [NSMenuItem] = [], createdRoots: [NSMenuItem] = []
    private var epoch = UUID(), retired = false, queued = false
    private var renderedFilterNames: [String]?
    private var observation: AnyCancellable?
    private var lifetimeObservations: [AnyCancellable] = []
    private var trackedMenus = Set<ObjectIdentifier>()
    private var synchronizing = false, synchronizationQueued = false
    var applicationMenu: () -> NSMenu? = { NSApp.mainMenu }
    private var available: () -> Bool
    private var state: (Command) -> MergeToolbarState?
    private var action: (Command) -> Void
    private let conflict: Bool
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    init(window: NSWindow, conflict: Bool, changes: ObservableObjectPublisher, available: @escaping () -> Bool,
         state: @escaping (Command) -> MergeToolbarState?, action: @escaping (Command) -> Void) {
        self.window = window;self.conflict = conflict;self.available = available;self.state = state;self.action = action
        super.init()
        observation = changes.sink { [weak self] _ in
            guard let self,!self.queued,!self.retired else { return };self.queued = true
            DispatchQueue.main.async { [weak self] in guard let self else { return };self.queued = false;self.refresh() }
        }
        lifetimeObservations.append(NotificationCenter.default.publisher(for:NSApplication.didUpdateNotification).sink { [weak self] _ in self?.scheduleSynchronizationIfNeeded() })
        lifetimeObservations.append(NotificationCenter.default.publisher(for:NSMenu.didBeginTrackingNotification).sink { [weak self] note in
            guard let self,let menu = note.object as? NSMenu,self.belongsToApplicationMenu(menu) else { return }
            self.trackedMenus.insert(ObjectIdentifier(menu))
        })
        lifetimeObservations.append(NotificationCenter.default.publisher(for:NSMenu.didEndTrackingNotification).sink { [weak self] note in
            guard let self,let menu = note.object as? NSMenu else { return }
            self.trackedMenus.remove(ObjectIdentifier(menu));self.scheduleSynchronizationIfNeeded()
            if self.trackedMenus.isEmpty {self.scheduleStateRefresh()}
        })
    }
    private func scheduleStateRefresh() {
        guard !retired,!queued else {return};queued = true
        DispatchQueue.main.async { [weak self] in guard let self else {return};self.queued = false;self.refresh() }
    }
    private var active: Bool {
        guard !retired,let window,let mainMenu else { return false }
        return mainMenu === applicationMenu() && keyWindow() === window && available()
    }
    private func belongsToApplicationMenu(_ candidate:NSMenu) -> Bool {
        guard let mainMenu else { return false }
        var current:NSMenu? = candidate,seen = Set<ObjectIdentifier>()
        while let menu = current,seen.insert(ObjectIdentifier(menu)).inserted {
            if menu === mainMenu { return true };current = menu.supermenu
        }
        return false
    }
    private func attached(_ item:NSMenuItem) -> Bool { item.menu.map(belongsToApplicationMenu) ?? false }
    private var needsSynchronization: Bool {
        guard !retired,let window,keyWindow() === window,available(),let current = applicationMenu() else { return false }
        return mainMenu !== current || contributed.isEmpty || contributed.contains { !attached($0) }
    }
    private func scheduleSynchronizationIfNeeded() {
        guard needsSynchronization,trackedMenus.isEmpty,!synchronizationQueued,!synchronizing else { return }
        synchronizationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return };self.synchronizationQueued = false;self.synchronize()
        }
    }
    func synchronize() {
        guard needsSynchronization,trackedMenus.isEmpty,!synchronizing else { return }
        synchronizing = true;defer { synchronizing = false }
        install(in:applicationMenu())
    }
    func install(in main: NSMenu? = nil) {
        remove()
        guard !retired,let window,available(),keyWindow() === window,let main = main ?? applicationMenu() else { return }
        mainMenu = main
        append([.toolbar(.open),.toolbar(.save),.saveAs,.toolbar(.resolved),.toolbar(.patch),.toolbar(.reload),.enableEdit],to:root("File",in:main))
        append([.useFile,.toolbar(conflict ? .useTheirs : .useLeft),.toolbar(.useMine),.useBothFirst,.useBothLast,
                .toolbar(.theirsThenMine),.toolbar(.mineThenTheirs),.toolbar(.find),.findNext,.findPrevious,.findSelectionNext,.findSelectionPrevious,.clearSearch,.gotoLine,.overwrite,.cycleEnding,.markBlock,.patchPreview,.patchAll,.patchSelected,.patchKeepCurrent,.patchUsePatched],to:root("Edit",in:main))
        append([.toolbar(.nextDifference),.toolbar(.previousDifference),.toolbar(.nextConflict),.toolbar(.previousConflict),.nextInline,.previousInline,.nextPane,.previousPane],to:root("Navigate",in:main))
        let view = root("View",in:main)
        append([.toolbarVisible,.statusVisible,.lineDiff,.locator,.fishEye,.toolbar(.wrap),.moved,.toolbar(.inline),.toolbar(.inlineWord),
                .whitespace(.compare),.whitespace(.ignoreChanges),.whitespace(.ignoreAll),.ignoreEndings,.ignoreCase,.ignoreComments,
                .toolbar(.whitespace),.lineNumbers,.toolbar(.onePane),.toolbar(.switchSides),.toolbar(.collapsed),.toolbar(.showBase),.patchFileList,.settings],to:view)
        if state(.regex(nil)) != nil || state(.configureRegex) != nil {
        let filters = NSMenuItem(title:"Filter Regexes",action:nil,keyEquivalent:"")
        filters.submenu = NSMenu(title:"Filter Regexes");view.addItem(filters);contributed.append(filters)
        rebuildFilters(filters.submenu!)
        }
        append([.toolbar(.help),.about],to:root("Help",in:main))
        for item in createdRoots where item.submenu?.items.isEmpty == true { main.removeItem(item) }
        createdRoots.removeAll { $0.submenu?.items.isEmpty == true }
        refresh()
    }
    /// Framework-owned roots are localized by macOS, independently from the
    /// application's translation catalog. Identify their role, never an English
    /// spelling (nor a table of translated spellings). Our IDs are assigned only
    /// to roots which do not already carry a framework identifier.
    private enum RootRole: String, CaseIterable {
        case file = "File", edit = "Edit", navigate = "Navigate", view = "View", window = "Window", help = "Help"
        var identifier: NSUserInterfaceItemIdentifier { .init("org.turtlegit.merge.menu." + rawValue.lowercased()) }
        var order: Int { Self.allCases.firstIndex(of: self)! }
    }
    private func hasRole(_ role: RootRole, item: NSMenuItem) -> Bool {
        guard let menu = item.submenu else { return false }
        if item.identifier == role.identifier { return true }
        if role == .window, menu === NSApp.windowsMenu { return true }
        if role == .help, menu === NSApp.helpMenu { return true }
        let selectors: Set<String>
        switch role {
        case .file: selectors = ["openDocument:", "saveDocument:", "saveDocumentAs:", "saveAllDocuments:", "performClose:"]
        case .edit: selectors = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"]
        case .view: selectors = ["toggleToolbarShown:", "toggleFullScreen:", "toggleSidebar:"]
        case .window: selectors = ["performMiniaturize:", "arrangeInFront:", "performZoom:"]
        case .help: selectors = ["showHelp:"]
        case .navigate: selectors = []
        }
        return menu.items.contains { command in
            if let action = command.action, selectors.contains(NSStringFromSelector(action)) { return true }
            let flags = command.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
            let key = command.keyEquivalent.lowercased()
            switch role {
            case .file:
                // SwiftUI uses private action targets, but the application owns
                // these standard File bindings, including standalone Save All.
                return ["o", "w", "s"].contains(key) && flags.contains(.command) && !flags.contains(.control)
            case .edit: return ["x", "c", "v", "a", "z"].contains(key) && flags == .command
            case .window: return key == "m" && flags == .command
            case .help: return key == "?" && flags == .command || key == "/" && flags == [.command, .shift]
            case .view, .navigate: return false
            }
        }
    }
    private func standardScaffoldRoot(_ role: RootRole, in main: NSMenu) -> NSMenuItem? {
        guard [.file, .edit, .view].contains(role),
              let windowsMenu = NSApp.windowsMenu, let helpMenu = NSApp.helpMenu,
              let applicationIndex = main.items.firstIndex(where: { root in root.submenu?.items.contains(where: { command in
                  command.action.map(NSStringFromSelector) == "terminate:" || command.keyEquivalent.lowercased() == "q" && command.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == .command
              }) == true }),
              let windowIndex = main.items.firstIndex(where: { $0.submenu === windowsMenu }),
              applicationIndex < windowIndex,
              main.items.contains(where: { $0.submenu === helpMenu }) else { return nil }
        // Both concrete App declarations retain the standard macOS scaffold:
        // App, File, Edit, View, custom commands, Window, Help. This narrowly
        // handles an empty/default SwiftUI root with no responder actions. It
        // does not interpret arbitrary foreign menus by their translated title.
        let standard = main.items[(applicationIndex + 1)..<windowIndex].filter {
            $0.submenu != nil && $0.identifier != RootRole.navigate.identifier
        }
        guard standard.count >= 3 else { return nil }
        return standard[role == .file ? 0 : role == .edit ? 1 : 2]
    }
    private func rootItem(_ role: RootRole, in main: NSMenu) -> NSMenuItem? {
        let found = main.items.first(where: { $0.identifier == role.identifier }) ??
            main.items.first(where: { hasRole(role, item: $0) }) ??
            standardScaffoldRoot(role, in: main) ??
            main.items.first(where: { $0.title == role.rawValue && $0.submenu != nil })
        if let found, found.identifier == nil { found.identifier = role.identifier }
        return found
    }
    private func root(_ name: String, in main: NSMenu) -> NSMenu {
        let role = RootRole(rawValue: name)!
        if let found = rootItem(role, in: main)?.submenu { return found }
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.identifier = role.identifier; item.submenu = NSMenu(title: name)
        let following = RootRole.allCases.filter { $0.order > role.order }.compactMap { rootItem($0, in: main) }
        let index = following.compactMap { main.items.firstIndex(of: $0) }.min() ?? main.items.count
        main.insertItem(item, at: index); createdRoots.append(item); return item.submenu!
    }
    private func append(_ commands: [Command], to menu: NSMenu) {
        let supported = commands.filter { state($0) != nil }
        guard !supported.isEmpty else { return }
        if !menu.items.isEmpty { let divider = NSMenuItem.separator();menu.addItem(divider);contributed.append(divider) }
        for command in supported { let item = makeItem(command);menu.addItem(item);contributed.append(item) }
    }
    private func makeItem(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title:title(command),action:#selector(invokeEditorMenu(_:)),keyEquivalent:"")
        item.target = self;item.representedObject = Invocation(command,epoch);item.image = icon(command)?.image()
        if let shortcut = shortcut(command) { item.keyEquivalent = shortcut.0;item.keyEquivalentModifierMask = shortcut.1 }
        update(item);return item
    }
    private func rebuildFilters(_ menu: NSMenu) {
        menu.removeAllItems()
        let definitions = filterNames();renderedFilterNames = definitions
        for command in [.regex(nil)] + definitions.map({Command.regex($0)}) + [.configureRegex] { menu.addItem(makeItem(command)) }
    }
    var filterNames: () -> [String] = { [] }
    private func update(_ item: NSMenuItem) {
        guard let invocation = item.representedObject as? Invocation else { return }
        let value = state(invocation.command)
        item.isEnabled = active && attached(item) && invocation.epoch == epoch && value?.enabled == true
        item.state = value?.checked == true ? .on : .off
    }
    func refresh() {
        guard !retired else { return }
        if !available() { remove();return }
        scheduleSynchronizationIfNeeded()
        for item in contributed {
            if item.title == "Filter Regexes",let submenu = item.submenu {
                if renderedFilterNames != filterNames(),trackedMenus.isEmpty { rebuildFilters(submenu) }
                for child in submenu.items { update(child) }
            }
            else { update(item) }
        }
    }
    func remove() {
        epoch = UUID()
        func disable(_ item: NSMenuItem) { item.isEnabled = false;for child in item.submenu?.items ?? [] { disable(child) } }
        for item in contributed { disable(item);item.menu?.removeItem(item) }
        if let mainMenu { for item in createdRoots where item.submenu?.items.isEmpty == true && mainMenu.items.contains(item) { mainMenu.removeItem(item) } }
        mainMenu = nil;contributed = [];createdRoots = [];renderedFilterNames = nil;trackedMenus.removeAll()
    }
    func retire() { remove();retired = true;observation = nil;lifetimeObservations = [];available = {false};state = {_ in nil};action = {_ in};filterNames = {[]};applicationMenu = {nil};keyWindow = {nil} }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { update(item);return item.isEnabled }
    @objc private func invokeEditorMenu(_ item: NSMenuItem) {
        guard active,attached(item),let invocation = item.representedObject as? Invocation,invocation.epoch == epoch,state(invocation.command)?.enabled == true else { return }
        action(invocation.command);refresh()
    }
    func performKeyEquivalent(_ event: NSEvent) -> Bool {
        synchronize()
        guard active,(window?.firstResponder as? NSTextView)?.isFieldEditor != true else { return false }
        let modifiers = event.modifierFlags.intersection([.command,.control,.option,.shift])
        guard let text = event.charactersIgnoringModifiers?.lowercased() else { return false }
        for item in contributed {
            guard attached(item),let invocation = item.representedObject as? Invocation else { continue }
            let bindings = shortcut(invocation.command).map{[$0]} ?? []
            guard (bindings + aliases(invocation.command)).contains(where:{$0.0.lowercased() == text && $0.1 == modifiers}) else { continue }
            guard state(invocation.command)?.enabled == true else { return false }
            invokeEditorMenu(item);return true
        }
        return false
    }
    private func aliases(_ command:Command) -> [(String,NSEvent.ModifierFlags)] {
        func key(_ value:Int) -> String {String(UnicodeScalar(value)!)}
        switch command {
        case .toolbar(.nextDifference):return [(key(NSF11FunctionKey),[]),(key(NSDownArrowFunctionKey),.control),(key(NSDownArrowFunctionKey),.option)]
        case .toolbar(.previousDifference):return [(key(NSF11FunctionKey),.shift),(key(NSF11FunctionKey),.control),(key(NSUpArrowFunctionKey),.control),(key(NSUpArrowFunctionKey),.option)]
        case .toolbar(.useLeft):return [(key(NSRightArrowFunctionKey),.option)]
        case .toolbar(.useMine):return [(key(NSF12FunctionKey),.shift)]
        case .toolbar(.reload):return [("r",.control),("r",.command)]
        case .findNext:return [(key(NSF3FunctionKey),[])]
        case .findPrevious:return [(key(NSF3FunctionKey),.shift)]
        case .findSelectionNext:return [(key(NSF3FunctionKey),.control)]
        case .findSelectionPrevious:return [(key(NSF3FunctionKey),[.control,.shift])]
        case .cycleEnding:return [("\n",.control)]
        default:return []
        }
    }
    private func title(_ command: Command) -> String {
        switch command {
        case .toolbar(.help):return "TurtleGitMerge Help"
        case .toolbar(let value):return value.title
        case .saveAs:return "Save As…";case .enableEdit:return "Enable editing"
        case .patchKeepCurrent:return "Keep current file state";case .patchUsePatched:return "Use patched file state"
        case .patchPreview:return "Preview patched file";case .patchSelected:return "Patch selected files";case .patchAll:return "Patch all files";case .patchFileList:return "Patch file list"
        case .overwrite:return "Overwrite mode";case .cycleEnding:return "Cycle current line ending";case .markBlock:return "Mark block"
        case .useFile:return "Use left file";case .useBothFirst:return "Use block from left before right";case .useBothLast:return "Use block from right before left"
        case .nextInline:return "Next inline difference";case .previousInline:return "Previous inline difference"
        case .nextPane:return "Next pane";case .previousPane:return "Previous pane";case .gotoLine:return "Go to Line…"
        case .findNext:return "Find Next";case .findPrevious:return "Find Previous"
        case .findSelectionNext:return "Find Next Selected Text";case .findSelectionPrevious:return "Find Previous Selected Text";case .clearSearch:return "Clear Search Highlights"
        case .toolbarVisible:return "Toolbar";case .statusVisible:return "Status Bar";case .lineDiff:return "Line diff bar";case .lineNumbers:return "Line numbers"
        case .moved:return "Moved blocks";case .locator:return "Locator bar";case .fishEye:return "Use fish-eye in locator bar"
        case .whitespace(let value):return value.title;case .ignoreEndings:return "Ignore line endings";case .ignoreCase:return "Ignore case changes";case .ignoreComments:return "Ignore Comments"
        case .regex(let name):return name ?? "No Filter";case .configureRegex:return "Configure Filter Regexes…"
        case .settings:return "Merge Editor Settings…";case .about:return "About TurtleGitMerge…"
        }
    }
    private func icon(_ command: Command) -> MenuIcon? {
        switch command {
        case .toolbar(let value):return value.icon
        case .patchKeepCurrent:return .mergeUseMine;case .patchUsePatched:return .mergeUseTheirs
        case .patchPreview:return .compare;case .patchSelected,.patchAll,.patchFileList:return .patch
        case .overwrite:return .editor;case .cycleEnding:return .compare;case .markBlock:return .mergeMarked
        case .saveAs:return .mergeSaveAs;case .enableEdit:return .editor;case .useFile:return .mergeUseTheirs
        case .useBothFirst:return .mergeTheirsThenMine;case .useBothLast:return .mergeMineThenTheirs
        case .nextInline:return .mergeNextInline;case .previousInline:return .mergePreviousInline
        case .findNext,.findPrevious,.gotoLine,.clearSearch:return .mergeFind
        case .findSelectionNext:return .jumpDown;case .findSelectionPrevious:return .jumpUp
        case .settings,.configureRegex:return .settings;case .about:return .merge
        case .moved:return .mergeMoved;case .whitespace,.ignoreComments,.ignoreEndings,.ignoreCase:return .compare
        default:return nil
        }
    }
    private func shortcut(_ command: Command) -> (String,NSEvent.ModifierFlags)? {
        func key(_ scalar: Int) -> String { String(UnicodeScalar(scalar)!) }
        switch command {
        case .toolbar(.open):return ("o",.command);case .toolbar(.reload):return (key(NSF5FunctionKey),[])
        case .toolbar(.save):return ("s",.command);case .saveAs:return ("s",[.command,.shift])
        case .toolbar(.find):return ("f",.command);case .findNext:return ("g",.command);case .findPrevious:return ("g",[.command,.shift])
        case .findSelectionNext:return ("g",[.command,.option]);case .findSelectionPrevious:return ("g",[.command,.option,.shift])
        case .toolbar(.useLeft):return (key(NSF12FunctionKey),[])
        case .toolbar(.useTheirs):return (key(NSF9FunctionKey),.control)
        case .toolbar(.useMine):return (key(NSF10FunctionKey),.control)
        case .toolbar(.theirsThenMine):return (key(NSF9FunctionKey),[.control,.shift])
        case .toolbar(.mineThenTheirs):return (key(NSF10FunctionKey),[.control,.shift])
        case .patchKeepCurrent:return (key(NSF10FunctionKey),.control);case .patchUsePatched:return (key(NSF9FunctionKey),.control)
        case .overwrite:return (key(NSInsertFunctionKey),[]);case .cycleEnding:return ("\r",.control);case .markBlock:return ("m",.control)
        case .gotoLine:return ("g",.control);case .nextPane:return (key(NSF6FunctionKey),[]);case .previousPane:return (key(NSF6FunctionKey),.shift)
        case .toolbar(.nextDifference):return (key(NSF7FunctionKey),[]);case .toolbar(.previousDifference):return (key(NSF7FunctionKey),.shift)
        case .toolbar(.nextConflict):return (key(NSF8FunctionKey),[]);case .toolbar(.previousConflict):return (key(NSF8FunctionKey),.shift)
        case .nextInline:return (key(NSRightArrowFunctionKey),[.control,.option]);case .previousInline:return (key(NSLeftArrowFunctionKey),[.control,.option])
        case .toolbar(.wrap):return ("p",.control);case .toolbar(.whitespace):return ("t",.control)
        case .toolbar(.onePane):return ("d",.control);case .toolbar(.switchSides):return ("u",.control)
        case .toolbar(.collapsed):return ("l",.control);case .enableEdit:return ("e",.control)
        default:return nil
        }
    }
    static func cycle(window: NSWindow, forward: Bool) {
        let panes = MergeMarkedWordInterface.panes(in:window.contentView).filter{!$0.isHiddenOrHasHiddenAncestor && $0.window === window}
        guard panes.count > 1 else { return }
        let current = panes.firstIndex(where:{$0 === window.firstResponder}) ?? (forward ? -1 : 0)
        let next = panes[(current + (forward ? 1 : panes.count - 1)) % panes.count]
        (next as? MergeLineNavigationProviding)?.beginUserNavigation();window.makeFirstResponder(next);next.setAccessibilityFocused(true)
    }
}

extension MergeEditorCommandMenu {
    static func comparison(_ owner: FileComparisonWindowController) -> MergeEditorCommandMenu? {
        guard let window = owner.window else { return nil }
        let model = owner.model, bar = owner.editorToolbar
        let ready = { [weak owner,weak window] in
            guard let owner,let window else { return false }
            return owner.window === window && window.attachedSheet == nil && owner.model.contextCommandsAllowed && !owner.model.filtering && owner.editorOpenWorkflow == nil && !owner.preparingReplacement && (window.firstResponder as? NSTextView)?.isFieldEditor != true
        }
        let text = { [weak model] in model?.activeFindText }
        let menu = MergeEditorCommandMenu(window:window,conflict:false,changes:model.objectWillChange,
            available:{ [weak owner,weak window] in owner?.window === window && owner?.model.imageComparison == nil },
            state:{ [weak model,weak bar,weak window] command in
                guard let model else { return nil };let enabled = ready(),document = enabled && model.alignment != nil
                switch command {
                case .toolbar(let value):
                    guard let state = bar?.commandState(value) else { return nil }
                    return .init(enabled:enabled && state.enabled,checked:state.checked)
                case .saveAs:return .init(enabled:enabled && model.canSavePaneAs)
                case .enableEdit:return .init(enabled:document && model.editableBase != nil,checked:model.editingEnabled)
                case .useFile:return .init(enabled:document && model.oppositeViewCommandsAllowed && model.canTransfer(toBase:false))
                case .useBothFirst,.useBothLast:return .init(enabled:document && model.oppositeViewCommandsAllowed && model.canTransfer(toBase:false) && model.transferRows != nil)
                case .nextInline,.previousInline:return .init(enabled:document && model.canNavigateInline(forward:command == .nextInline))
                case .nextPane,.previousPane:return .init(enabled:document && MergeMarkedWordInterface.panes(in:window?.contentView).filter{!$0.isHiddenOrHasHiddenAncestor}.count > 1)
                case .overwrite:return .init(enabled:document && (text() as? MergeTypingProviding)?.mergeTypingAllowed == true,checked:(text() as? MergeTypingProviding)?.mergeOverwrite == true)
                case .cycleEnding:return .init(enabled:document && (text() as? MergeTypingProviding)?.canCycleCurrentEnding == true)
                case .markBlock:return .init(enabled:document && !model.onePaneActive && model.canTransfer(toBase:false) && model.transferRows != nil,checked:model.transferRows.map { model.annotations(base:false).marked.contains($0.lowerBound) } == true)
                case .gotoLine:return .init(enabled:document && (text() as? (NSTextView & MergeLineNavigationProviding))?.canNavigateToSourceLine == true)
                case .findNext,.findPrevious:return .init(enabled:document && (text() as? MergeFindProviding)?.mergeFindHighlights.query.isEmpty == false)
                case .findSelectionNext,.findSelectionPrevious:return .init(enabled:document && (text() as? MergeFindProviding)?.mergeFindAllowed == true)
                case .clearSearch:return .init(enabled:document && (text() as? MergeFindProviding)?.mergeFindHighlights.query.isEmpty == false)
                case .toolbarVisible:return .init(enabled:enabled,checked:model.showToolbar)
                case .statusVisible:return .init(enabled:enabled,checked:model.showStatusBar)
                case .lineDiff:return .init(enabled:document && !model.onePaneActive && !model.singleFileMode,checked:model.showLineDiffBar)
                case .lineNumbers:return .init(enabled:document,checked:model.showLineNumbers)
                case .moved:return .init(enabled:enabled && model.canChangeMovedBlocks,checked:model.showMovedBlocks)
                case .locator:return .init(enabled:document,checked:model.locatorPreferences.visible)
                case .fishEye:return .init(enabled:document && model.locatorPreferences.visible,checked:model.locatorPreferences.fishEye)
                case .whitespace(let value):return .init(enabled:document,checked:model.comparisonOptions.whitespace == value)
                case .ignoreEndings:return .init(enabled:document,checked:model.comparisonOptions.ignoreEndings)
                case .ignoreCase:return .init(enabled:document,checked:model.comparisonOptions.ignoreCase)
                case .ignoreComments:return .init(enabled:document && model.supportsComments,checked:model.comparisonOptions.ignoreComments)
                case .regex(let name):return .init(enabled:document && (name == nil || model.regexFilters.contains{$0.name == name}),checked:model.regexFilterName == name)
                case .patchPreview,.patchSelected,.patchAll,.patchFileList,.patchKeepCurrent,.patchUsePatched:return nil
                case .configureRegex,.settings,.about:return .init(enabled:enabled)
                }
            },action:{ [weak owner,weak model,weak bar,weak window] command in
                guard let model,ready() else { return }
                switch command {
                case .toolbar(let value):bar?.perform(value)
                case .saveAs:model.saveAs(base:model.activeBase)
                case .enableEdit:model.editingEnabled.toggle()
                case .markBlock:
                    if let view = text() {model.updateSelection(view.selectedRange(),cells:model.displayCells(base:model.activeBase))}
                    if let first = model.transferRows?.lowerBound {model.markBlock(!model.annotations(base:false).marked.contains(first),targetBase:false)}
                case .useFile:model.useOtherFile(targetBase:false)
                case .useBothFirst:model.useOtherBlock(.otherThenCurrent,targetBase:false)
                case .useBothLast:model.useOtherBlock(.currentThenOther,targetBase:false)
                case .nextInline,.previousInline:model.navigateInline(forward:command == .nextInline)
                case .nextPane,.previousPane:if let window { cycle(window:window,forward:command == .nextPane) }
                case .overwrite:(text() as? MergeTypingProviding)?.toggleMergeOverwrite()
                case .cycleEnding:(text() as? MergeTypingProviding)?.cycleCurrentEnding()
                case .gotoLine:(text() as? (NSTextView & MergeLineNavigationProviding))?.navigateToSourceLine()
                case .findNext,.findPrevious:model.find(command == .findNext ? .nextMatch : .previousMatch)
                case .findSelectionNext,.findSelectionPrevious:if let text = text() {MergeFindInterface.selection(upwards:command == .findSelectionPrevious,in:text)}
                case .clearSearch:text()?.turtleClearFindHighlights(nil)
                case .toolbarVisible:model.setToolbarVisible(!model.showToolbar)
                case .statusVisible:model.setStatusBarVisible(!model.showStatusBar)
                case .lineDiff:model.showLineDiffBar.toggle()
                case .lineNumbers:model.showLineNumbers.toggle()
                case .moved:model.setMovedBlocks(!model.showMovedBlocks)
                case .locator:var value = model.locatorPreferences;value.visible.toggle();model.setLocatorPreferences(value)
                case .fishEye:var value = model.locatorPreferences;value.fishEye.toggle();model.setLocatorPreferences(value)
                case .whitespace(let value):var options = model.comparisonOptions;options.whitespace = value;model.setComparisonOptions(options)
                case .ignoreEndings:var value = model.comparisonOptions;value.ignoreEndings.toggle();model.setComparisonOptions(value)
                case .ignoreCase:var value = model.comparisonOptions;value.ignoreCase.toggle();model.setComparisonOptions(value)
                case .ignoreComments:var value = model.comparisonOptions;value.ignoreComments.toggle();model.setComparisonOptions(value)
                case .regex(let name):model.selectRegexFilter(name)
                case .configureRegex:model.manageRegexFilters()
                case .settings:SettingsPresentationService.shared.show(globalOnly:true,initialPage:.mergeEditor)
                case .about:TurtleGitAboutService.shared.show(.merge)
                case .patchPreview,.patchSelected,.patchAll,.patchFileList,.patchKeepCurrent,.patchUsePatched:break
                }
                withExtendedLifetime(owner) {}
            })
        menu.filterNames = { [weak model] in model?.regexFilters.map(\.name) ?? [] };return menu
    }
    static func conflict(_ owner: TextConflictWindowController) -> MergeEditorCommandMenu? {
        guard let window = owner.window else { return nil }
        let model = owner.model, bar = owner.editorToolbar
        let ready = { [weak owner,weak window] in
            guard let owner,let window else { return false }
            let model = owner.model
            return owner.window === window && model.sourceToolsAllowed && owner.editorOpenWorkflow == nil && !owner.preparingReplacement && (window.firstResponder as? NSTextView)?.isFieldEditor != true
        }
        let text = { [weak window] in (window as? TextConflictNSWindow)?.activeEditorText }
        let menu = MergeEditorCommandMenu(window:window,conflict:true,changes:model.objectWillChange,
            available:{ [weak owner,weak model,weak window] in owner?.window === window && model?.retired == false },
            state:{ [weak model,weak bar,weak window] command in
                guard let model else { return nil };let enabled = ready()
                switch command {
                case .toolbar(let value):guard let state = bar?.commandState(value) else { return nil };return .init(enabled:enabled && state.enabled,checked:state.checked)
                case .saveAs:return .init(enabled:enabled && model.sourceMutationsAllowed)
                case .enableEdit:return .init(enabled:false,checked:text()?.isEditable == true)
                case .useFile,.useBothFirst,.useBothLast,.nextInline,.previousInline,.moved:return nil
                case .lineDiff:return .init(enabled:enabled,checked:model.showLineDiffBar)
                case .lineNumbers:return .init(enabled:enabled,checked:model.showLineNumbers)
                case .nextPane,.previousPane:return .init(enabled:enabled && MergeMarkedWordInterface.panes(in:window?.contentView).filter{!$0.isHiddenOrHasHiddenAncestor}.count > 1)
                case .overwrite:return .init(enabled:enabled && (text() as? MergeTypingProviding)?.mergeTypingAllowed == true,checked:(text() as? MergeTypingProviding)?.mergeOverwrite == true)
                case .cycleEnding:return .init(enabled:enabled && (text() as? MergeTypingProviding)?.canCycleCurrentEnding == true)
                case .markBlock:return nil
                case .gotoLine:return .init(enabled:enabled && (text() as? (NSTextView & MergeLineNavigationProviding))?.canNavigateToSourceLine == true)
                case .findNext,.findPrevious:return .init(enabled:enabled && (text() as? MergeFindProviding)?.mergeFindHighlights.query.isEmpty == false)
                case .findSelectionNext,.findSelectionPrevious:return .init(enabled:enabled && (text() as? MergeFindProviding)?.mergeFindAllowed == true)
                case .clearSearch:return .init(enabled:enabled && (text() as? MergeFindProviding)?.mergeFindHighlights.query.isEmpty == false)
                case .toolbarVisible:return .init(enabled:enabled,checked:model.showToolbar)
                case .statusVisible:return .init(enabled:enabled,checked:model.showStatusBar)
                case .locator:return .init(enabled:enabled,checked:model.locatorPreferences.visible)
                case .fishEye:return .init(enabled:enabled && model.locatorPreferences.visible,checked:model.locatorPreferences.fishEye)
                case .whitespace(let value):return .init(enabled:enabled,checked:model.comparisonOptions.whitespace == value)
                case .ignoreEndings:return .init(enabled:enabled,checked:model.comparisonOptions.ignoreEndings)
                case .ignoreCase:return .init(enabled:enabled,checked:model.comparisonOptions.ignoreCase)
                case .ignoreComments:return .init(enabled:enabled && model.supportsComments,checked:model.comparisonOptions.ignoreComments)
                case .regex(let name):return .init(enabled:enabled && (name == nil || model.regexFilters.contains{$0.name == name}),checked:model.regexFilterName == name)
                case .patchPreview,.patchSelected,.patchAll,.patchFileList,.patchKeepCurrent,.patchUsePatched:return nil
                case .configureRegex,.settings,.about:return .init(enabled:enabled)
                }
            },action:{ [weak model,weak bar,weak window] command in
                guard let model,ready() else { return }
                switch command {
                case .toolbar(let value):bar?.perform(value)
                case .saveAs:model.export()
                case .nextPane,.previousPane:if let window { cycle(window:window,forward:command == .nextPane) }
                case .overwrite:(text() as? MergeTypingProviding)?.toggleMergeOverwrite()
                case .cycleEnding:(text() as? MergeTypingProviding)?.cycleCurrentEnding()
                case .gotoLine:(text() as? (NSTextView & MergeLineNavigationProviding))?.navigateToSourceLine()
                case .findNext,.findPrevious:if let text = text() { MergeFindInterface.perform(command == .findNext ? .nextMatch : .previousMatch,in:text) }
                case .findSelectionNext,.findSelectionPrevious:if let text = text() {MergeFindInterface.selection(upwards:command == .findSelectionPrevious,in:text)}
                case .clearSearch:text()?.turtleClearFindHighlights(nil)
                case .lineDiff:model.setLineDiffBar(!model.showLineDiffBar)
                case .lineNumbers:model.setLineNumbers(!model.showLineNumbers)
                case .toolbarVisible:model.setToolbarVisible(!model.showToolbar)
                case .statusVisible:model.setStatusBarVisible(!model.showStatusBar)
                case .locator:var value = model.locatorPreferences;value.visible.toggle();model.setLocatorPreferences(value)
                case .fishEye:var value = model.locatorPreferences;value.fishEye.toggle();model.setLocatorPreferences(value)
                case .whitespace(let value):var options = model.comparisonOptions;options.whitespace = value;model.setComparisonOptions(options)
                case .ignoreEndings:var value = model.comparisonOptions;value.ignoreEndings.toggle();model.setComparisonOptions(value)
                case .ignoreCase:var value = model.comparisonOptions;value.ignoreCase.toggle();model.setComparisonOptions(value)
                case .ignoreComments:var value = model.comparisonOptions;value.ignoreComments.toggle();model.setComparisonOptions(value)
                case .regex(let name):model.selectRegexFilter(name)
                case .configureRegex:model.manageRegexFilters()
                case .settings:SettingsPresentationService.shared.show(globalOnly:true,initialPage:.mergeEditor)
                case .about:TurtleGitAboutService.shared.show(.merge)
                default:break
                }
            })
        menu.filterNames = { [weak model] in model?.regexFilters.map(\.name) ?? [] };return menu
    }
}


extension MergeEditorCommandMenu {
    static func patchReview(_ owner:WorkingTreePatchWindowController) -> MergeEditorCommandMenu? {
        guard let window = owner.window else {return nil}
        let model = owner.model
        let ready = { [weak owner,weak window] in owner?.commandsAvailable == true && owner?.activeOperation == false && window?.attachedSheet == nil && (window?.firstResponder as? NSTextView)?.isFieldEditor != true }
        return MergeEditorCommandMenu(window:window,conflict:false,changes:model.objectWillChange,
            available:{ [weak owner,weak model,weak window] in owner?.window === window && model?.retired == false },
            state:{ [weak owner,weak model] command in
                guard let model else {return nil};let enabled = ready()
                switch command {
                case .toolbar(.open),.toolbar(.reload),.toolbar(.help),.settings,.about:return .init(enabled:enabled)
                case .toolbar(.save):return .init(enabled:enabled && model.canSaveDraft)
                case .toolbar(.undo):return .init(enabled:enabled && model.canUndoPreview)
                case .toolbar(.redo):return .init(enabled:enabled && model.canRedoPreview)
                case .toolbar(.find):return .init(enabled:enabled && (model.alignment != nil || model.conflictEditor?.document != nil))
                case .toolbar(let value):guard let state = owner?.editorToolbar?.commandState(value) else {return nil};return .init(enabled:enabled && state.enabled,checked:state.checked)
                case .saveAs:return model.conflictEditor == nil ? nil : .init(enabled:enabled && model.conflictEditor?.sourceToolsAllowed == true)
                case .patchKeepCurrent,.patchUsePatched:return model.specialComparison == nil ? nil : .init(enabled:enabled && model.canResolveSpecial)
                case .patchPreview:return .init(enabled:enabled && model.canPreviewFiles(model.highlightedFiles,generation:model.fileListGeneration))
                case .patchAll:return .init(enabled:enabled && model.canPatchFiles)
                case .patchSelected:return .init(enabled:enabled && model.canPatchFiles && model.review?.files.contains(where:{model.highlightedFiles.contains($0.id) && !model.appliedPaths.contains($0.pathBytes)}) == true)
                case .patchFileList:return .init(enabled:enabled && model.canToggleFileList,checked:model.fileListVisible)
                default:return nil
                }
            },action:{ [weak owner,weak model] command in
                guard let owner,let model,ready() else {return}
                switch command {
                case .toolbar(.open):owner.openMergeDocument(nil)
                case .toolbar(.reload):owner.reloadEditor(nil)
                case .toolbar(.save):model.saveDraft()
                case .toolbar(.undo):model.undoPreview()
                case .toolbar(.redo):model.redoPreview()
                case .toolbar(.find):model.findComparison()
                case .toolbar(.help):TurtleGitHelp.show(.patches)
                case .settings:SettingsPresentationService.shared.show(globalOnly:true,initialPage:.mergeEditor)
                case .about:TurtleGitAboutService.shared.show(.merge)
                case .toolbar(let value):owner.editorToolbar?.perform(value)
                case .saveAs:model.conflictEditor?.export()
                case .patchKeepCurrent:model.resolveSpecial(.current)
                case .patchUsePatched:model.resolveSpecial(.patched)
                case .patchPreview:model.previewFiles(model.highlightedFiles,generation:model.fileListGeneration)
                case .patchAll:model.patchFiles(Set(model.review?.files.map(\.id) ?? []),generation:model.fileListGeneration)
                case .patchSelected:model.patchFiles(model.highlightedFiles,generation:model.fileListGeneration)
                case .patchFileList:model.toggleFileList()
                default:break
                }
            })
    }
}
