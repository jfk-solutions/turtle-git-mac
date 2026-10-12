import AppKit
import FinderSync
import TurtleGitCore

/// Finder never launches Git. Only the containing application scans repositories.
@objc(FinderSync) final class FinderSync: FIFinderSync {
    private var snapshot: FinderSnapshot?
    private var badges: [String: FinderOverlayBadge] = [:]
    private var iconSet: FinderOverlayIconSet?
    override init() {
        super.init()
        reload()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload), name: NSNotification.Name(FinderIntegration.notification), object: nil)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    @objc private func reload() {
        let old = badges
        snapshot = FinderSnapshot.read()
        let settings = FinderOverlaySettings.read(), changedIcons = iconSet != settings.iconSet
        let controller = FIFinderSyncController.default()
        if changedIcons {
            for state in FinderOverlayBadge.allCases {
                guard let image = state.image(set: settings.iconSet) else { continue }
                controller.setBadgeImage(image, label: state.title, forBadgeIdentifier: state.rawValue)
            }
            iconSet = settings.iconSet
        }
        if let snapshot {
            let volumes = Dictionary(uniqueKeysWithValues: Set(snapshot.roots).map { ($0, FinderOverlaySettings.volumeKind(for: URL(fileURLWithPath: $0))) })
            badges = settings.overlayBadges(snapshot: snapshot, volume: { volumes[$0] ?? .unknown }, isDirectory: { path in
                var directory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
            })
        } else { badges = [:] }
        controller.directoryURLs = Set((snapshot?.roots ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) })
        let paths = Set(old.keys).union(badges.keys)
        for path in paths where changedIcons || old[path] != badges[path] {
            if changedIcons { controller.setBadgeIdentifier("", for: URL(fileURLWithPath: path)) }
            controller.setBadgeIdentifier(badges[path]?.rawValue ?? "", for: URL(fileURLWithPath: path))
        }
    }
    override func requestBadgeIdentifier(for url: URL) {
        FIFinderSyncController.default().setBadgeIdentifier(badges[url.path]?.rawValue ?? "", for: url)
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
        [.clone, .pull, .fetch, .push, .synchronize],
        [.commit, .svnDCommit, .svnRebase, .svnFetch, .svnIgnore],
        [.diff, .diffLater, .previousDiff],
        [.log, .logSubmodule, .reflog, .referenceBrowser, .daemon, .revisionGraph, .repositoryBrowser, .status, .rebase, .stash, .stashApply, .stashPop, .stashList],
        [.bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset],
        [.editConflict, .resolve, .mergeAbort, .rename, .remove, .removeKeep, .revert, .clean],
        [.lfs],
        [.switchBranch, .merge, .branch, .tag, .export],
        [.initialize, .add, .blame, .ignore, .ignoreDelete],
        [.worktreeList, .submoduleAdd, .submoduleUpdate, .submoduleSync],
        [.formatPatch, .importPatch, .reviewPatch, .sendMail],
        [.settings, .help, .about]
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
        let originalPaths = paths
        let paths = paths.filter { path in
            let knownRoot = snapshot?.roots.sorted { $0.count > $1.count }.first { root in path.path == root || path.path.hasPrefix(root + "/") }
            let fallback = knownRoot.map { URL(fileURLWithPath: $0) } ?? path.deletingLastPathComponent()
            let sensitive = (try? path.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
                ?? (try? fallback.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
            return settings.allowsPath(path.standardizedFileURL.path, caseSensitive: sensitive)
        }
        if !originalPaths.isEmpty && paths.isEmpty { return menu }
        let shellFlags = FinderShellRules.flags(paths: paths, snapshot: snapshot, extended: extended)
        guard settings.allowsMenu(flags: shellFlags, extended: extended) else { return menu }
        let creationDirectory = creationDirectory.flatMap { paths.contains($0) ? $0 : nil }
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
        let knownRepository = paths.contains { path in snapshot?.roots.contains { path.path == $0 || path.path.hasPrefix($0 + "/") } == true }
        if !submenu.items.isEmpty && knownRepository { submenu.addItem(.separator()) }
        for action in RepositoryAction.allCases.filter({ $0 != .clone && $0 != .initialize && $0 != .worktreeCreate && $0 != .reset && $0 != .diffLater && $0 != .clearComparisonMark && !$0.isIgnore && !$0.isLFS && $0.resolveChoice == nil }) {
            guard (knownRepository || action.isApplicationUtility || [.sendMail, .reviewPatch].contains(action) || action == .diff && paths.count == 2), FinderShellRules.allows(action, flags: shellFlags) else { continue }
            let item = NSMenuItem(title: action.title, action: actionSelector, keyEquivalent: "")
            item.image = image(action.icon)
            if action == .formatPatch || action == .worktreeList { item.isEnabled = paths.count == 1 && paths.first?.hasDirectoryPath == true }
            if action == .revert { item.isEnabled = snapshot?.canRevert(paths) == true }
            if action == .resolve { item.isEnabled = snapshot?.canResolve(paths) == true }
            if action == .editConflict { item.isEnabled = snapshot?.canResolve(paths) == true }
            if action == .rename { item.isEnabled = snapshot?.canRename(paths) == true }
            if action == .remove || action == .removeKeep { item.isEnabled = snapshot?.canRemove(paths) == true }
            item.target = target; item.representedObject = FinderMenuCommand(action: action, paths: paths); submenu.addItem(item)
        }
        if snapshot?.repositoryMetadata(for: paths)?.hasLFS == true, FinderShellRules.allows(.lfs, flags: shellFlags) {
            let choices = NSMenu(title: RepositoryAction.lfs.title); choices.autoenablesItems = false
            for action in [RepositoryAction.lfsLocks, .lfsLock, .lfsUnlock] where FinderShellRules.allows(action, flags: shellFlags) {
                let item = NSMenuItem(title: action.title, action: actionSelector, keyEquivalent: "")
                item.image = image(action.icon); item.target = target; item.representedObject = FinderMenuCommand(action: action, paths: paths)
                choices.addItem(item)
            }
            if !choices.items.isEmpty {
                let parent = NSMenuItem(title: RepositoryAction.lfs.title, action: nil, keyEquivalent: "")
                parent.image = image(.lfs); parent.submenu = choices; parent.representedObject = FinderMenuGroup(.lfs); submenu.addItem(parent)
            }
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
        for item in submenu.items {
            guard let action = FinderShellMenuLayout.action(item), let entry = FinderMenuEntry.entry(for: action) else { continue }
            if !settings.visible(entry, extended: extended) { submenu.removeItem(item) }
        }
        FinderShellMenuLayout.arrange(submenu)
        if toolbar { return submenu }
        let firstLevel = NSMenu(title: "TurtleGit")
        for item in submenu.items {
            guard let action = FinderShellMenuLayout.action(item), let entry = FinderMenuEntry.entry(for: action), settings.firstLevel(entry) else { continue }
            submenu.removeItem(item); item.title = "Git " + item.title; firstLevel.addItem(item)
        }
        FinderShellMenuLayout.arrange(firstLevel)
        FinderShellMenuLayout.arrange(submenu)
        for item in firstLevel.items { firstLevel.removeItem(item); menu.addItem(item) }
        if submenu.items.isEmpty { return menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let parent = NSMenuItem(title: "TurtleGit", action: nil, keyEquivalent: "")
        parent.image = image(.turtle)
        parent.submenu = submenu; menu.addItem(parent)
        return menu
    }
}
