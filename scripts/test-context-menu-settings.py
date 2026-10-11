#!/usr/bin/env python3
"""Grouped actual Settings model/transaction checks and offscreen page previews."""
import pathlib
import platform
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
frameworks = root / 'build/Build/Products/Debug'
driver = r'''
import AppKit
import SwiftUI
import TurtleGitCore
enum SettingsPageID { case contextMenu, advanced; var applyOrder: Int { self == .contextMenu ? 0 : 1 } }
@main struct Verify {
    @MainActor static func settle(_ view: NSView) {
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ContextMenu.Receiver." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var published: [FinderMenuSettings] = []
        let model = FinderContextMenuSettingsModel(defaults: defaults, publish: { published.append($0); return true })
        model.draft.set(.diff, checked: true, extendedOnly: false)
        model.draft.hideForUnversioned = true; model.draft.excludedPaths = "/example/private/"
        precondition(model.modified && published.isEmpty && defaults.data(forKey: "TurtleGit.FinderMenuSettings") == nil)
        model.cancel(); precondition(!model.modified && model.draft.excludedPaths.isEmpty && published.isEmpty)
        model.draft.set(.bisect, checked: true, extendedOnly: true)
        model.draft.set(.diff, checked: true, extendedOnly: false)
        model.draft.excludedPaths = "/example/private/"; model.draft.hideForUnversioned = true
        let retained = model.draft.extendedOnlyMask
        model.restore(extendedOnly: false)
        precondition(model.draft.topLevelMask == FinderMenuEntry.defaultTopMask && model.draft.extendedOnlyMask == retained && model.draft.hideForUnversioned)
        defaults.set(false, forKey: "ShowContextMenuIcons")
        precondition(model.apply() && !model.modified && published.count == 1 && !published[0].showIcons)
        precondition(FinderMenuSettings.from(defaults: defaults).excludedPaths == "/example/private/")
        let advanced = AdvancedSettingsModel(defaults: defaults, publishFinderMenu: { published.append($0) })
        precondition(advanced.edit("ShowContextMenuIcons", text: "true")); advanced.apply()
        precondition(published.last!.showIcons && published.last!.excludedPaths == "/example/private/" && published.last!.extendedOnlyMask == retained)
        model.draft.topLevelMask |= FinderMenuEntry.log.mask
        precondition(model.apply() && published.last!.showIcons, "Old page cannot overwrite Advanced's newer icon preference")
        struct Failure: Error {}
        let before = defaults.data(forKey: "TurtleGit.FinderMenuSettings")
        let failure = FinderContextMenuSettingsModel(defaults: defaults, publish: { _ in throw Failure() })
        failure.draft.hideForUnversioned = false
        precondition(!failure.apply() && failure.modified && failure.message != nil && defaults.data(forKey: "TurtleGit.FinderMenuSettings") == before)
        failure.cancel(); precondition(!failure.modified)
        let unsigned = FinderContextMenuSettingsModel(defaults: defaults, publish: { _ in false })
        unsigned.draft.hideForUnversioned = false
        precondition(unsigned.apply() && !unsigned.modified && unsigned.message!.contains("Signed App Group"))
        let transaction = SettingsTransaction()
        transaction.register("contextMenu", participant: .init(page: .contextMenu, modified: { model.modified }, validate: { model.draft.valid ? nil : "invalid path" }, apply: model.apply, cancel: model.cancel))
        model.draft.excludedPaths = "relative"
        transaction.apply(closeAfter: false)
        while transaction.busy { await Task.yield() }
        precondition(transaction.error == "invalid path" && model.modified)
        transaction.cancel(); precondition(!model.modified)
        model.draft.set(.log, checked: false, extendedOnly: false)
        transaction.apply(closeAfter: false)
        while transaction.busy { await Task.yield() }
        precondition(transaction.error == nil && !model.modified)
        transaction.invalidate()
        print("Actual Context Menu Settings model: deferred edits, Cancel, page-specific restore, Apply, publication failure, unsigned retention, Advanced icon/policy preservation and shared transaction validation passed.")
        // Previews use the actual page views in one prohibited-activation process.
        // No installed app or Finder extension is launched; no windows are shown.
        let preview = FinderContextMenuSettingsModel(defaults: UserDefaults(suiteName: suite + ".preview")!, publish: { _ in false })
        defer { UserDefaults(suiteName: suite + ".preview")!.removePersistentDomain(forName: suite + ".preview") }
        for dark in [false, true] {
            for extended in [false, true] {
                let name = "context-menu" + (extended ? "-2" : "") + (dark ? "-dark" : "-light")
                let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
                    Text(extended ? "Context Menu 2" : "Context Menu").font(.title2.bold()).padding(16)
                    Divider()
                    FinderContextMenuSettingsPage(model: preview, extendedOnly: extended)
                }.frame(width: 780, height: 780).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.frame = NSRect(x: 0, y: 0, width: 780, height: 780)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view
                defer { window.close() }
                settle(view)
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = bitmap.representation(using: .png, properties: [:])!
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
            }
        }
        print("Four offscreen native page previews rendered. Pointer/keyboard/window integration and signed Finder activation remain unverified.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='TurtleGitContextMenuSettings-') as directory:
    folder = pathlib.Path(directory)
    main = folder / 'Driver.swift'
    main.write_text(driver)
    binary = folder / 'verify'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-target', platform.machine() + '-apple-macos13.0',
                    '-F', str(frameworks), '-framework', 'TurtleGitCore',
                    '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                    str(root / 'Sources/TurtleGitMac/SettingsTransaction.swift'),
                    str(root / 'Sources/TurtleGitMac/AdvancedSettings.swift'),
                    str(root / 'Sources/TurtleGitMac/FinderContextMenuSettings.swift'),
                    str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root / 'docs/site/assets')], check=True)
