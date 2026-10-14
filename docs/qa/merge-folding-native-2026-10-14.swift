import AppKit
import TurtleGitCore

struct MergeFoldingNativeVerification {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitFolding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "TurtleGit.Folding." + UUID().uuidString, prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let lines = (0..<70).map { "row \($0) 🐢 unchanged content\n" }
        var mineLines = lines, theirLines = lines
        mineLines[30] = "mine changed content\n"; theirLines[30] = "theirs changed content\n"
        let base = folder.appendingPathComponent("base.cpp"), mine = folder.appendingPathComponent("mine.cpp"), theirs = folder.appendingPathComponent("theirs.cpp")
        let initial = [lines.joined(), mineLines.joined(), theirLines.joined()]
        for (url, text) in zip([base, mine, theirs], initial) { try Data(text.utf8).write(to: url) }
        let pair = FileComparisonWindowController(comparison: try WorkingFileComparison(base: theirs, destination: mine), permissions: [], preferences: prefs)
        defer { pair.close() }
        let two = pair.model; two.load(); try await TwoPaneEngineVerification.settled(two)
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(pair.window?.contentView).filter { !$0.isFieldEditor && $0.string.contains("row 10") }.count == 2 }
        let views = TwoPaneEngineVerification.editors(pair.window?.contentView).filter { !$0.isFieldEditor && $0.string.contains("row 10") }
        let original = views.map(\.string)
        two.setCollapsed(true)
        try await TwoPaneEngineVerification.wait { views.allSatisfy { $0.textStorage?.attribute(.mergeFoldMarker, at: 0, effectiveRange: nil) != nil } }
        for view in views {
            guard let layout = view.layoutManager, let container = view.textContainer else { throw Failure(message: "Missing native text layout") }
            layout.ensureLayout(for: container)
            let first = layout.glyphIndexForCharacter(at: 0), last = layout.glyphIndexForCharacter(at: (view.string as NSString).range(of: "row 69").location)
            let extent = layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).maxY - layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY
            try require(extent < 350, "Collapsed layout retained full seventy-line height: \(extent)")
            try require(!(view.accessibilityCustomActions() ?? []).isEmpty, "No accessible expansion action")
        }
        try require(views.map(\.string) == original && !two.dirty && !two.canUndo, "Folding changed text/history")
        guard let target = views.first else { throw Failure(message: "Missing pair view") }
        let offset = (target.string as NSString).range(of: "row 10").location
        target.setSelectedRange(NSRange(location: offset, length: 0)); target.scrollRangeToVisible(target.selectedRange())
        try await TwoPaneEngineVerification.wait { views.allSatisfy { $0.textStorage?.attribute(.mergeFoldHidden, at: offset, effectiveRange: nil) == nil } }
        two.setCollapsed(false)
        try await TwoPaneEngineVerification.wait { views.allSatisfy { $0.textStorage?.attribute(.mergeFoldMarker, at: 0, effectiveRange: nil) == nil } }
        two.switchPaneMode(true); try await TwoPaneEngineVerification.settled(two); two.setCollapsed(true)
        try await TwoPaneEngineVerification.wait { !two.folding.projection.rows.isEmpty && two.folding.projection.rows.count < 70 }

        let triple = TextConflictWindowController(repository: GitRepository(root: folder), access: nil, path: "mine.cpp", workingMerge: try WorkingTextMerge(base: base, theirs: theirs, mine: mine), preferences: prefs)
        defer { triple.close() }
        let three = triple.model; three.load()
        try await ThreePaneEngineVerification.wait { !three.busy && three.document != nil }
        try await ThreePaneEngineVerification.wait { three.resultFolding.folding.visibility.contains(.marker) }
        let result = three.result, anchors = three.resultPresentation.foldAnchors, dirty = three.dirty, undo = three.canUndo
        try require(!anchors.offsets.isEmpty, "Engine omitted common result anchors")
        guard let marker = three.resultFolding.projection.rows.firstIndex(where: { if case .marker = $0 { return true }; return false }) else { throw Failure(message: "No result marker") }
        try require(three.resultFolding.expand(screenRow: marker), "Result expansion refused")
        try require(three.folding.folding.visibility[0] == .shown, "Result expansion did not reveal both source panes")
        try require(three.result == result && three.resultPresentation.foldAnchors == anchors && three.dirty == dirty && three.canUndo == undo, "Expansion mutated result/provenance")
        three.busy = true; let saved = three.folding.collapsed; three.setCollapsed(!saved)
        try require(three.folding.collapsed == saved, "Busy view accepted fold command"); three.busy = false
        for appearance in [NSAppearance.Name.aqua, .darkAqua] { triple.window?.appearance = NSAppearance(named: appearance); triple.window?.contentView?.displayIfNeeded() }
        for (url, text) in zip([base, mine, theirs], initial) { try require(try Data(contentsOf: url) == Data(text.utf8), "Folding modified an input file") }
        three.retire(); try require(!three.resultFolding.reveal(sourceRow: 0), "Retired folding accepted action")
        print("PASS: native collapsed geometry, preserved source text/history, reveal, combined mode, engine-anchored three-pane expansion, gates, accessibility controls and both appearances")
    }
}
