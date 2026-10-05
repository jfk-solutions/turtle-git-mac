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
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let paths = selection.isEmpty ? controller.targetedURL().map { [$0] } ?? [] : selection
        return FinderMenuBuilder.make(paths: paths, snapshot: snapshot,
            settings: FinderMenuSettings.read(), comparisonMark: try? WorkingComparisonMarkSnapshot.read(),
            target: self, actionSelector: #selector(openAction(_:)))
    }
    @objc private func openAction(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let paths = selection.isEmpty ? controller.targetedURL().map { [$0] } ?? [] : selection
        guard let command = sender.representedObject as? String,
              var action = RepositoryAction(rawValue: command) else { return }
        if action == .diffLater, NSEvent.modifierFlags.contains(.control) { action = .clearComparisonMark }
        guard let url = FinderRequest(action: action, paths: paths).url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Builds the same menu used by the extension without requiring a live Finder controller.
enum FinderMenuBuilder {
    static func make(paths: [URL], snapshot: FinderSnapshot?, settings: FinderMenuSettings,
                     comparisonMark: WorkingComparisonMarkSnapshot?, target: AnyObject?, actionSelector: Selector) -> NSMenu {
        func image(_ icon: MenuIcon) -> NSImage? { settings.showIcons ? icon.image() : nil }
        let menu = NSMenu(title: "TurtleGit")
        let submenu = NSMenu(title: "TurtleGit")
        submenu.autoenablesItems = false
        for action in RepositoryAction.allCases.filter({ $0 != .clone && $0 != .initialize && $0 != .editConflict && $0 != .reset && $0 != .diffLater && $0 != .clearComparisonMark && !$0.isIgnore && $0.resolveChoice == nil }) {
            let item = NSMenuItem(title: action.title, action: actionSelector, keyEquivalent: "")
            item.image = image(action.icon)
            if action == .formatPatch || action == .worktreeCreate || action == .worktreeList { item.isEnabled = paths.count == 1 && paths.first?.hasDirectoryPath == true }
            if action == .revert { item.isEnabled = snapshot?.canRevert(paths) == true }
            if action == .resolve { item.isEnabled = snapshot?.canResolve(paths) == true }
            if action == .rename { item.isEnabled = snapshot?.canRename(paths) == true }
            if action == .remove || action == .removeKeep { item.isEnabled = snapshot?.canRemove(paths) == true }
            item.target = target; item.representedObject = action.rawValue; submenu.addItem(item)
        }
        for deleting in [false, true] where snapshot?.canIgnore(paths, deleting: deleting) == true {
            let ignore = NSMenuItem(title: deleting ? "Delete and add to ignore list" : "Add to ignore list", action: nil, keyEquivalent: "")
            ignore.image = image(.ignore)
            let choices = NSMenu(title: ignore.title); choices.autoenablesItems = false
            let name = paths.count == 1 ? paths[0].lastPathComponent : "Ignore \(paths.count) items by name"
            let named = NSMenuItem(title: name, action: actionSelector, keyEquivalent: "")
            named.target = target; named.image = image(.ignore); named.representedObject = (deleting ? RepositoryAction.ignoreDelete : .ignore).rawValue
            choices.addItem(named)
            let singleDirectory = paths.count == 1 && snapshot?.states.keys.contains(where: { $0.hasPrefix(paths[0].path + "/") }) == true
            if !singleDirectory && paths.contains(where: { !$0.pathExtension.isEmpty }) {
                let title = paths.count == 1 ? "*." + paths[0].pathExtension : "Ignore \(paths.count) items by extension"
                let mask = NSMenuItem(title: title, action: actionSelector, keyEquivalent: "")
                mask.target = target; mask.image = image(.ignore); mask.representedObject = (deleting ? RepositoryAction.ignoreDeleteMask : .ignoreMask).rawValue
                choices.addItem(mask)
            }
            ignore.submenu = choices; submenu.addItem(ignore)
        }
        if paths.count == 1, (try? paths[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false {
            let marked = comparisonMark
            let title = marked.map { "Compare with " + $0.path } ?? RepositoryAction.diffLater.title
            let item = NSMenuItem(title: title, action: actionSelector, keyEquivalent: "")
            item.target = target; item.image = image(.compare); item.representedObject = RepositoryAction.diffLater.rawValue
            submenu.addItem(.separator()); submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "TurtleGit", action: nil, keyEquivalent: "")
        parent.image = image(.turtle)
        parent.submenu = submenu; menu.addItem(parent)
        return menu
    }
}
