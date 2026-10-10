import AppKit
import TurtleGitCore
import Darwin

@main struct RevisionGraphVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(line: line)
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await verify(); fflush(stdout); exit(0) }
            catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let helper = URL(fileURLWithPath: CommandLine.arguments[3])
        let suite = "TurtleGit.RevisionGraph.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Graph Test"])
        _ = try await repo.run(["config", "user.email", "graph@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let file = root.appendingPathComponent("file.txt")
        try Data("root\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Initial graph")
        _ = try await repo.run(["tag", "v1.0"])
        _ = try await repo.run(["checkout", "-b", "feature/native-graph"])
        try Data("feature\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Native graph feature\n\nTooltip body 🐢")
        _ = try await repo.run(["checkout", "main"])
        try Data("main\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Main branch")
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), bytes = try Data(contentsOf: file)
        let controller = RevisionGraphWindowController(repository: repo, access: nil, preferences: prefs, layoutExecutable: helper, automaticallyLoad: false)
        let window = controller.window!, model = controller.model
        window.alphaValue = 0; window.orderFront(nil)
        defer { window.close() }
        model.load(); try await wait { !model.busy }
        try require(model.error == nil && model.nodes.count == 3 && model.geometry?.nodes.count == 3)
        window.contentView!.layoutSubtreeIfNeeded(); controller.update()
        try require(controller.scroll.contentSize.width > 600 && controller.scroll.contentSize.height > 300)
        let geometry = model.geometry!.nodes
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let green = RevisionGraphPalette.background(.localBranch, pointer: false, preferences: prefs).usingColorSpace(.sRGB)!
            assert(abs(green.greenComponent - 195.0/255) < 0.001 && green.redComponent == 0)
            assert(RevisionGraphPalette.foreground(green) == NSColor.white)
            prefs.set(true, forKey: "Graph.RevGraphUseLocalForCur")
            assert(RevisionGraphPalette.background(.currentBranch, pointer: false, preferences: prefs).usingColorSpace(.sRGB)! == green)
            prefs.removeObject(forKey: "Graph.RevGraphUseLocalForCur")
        }
        func click(_ index: Int, modifiers: NSEvent.ModifierFlags = []) {
            let rect = geometry[index].rect
            let point = NSPoint(x: rect.midX * model.zoom + 10, y: rect.midY * model.zoom + 10)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: controller.canvas.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            controller.canvas.mouseDown(with: event)
        }
        click(0); try require(model.selection == [geometry[0].hash])
        let menu = controller.nodeMenu()
        try require(menu.items.first { $0.title == "Show Log" }?.image != nil)
        var routed = false; model.onLog = { _ in routed = true }; controller.perform("log"); try require(routed)
        let center = NSPoint(x: geometry[0].rect.midX + 10, y: geometry[0].rect.midY + 10)
        let tip = controller.canvas.view(controller.canvas, stringForToolTip: 0, point: center, userData: nil)
        try require(tip.contains(geometry[0].hash) && tip.contains("Graph Test"))
        click(1, modifiers: .command); try require(model.selection == [geometry[0].hash, geometry[1].hash])
        var compared = false; model.onCompare = { _, _ in compared = true }
        let compare = controller.nodeMenu().items.first { $0.title == "Compare revisions" }!
        try require(controller.validateMenuItem(compare) && compare.image != nil)
        controller.perform("compare"); try require(compared)
        controller.perform("zoomOut"); try require(abs(model.zoom - 0.9) < 0.0001)
        controller.perform("zoom100"); controller.perform("overview"); try require(model.zoom == 1 && model.showOverview)
        func capture(_ target: NSWindow, prefix: String) async throws {
            guard CommandLine.arguments.count > 4 else { return }
            let directory = URL(fileURLWithPath: CommandLine.arguments[4])
            target.orderOut(nil); target.alphaValue = 1
            defer { target.alphaValue = 0; target.orderFront(nil) }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                target.appearance = NSAppearance(named: appearance); target.makeFirstResponder(nil)
                target.contentView!.layoutSubtreeIfNeeded(); target.contentView!.needsDisplay = true
                try await Task.sleep(nanoseconds: 200_000_000)
                let view = target.contentView!, bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                target.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(prefix + "-" + name + ".png"))
            }
            target.appearance = NSAppearance(named: .aqua)
        }
        try await capture(window, prefix: "revision-graph")
        controller.showFilter(); try await wait { window.attachedSheet != nil }
        let child = window.attachedSheet!; try require(child.alphaValue == 0)
        try await capture(child, prefix: "revision-graph-filter")
        let buttons = views(child.contentView!).compactMap { $0 as? NSButton }
        let current = buttons.first { $0.title == "Only Current Branch" }!, local = buttons.first { $0.title == "Only Local Branches" }!
        let to = views(child.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "To revision" }!
        current.performClick(nil); try require(current.state == .on && local.state == .off && !to.isEnabled)
        local.performClick(nil); try require(current.state == .off && local.state == .on && !to.isEnabled)
        local.performClick(nil); try require(to.isEnabled)
        try require(!controller.windowShouldClose(window))
        buttons.first { $0.title == "Cancel" }!.performClick(nil); try await wait { window.attachedSheet == nil }
        try require(!model.options.onlyCurrentBranch && !model.options.onlyLocalBranches)
        model.options.from = "v1.0"; model.options.onlyCurrentBranch = true
        controller.showFilter(); try await wait { window.attachedSheet != nil }
        let resetSheet = window.attachedSheet!; resetSheet.alphaValue = 0
        views(resetSheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Reset filter" }!.performClick(nil)
        try await wait { window.attachedSheet == nil && !model.busy }
        try require(model.options.from.isEmpty && !model.options.onlyCurrentBranch && model.nodes.count == 3)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterBytes = try Data(contentsOf: file)
        try require(head == afterHead && refs == afterRefs && index == afterIndex && config == afterConfig && bytes == afterBytes)
        model.load(); try require(model.busy)
        var closed = false; controller.onClosed = { closed = true }
        window.performClose(nil); try await wait { closed }
        try require(model.closed && !model.busy)
        model.load(); try require(!model.busy)
        print("PASS: Native Revision Graph selection, routing, zoom, tooltip, filter scopes, Reset, cancellation and repository invariants")
    }
}
