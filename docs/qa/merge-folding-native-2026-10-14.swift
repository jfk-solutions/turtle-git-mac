import AppKit
import TurtleGitCore

struct MergeFoldingNativeVerification {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    static func phase(_ text: String) { FileHandle.standardError.write(Data(("Folding phase: " + text + "\n").utf8)) }
    @MainActor final class Notifications { var edits = 0 }
    @MainActor static func verifyTransactions(preferences: UserDefaults) throws {
        let text = (0..<90).map { "row \($0) 🐢\n" }.joined()
        let view = NSTextView(frame: NSRect(x:0,y:0,width:640,height:400))
        view.string = text
        let storage = view.textStorage!
        storage.addAttributes([.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular),.foregroundColor:NSColor.systemGreen],range:NSRange(location:0,length:storage.length))
        storage.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:NSRange(location:5,length:4))
        // Capture the normal AppKit font fallback for emoji before comparing
        // restoration; NSTextStorage fixes fonts when an editing batch ends.
        storage.fixAttributes(in:NSRange(location:0,length:storage.length))
        let original = NSAttributedString(attributedString:storage)
        let controller = MergeFoldingController(preferences:preferences)
        var unchanged = Array(repeating:true,count:MergeLineEndings.lineRanges(in:text).count); unchanged[40] = false
        controller.update(unchanged:unchanged); controller.setCollapsed(true)
        let layout = MergeFoldTextLayout(), notifications = Notifications()
        let observation = NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,object:storage,queue:nil) { _ in MainActor.assumeIsolated { notifications.edits += 1 } }
        defer { NotificationCenter.default.removeObserver(observation); MergeFoldingPreferences(collapsed:false).saveCollapsed(to:preferences); controller.retire() }
        layout.apply(to:view,controller:controller)
        try require(notifications.edits == 1,"Fold application leaked intermediate text edits: \(notifications.edits)")
        notifications.edits = 0; layout.prepare(view)
        if !storage.isEqual(to:original) {
            for index in 0..<storage.length {
                let actual = storage.attributes(at:index,effectiveRange:nil), expected = original.attributes(at:index,effectiveRange:nil)
                if !NSDictionary(dictionary:actual).isEqual(to:expected) { phase("restored attribute difference at \(index): actual=\(actual), expected=\(expected)"); break }
            }
        }
        try require(notifications.edits == 1 && storage.isEqual(to:original),"Fold restoration did not publish one complete original attribute map; notifications=\(notifications.edits)")
        layout.apply(to:view,controller:controller)
        var geometry = 0, expansions = 0
        controller.geometryChanged = { geometry += 1 }
        controller.expanded = { ranges in expansions += 1; precondition(ranges.count > 1) }
        let revision = controller.revision
        layout.reveal(selection:NSRange(location:0,length:storage.length),in:view)
        try require(controller.revision == revision + 1 && geometry == 1 && expansions == 1,"Selection published per-row projections")
        try require(controller.folding.visibility.allSatisfy { $0 == .shown } && storage.isEqual(to:original) && view.string == text,"Batch reveal changed source attributes/text or left hidden rows")
        controller.update(unchanged:unchanged,force:true)
        let gatedRevision = controller.revision
        controller.actionsAllowed = { false }
        try require(!controller.reveal(sourceRows:Array(unchanged.indices)) && controller.revision == gatedRevision,"Busy batch reveal changed projection")
        controller.retire()
        try require(!controller.reveal(sourceRows:[0,Int.max]),"Retired batch reveal accepted work")
    }
    @MainActor static func verify() async throws {
        phase("start")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitFolding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "TurtleGit.Folding." + UUID().uuidString, prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let lines = (0..<70).map { "row \($0) 🐢 unchanged content\n" }
        var mineLines = lines, theirLines = lines
        mineLines[30] = "mine changed content\n"; theirLines[30] = "theirs changed content\n"
        mineLines[38] = "mine second conflict\n"; theirLines[38] = "theirs second conflict\n"
        let base = folder.appendingPathComponent("base.cpp"), mine = folder.appendingPathComponent("mine.cpp"), theirs = folder.appendingPathComponent("theirs.cpp")
        let initial = [lines.joined(), mineLines.joined(), theirLines.joined()]
        for (url, text) in zip([base, mine, theirs], initial) { try Data(text.utf8).write(to: url) }
        phase("atomic layout transactions and batch reveal")
        try verifyTransactions(preferences:prefs)
        phase("creating pair")
        let pair = FileComparisonWindowController(comparison: try WorkingFileComparison(base: theirs, destination: mine), permissions: [], preferences: prefs)
        defer { pair.close() }
        pair.window?.alphaValue = 0; pair.window?.orderFront(nil)
        let two = pair.model; two.load(); try await TwoPaneEngineVerification.settled(two)
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(pair.window?.contentView).filter { !$0.isFieldEditor && $0.string.contains("row 10") }.count == 2 }
        let views = TwoPaneEngineVerification.editors(pair.window?.contentView).filter { !$0.isFieldEditor && $0.string.contains("row 10") }
        let original = views.map(\.string)
        phase("pair loaded; collapsing")
        two.setCollapsed(true)
        try await TwoPaneEngineVerification.wait { views.allSatisfy { $0.textStorage?.attribute(.mergeFoldMarker, at: 0, effectiveRange: nil) != nil } }
        phase("fold attributes applied; measuring TextKit")
        for view in views {
            guard let layout = view.layoutManager, let container = view.textContainer else { throw Failure(message: "Missing native text layout") }
            phase("ensure layout")
            layout.ensureLayout(for: container)
            phase("layout ready")
            let first = layout.glyphIndexForCharacter(at: 0), last = layout.glyphIndexForCharacter(at: (view.string as NSString).range(of: "row 69").location)
            let extent = layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).maxY - layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY
            try require(extent < 350, "Collapsed layout retained full seventy-line height: \(extent)")
            try require(!(view.accessibilityCustomActions() ?? []).isEmpty, "No accessible expansion action")
        }
        try require(views.map(\.string) == original && !two.dirty && !two.canUndo, "Folding changed text/history")
        guard let target = views.first else { throw Failure(message: "Missing pair view") }
        let offset = (target.string as NSString).range(of: "row 10").location
        phase("selection reveal")
        target.setSelectedRange(NSRange(location: offset, length: 0)); target.scrollRangeToVisible(target.selectedRange())
        try await TwoPaneEngineVerification.wait { views.allSatisfy { $0.textStorage?.attribute(.mergeFoldHidden, at: offset, effectiveRange: nil) == nil } }
        two.setCollapsed(false)
        try await TwoPaneEngineVerification.wait { views.allSatisfy { $0.textStorage?.attribute(.mergeFoldMarker, at: 0, effectiveRange: nil) == nil } }
        phase("combined mode")
        two.switchPaneMode(true); try await TwoPaneEngineVerification.settled(two); two.setCollapsed(true)
        try await TwoPaneEngineVerification.wait { !two.folding.projection.rows.isEmpty && two.folding.projection.rows.count < 70 }

        phase("creating three-pane")
        let triple = TextConflictWindowController(repository: GitRepository(root: folder), access: nil, path: "mine.cpp", workingMerge: try WorkingTextMerge(base: base, theirs: theirs, mine: mine), preferences: prefs)
        defer { triple.close() }
        triple.window?.alphaValue = 0; triple.window?.orderFront(nil)
        let three = triple.model; three.load()
        try await ThreePaneEngineVerification.wait { !three.busy && three.document != nil }
        try await ThreePaneEngineVerification.wait { three.resultFolding.folding.visibility.contains(.marker) }
        phase("three-pane loaded; anchored expansion")
        let result = three.result, anchors = three.resultPresentation.foldAnchors, dirty = three.dirty, undo = three.canUndo
        try require(!anchors.offsets.isEmpty, "Engine omitted common result anchors")
        guard let marker = three.resultFolding.projection.rows.firstIndex(where: { if case .marker = $0 { return true }; return false }) else { throw Failure(message: "No result marker") }
        try require(three.resultFolding.expand(screenRow: marker), "Result expansion refused")
        try require(three.folding.folding.visibility[0] == .shown, "Result expansion did not reveal both source panes")
        try require(three.result == result && three.resultPresentation.foldAnchors == anchors && three.dirty == dirty && three.canUndo == undo, "Expansion mutated result/provenance")
        phase("aligned result expansion beyond serialized conflict markers")
        try require(three.alignedResultProjection != nil, "Missing aligned result for coordinate regression")
        guard let tailMarker = three.resultFolding.projection.rows.firstIndex(where: {
            if case .marker(let range) = $0 { return range.lowerBound > 30 && range.upperBound <= 38 }; return false
        }), case .marker(let tailRange) = three.resultFolding.projection.rows[tailMarker] else { throw Failure(message:"Missing short unchanged section between conflicts") }
        let serializedCandidates = three.resultPresentation.foldAnchors.resultRows(in:three.result).filter { tailRange.contains($0.value) }.keys
        try require(serializedCandidates.allSatisfy { !tailRange.contains($0) && three.folding.folding.visibility[$0] == .shown },"Fixture did not separate aligned coordinates from serialized marker offsets")
        try require(three.resultFolding.expand(screenRow:tailMarker),"Post-conflict result expansion refused")
        try require(tailRange.allSatisfy { three.folding.folding.visibility.indices.contains($0) && three.folding.folding.visibility[$0] == .shown },"Aligned result expansion used serialized conflict-marker coordinates")
        try require(three.result == result && three.resultPresentation.foldAnchors == anchors && three.dirty == dirty && three.canUndo == undo,"Tail expansion changed document/history")
        three.busy = true; let saved = three.folding.collapsed; three.setCollapsed(!saved)
        try require(three.folding.collapsed == saved, "Busy view accepted fold command"); three.busy = false
        phase("appearance drawing")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] { triple.window?.appearance = NSAppearance(named: appearance); triple.window?.contentView?.displayIfNeeded() }
        for (url, text) in zip([base, mine, theirs], initial) { try require(try Data(contentsOf: url) == Data(text.utf8), "Folding modified an input file") }
        phase("retirement")
        three.retire(); try require(!three.resultFolding.reveal(sourceRow: 0), "Retired folding accepted action")
        print("PASS: native collapsed geometry, preserved source text/history, reveal, combined mode, engine-anchored three-pane expansion, gates, accessibility controls and both appearances")
    }
}
