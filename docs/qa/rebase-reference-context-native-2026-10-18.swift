// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum RebaseReferenceContextVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2400 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Rebase reference context did not settle at \(line)")
    }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
    static func click(_ item: NSMenuItem?) throws {
        guard let item, item.isEnabled, let action = item.action else { throw Failure(description: "Missing enabled menu action") }
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }
    static func paint(_ field: LogReferenceTextField) throws {
        guard let painter = field.referenceCell else { throw Failure(description: "Missing shared reference painter") }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(field.bounds.width.rounded(.up))), pixelsHigh: max(1, Int(field.bounds.height.rounded(.up))), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        painter.drawInterior(withFrame: field.bounds, in: field)
    }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Rebase References QA"), ("user.email", "refs@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        var hashes: [String] = []
        for number in 0..<3 {
            try Data("line \(number)\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
            _ = try await repo.commit(message: "Reference commit \(number)"); hashes.append(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines))
        }
        let middle = hashes[1]
        for name in ["refs/heads/alpha", "refs/heads/beta", "refs/remotes/origin/topic", "refs/remotes/upstream/topic", "refs/tags/v2"] { _ = try await repo.run(["update-ref", name, middle]) }
        _ = try await repo.run(["tag", "-a", "v1", "-m", "Annotated QA", middle])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.RebaseReferenceContext." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!, clipboard = NSPasteboard.withUniqueName()
        preferences.set(false, forKey: "Gravatar")
        let owner = RebaseWindowController(repository: repo, access: nil, preferences: preferences), model = owner.model, window = owner.window!, log = model.revisionMenuLog
        var comparison: FileComparisonWindowController?
        defer { comparison?.close(); owner.close(); clipboard.releaseGlobally(); preferences.removePersistentDomain(forName: suite) }
        do {
            window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -2400, y: -2400)); window.orderFront(nil); log.clipboard = clipboard
            model.load(cherryPick: hashes)
            try await wait { !model.busy && !model.loadingPlan && model.entries.count == 3 && RebaseWindowModel.activeColumnReads == 0 && model.revisionReferenceNames[middle]?.contains("refs/tags/v1^{}") == true }
            var native: RebaseReplayNativeTable?
            try await wait { native = views(window.contentView!).compactMap { $0 as? RebaseReplayNativeTable }.first; return native?.numberOfRows == 3 }
            let table = native!, coordinator = table.owner!, row = model.entries.firstIndex { $0.commit.hash == middle }!, id = model.entries[row].id
            func select(_ ids: Set<String>) async throws {
                model.selection = ids
                try await wait { table.selectedRowIndexes == IndexSet(model.entries.indices.filter { ids.contains(model.entries[$0].id) }) && RebaseWindowModel.activePreparationReads == 0 && !model.revisionFiles.busy }
            }
            try await select([id])
            let column = table.column(withIdentifier: .init("Message")); table.tableColumns[column].width = 1600; table.layoutSubtreeIfNeeded()
            guard let field = (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField as? LogReferenceTextField else { throw Failure(description: "Rebase did not render shared native ref labels") }
            try paint(field)
            guard let frame = field.referenceCell?.badgeFrames.first(where: { $0.name == "refs/tags/v1" }) else { throw Failure(description: "Annotated tag badge missing") }
            try require(frame.style.pointed && frame.style.color != NSColor.clear, "Annotated tag shape/color missing")
            let point = table.convert(NSPoint(x: frame.rect.midX, y: frame.rect.midY), from: field)
            try require(table.reference(at: point)?.name == "refs/tags/v1", "Native ref hit lost canonical full name")
            var presented: NSMenu?
            table.presentContextMenu = { menu, _, _ in presented = menu }
            try require(table.showReferenceContextMenu(row: row, name: "refs/tags/v1", point: point), "Reference accessibility/context path failed")
            try require(presented?.item(withTitle: "Push \"v1\"…")?.image != nil, "Pointed Push caption/source icon missing")
            var pushes: [(String, Bool)] = [], creates: [(Bool, String)] = [], switches: [String] = [], pulls = 0
            log.onHistoryPush = { pushes.append(($0, $1)) }; log.onCreateReference = { creates.append(($0, $1)) }; log.onSwitchBranch = { switches.append($0) }; log.onHistoryPull = { pulls += 1 }
            let tag = LogReferenceMenuTarget(hash: middle, name: "refs/tags/v1"), remote = LogReferenceMenuTarget(hash: middle, name: "refs/remotes/upstream/topic"), branch = LogReferenceMenuTarget(hash: middle, name: "refs/heads/beta")
            func menu(_ target: LogReferenceMenuTarget? = nil, extended: Bool = false) -> NSMenu { coordinator.menu(ids: [id], alternate: extended, pointed: target) }
            let ordered = menu().items.map(\.title)
            try require(ordered.firstIndex(of: "Create branch at this version…")! < ordered.firstIndex(of: "Export this version…")! && ordered.firstIndex(of: "Export this version…")! < ordered.firstIndex(of: "Format Patch…")! && ordered.firstIndex(of: "Format Patch…")! < ordered.firstIndex(of: "Push…")!, "Source reference/patch/Push insertion order changed")
            try require(menu().item(withTitle: "Delete branch/tag")?.submenu?.item(withTitle: "All")?.image != nil, "Source Delete All submenu/icon missing")
            log.onBisect = { _ in }
            try require(menu().item(withTitle: "Bisect good") == nil, "Inactive Bisect leaked marking commands")
            log.bisectActive = true
            try require(menu().item(withTitle: "Bisect good")?.isEnabled == true && menu().item(withTitle: "Bisect bad")?.image != nil && menu().item(withTitle: "Bisect skip") != nil, "Active Bisect source commands/icons missing")
            log.bisectActive = false
            let pushed = menu(tag).item(withTitle: "Push \"v1\"…")!; try click(pushed); try click(pushed)
            try require(pushes.count == 1 && pushes[0].0 == "refs/tags/v1" && !pushes[0].1, "Pointed Push lost peeled tag/one-shot/all-branches semantics")
            try click(menu().item(withTitle: "Push…")); try require(pushes.last?.0 == "refs/heads/alpha" && pushes.last?.1 == true, "Unpointed Push did not guess first local branch/preserve All branches")
            try click(menu(remote).item(withTitle: "Create branch at this version…")); try require(creates.last?.0 == false && creates.last?.1 == remote.name, "Pointed remote branch guess lost canonical identity")
            try click(menu(branch).item(withTitle: "Create branch at this version…")); try require(creates.last?.1 == branch.name, "Pointed local branch was replaced by a remote guess")
            try click(menu(tag).item(withTitle: "Create tag at this version…")); try require(creates.last?.0 == true && creates.last?.1 == "refs/remotes/origin/topic", "Tag did not use source first-remote guess")
            try click(menu(branch).item(withTitle: "Switch branch \"beta\"")); try require(switches == [branch.name], "Pointed Switch branch lost full name")
            try require(menu(remote).item(withTitle: "Switch branch") == nil && menu(remote).item(withTitle: "Switch branch \"alpha\"") == nil, "Remote badge incorrectly offered local Switch alternatives")
            try click(items(menu(tag)).first { $0.title == "Tag/branch names" }); try require(clipboard.string(forType: .string) == "v1", "Pointed tag copy did not use short source caption")
            try click(items(menu()).first { $0.title == "Tag/branch names" }); try require(clipboard.string(forType: .string)?.contains("refs/heads/alpha\r\n") == true, "Unpointed copy omitted full reference names")
            let stale = menu(branch).item(withTitle: "Create branch at this version…")!, count = creates.count
            model.refreshRevisionHistoryContext(); try await wait { RebaseWindowModel.activeColumnReads == 0 && !model.loadingColumnMetadata }
            try click(stale); try require(creates.count == count, "Old popup survived reference context refresh")
            // Current branch is excluded from Switch/Delete; HEAD-only Pull uses its source gate.
            let headID = model.entries.first { $0.commit.hash == hashes[2] }!.id
            try await select([headID]); let headMenu = coordinator.menu(ids: [headID], alternate: false)
            try require(!items(headMenu).contains { $0.title == "Delete refs/heads/main" || $0.title == "Switch branch \"main\"" }, "Current branch leaked into mutation menus")
            try click(headMenu.item(withTitle: "Pull…")); try require(pulls == 1, "HEAD Pull did not use shared transport callback")
            let plainID = model.entries.first { $0.commit.hash == hashes[0] }!.id
            try await select([plainID])
            try require(coordinator.menu(ids: [plainID], alternate: false).item(withTitle: "Push…") == nil && coordinator.menu(ids: [plainID], alternate: true).item(withTitle: "Push…") != nil, "Hash-only Push ignored source extended-menu gate")
            // Shared change-set operation produces the actual viewer model with inherited preferences.
            let pair: Set<String> = [id, headID]; try await select(pair)
            log.onCommitChangeSets = { snapshot in comparison = FileComparisonWindowController(repository: repo, access: nil, changeSets: snapshot, preferences: preferences); comparison?.window?.alphaValue = 0 }
            try click(coordinator.menu(ids: pair, alternate: false).item(withTitle: "Compare change sets"))
            try require(log.busy, "Change-set menu did not start an owned operation")
            do { try await wait { comparison != nil && !log.busy } }
            catch { throw Failure(description: "Change-set handoff failed: busy=\(log.busy), entries=\(log.revisions.count), selected=\(log.selected.count), occurrences=\(log.occurrenceSelectionCount), error=\(log.error ?? "none"); \(error)") }
            try require(comparison?.model.comparisonDefaults === preferences, "Change-set viewer lost inherited preferences")
            comparison?.close(); comparison = nil
            var compared: (ComparisonRevision, ComparisonRevision)?
            log.onCompare = { compared = ($0, $1) }
            let all = Set(model.entries.map(\.id)); try await select(all)
            try click(coordinator.menu(ids: all, alternate: false).item(withTitle: "Compare revisions"))
            try require(compared?.0 == .revision(model.entries.last!.commit.hash) && compared?.1 == .revision(model.entries[0].commit.hash), "Contiguous occurrence Compare lost source endpoints")
            // Exercise real deletion/confirmation, refresh and old-menu invalidation in this private repository.
            try await select([id]); let deletedMenu = menu(branch), deletion = deletedMenu.item(withTitle: "Delete refs/heads/beta")!
            try click(deletion); try await wait { window.attachedSheet != nil }
            try require(model.revisionHistoryBlocked && !model.editable && !owner.windowShouldClose(window) && window.attachedSheet?.alphaValue == 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Owned reference question did not block parent/Close/Quit or became visible")
            let sheet = window.attachedSheet!, confirm = views(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Delete" }!
            confirm.performClick(nil)
            try await wait { !log.busy && !model.loadingColumnMetadata && RebaseWindowModel.activeColumnReads == 0 && model.revisionReferenceNames[middle]?.contains(branch.name) == false }
            try require(!model.revisionDeletionCandidates([id], target: nil).contains { $0.name == branch.name }, "Deleted reference survived owned metadata refresh")
            try click(deletion); try require(!log.busy, "Consumed deletion menu was reused")
            // Rebase rows have occurrence identity even when their hashes match.
            // Both shared actions must retain the two selected displayed entries.
            model.plan = try await repo.addingRebaseCommits(model.plan!, revisions: [middle])
            try await wait { table.numberOfRows == 4 }
            let repeated = Set(model.entries.filter { $0.commit.hash == middle }.map(\.id))
            try require(repeated.count == 2, "Fixture needs two distinct occurrences of one commit")
            try await select(repeated)
            try click(coordinator.menu(ids: repeated, alternate: false).item(withTitle: "Compare change sets"))
            try await wait { comparison != nil && !log.busy }
            try require(log.embeddedSelectionCount == 2 && log.selected.count == 1 && comparison?.model.snapshot.from == .revision(middle) && comparison?.model.snapshot.to == .revision(middle), "Change-set dispatch collapsed repeated occurrences")
            comparison?.close(); comparison = nil
            var bisects: [LogBisectRequest] = []; log.onBisect = { bisects.append($0) }
            try click(coordinator.menu(ids: repeated, alternate: false).item(withTitle: "Bisect start…"))
            try await wait { !log.busy && !bisects.isEmpty }
            try require(bisects.count == 1 && bisects[0].good == "refs/heads/alpha" && bisects[0].bad == "refs/heads/alpha", "Bisect preparation collapsed equal-hash occurrences or changed source presets")
            let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
            try require(head == finalHead && index == finalIndex, "Reference context actions changed HEAD/index")
            owner.close()
            try await wait { RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 && LogWindowModel.activeHistoryDeletions == 0 && LogWindowModel.activeHistoryLoads == 0 }
            print("PASS: Rebase painted reference targets, source menu gates/order/icons, remote guessing, canonical Push/Switch/copy, one-shot stale receipts, change sets and owned hidden deletion/refresh/Close/Quit; HEAD/index preserved")
        } catch {
            owner.close(); comparison?.close()
            try? await wait { RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 && LogWindowModel.activeHistoryDeletions == 0 && LogWindowModel.activeHistoryLoads == 0 }
            throw error
        }
    }
}
