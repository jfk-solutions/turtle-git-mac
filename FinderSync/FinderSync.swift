import AppKit
import FinderSync
import TurtleGitCore
import os

/// Finder never launches Git. Only the containing application scans repositories.
@objc(FinderSync) final class FinderSync: FIFinderSync {
    private let menuDispatch = FinderMenuDispatch()
    private static let handoffLog = Logger(subsystem: "org.turtlegit.macos.finder", category: "handoff")
    private var snapshot: FinderSnapshot?
    private var badges: GitPathMap<FinderOverlayBadge> = [:]
    private var iconSet: FinderOverlayIconSet?
    private var badgeLanguage: String?
    private var fileSystem = FinderOverlayFileSystem()
    private var badgeLookup = FinderOverlayBadgeLookup(badges: [:], caseSensitive: { _ in true })
    override init() {
        super.init()
        reload()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload), name: NSNotification.Name(FinderIntegration.notification), object: nil)
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func reload() {
        let old = badges
        snapshot = FinderSnapshot.read()
        let settings = FinderOverlaySettings.read(), changedIcons = iconSet != settings.iconSet
        let controller = FIFinderSyncController.default()
        let menuSettings = FinderMenuSettings.read()
        let captions = FinderMenuCaptions(language: menuSettings.language, bundle: Bundle(for: FinderSync.self))
        if changedIcons || badgeLanguage != menuSettings.language {
            for state in FinderOverlayBadge.allCases {
                guard let image = state.image(set: settings.iconSet) else { continue }
                controller.setBadgeImage(image, label: captions.label(state.title), forBadgeIdentifier: state.rawValue)
            }
            iconSet = settings.iconSet; badgeLanguage = menuSettings.language
        }
        let fileSystem = FinderOverlayFileSystem(); self.fileSystem = fileSystem
        if let snapshot {
            badges = settings.overlayBadges(snapshot: snapshot, volume: { fileSystem.volume($0).kind },
                isDirectory: fileSystem.isDirectory, caseSensitive: { fileSystem.volume($0).caseSensitive })
        } else { badges = [:] }
        badgeLookup = FinderOverlayBadgeLookup(badges: badges, caseSensitive: { fileSystem.volume($0).caseSensitive })
        controller.directoryURLs = Set((snapshot?.roots ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) })
        let paths = GitPathSet(old.keys).union(GitPathSet(badges.keys))
        for path in paths where changedIcons || old[path] != badges[path] {
            if changedIcons { controller.setBadgeIdentifier("", for: FileTransferPaths.fileURL(path)) }
            controller.setBadgeIdentifier(badgeLookup.badge(for: path, caseSensitive: fileSystem.volume(path).caseSensitive)?.rawValue ?? "", for: FileTransferPaths.fileURL(path))
        }
    }
    override func requestBadgeIdentifier(for url: URL) {
        FIFinderSyncController.default().setBadgeIdentifier(badgeLookup.badge(for: url.path, caseSensitive: fileSystem.volume(url.path).caseSensitive)?.rawValue ?? "", for: url)
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
        let menu = FinderMenuBuilder.make(paths: paths, snapshot: snapshot,
            settings: FinderMenuSettings.read(), comparisonMark: try? WorkingComparisonMarkSnapshot.read(),
            target: self, actionSelector: #selector(openAction(_:)), creationDirectory: creation,
            extended: NSEvent.modifierFlags.contains(.shift), toolbar: menuKind == .toolbarItemMenu,
            clipboardSources: (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
        menuDispatch.install(menu)
        return menu
    }
    @objc private func openAction(_ sender: NSMenuItem) {
        let carriedPayload = sender.representedObject is FinderMenuCommand
        Self.handoffLog.notice("Finder callback received; tag: \(sender.tag, privacy: .public), represented payload present: \(carriedPayload, privacy: .public)")
        guard let command = menuDispatch.claim(sender),
              let raw = command.url(control: NSEvent.modifierFlags.contains(.control), alternate: NSEvent.modifierFlags.contains(.shift)),
              let request = FinderRequest(url: raw),
              let application = FinderMenuDispatch.containingApplication(for: Bundle(for: FinderSync.self).bundleURL) else { return }
        Task { @MainActor in
            let captured = await FinderPatchReviewCapture.request(request, pasteboard: .general, store: .current)
            guard let url = captured.url else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true; configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
                if let error {
                    Self.handoffLog.error("Finder application handoff failed: \((error as NSError).code, privacy: .public)")
                    if let receipt = captured.clipboardPatch, let store = FinderPatchHandoff.current { store.discard(receipt) }
                }
            }
        }
    }
}

/// Finder hosts the menu in another process. Keep the immutable requests in the
/// extension and dispatch by the primitive NSMenuItem tag, not object identity.
final class FinderMenuDispatch {
    private var commands: [Int: FinderMenuCommand] = [:]
    private var nextTag = 1
    func install(_ menu: NSMenu) {
        commands.removeAll()
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let command = item.representedObject as? FinderMenuCommand {
                    if nextTag == Int.max { nextTag = 1; commands.removeAll() }
                    item.tag = nextTag; commands[nextTag] = command; nextTag += 1
                }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        visit(menu)
    }
    func claim(_ sender: NSMenuItem) -> FinderMenuCommand? {
        guard let command = commands[sender.tag] else { return nil }
        commands.removeAll()
        return command
    }
    static func containingApplication(for extensionURL: URL) -> URL? {
        guard extensionURL.pathExtension == "appex" else { return nil }
        let application = extensionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard application.pathExtension == "app", Bundle(url: application)?.bundleIdentifier == FinderCacheServiceIdentity.appIdentifier else { return nil }
        return application
    }
}

/// Builds the same menu used by the extension without requiring a live Finder controller.
final class FinderMenuCommand: NSObject {
    let request: FinderRequest
    init(action: RepositoryAction, paths: [URL]) { request = FinderRequest(action: action, paths: paths) }
    init(request: FinderRequest) { self.request = request }
    func url(control: Bool = false, alternate: Bool? = nil) -> URL? {
        if control && request.action == .diffLater {
            return FinderRequest(action: .clearComparisonMark, paths: request.paths).url
        }
        return FinderRequest(action:request.action,paths:request.paths,sources:request.sources,alternateTool:alternate ?? request.alternateTool,clipboardPatch:request.clipboardPatch).url
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
        [.pasteCopy, .pasteMove],
        [.properties, .settings, .help, .about]
    ]
    static func action(_ item: NSMenuItem) -> RepositoryAction? {
        (item.representedObject as? FinderMenuCommand)?.request.action ?? (item.representedObject as? FinderMenuGroup)?.action
    }
    static func preferenceEntry(_ action: RepositoryAction) -> FinderMenuEntry? {
        // Explorer's property page has no MenuInfo bit. Its native context
        // action follows Settings placement/visibility instead of adding one.
        FinderMenuEntry.entry(for: action) ?? (action == .properties ? .settings : nil)
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
                     creationDirectory: URL? = nil, extended: Bool = false, toolbar: Bool = false, clipboardSources: [URL] = [], localizationBundle: Bundle? = nil) -> NSMenu {
        let captions = FinderMenuCaptions(language: settings.language, bundle: localizationBundle ?? Bundle(for: FinderSync.self))
        func image(_ icon: MenuIcon) -> NSImage? { settings.showIcons ? icon.image() : nil }
        let menu = NSMenu(title: "TurtleGit"); menu.autoenablesItems = false
        let normalizedPaths = FinderRequest.normalizedSelection(paths)
        if normalizedPaths.contains(where: { $0.pathComponents.contains(".git") }) { return menu }
        let originalPaths = normalizedPaths
        let paths = normalizedPaths.filter { path in
            let knownRoot = snapshot?.repositoryRoot(for: path)
            let fallback = knownRoot.map { URL(fileURLWithPath: $0) } ?? path.deletingLastPathComponent()
            let sensitive = (try? path.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
                ?? (try? fallback.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
            return settings.allowsPath(path.standardizedFileURL.path, caseSensitive: sensitive)
        }
        if !originalPaths.isEmpty && paths.isEmpty { return menu }
        let shellFlags = FinderShellRules.flags(paths: paths, snapshot: snapshot, extended: extended)
        guard settings.allowsMenu(flags: shellFlags, extended: extended) else { return menu }
        let creationDirectory = creationDirectory.flatMap { FinderRequest.normalizedSelection([$0]).first }.flatMap { paths.contains($0) ? $0 : nil }
        let submenu = NSMenu(title: "TurtleGit")
        submenu.autoenablesItems = false
        let creationActions = creationDirectory.map {
            FinderCreationMenuContext.read(directory: $0, snapshot: snapshot, extended: extended).actions
        } ?? (toolbar ? [.clone, .initialize] : [])
        for action in creationActions {
            let item = NSMenuItem(title: captions.label(action.title), action: actionSelector, keyEquivalent: "")
            item.image = image(action.icon); item.target = target
            item.representedObject = FinderMenuCommand(action: action, paths: creationDirectory.map { [$0] } ?? []); submenu.addItem(item)
        }
        let knownRepository = paths.first.flatMap { snapshot?.repositoryRoot(for: $0) } != nil
        let sharedRepository = snapshot?.commonRepositoryRoot(for: paths) != nil
        if !submenu.items.isEmpty && knownRepository { submenu.addItem(.separator()) }
        for action in RepositoryAction.allCases.filter({ $0 != .clone && $0 != .initialize && $0 != .worktreeCreate && $0 != .reset && $0 != .diffLater && $0 != .clearComparisonMark && !$0.isIgnore && !$0.isLFS && $0.resolveChoice == nil }) {
            guard (knownRepository || action.isApplicationUtility || [.sendMail, .reviewPatch].contains(action) || action == .diff && paths.count == 2), FinderShellRules.allows(action, flags: shellFlags) else { continue }
            if action == .diff && paths.count == 2 && paths.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) { continue }
            let item = NSMenuItem(title: captions.label(action.title), action: actionSelector, keyEquivalent: "")
            item.image = image(action.icon)
            let sameOwner = sharedRepository || ([.rename, .remove, .removeKeep].contains(action) && snapshot?.commonFileOperationOwner(for: paths) != nil)
            if !sameOwner && !action.isApplicationUtility && ![.sendMail, .reviewPatch].contains(action) && !(action == .diff && paths.count == 2) {
                item.isEnabled = false; item.toolTip = captions.label("Select items in one repository to use this command.")
            }
            if action == .formatPatch || action == .worktreeList { item.isEnabled = item.isEnabled && (paths.count == 1 && (try? paths[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
            if action == .revert { item.isEnabled = item.isEnabled && (snapshot?.canRevert(paths) == true) }
            if action == .resolve { item.isEnabled = item.isEnabled && (snapshot?.canResolve(paths) == true) }
            if action == .editConflict { item.isEnabled = item.isEnabled && (snapshot?.canResolve(paths) == true) }
            if action == .rename { item.isEnabled = item.isEnabled && (snapshot?.canRename(paths) == true) }
            if action == .remove || action == .removeKeep { item.isEnabled = item.isEnabled && (snapshot?.canRemove(paths) == true) }
            item.target = target; item.representedObject = FinderMenuCommand(action: action, paths: paths); submenu.addItem(item)
        }
        if snapshot?.repositoryMetadata(for: paths)?.hasLFS == true, FinderShellRules.allows(.lfs, flags: shellFlags) {
            let choices = NSMenu(title: captions.label(RepositoryAction.lfs.title)); choices.autoenablesItems = false
            for action in [RepositoryAction.lfsLocks, .lfsLock, .lfsUnlock] where FinderShellRules.allows(action, flags: shellFlags) {
                let item = NSMenuItem(title: captions.label(action.title), action: actionSelector, keyEquivalent: "")
                item.image = image(action.icon); item.target = target; item.representedObject = FinderMenuCommand(action: action, paths: paths)
                choices.addItem(item)
            }
            if !choices.items.isEmpty {
                let parent = NSMenuItem(title: captions.label(RepositoryAction.lfs.title), action: nil, keyEquivalent: "")
                parent.image = image(.lfs); parent.submenu = choices; parent.representedObject = FinderMenuGroup(.lfs); submenu.addItem(parent)
            }
        }
        for deleting in [false, true] where snapshot?.canIgnore(paths, deleting: deleting) == true && FinderShellRules.allows(deleting ? .ignoreDelete : .ignore, flags: shellFlags) {
            let ignore = NSMenuItem(title: captions.label(deleting ? "Delete and add to ignore list" : "Add to ignore list"), action: nil, keyEquivalent: "")
            ignore.image = image(.ignore); ignore.representedObject = FinderMenuGroup(deleting ? .ignoreDelete : .ignore)
            let choices = NSMenu(title: ignore.title); choices.autoenablesItems = false
            let name = paths.count == 1 ? paths[0].lastPathComponent : captions.ignoreItems(paths.count, byExtension: false)
            let named = NSMenuItem(title: name, action: actionSelector, keyEquivalent: "")
            named.target = target; named.image = image(.ignore); named.representedObject = FinderMenuCommand(action: deleting ? .ignoreDelete : .ignore, paths: paths)
            choices.addItem(named)
            let singleDirectory = paths.count == 1 && snapshot?.states.keys.contains(where: { $0.hasPrefix(paths[0].path + "/") }) == true
            if !singleDirectory && paths.contains(where: { !$0.pathExtension.isEmpty }) {
                let title = paths.count == 1 ? "*." + paths[0].pathExtension : captions.ignoreItems(paths.count, byExtension: true)
                let mask = NSMenuItem(title: title, action: actionSelector, keyEquivalent: "")
                mask.target = target; mask.image = image(.ignore); mask.representedObject = FinderMenuCommand(action: deleting ? .ignoreDeleteMask : .ignoreMask, paths: paths)
                choices.addItem(mask)
            }
            ignore.submenu = choices; submenu.addItem(ignore)
        }
        if FinderShellRules.allows(.diffLater, flags: shellFlags), (try? paths[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false {
            let marked = comparisonMark
            let title = marked.map { captions.comparison(path: $0.path) } ?? captions.label(RepositoryAction.diffLater.title)
            let item = NSMenuItem(title: title, action: actionSelector, keyEquivalent: "")
            item.target = target; item.image = image(.compare); item.representedObject = FinderMenuCommand(action: .diffLater, paths: paths)
            submenu.addItem(.separator()); submenu.addItem(item)
        }
        if paths.count == 1 {
            for request in FinderTransferContext.requests(destination: paths[0], sources: clipboardSources, snapshot: snapshot, settings: settings) {
                let item = NSMenuItem(title: captions.label(request.action.title), action: actionSelector, keyEquivalent: "")
                item.image = image(request.action.icon); item.target = target; item.representedObject = FinderMenuCommand(request: request)
                submenu.addItem(item)
            }
        }
        for item in submenu.items {
            guard let action = FinderShellMenuLayout.action(item), let entry = FinderShellMenuLayout.preferenceEntry(action) else { continue }
            if !settings.visible(entry, extended: extended) { submenu.removeItem(item) }
        }
        FinderShellMenuLayout.arrange(submenu)
        if toolbar { return submenu }
        let firstLevel = NSMenu(title: "TurtleGit")
        for item in submenu.items {
            guard let action = FinderShellMenuLayout.action(item), let entry = FinderShellMenuLayout.preferenceEntry(action), settings.firstLevel(entry) else { continue }
            submenu.removeItem(item)
            if action != .properties { item.title = "Git " + item.title }
            firstLevel.addItem(item)
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


/// The existing source Review action prefers a selected patch file. Only an
/// explicit invocation on another file reads registered patch clipboard bytes;
/// popup construction does not inspect patch contents or broaden source clauses.
@MainActor enum FinderPatchReviewCapture {
    static let types = [NSPasteboard.PasteboardType(FinderPatchHandoff.clipboardType), NSPasteboard.PasteboardType(FinderPatchHandoff.legacyClipboardType)]
    static func request(_ request: FinderRequest, pasteboard: NSPasteboard, store: FinderPatchHandoff?) async -> FinderRequest {
        guard request.action == .reviewPatch, request.paths.count == 1,
              !["patch", "diff"].contains(request.paths[0].pathExtension.lowercased()) else { return request }
        guard let bytes = types.lazy.compactMap({ pasteboard.data(forType: $0) }).first(where: { !$0.isEmpty }) else { return request }
        let receipt: String
        if let store { receipt = (try? await Task.detached { try store.publish(bytes) }.value) ?? FinderPatchHandoff.unavailable }
        else { receipt = FinderPatchHandoff.unavailable }
        return FinderRequest(action: request.action, paths: request.paths, alternateTool: request.alternateTool, clipboardPatch: receipt)
    }
}
