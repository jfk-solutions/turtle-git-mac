// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct MergeColorsSourceVerification {
    struct Failure: Error { let message: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(message: message) } }
    @MainActor static func wait(_ yes: () -> Bool) async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Merge Colors source timeout")
    }
    @MainActor static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    @MainActor static func send(_ item: NSMenuItem) throws { try require(NSApp.sendAction(item.action!, to: item.target, from: item), "Native color item did not dispatch") }
    @MainActor static func rgb(_ color: NSColor) -> UInt32 {
        let color = color.usingColorSpace(.sRGB)!
        return UInt32((color.redComponent*255).rounded()) << 16 | UInt32((color.greenComponent*255).rounded()) << 8 | UInt32((color.blueComponent*255).rounded())
    }
    @MainActor static func capture(_ window: NSWindow, into folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(message: "Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(message: "Capture owner missing") }
            let options = SCStreamConfiguration(); options.includeChildWindows = false; options.width = Int(window.frame.width*2); options.height = Int(window.frame.height*2); options.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure(message: "PNG missing") }
            try png.write(to: folder.appendingPathComponent("merge-colors-source-" + suffix + ".png"))
        }; window.orderOut(nil); window.alphaValue = 0
    }
    @MainActor static func verify() async throws {
        let suite = "TurtleGit.MergeColorsSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); MergePalette.reload() }
        var saved = MergeColorPreferences(); saved.light[.added] = .init(0x112233, 0x445566); saved.dark[.added] = .init(0x778899, 0x334455); try saved.save(to: prefs)
        let model = MergeColorsSettingsModel(preferences: prefs, dark: false), transaction = SettingsTransaction()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 820), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Merge Colors – TurtleGit"; window.isReleasedWhenClosed = false; window.alphaValue = 0
        let viewport = SettingsPageViewport(frame: .zero), host = NSHostingView(rootView: MergeColorsSettings(model: model).environment(\.settingsTransaction, transaction))
        window.contentView = viewport; viewport.pageDocument.addSubview(host); host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: viewport.pageDocument.leadingAnchor), host.trailingAnchor.constraint(equalTo: viewport.pageDocument.trailingAnchor), host.topAnchor.constraint(equalTo: viewport.pageDocument.topAnchor), host.bottomAnchor.constraint(equalTo: viewport.pageDocument.bottomAnchor)])
        defer { transaction.invalidate(); window.close() }
        window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
        func choice() throws -> MergeColorChoiceView {
            guard let control = views(host).compactMap({ $0 as? MergeColorChoiceView }).first(where: { $0.identifier?.rawValue == "MergeColors.added.background" }) else { throw Failure(message: "Added swatch missing") }
            return control
        }
        try await wait { views(host).compactMap { $0 as? MergeColorChoiceView }.count == 17 && model.active }
        let lightContext = model.editContext, oldAutomatic = try choice().choices.items[0], oldMore = try choice().choices.items[2]
        model.selectPalette(true, context: lightContext)
        model.setColor(0x123456, role: .added, foreground: false, context: lightContext); model.restoreDefault(context: lightContext); model.selectPalette(false, context: lightContext)
        try require(model.dark && model.draft == saved, "Stale light controls crossed palette identity")
        try await wait { (try? rgb(choice().well.color)) == 0x334455 }
        try send(oldAutomatic); try send(oldMore); try require(model.draft == saved && !NSColorPanel.shared.isVisible, "Old palette menu changed draft or opened panel")
        let control = try choice(), panel = NSColorPanel.shared, originalAlpha = panel.showsAlpha
        var presentations = 0; control.presentPanel = { presentations += 1; $0.orderOut(nil) }
        let more = control.choices.items[2]; try send(more); try send(more)
        try require(presentations == 1 && control.well.isActive && !panel.showsAlpha, "More colors response duplicated or lost panel")
        model.selectPalette(false, context: model.editContext)
        try await wait { !control.well.isActive && panel.showsAlpha == originalAlpha }
        try require(model.draft == saved, "Palette switch persisted a color")
        let resetContext = model.editContext; model.restoreDefault(context: resetContext)
        let reset = model.draft
        model.setColor(0xabcdef, role: .normal, foreground: false, context: resetContext); model.restoreDefault(context: resetContext)
        try require(model.draft == reset && model.draft.dark == saved.dark, "Reset accepted old context or crossed palettes")
        let foreign = MergeColorsSettingsModel(preferences: prefs, dark: false)
        foreign.setColor(0xabcdef, role: .normal, foreground: false, context: model.editContext)
        try require(foreign.draft == saved, "Foreign model consumed color context")
        model.setColor(0x123456, role: .added, foreground: false); let hiddenContext = model.editContext
        model.setActive(false); model.setColor(0x654321, role: .added, foreground: false, context: hiddenContext)
        try require(model.draft.light[.added]?.background == 0x123456 && model.apply(), "Hidden page edited or refused authorized Apply")
        try require(MergeColorPreferences.load(from: prefs) == model.draft && !model.changed, "Hidden Apply lost palette draft")
        model.setActive(true); model.setColor(0x654321, role: .added, foreground: false, context: hiddenContext)
        try require(model.draft.light[.added]?.background == 0x123456, "Reactivation revived an old control")
        // Shared native control must reject a retained menu even when the RGB
        // values are identical across two different edit contexts.
        let owner = NSWindow(contentRect: .init(x: 0, y: 0, width: 160, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; defer { owner.close() }
        let generic = MergeColorChoiceView(); owner.contentView = generic
        var edits: [UInt32] = []
        generic.configure(value: 0x123456, automatic: 0, label: "Fixture", identifier: "fixture", contextIdentity: "first", changed: { edits.append($0) })
        let firstItem = generic.choices.items[0], firstMore = generic.choices.items[2]
        generic.configure(value: 0x123456, automatic: 0, label: "Fixture", identifier: "fixture", contextIdentity: "second", changed: { edits.append($0) })
        try send(firstItem); try send(firstMore); try require(edits.isEmpty && !generic.well.isActive, "Same-RGB context retained old menu")
        let automatic = generic.choices.items[0]; try send(automatic); try send(automatic)
        try require(edits == [0], "Automatic menu was not single use")
        generic.menuNeedsUpdate(generic.choices); try send(generic.choices.items[0]); try require(edits == [0, 0], "Reopened menu did not get a fresh invocation")
        owner.close()
        model.setActive(true); model.selectPalette(false, context: model.editContext)
        try await wait { views(host).compactMap { $0 as? MergeColorChoiceView }.allSatisfy { $0.well.isEnabled } }
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_COLORS_CAPTURE"] { try await capture(window, into: URL(fileURLWithPath: path)) }
        let closedContext = model.editContext; window.close()
        let closed = model.draft
        model.setColor(0xabcdef, role: .normal, foreground: false, context: closedContext); model.restoreDefault(context: closedContext)
        try require(!model.active && model.draft == closed && !model.apply() && !panel.isVisible, "Owner close revived settings or leaked panel")
        print("PASS Merge Colors source: 17 channels, captured palette/reset/hidden/foreign/closed contexts, authorized hidden Apply, same-RGB stale menus, single-use/reopened choices and native panel ownership; private preferences only")
    }
}
