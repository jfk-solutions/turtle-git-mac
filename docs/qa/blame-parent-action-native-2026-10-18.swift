// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum BlameParentActionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2400 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Blame parent family timeout at \(line)")
    }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func send(_ item: NSMenuItem) throws {
        guard item.isEnabled, let action = item.action else { throw Failure(description: "Missing enabled action: " + item.title) }
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }
    static func drained() -> Bool {
        BlameWindowModel.activeHistoryOperations == 0 && CommitContainingReferencesWindowController.activeOperations == 0 && ReferenceBrowserWindowModel.activeReads == 0 && RepositoryBrowserWindowModel.activeOperations == 0
    }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Parent QA"), ("user.email", "parent@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let old = "nested/old 雪\n.cpp", path = "nested/new 雪\n.cpp", stable = String(repeating: "stable context ", count: 20)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data((stable + "\nold line\nlast\n").utf8).write(to: root.appendingPathComponent(old)); try await repo.stage([old]); _ = try await repo.commit(message: "First parent subject exceeds twenty characters")
        let first = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["mv", "--", old, path]); try Data((stable + "\nchanged line\nlast\n").utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "Rename and modify")
        let second = try await repo.rebaseCommit("HEAD")
        try Data((stable + "\nchanged line\nlast changed\n").utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "Later change")
        let third = try await repo.rebaseCommit("HEAD"), choices = try await repo.blameParentComparisons(revision: second.hash, path: path), otherChoices = try await repo.blameParentComparisons(revision: third.hash, path: path)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let suite = "TurtleGit.BlameParentAction." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "TurtleGit.UnifiedDiffViewer.Enabled"); prefs.set(true, forKey: "ShowAppContextMenuIcons"); prefs.set(true, forKey: "DiffByDoubleClickInLog"); prefs.set(false, forKey: "EnableGravatar")
        let owner = BlameWindowController(repository: repo, access: nil, path: path, revision: third.hash, options: GitBlameOptions(), preferences: prefs), model = owner.model, window = owner.window!
        var heldParents: CheckedContinuation<[GitBlameParentComparison], Error>?, heldPatch: CheckedContinuation<Data, Error>?
        var browser: RepositoryBrowserWindowController?
        var parentToken: OperationCancellation?, patchToken: OperationCancellation?
        defer { heldParents?.resume(throwing: OperationCancellationFailure.cancelled); heldPatch?.resume(throwing: OperationCancellationFailure.cancelled); browser?.close(); owner.close(); prefs.removePersistentDomain(forName: suite) }
        do {
            window.alphaValue = 0; window.orderFront(nil)
            try await wait { !model.busy && !model.syntaxWorking && model.lines.count == 3 }
            window.contentView?.layoutSubtreeIfNeeded()
            guard let editor = views(window.contentView!).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Blame source text" }) else { throw Failure(description: "Production source editor missing") }
            var prior: (String, String, Int)?, priorOptions: GitBlameOptions?, compared: RevisionComparisonSnapshot?, alternate = false
            model.onPrevious = { prior = ($0, $1, $2); priorOptions = $3 }
            model.onChanges = { compared = $0; alternate = ComparisonToolInvocation.capture }
            var menus: [NSMenuItem] = [], presentations = 0
            model.presentSourceMenu = { menu, _, _ in menus = menu.items; presentations += 1; menu.delegate?.menuDidClose?(menu) }
            func open() throws { editor.setSelectedRange((editor.string as NSString).range(of: "changed line")); try require(editor.accessibilityPerformShowMenu(), "Source request rejected") }
            func item(_ title: String) throws -> NSMenuItem { guard let value = menus.first(where: { $0.title == title }) else { throw Failure(description: "Missing source item: " + title) }; return value }
            // Parent read failure must retain upstream's independent Log/Copy popup.
            model.readSourceParents = { _, _, _ in throw Failure(description: "injected parent read failure") }
            try open(); try await wait { presentations == 1 && drained() }
            try require(menus.contains { $0.title == "Show log" } && menus.contains { $0.title == "Copy SHA-1 to clipboard" } && !menus.contains { $0.title == "Blame previous revision" }, "Parent failure suppressed independent source actions")
            // A newer request wins even when the old Git reader ignores cancellation.
            var reads = 0
            model.readSourceParents = { _, _, token in
                reads += 1
                if reads == 1 { parentToken = token; return try await withCheckedThrowingContinuation { heldParents = $0 } }
                return choices
            }
            try open(); try await wait { heldParents != nil }
            try open(); try await wait { presentations == 2 && reads == 2 }
            try require(parentToken?.isCancelled == true && BlameWindowModel.activeHistoryOperations > 0, "Superseded read lost owned cancellation/accounting")
            heldParents?.resume(returning: otherChoices); heldParents = nil
            try await wait { drained() }; try require(presentations == 2 && model.parentChoices.map(\.id) == choices.map(\.id), "Late parent reply changed current popup/targets")
            model.readSourceParents = nil
            let compare = try item("Compare with previous revision"), previous = try item("Blame previous revision")
            let font = compare.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            try require(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true && compare.image != nil, "Source default emphasis/artwork missing")
            try send(previous); try require(prior?.0 == old && prior?.1 == first.hash && prior?.2 == 2 && priorOptions == model.appliedOptions, "Previous Blame lost old rename path/original line: actual=\(String(describing: prior)), expectedPath=\(old.debugDescription), first=\(first.hash), source=\(String(describing: model.selectedLine)), choices=\(choices.map { ($0.path, $0.revision, $0.comparison.to.label) }), canFind=\(model.canFind)")
            try ComparisonToolInvocation.$alternate.withValue(true) { try send(compare) }
            try require(alternate && compared?.files.first?.oldPath == old && compared?.files.first?.path == path && compared?.to == .revision(second.hash), "Historical comparison lost captured rename/alternate/revision")
            let target = model.sourceParentTarget(second.hash)!
            compared = nil; model.performHistoryParent(target, choices: otherChoices, action: .compare)
            try require(compared == nil, "Parent action accepted a snapshot for another destination revision")
            // Browse at a file seeds its parent listing and exact selection.
            let fileBrowser = RepositoryBrowserWindowController(repository: repo, access: nil, revision: second.hash, preferences: prefs, initialFile: path)
            browser = fileBrowser; fileBrowser.window?.alphaValue = 0
            fileBrowser.window?.orderFront(nil)
            try await wait { !fileBrowser.model.busy && RepositoryBrowserWindowModel.activeOperations == 0 }
            try require(fileBrowser.model.snapshot?.directory == "nested" && fileBrowser.model.selected.count == 1 && fileBrowser.model.selected.first?.path == path && fileBrowser.model.initialFile == nil && fileBrowser.model.preferences === prefs && fileBrowser.window?.alphaValue == 0, "Browser lost nested renamed file selection/private preferences/hidden ownership")
            fileBrowser.close(); browser = nil
            // Built-in viewers inherit private preferences and are invisible before display.
            model.performHistoryParent(target, choices: choices, action: .unified)
            try await wait { owner.historyUnifiedWindows.count == 1 && drained() }
            let viewer = owner.historyUnifiedWindows.values.first!
            try require(viewer.window?.alphaValue == 0 && viewer.model.appearancePreferences === prefs && viewer.model.readOnly, "Unified viewer escaped inherited hidden/preferences/read-only ownership")
            viewer.model.busy = true; try await wait { model.historyChildBlocked }
            try require(!model.canFind && !owner.windowShouldClose(window), "Busy unified child did not block parent actions/close")
            viewer.model.busy = false; try await wait { !model.historyChildBlocked }; viewer.close()
            model.onContainingReferences?(second.hash)
            try await wait { owner.containingReferences.count == 1 && !owner.containingReferences.values.first!.busy }
            let child = owner.containingReferences.values.first!
            try require(child.window?.alphaValue == 0 && child.preferences === prefs, "Containing window escaped hidden/private ownership")
            guard let chooser = child.chooser.menu?.items.first(where: { $0.title == "Browse References" && $0.action != nil }) else { throw Failure(description: "Containing picker action missing") }
            try send(chooser); try await wait { child.picker != nil && model.historyChildBlocked }
            try require(!owner.windowShouldClose(window) && !model.canFind && child.externalAvailability(), "Containing picker self-locked or left parent active")
            child.picker?.close(); try await wait { child.picker == nil && !model.historyChildBlocked }; child.close()
            // Close during a held patch read cancels it but retains work until reply.
            model.readHistoryPatch = { _, token in patchToken = token; return try await withCheckedThrowingContinuation { heldPatch = $0 } }
            model.performHistoryParent(target, choices: choices, action: .unified)
            try await wait { heldPatch != nil }
            owner.close()
            try require(patchToken?.isCancelled == true && BlameWindowModel.activeHistoryOperations > 0, "Retirement lost actual patch read ownership")
            heldPatch?.resume(returning: Data("late patch".utf8)); heldPatch = nil
            try await wait { drained() }
            try require(owner.historyUnifiedWindows.isEmpty && owner.containingReferences.isEmpty, "Late patch reply recreated retired children")
            try require((try await repo.run(["rev-parse", "HEAD"]).stdout) == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf: root.appendingPathComponent(path))) == bytes, "Historical actions changed HEAD/index/working input")
            print("PASS: Blame parent failure fallback, superseded exact snapshots, rename/line/alternate targets, native default emphasis/icons, hidden inherited viewers/containing children, child blocking and actual cancelled read drain")
        } catch {
            heldParents?.resume(throwing: OperationCancellationFailure.cancelled); heldParents = nil
            heldPatch?.resume(throwing: OperationCancellationFailure.cancelled); heldPatch = nil
            browser?.close(); owner.close(); try? await wait { drained() }; throw error
        }
    }
}
