// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

struct SubmodulePathIdentityVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners = [NSWindowController]()
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<1800 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Submodule identity wait at line \(line)")
    }
    @MainActor static func cleanup() async {
        owners.forEach { $0.close() }; owners = []
        for _ in 0..<1800 { if SubmoduleUpdateWindowModel.activeReads == 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func capture(_ window: NSWindow, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["TURTLEGIT_SUBMODULE_SOURCE_CAPTURE"] else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Owned capture API unavailable") }
        window.alphaValue = 1; window.orderFront(nil); defer { window.alphaValue = 0 }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Own submodule window missing") }
            let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + "-" + suffix + ".png"))
            print("Captured \(name)-\(suffix): \(config.width)x\(config.height)")
        }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: engine)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Submodule Identity QA"), ("user.email", "identity@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, oid = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines)
        let names = ["café/module", "cafe\u{301}/module"]
        for name in names { _ = try await repo.run(["-c", "core.precomposeunicode=false", "update-index", "--add", "--cacheinfo", "160000," + oid + "," + name]) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.SubmoduleIdentity." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let controller = SubmoduleUpdateWindowController(repository: repo, access: nil, scope: [], preferences: prefs), model = controller.model
        owners.append(controller); controller.window!.alphaValue = 0; controller.window!.orderFront(nil)
        var submissions = [[String]](); model.onSubmit = { paths, _ in submissions.append(paths) }; model.load()
        try await wait { !model.busy && model.paths.count == 2 }
        try require(model.selection.count == 2, "Initial exact selection collapsed equivalent paths")
        guard let table = views(controller.window!.contentView!).compactMap({ $0 as? SubmoduleUpdatePathTable }).first else { throw Failure(description: "Submodule path table missing") }
        try await wait { table.paths.count == 2 && table.selectedRowIndexes.count == 2 }
        let namesBefore = table.paths
        let point = table.convert(.init(x: table.rect(ofRow: 0).minX + 8, y: table.rect(ofRow: 0).midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        table.mouseDown(with: event)
        try await wait { model.selection.count == 1 && table.selectedRowIndexes.count == 1 }
        try require(model.selection == [GitReferenceName(namesBefore[1])], "Click deselected both equivalent names")
        let cell = table.tableView(table, viewFor: table.tableColumns[0], row: 0) as! NSTextField
        try require(cell.toolTip?.contains("UTF-8:") == true && cell.accessibilityLabel()?.contains("UTF-8:") == true, "Ambiguous spellings cannot be distinguished")
        table.configure(paths: Array(namesBefore.reversed()), selection: model.selection)
        try require(GitReferenceName.equal(table.paths[table.focusedRow], namesBefore[0]), "Exact focused path moved to equivalent sibling")
        table.configure(paths: model.paths, selection: model.selection)
        model.selectAll(); model.selectAll()
        try await wait { model.selection.count == 2 && table.selectedRowIndexes.count == 2 }
        try await capture(controller.window!, name: "submodule-update-identities")
        model.apply(); model.apply()
        try require(submissions.count == 1 && Set(submissions[0].map { GitReferenceName($0) }).count == 2, "Submission collapsed names or duplicated")
        let restored = SubmoduleUpdateWindowModel(repository: repo, access: nil, scope: [], selected: [], preferences: prefs)
        restored.onSubmit = { _, _ in }; restored.load(); try await wait { !restored.busy && restored.paths.count == 2 }; defer { restored.invalidate() }
        try require(restored.selection.count == 2, "Exact private saved selection collapsed")
        let add = SubmoduleAddWindowController(repository: repo, access: nil, preferences: prefs, clipboardText: "https://example.invalid/library.git")
        owners.append(add); add.model.useBranch = true; add.model.branch = "feature/Unicode"; add.model.sourceEndedEditing(); add.model.onSubmit = { _ in }
        add.window!.alphaValue = 0; add.window!.orderFront(nil); add.window!.contentView?.layoutSubtreeIfNeeded()
        try await capture(add.window!, name: "submodule-add-source-options")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require((try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index && afterHead == head, "Options/catalog changed index or HEAD")
    }
}
