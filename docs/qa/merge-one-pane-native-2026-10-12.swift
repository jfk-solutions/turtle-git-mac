import AppKit
import TurtleGitCore

struct MergeOnePaneNativeVerification {
    @MainActor static func verify() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "OnePaneNative", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitOnePane-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.OnePaneNative." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(true, forKey: "TurtleGitMerge.OnePane")
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt")
        let before = "same\r\nold 🦎 words\r\nremoved\r\nlast", after = "same\r\nnew words\r\nlast"
        let beforeBytes = try ComparisonTextEncoding.utf16LEBOM.encode(before), afterBytes = try ComparisonTextEncoding.utf8BOM.encode(after)
        try beforeBytes.write(to: base); try afterBytes.write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        defer { owner.window?.close() }
        let model = owner.model; model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); model.load()
        func wait(_ ready: () -> Bool, line: Int = #line) async throws {
            for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw NSError(domain: "OnePane wait at line \(line): mode=\(model.onePaneMode), active=\(model.onePaneActive), editors=\(TwoPaneEngineVerification.editors(owner.window?.contentView).count), busy=\(model.busy), filtering=\(model.filtering)", code: 1)
        }
        try await TwoPaneEngineVerification.settled(model)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { TwoPaneEngineVerification.editors(owner.window?.contentView).count == 1 }
        let view = TwoPaneEngineVerification.editors(owner.window?.contentView)[0]
        try check(model.onePaneActive && view.string == "same\nold 🦎 words\nremoved\nnew words\nlast\n" && !model.canCreateUnifiedPatch, "Combined ordering/default/patch gate differs: mode=\(model.onePaneMode), active=\(model.onePaneActive), string=\(String(reflecting: view.string)), patch=\(model.canCreateUnifiedPatch)")
        try check(model.locatorMap.lineCount == 5 && model.locatorMap.columns[2].isEmpty, "Combined locator differs")
        model.navigate(1); try check(view.selectedRange().location == 5, "Next difference did not target first removal")
        let selected = (view.string as NSString).range(of: "old 🦎 words"); view.setSelectedRange(selected)
        model.showInlineDiff = false; owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(view.selectedRange() == selected, "Display option collapsed removed selection")
        model.activatePane(base: false); model.editingEnabled = true
        try await wait { view.isEditable }
        view.insertText("changed", replacementRange: (view.string as NSString).range(of: "old"))
        try await TwoPaneEngineVerification.settled(model)
        let edited = "same\r\nchanged 🦎 words\r\nnew words\r\nlast"
        try check(model.draftText(base: false) == edited && model.dirty && model.canUndo, "Removed-line edit lost unselected payload or included untouched removals")
        model.undo(); try await TwoPaneEngineVerification.settled(model); try check(model.draftText(base: false) == after && !model.dirty, "Combined Undo failed")
        model.redo(); try await TwoPaneEngineVerification.settled(model); try check(model.draftText(base: false) == edited, "Combined Redo failed")
        model.choosePaneSwitch = { _ in .alertThirdButtonReturn }; model.switchPaneMode(false)
        try check(model.onePaneMode && model.dirty && prefs.bool(forKey: "TurtleGitMerge.OnePane"), "Cancel view switch changed draft/mode")
        model.save(); try await wait { !model.busy && !model.filtering && !model.dirty }
        let saved = try Data(contentsOf: mine), retained = try Data(contentsOf: base)
        let expected = try ComparisonTextEncoding.utf8BOM.encode(edited)
        try check(saved == expected && retained == beforeBytes, "Combined Save changed Base/BOM/EOL")
        model.switchPaneMode(false); try await TwoPaneEngineVerification.settled(model)
        try await wait { TwoPaneEngineVerification.editors(owner.window?.contentView).count == 2 }
        try check(!model.onePaneMode && !prefs.bool(forKey: "TurtleGitMerge.OnePane"), "Two-pane switch/default persistence failed")
        model.switchPaneMode(true); try await TwoPaneEngineVerification.settled(model)
        try await wait { TwoPaneEngineVerification.editors(owner.window?.contentView).count == 1 }
        let current = TwoPaneEngineVerification.editors(owner.window?.contentView)[0]
        model.editingEnabled = true; try await wait { current.isEditable }
        current.insertText("discarded", replacementRange: (current.string as NSString).range(of: "changed")); try await TwoPaneEngineVerification.settled(model)
        model.choosePaneSwitch = { _ in .alertSecondButtonReturn }; model.switchPaneMode(false)
        try await TwoPaneEngineVerification.settled(model)
        try check(!model.onePaneMode && !model.dirty && model.draftText(base: false) == edited, "Discard switch did not reread saved Mine")
        let destination = TwoPaneEngineVerification.editors(owner.window?.contentView).first { $0.isEditable }!
        destination.insertText("save branch", replacementRange: (destination.string as NSString).range(of: "changed")); try await TwoPaneEngineVerification.settled(model)
        let saveBranch = model.draftText(base: false)
        model.choosePaneSwitch = { _ in .alertFirstButtonReturn }; model.switchPaneMode(true)
        try await TwoPaneEngineVerification.settled(model)
        try await wait { TwoPaneEngineVerification.editors(owner.window?.contentView).count == 1 }
        let savedBranch = try Data(contentsOf: mine), expectedBranch = try ComparisonTextEncoding.utf8BOM.encode(saveBranch)
        try check(model.onePaneMode && !model.dirty && savedBranch == expectedBranch, "Save-before-switch failed")
        let combinedEditor = TwoPaneEngineVerification.editors(owner.window?.contentView)[0]
        model.editingEnabled = true; try await wait { combinedEditor.isEditable }
        guard let find = combinedEditor as? MergeFindProviding else { throw NSError(domain: "Combined Find receiver missing", code: 1) }
        let matches = MergeFind.matches("words", in: find.mergeFindLines, options: .init())
        try check(matches.count == 3 && find.replaceFindMatches(matches, with: "text"), "Combined Find/Replace All did not include removed/displayed matches")
        try await TwoPaneEngineVerification.settled(model)
        try check(model.draftText(base: false).contains("old 🦎 text") && !model.draftText(base: false).contains("words") && !model.draftText(base: false).contains("removed"), "Combined Replace All retained wrong source payload")
        model.undo(); try await TwoPaneEngineVerification.settled(model); try check(model.draftText(base: false) == saveBranch, "Replace All did not undo as one action")
        combinedEditor.setSelectedRange(NSRange(location: (combinedEditor.string as NSString).range(of: "old").location, length: 0))
        combinedEditor.insertTab(nil); try await TwoPaneEngineVerification.settled(model)
        try check(model.draftText(base: false).contains("\told 🦎 words"), "Combined removed-row Tab lost payload")
        model.undo(); try await TwoPaneEngineVerification.settled(model); try check(model.draftText(base: false) == saveBranch, "Tab Undo failed")
        model.retireImageLoader(); model.switchPaneMode(false); try check(model.onePaneMode, "Retired view switch accepted")
        print("One-pane: source removal/addition ordering, saved default, combined locator/navigation, stable removed selection, native removed-line typing, Undo/Redo, exact UTF-8 BOM/CRLF Save with Base unchanged, Save/Cancel/Discard/two-pane roundtrip/persistence, native combined Replace All/Tab with single Undo and retired guards passed. Owned window closed; private files/preferences only.")
    }
}
