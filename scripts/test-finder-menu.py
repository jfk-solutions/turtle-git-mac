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
            items(menu).map { "\($0.title)|\($0.isEnabled)|\($0.representedObject as? String ?? "")|\($0.state.rawValue)" }
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
            for item in items(disabled) where item.representedObject is String {
                precondition(item.target === target && item.action == selector)
            }
        }
        let ignoring = items(make([untracked], settings: FinderMenuSettings()))
        precondition(ignoring.contains { $0.title == "Add to ignore list" && $0.submenu?.items.count == 2 })
        let versioned = items(make([tracked], settings: FinderMenuSettings()))
        precondition(versioned.contains { $0.title == "Delete and add to ignore list" && $0.submenu?.items.count == 2 })
        precondition(versioned.contains { $0.representedObject as? String == RepositoryAction.remove.rawValue && $0.isEnabled })
        let conflicted = items(make([conflict], settings: FinderMenuSettings()))
        precondition(conflicted.contains { $0.representedObject as? String == RepositoryAction.resolve.rawValue && $0.isEnabled })
        let mark = WorkingComparisonMarkSnapshot(id: UUID(), path: "/other/marked.txt")
        let marked = items(make([tracked], settings: FinderMenuSettings(showIcons: false), mark: mark))
        precondition(marked.contains { $0.title == "Compare with /other/marked.txt" && $0.image == nil })
        let cache = folder.appendingPathComponent("shared/menu-settings.json")
        try FinderMenuSettings(showIcons: false).write(to: cache)
        precondition(items(make([tracked], settings: FinderMenuSettings.read(from: cache))).allSatisfy { $0.image == nil })
        try FinderMenuSettings().write(to: cache)
        precondition(items(make([tracked], settings: FinderMenuSettings.read(from: cache))).filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
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
