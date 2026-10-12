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
        find.modifiedOnly.state = .on; find.count(); try require(find.status.stringValue == "2 match(es).")
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
        model.redo(); try await wait { !model.filtering && model.draftText(base: false).contains("🦎 foo") }
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
        owner.window?.close(); try require(sourceFind.window?.parent == nil && find.window?.parent == nil)
        // Actual three-pane conflict editor, one grouped native undo and no Save.
        let repoRoot = root.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let repository = GitRepository(root: repoRoot, executable: URL(fileURLWithPath: "/usr/bin/git")), file = repoRoot.appendingPathComponent("sample.txt")
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
        let before = conflictModel.result
        resultFind.search.stringValue = "foo"; resultFind.modifiedOnly.state = .off; resultFind.replacement.stringValue = "FOO"; resultFind.replace(all: true)
        try require(conflictModel.result.contains("FOO") && !conflictModel.result.contains("foo"))
        result.undoManager?.undo(); try require(conflictModel.result == before)
        result.undoManager?.redo(); try require(conflictModel.result.contains("FOO"))
        let unchangedWorking = try Data(contentsOf: file), unchangedIndex = try Data(contentsOf: repoRoot.appendingPathComponent(".git/index"))
        try require(unchangedWorking == rawWorking && unchangedIndex == rawIndex)
        conflict.window?.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
        print("Merge Find: actual two/three-pane Find/Count, modified-line restriction, wrap status, readonly/async gates, pane-local ownership, source-gap exclusion, Unicode Replace All, single Undo/Redo and unchanged disk/index passed. All owned windows closed; private preferences only.")
    }
}
