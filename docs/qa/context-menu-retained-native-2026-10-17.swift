// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import SwiftUI
import TurtleGitCore
struct FinderMenuRetainedVerification {
    @MainActor static func settle(_ view: NSView) {
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ContextMenu.Receiver." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var published: [FinderMenuSettings] = []
        let model = FinderContextMenuSettingsModel(defaults: defaults, publish: { published.append($0); return true }, notify: {})
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
        let failure = FinderContextMenuSettingsModel(defaults: defaults, publish: { _ in throw Failure() }, notify: {})
        failure.draft.hideForUnversioned = false
        precondition(!failure.apply() && failure.modified && failure.message != nil && defaults.data(forKey: "TurtleGit.FinderMenuSettings") == before)
        failure.cancel(); precondition(!failure.modified)
        let unsigned = FinderContextMenuSettingsModel(defaults: defaults, publish: { _ in false }, notify: {})
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
    }
}
