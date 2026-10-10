import AppKit
import ImageIO
import PDFKit
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
        _ = try await repo.run(["config", "tag.gpgsign", "false"])
        let file = root.appendingPathComponent("file.txt")
        try Data("root\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Initial graph")
        _ = try await repo.run(["tag", "v1.0"])
        _ = try await repo.run(["tag", "-a", "release-v1", "-m", "Annotated root"])
        _ = try await repo.run(["checkout", "-b", "feature/native-graph"])
        try Data("feature\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Native graph feature\n\nTooltip body 🐢")
        _ = try await repo.run(["branch", "feature/alias-one"])
        _ = try await repo.run(["branch", "feature/alias-two"])
        _ = try await repo.run(["checkout", "main"])
        try Data("main\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Main branch")
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try await repo.run(["tag", "export<&\"'>"])
        _ = try await repo.run(["tag", "main"])
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
        click(0); try require(model.selection.isEmpty) // Plain click toggles the first node.
        click(0); click(1, modifiers: .control)
        click(0, modifiers: .control); try require(model.selection == [geometry[1].hash])
        click(2, modifiers: .command); click(0, modifiers: .command)
        try require(model.selection == [geometry[1].hash, geometry[0].hash])
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: controller.canvas.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        }
        let third = NSPoint(x: geometry[2].rect.midX + 10, y: geometry[2].rect.midY + 10)
        try require(controller.canvas.menu(for: mouse(.rightMouseDown, third)) == nil)
        try require(model.selection == [geometry[1].hash, geometry[0].hash])
        let blank = NSPoint(x: 1, y: 1)
        controller.canvas.mouseDown(with: mouse(.leftMouseDown, blank, modifiers: .control))
        try require(model.selection.count == 2)
        controller.canvas.mouseDown(with: mouse(.leftMouseDown, blank))
        try require(model.selection.isEmpty)
        controller.canvas.mouseUp(with: mouse(.leftMouseUp, blank))
        let scroll = controller.canvas.enclosingScrollView!, clip = scroll.contentView
        let originalSize = controller.canvas.frame.size
        let down = mouse(.leftMouseDown, blank)
        controller.canvas.mouseDown(with: down)
        // Selection redraw restores the real graph size. Enlarge only after
        // mouse-down to provide scrollable space for this small graph fixture.
        controller.canvas.setFrameSize(NSSize(width: originalSize.width + 1000, height: originalSize.height + 1000))
        clip.scroll(to: NSPoint(x: 100, y: 100)); scroll.reflectScrolledClipView(clip)
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: down.locationInWindow.x - 30, y: down.locationInWindow.y + 40), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        controller.canvas.mouseDragged(with: drag)
        try require(abs(clip.bounds.minX - 130) < 1 && abs(clip.bounds.minY - 140) < 1)
        controller.canvas.mouseUp(with: drag)
        controller.canvas.mouseDragged(with: down); try require(abs(clip.bounds.minX - 130) < 1)
        controller.canvas.setFrameSize(originalSize); clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        func wheel(_ delta: Int32, flags: CGEventFlags) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
            cg.flags = flags; return NSEvent(cgEvent: cg)!
        }
        controller.canvas.scrollWheel(with: wheel(-1, flags: .maskControl)); try require(abs(model.zoom - 0.9) < 0.0001)
        controller.canvas.scrollWheel(with: wheel(1, flags: .maskCommand)); try require(abs(model.zoom - 1) < 0.0001)
        print("PASS: Revision Graph mouse selection, pair menu rejection, drag pan and modifier-wheel zoom")
        model.select(nil, extending: false)

        // Menus derive reference-specific actions from the selected graph node.
        let feature = model.nodes.first { $0.references.contains { $0.name == "refs/heads/feature/native-graph" } }!
        model.select(feature.hash, extending: false)
        let switches = controller.nodeMenu().items.first { $0.title == "Switch to branch" }!.submenu!
        try require(switches.items.count == 3 && switches.items.allSatisfy { $0.image != nil && controller.validateMenuItem($0) })
        let switchItem = switches.items.first!
        var switched = ""; model.onSwitchBranch = { switched = $0 }
        try require(NSApp.sendAction(switchItem.action!, to: switchItem.target, from: switchItem) && switched.hasPrefix("refs/heads/feature/"))
        let rootNode = model.nodes.first { $0.references.contains { $0.name == "refs/tags/v1.0" } }!
        model.select(rootNode.hash, extending: false)
        let checkout = controller.nodeMenu().items.first { $0.title == "Switch/Checkout to this…" }!
        var checkedOut = ""; model.onCheckout = { checkedOut = $0 }
        try require(NSApp.sendAction(checkout.action!, to: checkout.target, from: checkout) && checkedOut == "refs/tags/v1.0")
        try require(!controller.validateMenuItem(switchItem)) // Retained menu cannot act on a different node.
        let main = model.nodes.first { $0.references.contains { $0.isCurrent } }!
        model.select(main.hash, extending: false)
        let deleteMenu = controller.nodeMenu().items.first { $0.title == "Delete branch/tag" }!.submenu!
        try require(deleteMenu.items.last!.title == "All" && !deleteMenu.items.contains { $0.title == "refs/heads/main" || $0.title == "refs/tags/main" })
        try require(!controller.nodeMenu().items.contains { $0.title == "Reset…" || $0.title == "Create branch…" || $0.title == "Copy hash" })
        var copied = ""; model.copyReferences = { copied = $0 }; controller.perform("copyRefs")
        try require(copied == main.references.map(\.name).joined(separator: "\n"))
        model.select(nil, extending: false); click(0)
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
        var range: HistoryRevisionRange?; model.onLogRange = { range = $0 }
        controller.perform("log"); try require(range == HistoryRevisionRange(from: geometry[0].hash, to: geometry[1].hash))
        try require(controller.nodeMenu().items.map(\.title) == ["Show Log", "Compare revisions", "Unified diff"])
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
        controller.requestRepositoryRefresh(); try require(!model.busy)
        let buttons = views(child.contentView!).compactMap { $0 as? NSButton }
        let current = buttons.first { $0.title == "Only Current Branch" }!, local = buttons.first { $0.title == "Only Local Branches" }!
        let to = views(child.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "To revision" }!
        current.performClick(nil); try require(current.state == .on && local.state == .off && !to.isEnabled)
        local.performClick(nil); try require(current.state == .off && local.state == .on && !to.isEnabled)
        local.performClick(nil); try require(to.isEnabled)
        try require(!controller.windowShouldClose(window))
        buttons.first { $0.title == "Cancel" }!.performClick(nil); try await wait { window.attachedSheet == nil && !model.busy }
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
        // Export actual data in every encoding, with scroll-independent extent.
        let picker = RevisionGraphSavePanel()
        try require(picker.format == .svg && picker.panel.nameFieldStringValue.hasSuffix(".svg"))
        model.zoom = 0.5; controller.update()
        let selection = model.selection, frame = controller.canvas.frame
        for (index, format) in RevisionGraphFormat.allCases.enumerated() {
            picker.formats.selectItem(at: index)
            try require(NSApp.sendAction(picker.formats.action!, to: picker.formats.target, from: picker.formats))
            try require(picker.format == format && picker.panel.nameFieldStringValue.hasSuffix("." + format.fileExtension))
            let data = try RevisionGraphExport.data(canvas: controller.canvas, viewport: controller.scroll.contentSize, format: format, appearance: NSAppearance(named: .aqua)!)
            let expected = try RevisionGraphExport.size(canvas: controller.canvas, viewport: controller.scroll.contentSize, format: format)
            if format == .svg {
                try require(XMLParser(data: data).parse())
                let text = String(decoding: data, as: UTF8.self)
                try require(text.contains("font-family=\"Helvetica\"") && text.contains("&lt;&amp;&quot;&apos;&gt;") && text.contains("<polyline") && !text.contains("<image"))
            } else if format == .graphviz {
                let text = String(decoding: data, as: UTF8.self)
                try require(text.contains("rankdir=BT") && text.contains("&lt;&amp;&quot;&apos;&gt;"))
                for edge in model.geometry!.edges { try require(text.contains("g" + edge.targetHash + " -> g" + edge.sourceHash)) }
            } else if format == .pdf {
                let pdf = PDFDocument(data: data)!
                try require(pdf.pageCount == 1 && abs(pdf.page(at: 0)!.bounds(for: .mediaBox).width - expected.width) < 0.1)
            } else {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(line: #line) }
                try require(CGImageSourceGetType(source) as String? == format.contentType.identifier)
                try require(image.width == Int(expected.width) && image.height == Int(expected.height))
            }
            try require(model.zoom == 0.5 && model.selection == selection && controller.canvas.frame == frame)
            if CommandLine.arguments.count > 4 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[4]).appendingPathComponent("graph-export." + format.fileExtension)) }
        }
        try require(RevisionGraphExport.xml("雪<&\"'>") == "雪&lt;&amp;&quot;&apos;&gt;")
        print("PASS: Revision Graph SVG/Graphviz/PDF/PNG/JPEG/BMP/GIF encodings, escaped refs, native format control, extents and unchanged view state")
        // Destructive checks touch only this disposable repository, after the read-only invariants above.
        func itemDeleting(_ name: String) throws -> NSMenuItem {
            let menu = controller.nodeMenu()
            for item in menu.items.flatMap({ [$0] + ($0.submenu?.items ?? []) }) {
                if let command = item.representedObject as? RevisionGraphReferenceCommand, case .delete(let names, _) = command, names == [name] { return item }
            }
            throw Failure(line: #line)
        }
        func invoke(_ item: NSMenuItem) throws { try require(controller.validateMenuItem(item) && NSApp.sendAction(item.action!, to: item.target, from: item)) }
        func sheetButton(_ title: String) async throws {
            try await wait { window.attachedSheet != nil }
            let sheet = window.attachedSheet!; try require(sheet.alphaValue == 0 && !controller.windowShouldClose(window))
            guard let button = views(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw Failure(line: #line) }
            button.performClick(nil)
            try await wait { window.attachedSheet !== sheet }
        }
        model.select(rootNode.hash, extending: false)
        let annotated = try itemDeleting("refs/tags/release-v1")
        try require(annotated.title == "refs/tags/release-v1^{}")
        controller.perform("copyRefs"); try require(copied.contains("refs/tags/release-v1^{}"))
        try invoke(annotated); try await wait { window.attachedSheet != nil }
        let abortSheet = window.attachedSheet!
        try require(abortSheet.defaultButtonCell?.title == "Abort" && !controller.windowShouldClose(window))
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: abortSheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        if !abortSheet.performKeyEquivalent(with: enter) { abortSheet.sendEvent(enter) }
        try await wait { window.attachedSheet == nil && !model.busy }
        let keptAnnotated = try await repo.run(["rev-parse", "refs/tags/release-v1"]).text
        try require(!keptAnnotated.isEmpty)
        try invoke(annotated); try await sheetButton("Delete"); try await wait { !model.busy }
        let removedAnnotated = try? await repo.run(["show-ref", "--verify", "refs/tags/release-v1"])
        try require(removedAnnotated == nil)
        model.select(main.hash, extending: false)
        let all = controller.nodeMenu().items.first { $0.title == "Delete branch/tag" }!.submenu!.items.last!
        try invoke(all)
        try await sheetButton("Delete local remote-tracking branch")
        // All confirms each reference in sequence; Abort stops at the next tag.
        try await sheetButton("Abort"); try await wait { !model.busy }
        let removedRemote = try? await repo.run(["show-ref", "--verify", "refs/remotes/origin/main"])
        let keptTag = try await repo.run(["show-ref", "--verify", "refs/tags/export<&\"'>"])
        let currentHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(removedRemote == nil && !keptTag.stdout.isEmpty && currentHead == head)
        // A ref moved before menu activation must not be deleted under the old node.
        model.select(rootNode.hash, extending: false)
        let stale = try itemDeleting("refs/tags/v1.0")
        _ = try await repo.run(["tag", "-f", "v1.0", "HEAD"])
        try invoke(stale); try await sheetButton("OK"); try await wait { !model.busy }
        let moved = try await repo.run(["rev-parse", "v1.0"]).stdout
        try require(moved == head)
        _ = try await repo.run(["tag", "-f", "v1.0", rootNode.hash]); model.load(); try await wait { !model.busy }
        model.select(rootNode.hash, extending: false)
        let raced = try itemDeleting("refs/tags/v1.0")
        try invoke(raced); try await wait { window.attachedSheet != nil }
        _ = try await repo.run(["tag", "-f", "v1.0", "HEAD"])
        try await sheetButton("Delete"); try await sheetButton("OK"); try await wait { !model.busy }
        let afterRace = try await repo.run(["rev-parse", "v1.0"]).stdout
        try require(afterRace == head)
        model.load(); try await wait { !model.busy }
        let unlabelled = model.nodes.first { $0.references.isEmpty }!
        model.select(unlabelled.hash, extending: false); controller.perform("copyRefs")
        try require(copied == unlabelled.hash)
        print("PASS: Revision Graph source node menus, branch/tag routing, range Log, copy refs, annotated deletion, Abort/All, moved-ref and confirmation-race guards")
        model.load(); try require(model.busy)
        var closed = false; controller.onClosed = { closed = true }
        window.performClose(nil); try await wait { closed }
        try require(model.closed && !model.busy)
        model.load(); try require(!model.busy)
        print("PASS: Native Revision Graph selection, routing, zoom, tooltip, filter scopes, Reset, cancellation and repository invariants")
    }
}
