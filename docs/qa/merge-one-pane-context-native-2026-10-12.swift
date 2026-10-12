import AppKit
import TurtleGitCore

struct MergeOnePaneContextVerification {
    @MainActor static func verify() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "OnePaneContext", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitOnePaneContext-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.OnePaneContext." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let first = NSPasteboard(name: .init("TurtleGit.OnePaneContext.First." + UUID().uuidString)), second = NSPasteboard(name: .init("TurtleGit.OnePaneContext.Second." + UUID().uuidString))
        defer { prefs.removePersistentDomain(forName: suite); first.releaseGlobally(); second.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        prefs.set(true, forKey: "TurtleGitMerge.OnePane")
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine")
        let before = "same\r\nold 🦎 words\r\nlast", after = "same\r\nnew words\r\nlast"
        try Data(before.utf8).write(to: base); try Data(after.utf8).write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        defer { owner.window?.close() }
        let model = owner.model; model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); model.load()
        try await TwoPaneEngineVerification.settled(model); owner.window?.contentView?.layoutSubtreeIfNeeded()
        func wait(_ ready: () -> Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw NSError(domain: "One-pane context did not settle", code: 1) }
        try await wait { TwoPaneEngineVerification.editors(owner.window?.contentView).count == 1 }
        let view = TwoPaneEngineVerification.editors(owner.window?.contentView)[0]
        guard let provider = view as? ComparisonContextMenuProviding else { throw NSError(domain: "Context provider missing", code: 1) }
        view.setSelectedRange((view.string as NSString).range(of: "old 🦎 words"))
        first.setString("FIRST", forType: .string); second.setString("SECOND", forType: .string)
        func item(_ menu: NSMenu, _ title: String) throws -> NSMenuItem { guard let item = menu.items.first(where: { $0.title == title }) else { throw NSError(domain: "Missing " + title, code: 1) }; return item }
        func invoke(_ item: NSMenuItem) throws { try check(NSApplication.shared.sendAction(item.action!, to: item.target, from: item), "Action did not route: " + item.title) }
        let menu = provider.comparisonContextMenu(defaults: prefs, pasteboard: first)
        try check(menu.items.prefix(3).map(\.title) == ["Use this block", "Use both blocks, this one first", "Use both blocks, this one last"], "Combined menu differs from left source role")
        try check(!menu.items.contains { ["Mark block", "Unmark block", "Leave only marked blocks"].contains($0.title) }, "Right-view mark commands leaked into combined mode")
        for title in ["Use this block", "Use both blocks, this one first", "Use both blocks, this one last", "Use this whole file"] {
            let command = try item(menu, title); try check(!command.isEnabled, "Missing opposite-view command enabled")
            try invoke(command)
        }
        model.useOtherFile(); model.markBlock(true); model.leaveOnlyMarked()
        try check(!model.dirty && !model.canUndo && model.draftText(base: false) == after, "Stale opposite-view command changed Mine")
        let copy = try item(menu, "Copy"); try check(copy.isEnabled, "Removed row cannot be copied")
        // A newer menu must not replace the older menu's captured pasteboard.
        _ = provider.comparisonContextMenu(defaults: prefs, pasteboard: second)
        try invoke(copy); try check(first.string(forType: .string) == "old 🦎 words" && second.string(forType: .string) == "SECOND", "Copy used the wrong pasteboard or excluded removed payload")
        let titles = menu.items.map(\.title)
        try check(titles.firstIndex(of: "Copy")! < titles.firstIndex(of: "End of Line Style")!, "Clipboard entries must precede writable format choices")
        let encoding = try item(menu, "File Encoding").submenu!
        try check(encoding.items.map(\.title) == MergeFormatSelection.encodings.map(\.rawValue), "Source nine-encoding order differs")
        try invoke(encoding.items.first { $0.title == ComparisonTextEncoding.utf16BEBOM.rawValue }!)
        try check(model.encoding(base: false) == .utf16BEBOM, "Reordered encoding action chose wrong format")
        model.changeEncoding(.utf8, base: false)
        view.setSelectedRange((view.string as NSString).range(of: "new"))
        let pasteMenu = provider.comparisonContextMenu(defaults: prefs, pasteboard: second)
        try invoke(try item(pasteMenu, "Paste")); try await TwoPaneEngineVerification.settled(model)
        try check(model.draftText(base: false) == "same\r\nSECOND words\r\nlast", "Paste did not use captured text/destination coordinates")
        model.undo(); try await TwoPaneEngineVerification.settled(model)
        view.setSelectedRange((view.string as NSString).range(of: "new"))
        let cutMenu = provider.comparisonContextMenu(defaults: prefs, pasteboard: first)
        try invoke(try item(cutMenu, "Cut")); try await TwoPaneEngineVerification.settled(model)
        try check(first.string(forType: .string) == "new" && model.draftText(base: false) == "same\r\n words\r\nlast", "Cut clipboard/payload differs")
        model.undo(); try await TwoPaneEngineVerification.settled(model)
        model.editingEnabled = false; try await wait { !view.isEditable }
        view.setSelectedRange((view.string as NSString).range(of: "old"))
        let readonly = provider.comparisonContextMenu(defaults: prefs, pasteboard: first)
        try check(!readonly.items.contains { $0.title == "Cut" || $0.title == "Paste" || $0.title == "File Encoding" }, "Readonly combined menu exposed write commands")
        let lateCopy = try item(readonly, "Copy"), latePaste = try item(pasteMenu, "Paste")
        first.clearContents(); first.setString("retain", forType: .string)
        let draft = model.draftText(base: false); model.retireImageLoader()
        try invoke(lateCopy); try invoke(latePaste)
        try check(first.string(forType: .string) == "retain" && model.draftText(base: false) == draft && !model.canEdit(base: false), "Retired menu changed clipboard/draft")
        let finalBase = try Data(contentsOf: base), finalMine = try Data(contentsOf: mine)
        try check(finalBase == Data(before.utf8) && finalMine == Data(after.utf8), "Context action changed saved inputs")
        print("One-pane context: source left-role labels/clipboard-format ordering, hidden-opposite command guards, no right-only marks, removed Copy, captured private pasteboards across menus, actual Cut/Paste with Undo, nine encoding order/action identity, readonly and retired clipboard/edit guards passed. Owned window/helpers closed; no user clipboard touched.")
    }
}
