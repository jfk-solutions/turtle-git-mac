import AppKit
import TurtleGitCore

@main struct InlineEngineVerification {
    struct Sample: Decodable {
        let base: String, destination: String, word: Bool
        let modified: [[Int]], tokens: [[Int]]
    }
    @MainActor static func sameColor(_ actual: NSColor?, _ expected: NSColor, _ appearance: NSAppearance) -> Bool {
        var result = false
        appearance.performAsCurrentDrawingAppearance {
            if let actual = actual?.usingColorSpace(.sRGB), let expected = expected.usingColorSpace(.sRGB) { result = actual == expected }
        }
        return result
    }
    @MainActor static func main() async throws {
        try await MergeInlineNativeVerification.verify()
        let path = ProcessInfo.processInfo.environment["TURTLEGIT_INLINE_SOURCE_EXPECTED"]!
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitInlineEngine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "TurtleGit.InlineEngine." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        for word in [false, true] {
            for (old, new) in [("aba", "baa"), ("baa", "aba")] {
                let a = "keep " + (word ? old.map(String.init).joined(separator: " ") : old) + " shared tail"
                let b = "keep " + (word ? new.map(String.init).joined(separator: " ") : new) + " shared tail"
                let sample = try MergeInlineNativeVerification.unwrap(samples.first { $0.base == a && $0.destination == b && $0.word == word }, "Missing source tie case")
                let units = [a.utf16.count, b.utf16.count]
                let lengths = word ? sample.tokens : units.map { Array(repeating: 1, count: $0) }
                let offsets = lengths.map { side -> [Int] in var result = [0]; for n in side { result.append(result.last! + n) }; return result }
                let expected = [0, 1].map { side in sample.modified.map { item in
                    let start = item[side * 2], end = start + item[side * 2 + 1]
                    return NSRange(location: offsets[side][start], length: offsets[side][end] - offsets[side][start])
                } }
                let base = folder.appendingPathComponent("base.txt"), mine = folder.appendingPathComponent("mine.txt")
                try Data((a + "\n").utf8).write(to: base); try Data((b + "\n").utf8).write(to: mine)
                let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
                do {
                    defer { owner.close() }
                    let model = owner.model; model.load()
                    try await TwoPaneEngineVerification.settled(model)
                    model.setInlineWordDiff(word)
                    owner.window?.contentView?.layoutSubtreeIfNeeded()
                    // An ended source has its real text record plus the pinned
                    // final empty NoEnding record. Both occupy a native display
                    // row, but the extra display LF contributes no source bytes.
                    let displayStrings = [a, b].map { $0 + "\n\n" }
                    for side in [true, false] {
                        let cells = model.displayCells(base: side)
                        try MergeInlineNativeVerification.require(cells.count == 2 && cells[1].lineNumber == 2 && cells[1].text.isEmpty && cells[1].state == .normal, "Missing final source NoEnding record")
                        try MergeInlineNativeVerification.require(model.draftText(base: side) == (side ? a : b) + "\n", "Display EOF record changed source text")
                    }
                    // Two NSTextViews can exist before SwiftUI has published the
                    // loaded source strings. Count alone observes construction,
                    // not the presentation consumed by the assertions below.
                    var presented = false
                    for _ in 0..<1000 {
                        owner.window?.contentView?.layoutSubtreeIfNeeded()
                        let views = TwoPaneEngineVerification.editors(owner.window?.contentView)
                        presented = !model.busy && !model.filtering && views.count == 2 &&
                            displayStrings.allSatisfy { value in views.contains { $0.window === owner.window && $0.string == value } }
                        if presented { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    let actual = TwoPaneEngineVerification.editors(owner.window?.contentView).map { $0.string.debugDescription }.joined(separator: "; ")
                    try MergeInlineNativeVerification.require(presented, "Repeated source presentation not ready: word=\(word), base=\(a.debugDescription), mine=\(b.debugDescription), busy=\(model.busy), filtering=\(model.filtering), error=\(String(describing: model.error)), actual=[\(actual)]")
                    let diff = try MergeInlineNativeVerification.unwrap(model.inlineDifference(0), "Missing repeated-text inline result")
                    try MergeInlineNativeVerification.require(diff.basePositions == expected[0] && diff.destinationPositions == expected[1], "Model diverged from original source tie choice")
                    let views = TwoPaneEngineVerification.editors(owner.window?.contentView)
                    for side in 0...1 {
                        let view = try MergeInlineNativeVerification.unwrap(views.first { $0.string == displayStrings[side] }, "Missing repeated source pane")
                        let nav = try MergeInlineNativeVerification.unwrap(view as? MergeInlineNavigationProviding, "Missing source navigator")
                        view.setSelectedRange(NSRange(location: 0, length: 0))
                        for target in Array(Set(expected[side].flatMap { [$0.location, NSMaxRange($0)] })).sorted() {
                            nav.navigateInline(forward: true)
                            try MergeInlineNativeVerification.require(view.selectedRange() == NSRange(location: target, length: 0), "Native repeated-text caret stop diverged")
                        }
                        try MergeInlineNativeVerification.require(!nav.canNavigateInline(forward: true), "Repeated-text navigation wrapped")
                        for name in [NSAppearance.Name.aqua, .darkAqua] {
                            owner.window?.appearance = NSAppearance(named: name)
                            try await TwoPaneEngineVerification.wait {
                                (0..<units[side]).allSatisfy { index in
                                    let changed = expected[side].contains { NSLocationInRange(index, $0) }
                                    let color = view.textStorage?.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor
                                    return sameColor(color, changed ? (side == 0 ? MergePalette.inlineRemoved : MergePalette.inlineAdded) : MergePalette.inlineCommon, NSAppearance(named: name)!)
                                }
                            }
                        }
                    }
                    model.previewLine(atRow: 0)
                    let preview = MergeLineDiffPreview(); preview.update(model)
                    try MergeInlineNativeVerification.require(preview.displayedStrings == [a, b], "Preview altered source strings")
                    for side in 0...1 {
                        for name in [NSAppearance.Name.aqua, .darkAqua] {
                            for index in 0..<units[side] {
                                let changed = expected[side].contains { NSLocationInRange(index, $0) }
                                let color = preview.displayedAttributes[side].attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor
                                try MergeInlineNativeVerification.require(sameColor(color, changed ? (side == 0 ? MergePalette.inlineRemoved : MergePalette.inlineAdded) : MergePalette.inlineCommon, NSAppearance(named: name)!), "Preview did not use source tie highlight")
                            }
                        }
                    }
                    let unchanged = try Data(contentsOf: base) == Data((a + "\n").utf8) && Data(contentsOf: mine) == Data((b + "\n").utf8)
                    try MergeInlineNativeVerification.require(!model.dirty && !model.canUndo && unchanged, "Inline matcher changed source data/history")
                }
            }
        }
        print("PASS: inline engine completed: original native inline family plus repeated-text character/word ties in both directions, preview paint, caret stops, Aqua/Dark Aqua, immutable files and Undo. Owners closed.")
    }
}
