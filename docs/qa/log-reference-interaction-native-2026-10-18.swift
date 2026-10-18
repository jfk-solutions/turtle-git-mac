// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

enum LogReferenceInteractionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2400 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Reference interaction timeout at \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func paint(_ field: LogReferenceTextField) throws {
        guard let cell = field.referenceCell else { throw Failure(description: "Reference painter missing") }
        let width = max(1, Int(ceil(field.bounds.width))), height = max(1, Int(ceil(field.bounds.height)))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        cell.drawInterior(withFrame: field.bounds, in: field)
    }
    @MainActor static func allItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (name, value) in [("user.name", "Reference QA"), ("user.email", "reference@example.invalid"), ("commit.gpgsign", "false")] { _ = try await repo.run(["config", name, value]) }
        let file = root.appendingPathComponent("file"); try Data("unchanged\n".utf8).write(to: file)
        try await repo.stage(["file"]); _ = try await repo.commit(message: "Reference subject\n\nbody")
        _ = try await repo.run(["config", "branch.main.description", "Main description\nsecond line"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), original = try Data(contentsOf: file)
        let suite = "TurtleGit.LogReferenceInteraction." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!, clipboard = NSPasteboard.withUniqueName()
        prefs.set(false, forKey: "Gravatar"); prefs.set(false, forKey: "LogIncludeWorkingTreeChanges")
        let owner = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false), model = owner.model, window = owner.window!
        var held: CheckedContinuation<[GitReferenceName: String], Error>?, token: OperationCancellation?
        defer { held?.resume(throwing: OperationCancellationFailure.cancelled); owner.close(); prefs.removePersistentDomain(forName: suite); clipboard.releaseGlobally() }
        do {
        window.alphaValue = 0; window.orderFront(nil); model.clipboard = clipboard
        try await wait { window.contentView?.layoutSubtreeIfNeeded(); return !model.busy && model.entries.count == 1 && views(window.contentView!).contains { $0 is HistoryTableView } }
        let table = views(window.contentView!).compactMap { $0 as? HistoryTableView }.first!
        model.select([model.entries[0].hash]); try await wait { !model.busy && !model.files.isEmpty }
        let column = table.column(withIdentifier: .init("message"))
        table.tableColumns[column].width = 900; table.layoutSubtreeIfNeeded()
        guard var field = (table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField as? LogReferenceTextField else { throw Failure(description: "Production reference text field missing") }
        try paint(field)
        guard let frame = field.referenceCell?.badgeFrames.first(where: { $0.name == "refs/heads/main" }) else { throw Failure(description: "Visible local badge missing") }
        var point = NSPoint(x: frame.rect.midX, y: frame.rect.midY)
        try require(field.tooltip(at: point) == "Description:\nMain description\nsecond line", "Local badge did not prefer multiline description")
        try require(field.tooltip(at: NSPoint(x: field.bounds.maxX - 2, y: point.y)) == "Reference subject", "Subject fallback changed outside label")
        // A config edit is refreshed on hover without changing history/selection.
        try await wait { LogWindowModel.activeReferenceReads == 0 }
        _ = try await repo.run(["config", "branch.main.description", "Updated description"])
        model.hoverReference(hash: model.entries[0].hash, name: nil)
        field.updateHover(at: point)
        try await wait { model.referenceDescriptions["refs/heads/main"] == "Updated description" && LogWindowModel.activeReferenceReads == 0 }
        // The published metadata may trigger a native layout/reuse pass. New
        // size/text correctly retires its old paint map before the next draw;
        // exercise the currently displayed field after that actual layout.
        window.contentView?.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
        guard let currentField = (table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField as? LogReferenceTextField else { throw Failure(description: "Updated reference field missing") }
        field = currentField; try paint(field)
        guard let updatedFrame = field.referenceCell?.badgeFrames.first(where: { $0.name == "refs/heads/main" }) else { throw Failure(description: "Updated local paint geometry missing") }
        point = NSPoint(x: updatedFrame.rect.midX, y: updatedFrame.rect.midY)
        let updatedTooltip = field.tooltip(at: point)
        try require(updatedTooltip == "Description:\nUpdated description", "Hover read did not update description; tooltip=\(String(describing: updatedTooltip)), model=\(String(describing: model.referenceDescriptions["refs/heads/main"])), attached=\(field.window === window), badges=\(field.referenceCell?.badgeFrames.count ?? -1)")
        try await wait { LogWindowModel.activeReferenceReads == 0 }
        let children = field.accessibilityChildren()?.compactMap { $0 as? LogReferenceAccessibleBadge } ?? []
        guard let badge = children.first(where: { $0.name == "refs/heads/main" }) else { throw Failure(description: "Accessible canonical badge missing") }
        try require(badge.isAccessibilityEnabled() && badge.accessibilityValue() as? String == "refs/heads/main" && !badge.accessibilityFrame().isEmpty, "Accessible badge lost canonical identity/frame")
        var captured: NSMenu?
        table.presentContextMenu = { menu, _, _ in captured = menu }
        let acceptedMenu = badge.accessibilityPerformShowMenu()
        try require(acceptedMenu && table.contextReference?.name == "refs/heads/main", "Accessible badge did not target pointed native context; accepted=\(acceptedMenu), context=\(String(describing: table.contextReference)), items=\(captured?.items.count ?? -1), allowed=\(table.contextMenuAvailable()), enabled=\(badge.isAccessibilityEnabled())")
        guard let copy = captured.flatMap({ allItems($0).first { $0.title == "Tag/branch names" } }), let action = copy.action else { throw Failure(description: "Pointed source reference clipboard action missing") }
        _ = NSApp.sendAction(action, to: copy.target, from: copy)
        try require(clipboard.string(forType: .string) == "main", "Accessible context copied a display label or row background instead of canonical ref")
        model.busy = true; try require(!badge.accessibilityPerformPress(), "Busy accessible badge action executed"); model.busy = false
        // New attributes retire the old paint hit map immediately, before redraw.
        let attributed = field.attributedStringValue
        field.attributedStringValue = attributed
        try require(field.referenceCell?.badgeFrames.isEmpty == true && !badge.accessibilityPerformPress(), "Old paint/AX geometry survived a new document assignment")
        try paint(field)
        let fresh = field.accessibilityChildren()?.compactMap { $0 as? LogReferenceAccessibleBadge } ?? []
        try require(fresh.first?.isAccessibilityEnabled() == true && !badge.isAccessibilityEnabled(), "New paint failed to replace stale accessible generation")
        // Hold a noncooperative description read through retirement; the counter
        // and scope stay owned until its actual reply, with no late publication.
        model.hoverReference(hash: model.entries[0].hash, name: nil)
        model.readReferenceDescriptions = { cancellation in token = cancellation; return try await withCheckedThrowingContinuation { held = $0 } }
        model.hoverReference(hash: model.entries[0].hash, name: "refs/heads/main")
        try await wait { held != nil && LogWindowModel.activeReferenceReads > 0 }
        let before = model.referenceDescriptions
        owner.close()
        try require(token?.isCancelled == true && LogWindowModel.activeReferenceReads > 0, "Retired hover lost cancellation or pending ownership")
        held?.resume(returning: ["refs/heads/main": "late"]); held = nil
        try await wait { LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeActionReads == 0 }
        try require(model.referenceDescriptions == before && fresh.allSatisfy { !$0.isAccessibilityEnabled() && !$0.accessibilityPerformShowMenu() }, "Retired hover or AX callback published late state")
        try require((try await repo.run(["rev-parse", "HEAD"]).stdout) == head, "Read-only reference interactions changed HEAD")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: file) == original, "Reference interactions changed index/input")
        print("PASS: native local branch descriptions, source fallback, fresh owned hover, canonical accessible context, stale geometry retirement and actual read drain")
        } catch {
            held?.resume(throwing: OperationCancellationFailure.cancelled); held = nil
            owner.close()
            try? await wait { LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeActionReads == 0 }
            throw error
        }
    }
}
