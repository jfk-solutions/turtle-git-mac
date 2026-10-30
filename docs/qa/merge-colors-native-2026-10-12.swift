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
        var transactionNotifications = 0
        transaction.changed = { transactionNotifications += 1 }
        let window = NSWindow(contentRect: NSRect(x: -24000, y: -24000, width: 640, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        let host = NSHostingView(rootView: MergeColorsSettings(model: model).environment(\.settingsTransaction, transaction))
        window.contentView = host; host.frame = window.contentLayoutRect
        // Native children can exist before SwiftUI appearance registers the
        // Settings participant and the owner probe publishes its edit context.
        // Order only this invisible private window; never activate the app.
        window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { transaction.changed = {}; transaction.invalidate(); window.contentView = nil; window.close() }
        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) } }
        func contextIdentity(_ view: MergeColorChoiceView) -> String? {
            // Inspect the existing receipt without adding a production test API
            // or calling an action to discover whether its context is ready.
            Mirror(reflecting: view).children.first { $0.label == "contextIdentity" }?.value as? String
        }
        func currentControls() -> Bool {
            let controls = views(MergeColorChoiceView.self, in: host)
            let context = model.editContext
            return controls.count == 17 && model.active && model.accepts(context) && controls.allSatisfy {
                guard let identifier = $0.identifier?.rawValue else { return false }
                return $0.window === window && $0.well.window === window && $0.well.isEnabled && $0.arrow.isEnabled
                    && contextIdentity($0) == identifier + "." + context.identity
            }
        }
        func state() -> String {
            let controls = views(MergeColorChoiceView.self, in: host)
            let context = model.editContext
            let details = controls.map { control in
                "\(control.identifier?.rawValue ?? "missing"){attached=\(control.window === window),enabled=\(control.well.isEnabled)/\(control.arrow.isEnabled),context=\(contextIdentity(control) ?? "missing"),rgb=\(String(describing: rgb(control.well.color)))}"
            }.joined(separator: ";")
            return "model.changed=\(model.changed),transaction.modified=\(transaction.modified),transaction.busy=\(transaction.busy),registration/notifications=\(transactionNotifications),active=\(model.active),dark=\(model.dark),acceptsCurrent=\(model.accepts(context)),expectedContext=\(context.identity),windowVisible=\(window.isVisible),alpha=\(window.alphaValue),swatches=\(controls.count),controls=[\(details)]"
        }
        func wait(_ message: String, line: UInt = #line, _ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "MergeColorsNative", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(message) at \(line); \(state())"])
        }
        try await wait("Initial Settings registration/current color controls") {
            transactionNotifications > 0 && currentControls()
        }
        try check(!model.changed && !transaction.modified && model.draft == saved,
                  "Readiness observation changed the initial draft")
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
        try await wait("Native color/transaction publication") { model.changed && transaction.modified }
        try check(model.draft.light[.added]?.foreground == 0 && model.draft.light[.added]?.background == 0x445566 && model.draft.dark == saved.dark && MergeColorPreferences.load(from: prefs) == saved, "Automatic changed another channel/palette or persisted before Apply")
        // Native custom color action strips alpha and converts calibrated color to sRGB.
        addedBackground.well.color = NSColor(srgbRed: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0, alpha: 0.2)
        try check(NSApplication.shared.sendAction(addedBackground.well.action!, to: addedBackground.well.target, from: addedBackground.well), "Native custom color action missing")
        try await wait("Native color/transaction publication") { model.draft.light[.added]?.background == 0x123456 }
        try check(addedBackground.well.color.alphaComponent == 1, "Opacity leaked into source RGB color")
        let palette = views(NSSegmentedControl.self, in: host).first { $0.identifier?.rawValue == "MergeColors.Palette" }!
        palette.selectedSegment = 1; try check(NSApplication.shared.sendAction(palette.action!, to: palette.target, from: palette), "Palette action missing")
        try await wait("Dark palette/current color controls") { model.dark && currentControls() && rgb(addedBackground.well.color) == 0x334455 }
        try send(addedBackground.choices.items[0])
        try await wait("Native color/transaction publication") { model.draft.dark[.added]?.background == MergeColorPreferences.standard(.added, dark: true).background }
        try check(model.draft.dark[.added]?.foreground == 0x778899 && model.draft.light[.added]?.background == 0x123456, "Dark Automatic lost the light draft or dark foreground")
        transaction.cancel(); try await wait("Cancel/current color controls") { !transaction.modified && model.draft == saved && currentControls() }
        // Restore Default affects only the currently selected palette.
        model.restoreDefault(); try await wait("Restore Default/current color controls") { transaction.modified && currentControls() }
        try check(model.draft.dark == MergeColorPreferences().dark && model.draft.light == saved.light, "Restore Default crossed palettes")
        transaction.apply(closeAfter: false); try await wait("Apply/current color controls") { !transaction.busy && !transaction.modified && currentControls() }
        let applied = MergeColorPreferences.load(from: prefs)
        try check(applied == model.draft && applied.light == saved.light && applied.dark == MergeColorPreferences().dark, "Apply did not retain both palettes")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance); host.layoutSubtreeIfNeeded()
            try check(swatches.allSatisfy { let rect = $0.convert($0.bounds, to: host); return rect.minX >= -1 && rect.maxX <= host.bounds.maxX + 1 && $0.well.bounds.width > 0 }, "Native swatch bounds overflow")
        }
        // Exercise actual shared-panel ownership without displaying it.
        try await wait("Applied palette/current color controls") { currentControls() }
        let panel = NSColorPanel.shared, alpha = panel.showsAlpha
        defer { if addedBackground.well.isActive { addedBackground.well.deactivate() }; panel.orderOut(nil); panel.showsAlpha = alpha }
        addedBackground.presentPanel = { $0.orderOut(nil) }
        try send(addedBackground.choices.items[2]); panel.orderOut(nil)
        try check(addedBackground.well.isActive && !panel.showsAlpha, "More colors did not own an RGB-only panel")
        window.close()
        try check(!addedBackground.well.isActive && !addedBackground.well.isEnabled && !panel.isVisible && panel.showsAlpha == alpha, "Window close leaked owned panel/alpha state")
        let closed = model.draft
        try send(addedBackground.choices.items[0]); try check(model.draft == closed, "Retired choice changed draft")
        // Closing an inactive page must not hide a panel owned by another color well.
        let other = MergeSettingsColorWell(); other.activate(true); panel.orderOut(nil)
        defer { other.deactivate(); panel.orderOut(nil) }
        addedBackground.retire(); try check(other.isActive, "Retired inactive picker deactivated another owner")
        other.deactivate(); panel.orderOut(nil)
        print("Merge Colors: all 17 source channels, native Automatic/More colors menus/default swatches, custom RGB/opacity conversion, independent light/dark drafts, selective Restore Default, shared Settings Apply/Cancel, actual light/dark control bounds and shared-panel owner/close/retired fencing passed. Owned panel/window closed; private preferences only.")
    }
}
