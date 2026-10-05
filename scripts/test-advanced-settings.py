#!/usr/bin/env python3
"""Actual Advanced Settings model/table receiver; no native windows displayed."""
import pathlib
import platform
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parent.parent
frameworks = root / 'build/Build/Products/Debug'
driver = r'''
import AppKit
import Combine
import Foundation
import TurtleGitCore
@main struct Verify {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.Advanced.Receiver." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AdvancedSettingsModel(defaults: defaults)
        let receiver = AdvancedSettingsTable.Coordinator(model: model)
        let scroll = receiver.makeScrollView(), table = scroll.documentView as! NSTableView
        scroll.frame = NSRect(x: 0, y: 0, width: 650, height: 400); scroll.tile(); table.tile()
        precondition(table.tableColumns.map(\.title) == ["Name", "Value"] && table.numberOfRows == 52)
        precondition(!table.tableColumns[0].isEditable && table.tableColumns[1].isEditable && !table.allowsColumnReordering)
        precondition(table.headerView!.frame.height > 0 && table.frame.height >= 52 * table.rowHeight)
        let background = AdvancedSettingDefinition.all.firstIndex { $0.name == "ShowListBackgroundImage" }!
        precondition(receiver.tableView(table, objectValueFor: table.tableColumns[1], row: background) as? String == "true")
        receiver.tableView(table, setObjectValue: nil, for: table.tableColumns[1], row: background)
        precondition(!model.modified && model.values["ShowListBackgroundImage"] == "true", "Cancelled label edit must not clear the value")
        receiver.tableView(table, setObjectValue: "false", for: table.tableColumns[1], row: background)
        precondition(model.modified && defaults.object(forKey: "ShowListBackgroundImage") == nil)
        var applied = 0, updates = 0; model.onApplied = { applied += 1 }
        let observation = model.objectWillChange.sink { updates += 1 }; defer { observation.cancel() }
        model.apply(); precondition(updates > 0, "Apply must notify the native view to disable its modified-state button"); precondition(applied == 1 && !model.modified && !defaults.bool(forKey: "ShowListBackgroundImage"))
        precondition(!model.edit("ShowListBackgroundImage", text: "FALSE") && model.values["ShowListBackgroundImage"] == "false")
        precondition(model.edit("ShowListBackgroundImage", text: "")); model.apply()
        precondition(defaults.object(forKey: "ShowListBackgroundImage") == nil && model.values["ShowListBackgroundImage"] == "" && !model.modified)
        model.cancel(); precondition(model.values["ShowListBackgroundImage"] == "true")
        precondition(model.edit("ShowListBackgroundImage", text: "false")); model.cancel()
        precondition(defaults.object(forKey: "ShowListBackgroundImage") == nil && !model.modified)
        defaults.set(false, forKey: "StyleCommitMessages")
        precondition(model.edit("AutoCompleteMinChars", text: "0")); model.apply()
        precondition(!defaults.bool(forKey: "StyleCommitMessages"), "Apply must preserve changes from another native settings page")
        precondition(defaults.integer(forKey: "AutoCompleteMinChars") == 0)
        precondition(model.edit("AutoCompleteMinChars", text: String(repeating: "9", count: 200))); model.apply()
        precondition(defaults.integer(forKey: "AutoCompleteMinChars") == Int(Int32.max) && !model.modified)
        precondition(model.values["AutoCompleteMinChars"] == String(repeating: "9", count: 200), "Apply preserves the source editor's input until reopening")
        precondition(model.edit("AutoCompleteMinChars", text: "")); model.apply(); model.cancel()
        precondition(defaults.object(forKey: "AutoCompleteMinChars") == nil && model.values["AutoCompleteMinChars"] == "3")
        var published: [FinderMenuSettings] = []
        let finder = AdvancedSettingsModel(defaults: defaults, publishFinderMenu: { published.append($0) })
        precondition(finder.edit("ShowContextMenuIcons", text: "false")); finder.cancel()
        precondition(published.isEmpty && defaults.object(forKey: "ShowContextMenuIcons") == nil)
        precondition(finder.edit("ShowContextMenuIcons", text: "false")); finder.apply()
        precondition(published == [FinderMenuSettings(showIcons: false)] && !finder.modified)
        precondition(finder.edit("ShowContextMenuIcons", text: "")); finder.apply()
        precondition(published.last == FinderMenuSettings() && defaults.object(forKey: "ShowContextMenuIcons") == nil)
        let count = published.count
        precondition(finder.edit("ShowAppContextMenuIcons", text: "false")); finder.apply()
        precondition(published.count == count, "App icon changes must not publish Finder settings")
        struct PublicationError: Error {}
        let failure = AdvancedSettingsModel(defaults: defaults, publishFinderMenu: { _ in throw PublicationError() })
        precondition(failure.edit("ShowContextMenuIcons", text: "false")); failure.apply()
        precondition(!failure.modified && !defaults.bool(forKey: "ShowContextMenuIcons") && failure.error!.contains("Settings saved"))
        print("Actual Advanced receiver: Finder drafts/Cancel/Apply/default reset, separate app preference and saved-but-publication-failed error passed. Signed handoff remains pending.")
        print("Actual native Advanced receiver: 52 Name/Value rows, editing/read-only columns, geometry, deferred Apply, default deletion, Cancel, unchanged-page preservation, zero/overflow and source input retention passed. Native F2/double-click/field editor/window close remain pending.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='TurtleGitAdvancedSettingsTest-') as directory:
    folder = pathlib.Path(directory)
    main = folder / 'Driver.swift'; main.write_text(driver)
    binary = folder / 'verify'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-target', platform.machine() + '-apple-macosx13.0',
                    '-F', str(frameworks), '-framework', 'TurtleGitCore',
                    '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                    str(root / 'Sources/TurtleGitMac/AdvancedSettings.swift'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
