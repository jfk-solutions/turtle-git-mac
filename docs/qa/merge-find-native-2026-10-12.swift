import AppKit
import TurtleGitCore

private struct MergeFindVerificationFailure: Error, CustomStringConvertible { let description: String }
struct MergeFindNativeVerification {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, line: Int = #line) throws {
        if !condition() { throw MergeFindVerificationFailure(description: "Merge Find assertion failed at line \(line)") }
    }
    @MainActor static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw MergeFindVerificationFailure(description: "Merge Find native transition did not settle")
    }
    @MainActor static func capture(_ window: NSWindow, in directory: URL) throws {
        guard let view = window.contentView else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: name); view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { preconditionFailure("Find content capture unavailable") }
            window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("Find PNG unavailable") }
            try png.write(to: directory.appendingPathComponent("merge-find-" + suffix + ".png"))
        }
    }
    @MainActor static func verifyPaint(_ view: NSTextView, count: Int) throws {
        guard let target = view as? MergeFindProviding, let layout = view.layoutManager, let storage = view.textStorage else { throw MergeFindVerificationFailure(description: "Missing native Find host") }
        try require(target.mergeFindHighlights.paintRanges.count == count)
        for range in target.mergeFindHighlights.paintRanges {
            try require(NSMaxRange(range) <= (view.string as NSString).length)
            try require((view.string as NSString).substring(with: range).compare(target.mergeFindHighlights.query, options: target.mergeFindHighlights.options.matchCase ? [] : .caseInsensitive) == .orderedSame)
            try require(layout.temporaryAttribute(.mergeFindMatch, atCharacterIndex: range.location, effectiveRange: nil) as? Bool == true)
            try require(storage.attribute(.mergeFindMatch, at: range.location, effectiveRange: nil) == nil)
            let original = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as! NSColor
            let highlighted = layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil) as! NSColor
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    precondition(highlighted.usingColorSpace(.sRGB) == MergeFindHighlights.intense(original).usingColorSpace(.sRGB))
                }
            }
        }
    }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergeFind-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.MergeFind.Native." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt")
        let originalBase = Data("same foo\nremoved row\nfoo old\n".utf8), originalMine = Data("same foo\nfoo new foo\n".utf8)
        try originalBase.write(to: base); try originalMine.write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
        defer { owner.window?.close() }
        let model = owner.model; model.comparisonDefaults = defaults; model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); model.load()
        try await wait { !model.busy && !model.filtering && model.alignment != nil }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { descendants(owner.window?.contentView).filter { $0 is MergeFindProviding }.count == 2 }
        let views = descendants(owner.window?.contentView).compactMap { $0 as? NSTextView }.filter { $0 is MergeFindProviding }
        let destination = views.first { $0.string.contains("new") }!, target = destination as! MergeFindProviding
        model.activatePane(base: false); model.editingEnabled = false
        try await wait { !destination.isEditable }
        let find = MergeFindWindowController(text: destination, defaults: defaults); target.mergeFindController = find
        defer { find.close() }
        find.present(show: false)
        try require(find.window?.parent === owner.window && !find.replacement.isEnabled)
        find.search.stringValue = " foo "; find.count(); try require(defaults.stringArray(forKey: "TurtleGitMerge.History.Find.Search")?.first == " foo ")
        find.search.stringValue = "foo"; find.count(); try require(find.status.stringValue == "3 match(es).")
        try verifyPaint(destination, count: 3); try require(!model.canUndo)
        for (input, expected) in [(NSColor.white, 225), (.black, 30)] {
            let color = MergeFindHighlights.intense(input).usingColorSpace(.sRGB)!
            try require(Int((color.redComponent * 255).rounded()) == expected)
        }
        find.modifiedOnly.state = .on; find.count(); try require(find.status.stringValue == "2 match(es).")
        try verifyPaint(destination, count: 3); try require(target.mergeFindHighlights.ranges.count == 2)
        try require(destination.layoutManager?.temporaryAttribute(.mergeFindMatch, atCharacterIndex: 5, effectiveRange: nil) as? Bool == true)
        destination.setSelectedRange(NSRange(location: 0, length: 0)); find.find()
        try require((destination.string as NSString).substring(with: destination.selectedRange()) == "foo")
        find.find(upwards: true); try require(find.status.stringValue.contains("Top reached"))
        model.activatePane(base: false); model.editingEnabled = true
        try await wait { destination.isEditable }
        find.updateGates(); try require(find.replaceAllButton.isEnabled && find.replacement.isEnabled)
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_FIND_CAPTURE"], let window = find.window {
            find.count(); try capture(window, in: URL(fileURLWithPath: path))
        }
        find.replacement.stringValue = "🦎 foo"; find.replace(all: true)
        try await wait { !model.filtering && model.draftText(base: false).contains("🦎 foo new 🦎 foo") }
        try require(model.draftText(base: false) == "same foo\n🦎 foo new 🦎 foo\n")
        try require(!model.draftText(base: false).contains("removed row") && model.canUndo)
        model.undo(); try await wait { !model.filtering && model.draftText(base: false) == String(decoding: originalMine, as: UTF8.self) }
        try await wait { (destination as! MergeFindProviding).mergeFindHighlights.ranges == MergeFind.matches("foo", in: target.mergeFindLines, options: target.mergeFindHighlights.options) }
        try verifyPaint(destination, count: 3)
        model.redo(); try await wait { !model.filtering && model.draftText(base: false).contains("🦎 foo") }
        try await wait { target.mergeFindHighlights.ranges == MergeFind.matches("foo", in: target.mergeFindLines, options: target.mergeFindHighlights.options) }
        try verifyPaint(destination, count: 3)
        let unchangedBase = try Data(contentsOf: base), unchangedMine = try Data(contentsOf: mine)
        try require(unchangedBase == originalBase && unchangedMine == originalMine)
        model.busy = true; find.updateGates(); try require(!find.findButton.isEnabled && !find.replaceButton.isEnabled)
        let held = model.draftText(base: false); find.replace(all: true); try require(model.draftText(base: false) == held); model.busy = false
        find.close(); try require(find.window?.parent == nil)
        try require(defaults.stringArray(forKey: "TurtleGitMerge.History.Find.Search")?.first == "foo")
        // Source panes keep their own dialog and readonly replacement gate.
        let source = views.first { $0 !== destination }!, sourceFind = MergeFindWindowController(text: source, defaults: defaults)
        (source as! MergeFindProviding).mergeFindController = sourceFind; sourceFind.search.stringValue = "removed"
        sourceFind.modifiedOnly.state = .off; sourceFind.count(); try require(sourceFind.status.stringValue == "1 match(es).")
        sourceFind.present(show: false); try require(!sourceFind.replaceButton.isEnabled)
        try verifyPaint(source, count: 1); try verifyPaint(destination, count: 3)
        let persistedBeforeSelection = MergeFindOptions.load(from: defaults)
        let firstMatch = MergeFind.matches("foo", in: target.mergeFindLines, options: MergeFindOptions()).first!
        destination.setSelectedRange(firstMatch)
        MergeFindInterface.selection(upwards: false, in: destination)
        try require(destination.selectedRange().location > firstMatch.location)
        try require(!target.mergeFindHighlights.options.modifiedOnly && !target.mergeFindHighlights.options.matchCase && !target.mergeFindHighlights.options.wholeWord)
        try verifyPaint(destination, count: 3)
        owner.window?.makeFirstResponder(destination)
        let selected = destination.selectedRange()
        let f3 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 99)!
        try require(owner.window!.performKeyEquivalent(with: f3) && destination.selectedRange() != selected)
        let previous = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .shift], timestamp: 0, windowNumber: owner.window!.windowNumber, context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5)!
        try require(owner.window!.performKeyEquivalent(with: previous) && destination.selectedRange() == selected)
        model.busy = true
        let heldSelection = destination.selectedRange(), heldSearch = target.mergeFindHighlights.query
        destination.turtleFindSelectionNext(nil)
        try require(destination.selectedRange() == heldSelection && target.mergeFindHighlights.query == heldSearch)
        model.busy = false
        destination.setSelectedRange(NSRange(location: 0, length: 0)); MergeFindInterface.selection(upwards: false, in: destination)
        try verifyPaint(destination, count: 0)
        MergeFindInterface.perform(.nextMatch, in: destination); try require(destination.selectedRange() == NSRange(location: 0, length: 0))
        let savedOptions = MergeFindOptions.load(from: defaults); try require(savedOptions == persistedBeforeSelection)
        for icons in [true, false] {
            defaults.set(icons, forKey: "ShowAppContextMenuIcons")
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            let menu = (destination as! ComparisonContextMenuProviding).comparisonContextMenu(defaults: defaults, pasteboard: board)
            let item = menu.items.first { $0.action == #selector(NSTextView.turtleFindSelectionNext(_:)) }!
            try require(item.isEnabled && item.target === destination && (item.image != nil) == icons)
            destination.setSelectedRange(firstMatch)
            try require(NSApp.sendAction(item.action!, to: item.target, from: item))
            try verifyPaint(destination, count: 3)
        }
        find.close(); try verifyPaint(destination, count: 3)
        owner.window?.close(); try require(sourceFind.window?.parent == nil && find.window?.parent == nil)
        let heldQuery = target.mergeFindHighlights.query
        destination.turtleClearFindHighlights(nil); try require(!target.mergeFindAllowed && target.mergeFindHighlights.query == heldQuery)
        // Actual three-pane conflict editor, one grouped native undo and no Save.
        let repoRoot = root.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let repository = GitRepository(root: repoRoot, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_FIND_TEST_GIT"] ?? "/usr/bin/git")), file = repoRoot.appendingPathComponent("sample.txt")
        _ = try await repository.run(["init", "-b", "main"])
        for pair in [("user.name", "Find QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", pair.0, pair.1]) }
        try Data("same foo\nbase\n".utf8).write(to: file); try await repository.stage(["sample.txt"]); _ = try await repository.commit(message: "base")
        _ = try await repository.run(["checkout", "-b", "side"]); try Data("same foo\ntheirs foo\n".utf8).write(to: file); _ = try await repository.run(["commit", "-am", "theirs"])
        _ = try await repository.run(["checkout", "main"]); try Data("same foo\nmine foo\n".utf8).write(to: file); _ = try await repository.run(["commit", "-am", "mine"])
        _ = try await repository.run(["merge", "side"], successfulExitCodes: 0...1)
        let rawIndex = try Data(contentsOf: repoRoot.appendingPathComponent(".git/index")), rawWorking = try Data(contentsOf: file)
        let conflict = TextConflictWindowController(repository: repository, access: nil, path: "sample.txt"), conflictModel = conflict.model
        defer { conflict.window?.close() }
        conflictModel.comparisonDefaults = defaults; conflictModel.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); conflictModel.load()
        try await wait { !conflictModel.busy && conflictModel.document != nil }
        conflict.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { descendants(conflict.window?.contentView).contains { ($0 as? NSTextView)?.isEditable == true } }
        let result = descendants(conflict.window?.contentView).compactMap { $0 as? NSTextView }.first { $0.isEditable }!
        let resultFind = MergeFindWindowController(text: result, defaults: defaults); (result as! MergeFindProviding).mergeFindController = resultFind
        defer { resultFind.close() }
        let conflictViews = descendants(conflict.window?.contentView).compactMap { $0 as? NSTextView }.filter { $0 is MergeFindProviding }
        for source in conflictViews where source !== result {
            let controller = MergeFindWindowController(text: source, defaults: defaults)
            (source as! MergeFindProviding).mergeFindController = controller
            controller.search.stringValue = "foo"; controller.modifiedOnly.state = .off; controller.count()
            try verifyPaint(source, count: 2); controller.close()
        }
        let before = conflictModel.result
        resultFind.search.stringValue = "foo"; resultFind.matchCase.state = .on; resultFind.modifiedOnly.state = .off; resultFind.replacement.stringValue = "FOO"; resultFind.replace(all: true)
        try require(conflictModel.result.contains("FOO") && !conflictModel.result.contains("foo"))
        try await wait { (result as! MergeFindProviding).mergeFindHighlights.ranges.isEmpty }
        result.undoManager?.undo(); try require(conflictModel.result == before)
        try await wait { (result as! MergeFindProviding).mergeFindHighlights.ranges.count == MergeFind.matches("foo", in: (result as! MergeFindProviding).mergeFindLines, options: (result as! MergeFindProviding).mergeFindHighlights.options).count }
        try verifyPaint(result, count: 3)
        result.undoManager?.redo(); try require(conflictModel.result.contains("FOO"))
        let unchangedWorking = try Data(contentsOf: file), unchangedIndex = try Data(contentsOf: repoRoot.appendingPathComponent(".git/index"))
        try require(unchangedWorking == rawWorking && unchangedIndex == rawIndex)
        conflict.window?.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
        print("Merge Find: actual two/three-pane Find/Count, modified-line restriction, wrap status, readonly/async gates, pane-local ownership, source-gap exclusion, Unicode Replace All, single Undo/Redo and unchanged disk/index passed. All owned windows closed; private preferences only.")
    }
}
