import AppKit
import TurtleGitCore

struct MergeComparisonLifecycleVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitComparisonLifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite = "TurtleGit.ComparisonLifecycle." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs); MergeComparisonOptions.exact.save(to:prefs)
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), original = "head\nkeep\ntail\n"
        try Data(original.utf8).write(to:base); try Data(original.utf8).write(to:mine)
        let owner = FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs), model = owner.model
        defer { owner.close() }; owner.window!.alphaValue = 0; owner.window!.orderFront(nil); model.load()
        func wait(_ ready: () -> Bool, line: Int = #line) async throws {
            for _ in 0..<2500 { owner.window?.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(description:"Comparison lifecycle wait at line \(line), busy=\(model.busy), pending=\(model.hasPendingEditorChoice), error=\(String(describing:model.error))")
        }
        func settled() async throws { try await wait { !model.busy && !model.filtering && !model.hasPendingEditorChoice && model.alignmentSelections.isEmpty && !model.initialNavigationPending } }
        try await settled()
        func editor(base: Bool) throws -> NSTextView {
            guard let view = TwoPaneEngineVerification.editors(owner.window?.contentView).first(where: { $0.accessibilityLabel() == (base ? "Base file" : "Destination file") }) else { throw Failure(description:"Missing native comparison pane") }; return view
        }
        func type(_ replacement: String, replacing text: String, base: Bool = false, line: Int = #line) async throws {
            model.activatePane(base:base); model.editingEnabled = true; let view = try editor(base:base)
            try await wait { view.isEditable && view.string == model.displayCells(base:base).map(\.displayText).joined(separator:"\n") + "\n" }; owner.window!.makeFirstResponder(view)
            let range = (view.string as NSString).range(of:text); try require(range.location != NSNotFound,"Missing text \(text) at line \(line), base=\(base), display=\(String(reflecting:view.string)), draft=\(String(reflecting:model.draftText(base:base)))")
            view.insertText(replacement,replacementRange:range); try await settled()
        }
        func save() async throws { model.saveAll(); try await settled(); try require(!model.dirty && model.error == nil,"Savepoint failed") }
        try await type("keep",replacing:"keep"); try await save()
        try await type("keep",replacing:"keep"); try require(model.dirty,"Same bytes after Save stayed clean")
        model.undo(); try await settled(); try require(!model.dirty,"Undo did not return to saved edit identity")
        model.redo(); try await settled(); try require(model.dirty,"Redo lost post-save identity")
        model.undo(); try await settled()
        try await type("keep",replacing:"keep"); try require(model.dirty,"New history branch reused the saved identity")
        try await save(); model.undo(); try await settled(); try require(model.dirty,"Undo across a later Save was clean")
        model.redo(); try await settled(); try require(!model.dirty,"Redo to later saved point was dirty")
        let right = try editor(base:false)
        right.insertText("one\ntwo\n",replacementRange:NSRange(location:5,length:0)); try await settled(); try require(model.alignment!.rows.count == 5,"Insertion did not pad opposite rows")
        right.insertText("",replacementRange:NSRange(location:5,length:8)); try await settled()
        try require(model.alignment!.rows.count == 3 && model.draftText(base:false) == original && right.selectedRange().location == 5,"Deleted padding survived or moved caret")
        model.undo(); try await settled(); try require(model.alignment!.rows.count == 5,"Undo did not restore padded rows")
        model.redo(); try await settled(); try require(model.alignment!.rows.count == 3,"Redo did not clean empty rows")
        try await save()
        var question: NSAlert?, answer: ((NSApplication.ModalResponse) -> Void)?
        model.presentProjectionQuestion = { alert,parent,completion in question = alert; answer = completion; alert.beginSheetModal(for:parent,completionHandler:completion) }
        func respond(_ title: String) async throws {
            guard let alert = question, let index = alert.buttons.firstIndex(where: { $0.title == title }) else { throw Failure(description:"Missing projection answer " + title) }
            question = nil
            owner.window!.endSheet(alert.window,returnCode:.init(rawValue:NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
            try await settled()
        }
        let insensitive = MergeComparisonOptions(whitespace:.compare,ignoreCase:true)
        try await type("draft",replacing:"head"); let draft = model.draftText(base:false)
        model.setComparisonOptions(insensitive); try await wait { question != nil && owner.window!.attachedSheet != nil }
        let closeAllowed = owner.windowShouldClose(owner.window!), quit = TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared)
        try require(model.comparisonOptions == .exact && MergeComparisonOptions.load(from:prefs) == .exact && !closeAllowed && quit == .terminateCancel,"Projection question ownership/persistence: model=\(model.comparisonOptions), prefs=\(MergeComparisonOptions.load(from:prefs)), close=\(closeAllowed), quit=\(quit), choices=\(FileComparisonWindowModel.activeProjectionChoices)")
        model.updateDraft("stale edit",base:false); model.setComparisonOptions(.init(whitespace:.ignoreAll))
        try require(model.draftText(base:false) == draft,"Question allowed competing mutation")
        let cancelledAnswer = answer; try await respond("Cancel"); cancelledAnswer?(.alertSecondButtonReturn)
        try require(model.comparisonOptions == .exact && model.draftText(base:false) == draft && model.canUndo,"Cancel or duplicate answer changed projection/history")
        model.setComparisonOptions(insensitive); try await wait { question != nil }; try await respond("Don’t Save")
        try require(model.comparisonOptions == insensitive && model.draftText(base:false) == original && !model.canUndo && !model.canRedo && !model.dirty,"Discard did not reload or clear Undo")
        model.undo(); try require(model.draftText(base:false) == original,"Obsolete Undo resurrected discarded rows")
        // A stale working snapshot must leave options/preferences/history intact.
        try await type("unsaved",replacing:"head"); try Data("external\n".utf8).write(to:mine)
        model.setComparisonOptions(.exact); try await wait { question != nil }; try await respond("Save")
        try require(model.error != nil && model.dirty && model.canUndo && model.comparisonOptions == insensitive && MergeComparisonOptions.load(from:prefs) == insensitive,"Failed Save applied pending options")
        // Acknowledge the owned error alert before asking the editor to reload.
        model.error = nil; try await wait { owner.window!.attachedSheet == nil }
        try Data(original.utf8).write(to:mine); model.load(discardingDraft:true); try await settled()
        try require(model.error == nil && model.draftText(base:false) == original,"Recovery reload failed: \(String(describing:model.error))")
        try await type("LEFT",replacing:"head",base:true); try await type("RIGHT",replacing:"head")
        model.activatePane(base:true); model.undo(); try await settled()
        try require(model.draftText(base:true) == "LEFT\nkeep\ntail\n" && model.draftText(base:false) == original,"Cross-pane Undo changed an older pane or clobbered its draft")
        model.undo(); try await settled(); try require(model.draftText(base:true) == original && model.draftText(base:false) == original,"Global Undo order lost the earlier edit")
        model.activatePane(base:false); model.redo(); try await settled(); model.redo(); try await settled()
        try require(model.draftText(base:true) == "LEFT\nkeep\ntail\n" && model.draftText(base:false) == "RIGHT\nkeep\ntail\n","Cross-pane Redo lost a peer payload")
        model.setComparisonOptions(.exact); try await wait { question != nil }
        try require(question!.buttons.map(\.title) == ["Save left pane","Save right pane","Save both panes","Don’t Save","Cancel"] && question!.window.defaultButtonCell === question!.buttons[2].cell,"Two-pane save choices/default differ")
        try await respond("Save left pane")
        try require(try String(contentsOf:base,encoding:.utf8) == "LEFT\nkeep\ntail\n" && String(contentsOf:mine,encoding:.utf8) == original && !model.dirty && !model.canUndo,"Save-left changed right or retained discarded history")
        try await type("LEFT2",replacing:"LEFT",base:true); try await type("RIGHT2",replacing:"head")
        model.setComparisonOptions(insensitive); try await wait { question != nil }; try await respond("Save both panes")
        try require(try String(contentsOf:base,encoding:.utf8) == "LEFT2\nkeep\ntail\n" && String(contentsOf:mine,encoding:.utf8) == "RIGHT2\nkeep\ntail\n" && !model.dirty,"Save-both did not write both panes")
        try await type("LEFT3",replacing:"LEFT2",base:true); try await type("RIGHT3",replacing:"RIGHT2")
        model.setComparisonOptions(.exact); try await wait { question != nil }; try await respond("Save right pane")
        try require(try String(contentsOf:base,encoding:.utf8) == "LEFT2\nkeep\ntail\n" && String(contentsOf:mine,encoding:.utf8) == "RIGHT3\nkeep\ntail\n" && !model.dirty,"Save-right changed left")
        let filter = MergeRegexFilter(name:"Names",expression:"LEFT|RIGHT",replacement:"SIDE")
        model.regexDefaults = prefs; try MergeRegexFilters.save([filter],defaults:prefs); model.refreshRegexFilters()
        try await type("REGEX",replacing:"RIGHT3"); model.selectRegexFilter(filter.name); try await wait { question != nil }; try await respond("Cancel")
        try require(model.regexFilterName == nil && model.dirty,"Regex Cancel discarded current draft")
        model.selectRegexFilter(filter.name); try await wait { question != nil }; try await respond("Don’t Save")
        try require(model.regexFilterName == filter.name && !model.canUndo && !model.dirty,"Regex change did not reload source/history")
        try await type("PENDING",replacing:"RIGHT3"); try MergeRegexFilters.save([],defaults:prefs); model.refreshRegexFilters(); try await wait { question != nil }; try await respond("Cancel")
        try require(model.regexFilterName == filter.name && model.regexFilters == [filter] && model.dirty,"Active-filter removal Cancel changed cached projection")
        model.refreshRegexFilters(); try await wait { question != nil }; try await respond("Don’t Save")
        try require(model.regexFilterName == nil && model.regexFilters.isEmpty && !model.dirty,"Active-filter removal did not recompare")
        try await type("CLOSE",replacing:"RIGHT3"); model.setComparisonOptions(insensitive); try await wait { question != nil }
        let late = answer, bytes = try Data(contentsOf:mine)
        owner.close(); late?(.alertSecondButtonReturn)
        try await wait { FileComparisonWindowModel.activeProjectionChoices == 0 && FileComparisonWindowModel.activePaneExports == 0 && MergeRegexOperations.activeRequests == 0 }
        try require(MergeComparisonOptions.load(from:prefs) == .exact && Data(contentsOf:mine) == bytes,"Retired projection answer changed options or file")
        print("PASS: saved/branched same-byte edit identities, native gap cleanup/caret/Undo, owned options Cancel/discard/failed Save/per-pane Save/all Save, regex/removal choices, cleared stale history, close/Quit/duplicate/late gates and exact files; owned windows closed")
    }
}
