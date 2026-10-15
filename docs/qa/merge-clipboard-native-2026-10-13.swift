import AppKit
import TurtleGitCore

@main struct MergeClipboardVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Clipboard native UI did not settle")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func invoke(_ item: NSMenuItem) throws {
        guard item.isEnabled, let action = item.action else { throw Failure(description: "Disabled/missing " + item.title) }
        try require(NSApp.sendAction(action, to: item.target, from: item), "Action did not dispatch: " + item.title + " target=" + String(describing: item.target))
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Merge clipboard failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.MergeClipboard.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(true, forKey: "TurtleGitMerge.UseUTF8")
        prefs.set(false, forKey: "TurtleGitMerge.OnePane")
        let board = NSPasteboard(name: .init(suite)); defer { board.releaseGlobally() }
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Clipboard QA"), ("user.email", "clipboard@example.invalid"), ("core.hooksPath", "/dev/null"), ("commit.gpgsign", "false")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("conflict.txt")
        try Data("head\nold\ntail\n".utf8).write(to: file); try await repo.stage(["conflict.txt"]); _ = try await repo.commit(message: "Base")
        _ = try await repo.run(["switch", "-c", "side"])
        try Data("head\ntheirs 雪\ntail\n".utf8).write(to: file); try await repo.stage(["conflict.txt"]); _ = try await repo.commit(message: "Theirs")
        _ = try await repo.run(["switch", "main"])
        try Data("head\nmine 🦎\ntail\n".utf8).write(to: file); try await repo.stage(["conflict.txt"]); _ = try await repo.commit(message: "Mine")
        _ = try await repo.run(["merge", "--no-ff", "side"], successfulExitCodes: 0...1)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: file)
        let owner = TextConflictWindowController(repository: repo, access: nil, path: "conflict.txt", preferences: prefs)
        defer { owner.close() }
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        do { try await wait {
            owner.window!.contentView!.layoutSubtreeIfNeeded()
            return owner.model.document != nil && !owner.model.busy && descendants(owner.window!.contentView!).compactMap { $0 as? NSTextView }.filter { $0 is MergeContextMenuProviding }.count == 3
        } } catch {
            throw Failure(description: "Three-pane load: busy=\(owner.model.busy), document=\(owner.model.document != nil), error=\(owner.model.error ?? "none"), views=\(descendants(owner.window!.contentView!).compactMap { $0 as? NSTextView }.count)")
        }
        print("Three-pane loaded:", owner.model.busy, owner.model.error ?? "no error")
        let views = descendants(owner.window!.contentView!).compactMap { $0 as? NSTextView }.filter { $0 is MergeContextMenuProviding }
        try require(views.count == 3, "Three merge panes missing")
        for view in views where !view.isEditable {
            let protocolView = view as! MergeContextMenuProviding
            let needle = view.string.contains("mine 🦎") ? "mine 🦎" : "theirs 雪"
            let location = (view.string as NSString).range(of: needle).location
            try require(location != NSNotFound, "Source needle missing")
            view.setSelectedRange(NSRange(location: location, length: 0))
            (view as! MergeBlockSelecting).selectContextBlock(at:location)
            try require(owner.window!.firstResponder === view,"Source context retained another pane's focus")
            let menu = protocolView.mergeContextMenu(defaults: prefs, pasteboard: board)
            let copy = menu.items.first { $0.title == "Copy" }!
            try invoke(copy)
            try require(board.string(forType: .string)?.contains(needle) == true, "Block-only source Copy omitted changed text")
            try require(!menu.items.contains { $0.title == "Cut" || $0.title == "Paste" }, "Read-only source offers mutation")
            view.setSelectedRange(NSRange(location: location, length: (needle as NSString).length))
            try invoke(protocolView.mergeContextMenu(defaults: prefs, pasteboard: board).items.first { $0.title == "Copy" }!)
            try require(board.string(forType: .string) == needle, "Selected source Copy differs")
        }
        let merged = views.first { $0.isEditable }!, mergedProtocol = merged as! MergeContextMenuProviding
        let original = owner.model.result
        let range = (merged.string as NSString).range(of: "mine 🦎")
        merged.setSelectedRange(range)
        let cut = mergedProtocol.mergeContextMenu(defaults: prefs, pasteboard: board).items.first { $0.title == "Cut" }!
        try invoke(cut); try await wait { owner.model.result != original }
        try require(board.string(forType: .string) == "mine 🦎", "Cut used a different pasteboard")
        merged.undoManager!.undo(); try await wait { owner.model.result == original }
        merged.setSelectedRange(NSRange(location: 0, length: 0)); board.clearContents(); board.setString("insert\r\n", forType: .string)
        let paste = mergedProtocol.mergeContextMenu(defaults: prefs, pasteboard: board).items.first { $0.title == "Paste" }!
        owner.model.busy = true
        NSApp.sendAction(paste.action!, to: paste.target, from: paste)
        try require(owner.model.result == original, "Stale Paste mutated busy editor")
        owner.model.busy = false
        try await wait { merged.isEditable }
        try invoke(paste); try await wait { owner.model.result.hasPrefix("insert\n") }
        merged.undoManager!.undo(); try await wait { owner.model.result == original }
        owner.close(); board.clearContents(); board.setString("sentinel", forType: .string)
        NSApp.sendAction(cut.action!, to: cut.target, from: cut)
        try require(board.string(forType: .string) == "sentinel", "Retired Cut changed private clipboard")
        // Two-pane comparison copies normalized visible text, including removed
        // rows in a combined view, and Cut with only a block does not delete it.
        let a = root.appendingPathComponent("left.txt"), b = root.appendingPathComponent("right.txt")
        try Data("head\r\nold 🦎\r\ntail\r\n".utf8).write(to: a)
        try Data("head\r\nnew 雪\r\ntail\r\n".utf8).write(to: b)
        let comparison = FileComparisonWindowController(comparison: try WorkingFileComparison(base: a, destination: b), permissions: [], preferences: prefs)
        defer { comparison.close() }
        comparison.window!.contentView!.layoutSubtreeIfNeeded()
        try await wait {
            comparison.window!.contentView!.layoutSubtreeIfNeeded()
            return comparison.model.alignment != nil && !comparison.model.busy && !comparison.model.filtering && descendants(comparison.window!.contentView!).compactMap { $0 as? NSTextView }.filter { $0 is ComparisonContextMenuProviding }.count == 2
        }
        print("Two-pane loaded:", comparison.model.busy, comparison.model.error ?? "no error")
        let panes = descendants(comparison.window!.contentView!).compactMap { $0 as? NSTextView }.filter { $0 is ComparisonContextMenuProviding }
        try require(panes.count == 2, "Two comparison panes missing")
        for pane in panes {
            let text = pane.string, needle = text.contains("old 🦎") ? "old 🦎" : "new 雪", offset = (text as NSString).range(of: needle).location
            pane.setSelectedRange(NSRange(location: offset, length: 0))
            (pane as! MergeBlockSelecting).selectContextBlock(at:offset)
            try require(comparison.window!.firstResponder === pane,"Comparison context retained another pane's focus")
            let menu = (pane as! ComparisonContextMenuProviding).comparisonContextMenu(defaults: prefs, pasteboard: board)
            try invoke(menu.items.first { $0.title == "Copy" }!)
            try require(board.string(forType: .string)?.contains(needle) == true && board.string(forType: .string)?.contains("\r") == false, "Two-pane block Copy lost text/endings")
            if let item = menu.items.first(where: { $0.title == "Cut" }), item.isEnabled {
                try invoke(item); try require(pane.string == text, "Block-only Cut deleted comparison text")
            }
        }
        try await wait { !comparison.model.busy && !comparison.model.filtering && !comparison.model.confirmingQuit }
        print("Mode preflight:", comparison.model.onePaneMode, comparison.model.singleFileMode, comparison.window!.attachedSheet != nil, comparison.model.document != nil)
        comparison.model.switchPaneMode(true)
        print("Mode submitted:", comparison.model.onePaneMode, comparison.model.busy)
        do { try await wait {
            comparison.window!.contentView!.layoutSubtreeIfNeeded()
            return !comparison.model.busy && !comparison.model.filtering && comparison.model.onePaneActive && descendants(comparison.window!.contentView!).compactMap { $0 as? NSTextView }.filter { $0 is ComparisonContextMenuProviding }.count == 1
        } } catch {
            throw Failure(description: "One-pane switch: active=\(comparison.model.onePaneActive), busy=\(comparison.model.busy), error=\(comparison.model.error ?? "none"), views=\(descendants(comparison.window!.contentView!).compactMap { $0 as? NSTextView }.filter { $0 is ComparisonContextMenuProviding }.count), dirty=\(comparison.model.dirty)")
        }
        let combined = descendants(comparison.window!.contentView!).compactMap { $0 as? NSTextView }.first { $0 is ComparisonContextMenuProviding }!
        let removed = (combined.string as NSString).range(of: "old 🦎")
        try require(removed.location != NSNotFound, "One-pane removed row missing")
        combined.setSelectedRange(NSRange(location: removed.location, length: 0))
        (combined as! MergeBlockSelecting).selectContextBlock(at:removed.location)
        let combinedMenu = (combined as! ComparisonContextMenuProviding).comparisonContextMenu(defaults: prefs, pasteboard: board)
        try invoke(combinedMenu.items.first { $0.title == "Copy" }!)
        let copied = board.string(forType: .string) ?? ""
        try require(copied.contains("old 🦎") && !copied.contains("new 雪") && !copied.hasSuffix("\n"), "One-pane context block crossed Removed/Added states or included a synthetic final break")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(after == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf: file)) == bytes, "Clipboard operations changed repository state")
        print("Merge clipboard: source/block/text Copy, normalized endings, private-board Cut/Paste, Undo, busy and retired refusal, two-pane block-only Cut and exact repository preservation passed. Owned windows closed.")
    }
}
