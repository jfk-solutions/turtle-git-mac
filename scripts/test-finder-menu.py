#!/usr/bin/env python3
"""Exercise the actual Finder menu builder without activating an extension."""
import pathlib
import platform
import subprocess
import tempfile
from native_receiver import fingerprint, run_receiver

root = pathlib.Path(__file__).resolve().parent.parent
frameworks = root / 'build/Build/Products/Debug'
driver = r'''
import AppKit
import FinderSync
import TurtleGitCore

@MainActor final class MenuTarget: NSObject {
    @objc func openAction(_ item: NSMenuItem) {}
}
@main struct FinderMenuVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        struct SourceOrder: Decodable { let groups: [[String]] }
        let sourceOrder = try JSONDecoder().decode(SourceOrder.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let mapping: [RepositoryAction: String] = [
            .inaccessible: "Inaccessible",
            .svnDCommit: "SVNDCommit", .svnRebase: "SVNRebase", .svnFetch: "SVNDFetch", .svnIgnore: "SVNIgnore",
            .lfs: "LFSMenu", .reviewPatch: "ApplyPatch", .sendMail: "Sendmail",
            .synchronize: "Sync", .previousDiff: "PrevDiff", .logSubmodule: "LogSubmoduleFolder", .blame: "Blame", .editConflict: "ConflictEditor", .settings: "Settings", .help: "Help", .about: "About",
            .add: "Add", .clone: "Clone", .pull: "Pull", .fetch: "Fetch", .push: "Push", .commit: "Commit",
            .diff: "Diff", .diffLater: "DiffLater", .log: "Log", .daemon: "Daemon", .revisionGraph: "RevisionGraph", .reflog: "RefLog", .referenceBrowser: "RefBrowser", .repositoryBrowser: "RepoBrowse",
            .bisectStart: "BisectStart", .bisectGood: "BisectGood", .bisectBad: "BisectBad", .bisectSkip: "BisectSkip", .bisectReset: "BisectReset",
            .status: "ShowChanged", .rebase: "Rebase", .stash: "StashSave", .stashApply: "StashApply",
            .stashPop: "StashPop", .stashList: "StashList", .resolve: "Resolve", .mergeAbort: "MergeAbort", .rename: "Rename",
            .remove: "Remove", .removeKeep: "RemoveKeep", .revert: "Revert", .clean: "Cleanup", .switchBranch: "Switch",
            .merge: "Merge", .branch: "Branch", .tag: "Tag", .export: "Export", .initialize: "CreateRepo",
            .ignore: "IgnoreSub", .ignoreDelete: "DeleteIgnoreSub", .worktreeList: "Worktree",
            .submoduleAdd: "SubmoduleAdd", .submoduleUpdate: "SubmoduleUpdate", .submoduleSync: "SubmoduleSync", .formatPatch: "FormatPatch", .importPatch: "ImportPatch"
        ]
        let nativeBySource = Dictionary(uniqueKeysWithValues: mapping.map { ($0.value, $0.key) })
        let projected = sourceOrder.groups.map { $0.compactMap { nativeBySource[$0] } }.filter { !$0.isEmpty }
        // Properties adapts Explorer's property page; direct New Worktree
        // adapts DropNewWorktree for an explicitly captured source selection.
        // Neither is a MenuInfo root entry. Verify their exact native positions
        // independently while retaining every mapped source ordering assertion.
        let nativeAdaptations:Set<RepositoryAction>=[.properties,.worktreeCreate]
        precondition(FinderShellMenuLayout.groups.map { $0.filter { !nativeAdaptations.contains($0) && !$0.isFileTransfer } }.filter { !$0.isEmpty } == projected, "Every implemented source root command must preserve pinned MenuInfo order/group")
        let adapted = projected.map { group -> [RepositoryAction] in
            var result=group
            if let settings=result.firstIndex(of:.settings) {result.insert(.properties,at:settings)}
            if let worktrees=result.firstIndex(of:.worktreeList) {result.insert(.worktreeCreate,at:worktrees)}
            return result
        }
        precondition(FinderShellMenuLayout.groups.map { $0.filter { !$0.isFileTransfer } }.filter { !$0.isEmpty } == adapted, "Native Properties must precede Settings and source-selection New Worktree must precede Worktrees")
        precondition(Set(projected.flatMap { $0 }) == Set(mapping.keys))
        func allCommands(showIcons: Bool = true) -> FinderMenuSettings {
            var settings = FinderMenuSettings(showIcons: showIcons)
            settings.topLevelMask = 0; settings.extendedOnlyMask = 0
            return settings
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let untracked = folder.appendingPathComponent("new.txt"), tracked = folder.appendingPathComponent("tracked.txt")
        let conflict = folder.appendingPathComponent("conflict.txt")
        for path in [untracked, tracked, conflict] { try Data("fixture".utf8).write(to: path) }
        let snapshot = FinderSnapshot(roots: [folder.path], states: [folder.path: .conflicted,
            untracked.path: .untracked, tracked.path: .normal, conflict.path: .conflicted])
        let target = MenuTarget(), selector = #selector(MenuTarget.openAction(_:))
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        func signatures(_ menu: NSMenu) -> [String] {
            items(menu).map { "\($0.title)|\($0.isEnabled)|\(($0.representedObject as? FinderMenuCommand)?.url()?.absoluteString ?? "")|\($0.state.rawValue)" }
        }
        func verifyOrder(_ menu: NSMenu) {
            let roots = menu.items.first?.submenu ?? menu
            var actual: [[RepositoryAction]] = [[]]
            for item in roots.items {
                if item.isSeparatorItem { precondition(!actual.last!.isEmpty); actual.append([]) }
                else { actual[actual.count - 1].append(FinderShellMenuLayout.action(item)!) }
            }
            if !roots.items.isEmpty { precondition(!actual.last!.isEmpty) }
            let visible = Set(actual.flatMap { $0 })
            let expected = adapted.map { $0.filter { visible.contains($0) } }.filter { !$0.isEmpty }
            precondition(actual.filter { !$0.isEmpty } == expected, "Visible menu groups must match independent source projection")
            precondition(!visible.contains(.worktreeCreate), "A baseline without an explicit source selection must not offer direct New Worktree")
        }
        func make(_ paths: [URL], settings: FinderMenuSettings, mark: WorkingComparisonMarkSnapshot? = nil) -> NSMenu {
            FinderMenuBuilder.make(paths: paths, snapshot: snapshot, settings: settings,
                comparisonMark: mark, target: target, actionSelector: selector)
        }
        // Diagnose a root that cannot enter the cache-backed repository loop.
        // Source keeps this entry top-level and outside configurable menu rows.
        let inaccessible = folder.appendingPathComponent("inaccessible", isDirectory: true)
        try FileManager.default.createDirectory(at: inaccessible, withIntermediateDirectories: false)
        try Data("gitdir: absent\n".utf8).write(to: inaccessible.appendingPathComponent(".git"))
        var diagnosticPolicy=allCommands();diagnosticPolicy.extendedOnlyMask=FinderMenuEntry.allMask
        for icons in [true,false] {
            diagnosticPolicy.showIcons=icons
            let menu=FinderMenuBuilder.make(paths:[inaccessible,tracked],snapshot:nil,settings:diagnosticPolicy,
                comparisonMark:nil,target:target,actionSelector:selector)
            let diagnostic=menu.items.filter {FinderShellMenuLayout.action($0) == .inaccessible}
            precondition(diagnostic.count==1,"Inaccessible must remain a single top-level command without a cached root")
            let item=diagnostic[0],command=item.representedObject as! FinderMenuCommand
            precondition(item.isEnabled && item.target === target && item.action==selector)
            precondition((item.image != nil)==icons)
            let expected=FinderRequest(action:.inaccessible,paths:[inaccessible])
            precondition(command.request.action == .inaccessible && command.request.paths.count==1 &&
                         command.request.paths.map {Data($0.path.utf8)} == expected.paths.map {Data($0.path.utf8)} &&
                         command.request.url == expected.url,"Only the normalized representative folder is captured")
            precondition(!items(menu).contains {FinderShellMenuLayout.action($0) == .commit})
        }
        diagnosticPolicy.excludedPaths=inaccessible.path
        let excludedDiagnostic=FinderMenuBuilder.make(paths:[inaccessible],snapshot:nil,settings:diagnosticPolicy,
            comparisonMark:nil,target:target,actionSelector:selector)
        precondition(!items(excludedDiagnostic).contains {FinderShellMenuLayout.action($0) == .inaccessible},"Global path exclusions also suppress diagnosis")
        print("PASS Finder inaccessible entry: unknown root, forced top-level/unextended, original icon policy, one representative path and global exclusion; no extension activation or trust mutation.")
        for paths in [[untracked], [tracked], [conflict], [folder], [untracked, tracked], []] {
            let enabled = make(paths, settings: allCommands())
            let disabled = make(paths, settings: allCommands(showIcons: false))
            verifyOrder(enabled); verifyOrder(disabled)
            precondition(signatures(enabled) == signatures(disabled), "Preference must preserve command conditions/routing")
            precondition(items(enabled).filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
            precondition(items(disabled).allSatisfy { $0.image == nil }, "Parent, nested ignore and ordinary action icons must all be disabled")
            // AppKit installs its own actions on submenu headers; only command
            // metadata items route to the extension's openAction selector.
            for item in items(disabled) where item.representedObject is FinderMenuCommand {
                precondition(item.target === target && item.action == selector)
            }
        }
        // Exercise real menu placement and presentation policy independently of
        // the all-visible baseline matrix used below.
        var policy = FinderMenuSettings()
        func policyMenu(_ selected: [URL], snapshot cached: FinderSnapshot? = snapshot, extended: Bool = false, toolbar: Bool = false) -> NSMenu {
            FinderMenuBuilder.make(paths: selected, snapshot: cached, settings: policy, comparisonMark: nil,
                target: target, actionSelector: selector, creationDirectory: selected.count == 1 ? selected.first : nil, extended: extended, toolbar: toolbar)
        }
        let defaultsMenu = policyMenu([folder])
        precondition(defaultsMenu.items.contains { FinderShellMenuLayout.action($0) == .commit }, "Commit must appear directly in the main menu")
        let defaultParent = defaultsMenu.items.first { $0.title == "TurtleGit" }!
        precondition(defaultParent.submenu!.items.contains { FinderShellMenuLayout.action($0) == .log })
        precondition(!defaultParent.submenu!.items.contains { FinderShellMenuLayout.action($0) == .commit })
        let propertyMenu = make([tracked], settings: allCommands())
        let propertyItem = items(propertyMenu).first { FinderShellMenuLayout.action($0) == .properties }!
        precondition(propertyItem.isEnabled && propertyItem.image != nil, "Native Properties action/icon missing")
        var propertyPolicy = allCommands(); propertyPolicy.topLevelMask = FinderMenuEntry.settings.mask
        let directProperty = make([tracked], settings: propertyPolicy).items.first { FinderShellMenuLayout.action($0) == .properties }!
        precondition(directProperty.title == RepositoryAction.properties.title && directProperty.image != nil)
        propertyPolicy.extendedOnlyMask = FinderMenuEntry.settings.mask
        precondition(!items(make([tracked], settings: propertyPolicy)).contains { FinderShellMenuLayout.action($0) == .properties })
        let shiftedProperty = FinderMenuBuilder.make(paths: [tracked], snapshot: snapshot, settings: propertyPolicy, comparisonMark: nil, target: target, actionSelector: selector, extended: true)
        precondition(items(shiftedProperty).contains { FinderShellMenuLayout.action($0) == .properties })
        let rich = FinderSnapshot(roots: [folder.path], states: [folder.path: .normal], repositories: [folder.path: FinderRepositoryMetadata(hasStash: true, hasSubmoduleConfig: true)])
        precondition(!items(policyMenu([folder], snapshot: rich)).contains { FinderShellMenuLayout.action($0) == .stashApply || FinderShellMenuLayout.action($0) == .submoduleSync })
        precondition(items(policyMenu([folder], snapshot: rich, extended: true)).contains { FinderShellMenuLayout.action($0) == .stashApply })
        precondition(items(policyMenu([folder], snapshot: rich, extended: true)).contains { FinderShellMenuLayout.action($0) == .submoduleSync })
        policy.topLevelMask = FinderMenuEntry.ignore.mask
        let directIgnore = policyMenu([untracked]).items.first { FinderShellMenuLayout.action($0) == .ignore }!
        precondition(directIgnore.submenu!.items.count == 2 && directIgnore.image != nil, "Moved group retains nested choices and icon")
        for child in directIgnore.submenu!.items {
            precondition((child.representedObject as! FinderMenuCommand).request.paths == [untracked])
            precondition(child.action == selector && child.target === target)
        }
        policy.topLevelMask = FinderMenuEntry.allMask
        let allDirect = policyMenu([folder], extended: true)
        precondition(!allDirect.items.contains { $0.title == "TurtleGit" }, "Empty submenu is omitted")
        precondition(allDirect.items.last?.isSeparatorItem != true && allDirect.items.first?.isSeparatorItem != true)
        let toolbarPolicy = policyMenu([folder], extended: true, toolbar: true)
        precondition(!toolbarPolicy.items.contains { $0.title == "TurtleGit" })
        policy.excludedPaths = untracked.path
        precondition(policyMenu([untracked], extended: true).items.isEmpty, "Shift cannot bypass path exclusions")
        let filtered = policyMenu([untracked, conflict])
        for item in items(filtered) where item.representedObject is FinderMenuCommand {
            precondition((item.representedObject as! FinderMenuCommand).request.paths == [conflict], "Excluded paths must never reach a command")
        }
        policy.excludedPaths = ""; policy.hideForUnversioned = true
        let outsideFolder = folder.deletingLastPathComponent()
        precondition(policyMenu([outsideFolder], snapshot: nil).items.isEmpty)
        precondition(!policyMenu([outsideFolder], snapshot: nil, extended: true).items.isEmpty)
        precondition(!policyMenu([untracked]).items.isEmpty, "Untracked items inside a repository retain their menu")
        for selected in [[folder], [tracked], []] {
            let menu = FinderMenuBuilder.make(paths: selected, snapshot: nil, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector)
            let utilities = items(menu).compactMap { $0.representedObject as? FinderMenuCommand }.filter { $0.request.action.isApplicationUtility }
            precondition(Set(utilities.map { $0.request.action }) == [.settings, .help, .about])
            for command in utilities { precondition(FinderRequest(url: command.url()!)!.action == command.request.action) }
        }
        let syncMenu = policyMenu([folder], snapshot: rich)
        precondition(items(syncMenu).contains { FinderShellMenuLayout.action($0) == .synchronize && $0.title.hasPrefix("Git ") }, "Source Sync default is first level")
        let conflictMenu = make([conflict], settings: allCommands())
        precondition(items(conflictMenu).contains { FinderShellMenuLayout.action($0) == .editConflict && $0.isEnabled })
        print("Context Menu policy: default/direct placement, Shift-only defaults, nested ignore routing/icons, all-direct omission, toolbar, exclusions and unversioned membership pass against the actual builder.")
        let ignoring = items(make([untracked], settings: allCommands()))
        precondition(ignoring.contains { $0.title == "Add to ignore list" && $0.submenu?.items.count == 2 })
        for name in [".profile", "trailing.", "extensionless"] {
            let path = folder.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: path)
            let live = FinderSnapshot(roots: [folder.path], states: [path.path: .untracked])
            let menu = FinderMenuBuilder.make(paths: [path], snapshot: live, settings: allCommands(),
                comparisonMark: nil, target: target, actionSelector: selector)
            let masks = items(menu).filter { ($0.representedObject as? FinderMenuCommand)?.request.action == .ignoreMask }
            precondition(masks.count == (name == "extensionless" ? 0 : 1))
            if name != "extensionless" { precondition(masks[0].title == "*" + IgnoreOptions.extensionSuffix(for: path.path)!) }
        }
        let noExtension = [folder.appendingPathComponent("first"), folder.appendingPathComponent("second")]
        for path in noExtension { try Data("fixture".utf8).write(to: path) }
        let noExtensionSnapshot = FinderSnapshot(roots: [folder.path], states: GitPathMap(uniqueKeysWithValues: noExtension.map { ($0.path, FileState.untracked) }))
        let noExtensionMenu = FinderMenuBuilder.make(paths: noExtension, snapshot: noExtensionSnapshot, settings: allCommands(),
            comparisonMark: nil, target: target, actionSelector: selector)
        precondition(items(noExtensionMenu).contains { ($0.representedObject as? FinderMenuCommand)?.request.action == .ignoreMask }, "Source multi-selection offers mask even without extensions")
        let versioned = items(make([tracked], settings: allCommands()))
        precondition(versioned.contains { $0.title == "Delete and add to ignore list" && $0.submenu?.items.count == 2 })
        precondition(versioned.contains { ($0.representedObject as? FinderMenuCommand)?.request.action == .remove && $0.isEnabled })
        let conflicted = items(make([conflict], settings: allCommands()))
        precondition(conflicted.contains { ($0.representedObject as? FinderMenuCommand)?.request.action == .resolve && $0.isEnabled })
        let mark = WorkingComparisonMarkSnapshot(id: UUID(), path: "/other/marked.txt")
        let marked = items(make([tracked], settings: allCommands(showIcons: false), mark: mark))
        precondition(marked.contains { $0.title == "Compare with /other/marked.txt" && $0.image == nil })
        let cache = folder.appendingPathComponent("shared/menu-settings.json")
        try allCommands(showIcons: false).write(to: cache)
        precondition(items(make([tracked], settings: FinderMenuSettings.read(from: cache))).allSatisfy { $0.image == nil })
        try allCommands().write(to: cache)
        precondition(items(make([tracked], settings: FinderMenuSettings.read(from: cache))).filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside 雪", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        func creation(_ directory: URL?, toolbar: Bool = false, extended: Bool = false) -> [NSMenuItem] {
            items(FinderMenuBuilder.make(paths: directory.map { [$0] } ?? [], snapshot: snapshot,
                settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector,
                creationDirectory: directory, extended: extended, toolbar: toolbar))
        }
        for (directory, toolbar) in [(outside as URL?, false), (nil, true)] {
            let commands = creation(directory, toolbar: toolbar).filter { !$0.isSeparatorItem && $0.submenu == nil && FinderShellMenuLayout.action($0)?.isApplicationUtility != true }
            precondition(commands.map(\.title) == [RepositoryAction.clone.title, RepositoryAction.initialize.title])
            for item in commands {
                let command = item.representedObject as! FinderMenuCommand
                let request = command.request
                precondition(request.paths.map(\.path) == directory.map { [$0.standardizedFileURL.path] } ?? [] && item.target === target && item.action == selector)
                let url = command.url()!
                precondition(FinderRequest(url: url)?.action == request.action)
                precondition(FinderRequest(url: url)?.paths.map(\.path) == directory.map { [$0.standardizedFileURL.path] } ?? [])
            }
        }
        var selection = [untracked, tracked]
        let captured = items(make(selection, settings: allCommands()))
        selection = [conflict]
        for item in captured {
            guard let command = item.representedObject as? FinderMenuCommand else { continue }
            precondition(command.request.paths.map(\.path) == FinderRequest(action: command.request.action, paths: [untracked, tracked]).paths.map(\.path))
            precondition(FinderRequest(url: command.url()!)?.paths.map(\.path) == command.request.paths.map(\.path))
            precondition(FinderRequest(url: command.url(control: true)!)?.action == command.request.action, "Control must not change unrelated actions")
            for alternate in [false,true] {
                let delivered=FinderRequest(url:command.url(alternate:alternate)!)!
                precondition(delivered.alternateTool==alternate && delivered.action==command.request.action && delivered.paths.map(\.path)==command.request.paths.map(\.path))
            }

        }
        // Native first-use discovery is independent of the pinned creation
        // clauses above. A candidate conveys intent, never authority or proof
        // of existence; even unavailable resource metadata cannot hide entry.
        let unavailable=folder.deletingLastPathComponent().appendingPathComponent("not granted/not present 雪",isDirectory:false)
        precondition(!FileManager.default.fileExists(atPath:unavailable.path))
        for icons in [false,true] {
            var discoverySettings=allCommands(showIcons:icons);discoverySettings.hideForUnversioned=true
            let discovery=FinderMenuBuilder.make(paths:[unavailable],snapshot:nil,settings:discoverySettings,comparisonMark:nil,target:target,actionSelector:selector,registrationCandidate:unavailable,cloneDirectory:unavailable)
            let leaves=items(discovery).filter{$0.representedObject is FinderMenuCommand}
            precondition(leaves.compactMap{FinderShellMenuLayout.action($0)} == [.clone,.initialize,.registerRepository,.settings,.help,.about])
            for item in items(discovery) where !item.isSeparatorItem {
                precondition((item.image != nil) == icons,"First-use parents and leaves respect the Finder icon setting")
                if icons,#available(macOS 27.0,*) {
                    precondition(item.responds(to:NSSelectorFromString("preferredImageVisibility")))
                    precondition((item.value(forKey:"preferredImageVisibility") as? NSNumber)?.intValue == 1,"Public macOS27 image visibility must be explicitly visible")
                }
            }
            let registration=leaves.first{FinderShellMenuLayout.action($0) == .registerRepository}!
            let request=(registration.representedObject as! FinderMenuCommand).request
            let expected=FinderRequest(action:.registerRepository,paths:[unavailable])
            precondition(request.paths.count == 1 && request.paths.map{Data($0.path.utf8)} == expected.paths.map{Data($0.path.utf8)})
            precondition(registration.target === target && registration.action == selector && FinderRequest(url:request.url!)?.action == .registerRepository)
            let registrationCommand=registration.representedObject as! FinderMenuCommand
            for alternate in [false,true] {
                for control in [false,true] {
                    guard let callbackURL=registrationCommand.url(control:control,alternate:alternate),let decoded=FinderRequest(url:callbackURL) else {preconditionFailure("Registration callback modifiers must retain a valid typed request")}
                    precondition(decoded.action == .registerRepository && decoded.alternateTool == nil)
                    precondition(decoded.paths.map{Data($0.path.utf8)} == expected.paths.map{Data($0.path.utf8)})
                }
            }
            let toolbar=FinderMenuBuilder.make(paths:[unavailable],snapshot:nil,settings:discoverySettings,comparisonMark:nil,target:target,actionSelector:selector,toolbar:true,registrationCandidate:unavailable,cloneDirectory:unavailable)
            precondition(toolbar.items.compactMap{FinderShellMenuLayout.action($0)} == [.clone,.initialize,.registerRepository,.settings,.help,.about])
            if icons,#available(macOS 27.0,*) {precondition(toolbar.items.allSatisfy{($0.value(forKey:"preferredImageVisibility") as? NSNumber)?.intValue == 1})}
            discoverySettings.extendedOnlyMask=FinderMenuEntry.clone.mask | FinderMenuEntry.createRepo.mask
            let masked=FinderMenuBuilder.make(paths:[unavailable],snapshot:nil,settings:discoverySettings,comparisonMark:nil,target:target,actionSelector:selector,registrationCandidate:unavailable,cloneDirectory:unavailable)
            precondition(!items(masked).contains{[RepositoryAction.clone,.initialize].contains(FinderShellMenuLayout.action($0) ?? .about)})
            precondition(items(masked).contains{FinderShellMenuLayout.action($0) == .registerRepository},"Mac registration has no invented source mask")
            discoverySettings.excludedPaths=unavailable.path
            precondition(FinderMenuBuilder.make(paths:[unavailable],snapshot:nil,settings:discoverySettings,comparisonMark:nil,target:target,actionSelector:selector,registrationCandidate:unavailable,cloneDirectory:unavailable).items.isEmpty)
        }
        precondition(FinderContextDiscovery.commandDirectories == [URL(fileURLWithPath:"/",isDirectory:true)])
        precondition(!FinderContextDiscovery.permitsStatus(unavailable.path,snapshot:nil))
        precondition(!FinderContextDiscovery.permitsStatus(unavailable.path,snapshot:snapshot))
        precondition(FinderContextDiscovery.permitsStatus(folder.path,snapshot:snapshot))
        precondition(FinderContextDiscovery.permitsStatus(tracked.path,snapshot:snapshot))
        precondition(!FinderContextDiscovery.permitsStatus(folder.path+"-other/file",snapshot:snapshot))
        let composedRoot="/cached-only/Caf\u{00e9}",decomposedRoot="/cached-only/Cafe\u{0301}"
        let canonicalSnapshot=FinderSnapshot(roots:[composedRoot],states:[composedRoot:.normal])
        let canonicalAdmission=FinderContextDiscovery(snapshot:canonicalSnapshot)
        precondition(canonicalAdmission.permitsStatus(decomposedRoot+"/new/not-yet-cached.txt"),"New children under a unique cached Unicode alias retain status admission")
        precondition(!canonicalAdmission.permitsStatus(decomposedRoot+"-sibling/new.txt"),"Component ownership never widens to sibling prefixes")
        let caseRoot="/cached-only/CaseRoot"
        let insensitive=FinderSnapshot(roots:[caseRoot],states:[caseRoot:.normal],overlayPolicies:[caseRoot:.init(identity:"fixture",caseSensitive:false)])
        precondition(FinderContextDiscovery(snapshot:insensitive).permitsStatus("/CACHED-ONLY/caseroot/new/child"))
        let sensitive=FinderSnapshot(roots:[caseRoot],states:[caseRoot:.normal],overlayPolicies:[caseRoot:.init(identity:"fixture",caseSensitive:true)])
        precondition(!FinderContextDiscovery(snapshot:sensitive).permitsStatus("/cached-only/caseroot/new/child"),"Sensitive roots cannot authorize a differently cased sibling")
        let lowerRoot="/cached-only/caseroot"
        let ambiguousCase=FinderSnapshot(roots:[caseRoot,lowerRoot],states:[caseRoot:.normal,lowerRoot:.normal],overlayPolicies:[caseRoot:.init(identity:"fixture",caseSensitive:false),lowerRoot:.init(identity:"fixture",caseSensitive:false)])
        precondition(!FinderContextDiscovery(snapshot:ambiguousCase).permitsStatus("/cached-only/CASEROOT/new"),"Ambiguous folded roots never choose an arbitrary owner")
        precondition(FinderContextDiscovery(snapshot:ambiguousCase).permitsStatus(caseRoot+"/new"),"Exact byte ownership stays available even with alias peers")
        let angstromA="/cached-only/\u{00c5}",angstromB="/cached-only/A\u{030a}"
        let ambiguousUnicode=FinderSnapshot(roots:[angstromA,angstromB],states:[angstromA:.normal,angstromB:.normal])
        precondition(!FinderContextDiscovery(snapshot:ambiguousUnicode).permitsStatus("/cached-only/\u{212b}/new"),"A third canonical spelling cannot choose between byte-distinct roots")
        let knownDiscovery=FinderMenuBuilder.make(paths:[folder],snapshot:snapshot,settings:allCommands(),comparisonMark:nil,target:target,actionSelector:selector,registrationCandidate:folder,cloneDirectory:folder)
        precondition(items(knownDiscovery).filter{FinderShellMenuLayout.action($0) == .clone}.count == 1)
        precondition(items(knownDiscovery).contains{FinderShellMenuLayout.action($0) == .registerRepository})
        precondition(items(knownDiscovery).contains{FinderShellMenuLayout.action($0) == .commit},"Known repository commands remain present")
        print("First-use discovery: unavailable metadata candidate, typed single selection, Clone/Create masks, icon preferences/SDK visibility, known commands, and namespace-only status admission passed.")
        let containerPaths = FinderMenuBuilder.paths(kind: .contextualMenuForContainer, selection: [tracked], target: folder)
        for item in items(make(containerPaths, settings: allCommands())) {
            if let command = item.representedObject as? FinderMenuCommand {
                precondition(command.request.paths.map(\.path) == [folder.standardizedFileURL.path])
            }
        }
        let ignoredCommands = ignoring.compactMap { $0.representedObject as? FinderMenuCommand }.filter { $0.request.action.isIgnore }
        precondition(ignoredCommands.count == 2 && ignoredCommands.allSatisfy { $0.request.paths.map(\.path) == FinderRequest(action: .ignore, paths: [untracked]).paths.map(\.path) })
        let compare = marked.compactMap { $0.representedObject as? FinderMenuCommand }.first { $0.request.action == .diffLater }!
        precondition(FinderRequest(url: compare.url()!)?.action == .diffLater)
        precondition(FinderRequest(url: compare.url(control: true)!)?.action == .clearComparisonMark)
        precondition(FinderRequest(url:compare.url(alternate:true)!)?.alternateTool==true)
        precondition(FinderRequest(url:compare.url(control:true,alternate:true)!)?.action == .clearComparisonMark)
        precondition(FinderRequest(url:compare.url(control:true,alternate:true)!)?.alternateTool == nil)

        precondition(FinderRequest(url: compare.url(control: true)!)?.paths.map(\.path) == compare.request.paths.map(\.path))
        let unusual = folder.appendingPathComponent("literal 雪\n&?.txt")
        let literal = FinderMenuCommand(action: .removeKeep, paths: [unusual, tracked, unusual])
        let decoded = FinderRequest(url: literal.url()!)!
        precondition(decoded.action == .removeKeep && decoded.paths.count == 2)
        precondition(decoded.paths.first?.lastPathComponent == "literal 雪\n&?.txt")
        precondition(decoded.paths.map(\.path) == literal.request.paths.map(\.path))
        print("Actual command receiver: ordinary/multi-file/container/nested-ignore/comparison requests retain menu-time selection; Control only clears the comparison mark. No activation/handoff performed.")
        let cleanMenu = make([folder], settings: allCommands())
        let cleanItem = items(cleanMenu).first { ($0.representedObject as? FinderMenuCommand)?.request.action == .clean }!
        precondition(cleanItem.isEnabled && cleanItem.image != nil && cleanItem.title == "Clean up…")
        let cleanRequest = FinderRequest(url: (cleanItem.representedObject as! FinderMenuCommand).url()!)!
        precondition(cleanRequest.action == .clean && cleanRequest.paths.map { Array($0.path.utf8) } == [Array(folder.path.utf8)])
        precondition(items(make([tracked], settings: allCommands())).allSatisfy { ($0.representedObject as? FinderMenuCommand)?.request.action != .clean })
        let toolbarMenu = FinderMenuBuilder.make(paths: [], snapshot: snapshot, settings: allCommands(),
            comparisonMark: nil, target: target, actionSelector: selector, toolbar: true)
        precondition(toolbarMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [RepositoryAction.clone.title, RepositoryAction.initialize.title, RepositoryAction.settings.title, RepositoryAction.help.title, RepositoryAction.about.title], "Toolbar commands should appear directly")
        verifyOrder(toolbarMenu)
        precondition(toolbarMenu.items.count == 7 && toolbarMenu.items[1].isSeparatorItem && toolbarMenu.items[3].isSeparatorItem)
        precondition(creation(folder).allSatisfy { !(($0.representedObject as? FinderMenuCommand).map { [.clone, .initialize].contains($0.request.action) } ?? false) })
        precondition(creation(folder, extended: true).compactMap { ($0.representedObject as? FinderMenuCommand).flatMap { [.clone, .initialize].contains($0.request.action) ? $0.request.action : nil } } == [.clone])
        let admin = folder.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        precondition(creation(admin, extended: true).isEmpty)
        precondition(FinderMenuBuilder.paths(kind: .contextualMenuForContainer, selection: [tracked], target: folder) == [folder])
        precondition(FinderMenuBuilder.paths(kind: .contextualMenuForItems, selection: [tracked], target: folder) == [tracked])
        precondition(FinderMenuBuilder.paths(kind: .toolbarItemMenu, selection: [tracked], target: nil).isEmpty)
        print("Actual creation menu receiver: outside folder and targetless toolbar Clone/Create only, captured target routing and URL round-trip, versioned Shift rules, admin exclusion and container/item/toolbar selection passed. Activated Finder and native dialog handoff remain pending.")
        func metadataMenu(_ info: FinderRepositoryMetadata) -> NSMenu {
            let cached = FinderSnapshot(roots: snapshot.roots, states: snapshot.states, repositories: [folder.path: info])
            return FinderMenuBuilder.make(paths: [folder], snapshot: cached, settings: allCommands(),
                comparisonMark: nil, target: target, actionSelector: selector)
        }
        func rootActions(_ menu: NSMenu) -> Set<RepositoryAction> {
            let roots = menu.items.flatMap { $0.title == "TurtleGit" ? ($0.submenu?.items ?? []) : [$0] }
            // Source command-set comparisons exclude the independently checked native property-page adaptation.
            return Set(roots.compactMap(FinderShellMenuLayout.action).filter { !$0.isApplicationUtility && $0 != .properties })
        }
        let lfsSnapshot = FinderSnapshot(roots: [folder.path], states: [folder.path: .normal, tracked.path: .normal, untracked.path: .untracked], repositories: [folder.path: FinderRepositoryMetadata(hasLFS: true)])
        func lfsMenu(_ paths: [URL], settings: FinderMenuSettings = allCommands(), extended: Bool = false) -> NSMenu {
            FinderMenuBuilder.make(paths: paths, snapshot: lfsSnapshot, settings: settings, comparisonMark: nil, target: target, actionSelector: selector, extended: extended)
        }
        let folderLFS = items(lfsMenu([folder])).first { FinderShellMenuLayout.action($0) == .lfs }!
        precondition(folderLFS.submenu!.items.compactMap(FinderShellMenuLayout.action) == [.lfsLocks])
        let fileLFS = items(lfsMenu([tracked])).first { FinderShellMenuLayout.action($0) == .lfs }!
        precondition(fileLFS.submenu!.items.compactMap(FinderShellMenuLayout.action) == [.lfsLock, .lfsUnlock])
        for item in fileLFS.submenu!.items {
            let request = (item.representedObject as! FinderMenuCommand).request
            precondition(request.paths == [tracked] && item.target === target && item.action == selector && item.image != nil)
        }
        precondition(!items(lfsMenu([untracked])).contains { FinderShellMenuLayout.action($0) == .lfs })
        precondition(!items(make([tracked], settings: allCommands())).contains { FinderShellMenuLayout.action($0) == .lfs }, "Legacy/missing LFS metadata hides the group")
        var lfsPolicy = allCommands(); lfsPolicy.topLevelMask = FinderMenuEntry.lfs.mask
        let directLFS = lfsMenu([tracked], settings: lfsPolicy)
        precondition(directLFS.items.first?.title == "Git LFS" && directLFS.items.first?.submenu?.items.count == 2)
        lfsPolicy.extendedOnlyMask = FinderMenuEntry.lfs.mask
        precondition(!items(lfsMenu([tracked], settings: lfsPolicy)).contains { FinderShellMenuLayout.action($0) == .lfs })
        precondition(items(lfsMenu([tracked], settings: lfsPolicy, extended: true)).contains { FinderShellMenuLayout.action($0) == .lfs })
        lfsPolicy.showIcons = false
        precondition(items(lfsMenu([tracked], settings: lfsPolicy, extended: true)).allSatisfy { $0.image == nil })
        let patchFile = folder.appendingPathComponent("mail 雪\n.patch"); try Data().write(to: patchFile)
        for (selected, extended) in [([patchFile], false), ([tracked], true)] {
            let menu = FinderMenuBuilder.make(paths: selected, snapshot: nil, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector, extended: extended)
            let mail = items(menu).first { FinderShellMenuLayout.action($0) == .sendMail }!
            precondition((mail.representedObject as! FinderMenuCommand).request.paths.map { Array($0.path.utf8) } == selected.map { Array($0.path.utf8) } && mail.image != nil)
        }
        for (selected, extended) in [([patchFile], false), ([tracked], true)] {
            let menu = FinderMenuBuilder.make(paths: selected, snapshot: nil, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector, extended: extended)
            let item = items(menu).first { FinderShellMenuLayout.action($0) == .reviewPatch }!
            let request = (item.representedObject as! FinderMenuCommand).request
            precondition(request.paths.map { Array($0.path.utf8) } == selected.map { Array($0.path.utf8) } && item.image != nil && FinderRequest(url: request.url!)?.action == .reviewPatch)
        }
        let severalPatches = FinderMenuBuilder.make(paths: [patchFile, tracked], snapshot: nil, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector, extended: true)
        precondition(!items(severalPatches).contains { FinderShellMenuLayout.action($0) == .reviewPatch })
        var reviewPolicy = allCommands(); reviewPolicy.topLevelMask = FinderMenuEntry.applyPatch.mask
        let topReview = FinderMenuBuilder.make(paths: [patchFile], snapshot: nil, settings: reviewPolicy, comparisonMark: nil, target: target, actionSelector: selector)
        precondition(topReview.items.contains { FinderShellMenuLayout.action($0) == .reviewPatch && $0.title.hasPrefix("Git ") })
        reviewPolicy.showIcons = false
        let noIcon = FinderMenuBuilder.make(paths: [patchFile], snapshot: nil, settings: reviewPolicy, comparisonMark: nil, target: target, actionSelector: selector)
        precondition(items(noIcon).allSatisfy { $0.image == nil })
        print("Finder Review Patch: single patch and Extended file clauses, captured Unicode/newline request, original artwork, first-level placement and icon suppression passed.")
        precondition(!items(make([tracked], settings: allCommands())).contains { FinderShellMenuLayout.action($0) == .sendMail })
        print("Actual Finder LFS/Send Mail: cached marker, folder/file nested commands, original icons and selectors, captured URL paths, first-level/Shift/icon policies and outside-repository patch/extended mail gates passed.")
        let trackedActions = rootActions(make([tracked], settings: allCommands()))
        precondition(trackedActions == [.commit, .diff, .diffLater, .previousDiff, .blame, .log, .daemon, .revisionGraph, .status, .stash, .rename, .remove, .removeKeep, .ignoreDelete], "Unchanged tracked file must have source file commands, not folder commands or Revert")
        let addedFile = folder.appendingPathComponent("added.txt"); try Data().write(to: addedFile)
        let addedSnapshot = FinderSnapshot(roots: [folder.path], states: [addedFile.path: .added], repositories: [folder.path: FinderRepositoryMetadata()])
        let addedMenu = FinderMenuBuilder.make(paths: [addedFile], snapshot: addedSnapshot, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector)
        precondition(rootActions(addedMenu) == [.commit, .diff, .diffLater, .status, .stash, .rename, .revert, .ignoreDelete], "Added paths exclude history and removal")
        verifyOrder(addedMenu)
        let multiple = rootActions(make([tracked, conflict], settings: allCommands()))
        precondition(multiple == [.commit, .diff, .status, .remove, .removeKeep, .ignoreDelete], "Two files use the representative normal status, excluding later conflict and single-selection commands")
        let untrackedFolder = folder.appendingPathComponent("new-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: untrackedFolder, withIntermediateDirectories: true)
        let creationRules = FinderCreationMenuContext.read(directory: untrackedFolder, snapshot: snapshot, extended: false)
        precondition(creationRules.folderInGit && creationRules.actions.isEmpty, "Untracked folders inside a worktree retain folder-in-Git metadata")
        precondition(FinderCreationMenuContext.read(directory: untrackedFolder, snapshot: snapshot, extended: true).actions == [.clone, .initialize])
        precondition(FinderMenuBuilder.make(paths: [tracked, admin], snapshot: snapshot, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector).items.isEmpty)
        print("Actual path menu receiver: exact tracked/added/two-file command sets, untracked worktree-folder creation and mixed admin exclusion passed. Full submodule and selection classification remains pending.")
        let svnRoot = metadataMenu(FinderRepositoryMetadata(hasGitSVN: true))
        verifyOrder(svnRoot)
        precondition([RepositoryAction.svnDCommit, .svnRebase, .svnFetch, .svnIgnore].allSatisfy { rootActions(svnRoot).contains($0) })
        let svnMerge = metadataMenu(FinderRepositoryMetadata(mergeActive: true, hasGitSVN: true))
        precondition(!rootActions(svnMerge).contains(.svnDCommit) && !rootActions(svnMerge).contains(.svnRebase))
        precondition(rootActions(svnMerge).contains(.svnFetch) && rootActions(svnMerge).contains(.svnIgnore))
        print("Finder SVN: cached .metadata marker exposes all four original-icon groups in source order; merge excludes DCommit/Rebase while retaining Fetch/Ignore.")
        let ordinary = metadataMenu(FinderRepositoryMetadata())
        verifyOrder(ordinary)
        precondition(!rootActions(ordinary).contains(.stashApply) && !rootActions(ordinary).contains(.stashPop) && !rootActions(ordinary).contains(.stashList) && !rootActions(ordinary).contains(.submoduleUpdate))
        let complete = metadataMenu(FinderRepositoryMetadata(hasStash: true, hasSubmoduleConfig: true))
        verifyOrder(complete)
        precondition([RepositoryAction.stashApply, .stashPop, .stashList, .submoduleUpdate].allSatisfy(rootActions(complete).contains))
        enum SubmoduleVerificationFailure: Error { case eligibility, routing }
        guard rootActions(ordinary).contains(.submoduleAdd), !rootActions(ordinary).contains(.submoduleSync), rootActions(complete).contains(.submoduleSync) else { throw SubmoduleVerificationFailure.eligibility }
        for action in [RepositoryAction.submoduleAdd, .submoduleSync] {
            guard let item = items(complete).first(where: { FinderShellMenuLayout.action($0) == action }),
                  let command = item.representedObject as? FinderMenuCommand, item.isEnabled, item.image != nil,
                  item.target === target, item.action == selector, command.request.paths.map({ Array($0.path.utf8) }) == [Array(folder.path.utf8)],
                  command.url().flatMap(FinderRequest.init(url:))?.action == action else { throw SubmoduleVerificationFailure.routing }
        }
        print("Actual Finder Submodule Add/Sync: pinned group/order, one-folder/container eligibility, original artwork and captured selector/URL routing passed. Signed dispatch remains pending.")
        let merging = metadataMenu(FinderRepositoryMetadata(mergeActive: true, hasStash: true, hasSubmoduleConfig: true))
        verifyOrder(merging)
        precondition([RepositoryAction.pull, .merge, .rebase, .stash].allSatisfy { !rootActions(merging).contains($0) })
        precondition(rootActions(merging).contains(.fetch) && rootActions(merging).contains(.commit) && rootActions(merging).contains(.stashApply))
        precondition(!rootActions(ordinary).contains(.mergeAbort) && rootActions(merging).contains(.mergeAbort))
        let abortItem = items(merging).first { FinderShellMenuLayout.action($0) == .mergeAbort }!
        precondition(abortItem.isEnabled && abortItem.image != nil && abortItem.title == "Abort Merge")
        let abortCommand = abortItem.representedObject as! FinderMenuCommand
        precondition(FinderRequest(url: abortCommand.url()!)!.action == .mergeAbort)
        precondition(abortCommand.request.paths == FinderRequest(action: .mergeAbort, paths: [folder]).paths)
        let bisecting = metadataMenu(FinderRepositoryMetadata(bisectActive: true))
        verifyOrder(bisecting)
        precondition([RepositoryAction.pull, .merge, .rebase].allSatisfy { !rootActions(bisecting).contains($0) } && rootActions(bisecting).contains(.stash))
        precondition(rootActions(ordinary).contains(.bisectStart) && !rootActions(bisecting).contains(.bisectStart) && !rootActions(merging).contains(.bisectStart))
        let bisectOperations: [RepositoryAction] = [.bisectGood, .bisectBad, .bisectSkip, .bisectReset]
        precondition(bisectOperations.allSatisfy { rootActions(bisecting).contains($0) && !rootActions(ordinary).contains($0) })
        for action in [.bisectStart] + bisectOperations {
            let menu = action == .bisectStart ? ordinary : bisecting
            let item = items(menu).first { ($0.representedObject as? FinderMenuCommand)?.request.action == action }!
            let request = (item.representedObject as! FinderMenuCommand).request
            precondition(item.image != nil && item.isEnabled && item.target === target && item.action == selector)
            precondition(request.paths.map { Array($0.path.utf8) } == [Array(folder.path.utf8)] && FinderRequest(url: request.url!)?.action == action)
        }
        precondition(!trackedActions.contains(.bisectStart) && !multiple.contains(.bisectStart))
        print("Actual Finder Bisect: inactive Start, active Good/Bad/Skip/Reset, merge/file/multiple exclusion, original icons, selectors, captured folder and URL round-trip passed.")
        let registered = metadataMenu(FinderRepositoryMetadata(submoduleParentRoot: folder.deletingLastPathComponent().path))
        verifyOrder(registered)
        precondition(rootActions(registered).contains(.rename) && rootActions(registered).contains(.remove) && !rootActions(registered).contains(.removeKeep))
        for action in [RepositoryAction.rename, .remove] {
            let item = registered.items[0].submenu!.items.first { FinderShellMenuLayout.action($0) == action }!
            precondition(item.isEnabled && (item.representedObject as! FinderMenuCommand).request.paths.map { Array($0.path.utf8) } == [Array(folder.path.utf8)])
        }
        precondition(!rootActions(ordinary).contains(.rename) && !rootActions(ordinary).contains(.remove))
        print("Actual submodule root menu receiver: registered root enables captured Rename/Remove, excludes RemoveKeep; ordinary root excludes Rename/Remove. Parent authorization and native dispatch remain pending.")
        let exportMenu = make([folder], settings: allCommands())
        guard let exportItem = items(exportMenu).first(where: { ($0.representedObject as? FinderMenuCommand)?.request.action == .export }) else { fatalError("Folder Export missing") }
        precondition(exportItem.isEnabled && exportItem.image != nil && exportItem.target === target && exportItem.action == selector)
        let exportRequest = (exportItem.representedObject as! FinderMenuCommand).request
        precondition(FinderRequest(url: exportRequest.url!)?.action == .export && exportRequest.paths.map { Array($0.path.utf8) } == [Array(folder.path.utf8)])
        precondition(!trackedActions.contains(.export) && !multiple.contains(.export))
        let bareMenu = metadataMenu(FinderRepositoryMetadata(bare: true))
        verifyOrder(bareMenu)
        precondition(rootActions(bareMenu) == [.fetch, .push, .log, .daemon, .revisionGraph, .reflog, .referenceBrowser, .repositoryBrowser, .export, .worktreeList])
        print("Actual metadata menu receiver: absent/present stash and .gitmodules, merge/bisect exclusions and ten bare-root Git commands plus utilities follow source repository clauses while preserving groups. Cached facts only; fresh signed handoff remains pending.")
        let unrelated = outside.appendingPathComponent("plain.txt"); try Data().write(to: unrelated)
        let outsideFileMenu = FinderMenuBuilder.make(paths: [unrelated], snapshot: nil, settings: allCommands(),
            comparisonMark: nil, target: target, actionSelector: selector)
        let unrelatedSecond = outside.appendingPathComponent("second &雪.txt"); try Data("second".utf8).write(to: unrelatedSecond)
        let outsidePairMenu = FinderMenuBuilder.make(paths: [unrelated, unrelatedSecond], snapshot: nil, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector)
        precondition(rootActions(outsidePairMenu) == [.diff], "Two outside files expose direct Diff without repository commands")
        let pairCommand = outsidePairMenu.items[0].submenu!.items[0].representedObject as! FinderMenuCommand
        precondition(FinderRequest(url: pairCommand.url()!)?.paths == [unrelated, unrelatedSecond])
        verifyOrder(outsidePairMenu)
        let fileAndFolder = FinderMenuBuilder.make(paths: [unrelated, outside], snapshot: nil, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector)
        precondition(rootActions(fileAndFolder).isEmpty, "Folder selections do not satisfy the two-file clause")
        print("Actual pair menu receiver: two outside files expose Diff alongside utilities and retain ordered paths; file/folder selection is excluded. Native comparison activation remains pending.")
        verifyOrder(outsideFileMenu)
        precondition(outsideFileMenu.items[0].submenu!.items.filter { !$0.isSeparatorItem && FinderShellMenuLayout.action($0)?.isApplicationUtility != true }.count == 1, "A lone mark command needs no leading separator")
        print("Actual layout receiver: all \(mapping.count) implemented root entries match pinned MenuInfo fixture order/groups; six-case visible projections, nested Ignore positions, sparse toolbar/outside-file separators and source-selection-only direct New Worktree passed. Activated Finder still pending.")
        let actualRoot = folder.appendingPathComponent("actual-parent", isDirectory: true)
        let actualSource = folder.appendingPathComponent("actual-source", isDirectory: true)
        for directory in [actualRoot, actualSource] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let repo = GitRepository(root: directory)
            _ = try await repo.run(["init", "-b", "main"])
            _ = try await repo.run(["config", "user.name", "Finder receiver"])
            _ = try await repo.run(["config", "user.email", "finder@example.invalid"])
            _ = try await repo.run(["config", "commit.gpgsign", "false"])
            try Data("base".utf8).write(to: directory.appendingPathComponent("file.txt"))
            try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        }
        let parentRepo = GitRepository(root: actualRoot)
        let childPath = "child 雪\n"
        _ = try await parentRepo.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", "child", "--", actualSource.path, childPath])
        try await parentRepo.stage([".gitmodules", childPath]); _ = try await parentRepo.commit(message: "module")
        let discoveredChildren = try await parentRepo.finderSubmoduleSnapshots(authorizedRoot: actualRoot)
        precondition(discoveredChildren.failures.isEmpty && discoveredChildren.snapshots.count == 1)
        var freshBase = FinderSnapshot.build(root: actualRoot, tracked: try await parentRepo.trackedPaths(), changes: try await parentRepo.status())
        freshBase.repositories[actualRoot.path] = try await parentRepo.finderMetadata()
        var fresh = FinderSnapshot(roots: [], states: [:])
        fresh.replaceSubtree(root: actualRoot, snapshots: [freshBase] + discoveredChildren.snapshots)
        let sharedBytes = try JSONEncoder().encode(fresh)
        let restoredFresh = try JSONDecoder().decode(FinderSnapshot.self, from: sharedBytes)
        let actualChild = actualRoot.appendingPathComponent(childPath, isDirectory: true)
        let scannedMenu = FinderMenuBuilder.make(paths: [actualChild], snapshot: restoredFresh, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector)
        verifyOrder(scannedMenu)
        for action in [RepositoryAction.rename, .remove] {
            let item = scannedMenu.items[0].submenu!.items.first { FinderShellMenuLayout.action($0) == action }!
            precondition(item.isEnabled && (item.representedObject as! FinderMenuCommand).request.paths.map { Array($0.path.utf8) } == [Array(actualChild.path.utf8)])
        }
        let realChildRepo = GitRepository(root: actualChild)
        let owner = try await realChildRepo.discoverSelectionRoot(for: .rename, selected: actualChild)
        precondition(owner.path == actualRoot.path)
        print("Actual collected-cache receiver: real parent refresh discovers unopened Unicode/newline child; serialized snapshot drives enabled captured Rename/Remove and verified parent selection routing. No entitled publication/native activation performed.")
        // Real merge metadata, rather than a manually asserted cache flag.
        _ = try await parentRepo.run(["switch", "-c", "abort-feature"])
        try Data("theirs\n".utf8).write(to: actualRoot.appendingPathComponent("file.txt")); try await parentRepo.stage(["file.txt"]); _ = try await parentRepo.commit(message: "theirs")
        _ = try await parentRepo.run(["switch", "main"])
        try Data("ours\n".utf8).write(to: actualRoot.appendingPathComponent("file.txt")); try await parentRepo.stage(["file.txt"]); _ = try await parentRepo.commit(message: "ours")
        do { _ = try await parentRepo.run(["merge", "--no-edit", "abort-feature"]); preconditionFailure("Expected conflict") } catch is GitFailure {}
        var mergeSnapshot = FinderSnapshot.build(root: actualRoot, tracked: try await parentRepo.trackedPaths(), changes: try await parentRepo.status())
        mergeSnapshot.repositories[actualRoot.path] = try await parentRepo.finderMetadata()
        let decodedMerge = try JSONDecoder().decode(FinderSnapshot.self, from: JSONEncoder().encode(mergeSnapshot))
        let mergeHead = try await parentRepo.run(["rev-parse", "HEAD"]).stdout
        let mergeIndex = try Data(contentsOf: actualRoot.appendingPathComponent(".git/index"))
        let mergeFile = try Data(contentsOf: actualRoot.appendingPathComponent("file.txt"))
        for selected in [[actualRoot], [actualRoot.appendingPathComponent("file.txt")], [actualRoot.appendingPathComponent("file.txt"), actualRoot.appendingPathComponent(".gitmodules")]] {
            for icons in [true, false] {
                var settings = allCommands(); settings.showIcons = icons
                let menu = FinderMenuBuilder.make(paths: selected, snapshot: decodedMerge, settings: settings, comparisonMark: nil, target: target, actionSelector: selector)
                verifyOrder(menu)
                let item = items(menu).first { FinderShellMenuLayout.action($0) == .mergeAbort }!
                precondition(item.isEnabled && (item.image != nil) == icons)
                let command = item.representedObject as! FinderMenuCommand
                precondition(command.request.paths == FinderRequest(action: .mergeAbort, paths: selected).paths)
                precondition(FinderRequest(url: command.url()!)!.action == .mergeAbort)
            }
        }
        let afterMergeHead = try await parentRepo.run(["rev-parse", "HEAD"]).stdout
        let afterMergeIndex = try Data(contentsOf: actualRoot.appendingPathComponent(".git/index")), afterMergeFile = try Data(contentsOf: actualRoot.appendingPathComponent("file.txt"))
        precondition(mergeHead == afterMergeHead && mergeIndex == afterMergeIndex && mergeFile == afterMergeFile)
        _ = try await parentRepo.abortMerge()
        var afterSnapshot = FinderSnapshot.build(root: actualRoot, tracked: try await parentRepo.trackedPaths(), changes: try await parentRepo.status())
        afterSnapshot.repositories[actualRoot.path] = try await parentRepo.finderMetadata()
        let afterMenu = FinderMenuBuilder.make(paths: [actualRoot], snapshot: afterSnapshot, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector)
        precondition(!rootActions(afterMenu).contains(.mergeAbort))
        print("Abort Merge menu: real conflicted Git metadata survives cache serialization; repository, tracked file and multiple tracked selections offer correctly ordered enabled original icon/URL actions with icons on/off; menu construction preserves HEAD/index/file; refreshed aborted state removes entry. No installed Finder activation.")

        let destination = actualRoot.appendingPathComponent("destination 雪", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var transferSnapshot = FinderSnapshot.build(root: actualRoot, tracked: try await parentRepo.trackedPaths(), changes: try await parentRepo.status())
        transferSnapshot.repositories[actualRoot.path] = FinderRepositoryMetadata(bare: false)
        for icons in [true, false] {
            let transferMenu = FinderMenuBuilder.make(paths: [destination], snapshot: transferSnapshot, settings: allCommands(showIcons: icons), comparisonMark: nil, target: target, actionSelector: selector, clipboardSources: [actualRoot.appendingPathComponent("file.txt")])
            let entries = items(transferMenu).filter { FinderShellMenuLayout.action($0)?.isFileTransfer == true }
            precondition(entries.count == 2)
            precondition(entries.map { FinderShellMenuLayout.action($0)! } == [.pasteCopy, .pasteMove])
            for entry in entries {
                precondition((entry.image != nil) == icons)
                let command = entry.representedObject as! FinderMenuCommand
                let decoded = FinderRequest(url: command.url()!)!
                precondition(decoded.paths.map(\.path) == [destination.path] && decoded.sources.map(\.path) == [actualRoot.appendingPathComponent("file.txt").path])
            }
        }
        var noTransfers = allCommands(); noTransfers.clipboardTransfers = false
        let disabledTransfers = FinderMenuBuilder.make(paths: [destination], snapshot: transferSnapshot, settings: noTransfers, comparisonMark: nil, target: target, actionSelector: selector, clipboardSources: [actualRoot.appendingPathComponent("file.txt")])
        precondition(!items(disabledTransfers).contains { FinderShellMenuLayout.action($0)?.isFileTransfer == true })
        let copyOnly = FinderMenuBuilder.make(paths: [destination], snapshot: transferSnapshot, settings: allCommands(), comparisonMark: nil, target: target, actionSelector: selector, clipboardSources: [actualSource.appendingPathComponent("file.txt")])
        precondition(items(copyOnly).compactMap { FinderShellMenuLayout.action($0) }.filter(\.isFileTransfer) == [.pasteCopy])
        print("Finder clipboard transfers: actual submenu/icons/request payload, Copy-only external source, captured folder/files and separate disable preference passed. No live Finder activation.")
        // Use the actual compiled extension tables, with no Finder activation.
        let resources = Bundle(path: CommandLine.arguments[3])!
        precondition(Set(AppLanguageChoice.bundledIDs).isSubset(of: Set(resources.localizations)), "Extension missing a compiled language")
        let literalFile = folder.appendingPathComponent("Commit-%n-é.txt")
        try Data("literalFile".utf8).write(to: literalFile)
        var languageSnapshot = snapshot
        languageSnapshot.states[literalFile.path] = .untracked
        func commands(_ menu: NSMenu) -> [NSMenuItem] { items(menu).filter { $0.representedObject is FinderMenuCommand } }
        for language in ["de", "fr", "en", "system"] {
            var policy = allCommands(); policy.language = language
            let captions = FinderMenuCaptions(language: language, bundle: resources, preferredLanguages: ["fr-CA", "en"])
            if language == "system" { precondition(captions.label("Cancel") == "Annuler") }
            if language == "de" { precondition(captions.label("Cancel") == "Abbrechen") }
            if language == "en" { precondition(captions.label("Cancel") == "Cancel") }
            precondition(captions.label("missing native Finder key") == "missing native Finder key")
            let localized = FinderMenuBuilder.make(paths: [literalFile], snapshot: languageSnapshot, settings: policy,
                comparisonMark: mark, target: target, actionSelector: selector, localizationBundle: resources)
            let baseline = FinderMenuBuilder.make(paths: [literalFile], snapshot: languageSnapshot, settings: allCommands(), comparisonMark: mark, target: target, actionSelector: selector)
            let actual = commands(localized), original = commands(baseline)
            precondition(actual.count == original.count)
            for (a,b) in zip(actual,original) {
                precondition(FinderShellMenuLayout.action(a) == FinderShellMenuLayout.action(b) && a.isEnabled == b.isEnabled && a.target === target && a.action == selector)
                precondition((a.representedObject as! FinderMenuCommand).url() == (b.representedObject as! FinderMenuCommand).url())
                precondition((a.image != nil) == (b.image != nil))
            }
            let ignore = items(localized).first { FinderShellMenuLayout.action($0) == .ignore && $0.submenu != nil }!
            precondition(ignore.submenu!.items[0].title == literalFile.lastPathComponent, "Filename was translated/interpreted as formatting")
            precondition(ignore.submenu!.items[1].title == "*.txt")
            let countMenu = FinderMenuBuilder.make(paths: [literalFile,untracked], snapshot: languageSnapshot, settings: policy,
                comparisonMark: nil, target: target, actionSelector: selector, localizationBundle: resources)
            let countIgnore = items(countMenu).first { FinderShellMenuLayout.action($0) == .ignore && $0.submenu != nil }!
            precondition(countIgnore.submenu!.items[0].title.contains("2"))
            if language == "de" || language == "fr" {
                precondition(countIgnore.submenu!.items[0].title != "Ignore 2 items by name")
                let add = actual.first { FinderShellMenuLayout.action($0) == .add }!
                precondition(add.title != RepositoryAction.add.title)
            }
            var firstLevel = policy; firstLevel.topLevelMask = FinderMenuEntry.allMask
            let top = FinderMenuBuilder.make(paths: [tracked], snapshot: snapshot, settings: firstLevel,
                comparisonMark: nil, target: target, actionSelector: selector, localizationBundle: resources)
            precondition(top.items.filter { $0.representedObject is FinderMenuCommand && FinderShellMenuLayout.action($0) != .properties }.allSatisfy { $0.title.hasPrefix("Git ") })
        }
        print("PASS Finder language family: 38 compiled locale resources, live de/fr/en/system command projection, exact payload/order/icons and literalFile filenames/patterns; private count captions and system matching.")

        // The host sends a new NSMenuItem instance with primitive transport fields.
        let dispatch = FinderMenuDispatch(), capturedTransport = FinderRequest(action: .log, paths: [folder.appendingPathComponent("README.md")])
        let transportedMenu = NSMenu(), branch = NSMenuItem(title:"TurtleGit",action:nil,keyEquivalent:"")
        let children = NSMenu(), leaf = NSMenuItem(title:"Log",action:#selector(MenuTarget.openAction(_:)),keyEquivalent:"")
        leaf.representedObject = FinderMenuCommand(request:capturedTransport); children.addItem(leaf); branch.submenu = children; transportedMenu.addItem(branch)
        dispatch.install(transportedMenu)
        let transported = NSMenuItem(title:"Log",action:nil,keyEquivalent:""); transported.tag = leaf.tag
        precondition(transported.representedObject == nil && transported.tag != 0)
        leaf.representedObject = FinderMenuCommand(action:.remove,paths:[])
        precondition(dispatch.claim(transported)?.request.url == capturedTransport.url, "A transported item lost or retargeted its immutable request")
        precondition(dispatch.claim(transported) == nil, "A Finder popup dispatched twice")
        dispatch.install(transportedMenu); let staleTag = leaf.tag
        dispatch.install(transportedMenu)
        let staleItem = NSMenuItem(title:"stale",action:nil,keyEquivalent:""); staleItem.tag = staleTag
        precondition(dispatch.claim(staleItem) == nil, "A replaced popup's tag remained active")
        let bundledExtension = URL(fileURLWithPath:CommandLine.arguments[3])
        precondition(FinderMenuDispatch.containingApplication(for:bundledExtension) == bundledExtension.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        precondition(FinderMenuDispatch.containingApplication(for:folder) == nil)
        print("PASS Finder menu transport: primitive tag-only callback, immutable owned payload, once-only dispatch, replaced menu expiry and containing-app routing; no actual launch.")

        for state in FileState.allCases { precondition(state.icon.image() != nil, "Badge artwork stays available") }
        print("Actual Finder menu builder: parent/action/nested-ignore/marked-compare images toggle; six selection cases preserve titles, enabled states and routing; fresh cache reset and badge artwork pass. No Finder controller/extension/window activated; signed integration and gestures remain pending.")
    }
}
'''
compiler = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True)
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
sdk_build = subprocess.check_output(['xcrun', '--show-sdk-build-version'], text=True).strip()
target = platform.machine() + '-apple-macos13.0'
flags = ['-swift-version', '6', '-parse-as-library', '-target', target,
         '-sdk', sdk, '-F', str(frameworks), '-framework', 'TurtleGitCore',
         '-framework', 'FinderSync', '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
inputs = [pathlib.Path(__file__).resolve(), root / 'scripts/native_receiver.py', root / 'FinderSync/FinderSync.swift']
inputs += sorted((root / 'Sources').rglob('*.swift'))
core = frameworks / 'TurtleGitCore.framework'
if not core.is_dir():
    raise RuntimeError('Build the current Debug Core framework before Finder menu verification.')
inputs += [path for path in core.rglob('*') if path.is_file() and not path.is_symlink()]
settings = dict(version=1, architecture=platform.machine(), target=target,
                compiler=compiler, sdk=sdk, sdk_build=sdk_build, flags=flags, driver=driver)
generation = root / 'build/qa/native-receivers/finder-menu' / fingerprint(inputs, settings)
generation.mkdir(parents=True, exist_ok=True)
binary = generation / 'finder-menu-check'
if not binary.is_file():
    with tempfile.TemporaryDirectory(prefix='compile-', dir=generation) as staging:
        staging = pathlib.Path(staging)
        main = staging / 'main.swift'; main.write_text(driver)
        output = staging / binary.name
        subprocess.run(['xcrun', 'swiftc', *flags, str(root / 'FinderSync/FinderSync.swift'),
                        str(main), '-o', str(output)], cwd=root, check=True, timeout=300)
        output.replace(binary)
    print('Native QA: compiled current Finder menu receiver.', flush=True)
else:
    print('Native QA: reused unchanged Finder menu receiver.', flush=True)
with tempfile.TemporaryDirectory(prefix='TurtleGitFinderMenuTest-') as directory:
    folder = pathlib.Path(directory)
    run_receiver([str(binary), str(folder / 'fixture'), str(root / 'docs/upstream-shell-menu-order.json'), str(frameworks/'TurtleGitMac.app/Contents/PlugIns/TurtleGitFinder.appex')], cwd=root, check=True)
