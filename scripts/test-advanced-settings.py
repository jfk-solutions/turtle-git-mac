#!/usr/bin/env python3
"""Actual Advanced Settings model/table receiver; no native windows displayed."""
import pathlib
import os
import shutil
from native_receiver import build_receiver, run_receiver
import tempfile
root = pathlib.Path(__file__).resolve().parent.parent
frameworks = root / 'build/Build/Products/Debug'
driver = r'''
import AppKit
import Combine
import Foundation
import TurtleGitCore
enum RetainedAdvancedSettingsVerification {
    @MainActor static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.Advanced.Receiver." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AdvancedSettingsModel(defaults: defaults, publishFinderMenu: { _ in }, publishCachePersistence: { _ in }, publishCacheTray: { _ in })
        let receiver = AdvancedSettingsTable.Coordinator(model: model)
        let scroll = receiver.makeScrollView(), table = scroll.documentView as! NSTableView
        scroll.frame = NSRect(x: 0, y: 0, width: 650, height: 400); scroll.tile(); table.tile()
        let window=NSWindow(contentRect:NSRect(x:-24000,y:-24000,width:650,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.alphaValue=0;window.contentView=scroll;model.attach(to:window);window.orderFront(nil)
        defer{window.close()}

        precondition(table.tableColumns.map(\.title) == ["Name", "Value"] && table.numberOfRows == AdvancedSettingDefinition.all.count)
        precondition(!table.tableColumns[0].isEditable && table.tableColumns[1].isEditable && !table.allowsColumnReordering)
        precondition(table.headerView!.frame.height > 0 && table.frame.height >= CGFloat(AdvancedSettingDefinition.all.count) * table.rowHeight)
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
        let finder = AdvancedSettingsModel(defaults: defaults, publishFinderMenu: { published.append($0) }, publishCachePersistence: { _ in }, publishCacheTray: { _ in })
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
        let failure = AdvancedSettingsModel(defaults: defaults, publishFinderMenu: { _ in throw PublicationError() }, publishCachePersistence: { _ in }, publishCacheTray: { _ in })
        precondition(failure.edit("ShowContextMenuIcons", text: "false")); failure.apply()
        precondition(failure.modified && !defaults.bool(forKey: "ShowContextMenuIcons") && failure.error!.contains("Settings saved"))
        print("Actual Advanced receiver: Finder drafts/Cancel/Apply/default reset, separate app preference and saved-but-publication-failed error passed. Signed handoff remains pending.")
        print("Actual native Advanced receiver: source-defined Name/Value rows, editing/read-only columns, geometry, deferred Apply, default deletion, Cancel, unchanged-page preservation, zero/overflow and source input retention passed. Native F2/double-click/field editor/window close remain pending.")
    }
}
'''
generated = root/'build/qa/settings-publication-recovery-native-sources'
generated.mkdir(parents=True, exist_ok=True)
retained = generated/'RetainedAdvancedSettings.swift'
if not retained.is_file() or retained.read_text() != driver:
    retained.write_text(driver)
receiver = build_receiver(root, [retained, root/'docs/qa/settings-publication-recovery-native-2026-10-29.swift'], generated)
with tempfile.TemporaryDirectory(prefix='TurtleGitSettingsPublication-') as directory:
    folder = pathlib.Path(directory)
    for name in ['fixture', 'home/Library/Preferences', 'temporary', 'xdg']:
        (folder/name).mkdir(parents=True, mode=0o700)
    environment = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(HOME=str(folder/'home'), CFFIXED_USER_HOME=str(folder/'home'), TMPDIR=str(folder/'temporary')+'/',
                       XDG_CONFIG_HOME=str(folder/'xdg'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                       GIT_CONFIG_COUNT='0', DYLD_FRAMEWORK_PATH=str(frameworks))
    try:
        result=run_receiver([str(receiver),str(folder/'fixture')],cwd=root,env=environment,capture_output=True,text=True,timeout=120,
                            timeout_sample=root/'build/qa/settings-publication-recovery-timeout.sample.txt')
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS Settings publication recovery:' not in result.stdout:
            raise RuntimeError('Settings receiver exited before grouped assertions/drain')
    except BaseException:
        evidence=pathlib.Path(tempfile.mkdtemp(prefix='settings-publication-recovery-failed-',dir=root/'build/qa'))
        shutil.copytree(folder,evidence,dirs_exist_ok=True)
        print('Private failed Settings evidence: '+str(evidence),flush=True)
        raise
