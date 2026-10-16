import AppKit
import SwiftUI
import TurtleGitCore

@main struct DockProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var windows: [NSWindow] = []
    @MainActor static var controllers: [NSWindowController] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Dock progress timeout at \(line)")
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); cleanup() } catch { cleanup(); fputs("Dock progress failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func cleanup() { controllers.forEach { $0.close() }; controllers = []; windows.forEach { $0.close() }; windows = []; DockProgressPresenter.shared.clear() }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Dock QA"), ("user.email", "dock@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let before = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try await repo.run(["write-tree"]).stdout
        let suite = "TurtleGit.Dock." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(0, forKey: "AutoCloseGitProgress")
        var publications: [DockProgressState?] = []
        let registry = DockProgressRegistry { publications.append($0) }, first = UUID(), second = UUID(), paused = UUID()
        registry.update(first, DockProgressState(.running, percentage: -5)); try require(registry.current?.percentage == 0, "Negative progress not clamped")
        registry.update(first, DockProgressState(.running, percentage: 40)); registry.update(second, DockProgressState(.running, percentage: 70))
        try require(registry.current == DockProgressState(.running, percentage: 40), "Concurrent progress invents an aggregate fraction")
        registry.update(paused, DockProgressState(.paused, percentage: 20)); try require(registry.current?.kind == .running, "Paused session obscures running work")
        registry.update(second, DockProgressState(.running)); try require(registry.current?.percentage == nil, "Unknown work shown as a known fraction")
        registry.update(paused, DockProgressState(.failed, percentage: 200)); try require(registry.current == DockProgressState(.failed, percentage: 100), "Retained error hidden by another command")
        registry.remove(paused); registry.remove(first); registry.remove(second)
        try require(registry.current == nil && registry.ownerCount == 0 && publications.last! == nil, "Last owner did not clear tile")
        let unchanged = publications.count; registry.remove(first); try require(publications.count == unchanged, "Duplicate retirement republished tile")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; windows.append(window)
        let attachment = DockProgressAttachment.Coordinator(registry: registry)
        attachment.update(DockProgressState(.running, percentage: 25)); try require(registry.ownerCount == 0, "Unattached view published progress")
        attachment.attach(window); try require(registry.ownerCount == 1, "Window attachment lost progress")
        window.orderOut(nil); try require(registry.ownerCount == 1, "Hidden window cleared live command")
        window.close(); try require(registry.ownerCount == 0, "Closed retained window kept stale Dock progress")
        attachment.update(DockProgressState(.failed)); attachment.attach(window); attachment.retire()
        try require(registry.ownerCount == 0, "Retired coordinator recreated progress")
        // Render the real native tile through private injected content. The process
        // never changes the installed application's Dock or shared preferences.
        let original = NSView(frame: .zero); var content: NSView? = original, redraws = 0, motion = false
        let app = URL(fileURLWithPath: CommandLine.arguments[3]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        let presenter = DockProgressPresenter(read: { content }, write: { content = $0 }, display: { redraws += 1 }, icon: { icon }, allowed: { true }, reduceMotion: { motion })
        defer { presenter.clear() }
        presenter.present(DockProgressState(.running)); try require(presenter.timer != nil && content === presenter.tile, "Indeterminate Dock animation not installed")
        try await wait { presenter.tile!.phase > 0 }
        motion = true; presenter.present(DockProgressState(.running)); try require(presenter.timer == nil, "Reduced motion retained timer")
        for (name, value) in [("running", DockProgressState(.running, percentage: 45)), ("waiting", DockProgressState(.paused, percentage: 45)), ("failed", DockProgressState(.failed, percentage: 100)), ("unknown", DockProgressState(.running))] {
            presenter.present(value); let tile = presenter.tile!
            try require(tile.accessibilityLabel() == value.accessibilityText, "Dock accessibility state lost")
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                tile.appearance = NSAppearance(named: appearance)
                guard let bitmap = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) else { throw Failure(description: "Tile bitmap unavailable") }
                tile.cacheDisplay(in: tile.bounds, to: bitmap)
                if let folder = ProcessInfo.processInfo.environment["TURTLEGIT_DOCK_CAPTURES"] {
                    let directory = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("dock-\(name)-\(suffix).png"))
                }
                try require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Dock tile is empty")
            }
        }
        presenter.clear(); try require(content === original && presenter.timer == nil && redraws > 0, "Previous custom Dock content not restored")
        presenter.present(DockProgressState(.running)); let foreign = NSView(frame: .zero); content = foreign; presenter.clear()
        try require(content === foreign, "Retiring progress overwrote another Dock owner")
        // Actual shipping Push progress views exercise observed percentage, a
        // retained error, simultaneous work, success and close (while retained).
        let owner = PushWindowModel(repository: repo, access: nil, preferences: prefs)
        defer { owner.invalidate() }
        let result = PushProgressWindowModel(options: PushOptions(), superproject: nil, preferences: prefs)
        let controller = PushProgressWindowController(owner: owner, result: result); controllers.append(controller)
        controller.window?.alphaValue = 0; controller.window?.orderFront(nil)
        try await wait { DockProgressRegistry.shared.current?.kind == .running }
        let parser = GitCliOutputParser(limit: 16384); parser.appendChunk(Data("Pushing: 45%\r".utf8)); result.consume(parser.processPending(), parser: parser)
        try await wait { DockProgressRegistry.shared.current?.percentage == 45 }
        result.complete(output: "controlled failure", success: false, cancelled: false)
        try await wait { DockProgressRegistry.shared.current?.kind == .failed }
        let next = PushProgressWindowModel(options: PushOptions(), superproject: nil, preferences: prefs)
        let nextController = PushProgressWindowController(owner: owner, result: next); controllers.append(nextController)
        nextController.window?.alphaValue = 0; nextController.window?.orderFront(nil)
        try await wait { DockProgressRegistry.shared.ownerCount == 2 }
        try require(DockProgressRegistry.shared.current?.kind == .failed, "Concurrent window hid error")
        controller.close(); try await wait { DockProgressRegistry.shared.current?.kind == .running && DockProgressRegistry.shared.ownerCount == 1 }
        next.complete(output: "done", success: true, cancelled: false)
        try await wait { DockProgressRegistry.shared.current == nil }
        nextController.close(); try require(DockProgressRegistry.shared.ownerCount == 0, "Success/close retained Dock entry")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try await repo.run(["write-tree"]).stdout
        try require(after == before && afterIndex == index, "Dock presentation mutated Git")
        print("PASS: native Dock aggregation, running/waiting/error rendering, reduced motion/timer cleanup, retained-window retirement and observed shipping progress views; unchanged HEAD/index")
    }
}
