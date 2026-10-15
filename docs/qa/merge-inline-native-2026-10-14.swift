import AppKit
import TurtleGitCore

struct MergeInlineNativeVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func verify() async throws {
        UserDefaults.standard.setVolatileDomain(["TurtleGit.DiffTools": try JSONEncoder().encode(DiffToolPreferences())], forName: "NSArgumentDomain")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitInline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "TurtleGit.InlineNative." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("base.cpp"), mine = folder.appendingPathComponent("mine.cpp"), theirs = folder.appendingPathComponent("theirs.cpp")
        let baseText = "🐢 stable prefix value 00 suffix constant\r\n", mineText = "🐢 stable prefix value 20 suffix constant\r\n", theirsText = "🐢 stable prefix value 10 suffix constant\r\n"
        try Data(baseText.utf8).write(to: base); try Data(mineText.utf8).write(to: mine); try Data(theirsText.utf8).write(to: theirs)
        var general = MergeGeneralPreferences(firstDifference: false, firstConflict: false); general.save(to: prefs)
        let pair = FileComparisonWindowController(comparison: try WorkingFileComparison(base: theirs, destination: mine), permissions: [])
        defer { pair.close() }
        let two = pair.model; two.comparisonDefaults = prefs; two.load()
        try await TwoPaneEngineVerification.settled(two)
        pair.window?.contentView?.layoutSubtreeIfNeeded()
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(pair.window?.contentView).count == 2 }
        let views = TwoPaneEngineVerification.editors(pair.window?.contentView)
        let right = try unwrap(views.first { $0.string.contains("value 20") }, "Missing Mine pane")
        let navigation = try unwrap(right as? MergeInlineNavigationProviding, "Missing native inline navigator")
        let valueOffset = (right.string as NSString).range(of: "20").location
        right.setSelectedRange(NSRange(location: 0, length: 0))
        try require(navigation.canNavigateInline(forward: true), "Inline next incorrectly disabled")
        navigation.navigateInline(forward: true)
        try require(right.selectedRange() == NSRange(location: valueOffset, length: 0), "Inline next did not reach chunk start")
        navigation.navigateInline(forward: true)
        try require(right.selectedRange() == NSRange(location: valueOffset + 1, length: 0), "Character inline next did not reach chunk end")
        try require(!navigation.canNavigateInline(forward: true), "Inline next wrapped to another line")
        navigation.navigateInline(forward: false)
        try require(right.selectedRange().location == valueOffset, "Inline previous did not reach chunk start")
        two.setInlineWordDiff(true)
        right.setSelectedRange(NSRange(location: valueOffset, length: 0)); navigation.navigateInline(forward: true)
        try require(right.selectedRange().location == valueOffset + 2, "Word navigation did not use token end")
        let cells = TwoPaneEngineVerification.editors(pair.window?.contentView).map { $0.string }
        let generation = two.alignmentGeneration
        two.setInlineDiff(false)
        try require(!MergeInlinePresentation.defaultEnabled(from: prefs) && !navigation.canNavigateInline(forward: false), "Saved disable did not gate navigation")
        two.setInlineWordDiff(false)
        try require(two.inlineWordDiff, "Disabled word command changed session mode")
        two.setInlineDiff(true)
        try require(two.alignmentGeneration == generation && !two.dirty && !two.canUndo && views.map(\.string) == cells, "Display controls altered documents or edit history")
        // The combined source view has no live opposite view for inline navigation.
        two.switchPaneMode(true)
        try await TwoPaneEngineVerification.settled(two)
        try require(!navigation.canNavigateInline(forward: true), "Combined mode exposed two-view navigation")
        two.switchPaneMode(false)
        try await TwoPaneEngineVerification.settled(two)
        let context = GitRepository(root: folder)
        let triple = TextConflictWindowController(repository: context, access: nil, path: "mine.cpp", workingMerge: try WorkingTextMerge(base: base, theirs: theirs, mine: mine), preferences: prefs)
        defer { triple.close() }
        let three = triple.model; three.load()
        try await ThreePaneEngineVerification.wait { !three.busy && three.document != nil }
        triple.window?.contentView?.layoutSubtreeIfNeeded()
        try await ThreePaneEngineVerification.wait { ThreePaneEngineVerification.textViews(triple.window?.contentView).filter { !$0.isEditable && !$0.isFieldEditor }.count >= 2 }
        let sourceViews = ThreePaneEngineVerification.textViews(triple.window?.contentView).filter { !$0.isEditable && !$0.isFieldEditor && $0.string.contains("stable prefix") }
        let source = try unwrap(sourceViews.first { $0.string.contains("value 20") }, "Missing three-pane Mine source")
        let offset = (source.string as NSString).range(of: "20").location
        let commonOffset = (source.string as NSString).range(of: "🐢 stable prefix value 20").location
        try await ThreePaneEngineVerification.wait {
            guard let changed = source.textStorage?.attribute(.backgroundColor, at: offset, effectiveRange: nil) as? NSColor,
                  let common = source.textStorage?.attribute(.backgroundColor, at: commonOffset, effectiveRange: nil) as? NSColor else { return false }
            var distinct = false
            (triple.window?.effectiveAppearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
                if let changed = changed.usingColorSpace(.sRGB), let common = common.usingColorSpace(.sRGB) { distinct = changed != common }
            }
            return distinct
        }
        let originalDirty = three.dirty, originalUndo = three.canUndo
        let originalResult = three.result, originalSelection = sourceViews.map { $0.selectedRange() }, originalStrings = sourceViews.map(\.string)
        let changedRow = try unwrap(three.sourceComparison?.rows.firstIndex { $0.mine.displayText.contains("value 20") && $0.theirs.displayText.contains("value 10") }, "Missing aligned changed source row")
        let char = try unwrap(three.inlineDifference(changedRow, mine: true), "Three-pane character difference absent")
        try require(char.destination.first?.length == 1, "Three-pane character range incorrect")
        three.setInlineWordDiff(true)
        let word = try unwrap(three.inlineDifference(changedRow, mine: true), "Three-pane word difference absent")
        try require(word.destination.first?.length == 2, "Three-pane word cache did not invalidate")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            triple.window?.appearance = NSAppearance(named: name)
            triple.window?.contentView?.displayIfNeeded()
            try require(three.inlineDifference(changedRow, mine: false) != nil, "Appearance lost inline projection")
        }
        if let directory = CommandLine.arguments.last, !directory.hasPrefix("--"), FileManager.default.fileExists(atPath: directory) {
            try await capture(pair, name: "two-pane-inline", directory: URL(fileURLWithPath: directory))
            pair.window?.orderOut(nil)
            try await capture(triple, name: "three-pane-inline", directory: URL(fileURLWithPath: directory))
            triple.window?.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        three.setInlineDiff(false)
        try require(three.inlineDifference(changedRow, mine: true) == nil, "Three-pane toggle did not suppress inline colors")
        three.setInlineDiff(true)
        general.maximumInlineLength = 2; general.save(to: prefs)
        NotificationCenter.default.post(name: .mergeEditorPreferencesChanged, object: nil)
        try require(three.inlineDifference(changedRow, mine: true) == nil, "Three-pane maximum length change reused stale cache")
        try require(three.result == originalResult && three.dirty == originalDirty && three.canUndo == originalUndo && sourceViews.map(\.string) == originalStrings && sourceViews.map { $0.selectedRange() } == originalSelection, "Inline display changed merge data/selection/history")
        try require(try Data(contentsOf: base) == Data(baseText.utf8) && Data(contentsOf: mine) == Data(mineText.utf8) && Data(contentsOf: theirs) == Data(theirsText.utf8), "Inline commands changed source files")
        three.retire(); try require(three.inlineDifference(changedRow, mine: true) == nil, "Retired inline model remained active")
        for icon in [MenuIcon.mergeInline, .mergeInlineWord, .mergePreviousInline, .mergeNextInline] { try require(icon.image() != nil, "Missing original inline icon") }
        print("Merge inline: native chunk start/end and word navigation, no wrap/combined navigation, persisted visibility, three-pane attributed source colors in light/dark, word/limit cache invalidation, retirement and unchanged text/selection/Undo/files passed. Owners closed.")
    }
    @MainActor static func capture(_ controller: NSWindowController, name: String, directory: URL) async throws {
        guard let window = controller.window, let view = window.contentView else { throw Failure(message: "Missing inline capture window") }
        NSApplication.shared.setActivationPolicy(.regular)
        controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(nanoseconds: 150_000_000)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "No inline capture bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size); image.lockFocus()
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: view.bounds.size).fill()
                bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            }
            image.unlockFocus()
            guard let data = image.tiffRepresentation, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { throw Failure(message: "No inline capture PNG") }
            try png.write(to: directory.appendingPathComponent(name + "-" + suffix + ".png"))
        }
    }
    static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw Failure(message: message) }; return value }
}
