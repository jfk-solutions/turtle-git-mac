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
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
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
        func make(_ paths: [URL], settings: FinderMenuSettings, mark: WorkingComparisonMarkSnapshot? = nil) -> NSMenu {
            FinderMenuBuilder.make(paths: paths, snapshot: snapshot, settings: settings,
                comparisonMark: mark, target: target, actionSelector: selector)
        }
        for paths in [[untracked], [tracked], [conflict], [folder], [untracked, tracked], []] {
            let enabled = make(paths, settings: FinderMenuSettings())
            let disabled = make(paths, settings: FinderMenuSettings(showIcons: false))
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
        precondition(toolbarMenu.items.map(\.title) == [RepositoryAction.clone.title, RepositoryAction.initialize.title], "Toolbar commands should appear directly")
        precondition(creation(folder).allSatisfy { !(($0.representedObject as? FinderMenuCommand).map { [.clone, .initialize].contains($0.request.action) } ?? false) })
        precondition(creation(folder, extended: true).compactMap { ($0.representedObject as? FinderMenuCommand).flatMap { [.clone, .initialize].contains($0.request.action) ? $0.request.action : nil } } == [.clone])
        let admin = folder.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        precondition(creation(admin, extended: true).isEmpty)
        precondition(FinderMenuBuilder.paths(kind: .contextualMenuForContainer, selection: [tracked], target: folder) == [folder])
        precondition(FinderMenuBuilder.paths(kind: .contextualMenuForItems, selection: [tracked], target: folder) == [tracked])
        precondition(FinderMenuBuilder.paths(kind: .toolbarItemMenu, selection: [tracked], target: nil).isEmpty)
        print("Actual creation menu receiver: outside folder and targetless toolbar Clone/Create only, captured target routing and URL round-trip, versioned Shift rules, admin exclusion and container/item/toolbar selection passed. Activated Finder and native dialog handoff remain pending.")
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
    subprocess.run([str(binary), str(folder / 'fixture')], check=True)
