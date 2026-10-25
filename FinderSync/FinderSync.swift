import AppKit
import FinderSync
import TurtleGitCore
import os

/// Finder never launches Git. Authorized app/service publishers collect status.
@objc(FinderSync) final class FinderSync: FIFinderSync {
    private let menuDispatch = FinderMenuDispatch()
    private let statusQueries = FinderObservedStatusQueries()
    private var observedDirectories=GitPathSet()
    private var statusPolicy:FinderStatusPolicy?
    private static let handoffLog = Logger(subsystem: "org.turtlegit.macos.finder", category: "handoff")
    private let liveReader = FinderIntegration.snapshotURL.map { FinderSnapshotLiveReader(url:$0) }
    private var snapshot: FinderSnapshot?
    private var contextDiscovery=FinderContextDiscovery(snapshot:nil)
    private var badges: GitPathMap<FinderOverlayBadge> = [:]
    private var iconSet: FinderOverlayIconSet?
    private var badgeLanguage: String?
    private var fileSystem = FinderOverlayFileSystem()
    private var badgeLookup = FinderOverlayBadgeLookup(badges: [:], caseSensitive: { _ in true })
    override init() {
        super.init()
        reload()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload), name: NSNotification.Name(FinderIntegration.notification), object: nil)
        for name in [FinderStatusPolicyPreferences.notification,FinderStatusOperationLease.notification] {DistributedNotificationCenter.default().addObserver(self,selector:#selector(statusPolicyChanged),name:NSNotification.Name(name),object:nil)}
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
    }
    deinit { statusQueries.retire();DistributedNotificationCenter.default().removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func reload() { install(try? liveReader?.read()) }
    @objc private func statusPolicyChanged() {reload();for path in observedDirectories {requestStatus(path,force:true)}}
    private func requestStatus(_ path:String,force:Bool=false) {
        guard contextDiscovery.permitsStatus(path) else{return}
        guard let policy=statusPolicy,policy.cacheMode == .shell || policy.cacheMode == .shellExtended else{return}
        guard !policy.blockStatus || !FinderStatusOperationLease.isBlocked() else{return}
        statusQueries.request(path,force:force)
    }
    override func beginObservingDirectory(at url:URL) {
        guard contextDiscovery.permitsStatus(url.path) else{return}
        if observedDirectories.count<4096 {observedDirectories.insert(url.path)};requestStatus(url.path,force:true)
    }
    override func endObservingDirectory(at url:URL) {observedDirectories.remove(url.path)}
    private func revalidateLivePublication() {
        let live = try? liveReader?.read()
        // Live ownership can change without changing the stored timestamp.
        if live?.liveRevision != snapshot?.liveRevision {
            install(live)
        }
    }
    private func install(_ live: FinderSnapshot?) {
        let old = badges
        snapshot = live
        contextDiscovery=FinderContextDiscovery(snapshot:live)
        let settings = FinderOverlaySettings.read(), changedIcons = iconSet != settings.iconSet
        statusPolicy=try? FinderStatusPolicy.read()
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
        if let snapshot,let policy=statusPolicy,!((policy.cacheMode == .shell || policy.cacheMode == .shellExtended) && policy.blockStatus && FinderStatusOperationLease.isBlocked()) {
            badges = settings.overlayBadges(snapshot: snapshot, volume: { fileSystem.volume($0).kind },
                isDirectory: fileSystem.isDirectory, caseSensitive: { fileSystem.volume($0).caseSensitive },statusPolicy:policy)
        } else { badges = [:] }
        badgeLookup = FinderOverlayBadgeLookup(badges: badges, caseSensitive: { snapshot?.overlayCaseSensitive(for:$0,fallback:fileSystem.volume($0).caseSensitive) ?? fileSystem.volume($0).caseSensitive })
        // This namespace enables first-use commands; it grants no repository access.
        controller.directoryURLs = FinderContextDiscovery.commandDirectories
        observedDirectories=GitPathSet(observedDirectories.filter{contextDiscovery.permitsStatus($0)})
        let paths = GitPathSet(old.keys).union(GitPathSet(badges.keys))
        for path in paths where changedIcons || old[path] != badges[path] {
            guard contextDiscovery.permitsStatus(path) else {controller.setBadgeIdentifier("",for:FileTransferPaths.fileURL(path));continue}
            if changedIcons { controller.setBadgeIdentifier("", for: FileTransferPaths.fileURL(path)) }
            controller.setBadgeIdentifier(badgeLookup.badge(for: path, caseSensitive: snapshot?.overlayCaseSensitive(for:path,fallback:fileSystem.volume(path).caseSensitive) ?? fileSystem.volume(path).caseSensitive)?.rawValue ?? "", for: FileTransferPaths.fileURL(path))
        }
    }
    override func requestBadgeIdentifier(for url: URL) {
        // A publisher can exit without a distributed notification. Revalidate
        // process leases before serving a previously cached badge.
        revalidateLivePublication()
        guard contextDiscovery.permitsStatus(url.path) else {
            FIFinderSyncController.default().setBadgeIdentifier("",for:url);return
        }
        requestStatus(url.path)
        let blocked=statusPolicy.map {($0.cacheMode == .shell || $0.cacheMode == .shellExtended) && $0.blockStatus && FinderStatusOperationLease.isBlocked()} ?? true
        let sensitive=snapshot?.overlayCaseSensitive(for:url.path,fallback:fileSystem.volume(url.path).caseSensitive) ?? fileSystem.volume(url.path).caseSensitive
        var badge=blocked ? nil:badgeLookup.badge(for:url.path,caseSensitive:sensitive)
        if statusPolicy?.cacheMode == FinderOverlayCacheMode.none,snapshot?.overlayRepositoryRoot(for:url.path) != nil,!url.path.split(separator:"/").contains(".git"),fileSystem.isDirectory(url.path) {
            let settings=FinderOverlaySettings.read(),allowed=settings.pathPolicy.allows(url.path,fallback:settings.volumes.contains(fileSystem.volume(url.path).kind),caseSensitive:sensitive)
            if (allowed && !settings.hiddenStates.contains(.normal)) || (!allowed && settings.showExcludedAsNormal) {badge = .normal}
        }
        FIFinderSyncController.default().setBadgeIdentifier(badge?.rawValue ?? "",for:url)
    }
    override var toolbarItemName: String { "TurtleGit" }
    override var toolbarItemToolTip: String { "TurtleGit for Mac" }
    override var toolbarItemImage: NSImage { MenuIcon.turtle.image() ?? NSImage() }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        revalidateLivePublication()
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let targetURL = controller.targetedURL()
        let paths = FinderMenuBuilder.paths(kind: menuKind, selection: selection, target: targetURL)
        for path in paths.prefix(128) {requestStatus(path.path)}
        let creation = paths.count == 1 ? paths.first : nil
        let menu = FinderMenuBuilder.make(paths: paths, snapshot: snapshot,
            settings: FinderMenuSettings.read(), comparisonMark: try? WorkingComparisonMarkSnapshot.read(),
            target: self, actionSelector: #selector(openAction(_:)), creationDirectory: creation,
            extended: NSEvent.modifierFlags.contains(.shift), toolbar: menuKind == .toolbarItemMenu,
            sourceSelection: menuKind == .contextualMenuForItems ? selection : [],
            registrationCandidate: paths.count == 1 ? paths.first:nil,
            cloneDirectory: selection.count == 1 && selection[0].hasDirectoryPath ? selection[0]:targetURL,
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

/// Broad Finder registration is for menu discovery only. All status traffic
/// remains inside the byte-exact roots supplied by authorized publishers.
struct FinderContextDiscovery {
    static var commandDirectories:Set<URL> {[URL(fileURLWithPath:"/",isDirectory:true)]}
    private let snapshot:FinderSnapshot?
    private let foldedRoots:[String:GitPathSet]
    init(snapshot:FinderSnapshot?) {
        self.snapshot=snapshot
        var roots=[String:GitPathSet]()
        for root in snapshot?.roots ?? [] {roots[Self.fold(root),default:[]].insert(root)}
        foldedRoots=roots
    }
    private static func fold(_ path:String)->String {
        path.precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
    }
    func permitsStatus(_ path:String)->Bool {
        guard let snapshot,path.hasPrefix("/"),!path.utf8.contains(0) else{return false}
        if snapshot.overlayRepositoryRoot(for:path) != nil {return true}
        var ancestor=FileTransferPaths.lexicalPath(path)
        // The cached namespace resolver prefers exact bytes, then unique Unicode
        // aliases. New children can resolve through a cached ancestor. Folded
        // roots additionally require the publisher's insensitive-volume policy.
        // No directory enumeration, resource lookup or filesystem probe occurs.
        for _ in 0..<1024 {
            if snapshot.repositoryRoot(for:FileTransferPaths.fileURL(ancestor)) != nil {return true}
            if let matches=foldedRoots[Self.fold(ancestor)],matches.count == 1,let root=matches.first,
               snapshot.overlayPolicies[root]?.caseSensitive == false {return true}
            if ancestor == "/" {return false}
            let next=FileTransferPaths.lexicalPath((ancestor as NSString).deletingLastPathComponent)
            guard !GitReferenceName.equal(next,ancestor) else{return false};ancestor=next
        }
        return false
    }
    static func permitsStatus(_ path:String,snapshot:FinderSnapshot?)->Bool {Self(snapshot:snapshot).permitsStatus(path)}
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
        // Registration has no comparison-tool choice. Preserve its strict
        // request shape when Finder supplies either state of Shift/Control.
        if request.action == .registerRepository {return request.url}
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
        [.inaccessible, .clone, .pull, .fetch, .push, .synchronize],
        [.commit, .svnDCommit, .svnRebase, .svnFetch, .svnIgnore],
        [.diff, .diffLater, .previousDiff],
        [.log, .logSubmodule, .reflog, .referenceBrowser, .daemon, .revisionGraph, .repositoryBrowser, .status, .rebase, .stash, .stashApply, .stashPop, .stashList],
        [.bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset],
        [.editConflict, .resolve, .mergeAbort, .rename, .remove, .removeKeep, .revert, .clean],
        [.lfs],
        [.switchBranch, .merge, .branch, .tag, .export],
        [.initialize, .add, .blame, .ignore, .ignoreDelete],
        [.worktreeCreate, .worktreeList, .submoduleAdd, .submoduleUpdate, .submoduleSync],
        [.formatPatch, .importPatch, .reviewPatch, .sendMail],
        [.transferFiles, .pasteCopy, .pasteMove],
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
            // The Mac registration action has no source mask/order entry.
            // Place it beside Clone without changing the pinned source groups.
            let group = action == .registerRepository ? 0 : groups.firstIndex { action.map($0.contains) ?? false } ?? groups.count
            let sourceRank = action.flatMap { groups.indices.contains(group) ? groups[group].firstIndex(of: $0) : nil }
            let rank = action == .registerRepository ? 3 : sourceRank.map{$0 * 2} ?? Int.max
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
                     creationDirectory: URL? = nil, extended: Bool = false, toolbar: Bool = false, sourceSelection: [URL] = [], registrationCandidate:URL? = nil, cloneDirectory:URL? = nil, clipboardSources: [URL] = [], localizationBundle: Bundle? = nil) -> NSMenu {
        let captions = FinderMenuCaptions(language: settings.language, bundle: localizationBundle ?? Bundle(for: FinderSync.self))
        func image(_ icon: MenuIcon) -> NSImage? { settings.showIcons ? icon.image() : nil }
        let menu = NSMenu(title: "TurtleGit"); menu.autoenablesItems = false
        defer { MenuImageVisibility.apply(to:menu) }
        let normalizedPaths = FinderRequest.normalizedSelection(paths)
        if normalizedPaths.contains(where: { $0.pathComponents.contains(".git") }) { return menu }
        // First-use discovery cannot depend on reading an ungranted directory,
        // cached Git metadata, or successful directory resource lookup. The app
        // receives the candidate and obtains its own folder grant before use.
        let candidate=registrationCandidate.flatMap{FinderRequest.normalizedSelection([$0]).first}.flatMap{candidate in normalizedPaths.count == 1 && GitReferenceName.equal(normalizedPaths[0].path,candidate.path) ? candidate:nil}
        let clone=cloneDirectory.flatMap{FinderRequest.normalizedSelection([$0]).first}.flatMap{!$0.pathComponents.contains(".git") && settings.allowsPath($0.path) ? $0:nil}
        if candidate != nil || clone != nil, !normalizedPaths.contains(where:{snapshot?.repositoryRoot(for:$0) != nil}) {
            guard normalizedPaths.allSatisfy({settings.allowsPath($0.path)}) else{return menu}
            let choices=NSMenu(title:"TurtleGit");choices.autoenablesItems=false
            func add(_ action:RepositoryAction,_ path:URL?) {
                let item=NSMenuItem(title:captions.label(action.title),action:actionSelector,keyEquivalent:"")
                item.target=target;item.image=image(action.icon);item.representedObject=FinderMenuCommand(action:action,paths:path.map{[$0]} ?? []);choices.addItem(item)
            }
            if let clone {
                if settings.visible(.clone,extended:extended) {add(.clone,clone)}
                if settings.visible(.createRepo,extended:extended) {add(.initialize,clone)}
            }
            if let candidate {add(.registerRepository,candidate)}
            for action in [RepositoryAction.settings,.help,.about] {
                if let entry=FinderShellMenuLayout.preferenceEntry(action),settings.visible(entry,extended:extended) {add(action,nil)}
            }
            if toolbar {MenuImageVisibility.apply(to:choices);return choices}
            if !choices.items.isEmpty {let parent=NSMenuItem(title:"TurtleGit",action:nil,keyEquivalent:"");parent.image=image(.turtle);parent.submenu=choices;menu.addItem(parent)}
            return menu
        }
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
        // Source Inaccessible uses its representative folder even when the
        // status cache cannot adopt it. It remains a request, never a grant.
        if let selected=paths.first,FinderShellRules.allows(.inaccessible,flags:shellFlags) {
            let item=NSMenuItem(title:captions.label(RepositoryAction.inaccessible.title),action:actionSelector,keyEquivalent:"")
            item.image=image(RepositoryAction.inaccessible.icon);item.target=target
            item.representedObject=FinderMenuCommand(action:.inaccessible,paths:[selected]);submenu.addItem(item)
        }
        if let candidate {
            let item=NSMenuItem(title:captions.label(RepositoryAction.registerRepository.title),action:actionSelector,keyEquivalent:"")
            item.image=image(RepositoryAction.registerRepository.icon);item.target=target;item.representedObject=FinderMenuCommand(action:.registerRepository,paths:[candidate]);submenu.addItem(item)
        }
        let creationActions = creationDirectory.map {
            FinderCreationMenuContext.read(directory: $0, snapshot: snapshot, extended: extended).actions
        } ?? (toolbar ? [.clone, .initialize] : [])
        for action in creationActions {
            let item = NSMenuItem(title: captions.label(action.title), action: actionSelector, keyEquivalent: "")
            item.image = image(action.icon); item.target = target
            item.representedObject = FinderMenuCommand(action: action, paths: creationDirectory.map { [$0] } ?? []); submenu.addItem(item)
        }
        if let clone,!submenu.items.contains(where:{FinderShellMenuLayout.action($0) == .clone}),settings.visible(.clone,extended:extended) {
            let item=NSMenuItem(title:captions.label(RepositoryAction.clone.title),action:actionSelector,keyEquivalent:"")
            item.image=image(RepositoryAction.clone.icon);item.target=target;item.representedObject=FinderMenuCommand(action:.clone,paths:[clone]);submenu.addItem(item)
        }
        let knownRepository = paths.first.flatMap { snapshot?.repositoryRoot(for: $0) } != nil
        let sharedRepository = snapshot?.commonRepositoryRoot(for: paths) != nil
        if !submenu.items.isEmpty && knownRepository { submenu.addItem(.separator()) }
        for action in RepositoryAction.allCases.filter({ $0 != .registerRepository && $0 != .inaccessible && $0 != .clone && $0 != .initialize && $0 != .worktreeCreate && $0 != .reset && $0 != .diffLater && $0 != .clearComparisonMark && $0 != .transferFiles && !$0.isIgnore && !$0.isLFS && $0.resolveChoice == nil }) {
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
            let singleDirectory = paths.count == 1 && ((try? FileManager.default.attributesOfItem(atPath: paths[0].path)[.type]) as? FileAttributeType) == .typeDirectory
            // The source offers the mask choice for every multi-selection;
            // extensionless items are skipped when writing ignore patterns.
            if !singleDirectory && (paths.count > 1 || paths.contains(where: { IgnoreOptions.extensionSuffix(for: $0.path) != nil })) {
                let title = paths.count == 1 ? "*" + (IgnoreOptions.extensionSuffix(for: paths[0].path) ?? "") : captions.ignoreItems(paths.count, byExtension: true)
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
        // Only real item selections offer the direct source action. Container,
        // sidebar and toolbar paths describe destinations, never dragged sources.
        let capturedSources = FinderRequest.normalizedSelection(sourceSelection)
        if !toolbar, !capturedSources.isEmpty,
           capturedSources.count == paths.count,
           capturedSources.allSatisfy({ source in paths.contains { GitReferenceName.equal($0.path, source.path) } }),
           let request = FinderTransferContext.sourceRequest(selection: sourceSelection, snapshot: snapshot, settings: settings) {
            let item = NSMenuItem(title: captions.label(request.action.title), action: actionSelector, keyEquivalent: "")
            item.image = image(request.action.icon); item.target = target
            item.representedObject = FinderMenuCommand(request: request); submenu.addItem(item)
        }
        if !toolbar, capturedSources.count == paths.count,
           capturedSources.allSatisfy({ source in paths.contains { GitReferenceName.equal($0.path, source.path) } }),
           let request = FinderWorktreeContext.sourceRequest(selection: sourceSelection, snapshot: snapshot) {
            let item = NSMenuItem(title: captions.label(request.action.title), action: actionSelector, keyEquivalent: "")
            item.image = image(request.action.icon); item.target = target
            item.representedObject = FinderMenuCommand(request: request); submenu.addItem(item)
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
        if toolbar { MenuImageVisibility.apply(to:submenu);return submenu }
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

/// Bounded asynchronous hints only. The daemon authenticates this extension and
/// intersects requested paths with its private restored grants before reading.
private final class FinderObservedStatusQueries: @unchecked Sendable {
    private let queue=DispatchQueue(label:"org.turtlegit.macos.finder.observed-status")
    private var pending=GitPathSet(),recent:GitPathMap<Date>=[:]
    private var scheduled=false,retired=false
    private var connection:NSXPCConnection?
    private var requestID:UUID?
    private var retryAfter=Date.distantPast
    private let enabled=FinderIntegration.snapshotURL != nil
    func request(_ path:String,force:Bool=false) {
        guard enabled,path.hasPrefix("/"),path.utf8.count<=1048576,!path.utf8.contains(0) else{return}
        queue.async {[weak self] in
            guard let self,!self.retired,Date()>=self.retryAfter else{return}
            if !force,let last=self.recent[path],Date().timeIntervalSince(last)<2 {return}
            guard self.pending.count<128 || self.pending.contains(path) else{return}
            self.pending.insert(path);self.schedule()
        }
    }
    func retire() {queue.async {[weak self] in guard let self else{return};self.retired=true;self.pending=[];self.requestID=nil;self.connection?.invalidate();self.connection=nil}}
    private func schedule() {
        guard !retired,!scheduled,requestID==nil,!pending.isEmpty else{return};scheduled=true
        queue.asyncAfter(deadline:.now()+0.2) {[weak self] in guard let self else{return};self.scheduled=false;self.send()}
    }
    private func send() {
        guard !retired,requestID==nil,!pending.isEmpty else{return}
        let paths=Array(pending.prefix(128));pending=[]
        do {
            let data=try JSONEncoder().encode(paths);guard data.count<=2*1024*1024 else{return}
            let requirement=try FinderCacheServiceIdentity.requirement(identifier:FinderCacheServiceIdentity.bundleIdentifier,team:FinderCacheServiceIdentity.currentTeam())
            let identity=UUID(),peer=NSXPCConnection(machServiceName:FinderCacheServiceIdentity.queryMachService,options:[])
            requestID=identity;connection=peer
            peer.setCodeSigningRequirement(requirement)
            peer.remoteObjectInterface=NSXPCInterface(with:FinderCacheQueryProtocol.self)
            peer.invalidationHandler={[weak self] in self?.queue.async {[weak self] in self?.finish(identity,success:false)}}
            peer.interruptionHandler=peer.invalidationHandler;peer.resume()
            guard let proxy=peer.remoteObjectProxyWithErrorHandler({[weak self] _ in self?.queue.async {[weak self] in self?.finish(identity,success:false)}}) as? FinderCacheQueryProtocol else{finish(identity,success:false);return}
            for path in paths {recent[path]=Date()};if recent.count>1024 {recent=GitPathMap(recent.sorted {$0.value>$1.value}.prefix(512).map {($0.key,$0.value)},uniquingKeysWith:{_,last in last})}
            proxy.refreshObserved(data) {[weak self] error in self?.queue.async {[weak self] in self?.finish(identity,success:error==nil)}}
            queue.asyncAfter(deadline:.now()+5) {[weak self] in self?.finish(identity,success:false)}
        } catch {retryAfter=Date().addingTimeInterval(5)}
    }
    private func finish(_ identity:UUID,success:Bool) {
        guard requestID==identity else{return};requestID=nil
        let peer=connection;connection=nil;peer?.invalidationHandler=nil;peer?.interruptionHandler=nil;peer?.invalidate()
        if !success {retryAfter=Date().addingTimeInterval(5);pending=[]}
        schedule()
    }
}
