import AppKit
import SwiftUI
import TurtleGitCore

struct MergeColorsNativeVerification {
    @MainActor static func verify() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "MergeColorsNative", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        func rgb(_ color: NSColor) -> UInt32? {
            guard let color = color.usingColorSpace(.sRGB) else { return nil }
            return UInt32((color.redComponent * 255).rounded()) << 16 | UInt32((color.greenComponent * 255).rounded()) << 8 | UInt32((color.blueComponent * 255).rounded())
        }
        let suite = "TurtleGit.MergeColorsNative." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); MergePalette.reload() }
        var saved = MergeColorPreferences()
        saved.light[.added] = .init(0x112233, 0x445566); saved.dark[.added] = .init(0x778899, 0x334455)
        try saved.save(to: prefs)
        let model = MergeColorsSettingsModel(preferences: prefs, dark: false), transaction = SettingsTransaction()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MergeColorsSettings(model: model).environment(\.settingsTransaction, transaction))
        window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
        defer { transaction.invalidate(); window.contentView = nil; window.close() }
        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) } }
        try await TwoPaneEngineVerification.wait { views(MergeColorChoiceView.self, in: host).count == 17 }
        func choice(_ identifier: String) throws -> MergeColorChoiceView {
            guard let view = views(MergeColorChoiceView.self, in: host).first(where: { $0.identifier?.rawValue == "MergeColors." + identifier }) else { throw NSError(domain: "Missing color " + identifier, code: 1) }
            return view
        }
        let swatches = views(MergeColorChoiceView.self, in: host)
        try check(swatches.count == 17 && !swatches.contains { $0.identifier?.rawValue == "MergeColors.filtered.foreground" || $0.identifier?.rawValue == "MergeColors.whitespace.background" }, "Source channel shape differs")
        let addedForeground = try choice("added.foreground"), addedBackground = try choice("added.background")
        func send(_ item: NSMenuItem) throws { try check(NSApplication.shared.sendAction(item.action!, to: item.target, from: item), "Menu action did not route") }
        try check(addedForeground.choices.items.map(\.title) == ["Automatic", "", "More colors…"] && addedForeground.choices.items[0].image != nil, "Source choices/default swatch missing")
        try send(addedForeground.choices.items[0])
        try await TwoPaneEngineVerification.wait { model.changed && transaction.modified }
        try check(model.draft.light[.added]?.foreground == 0 && model.draft.light[.added]?.background == 0x445566 && model.draft.dark == saved.dark && MergeColorPreferences.load(from: prefs) == saved, "Automatic changed another channel/palette or persisted before Apply")
        // Native custom color action strips alpha and converts calibrated color to sRGB.
        addedBackground.well.color = NSColor(srgbRed: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0, alpha: 0.2)
        try check(NSApplication.shared.sendAction(addedBackground.well.action!, to: addedBackground.well.target, from: addedBackground.well), "Native custom color action missing")
        try await TwoPaneEngineVerification.wait { model.draft.light[.added]?.background == 0x123456 }
        try check(addedBackground.well.color.alphaComponent == 1, "Opacity leaked into source RGB color")
        let palette = views(NSSegmentedControl.self, in: host).first { $0.identifier?.rawValue == "MergeColors.Palette" }!
        palette.selectedSegment = 1; try check(NSApplication.shared.sendAction(palette.action!, to: palette.target, from: palette), "Palette action missing")
        try await TwoPaneEngineVerification.wait { model.dark && rgb(addedBackground.well.color) == 0x334455 }
        try send(addedBackground.choices.items[0])
        try await TwoPaneEngineVerification.wait { model.draft.dark[.added]?.background == MergeColorPreferences.standard(.added, dark: true).background }
        try check(model.draft.dark[.added]?.foreground == 0x778899 && model.draft.light[.added]?.background == 0x123456, "Dark Automatic lost the light draft or dark foreground")
        transaction.cancel(); try await TwoPaneEngineVerification.wait { !transaction.modified && model.draft == saved }
        // Restore Default affects only the currently selected palette.
        model.restoreDefault(); try await TwoPaneEngineVerification.wait { transaction.modified }
        try check(model.draft.dark == MergeColorPreferences().dark && model.draft.light == saved.light, "Restore Default crossed palettes")
        transaction.apply(closeAfter: false); try await TwoPaneEngineVerification.wait { !transaction.busy && !transaction.modified }
        let applied = MergeColorPreferences.load(from: prefs)
        try check(applied == model.draft && applied.light == saved.light && applied.dark == MergeColorPreferences().dark, "Apply did not retain both palettes")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance); host.layoutSubtreeIfNeeded()
            try check(swatches.allSatisfy { let rect = $0.convert($0.bounds, to: host); return rect.minX >= -1 && rect.maxX <= host.bounds.maxX + 1 && $0.well.bounds.width > 0 }, "Native swatch bounds overflow")
        }
        // Exercise actual shared-panel ownership without displaying it.
        let panel = NSColorPanel.shared, alpha = panel.showsAlpha
        addedBackground.presentPanel = { $0.orderOut(nil) }
        try send(addedBackground.choices.items[2]); panel.orderOut(nil)
        try check(addedBackground.well.isActive && !panel.showsAlpha, "More colors did not own an RGB-only panel")
        window.close()
        try check(!addedBackground.well.isActive && !addedBackground.well.isEnabled && !panel.isVisible && panel.showsAlpha == alpha, "Window close leaked owned panel/alpha state")
        let closed = model.draft
        try send(addedBackground.choices.items[0]); try check(model.draft == closed, "Retired choice changed draft")
        // Closing an inactive page must not hide a panel owned by another color well.
        let other = MergeSettingsColorWell(); other.activate(true); panel.orderOut(nil)
        addedBackground.retire(); try check(other.isActive, "Retired inactive picker deactivated another owner")
        other.deactivate(); panel.orderOut(nil)
        print("Merge Colors: all 17 source channels, native Automatic/More colors menus/default swatches, custom RGB/opacity conversion, independent light/dark drafts, selective Restore Default, shared Settings Apply/Cancel, actual light/dark control bounds and shared-panel owner/close/retired fencing passed. Owned panel/window closed; private preferences only.")
    }
}
