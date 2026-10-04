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
        let menu = NSMenu(title: "TurtleGit")
        let submenu = NSMenu(title: "TurtleGit")
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let paths = selection.isEmpty ? controller.targetedURL().map { [$0] } ?? [] : selection
        submenu.autoenablesItems = false
        for action in RepositoryAction.allCases.filter({ $0 != .clone && $0 != .initialize && $0 != .editConflict && $0 != .reset && !$0.isIgnore && $0.resolveChoice == nil }) {
            let item = NSMenuItem(title: action.title, action: #selector(openAction(_:)), keyEquivalent: "")
            item.image = action.icon.image()
            if action == .revert { item.isEnabled = snapshot?.canRevert(paths) == true }
            if action == .resolve { item.isEnabled = snapshot?.canResolve(paths) == true }
            if action == .rename { item.isEnabled = snapshot?.canRename(paths) == true }
            if action == .remove || action == .removeKeep { item.isEnabled = snapshot?.canRemove(paths) == true }
            item.target = self; item.representedObject = action.rawValue; submenu.addItem(item)
        }
        for deleting in [false, true] where snapshot?.canIgnore(paths, deleting: deleting) == true {
            let ignore = NSMenuItem(title: deleting ? "Delete and add to ignore list" : "Add to ignore list", action: nil, keyEquivalent: "")
            ignore.image = MenuIcon.ignore.image()
            let choices = NSMenu(title: ignore.title); choices.autoenablesItems = false
            let name = paths.count == 1 ? paths[0].lastPathComponent : "Ignore \(paths.count) items by name"
            let named = NSMenuItem(title: name, action: #selector(openAction(_:)), keyEquivalent: "")
            named.target = self; named.image = MenuIcon.ignore.image(); named.representedObject = (deleting ? RepositoryAction.ignoreDelete : .ignore).rawValue
            choices.addItem(named)
            let singleDirectory = paths.count == 1 && snapshot?.states.keys.contains(where: { $0.hasPrefix(paths[0].path + "/") }) == true
            if !singleDirectory && paths.contains(where: { !$0.pathExtension.isEmpty }) {
                let title = paths.count == 1 ? "*." + paths[0].pathExtension : "Ignore \(paths.count) items by extension"
                let mask = NSMenuItem(title: title, action: #selector(openAction(_:)), keyEquivalent: "")
                mask.target = self; mask.image = MenuIcon.ignore.image(); mask.representedObject = (deleting ? RepositoryAction.ignoreDeleteMask : .ignoreMask).rawValue
                choices.addItem(mask)
            }
            ignore.submenu = choices; submenu.addItem(ignore)
        }
        let parent = NSMenuItem(title: "TurtleGit", action: nil, keyEquivalent: "")
        parent.image = MenuIcon.turtle.image()
        parent.submenu = submenu; menu.addItem(parent)
        return menu
    }
    @objc private func openAction(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let paths = selection.isEmpty ? controller.targetedURL().map { [$0] } ?? [] : selection
        guard let command = sender.representedObject as? String,
              let action = RepositoryAction(rawValue: command),
              let url = FinderRequest(action: action, paths: paths).url else { return }
        NSWorkspace.shared.open(url)
    }
}
