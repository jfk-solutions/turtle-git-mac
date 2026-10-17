import AppKit
import TurtleGitCore

struct MergeWholeSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitWholeSource-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.WholeSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        MergeComparisonOptions.exact.save(to: prefs); MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs"), output = root.appendingPathComponent("result")
        let originals = [(base, "head 🐢\nold\ntail"), (mine, "head 🐢\r\nmine1\r\nmine2\r\ntail"), (theirs, "head 🐢\ntheirs\ntail")]
        for (url, value) in originals { try Data(value.utf8).write(to: url) }
        let owner = TextConflictWindowController(repository: GitRepository(root: root), access: nil, path: "mine", workingMerge: try WorkingTextMerge(base: base, theirs: theirs, mine: mine), preferences: prefs), model = owner.model
        defer { owner.close() }
        owner.window!.alphaValue = 0; owner.window!.orderFront(nil); model.chooseReload = { .discard }; model.load()
        func views() -> [NSTextView] { ThreePaneEngineVerification.textViews(owner.window?.contentView).filter { !$0.isFieldEditor } }
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<2000 {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                if ready() && views().count == 3 && views().compactMap { $0 as? MergeContextMenuProviding }.allSatisfy(\.mergeSourceRowsReady) && model.sourceToolsAllowed { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw Failure(description: "Whole-source native state did not settle")
        }
        try await wait { !model.busy && model.document != nil }
        let result = views().first { $0.isEditable }!, right = views().first { !$0.isEditable && $0.string.contains("mine1") }!, left = views().first { !$0.isEditable && $0.string.contains("theirs") }!
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        func whole(_ view: NSTextView) throws -> NSMenuItem {
            let menu = (view as! MergeContextMenuProviding).mergeContextMenu(defaults: prefs, pasteboard: board)
            guard let item = menu.item(withTitle: "Use this whole file"), item.isEnabled, item.image != nil else { throw Failure(description: "Whole-source action disabled for an unmapped result") }
            return item
        }
        func invoke(_ item: NSMenuItem) throws { try require(NSApp.sendAction(item.action!, to: item.target, from: item), "Whole-source action dispatch failed") }
        // The native whole-buffer editor entry is also used by patch/replacement
        // workflows. Its free result no longer claims an aligned source map.
        model.replaceEntireResult?("scratch 🦎\ncustom result\n")
        try await wait { model.alignedResultProjection == nil && model.result.hasPrefix("scratch") && result.string == model.result }
        let stale = try whole(right)
        result.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))
        try await wait { model.result.hasPrefix("typed ") }
        let held = model.resultPresentation; try invoke(stale)
        try require(model.resultPresentation == held, "Stale whole-source action overwrote typing")
        let formatStale = try whole(right)
        model.resultLineEnding = .cr
        try invoke(formatStale)
        try require(model.resultPresentation == held, "Whole-source action used an obsolete selected ending")
        model.changeLineEnding(.crlf)
        try await wait { model.resultLineEnding == .crlf && result.string == model.result }
        let scratch = model.resultPresentation, sourceCount = model.sourceComparison!.rows.count
        for (pane, expected) in [(right, "head 🐢\r\nmine1\r\nmine2\r\ntail"), (left, "head 🐢\r\ntheirs\r\ntail")] {
            let item = try whole(pane)
            model.confirmingQuit = true; try invoke(item); try require(model.resultPresentation == scratch, "Quit gate accepted whole-source replacement"); model.confirmingQuit = false
            try invoke(item)
            try await wait { model.result == expected && model.alignedResultProjection != nil && result.string == model.resultDisplayText }
            let copied = model.resultPresentation
            try require(model.blocks.isEmpty && model.canUndo && model.dirty, "Whole-source choice lost conflict/history state")
            try require(model.alignedResultStates.contains(.resolved) && !model.alignedResultStates.contains(where: \.isConflict), "Whole-source result lost resolved row colors")
            try require(!MergeLineEndings.hasFinalEnding(model.result), "Whole-source action added a final ending")
            model.undo(); try await wait { model.resultPresentation == scratch && model.alignedResultProjection == nil && model.sourceComparison?.rows.count == sourceCount }
            model.redo(); try await wait { model.resultPresentation == copied && model.alignedResultProjection != nil }
            model.undo(); try await wait { model.resultPresentation == scratch && model.alignedResultProjection == nil }
        }
        try invoke(whole(left)); try await wait { model.result == "head 🐢\r\ntheirs\r\ntail" && model.alignedResultProjection != nil }
        model.chooseStandaloneOutput = { _, _ in output }; model.changeEncoding(.utf8); model.save(markResolved: false)
        try await wait { !model.busy }
        try require(model.error == nil && (try Data(contentsOf: output)) == Data("head 🐢\r\ntheirs\r\ntail".utf8), "Whole-source Save changed EOL/EOF or wrote the wrong output")
        let oldCommand = try whole(right)
        model.load(); try await wait { !model.busy && !model.preparing }
        let loaded = model.resultPresentation; try invoke(oldCommand)
        try require(model.resultPresentation == loaded, "Reload revived a whole-source command")
        let closedCommand = try whole(right)
        owner.close(); try invoke(closedCommand)
        try require(model.resultPresentation == loaded, "Closed owner accepted whole-source replacement")
        for (url, text) in originals { try require(try Data(contentsOf: url) == Data(text.utf8), "Whole-source workflow rewrote a source input") }
        print("PASS: whole Mine/Theirs menus restore freely edited result mapping; original icons, selected CRLF and missing EOF, row colors, one-step Undo/Redo, stale typing/format/reload/Quit/closed guards, exact Save and untouched sources; owned window closed")
    }
}
