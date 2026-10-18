// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum ReferenceComparisonOwnershipVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2200 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Reference comparison ownership did not settle at \(line)")
    }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func click(_ item: NSMenuItem) throws {
        guard item.isEnabled, let action = item.action else { throw Failure(description: "Unavailable native command: " + item.title) }
        try require(NSApp.sendAction(action, to: item.target, from: item), "Native reference action was not dispatched")
    }
    static func verify() async throws {
        let suite = "TurtleGit.ReferenceComparisonOwnership.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(17, forKey: "DiffSimilarityIndexThreshold")
        defer { prefs.removePersistentDomain(forName: suite) }
        // Git detection is captured by the repository session before any read.
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]), diffDetection: .load(from: prefs))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Reference comparison QA"), ("user.email", "reference@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("file")
        try Data("first\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "first")
        _ = try await repo.run(["branch", "a-old"])
        let old = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("second\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "second")
        _ = try await repo.run(["branch", "z-new"])
        _ = try await repo.run(["remote", "add", "origin", root.path]); _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        let newer = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let tree = try await repo.run(["rev-parse", "HEAD^{tree}"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/custom/tree", tree])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let owner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/a-old", preferences: prefs, picking: false) { _ in }
        let window = owner.window!, model = owner.model
        var comparisons: [RevisionComparisonWindowController] = [], otherBrowsers: [ReferenceBrowserWindowController] = []
        var held: CheckedContinuation<Data, Error>?
        func drained() -> Bool { ReferenceBrowserWindowModel.activeReads == 0 && ReferenceBrowserWindowModel.activeComparisons == 0 && ReferenceBrowserWindowModel.activeMutations == 0 && ReferenceBrowserWindowController.activeChildReleases == 0 }
        func cleanup() async throws {
            owner.close(); otherBrowsers.forEach { $0.close() }; comparisons.forEach { $0.close() }
            held?.resume(throwing: OperationCancellationFailure.cancelled); held = nil
            try await wait { drained() }
            try require(!window.isVisible && comparisons.allSatisfy { $0.window?.isVisible != true } && otherBrowsers.allSatisfy { $0.window?.isVisible != true }, "Owned reference windows survived cleanup")
        }
        do {
        window.alphaValue = 0; window.orderFront(nil); model.load()
        try await wait { !model.busy && model.snapshot != nil && ReferenceBrowserWindowModel.activeReads == 0 }
        guard let table = views(window.contentView!).compactMap({ $0 as? ReferenceBrowserRenameTable }).first,
              let coordinator = table.delegate as? ReferenceBrowserNativeView.Coordinator,
              let menu = table.menu else { throw Failure(description: "Native reference report/menu missing") }
        func select(_ names: Set<GitReferenceName>, last: GitReferenceName? = nil) async throws {
            let folder = model.snapshot!.initialSelection(names.first!.rawValue).folder
            model.setFolder(folder); model.select(names, last: last ?? names.first)
            try await wait { !model.busy && !model.hasChild && ReferenceBrowserWindowModel.activeReads == 0 && table.window === window && Set(table.selectedRowIndexes.compactMap { model.rows.indices.contains($0) ? model.rows[$0].reference.name : nil }) == names && model.selection == names }
        }
        func item(_ title: String) throws -> NSMenuItem {
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let item = menu.item(withTitle: title) else { throw Failure(description: "Missing source reference command: " + title) }
            return item
        }
        model.onLog = { _ in }; model.onBrowse = { _ in }
        var workingTargets: [(String, Bool)] = []
        model.onCompareWithOptions = { name, alternate in
            workingTargets.append((name, alternate))
            let comparison = ComparisonToolInvocation.$alternate.withValue(alternate) { RevisionComparisonWindowController(repository: repo, access: nil, from: .revision(name), to: .workingTree, preferences: prefs) }
            comparison.window?.alphaValue = 0; comparisons.append(comparison); comparison.model.load()
        }
        try await select(["refs/heads/a-old"])
        let working = try item("Compare with working tree")
        let defaultFont = menu.items.first?.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let defaultBold = defaultFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
        try require(menu.items.first?.title == "Show log" && defaultBold && working.image != nil, "Source default item/order/comparison artwork missing")
        coordinator.menuModifiers = { .shift }
        model.select(["refs/heads/z-new"], last: "refs/heads/z-new")
        try click(working); try click(working)
        try require(workingTargets.count == 1 && workingTargets[0].0 == "refs/heads/a-old" && workingTargets[0].1 && model.selected == "refs/heads/z-new", "Shift/canonical captured target or one-shot menu ownership failed")
        try await wait { comparisons.first?.model.busy == false && comparisons.first?.model.snapshot != nil }
        try require(comparisons[0].model.alternateTool == true && comparisons[0].model.preferences === prefs && comparisons[0].model.snapshot?.diffDetection.percentage == 17 && comparisons[0].model.from == "refs/heads/a-old" && comparisons[0].model.to == ComparisonRevision.workingTree.label, "Working comparison lost explicit alternate/preferences/endpoints: alternate=\(String(describing: comparisons[0].model.alternateTool)), prefs=\(comparisons[0].model.preferences === prefs), detection=\(String(describing: comparisons[0].model.snapshot?.diffDetection.percentage)), from=\(comparisons[0].model.from), to=\(comparisons[0].model.to)")
        comparisons.forEach { $0.close() }; comparisons = []
        try await select(["refs/heads/a-old"])
        let stale = try item("Compare with working tree")
        model.load(); try await wait { !model.busy && ReferenceBrowserWindowModel.activeReads == 0 }
        try click(stale); try require(workingTargets.count == 1, "Catalog refresh revived a captured menu")
        try await select(["refs/heads/a-old"])
        let quitHeld = try item("Compare with working tree"), quitForm = model.formContext
        model.confirmingQuit = true
        try click(quitHeld); model.compareWorkingTree(alternate: false); owner.showSwitch(); model.deleteChosen(); model.currentBranch()
        model.queryBinding(context: quitForm).wrappedValue = "stale"
        try require(!model.canEditPresentation && !model.canAccept && !model.canDelete && !model.canUseFolder && owner.switchDialog == nil && !owner.windowShouldClose(window) && workingTargets.count == 1 && model.query.isEmpty && !model.busy, "Deferred Quit allowed reference actions or stale form mutation")
        model.confirmingQuit = false
        try click(quitHeld); try require(workingTargets.count == 1, "Cancelled Quit revived an old captured menu")
        var legacyAlternate = false
        model.onCompareWithOptions = nil; model.onCompare = { name in legacyAlternate = ComparisonToolInvocation.alternate == true && name == "refs/heads/a-old" }
        try await select(["refs/heads/a-old"]); try click(item("Compare with working tree"))
        try require(legacyAlternate, "Legacy comparison callback lost captured alternate task context")
        model.hasChild = true; model.compareWorkingTree(alternate: false); try require(workingTargets.count == 1, "Comparison ran behind an owned child"); model.hasChild = false

        // Unified comparison uses source captured object hashes even if a named
        // endpoint moves after its menu is displayed. Working comparison keeps
        // its canonical name so its own dialog can resolve the live endpoint.
        try await select(["refs/heads/a-old", "refs/heads/z-new"], last: "refs/heads/a-old")
        let pair = model.comparisonPair!, expected = try await repo.referenceBrowserUnifiedDiff(pair)
        let unified = try item("Show changes as unified diff")
        _ = try await repo.run(["update-ref", "refs/heads/a-old", newer])
        var output: Data?, alternate: Bool?
        owner.presentUnified = { bytes, shift, _ in output = bytes; alternate = shift }
        try click(unified); try await wait { !model.busy && ReferenceBrowserWindowModel.activeComparisons == 0 }
        try require(pair.fromHash == old && output == expected && alternate == true, "Unified source captured hashes or Shift route was replaced by moving references")

        model.load(); try await wait { !model.busy && ReferenceBrowserWindowModel.activeReads == 0 }
        try await select(["refs/custom/tree"])
        let browse = try item("Browse repository")
        try require(menu.items.first === browse && browse.attributedTitle != nil && menu.item(withTitle: "Compare with working tree") == nil, "Noncommit menu/default/working-copy gate differs")
        try await select(["refs/heads/a-old"])
        // Tracking must wait for actual picker release before its mutation; the
        // old hasChild gate must not silently discard the captured selection.
        owner.selectTracking()
        try await wait { owner.trackingPicker?.model.busy == false && owner.trackingPicker?.model.snapshot != nil }
        let picker = owner.trackingPicker!
        try require(picker.window?.sheetParent === window && picker.window?.alphaValue == 0 && model.hasChild && !owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Tracking child lost actual hidden sheet/Close/Quit ownership")
        picker.model.setFolder("refs/remotes/origin"); picker.model.select(["refs/remotes/origin/main"], last: "refs/remotes/origin/main"); picker.model.accept()
        if window.attachedSheet != nil { try require(model.hasChild, "Browser unblocked before actual tracking sheet detachment") }
        try await wait { owner.trackingPicker == nil && window.attachedSheet == nil && !model.hasChild && !model.busy && ReferenceBrowserWindowModel.activeMutations == 0 && ReferenceBrowserWindowModel.activeReads == 0 }
        let upstream = try await repo.run(["config", "--local", "--get", "branch.a-old.merge"]).text
        try require(upstream == "refs/heads/main\n" && model.snapshot?.references.first(where: { $0.name == "refs/heads/a-old" })?.upstream == "origin/main", "Picker reply was lost before the actual tracking update/catalog refresh")

        // Opening and cancelling native action dialogs must refresh changes made
        // while they were open and retain the original visible reference.
        try await select(["refs/heads/a-old"]); owner.showSwitch()
        try await wait { owner.switchDialog?.model.busy == false && owner.switchDialog?.model.references.isEmpty == false }
        let checkout = owner.switchDialog!
        try require(checkout.window?.sheetParent === window && checkout.window?.alphaValue == 0, "Switch child did not inherit hidden owner presentation")
        _ = try await repo.run(["branch", "switch-appeared", newer]); checkout.model.close()
        if window.attachedSheet != nil { try require(model.hasChild && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Switch close released browser/Quit before sheet drain") }
        try await wait { owner.switchDialog == nil && window.attachedSheet == nil && !model.busy && !model.hasChild && ReferenceBrowserWindowModel.activeReads == 0 }
        try require(model.snapshot?.references.contains(where: { $0.name == "refs/heads/switch-appeared" }) == true && model.selected == "refs/heads/a-old", "Switch close left stale catalog/selection")
        owner.showMerge(); try await wait { owner.mergeDialog?.model.busy == false && owner.mergeDialog?.model.references.isEmpty == false }
        let merge = owner.mergeDialog!
        try require(merge.window?.sheetParent === window && merge.window?.alphaValue == 0, "Merge child did not inherit hidden owner presentation")
        _ = try await repo.run(["branch", "merge-appeared", newer]); merge.model.close()
        try await wait { owner.mergeDialog == nil && window.attachedSheet == nil && !model.busy && !model.hasChild && ReferenceBrowserWindowModel.activeReads == 0 }
        try require(model.snapshot?.references.contains(where: { $0.name == "refs/heads/merge-appeared" }) == true && model.selected == "refs/heads/a-old", "Merge close left stale catalog/selection")

        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = ReferenceBrowserWindowController(repository: GitRepository(root: bareRoot, executable: repo.executable), access: nil, initial: "refs/heads/a-old", preferences: prefs, picking: false) { _ in }
        var bareComparisons = 0
        otherBrowsers.append(bare); bare.window?.alphaValue = 0; bare.model.onCompareWithOptions = { _, _ in bareComparisons += 1 }; bare.model.load()
        try await wait { !bare.model.busy && bare.model.snapshot != nil && ReferenceBrowserWindowModel.activeReads == 0 }
        bare.model.compareWorkingTree(alternate: true)
        try require(bare.model.bare && !bare.model.canCompareWorkingTree && bareComparisons == 0, "Bare repository exposed working comparison")
        bare.close()

        // A noncooperative comparison read is cancelled on owner retirement,
        // but retains actual pending work/access/Quit ownership until return.
        try await select(["refs/heads/a-old", "refs/heads/z-new"])
        var readToken: OperationCancellation?, published = false
        model.readUnifiedComparison = { _, token in readToken = token; return try await withCheckedThrowingContinuation { held = $0 } }
        owner.presentUnified = { _, _, _ in published = true }
        model.comparePair(unified: true, alternate: true); try await wait { held != nil }
        owner.close()
        try require(readToken?.isCancelled == true && ReferenceBrowserWindowModel.activeComparisons > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired comparison lost cancellation/actual lifetime/Quit accounting")
        let reply = held; held = nil; reply?.resume(returning: expected)
        try await wait { ReferenceBrowserWindowModel.activeComparisons == 0 }
        try require(model.closed && !published && model.error == nil, "Late comparison revived a retired browser")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), finalBytes = try Data(contentsOf: file)
        try require(finalHead == head && index == finalIndex && Data("second\n".utf8) == finalBytes, "Read-only comparison/dialog entry changed HEAD/index/working bytes")
        try await cleanup()
        print("PASS: source working comparison Shift/defaults/canonical and one-shot targets, captured unified hashes, actual hidden tracking/detach mutation, Switch/Merge catalog freshness, permissions/preferences and cancelled comparison lifetime; HEAD/index/working bytes preserved")
        } catch {
            let original = error
            do { try await cleanup() } catch { throw Failure(description: "\(original); cleanup: \(error)") }
            throw original
        }
    }
}
