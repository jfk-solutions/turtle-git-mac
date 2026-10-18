import AppKit
import TurtleGitCore

struct RemoteListVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func trace(_ phase: String) { fputs("Remote list phase: \(phase)\n", stderr); fflush(stderr) }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Remote List"), ("user.email", "remote-list@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let input = root.appendingPathComponent("file"); try Data("base\n".utf8).write(to: input); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let long = "zz-team-with-a-long-configured-remote-name-for-horizontal-scrolling"
        let names = ["alpha", "origin", long] + (0..<20).map { "remote-" + String(format: "%02d", $0) }
        for name in names { _ = try await repo.run(["remote", "add", name, root.path]) }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: input)
        let suite = "TurtleGit.RemoteList." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        trace("create native standalone view")
        let owner = RemoteSettingsWindowController(repository: repo, access: nil, preferences: prefs), model = owner.model, window = owner.window!
        guard let view = window.contentView as? RemoteSettingsNativeView else { throw Failure(description: "Shipping Remote view missing") }
        var answer: CheckedContinuation<(yes: Bool, suppress: Bool), Never>?
        defer { answer?.resume(returning: (false, false)); owner.close() }
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<2500 { window.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw Failure(description: "Native Remote list timeout")
        }
        trace("load catalog and minimum-size layout")
        window.alphaValue = 0; window.orderFront(nil)
        model.load(); try await wait { !model.busy && view.table.numberOfRows == names.count }
        window.setContentSize(NSSize(width: 680, height: 420)); window.contentView?.layoutSubtreeIfNeeded()
        try require(view.remoteScroll.borderType == .bezelBorder && view.remoteScroll.bounds.width >= 175 && view.remoteScroll.bounds.height >= 220, "Remote list lacks a visible bordered viewport")
        try require(view.table.usesAlternatingRowBackgroundColors && !view.table.allowsMultipleSelection && view.table.rowHeight >= 22 && view.table.tableColumns.count == 1 && view.table.headerView == nil, "Remote list row/single-selection behavior differs")
        try require(view.table.tableColumns[0].width > view.remoteScroll.contentSize.width && view.remoteScroll.hasHorizontalScroller && view.remoteScroll.hasVerticalScroller, "Long remote names cannot scroll")
        try require(view.table.nextKeyView === view.remote && view.remote.nextKeyView === view.rename && view.rename.nextKeyView === view.url, "List/remote/name Tab order differs")
        func select(_ name: String) async throws {
            guard let row = model.names.firstIndex(of: GitReferenceName(name)) else { throw Failure(description: "Missing named remote: " + name) }
            view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try await wait { !model.busy && model.selected == GitReferenceName(name) && view.remote.stringValue == name && view.table.selectedRow == row }
        }
        trace("native selection and keyboard focus")
        try await select("alpha")
        try require(window.makeFirstResponder(view.table), "Remote list cannot receive keyboard focus")
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
        view.table.keyDown(with: down)
        try await wait { !model.busy && model.selected == model.names[1] }
        try require(view.table.selectedRow == 1 && view.remote.stringValue == model.names[1].rawValue && window.firstResponder === view.table, "Arrow selection did not load the selected remote or keep focus: row=\(view.table.selectedRow), field=\(view.remote.stringValue), expected=\(model.names[1].rawValue), responder=\(String(describing:window.firstResponder)), table=\(view.table), enabled=\(view.table.isEnabled)")
        trace("stable native rows while typing")
        // Field editing must preserve the actual existing native rows and scroll.
        view.table.scrollRowToVisible(view.table.numberOfRows - 1); view.layoutSubtreeIfNeeded()
        let origin = view.table.visibleRect.origin, row = view.table.rows(in: view.table.visibleRect).location
        guard row != NSNotFound, let cell = view.table.view(atColumn: 0, row: row, makeIfNecessary: true) else { throw Failure(description: "Visible Remote row missing") }
        view.pushURL.stringValue = "unsaved-native-draft"; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.pushURL))
        view.layoutSubtreeIfNeeded()
        try require(view.table.view(atColumn: 0, row: row, makeIfNecessary: false) === cell && view.table.visibleRect.origin == origin, "Typing in Remote fields recreated or scrolled the name list")
        trace("owned Save/Discard pending selection")
        // Retain the newly highlighted intent while the owned Save/Discard read
        // blocks controls, then adopt the accepted native selection once.
        model.confirm = { prompt in
            if case .saveDiscard = prompt { return await withCheckedContinuation { answer = $0 } }
            return (false, false)
        }
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await wait { answer != nil }
        try require(model.busy && model.displayedSelection == model.names[0] && view.table.selectedRow == 0 && !view.table.isEnabled && !view.tableView(view.table, shouldSelectRow: 1), "Pending draft selection lost its highlight or busy fence")
        model.select(model.names[2]); try require(model.displayedSelection == model.names[0], "Competing selection replaced pending draft target")
        answer?.resume(returning: (false, false)); answer = nil
        try await wait { !model.busy && model.selected == "alpha" && model.changed.isEmpty }
        try require(view.pushURL.stringValue.isEmpty && view.remote.stringValue == "alpha", "Discard did not restore the newly selected remote")
        trace("native Add Save Fetch Rename Remove")
        // Actual controls retain the existing Add/Save, Fetch, Rename and Remove
        // model/Git workflow rather than maintaining a separate display-only list.
        var fetches: [String] = []
        model.onFetch = { fetches.append($0) }
        model.confirm = { prompt in if case .fetch = prompt { return (true, false) }; if case .remove = prompt { return (true, false) }; return (false, false) }
        view.remote.stringValue = "new-native-list-remote"; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.remote))
        view.url.stringValue = root.path; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.url))
        view.add.performClick(nil); try await wait { !model.busy && model.selected == "new-native-list-remote" }
        try require(model.error == nil && fetches == ["new-native-list-remote"] && view.table.numberOfRows == names.count + 1, "Native Add/Save list refresh or Fetch handoff failed")
        view.remote.stringValue = "renamed-native-list-remote"; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.remote)); view.rename.performClick(nil)
        try await wait { !model.busy && model.selected == "renamed-native-list-remote" }
        try require(model.error == nil && model.names.contains("renamed-native-list-remote") && !model.names.contains("new-native-list-remote"), "Native Rename lost list selection")
        view.remove.performClick(nil); try await wait { !model.busy && model.selected == nil }
        try require(model.error == nil && view.table.selectedRow == -1 && view.table.numberOfRows == names.count && view.remote.stringValue.isEmpty, "Native Remove did not clear the selected draft")
        try await select("origin")
        trace("embedded native list layout")
        let embeddedModel = RemoteSettingsWindowModel(repository: repo, access: nil, preferences: prefs, noFetch: true)
        let embedded = RemoteSettingsNativeView(model: embeddedModel, embeddedSettings: true)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = embedded; host.alphaValue = 0; host.orderFront(nil)
        defer { embeddedModel.invalidate(); host.close() }
        embeddedModel.load(); try await wait { !embeddedModel.busy && embeddedModel.names.count == names.count }
        embeddedModel.select("origin"); try await wait { !embeddedModel.busy && embeddedModel.selected == "origin" }
        embedded.layoutSubtreeIfNeeded()
        try require(embedded.remoteScroll.bounds.height >= 220 && embedded.remoteScroll.borderType == .bezelBorder && embedded.table.numberOfRows == names.count, "Embedded Settings page lost full-height native list")
        for content in [view, embedded] {
            let bounds = content.bounds
            for control in [content.remoteScroll, content.remote, content.url, content.pushURL, content.sshKey, content.add, content.remove] {
                let rect = content.convert(control.bounds, from: control)
                try require(rect.minX >= -1 && rect.minY >= -1 && rect.maxX <= bounds.maxX + 1 && rect.maxY <= bounds.maxY + 1 && rect.width > 0 && rect.height > 0, "Remote list/form control escapes native content bounds")
            }
        }
        trace("optional native light dark captures")
        if let destination = ProcessInfo.processInfo.environment["TURTLEGIT_REMOTE_LIST_CAPTURE"] {
            let directory = URL(fileURLWithPath: destination); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for (kind, content, ownerWindow) in [("standalone", view, window), ("embedded", embedded, host)] {
                    ownerWindow.appearance = NSAppearance(named: appearance); content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
                    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw Failure(description: "Remote content capture unavailable") }
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Remote PNG encoding unavailable") }
                    try png.write(to: directory.appendingPathComponent("remote-list-" + kind + "-" + name + ".png"))
                }
            }
        }
        trace("close owned windows and drain operations")
        owner.close(); embeddedModel.invalidate(); host.close()
        try await wait { RemoteSettingsWindowModel.activeOperations == 0 }
        try require(head == (try await repo.run(["rev-parse", "HEAD"])).stdout && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && bytes == Data(contentsOf: input), "Remote UI changed HEAD/index/input")
        let finalNames = try await repo.remoteNames()
        try require(GitPathSet(finalNames) == GitPathSet(names), "Native list flow left an unexpected remote mutation")
        print("PASS: bordered selectable/scrollable Remote list, native keyboard focus, stable rows through typing, owned pending draft selection, Add/Save/Fetch/Rename/Remove and standalone/embedded layout")
    }
}
