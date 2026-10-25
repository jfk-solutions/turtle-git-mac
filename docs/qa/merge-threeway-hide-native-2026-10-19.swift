// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Links the actual Debug app objects. Windows stay transparent and offscreen;
/// no system pasteboard, repository or user preference domain is mutated.
@main struct MergeThreewayHideVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct CellSnapshot: Equatable {
        let bytes: Data, number: Int?, state: MergeSourceState, hidden: Bool
        init(_ cell: MergeSourceCell) { bytes = Data(cell.text.utf8); number = cell.lineNumber; state = cell.state; hidden = cell.hiddenByComparison }
    }
    static func snapshot(_ rows: [MergeSourceRow]) -> [CellSnapshot] { rows.flatMap { [CellSnapshot($0.mine), CellSnapshot($0.theirs)] } }
    @MainActor final class Ownership {
        var windows: [TextConflictWindowController] = []
        func close() { for owner in windows { owner.model.retire(); owner.close() } }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, diagnostic: () -> String = { "" }, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Three-way HideState wait at line \(line); \(diagnostic())")
    }
    @MainActor static func editors(_ view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editors($0) }
    }
    @MainActor static func panes(_ owner: TextConflictWindowController) -> [NSTextView] {
        editors(owner.window?.contentView).filter { $0 is MergeContextMenuProviding }
    }
    @MainActor static func settled(_ owner: TextConflictWindowController) async throws {
        try await wait {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            let model = owner.model, views = panes(owner)
            return !model.busy && !model.preparing && model.document != nil && views.count == 3 && views.allSatisfy { ($0 as? MergeContextMenuProviding)?.mergeSourceRowsReady == true }
        }
        try require(owner.model.error == nil, "Three-way load: " + (owner.model.error ?? "unknown error"))
    }
    @MainActor static func offscreen(_ owner: TextConflictWindowController, ownership: Ownership) {
        ownership.windows.append(owner)
        owner.window!.alphaValue = 0; owner.window!.setFrameOrigin(NSPoint(x: -20000, y: -20000)); owner.window!.orderFront(nil)
    }
    @MainActor static func rgb(_ color: NSColor, _ appearance: NSAppearance) -> UInt32? {
        var result: UInt32?
        appearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) { result = UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded()) }
        }
        return result
    }
    @MainActor static func assertPaint(_ owner: TextConflictWindowController, text: String, expected: (Bool) -> UInt32, resultOnly: Bool = false) async throws {
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let appearance = NSAppearance(named: name)!
            owner.window!.appearance = appearance; owner.model.objectWillChange.send()
            try await wait {
                let views = panes(owner).filter { !resultOnly || $0.isEditable }
                return !views.isEmpty && views.allSatisfy { view in
                    let range = (view.string as NSString).range(of: text)
                    guard range.location != NSNotFound, let color = view.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor else { return false }
                    return rgb(color, appearance) == expected(dark)
                }
            }
        }
    }
    @MainActor static func commonMatrix(root: URL, git: URL, prefs: UserDefaults, ownership: Ownership) async throws {
        let cases: [(String, String, String, MergeComparisonOptions, Bool)] = [
            ("whitespace", "target X Y\n", "targetXY\n", .init(whitespace: .ignoreAll, ignoreEndings: false), false),
            ("endings", "target eol\n", "target eol\r\n", .init(ignoreEndings: true), false),
            ("case", "target VALUE\n", "target value\n", .init(ignoreCase: true, ignoreEndings: false), false),
            ("comments", "target // base\n", "target // mine\n", .init(ignoreEndings: false, ignoreComments: true), false),
            ("regex", "target version100\n", "target version200\n", .exact, true)
        ]
        let filter = MergeRegexFilter(name: "Private versions", expression: "[0-9]+", replacement: "")
        try MergeRegexFilters.save([filter], defaults: prefs)
        var palette = MergeColorPreferences()
        palette.light[.normal] = .init(0x112233, 0x345678); palette.dark[.normal] = .init(0xabcdef, 0x234567)
        try palette.save(to: prefs)
        for (name, old, new, options, useRegex) in cases {
            let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var baseLines = (0..<70).map { "line \($0) 雪🦎 unchanged\n" }; baseLines[25] = old
            var mineLines = baseLines; mineLines[25] = new
            var theirLines = baseLines; theirLines[50] = "theirs visible change\n"
            let urls = ["base.cpp", "mine.cpp", "theirs.cpp"].map { folder.appendingPathComponent($0) }
            let originals = [try ComparisonTextEncoding.utf16LEBOM.encode(baseLines.joined()), try ComparisonTextEncoding.utf8BOM.encode(mineLines.joined()), Data(theirLines.joined().utf8)]
            for (url, bytes) in zip(urls, originals) { try bytes.write(to: url) }
            let profile = folder.appendingPathComponent("ignorecomments.txt"); try Data("cpp=//,/*,*/\n".utf8).write(to: profile)
            options.save(to: prefs); MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
            MergeFoldingPreferences(collapsed: false).saveCollapsed(to: prefs)
            let owner = TextConflictWindowController(repository: GitRepository(root: folder, executable: git), access: nil, path: "mine.cpp", workingMerge: try WorkingTextMerge(base: urls[0], theirs: urls[2], mine: urls[1]), preferences: prefs, deferInitialLoad: true), model = owner.model
            offscreen(owner, ownership: ownership); model.commentProfileURL = profile; model.regexDefaults = prefs; model.refreshRegexFilters(); model.beginTransferredDocument()
            try await settled(owner)
            if useRegex {
                // This standalone result already contains a Theirs-only change.
                // Exercise the owned reload decision with an injected discard.
                model.chooseReload = { .discard }
                model.selectRegexFilter(filter.name)
                try await wait { !model.busy && !model.preparing && model.regexFilterName == filter.name }
                try await settled(owner)
            }
            model.setInlineDiff(false); try await settled(owner)
            guard let comparison = model.sourceComparison, let row = comparison.rows.firstIndex(where: { $0.mine.displayText.hasPrefix("target") }), let projection = model.alignedResultProjection else { throw Failure(description: name + ": missing original aligned target") }
            try require(comparison.rows[row].mine.state == .normal && comparison.rows[row].theirs.state == .normal && comparison.rows[row].mine.hiddenByComparison && comparison.rows[row].theirs.hiddenByComparison, name + ": three-way common sources did not retain Normal + Hidden")
            try require(projection.cells[row].state == .normal && projection.cells[row].hiddenByComparison, name + ": result inherited filtered color or discarded HideState")
            try require(comparison.rows[row].mine.text.utf8.elementsEqual(new.utf8) && comparison.rows[row].theirs.text.utf8.elementsEqual(old.utf8), name + ": source originals were normalized")
            try await assertPaint(owner, text: "target", expected: { palette.colors(.normal, dark: $0).background })
            let resultBefore = model.result, sourceBefore = snapshot(comparison.rows), flagsBefore = model.resultPresentation.hiddenByComparison()
            let dirtyBefore = model.dirty, undoBefore = model.canUndo
            model.setCollapsed(true)
            try await wait { model.folding.folding.visibility.indices.contains(row) && model.folding.folding.visibility[row] == .hidden && model.resultFolding.folding.visibility == model.folding.folding.visibility }
            // The controller publishes its map before SwiftUI commits all three
            // attributed snapshots. Await the actual native presentation too.
            try await wait {
                let views = panes(owner)
                return views.count == 3 && views.allSatisfy { view in
                    let target = (view.string as NSString).range(of: "target")
                    return target.location != NSNotFound && view.textStorage?.attribute(.mergeFoldHidden, at: target.location, effectiveRange: nil) != nil
                }
            }
            for view in panes(owner) {
                let target = (view.string as NSString).range(of: "target")
                try require(target.location != NSNotFound && view.textStorage?.attribute(.mergeFoldHidden, at: target.location, effectiveRange: nil) != nil, name + ": native pane did not hide common comparison-key row")
            }
            guard let changed = comparison.rows.firstIndex(where: { $0.theirs.displayText.hasPrefix("theirs visible") }) else { throw Failure(description: name + ": missing visible result change") }
            try require(model.folding.folding.visibility[changed] == .shown && model.resultFolding.folding.visibility[changed] == .shown, name + ": a source Normal flag hid an actual result change")
            try require(model.result == resultBefore && model.sourceComparison.map({ snapshot($0.rows) }) == sourceBefore && model.resultPresentation.hiddenByComparison() == flagsBefore && model.dirty == dirtyBefore && model.canUndo == undoBefore, name + ": collapse mutated source records or history; dirty=\(dirtyBefore)->\(model.dirty), undo=\(undoBefore)->\(model.canUndo)")
            model.setCollapsed(false); try await settled(owner)
            if name == "whitespace" {
                guard let result = panes(owner).first(where: \.isEditable) else { throw Failure(description: "Missing editable result") }
                let selected = (result.string as NSString).range(of: "target")
                owner.window?.makeFirstResponder(result)
                result.setSelectedRange(selected)
                let pasteboard = NSPasteboard(name: .init("TurtleGit.HideState." + UUID().uuidString)); defer { pasteboard.releaseGlobally() }
                let context = (result as! MergeContextMenuProviding).mergeContextMenu(defaults: prefs, pasteboard: pasteboard)
                guard let copy = context.items.first(where: { $0.action == NSSelectorFromString("copySelection:") }), let action = copy.action else { throw Failure(description: "Missing production Copy command") }
                _ = NSApp.sendAction(action, to: copy.target, from: copy)
                try require(pasteboard.string(forType: .string) == "target", "Private Copy did not use actual selected original text")
                result.insertText("edited", replacementRange: selected); try await settled(owner)
                try await wait { model.canUndo && model.result.contains("edited") }
                guard let editRow = model.alignedResultProjection?.cells.firstIndex(where: { $0.displayText.hasPrefix("edited") }) else { throw Failure(description: "Native edit did not produce aligned edited row") }
                try require(model.alignedResultProjection!.cells[editRow].state == .edited && !model.alignedResultProjection!.cells[editRow].hiddenByComparison, "Manual edit retained an inherited Hidden flag")
                model.undo(); try await settled(owner)
                try require(model.result == resultBefore && model.resultPresentation.hiddenByComparison() == flagsBefore && model.dirty == dirtyBefore, "Undo discarded original HideState/common bytes")
                model.redo(); try await settled(owner)
                try require(model.alignedResultProjection!.cells.contains { $0.displayText.hasPrefix("edited") && !$0.hiddenByComparison } && model.dirty, "Redo discarded edited Shown metadata")
                model.undo(); try await settled(owner)
            }
            for (url, bytes) in zip(urls, originals) { try require(try Data(contentsOf: url) == bytes, name + ": read/fold/edit history rewrote source bytes or encoding") }
            model.retire(); owner.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
            print("PASS: three-way HideState \(name), native colors in both appearances, all-pane collapse, raw records, edited metadata and exact source bytes")
        }
    }
    @MainActor static func ignored(root: URL, git: URL, prefs: UserDefaults, ownership: Ownership) async throws {
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Private HideState QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let path = "ignored 雪🦎.cpp", file = root.appendingPathComponent(path)
        var baseLines = (0..<70).map { "row \($0) unchanged 雪🦎\n" }; baseLines[25] = "target X Y\n"
        var mineLines = baseLines; mineLines[25] = "targetXY\n"
        var theirLines = baseLines; theirLines[25] = "target X  Y\n"
        try Data(baseLines.joined().utf8).write(to: file); try Data("other base\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        try await repo.stage([path, "other.txt"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "side"]); try Data(theirLines.joined().utf8).write(to: file); try await repo.stage([path]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"]); try Data(mineLines.joined().utf8).write(to: file); try await repo.stage([path]); _ = try await repo.commit(message: "mine")
        _ = try await repo.run(["merge", "--no-edit", "side"], successfulExitCodes: 0...1)
        try Data("unrelated staged\n".utf8).write(to: root.appendingPathComponent("other.txt")); try await repo.stage(["other.txt"]); try Data("unrelated working\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        let original = try Data(contentsOf: file), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        MergeComparisonOptions(whitespace: .ignoreAll).save(to: prefs); MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs); MergeFoldingPreferences(collapsed: false).saveCollapsed(to: prefs)
        var palette = MergeColorPreferences(); palette.light[.conflicted] = .init(0x112233, 0x456789); palette.dark[.conflicted] = .init(0xabcdef, 0x234567); try palette.save(to: prefs)
        let owner = TextConflictWindowController(repository: repo, access: nil, path: path, preferences: prefs, deferInitialLoad: true), model = owner.model
        offscreen(owner, ownership: ownership); model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); model.regexDefaults = prefs; model.refreshRegexFilters(); model.beginTransferredDocument(); try await settled(owner); model.setInlineDiff(false)
        guard let block = model.blocks.first, block.isIgnored, let comparison = model.sourceComparison, let row = comparison.rows.firstIndex(where: { $0.mine.displayText.hasPrefix("target") }) else { throw Failure(description: "Ignored conflict missing") }
        try require(model.blocks.count == 1 && model.resultStates.contains(.conflictedIgnored) && model.alignedResultProjection!.cells[row].hiddenByComparison && comparison.rows[row].mine.hiddenByComparison && comparison.rows[row].theirs.hiddenByComparison, "Ignored conflict promotion discarded source/result HideState")
        try await assertPaint(owner, text: "target", expected: { palette.colors(.conflicted, dark: $0).background }, resultOnly: true)
        let hiddenBefore = model.resultPresentation.hiddenByComparison()
        model.setCollapsed(true); try await wait { model.folding.folding.visibility[row] == .hidden && model.resultFolding.folding.visibility == model.folding.folding.visibility }
        var warning = "", completion: Bool?, owned = false
        model.confirmUnresolvedSave = { message in warning = message; owned = model.busy && MergeRegexOperations.activeRequests > 0; return false }
        model.save(markResolved: false) { completion = $0 }; try await wait { completion != nil && !model.busy }
        try require(completion == false && owned && warning.contains("ignored by comparison options"), "Hidden ignored conflict bypassed unresolved Save warning")
        var marked: Bool?; model.save(markResolved: true) { marked = $0 }
        try require(marked == false, "Hidden ignored conflict bypassed Mark resolved gate")
        let expectedBlock = model.alignedResultProjection?.displayRange(serializedRange: block.range) ?? block.range
        func selectedBlock() -> NSRange? { (panes(owner).first(where: \.isEditable) as? MergeBlockSelecting)?.mergeSelectedBlockRange }
        model.continueResolving()
        try await wait(diagnostic: { "canChoose=\(model.canChooseConflict), source=\(model.folding.folding.visibility[row]), result=\(model.resultFolding.folding.visibility[row]), block=\(String(describing:selectedBlock())), expected=\(expectedBlock)" }) {
            model.canChooseConflict && model.folding.folding.visibility[row] == .shown && model.resultFolding.folding.visibility[row] == .shown && selectedBlock() == expectedBlock
        }
        // Source block selection is distinct from the zero-length text caret.
        try require(selectedBlock() == expectedBlock, "Ignored navigation did not select exact native block")
        model.choose(.mine); try await settled(owner); try await wait { model.blocks.isEmpty && model.canUndo }
        try require(model.result == mineLines.joined() && model.alignedResultProjection!.cells[row].hiddenByComparison, "Source resolution did not copy retained Hidden metadata")
        model.undo(); try await settled(owner)
        try require(model.blocks.first?.isIgnored == true && model.resultPresentation.hiddenByComparison() == hiddenBefore && !model.dirty, "Ignored Undo did not restore source flags and original state")
        model.redo(); try await settled(owner)
        try require(model.blocks.isEmpty && model.alignedResultProjection!.cells[row].hiddenByComparison && model.dirty, "Ignored Redo lost copied Hidden flag or source resolution")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, stagedOther = try await repo.run(["show", ":other.txt"]).text
        try require(try Data(contentsOf: file) == original && Data(contentsOf: root.appendingPathComponent(".git/index")) == index && afterHead == head, "Cancelled Save or unsaved resolution changed conflict file/index/HEAD")
        try require(try Data(contentsOf: root.appendingPathComponent("other.txt")) == Data("unrelated working\n".utf8) && stagedOther == "unrelated staged\n", "Ignored workflow changed unrelated staged/working bytes")
        model.retire(); owner.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
        print("PASS: ignored conflict retains Hidden independently of conflict color, synchronized collapse/navigation reveal, Save warning/resolve gate, source-copy Undo/Redo flags and exact index/HEAD/bytes")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), name = "TurtleGit.ThreewayHide." + UUID().uuidString, prefs = UserDefaults(suiteName: name)!, ownership = Ownership()
        defer { prefs.removePersistentDomain(forName: name) }
        var failure: Error?
        do {
            switch CommandLine.arguments[3] {
            case "options": try await commonMatrix(root: root, git: git, prefs: prefs, ownership: ownership)
            case "ignored": try await ignored(root: root, git: git, prefs: prefs, ownership: ownership)
            default: throw Failure(description: "Unknown three-way HideState case")
            }
        } catch { failure = error }
        ownership.close()
        try await wait { MergeRegexOperations.activeRequests == 0 && MergeSourceExport.activeExports == 0 && MergeExternalReloadCoordinator.activeRequests == 0 && ownership.windows.allSatisfy { $0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet == nil } }
        if let failure { throw failure }
        print("PASS: three-way HideState receiver drained helpers and closed every owned window")
    }
}
