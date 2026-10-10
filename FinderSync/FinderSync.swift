import AppKit
import FinderSync
import TurtleGitCore

/// Finder never launches Git. Only the containing application scans repositories.
@objc(FinderSync) final class FinderSync: FIFinderSync {
    private var snapshot: FinderSnapshot?
    override init() {
        super.init()
        let controller = FIFinderSyncController.default()
        for state in FileState.allCases {
            guard let image = state.icon.image() else { continue }
            controller.setBadgeImage(image, label: state.rawValue.capitalized, forBadgeIdentifier: state.rawValue)
        }
        reload()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload), name: NSNotification.Name(FinderIntegration.notification), object: nil)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    @objc private func reload() {
        let old = snapshot
        snapshot = FinderSnapshot.read()
        let controller = FIFinderSyncController.default()
        controller.directoryURLs = Set((snapshot?.roots ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) })
        let paths = Set(old?.states.keys.map { $0 } ?? []).union(snapshot?.states.keys.map { $0 } ?? [])
        for path in paths where old?.states[path] != snapshot?.states[path] {
            controller.setBadgeIdentifier(snapshot?.states[path]?.rawValue ?? "", for: URL(fileURLWithPath: path))
        }
    }
    override func requestBadgeIdentifier(for url: URL) {
        FIFinderSyncController.default().setBadgeIdentifier(snapshot?.states[url.path]?.rawValue ?? "", for: url)
    }
    override var toolbarItemName: String { "TurtleGit" }
    override var toolbarItemToolTip: String { "TurtleGit for Mac" }
    override var toolbarItemImage: NSImage { MenuIcon.turtle.image() ?? NSImage() }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let targetURL = controller.targetedURL()
        let paths = FinderMenuBuilder.paths(kind: menuKind, selection: selection, target: targetURL)
        let creation = paths.count == 1 ? paths.first : nil
        return FinderMenuBuilder.make(paths: paths, snapshot: snapshot,
            settings: FinderMenuSettings.read(), comparisonMark: try? WorkingComparisonMarkSnapshot.read(),
            target: self, actionSelector: #selector(openAction(_:)), creationDirectory: creation,
            extended: NSEvent.modifierFlags.contains(.shift), toolbar: menuKind == .toolbarItemMenu)
    }
    @objc private func openAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? FinderMenuCommand,
              let url = command.url(control: NSEvent.modifierFlags.contains(.control)) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Builds the same menu used by the extension without requiring a live Finder controller.
final class FinderMenuCommand: NSObject {
    let request: FinderRequest
    init(action: RepositoryAction, paths: [URL]) { request = FinderRequest(action: action, paths: paths) }
    func url(control: Bool = false) -> URL? {
        if control && request.action == .diffLater {
            return FinderRequest(action: .clearComparisonMark, paths: request.paths).url
        }
        return request.url
    }
}

final class FinderMenuGroup: NSObject {
    let action: RepositoryAction
    init(_ action: RepositoryAction) { self.action = action }
}

/// Projection of pinned MenuInfo command order onto implemented Finder commands.
enum FinderShellMenuLayout {
    static let groups: [[RepositoryAction]] = [
        [.clone, .pull, .fetch, .push],
        [.commit],
        [.diff, .diffLater],
        [.log, .reflog, .referenceBrowser, .revisionGraph, .repositoryBrowser, .status, .rebase, .stash, .stashApply, .stashPop, .stashList],
        [.bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset],
        [.resolve, .mergeAbort, .rename, .remove, .removeKeep, .revert, .clean],
        [.switchBranch, .merge, .branch, .tag, .export],
        [.initialize, .add, .ignore, .ignoreDelete],
        [.worktreeList, .submoduleAdd, .submoduleUpdate, .submoduleSync],
        [.formatPatch, .importPatch]
    ]
    static func action(_ item: NSMenuItem) -> RepositoryAction? {
        (item.representedObject as? FinderMenuCommand)?.request.action ?? (item.representedObject as? FinderMenuGroup)?.action
    }
    static func arrange(_ menu: NSMenu) {
        let ordered = menu.items.enumerated().filter { !$0.element.isSeparatorItem }.map { entry in
            let action = action(entry.element)
            let group = groups.firstIndex { action.map($0.contains) ?? false } ?? groups.count
            let rank = action.flatMap { groups.indices.contains(group) ? groups[group].firstIndex(of: $0) : nil } ?? Int.max
            return (item: entry.element, group: group, rank: rank, offset: entry.offset)
        }.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.offset < $1.offset
        }
        menu.removeAllItems()
        var previous: Int?
        for entry in ordered {
            if let previous, previous != entry.group { menu.addItem(.separator()) }
            menu.addItem(entry.item); previous = entry.group
        }
    }
}

enum FinderMenuBuilder {
    static func paths(kind: FIMenuKind, selection: [URL], target: URL?) -> [URL] {
        if kind == .contextualMenuForContainer || kind == .toolbarItemMenu { return target.map { [$0] } ?? [] }
        return selection.isEmpty ? target.map { [$0] } ?? [] : selection
    }
    static func make(paths: [URL], snapshot: FinderSnapshot?, settings: FinderMenuSettings,
                     comparisonMark: WorkingComparisonMarkSnapshot?, target: AnyObject?, actionSelector: Selector,
                     creationDirectory: URL? = nil, extended: Bool = false, toolbar: Bool = false) -> NSMenu {
        func image(_ icon: MenuIcon) -> NSImage? { settings.showIcons ? icon.image() : nil }
        let menu = NSMenu(title: "TurtleGit")
        if paths.contains(where: { $0.pathComponents.contains(".git") }) { return menu }
        let submenu = NSMenu(title: "TurtleGit")
        submenu.autoenablesItems = false
        let creationActions = creationDirectory.map {
            FinderCreationMenuContext.read(directory: $0, snapshot: snapshot, extended: extended).actions
        } ?? (toolbar ? [.clone, .initialize] : [])
        for action in creationActions {
            let item = NSMenuItem(title: action.title, action: actionSelector, keyEquivalent: "")
            item.image = image(action.icon); item.target = target
            item.representedObject = FinderMenuCommand(action: action, paths: creationDirectory.map { [$0] } ?? []); submenu.addItem(item)
        }
        let shellFlags = FinderShellRules.flags(paths: paths, snapshot: snapshot, extended: extended)
        let knownRepository = paths.contains { path in snapshot?.roots.contains { path.path == $0 || path.path.hasPrefix($0 + "/") } == true }
        if !submenu.items.isEmpty && knownRepository { submenu.addItem(.separator()) }
        for action in RepositoryAction.allCases.filter({ $0 != .clone && $0 != .initialize && $0 != .worktreeCreate && $0 != .editConflict && $0 != .reset && $0 != .diffLater && $0 != .clearComparisonMark && !$0.isIgnore && $0.resolveChoice == nil }) {
            guard (knownRepository || action == .diff && paths.count == 2), FinderShellRules.allows(action, flags: shellFlags) else { continue }
            let item = NSMenuItem(title: action.title, action: actionSelector, keyEquivalent: "")
            item.image = image(action.icon)
            if action == .formatPatch || action == .worktreeList { item.isEnabled = paths.count == 1 && paths.first?.hasDirectoryPath == true }
            if action == .revert { item.isEnabled = snapshot?.canRevert(paths) == true }
            if action == .resolve { item.isEnabled = snapshot?.canResolve(paths) == true }
            if action == .rename { item.isEnabled = snapshot?.canRename(paths) == true }
            if action == .remove || action == .removeKeep { item.isEnabled = snapshot?.canRemove(paths) == true }
            item.target = target; item.representedObject = FinderMenuCommand(action: action, paths: paths); submenu.addItem(item)
        }
        for deleting in [false, true] where snapshot?.canIgnore(paths, deleting: deleting) == true && FinderShellRules.allows(deleting ? .ignoreDelete : .ignore, flags: shellFlags) {
            let ignore = NSMenuItem(title: deleting ? "Delete and add to ignore list" : "Add to ignore list", action: nil, keyEquivalent: "")
            ignore.image = image(.ignore); ignore.representedObject = FinderMenuGroup(deleting ? .ignoreDelete : .ignore)
            let choices = NSMenu(title: ignore.title); choices.autoenablesItems = false
            let name = paths.count == 1 ? paths[0].lastPathComponent : "Ignore \(paths.count) items by name"
            let named = NSMenuItem(title: name, action: actionSelector, keyEquivalent: "")
            named.target = target; named.image = image(.ignore); named.representedObject = FinderMenuCommand(action: deleting ? .ignoreDelete : .ignore, paths: paths)
            choices.addItem(named)
            let singleDirectory = paths.count == 1 && snapshot?.states.keys.contains(where: { $0.hasPrefix(paths[0].path + "/") }) == true
            if !singleDirectory && paths.contains(where: { !$0.pathExtension.isEmpty }) {
                let title = paths.count == 1 ? "*." + paths[0].pathExtension : "Ignore \(paths.count) items by extension"
                let mask = NSMenuItem(title: title, action: actionSelector, keyEquivalent: "")
                mask.target = target; mask.image = image(.ignore); mask.representedObject = FinderMenuCommand(action: deleting ? .ignoreDeleteMask : .ignoreMask, paths: paths)
                choices.addItem(mask)
            }
            ignore.submenu = choices; submenu.addItem(ignore)
        }
        if FinderShellRules.allows(.diffLater, flags: shellFlags), (try? paths[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false {
            let marked = comparisonMark
            let title = marked.map { "Compare with " + $0.path } ?? RepositoryAction.diffLater.title
            let item = NSMenuItem(title: title, action: actionSelector, keyEquivalent: "")
            item.target = target; item.image = image(.compare); item.representedObject = FinderMenuCommand(action: .diffLater, paths: paths)
            submenu.addItem(.separator()); submenu.addItem(item)
        }
        FinderShellMenuLayout.arrange(submenu)
        if toolbar { return submenu }
        let parent = NSMenuItem(title: "TurtleGit", action: nil, keyEquivalent: "")
        parent.image = image(.turtle)
        parent.submenu = submenu; menu.addItem(parent)
        return menu
    }
}
