import AppKit
import TurtleGitCore

struct ReferenceActionFamilyVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, in root: NSView?, label: String) -> T? {
        guard let root else { return nil }; if let view = root as? T, view.accessibilityLabel() == label { return view }
        return root.subviews.compactMap { find(type, in: $0, label: label) }.first
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Reference Actions"), ("user.email", "refs@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let input = root.appendingPathComponent("file"); try Data("base\n".utf8).write(to: input); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        for name in ["left", "right"] { _ = try await repo.run(["branch", name]) }
        _ = try await repo.run(["tag", "release"])
        _ = try await repo.run(["remote", "add", "origin", "https://example.invalid/unused"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/topic", "HEAD"])
        _ = try await repo.run(["config", "--add", "branch.left.description", "first\nline"])
        _ = try await repo.run(["config", "--add", "branch.left.description", "ignored"])
        _ = try await repo.run(["branch", "--set-upstream-to=origin/topic", "left"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: input)
        let suite = "TurtleGit.ReferenceActionFamily." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "UseMailmap"); prefs.set(317, forKey: "ReferenceActionFamily.Sentinel")
        let owner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/left", preferences: prefs, picking: false) { _ in }, model = owner.model, window = owner.window!
        defer { owner.close() }
        owner.commandKeyWindow = { window }; window.alphaValue = 0; window.orderFront(nil)
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<2500 { window.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw Failure(description: "Reference action family timeout")
        }
        model.load(); try await wait { !model.busy && model.snapshot != nil }
        guard let table = find(ReferenceBrowserRenameTable.self, in: window.contentView, label: "References"),
              let tree = find(ReferenceBrowserNamespaceOutline.self, in: window.contentView, label: "Reference namespaces") else { throw Failure(description: "Native reference views missing") }
        try require(model.snapshot?.references.first { $0.name == "refs/heads/left" }?.description == "first\nline", "Catalog did not retain first local branch description")
        var menu: NSMenu?, calls: [String] = []
        table.selectionMenu.present = { popup, _, view in if view === table { menu = popup } }
        tree.selectionMenu.present = { popup, _, view in if view === tree { menu = popup } }
        model.onLog = { calls.append($0) }; model.copyReferences = { calls.append($0) }
        func choose(_ refs: Set<GitReferenceName>) async throws {
            model.select(refs, last: refs.first)
            try await wait { table.isEnabled && table.selectedRowIndexes.count == refs.count && table.selectedRowIndexes.allSatisfy { model.rows.indices.contains($0) && refs.contains(model.rows[$0].reference.name) } }
        }
        func invoke(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw Failure(description: "Missing native action: " + item.title) }
            try require(NSApp.sendAction(action, to: item.target, from: item), "Native menu dispatch failed")
        }
        try await choose(["refs/heads/left"])
        try require(table.accessibilityPerformShowMenu(), "First accessible reference popup failed")
        guard let popup = menu, let copy = popup.item(withTitle: "Copy ref names"), let log = popup.item(withTitle: "Show log") else { throw Failure(description: "Source reference commands missing") }
        let titles = popup.items.map(\.title)
        guard let rename = titles.firstIndex(of: "Rename"), let unset = titles.firstIndex(of: "Unset tracked branch") else { throw Failure(description: "Source tracking section missing") }
        try require(unset == rename + 2 && popup.items[rename + 1].isSeparatorItem && copy.image != nil && log.image != nil, "Source tracking separator/icon order differs")
        try await choose(["refs/heads/right"]); try invoke(copy); try invoke(copy)
        try require(calls == ["left"] && model.selection == ["refs/heads/right"], "Captured one-shot copy retargeted, replayed or replaced visible selection")
        try invoke(log); try invoke(log)
        try require(calls == ["left", "refs/heads/left"], "Captured Log callback replayed or retargeted")
        // Native keyboard and accessibility entry share the selected-row route.
        menu = nil; window.makeFirstResponder(table)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 109)!
        table.keyDown(with: key)
        try require(menu != nil && model.selection == ["refs/heads/right"], "Shift-F10 lost selected reference")
        let retired = menu!.item(withTitle: "Show log")!, count = calls.count
        model.hasChild = true; try require(!table.accessibilityPerformShowMenu(), "Child owner allowed accessible reference popup"); try invoke(retired); model.hasChild = false; try invoke(retired)
        try require(calls.count == count, "Child transition revived old native popup")
        // Folder menus have no leaf payload even while a list selection exists.
        model.setFolder("refs/heads"); try await choose(["refs/heads/right"])
        try await wait { tree.selectedRow >= 0 }
        menu = nil; try require(tree.accessibilityPerformShowMenu(), "Namespace accessibility popup failed")
        guard let folder = menu, let create = folder.item(withTitle: "Create Branch…") else { throw Failure(description: "Source namespace command missing") }
        var folderCalls = 0, leafCount = -1
        model.onCreateFolder = { tag in if !tag { folderCalls += 1; leafCount = model.selectedRows.count } }
        try invoke(create); try invoke(create)
        try require(folderCalls == 1 && leafCount == 0 && model.selection == ["refs/heads/right"], "Namespace popup inherited/replayed leaf selection")
        // Pair comparisons inherit the owner's actual preferences, not standard.
        try await choose(["refs/heads/left", "refs/heads/right"])
        model.onComparePair = { [weak owner] pair in owner?.showComparison(pair) }
        owner.presentComparison = { _, _ in true }
        model.comparePair(unified: false)
        guard let comparison = owner.comparisonDialog else { throw Failure(description: "Owned comparison did not open") }
        try require(comparison.model.preferences === prefs && comparison.model.preferences.integer(forKey: "ReferenceActionFamily.Sentinel") == 317 && model.hasChild, "Comparison lost owning preferences")
        try await wait { !comparison.model.busy }
        comparison.close(); try require(owner.comparisonDialog == nil && !model.hasChild, "Comparison ownership did not release")
        try await choose(["refs/heads/right"]); try require(table.accessibilityPerformShowMenu(), "Retirement popup missing")
        let closedCopy = menu!.item(withTitle: "Copy ref names")!, beforeClose = calls.count
        owner.close(); try invoke(closedCopy)
        try require(!table.accessibilityPerformShowMenu() && !tree.accessibilityPerformShowMenu() && calls.count == beforeClose, "Closed owner allowed stale native actions")
        try await wait { ReferenceBrowserWindowModel.activeReads == 0 && ReferenceBrowserWindowModel.activeMutations == 0 }
        try require(head == (try await repo.run(["rev-parse", "HEAD"])).stdout && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && bytes == Data(contentsOf: input), "Read-only reference actions changed repository")
        print("PASS: source reference sections, local first descriptions, selected-row AX/keyboard popups, captured one-shot leaf/folder actions, owned comparison preferences and retirement")
    }
}
