// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

struct MergeViewportOwnershipVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(description: message) } }
    @MainActor static func wait(_ yes: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Viewport ownership timeout at \(line)")
    }
    @MainActor static func verify() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("TurtleGitViewportOwner-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.ViewportOwner." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        MergeGeneralPreferences(firstDifference: true, firstConflict: false).save(to: prefs)
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt")
        let original = [Data("head\nprefix old suffix remains\ntail\n".utf8), Data("head\nprefix new suffix remains\ntail\n".utf8)]
        try original[0].write(to: base); try original[1].write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs, deferInitialLoad: true)
        defer { owner.close() }; let window = owner.window!, model = owner.model
        window.alphaValue = 0; window.orderFront(nil)
        let blocker = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        blocker.isReleasedWhenClosed = false; blocker.alphaValue = 0
        defer { if blocker.sheetParent != nil { window.endSheet(blocker) }; blocker.close() }
        // Hold actual automatic entry until the generation, display and geometry
        // are ready, then deliver its callback while its real host is detached.
        model.beginTransferredDocument(); window.beginSheet(blocker, completionHandler: { _ in })
        try await wait {
            window.contentView?.layoutSubtreeIfNeeded()
            let panes = TwoPaneEngineVerification.editors(window.contentView)
            return !model.busy && !model.filtering && model.alignment != nil && panes.count == 2 && panes.allSatisfy { $0.string.contains("tail") && ($0.enclosingScrollView?.contentSize.height ?? 0) > 32 }
        }
        try require(model.initialNavigationPending, "Sheet did not retain initial entry")
        let host = window.contentView!, oldPanes = TwoPaneEngineVerification.editors(host)
        window.contentView = NSView(); window.endSheet(blocker); blocker.orderOut(nil)
        try require(oldPanes.allSatisfy { $0.window == nil }, "Fixture panes did not detach")
        model.applyViewportNavigation(); model.applyInitialBlockSelection()
        try require(model.initialNavigationPending, "Detached panes consumed initial block/inline entry")
        window.contentView = host; window.contentView?.layoutSubtreeIfNeeded(); model.applyViewportNavigation()
        try await TwoPaneEngineVerification.settled(model)
        var right = TwoPaneEngineVerification.editors(host).first { $0.string.contains("prefix new") }!
        let left = TwoPaneEngineVerification.editors(host).first { $0.string.contains("prefix old") }!
        try require(right.selectedRange() == NSRange(location: 12, length: 0) && (right as! MergeBlockSelecting).mergeSelectedBlockRange == NSRange(location: 5, length: 25), "Attached initial inline/block entry differs")
        try require((left as! MergeBlockSelecting).mergeSelectedBlockRange != nil && model.transferRows == 1..<2, "Attached peer block missing")
        let generation = model.alignmentGeneration
        model.loadOnAppearance(); model.loadOnAppearance()
        try require(!model.busy && model.alignmentGeneration == generation && right.selectedRange().location == 12, "Repeated appearance reloaded an accepted document")
        // Real Undo restoration may wait for attachment, but cannot consume or
        // move a pane while its host is detached from this editor.
        guard let caret = model.captureHistoryCaret(base: false) else { throw Failure(description: "History caret unavailable") }
        right.setSelectedRange(NSRange(location: 0, length: 0)); model.requestHistoryCaret(caret, base: false)
        window.contentView = NSView()
        model.restoreHistoryCaret(base: false, view: right, cells: model.displayCells(base: false))
        model.applyViewportNavigation()
        try require(right.selectedRange() == NSRange(location: 0, length: 0) && model.captureHistoryCaret(base: false) == nil, "Detached history callback consumed or captured a caret")
        window.contentView = host; window.contentView?.layoutSubtreeIfNeeded(); model.applyViewportNavigation()
        try await wait { TwoPaneEngineVerification.editors(host).contains { $0.string.contains("prefix new") && $0.selectedRange() == NSRange(location: 12, length: 0) } }
        right = TwoPaneEngineVerification.editors(host).first { $0.string.contains("prefix new") }!
        let foreign = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs, deferInitialLoad: true)
        defer { foreign.close() }; foreign.window?.alphaValue = 0
        var foreignRegistrations = 0; foreign.model.onRegisterScroll = { _, _ in foreignRegistrations += 1 }
        let scroll = right.enclosingScrollView!
        foreign.model.register(scroll, base: false)
        try require(foreignRegistrations == 0 && !foreign.model.ownsViewport(scroll, base: false) && model.ownsViewport(scroll, base: false), "Foreign pane stole a registry")
        owner.model.activatePane(base: false); owner.model.editingEnabled = true
        try await wait { right.isEditable }
        (right as! MergeLineNavigationProviding).beginUserNavigation(); right.setSelectedRange(NSRange(location: 0, length: 0))
        let view = right as! MergeFindProviding
        try require(view.replaceFindMatches([NSRange(location: 0, length: 4)], with: "edited"), "Native draft edit failed")
        try await TwoPaneEngineVerification.settled(model)
        let draft = model.draftText(base: false), editedGeneration = model.alignmentGeneration
        model.loadOnAppearance()
        try require(model.dirty && !model.busy && model.draftText(base: false) == draft && model.alignmentGeneration == editedGeneration, "Appearance replaced a dirty draft or opened Reload")
        // Explicit Reload still works; the automatic appearance guard is not a
        // blanket load lock. The caller has already authorized discarding draft.
        model.load(discardingDraft: true); try await TwoPaneEngineVerification.settled(model)
        try require(!model.dirty && model.draftText(base: false) == String(decoding: original[1], as: UTF8.self), "Explicit Reload stopped working")
        owner.close(); model.applyViewportNavigation(); model.applyInitialBlockSelection()
        try require(!model.ownsViewport(scroll, base: false) && !view.mergeFindAllowed && !model.busy, "Retired viewport remained actionable")
        try require(try Data(contentsOf: base) == original[0] && Data(contentsOf: mine) == original[1], "Viewport/Reload workflow changed disk bytes")
        print("PASS viewport ownership: detached ready panes retain initial block/inline entry; attached peer/caret navigation, appearance-once/dirty preservation, attached-only history restoration, foreign registry refusal, explicit Reload and retired callbacks; disk bytes unchanged")
    }
}
