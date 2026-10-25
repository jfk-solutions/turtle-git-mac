import AppKit
import TurtleGitCore

struct MergeWhitespaceDisplayVerification {
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitWhitespaceDisplay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "TurtleGit.WhitespaceNative." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("before.cpp"), mine = folder.appendingPathComponent("after.cpp")
        let before = "雪🦎 \t first\r\nsecond  line\nlast without ending", after = "雪🦎 \t first\nsecond  line\nlast without ending"
        try Data(before.utf8).write(to: base); try Data(after.utf8).write(to: mine)
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
        defer { controller.window?.close() }
        let model = controller.model
        model.comparisonDefaults = defaults; model.commentProfileURL = folder.appendingPathComponent("ignorecomments.txt")
        model.setWhitespaceDisplay(.init()); model.load(); try await TwoPaneEngineVerification.settled(model)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await TwoPaneEngineVerification.wait {
            TwoPaneEngineVerification.editors(controller.window?.contentView).filter { $0 is MergeWhitespaceDisplaying }.count == 2
        }
        let views = TwoPaneEngineVerification.editors(controller.window?.contentView)
        guard let left = views.first(where: { !$0.isEditable }), let renderer = (left as? MergeWhitespaceDisplaying)?.whitespaceRenderer else { preconditionFailure("Missing whitespace source renderer") }
        try await TwoPaneEngineVerification.wait { renderer.markers.contains { $0.kind == .ending(.crlf, changed: true) } }
        precondition(renderer.markers.contains { $0.kind == .space } && renderer.markers.contains { $0.kind == .tab })
        precondition(renderer.markers.filter { if case .ending = $0.kind { return true }; return false }.count == 2)
        let strings = views.map(\.string), selections = views.map { $0.selectedRange() }, generation = model.alignmentGeneration
        for icons in [false, true] {
            model.setWhitespaceDisplay(.init(visible: true, endingIcons: icons))
            try await TwoPaneEngineVerification.wait { renderer.preferences.endingIcons == icons }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                left.appearance = NSAppearance(named: appearance); left.needsDisplay = true
                let rect = NSRect(x: 0, y: 0, width: min(440, left.bounds.width), height: min(130, left.bounds.height))
                guard let bitmap = left.bitmapImageRepForCachingDisplay(in: rect) else { preconditionFailure("Missing whitespace bitmap") }
                left.cacheDisplay(in: rect, to: bitmap)
                let file = "merge-whitespace-" + (icons ? "icons-" : "shapes-") + name + ".png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/" + file))
            }
        }
        model.setWhitespaceDisplay(.init(visible: false, endingIcons: true))
        try await TwoPaneEngineVerification.wait { views.allSatisfy { ($0 as? MergeWhitespaceDisplaying)?.whitespaceRenderer.preferences.visible == false } }
        precondition(MergeWhitespaceDisplayPreferences.load(from: defaults) == .init(visible: false, endingIcons: true))
        precondition(views.map(\.string) == strings && views.map { $0.selectedRange() } == selections)
        precondition(model.alignmentGeneration == generation && !model.dirty && !model.canUndo)
        model.busy = true; model.setWhitespaceDisplay(.init()); model.busy = false
        precondition(model.whitespaceDisplay == .init(visible: false, endingIcons: true))
        var colors = MergeColorPreferences()
        colors.light[.filtered] = .init(0, 0x336699); colors.dark[.filtered] = .init(0xdddddd, 0x336699)
        colors.light[.normal] = .init(0x112233, 0x445566); colors.dark[.normal] = .init(0x112233, 0x445566)
        colors.dark[.whitespace] = .init(0xff00ff, 0)
        try colors.save(to: defaults); NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: defaults)
        try await TwoPaneEngineVerification.wait {
            guard let color = left.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
                  let rgb = color.usingColorSpace(.sRGB) else { return false }
            return abs(rgb.blueComponent - 0.6) < 0.01
        }
        let normalOffset = (left.string as NSString).range(of: "second").location
        let foreground = (left.textStorage?.attribute(.foregroundColor, at: normalOffset, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        precondition(foreground != nil && abs(foreground!.redComponent - 17.0 / 255) < 0.01)
        precondition(views.map(\.string) == strings && !model.dirty && !model.canUndo && model.alignmentGeneration == generation)
        colors.restore(dark: true); try colors.save(to: defaults); NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: defaults)
        let finalBase = try Data(contentsOf: base), finalMine = try Data(contentsOf: mine)
        precondition(finalBase == Data(before.utf8) && finalMine == Data(after.utf8))
        controller.window?.close(); try await TwoPaneEngineVerification.wait { MergeRegexOperations.activeRequests == 0 }
        print("Whitespace display: production source plans, spaces/tabs/original CRLF and changed ending, unended final-line suppression, original icon/shape light/dark renders, persistence, stale busy refusal and unchanged text/selection/history/files passed. Owned window closed.")
    }
}
