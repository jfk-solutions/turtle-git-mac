import AppKit
import TurtleGitCore

struct MergeMarkedWordNativeVerification {
    @MainActor static func require(_ value: @autoclosure () -> Bool, line: Int = #line) throws {
        if !value() { throw NSError(domain: "MergeMarkedWordNative", code: line, userInfo: [NSLocalizedDescriptionKey: "Marked-word assertion at line \(line)"]) }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws { try await MergeFindNativeVerification.wait(condition) }
    @MainActor static func views(_ owner: NSWindowController) -> [NSView] { MergeFindNativeVerification.descendants(owner.window?.contentView) }
    @MainActor static func marked(_ view: NSTextView) -> MergeFindHighlights { (view as! MergeFindProviding).mergeFindHighlights }
    @MainActor static func event(_ view: NSTextView, offset: Int, count: Int = 2, local: Bool = false) -> NSEvent {
        let layout = view.layoutManager!, container = view.textContainer!
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
        let point = view.convert(NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: local ? [.option] : [], timestamp: 0, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
    }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMarkedWord-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.MarkedWord.Native." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base.swift"), mine = root.appendingPathComponent("mine.swift")
        let lines = (0..<80).map { row in [5, 40, 65].contains(row) ? "row \(row) token\(row == 5 ? " token" : "")" : row == 7 ? "local" : "row \(row)" }
        let before = lines.joined(separator: "\n") + "\n"
        var changed = lines; changed[30] = "changed row 30"; let after = changed.joined(separator: "\n") + "\n"
        try Data(before.utf8).write(to: base); try Data(after.utf8).write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
        defer { owner.window?.close() }
        let model = owner.model; model.comparisonDefaults = defaults; model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); model.load()
        try await wait { !model.busy && !model.filtering && model.alignment != nil }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { views(owner).filter { $0 is MergeFindProviding }.count == 2 && views(owner).contains { $0 is MergeLocatorNativeView } }
        let editors = views(owner).compactMap { $0 as? NSTextView }.filter { $0 is MergeFindProviding }
        let destination = editors.first { $0.string.contains("changed row") }!, source = editors.first { $0 !== destination }!
        let bar = views(owner).first { $0 is MergeLocatorNativeView } as! MergeLocatorNativeView
        let first = (destination.string as NSString).range(of: "token")
        destination.mouseDown(with: event(destination, offset: first.location + 1))
        try require(destination.selectedRange() == first)
        for text in editors { try require(marked(text).markedWord == "token" && marked(text).markedRanges.count == 4) }
        try await wait { bar.highlights.count == 3 && bar.highlights[0].marked.count == 3 && bar.highlights[2].marked.count == 3 }
        try require(bar.highlights[1].marked.isEmpty && !model.dirty && !model.canUndo)
        // Repeated double-click toggles the shared word off, then back on.
        destination.mouseDown(with: event(destination, offset: first.location + 1)); try require(editors.allSatisfy { marked($0).markedWord.isEmpty })
        destination.mouseDown(with: event(destination, offset: first.location + 1))
        let local = (destination.string as NSString).range(of: "local")
        destination.mouseDown(with: event(destination, offset: local.location + 1, local: true))
        try require(marked(destination).markedWord == "local" && marked(source).markedWord == "token")
        try require(!MergeMarkedWordInterface.mouse(event(destination, offset: local.location, count: 3), in: destination))
        try require(editors.allSatisfy { marked($0).markedWord == "token" })
        let search = MergeFindWindowController(text: destination, defaults: defaults)
        (destination as! MergeFindProviding).mergeFindController = search; defer { search.close() }
        search.search.stringValue = "token"; search.modifiedOnly.state = .on; search.count()
        try require(marked(destination).ranges.isEmpty && marked(destination).paintRanges.count == 4)
        try await wait { bar.highlights[2].search.isEmpty && bar.highlights[2].marked.count == 3 }
        let index = marked(destination).markedRanges.first!.location
        let original = destination.textStorage!.attribute(.backgroundColor, at: index, effectiveRange: nil) as! NSColor
        let combined = destination.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as! NSColor
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                precondition(combined.usingColorSpace(.sRGB) == MergeFindHighlights.intense(MergeFindHighlights.intense(original, scale: 200), scale: 30).usingColorSpace(.sRGB))
            }
        }
        search.modifiedOnly.state = .off; search.count()
        try await wait { bar.highlights[2].search.count == 3 }
        try require((bar.accessibilityValue() as? String)?.contains("6 marked lines; 3 search lines") == true)
        // Only this document's panes participate, even with another editor alive.
        let foreign = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
        defer { foreign.window?.close() }; foreign.model.comparisonDefaults = defaults; foreign.model.load()
        try await wait { !foreign.model.busy && !foreign.model.filtering && foreign.model.alignment != nil }
        foreign.window?.contentView?.layoutSubtreeIfNeeded()
        try require(views(foreign).compactMap { $0 as? NSTextView }.filter { $0 is MergeFindProviding }.allSatisfy { marked($0).markedWord.isEmpty })
        // Real source menu route, icon policy and execution-time busy refusal.
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let popup = (destination as! ComparisonContextMenuProviding).comparisonContextMenu(defaults: defaults, pasteboard: board)
        let clear = popup.items.first { $0.action == #selector(NSTextView.turtleClearMarkedWord(_:)) }!
        try require(clear.isEnabled && clear.image != nil)
        model.busy = true; try require(NSApp.sendAction(clear.action!, to: clear.target, from: clear)); try require(marked(destination).markedWord == "token"); model.busy = false
        // Real editing, reprojected ranges and queued locator publication.
        model.activatePane(base: false); model.editingEnabled = true
        try await wait { destination.isEditable }
        try require((destination as! MergeFindProviding).replaceFindMatches(marked(destination).markedRanges, with: "gone"))
        try await wait { !model.filtering && !destination.string.contains("token") && marked(destination).markedRanges.isEmpty && bar.highlights[2].marked.isEmpty && bar.highlights[2].search.isEmpty }
        try require(marked(source).markedRanges.count == 4)
        model.undo(); try await wait { !model.filtering && destination.string.contains("token token") && marked(destination).markedRanges.count == 4 && bar.highlights[2].marked.count == 3 }
        if let capture = ProcessInfo.processInfo.environment["TURTLEGIT_MARKED_WORD_CAPTURE"] {
            let folder = URL(fileURLWithPath: capture); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                bar.appearance = NSAppearance(named: appearance); bar.fishEye = false
                guard let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { throw NSError(domain: "Locator capture", code: 1) }
                bar.effectiveAppearance.performAsCurrentDrawingAppearance { bar.cacheDisplay(in: bar.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("merge-search-locator-" + name + ".png"))
            }
        }
        let retainedBase = try Data(contentsOf: base), retainedMine = try Data(contentsOf: mine)
        try require(retainedBase == Data(before.utf8) && retainedMine == Data(after.utf8))
        destination.turtleClearMarkedWord(nil)
        try await wait { editors.allSatisfy { marked($0).markedRanges.isEmpty } && bar.highlights.allSatisfy { $0.marked.isEmpty } }
        try require(marked(destination).paintRanges.count == 4 && bar.highlights[2].search.count == 3)
        owner.window?.close()
        let held = marked(destination).markedWord
        MergeMarkedWordInterface.apply("foreign", local: false, in: destination); try require(marked(destination).markedWord == held)
        print("PASS: actual shared/local/toggled/triple-click word marking; layered source colors, Find and locator bands; menu/busy/retired/foreign guards; real replacement and Undo; files unchanged; owned windows closed")
    }
}
