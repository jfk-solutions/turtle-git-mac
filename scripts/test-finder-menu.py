#!/usr/bin/env python3
"""Exercise the actual Finder menu builder without activating an extension."""
import pathlib
import platform
import subprocess
import tempfile

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
            .clone: "Clone", .pull: "Pull", .fetch: "Fetch", .push: "Push", .commit: "Commit",
            .diff: "Diff", .diffLater: "DiffLater", .log: "Log", .reflog: "RefLog", .repositoryBrowser: "RepoBrowse",
            .status: "ShowChanged", .rebase: "Rebase", .stash: "StashSave", .stashApply: "StashApply",
            .stashPop: "StashPop", .stashList: "StashList", .resolve: "Resolve", .rename: "Rename",
            .remove: "Remove", .removeKeep: "RemoveKeep", .revert: "Revert", .switchBranch: "Switch",
            .merge: "Merge", .branch: "Branch", .tag: "Tag", .initialize: "CreateRepo",
            .ignore: "IgnoreSub", .ignoreDelete: "DeleteIgnoreSub", .worktreeList: "Worktree",
            .submoduleUpdate: "SubmoduleUpdate", .formatPatch: "FormatPatch"
        ]
        let nativeBySource = Dictionary(uniqueKeysWithValues: mapping.map { ($0.value, $0.key) })
        let projected = sourceOrder.groups.map { $0.compactMap { nativeBySource[$0] } }.filter { !$0.isEmpty }
        precondition(FinderShellMenuLayout.groups == projected, "Every implemented root command must preserve pinned MenuInfo order/group")
        precondition(Set(projected.flatMap { $0 }) == Set(mapping.keys))
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
            let expected = projected.map { $0.filter { visible.contains($0) } }.filter { !$0.isEmpty }
            precondition(actual.filter { !$0.isEmpty } == expected, "Visible menu groups must match independent source projection")
            precondition(!visible.contains(.worktreeCreate), "New Worktree belongs in the manager")
        }
        func make(_ paths: [URL], settings: FinderMenuSettings, mark: WorkingComparisonMarkSnapshot? = nil) -> NSMenu {
            FinderMenuBuilder.make(paths: paths, snapshot: snapshot, settings: settings,
                comparisonMark: mark, target: target, actionSelector: selector)
        }
        for paths in [[untracked], [tracked], [conflict], [folder], [untracked, tracked], []] {
            let enabled = make(paths, settings: FinderMenuSettings())
            let disabled = make(paths, settings: FinderMenuSettings(showIcons: false))
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
        let ignoring = items(make([untracked], settings: FinderMenuSettings()))
        precondition(ignoring.contains { $0.title == "Add to ignore list" && $0.submenu?.items.count == 2 })
        let versioned = items(make([tracked], settings: FinderMenuSettings()))
        precondition(versioned.contains { $0.title == "Delete and add to ignore list" && $0.submenu?.items.count == 2 })
        precondition(versioned.contains { ($0.representedObject as? FinderMenuCommand)?.request.action == .remove && $0.isEnabled })
        let conflicted = items(make([conflict], settings: FinderMenuSettings()))
        precondition(conflicted.contains { ($0.representedObject as? FinderMenuCommand)?.request.action == .resolve && $0.isEnabled })
        let mark = WorkingComparisonMarkSnapshot(id: UUID(), path: "/other/marked.txt")
        let marked = items(make([tracked], settings: FinderMenuSettings(showIcons: false), mark: mark))
        precondition(marked.contains { $0.title == "Compare with /other/marked.txt" && $0.image == nil })
        let cache = folder.appendingPathComponent("shared/menu-settings.json")
        try FinderMenuSettings(showIcons: false).write(to: cache)
        precondition(items(make([tracked], settings: FinderMenuSettings.read(from: cache))).allSatisfy { $0.image == nil })
        try FinderMenuSettings().write(to: cache)
        precondition(items(make([tracked], settings: FinderMenuSettings.read(from: cache))).filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside 雪", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        func creation(_ directory: URL?, toolbar: Bool = false, extended: Bool = false) -> [NSMenuItem] {
            items(FinderMenuBuilder.make(paths: directory.map { [$0] } ?? [], snapshot: snapshot,
                settings: FinderMenuSettings(), comparisonMark: nil, target: target, actionSelector: selector,
                creationDirectory: directory, extended: extended, toolbar: toolbar))
        }
        for (directory, toolbar) in [(outside as URL?, false), (nil, true)] {
            let commands = creation(directory, toolbar: toolbar).filter { !$0.isSeparatorItem && $0.submenu == nil }
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
        let captured = items(make(selection, settings: FinderMenuSettings()))
        selection = [conflict]
        for item in captured {
            guard let command = item.representedObject as? FinderMenuCommand else { continue }
            precondition(command.request.paths.map(\.path) == FinderRequest(action: command.request.action, paths: [untracked, tracked]).paths.map(\.path))
            precondition(FinderRequest(url: command.url()!)?.paths.map(\.path) == command.request.paths.map(\.path))
            precondition(FinderRequest(url: command.url(control: true)!)?.action == command.request.action, "Control must not change unrelated actions")
        }
        let containerPaths = FinderMenuBuilder.paths(kind: .contextualMenuForContainer, selection: [tracked], target: folder)
        for item in items(make(containerPaths, settings: FinderMenuSettings())) {
            if let command = item.representedObject as? FinderMenuCommand {
                precondition(command.request.paths.map(\.path) == [folder.standardizedFileURL.path])
            }
        }
        let ignoredCommands = ignoring.compactMap { $0.representedObject as? FinderMenuCommand }.filter { $0.request.action.isIgnore }
        precondition(ignoredCommands.count == 2 && ignoredCommands.allSatisfy { $0.request.paths.map(\.path) == FinderRequest(action: .ignore, paths: [untracked]).paths.map(\.path) })
        let compare = marked.compactMap { $0.representedObject as? FinderMenuCommand }.first { $0.request.action == .diffLater }!
        precondition(FinderRequest(url: compare.url()!)?.action == .diffLater)
        precondition(FinderRequest(url: compare.url(control: true)!)?.action == .clearComparisonMark)
        precondition(FinderRequest(url: compare.url(control: true)!)?.paths.map(\.path) == compare.request.paths.map(\.path))
        let unusual = folder.appendingPathComponent("literal 雪\n&?.txt")
        let literal = FinderMenuCommand(action: .removeKeep, paths: [unusual, tracked, unusual])
        let decoded = FinderRequest(url: literal.url()!)!
        precondition(decoded.action == .removeKeep && decoded.paths.count == 2)
        precondition(decoded.paths.first?.lastPathComponent == "literal 雪\n&?.txt")
        precondition(decoded.paths.map(\.path) == literal.request.paths.map(\.path))
        print("Actual command receiver: ordinary/multi-file/container/nested-ignore/comparison requests retain menu-time selection; Control only clears the comparison mark. No activation/handoff performed.")
        let toolbarMenu = FinderMenuBuilder.make(paths: [], snapshot: snapshot, settings: FinderMenuSettings(),
            comparisonMark: nil, target: target, actionSelector: selector, toolbar: true)
        precondition(toolbarMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [RepositoryAction.clone.title, RepositoryAction.initialize.title], "Toolbar commands should appear directly")
        verifyOrder(toolbarMenu)
        precondition(toolbarMenu.items.count == 3 && toolbarMenu.items[1].isSeparatorItem)
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
            return FinderMenuBuilder.make(paths: [folder], snapshot: cached, settings: FinderMenuSettings(),
                comparisonMark: nil, target: target, actionSelector: selector)
        }
        func rootActions(_ menu: NSMenu) -> Set<RepositoryAction> {
            Set(menu.items[0].submenu!.items.compactMap(FinderShellMenuLayout.action))
        }
        let trackedActions = rootActions(make([tracked], settings: FinderMenuSettings()))
        precondition(trackedActions == [.commit, .diff, .diffLater, .log, .status, .stash, .rename, .remove, .removeKeep, .ignoreDelete], "Unchanged tracked file must have source file commands, not folder commands or Revert")
        let addedFile = folder.appendingPathComponent("added.txt"); try Data().write(to: addedFile)
        let addedSnapshot = FinderSnapshot(roots: [folder.path], states: [addedFile.path: .added], repositories: [folder.path: FinderRepositoryMetadata()])
        let addedMenu = FinderMenuBuilder.make(paths: [addedFile], snapshot: addedSnapshot, settings: FinderMenuSettings(), comparisonMark: nil, target: target, actionSelector: selector)
        precondition(rootActions(addedMenu) == [.commit, .diff, .diffLater, .status, .stash, .rename, .revert, .ignoreDelete], "Added paths exclude history and removal")
        verifyOrder(addedMenu)
        let multiple = rootActions(make([tracked, conflict], settings: FinderMenuSettings()))
        precondition(multiple == [.commit, .diff, .status, .resolve, .remove, .removeKeep, .ignoreDelete], "Two files exclude single-selection and folder commands")
        let untrackedFolder = folder.appendingPathComponent("new-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: untrackedFolder, withIntermediateDirectories: true)
        let creationRules = FinderCreationMenuContext.read(directory: untrackedFolder, snapshot: snapshot, extended: false)
        precondition(creationRules.folderInGit && creationRules.actions.isEmpty, "Untracked folders inside a worktree retain folder-in-Git metadata")
        precondition(FinderCreationMenuContext.read(directory: untrackedFolder, snapshot: snapshot, extended: true).actions == [.clone, .initialize])
        precondition(FinderMenuBuilder.make(paths: [tracked, admin], snapshot: snapshot, settings: FinderMenuSettings(), comparisonMark: nil, target: target, actionSelector: selector).items.isEmpty)
        print("Actual path menu receiver: exact tracked/added/two-file command sets, untracked worktree-folder creation and mixed admin exclusion passed. Full submodule and selection classification remains pending.")
        let ordinary = metadataMenu(FinderRepositoryMetadata())
        verifyOrder(ordinary)
        precondition(!rootActions(ordinary).contains(.stashApply) && !rootActions(ordinary).contains(.stashPop) && !rootActions(ordinary).contains(.stashList) && !rootActions(ordinary).contains(.submoduleUpdate))
        let complete = metadataMenu(FinderRepositoryMetadata(hasStash: true, hasSubmoduleConfig: true))
        verifyOrder(complete)
        precondition([RepositoryAction.stashApply, .stashPop, .stashList, .submoduleUpdate].allSatisfy(rootActions(complete).contains))
        let merging = metadataMenu(FinderRepositoryMetadata(mergeActive: true, hasStash: true, hasSubmoduleConfig: true))
        verifyOrder(merging)
        precondition([RepositoryAction.pull, .merge, .rebase, .stash].allSatisfy { !rootActions(merging).contains($0) })
        precondition(rootActions(merging).contains(.fetch) && rootActions(merging).contains(.commit) && rootActions(merging).contains(.stashApply))
        let bisecting = metadataMenu(FinderRepositoryMetadata(bisectActive: true))
        verifyOrder(bisecting)
        precondition([RepositoryAction.pull, .merge, .rebase].allSatisfy { !rootActions(bisecting).contains($0) } && rootActions(bisecting).contains(.stash))
        let registered = metadataMenu(FinderRepositoryMetadata(submoduleParentRoot: folder.deletingLastPathComponent().path))
        verifyOrder(registered)
        precondition(rootActions(registered).contains(.rename) && rootActions(registered).contains(.remove) && !rootActions(registered).contains(.removeKeep))
        for action in [RepositoryAction.rename, .remove] {
            let item = registered.items[0].submenu!.items.first { FinderShellMenuLayout.action($0) == action }!
            precondition(item.isEnabled && (item.representedObject as! FinderMenuCommand).request.paths == [folder])
        }
        precondition(!rootActions(ordinary).contains(.rename) && !rootActions(ordinary).contains(.remove))
        print("Actual submodule root menu receiver: registered root enables captured Rename/Remove, excludes RemoveKeep; ordinary root excludes Rename/Remove. Parent authorization and native dispatch remain pending.")
        let bareMenu = metadataMenu(FinderRepositoryMetadata(bare: true))
        verifyOrder(bareMenu)
        precondition(rootActions(bareMenu) == [.fetch, .push, .log, .reflog, .repositoryBrowser, .worktreeList])
        print("Actual metadata menu receiver: absent/present stash and .gitmodules, merge/bisect exclusions and six bare-root commands follow source repository clauses while preserving groups. Cached facts only; fresh signed handoff remains pending.")
        let unrelated = outside.appendingPathComponent("plain.txt"); try Data().write(to: unrelated)
        let outsideFileMenu = FinderMenuBuilder.make(paths: [unrelated], snapshot: nil, settings: FinderMenuSettings(),
            comparisonMark: nil, target: target, actionSelector: selector)
        let unrelatedSecond = outside.appendingPathComponent("second &雪.txt"); try Data("second".utf8).write(to: unrelatedSecond)
        let outsidePairMenu = FinderMenuBuilder.make(paths: [unrelated, unrelatedSecond], snapshot: nil, settings: FinderMenuSettings(), comparisonMark: nil, target: target, actionSelector: selector)
        precondition(rootActions(outsidePairMenu) == [.diff], "Two outside files expose direct Diff without repository commands")
        let pairCommand = outsidePairMenu.items[0].submenu!.items[0].representedObject as! FinderMenuCommand
        precondition(FinderRequest(url: pairCommand.url()!)?.paths == [unrelated, unrelatedSecond])
        verifyOrder(outsidePairMenu)
        let fileAndFolder = FinderMenuBuilder.make(paths: [unrelated, outside], snapshot: nil, settings: FinderMenuSettings(), comparisonMark: nil, target: target, actionSelector: selector)
        precondition(rootActions(fileAndFolder).isEmpty, "Folder selections do not satisfy the two-file clause")
        print("Actual pair menu receiver: two outside files expose only Diff and retain ordered paths; file/folder selection is excluded. Native comparison activation remains pending.")
        verifyOrder(outsideFileMenu)
        precondition(outsideFileMenu.items[0].submenu!.items.count == 1, "A lone mark command needs no leading separator")
        print("Actual layout receiver: all 31 implemented root entries match pinned MenuInfo fixture order/groups; six-case visible projections, nested Ignore positions, sparse toolbar/outside-file separators and manager-only New Worktree passed. Activated Finder still pending.")
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
        let scannedMenu = FinderMenuBuilder.make(paths: [actualChild], snapshot: restoredFresh, settings: FinderMenuSettings(), comparisonMark: nil, target: target, actionSelector: selector)
        verifyOrder(scannedMenu)
        for action in [RepositoryAction.rename, .remove] {
            let item = scannedMenu.items[0].submenu!.items.first { FinderShellMenuLayout.action($0) == action }!
            precondition(item.isEnabled && (item.representedObject as! FinderMenuCommand).request.paths == [actualChild])
        }
        let realChildRepo = GitRepository(root: actualChild)
        let owner = try await realChildRepo.discoverSelectionRoot(for: .rename, selected: actualChild)
        precondition(owner.path == actualRoot.path)
        print("Actual collected-cache receiver: real parent refresh discovers unopened Unicode/newline child; serialized snapshot drives enabled captured Rename/Remove and verified parent selection routing. No entitled publication/native activation performed.")
        for state in FileState.allCases { precondition(state.icon.image() != nil, "Badge artwork stays available") }
        print("Actual Finder menu builder: parent/action/nested-ignore/marked-compare images toggle; six selection cases preserve titles, enabled states and routing; fresh cache reset and badge artwork pass. No Finder controller/extension/window activated; signed integration and gestures remain pending.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='TurtleGitFinderMenuTest-') as directory:
    folder = pathlib.Path(directory)
    main = folder / 'main.swift'; main.write_text(driver)
    binary = folder / 'finder-menu-check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-target', platform.machine() + '-apple-macos13.0',
                    '-F', str(frameworks), '-framework', 'TurtleGitCore', '-framework', 'FinderSync',
                    '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                    str(root / 'FinderSync/FinderSync.swift'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'fixture'), str(root / 'docs/upstream-shell-menu-order.json')], check=True)
