import AppKit
import TurtleGitCore

struct MergeLocatorVerification {
    @MainActor static func locate(_ view: NSView?) -> MergeLocatorNativeView? {
        guard let view else { return nil }
        return (view as? MergeLocatorNativeView) ?? view.subviews.lazy.compactMap { locate($0) }.first
    }
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitLocator-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "TurtleGit.LocatorNative." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("before.cpp"), mine = folder.appendingPathComponent("after.cpp")
        let before = (0..<300).map { "line \($0)\n" }.joined()
        var changed = (0..<300).map { "line \($0)\n" }
        for index in [40, 160, 270] { changed[index] = "changed \(index) 🦎\n" }
        let after = changed.joined()
        try Data(before.utf8).write(to: base); try Data(after.utf8).write(to: mine)
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
        defer { controller.window?.close() }
        let model = controller.model
        model.comparisonDefaults = defaults; model.commentProfileURL = folder.appendingPathComponent("ignorecomments.txt")
        model.load(); try await TwoPaneEngineVerification.settled(model)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await TwoPaneEngineVerification.wait { locate(controller.window?.contentView)?.bounds.height ?? 0 > 100 }
        guard let bar = locate(controller.window?.contentView) else { preconditionFailure("Missing production locator") }
        precondition(bar.map.columns.count == 3 && bar.map.columns[1].isEmpty)
        precondition(bar.map.columns[0].contains { $0.state == .removed } && bar.map.columns[2].contains { $0.state == .added })
        let views = TwoPaneEngineVerification.editors(controller.window?.contentView)
        let selections = views.map { $0.selectedRange() }, initial = model.locatorViewport
        bar.navigate(toFraction: 0.65)
        try await TwoPaneEngineVerification.wait { model.locatorViewport.rows.lowerBound > initial.rows.lowerBound }
        precondition(views.map { $0.selectedRange() } == selections && !model.dirty && !model.canUndo)
        precondition(bar.accessibilityValue() != nil)
        let viewport = model.locatorViewport
        model.busy = true; bar.navigate(toFraction: 0.1); model.scrollLocator(to: 0)
        precondition(model.locatorViewport == viewport); model.busy = false
        bar.enabled = false
        precondition(!bar.accessibilityPerformIncrement()); bar.navigate(toFraction: 0)
        precondition(model.locatorViewport == viewport); bar.enabled = true
        precondition(bar.accessibilityPerformDecrement())
        try await TwoPaneEngineVerification.wait { model.locatorViewport.rows.lowerBound < viewport.rows.lowerBound }
        // Render the real custom NSView rather than an unrendered SwiftUI host.
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            bar.appearance = NSAppearance(named: appearance); bar.needsDisplay = true
            guard let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { preconditionFailure("Missing locator bitmap") }
            bar.cacheDisplay(in: bar.bounds, to: bitmap)
            precondition(bitmap.pixelsWide > 20 && bitmap.pixelsHigh > 100)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/merge-locator-" + name + ".png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        }
        model.setLocatorPreferences(.init(visible: false, fishEye: false))
        try await TwoPaneEngineVerification.wait { locate(controller.window?.contentView) == nil }
        precondition(MergeLocatorPreferences.load(from: defaults) == .init(visible: false, fishEye: false))
        model.setLocatorPreferences(.init())
        try await TwoPaneEngineVerification.wait { locate(controller.window?.contentView) != nil }
        let finalBase = try Data(contentsOf: base), finalMine = try Data(contentsOf: mine)
        precondition(finalBase == Data(before.utf8) && finalMine == Data(after.utf8))
        controller.window?.close()
        try await TwoPaneEngineVerification.wait { MergeRegexOperations.activeRequests == 0 }
        print("Native locator: actual engine state stripes, viewport scrolling, unchanged selections/history/files, stale busy dispatch refusal, accessibility navigation, visibility persistence, recreation and light/dark NSView captures passed. Owned window closed.")
    }
}
