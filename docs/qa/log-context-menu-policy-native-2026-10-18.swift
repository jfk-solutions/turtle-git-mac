// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

enum LogContextMenuPolicyVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2400 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Log menu policy timeout")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func leaves(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { item in item.submenu.map(leaves) ?? [item] } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Menu QA"), ("user.email", "menu@example.invalid"), ("commit.gpgsign", "false")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("file")
        for number in 1...3 { try Data("\(number)\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "Menu \(number)") }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), original = try Data(contentsOf: file)
        let suite = "TurtleGit.LogContextMenuPolicy." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!, clipboard = NSPasteboard.withUniqueName()
        prefs.set(false, forKey: "Gravatar"); prefs.set(false, forKey: "LogIncludeWorkingTreeChanges"); prefs.set(true, forKey: "DiffByDoubleClickInLog")
        let owner = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false), model = owner.model, window = owner.window!
        defer { owner.close(); prefs.removePersistentDomain(forName: suite); clipboard.releaseGlobally() }
        do {
            window.alphaValue = 0; window.orderFront(nil); model.clipboard = clipboard
            try await wait { window.contentView?.layoutSubtreeIfNeeded(); return !model.busy && model.entries.count == 3 }
            guard let table = views(window.contentView!).compactMap({ $0 as? HistoryTableView }).first,
                  let coordinator = table.delegate as? RevisionTable.Coordinator, let menu = table.menu else { throw Failure(description: "Production revision menu missing") }
            let middle = model.entries[1]
            model.select([middle.hash]); try await wait { !model.files.isEmpty }
            func rebuild() { coordinator.menuNeedsUpdate(menu) }
            func action(_ name: String) -> NSMenuItem? { leaves(menu).first { $0.action.map { NSStringFromSelector($0) } == name } }
            func dispatch(_ item: NSMenuItem) { if let selector = item.action { _ = NSApp.sendAction(selector, to: item.target, from: item) } }
            var browsed = 0
            model.onBrowseRepository = { _ in browsed += 1 }
            model.onCompare = { _, _ in }
            model.contextMenuPolicy = .log; rebuild()
            try require(action("showHistory:") == nil, "Normal unnamed revision unexpectedly showed log")
            guard let previous = action("compare") else { throw Failure(description: "Default comparison missing") }
            guard let defaultTitle = previous.attributedTitle, defaultTitle.length > 0 else { throw Failure(description: "Default comparison has no attributed title") }
            let defaultFont = defaultTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            try require(defaultTitle.string == previous.title && defaultFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "Source default comparison has no bold emphasis")
            let defaultTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            model.contextMenuPolicy = HistoryContextMenuPolicy(commands: [.comparePrevious, .repositoryBrowser, .copyClipboard])
            rebuild()
            let filteredTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            try require(filteredTitles == defaultTitles.filter { filteredTitles.contains($0) }, "Consumer filtering reordered source commands")
            try require(action("compare") != nil && action("browseRepository") != nil && action("copyHashes") != nil && action("reset") == nil && action("findEntry:") == nil && action("editNotes") == nil, "Mask leaked mutation/find/note commands or lost parent/clipboard actions")
            try require(menu.items.first?.isSeparatorItem != true && menu.items.last?.isSeparatorItem != true && !zip(menu.items, menu.items.dropFirst()).contains(where: { pair in pair.0.isSeparatorItem && pair.1.isSeparatorItem }), "Mask left orphan separators")
            guard let captured = action("browseRepository") else { throw Failure(description: "Captured browse missing") }
            model.contextMenuPolicy.hide([.repositoryBrowser]); dispatch(captured)
            try require(browsed == 0, "Changed consumer mask accepted a stale receipt")
            model.contextMenuPolicy = .blame; rebuild()
            try require(action("showHistory:") != nil && action("reset") == nil && action("findEntry:") == nil, "Explicit source Show log bit did not override unnamed revision restriction")
            table.contextExtendedMenu = true; model.contextMenuPolicy = HistoryContextMenuPolicy(commands: []); rebuild()
            try require(leaves(menu).filter { !$0.isSeparatorItem }.count == 1 && action("showHistory:") != nil, "Shift did not preserve source Show log exception to empty mask")
            table.contextExtendedMenu = false
            model.select([model.entries[0].hash]); model.contextMenuPolicy = HistoryContextMenuPolicy(commands: []); rebuild()
            try require(action("showHistory:") != nil, "Named revision lost source Show log exception")
            // Range log entries are intentionally not governed by a source bit.
            model.select(Set(model.entries.prefix(2).map(\.hash))); rebuild()
            try require(leaves(menu).filter { $0.action.map { NSStringFromSelector($0) } == "showHistoryRange:" }.count == 3, "Mask incorrectly hid unmasked source range log entries")
            model.select([middle.hash]); model.contextMenuPolicy = .log; rebuild()
            guard let quitItem = action("browseRepository") else { throw Failure(description: "Quit receipt missing") }
            model.confirmingQuit = true; dispatch(quitItem); model.confirmingQuit = false
            try require(browsed == 0, "Quit confirmation accepted a captured menu action")
            rebuild(); guard let current = action("browseRepository") else { throw Failure(description: "Current browse missing") }
            dispatch(current); dispatch(current)
            try require(browsed == 1, "Current receipt did not execute exactly once")
            owner.close()
            try await wait { LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeActionReads == 0 }
            dispatch(current); try require(browsed == 1, "Retired menu receipt executed")
            try require((try await repo.run(["rev-parse", "HEAD"]).stdout) == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf: file)) == original, "Context policy interactions changed HEAD/index/input")
            print("PASS: native source masks, Show log exceptions, source order/default emphasis, unmasked ranges and captured-mask/Quit/once ownership")
        } catch {
            owner.close(); try? await wait { LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeActionReads == 0 }; throw error
        }
    }
}
