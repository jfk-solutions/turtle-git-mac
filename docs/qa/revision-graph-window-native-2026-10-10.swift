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
    @MainActor static func XCToolbar(_ window: NSWindow) throws -> NSStackView {
        guard let toolbar = views(window.contentView!).first(where: { $0.identifier?.rawValue == "RevisionGraphToolbar" }) as? NSStackView else { throw Failure(line: #line) }
        return toolbar
    }
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
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let green = RevisionGraphPalette.background(.localBranch, pointer: false, preferences: prefs).usingColorSpace(.sRGB)!
            assert(abs(green.greenComponent - 195.0/255) < 0.001 && green.redComponent == 0)
            assert(RevisionGraphPalette.foreground(green) == NSColor.white)
            prefs.set(true, forKey: "Graph.RevGraphUseLocalForCur")
            assert(RevisionGraphPalette.background(.currentBranch, pointer: false, preferences: prefs).usingColorSpace(.sRGB)! == green)
            prefs.removeObject(forKey: "Graph.RevGraphUseLocalForCur")
        }
        try require(!model.showOverview && !model.arrowsTowardMerges && !model.options.showBranchingsAndMerges && model.options.showAllTags)
        let keys = ["ShowRevGraphOverview", "ArrowPointToMerges", "ShowRevGraphBranchesMerges", "ShowRevGraphAllTags"]
        try require(keys.allSatisfy { prefs.object(forKey: $0) == nil })
        func displayItem(_ owner: RevisionGraphWindowController, _ command: String) -> NSMenuItem {
            views(owner.window!.contentView!).compactMap { $0 as? NSPopUpButton }.flatMap { $0.itemArray }.first { ($0.representedObject as? String) == command }!
        }
        func toggle(_ command: String) async throws {
            let item = displayItem(controller, command)
            try require(NSApp.sendAction(item.action!, to: item.target, from: item))
            try await wait { !model.busy }
        }
        try await toggle("overview"); try await toggle("arrows"); try await toggle("branchings"); try await toggle("tags")
        try require(prefs.bool(forKey: keys[0]) && prefs.bool(forKey: keys[1]) && prefs.bool(forKey: keys[2]) && !prefs.bool(forKey: keys[3]))
        model.options.from = "transient-filter"; model.options.onlyCurrentBranch = true; model.zoom = 0.5
        let reopened = RevisionGraphWindowController(repository: repo, access: nil, preferences: prefs, layoutExecutable: helper, automaticallyLoad: false)
        reopened.window!.alphaValue = 0
        try require(reopened.model.showOverview && reopened.model.arrowsTowardMerges && reopened.model.options.showBranchingsAndMerges && !reopened.model.options.showAllTags)
        try require(reopened.model.zoom == 1 && reopened.model.options.from.isEmpty && !reopened.model.options.onlyCurrentBranch && reopened.model.selection.isEmpty)
        for (command, state) in [("overview", NSControl.StateValue.on), ("arrows", .on), ("branchings", .on), ("tags", .off)] {
            let item = displayItem(reopened, command); try require(reopened.validateMenuItem(item) && item.state == state)
        }
        reopened.window!.close(); try require(reopened.model.closed)
        reopened.perform("arrows"); try require(prefs.bool(forKey: keys[1]))
        model.options.from = ""; model.options.onlyCurrentBranch = false; model.zoom = 1
        // Loading/sheet guards must reject actions before touching saved state.
        model.load(); try require(model.busy)
        controller.perform("overview"); try require(model.showOverview && prefs.bool(forKey: keys[0]))
        try await wait { !model.busy }
        try await toggle("overview"); try await toggle("arrows"); try await toggle("branchings"); try await toggle("tags")
        try require(!model.showOverview && !model.arrowsTowardMerges && !model.options.showBranchingsAndMerges && model.options.showAllTags)
        try require(!prefs.bool(forKey: keys[0]) && !prefs.bool(forKey: keys[1]) && !prefs.bool(forKey: keys[2]) && prefs.bool(forKey: keys[3]))
        print("PASS: Revision Graph display preferences, source defaults, menu dispatch/checkmarks, reopen and busy/closed guards")
        let geometry = model.geometry!.nodes // Preference toggles reload layout; use current geometry.
        let pointerNode = model.nodes.first { $0.hash == geometry[0].hash }!
        let pointerRows = model.lines(pointerNode, pointers: [pointerNode.hash: ["super-project-rebase-head", "super-project-head"]])
        try require(Array(pointerRows.prefix(2)).map { $0.0 } == ["super-project-rebase-head", "super-project-head"])
        try require(pointerRows.prefix(2).allSatisfy { $0.2 } && pointerRows.dropFirst(2).allSatisfy { !$0.2 })
        let pointerColor = RevisionGraphPalette.background(.otherRef, pointer: true, preferences: prefs)
        try require(pointerColor != RevisionGraphPalette.background(.otherRef, pointer: false, preferences: prefs))
        print("PASS: Revision Graph distinct submodule pointer label rows and pointer color identity")
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
        let toolbar = try XCToolbar(window)
        let toolbarControls = toolbar.arrangedSubviews.compactMap { $0 as? NSButton }
        try require(toolbarControls.map { $0.identifier!.rawValue } == ["zoomIn", "zoomOut", "zoom100", "fitHeight", "fitWidth", "fit", "filter", "overview", "find", "refresh"])
        let glyphs: [RevisionGraphToolbarIcon] = [.zoomIn, .zoomOut, .zoom100, .fitHeight, .fitWidth, .fitGraph, .filter, .overview, .find]
        for (button, glyph) in zip(toolbarControls, glyphs) {
            let actual = (button.image!.representations.first as! NSBitmapImageRep).representation(using: .png, properties: [:])
            let expected = (glyph.image()!.representations.first as! NSBitmapImageRep).representation(using: .png, properties: [:])
            try require(actual == expected && button.isEnabled && !button.isBordered)
        }
        func press(_ command: String) throws {
            let button = toolbarControls.first { $0.identifier?.rawValue == command }!
            try require(NSApp.sendAction(button.action!, to: button.target, from: button))
        }
        try press("zoomOut"); try require(abs(model.zoom - 0.9) < 0.0001)
        try press("zoomIn"); try require(abs(model.zoom - 1) < 0.0001)
        for command in ["fitHeight", "fitWidth", "fit"] { try press(command); try require(model.zoom > 0 && model.zoom <= 2) }
        try press("zoom100"); try require(model.zoom == 1)
        try press("overview"); try require(!model.showOverview && toolbarControls[7].state == .off)
        try press("overview"); try require(model.showOverview && toolbarControls[7].state == .on)
        print("PASS: Revision Graph original toolbar pixels, command order, six zoom actions and Overview state")
        let zoomBox = controller.zoomBox
        try require(zoomBox.objectValues as? [String] == ["200%", "100%", "75%", "50%", "40%", "20%", "10%", "5%"] && zoomBox.stringValue == "100%" && zoomBox.isEnabled)
        func zoomText(_ value: String) throws {
            window.makeFirstResponder(nil); zoomBox.stringValue = value
            try require(NSApp.sendAction(zoomBox.action!, to: zoomBox.target, from: zoomBox))
        }
        try zoomText("125%"); try require(abs(model.zoom - 1.25) < 0.0001 && zoomBox.stringValue == "125%")
        try zoomText("12.5"); try require(abs(model.zoom - 0.125) < 0.0001)
        try zoomText("250%"); try require(abs(model.zoom - 2.5) < 0.0001 && zoomBox.stringValue == "250%")
        for invalid in ["", "0%", "-25%", "nonsense", "25% junk", "NaN", "1e300%", "1e-320%"] {
            try zoomText(invalid); try require(model.zoom == 2.5 && zoomBox.stringValue == "250%")
        }
        zoomBox.selectItem(at: 2)
        NotificationCenter.default.post(name: NSComboBox.selectionDidChangeNotification, object: zoomBox)
        try require(model.zoom == 0.75 && zoomBox.stringValue == "75%")
        controller.perform("zoomOut"); try require(abs(model.zoom - 0.675) < 0.0001 && zoomBox.stringValue == String(format: "%.0f%%", model.zoom * 100))
        controller.perform("zoom100")
        window.makeFirstResponder(zoomBox)
        let editor = zoomBox.currentEditor() as! NSTextView
        editor.selectAll(nil); editor.insertText("150%", replacementRange: editor.selectedRange())
        let zoomReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(zoomReturn)
        try await wait { abs(model.zoom - 1.5) < 0.0001 }
        window.makeFirstResponder(nil); controller.perform("zoom100")
        model.load(); try require(!zoomBox.isEnabled && toolbarControls.allSatisfy { !$0.isEnabled })
        try zoomText("75%"); try require(model.zoom == 1 && zoomBox.stringValue == "100%")
        try await wait { !model.busy }; try require(zoomBox.isEnabled)
        print("PASS: Revision Graph editable zoom presets, custom percentages, native Return, synchronized display and invalid/busy guards")
        let overview = views(window.contentView!).compactMap { $0 as? RevisionGraphOverview }.first!
        let tall = RevisionGraphOverview.layout(graph: CGSize(width: 4000, height: 8000), viewport: CGSize(width: 960, height: 560))
        try require(abs(tall.size.width - 104) < 0.01 && abs(tall.size.height - 200) < 0.01 && abs(tall.scale - 0.024) < 0.0001)
        let tiny = RevisionGraphOverview.layout(graph: CGSize(width: 2, height: 3), viewport: CGSize(width: 960, height: 560))
        try require(tiny.size == CGSize(width: 30, height: 30) && tiny.scale == 1)
        let wide = RevisionGraphOverview.layout(graph: CGSize(width: 8000, height: 1000), viewport: CGSize(width: 1600, height: 1000))
        try require(abs(wide.size.width - 400) < 0.01 && abs(wide.size.height - 57) < 0.01)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: overview.superview!)
        try require(abs(overview.frame.maxX - viewport.maxX) < 1 && abs(overview.frame.minY - viewport.minY) < 1)
        try require(overview.frame.width <= max(100, scroll.contentSize.width / 4) && overview.frame.height <= max(200, scroll.contentSize.height / 4))
        let originalWindowFrame = window.frame
        window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: 1400, height: 900)), display: false)
        window.contentView!.layoutSubtreeIfNeeded(); controller.update()
        let resizedViewport = scroll.contentView.convert(scroll.contentView.bounds, to: overview.superview!)
        try require(abs(overview.frame.maxX - resizedViewport.maxX) < 1 && abs(overview.frame.minY - resizedViewport.minY) < 1)
        try require(overview.frame.width > 0 && overview.scale <= 1)
        window.setFrame(originalWindowFrame, display: false); window.contentView!.layoutSubtreeIfNeeded(); controller.update()
        model.zoom = 2; controller.update()
        controller.canvas.setFrameSize(CGSize(width: 3000, height: 3000))
        clip.scroll(to: NSPoint(x: 100, y: 100)); scroll.reflectScrolledClipView(clip)
        let selectedPair = model.selection
        func overviewEvent(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: overview.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        }
        let edge = NSPoint(x: overview.bounds.maxX - 1, y: overview.bounds.maxY - 1)
        let expectedOrigin = NSPoint(x: max(0, (edge.x - 4) / overview.scale * model.zoom - scroll.contentSize.width / 2), y: max(0, (edge.y - 4) / overview.scale * model.zoom - scroll.contentSize.height / 2))
        overview.mouseDown(with: overviewEvent(.leftMouseDown, edge))
        try require(abs(clip.bounds.minX - expectedOrigin.x) < 1 && abs(clip.bounds.minY - expectedOrigin.y) < 1)
        try require(model.selection == selectedPair && overview.bounds.contains(overview.viewportRect))
        let lastOrigin = clip.bounds.origin
        overview.mouseDragged(with: overviewEvent(.leftMouseDragged, NSPoint(x: -20, y: -20)))
        try require(clip.bounds.origin == lastOrigin) // Outside the overview does not navigate.
        overview.mouseDragged(with: overviewEvent(.leftMouseDragged, NSPoint(x: 1, y: 1)))
        try require(clip.bounds.origin == .zero && model.selection == selectedPair)
        model.zoom = 1; controller.update(); clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        print("PASS: Revision Graph adaptive overview dimensions, bottom-right placement, resize, viewport and drag routing")
        func capture(_ target: NSWindow, prefix: String) async throws {
            guard CommandLine.arguments.count > 4 else { return }
            let directory = URL(fileURLWithPath: CommandLine.arguments[4])
            target.orderOut(nil); target.alphaValue = 1
            defer { target.alphaValue = 0; target.orderFront(nil) }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                target.appearance = NSAppearance(named: appearance); target.makeFirstResponder(nil)
                target.contentView!.layoutSubtreeIfNeeded(); target.contentView!.needsDisplay = true
                if prefix == "revision-graph-find" {
                    let findButton = views(target.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Find" }!
                    let frame = findButton.convert(findButton.bounds, to: target.contentView!)
                    try require(target.contentView!.bounds.maxX - frame.maxX < 30 && target.contentView!.bounds.contains(frame))
                }
                try await Task.sleep(nanoseconds: 200_000_000)
                let view = target.contentView!, bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                target.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(prefix + "-" + name + ".png"))
            }
            target.appearance = NSAppearance(named: .aqua)
        }
        try await capture(window, prefix: "revision-graph")
        let regexHelper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let commandF = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        try require(window.performKeyEquivalent(with: commandF) && controller.find != nil)
        let keyboardFind = controller.find!; try require(keyboardFind.loadingReferences); keyboardFind.cancelButton.performClick(nil)
        try await wait { controller.find == nil }; try require(keyboardFind.closed && !keyboardFind.loadingReferences && keyboardFind.references.isEmpty)
        controller.showFind(regexExecutable: regexHelper)
        let find = controller.find!, findWindow = find.window!
        let initialFindHistory = prefs.stringArray(forKey: "History.Find.Search"), initialFindSelection = model.selection
        try require(find.loadingReferences && !find.findButton.isEnabled && !find.searchBox.isEnabled && !find.table.isEnabled && !find.referenceFilter.isEnabled)
        find.searchBox.stringValue = "startup must wait"; find.findNext(); find.searchReference("refs/heads/no-such-reference")
        try require(!find.busy && findWindow.attachedSheet == nil && model.selection == initialFindSelection && prefs.stringArray(forKey: "History.Find.Search") == initialFindHistory)
        try await wait { !find.references.isEmpty }
        try require(findWindow.alphaValue == 0 && window.childWindows?.contains(findWindow) == true && window.attachedSheet == nil)
        controller.showFind(); try require(controller.find === find)
        findWindow.contentView!.layoutSubtreeIfNeeded()
        try require(find.searchBox.frame.width >= 270 && find.searchBox.frame.height >= 20 && find.findButton.frame.width >= 40)
        try require(find.table.enclosingScrollView!.frame.height >= 160 && find.table.enclosingScrollView!.frame.width > 400 && find.referenceFilter.frame.width > 300)
        let queryFrame = find.searchBox.convert(find.searchBox.bounds, to: findWindow.contentView!), refsFrame = find.table.enclosingScrollView!.convert(find.table.enclosingScrollView!.bounds, to: findWindow.contentView!)
        try require(queryFrame.minY > refsFrame.maxY && findWindow.contentView!.bounds.contains(queryFrame) && findWindow.contentView!.bounds.contains(refsFrame))
        try require(find.references.contains("refs/tags/release-v1") && find.references.contains("refs/heads/main") && find.references.contains("refs/remotes/origin/main"))
        for name in ["refs/tags/release-v1", "refs/heads/main", "refs/remotes/origin/main"] {
            let index = find.visibleReferences.firstIndex(of: name)!
            let row = find.tableView(find.table, viewFor: find.table.tableColumns[0], row: index)!
            let actual = views(row).compactMap { $0 as? NSImageView }.first!.image!
            let expected = ReferenceTypeIcon(referenceName: name)!.image()!
            try require((actual.representations[0] as! NSBitmapImageRep).representation(using: .png, properties: [:]) == (expected.representations[0] as! NSBitmapImageRep).representation(using: .png, properties: [:]))
        }
        func findText(_ query: String, regex: Bool = false, sensitive: Bool = false) async throws {
            find.searchBox.stringValue = query; find.regex.state = regex ? .on : .off; find.matchCase.state = sensitive ? .on : .off; find.updateAvailability()
            try require(find.findButton.isEnabled && NSApp.sendAction(find.findButton.action!, to: find.findButton.target, from: find.findButton))
            try require(find.busy && !find.findButton.isEnabled && !find.table.isEnabled)
            try await wait { !find.busy }
        }
        try require(find.searchIndex() == 0)
        try await findText(model.nodes[0].hash)
        try require(find.status.stringValue.contains("No further match") && model.findSearchIndex == 0)
        // The feature commit is row zero in this fixture: source Find excludes
        // the initial retained row until another match/reference advances it.
        find.searchReference("refs/tags/release-v1"); try await wait { !find.busy }
        try require(model.selection == [rootNode.hash])
        try await findText("Tooltip body 🐢"); try require(model.selection == [feature.hash])
        try await findText("TOOLTIP", sensitive: true); try require(model.selection == [feature.hash] && find.status.stringValue.contains("No further match"))
        try await findText("graph@example.invalid", regex: true); try require(model.selection.count == 1 && model.selection != [feature.hash])
        let beforeNoMatch = model.selection
        try await findText("no-such-message"); try require(model.selection == beforeNoMatch && find.status.stringValue.contains("No further match"))
        find.searchReference("refs/tags/release-v1"); try await wait { !find.busy }; try require(model.selection == [rootNode.hash])
        find.searchReference("refs/heads/feature/native-graph", select: false); try await wait { !find.busy }; try require(model.selection == [rootNode.hash])
        // An error is acknowledged in a real child-owned critical sheet.
        let beforeError = model.selection
        find.searchReference("refs/heads/no-such-reference")
        try await wait { findWindow.attachedSheet != nil }
        let errorSheet = findWindow.attachedSheet!
        try require(find.acknowledgingFailure && errorSheet.alphaValue == 0 && !find.findButton.isEnabled && !zoomBox.isEnabled)
        try require(!controller.windowShouldClose(window) && !find.windowShouldClose(findWindow))
        let messageLabels = views(errorSheet.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue)
        try require(messageLabels.contains { $0.contains("Could not get hash of ref") && $0.contains("refs/heads/no-such-reference^{}") })
        let beforeErrorZoom = model.zoom; controller.perform("zoomOut"); controller.showFilter()
        try require(model.zoom == beforeErrorZoom && controller.filter == nil && model.selection == beforeError)
        find.findNext(); try require(!find.busy)
        click(geometry.firstIndex { !beforeError.contains($0.hash) }!)
        try require(model.selection == beforeError && controller.nodeMenu().items.isEmpty)
        find.cancelButton.performClick(nil); try require(!find.closed)
        let errorReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: errorSheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        errorSheet.sendEvent(errorReturn)
        try await wait { findWindow.attachedSheet == nil && !find.acknowledgingFailure }
        try require(find.findButton.isEnabled && zoomBox.isEnabled && model.selection == beforeError)
        // Plain Return through the native field editor submits the current query.
        find.searchReference("refs/tags/release-v1"); try await wait { !find.busy }
        findWindow.makeFirstResponder(find.searchBox)
        let plainFindEditor = find.searchBox.currentEditor() as! NSTextView
        plainFindEditor.selectAll(nil); plainFindEditor.insertText("Tooltip body", replacementRange: plainFindEditor.selectedRange())
        find.regex.state = .off; find.matchCase.state = .off
        let findReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: findWindow.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        findWindow.sendEvent(findReturn)
        try await wait { !find.busy && model.selection == [feature.hash] }
        // Shift-Return goes to a result while preserving the selected Base.
        find.searchReference("refs/tags/release-v1"); try await wait { !find.busy }
        findWindow.makeFirstResponder(find.searchBox)
        let findEditor = find.searchBox.currentEditor() as! NSTextView
        findEditor.selectAll(nil); findEditor.insertText("Tooltip body", replacementRange: findEditor.selectedRange())
        find.regex.state = .off; find.matchCase.state = .off
        let shiftReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: findWindow.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        findWindow.sendEvent(shiftReturn); try await wait { !find.busy }
        try require(model.selection == [rootNode.hash] && find.status.stringValue.contains("beginning"))
        find.referenceFilter.stringValue = "refs/heads/feature/"; find.applyReferenceFilter()
        try require(find.visibleReferences.count == 3)
        find.referenceFilter.stringValue = "REFS/HEADS"; find.applyReferenceFilter(); try require(find.visibleReferences.isEmpty)
        find.referenceFilter.stringValue = ""; find.applyReferenceFilter()
        findWindow.makeFirstResponder(find.referenceFilter)
        let referenceEditor = find.referenceFilter.currentEditor() as! NSTextView
        referenceEditor.selectAll(nil); referenceEditor.insertText("refs/tags/", replacementRange: referenceEditor.selectedRange())
        try await wait { find.visibleReferences.count == 4 && find.visibleReferences.allSatisfy { $0.hasPrefix("refs/tags/") } }
        findWindow.makeFirstResponder(nil); find.referenceFilter.stringValue = ""; find.applyReferenceFilter()
        let refRow = find.visibleReferences.firstIndex(of: "refs/remotes/origin/main")!
        find.table.selectRowIndexes(IndexSet(integer: refRow), byExtendingSelection: false)
        try require(NSApp.sendAction(find.table.action!, to: find.table.target, from: find.table))
        try await wait { !find.busy }; try require(model.selection == [main.hash])
        try require(prefs.stringArray(forKey: "History.Find.Search")?.first == "Tooltip body")
        find.searchBox.stringValue = "Body"; find.regex.state = .on; find.matchCase.state = .on; find.updateAvailability()
        try await capture(findWindow, prefix: "revision-graph-find")
        let retainedFindIndex = model.findSearchIndex
        model.load(); try require(!find.findButton.isEnabled); find.findNext(); try require(!find.busy)
        try await wait { !model.busy }; try require(find.findButton.isEnabled)
        try require(model.findSearchIndex == retainedFindIndex && find.searchIndex() == retainedFindIndex)
        find.findNext(); try require(find.busy); find.close()
        try await wait { controller.find == nil }; try require(find.closed && window.childWindows?.contains(findWindow) != true)
        find.findNext(); try require(find.closed)
        controller.showFind(regexExecutable: regexHelper)
        let reopenedFind = controller.find!; try require(reopenedFind.searchBox.stringValue == "Body" && reopenedFind.regex.state == .on && reopenedFind.matchCase.state == .on)
        try await wait { !reopenedFind.loadingReferences }
        try require(reopenedFind.searchIndex() == retainedFindIndex)
        reopenedFind.regex.state = .off; reopenedFind.matchCase.state = .off
        reopenedFind.searchBox.stringValue = model.nodes[retainedFindIndex].hash
        reopenedFind.findNext(); try await wait { !reopenedFind.busy }
        try require(reopenedFind.status.stringValue.contains("No further match"))
        print("PASS: Source-owned numeric Find position starts after row zero and persists across Graph reload and reopen")
        let missingRepository = GitRepository(root: root.appendingPathComponent("missing-find-repository"), executable: repo.executable)
        let missingFind = RevisionGraphFindController(repository: missingRepository, access: nil, preferences: prefs)
        missingFind.canSearch = { true }; missingFind.window!.alphaValue = 0; missingFind.window!.orderFront(nil); missingFind.loadReferences()
        try await wait { missingFind.window?.attachedSheet != nil }
        let missingSheet = missingFind.window!.attachedSheet!
        try require(views(missingSheet.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Could not get all refs." })
        try require(!missingFind.windowShouldClose(missingFind.window!))
        missingFind.close(); try require(missingFind.closed && !missingSheet.isVisible)
        print("PASS: Find startup load/search exclusion, plain Return and critical-sheet Return acknowledgment")
        print("PASS: Find original reference-type pixels, Command-F/Cancel and Shift-Return routes, error sheets, root/input locks and forced-owned cleanup")
        model.selection = selectedPair; controller.update()
        print("PASS: Revision Graph modeless Find ownership, text/case/ECMAScript/email/ref search, shift navigation, filter/history, busy locks and cancellation")
        controller.showFilter(); try await wait { window.attachedSheet != nil }
        let child = window.attachedSheet!; try require(child.alphaValue == 0 && !zoomBox.isEnabled)
        try require(!reopenedFind.findButton.isEnabled); reopenedFind.findNext(); try require(!reopenedFind.busy)
        reopenedFind.close(); try await wait { controller.find == nil }
        try zoomText("75%"); try require(model.zoom == 1 && zoomBox.stringValue == "100%")
        try await capture(child, prefix: "revision-graph-filter")
        controller.requestRepositoryRefresh(); try require(!model.busy)
        let buttons = views(child.contentView!).compactMap { $0 as? NSButton }
        let current = buttons.first { $0.title == "Only Current Branch" }!, local = buttons.first { $0.title == "Only Local Branches" }!
        let to = views(child.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "To revision" }!
        let filter = controller.filter!, from = filter.fromField
        to.stringValue = "original-to"; child.makeFirstResponder(from)
        filter.fromBrowse.performClick(nil)
        try await wait { filter.picker != nil && filter.picker?.model.busy == false }
        let referencePicker = filter.picker!, browserWindow = referencePicker.window!
        try require(browserWindow.sheetParent === child && browserWindow.alphaValue == 0 && referencePicker.model.pickMultiple)
        try require(!filter.windowShouldClose(child) && !controller.windowShouldClose(window))
        filter.abort(); filter.resetFilter(); try require(controller.filter === filter)
        referencePicker.model.setFolder("refs")
        try await wait { views(browserWindow.contentView!).contains { ($0 as? NSTableView)?.numberOfRows == referencePicker.model.rows.count } }
        let referenceTable = views(browserWindow.contentView!).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "References" }!
        try require(referenceTable.allowsMultipleSelection)
        let names: Set<GitReferenceName> = ["refs/heads/main", "refs/tags/v1.0"]
        let indices = IndexSet(referencePicker.model.rows.indices.filter { names.contains(referencePicker.model.rows[$0].reference.name) })
        try require(indices.count == 2)
        referenceTable.selectRowIndexes(indices, byExtendingSelection: false)
        try await wait { referencePicker.model.selection == names }
        let chosenRefs = referencePicker.model.selectedRows.map { $0.reference.name.browserShortName }.joined(separator: " ")
        referencePicker.model.accept()
        try await wait { child.attachedSheet == nil && filter.picker == nil && from.currentEditor() != nil }
        try require(from.stringValue == chosenRefs && referencePicker.model.closed)
        child.makeFirstResponder(to); filter.toBrowse.performClick(nil)
        try await wait { filter.picker != nil && filter.picker?.model.busy == false }
        let cancelledPicker = filter.picker!
        cancelledPicker.model.finish(nil)
        try await wait { child.attachedSheet == nil && filter.picker == nil && to.currentEditor() != nil }
        try require(to.stringValue == "original-to" && cancelledPicker.model.closed)
        current.performClick(nil); try require(current.state == .on && local.state == .off && !local.isEnabled && !to.isEnabled && to.stringValue.isEmpty)
        current.performClick(nil); try require(local.isEnabled && to.isEnabled)
        to.stringValue = "discarded-to"; local.performClick(nil)
        try require(current.state == .off && local.state == .on && !current.isEnabled && !to.isEnabled && to.stringValue.isEmpty)
        local.performClick(nil); try require(current.isEnabled && to.isEnabled)
        print("PASS: Revision Graph Filter multi-reference picker, nested ownership, selection/cancel focus and source scope gates")
        try require(!controller.windowShouldClose(window))
        buttons.first { $0.title == "Cancel" }!.performClick(nil); try await wait { window.attachedSheet == nil && !model.busy }
        try require(!model.options.onlyCurrentBranch && !model.options.onlyLocalBranches)
        controller.showFilter(); try await wait { window.attachedSheet != nil }
        controller.filter!.window!.makeFirstResponder(nil)
        controller.filter!.fromField.stringValue = ""; controller.filter!.toField.stringValue = chosenRefs
        controller.filter!.ok.performClick(nil); try await wait { window.attachedSheet == nil && !model.busy }
        if model.error != nil || model.options.to != chosenRefs || model.nodes.isEmpty { print("Filter apply diagnostic:", model.options.from, model.options.to, chosenRefs, model.error ?? "no error", model.nodes.count) }
        try require(model.error == nil && model.options.to == chosenRefs && !model.nodes.isEmpty)
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
        let parentRoot = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-superproject")
        try FileManager.default.createDirectory(at: parentRoot, withIntermediateDirectories: true)
        let parentRepo = GitRepository(root: parentRoot, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await parentRepo.run(["init", "-b", "main"])
        _ = try await parentRepo.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", root.path, "child"])
        var pointerTrees: [String] = []
        for hash in [rootNode.hash, main.hash, feature.hash] {
            _ = try await parentRepo.run(["update-index", "--cacheinfo", "160000," + hash + ",child"])
            pointerTrees.append(try await parentRepo.run(["write-tree"]).text.trimmingCharacters(in: .newlines))
        }
        _ = try await parentRepo.run(["read-tree", pointerTrees[1]])
        _ = try await parentRepo.run(["read-tree", "-m"] + pointerTrees)
        let parentIndex = try Data(contentsOf: parentRoot.appendingPathComponent(".git/index"))
        let childRepo = GitRepository(root: parentRoot.appendingPathComponent("child"), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let childGraph = RevisionGraphWindowController(repository: childRepo, access: nil, preferences: prefs, layoutExecutable: helper, automaticallyLoad: false)
        childGraph.window!.alphaValue = 0; childGraph.window!.orderFront(nil)
        childGraph.model.load(); try await wait { !childGraph.model.busy }
        try require(childGraph.model.error == nil)
        try require(childGraph.model.pointers[main.hash] == ["super-project-head"] && childGraph.model.pointers[feature.hash] == ["super-project-merge-head"])
        for (hash, label) in [(main.hash, "super-project-head"), (feature.hash, "super-project-merge-head")] {
            let node = childGraph.model.nodes.first { $0.hash == hash }!
            let rows = childGraph.model.lines(node)
            try require(rows.first!.0 == label && rows.first!.2)
            let geometry = childGraph.model.geometry!.nodes.first { $0.hash == hash }!
            try require(geometry.rect.height >= CGFloat(rows.count) * (ceil(RevisionGraphWindowModel.font.ascender - RevisionGraphWindowModel.font.descender) + 10))
        }
        let pointerSVG = try RevisionGraphExport.data(canvas: childGraph.canvas, viewport: childGraph.scroll.contentSize, format: .svg, appearance: NSAppearance(named: .aqua)!)
        let svgText = String(decoding: pointerSVG, as: UTF8.self)
        try require(svgText.contains("super-project-head") && svgText.contains("super-project-merge-head") && svgText.contains("#f699fd"))
        let parentAfter = try Data(contentsOf: parentRoot.appendingPathComponent(".git/index"))
        try require(parentAfter == parentIndex)
        childGraph.window!.close(); try require(childGraph.model.closed)
        prefs.set(false, forKey: "LogShowSuperProjectSubmodulePointer")
        let hiddenChild = RevisionGraphWindowController(repository: childRepo, access: nil, preferences: prefs, layoutExecutable: helper, automaticallyLoad: false)
        hiddenChild.window!.alphaValue = 0
        hiddenChild.model.load(); try await wait { !hiddenChild.model.busy }
        try require(hiddenChild.model.error == nil && hiddenChild.model.pointers.isEmpty && !hiddenChild.model.options.showSuperprojectPointers)
        hiddenChild.window!.close(); prefs.removeObject(forKey: "LogShowSuperProjectSubmodulePointer")
        let afterHidden = try Data(contentsOf: parentRoot.appendingPathComponent(".git/index"))
        try require(afterHidden == parentIndex)
        print("PASS: Native conflicted submodule graph pointer labels, measured rows, SVG pointer color Advanced setting and unchanged parent index")
        controller.showFind(regexExecutable: regexHelper)
        let finalFind = controller.find!
        model.load(); try require(model.busy)
        var closed = false; controller.onClosed = { closed = true }
        window.performClose(nil); try await wait { closed }
        try require(model.closed && !model.busy && finalFind.closed && controller.find == nil)
        model.load(); try require(!model.busy)
        print("PASS: Native Revision Graph selection, routing, zoom, tooltip, filter scopes, Reset, cancellation and repository invariants")
    }
}
