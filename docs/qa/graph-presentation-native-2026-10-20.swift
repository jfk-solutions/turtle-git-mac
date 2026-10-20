import AppKit
import TurtleGitCore

@MainActor enum GraphPresentationVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<1000 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(message: "Graph presentation receiver timed out")
    }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func verifyPersistentMark(_ button: NSButton) throws {
        try require(button is RevisionGraphToolbarButton, "Filter/Overview use persistent native checked painting")
        let originalState = button.state, originalAppearance = button.appearance, originalEnabled = button.isEnabled
        defer { button.state = originalState; button.appearance = originalAppearance; button.isEnabled = originalEnabled }
        let width = Int(button.bounds.width.rounded()), height = Int(button.bounds.height.rounded())
        try require(width >= 24 && height >= 24, "Actual toolbar button geometry")
        func raster(_ appearance: NSAppearance) throws -> NSBitmapImageRep {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure(message: "Toolbar bitmap context") }
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill(); button.bounds.fill()
                button.draw(button.bounds)
            }
            context.flushGraphics()
            return bitmap
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            button.appearance = appearance
            for enabled in [true, false] {
                button.isEnabled = enabled
                button.state = .off; let unchecked = try raster(appearance)
                button.state = .on; let checked = try raster(appearance)
                var changed = 0
                // These edge columns lie outside the 20-point source icon; the
                // oracle proves the persistent background rather than icon tint.
                for x in [1, 2, width - 3, width - 2] {
                    for y in 7..<(height - 7) {
                        let before = unchecked.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        let after = checked.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        let difference = abs(before.redComponent - after.redComponent) + abs(before.greenComponent - after.greenComponent) + abs(before.blueComponent - after.blueComponent)
                        if difference > 0.03 { changed += 1 }
                    }
                }
                try require(changed >= 12, "Persistent checked perimeter must paint in light/dark, enabled/disabled")
            }
        }
    }
    static func verify(root: URL, git: URL) async throws {
        let directory = root.appendingPathComponent("graph-presentation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = GitRepository(root: directory, executable: git)
        _ = try await repository.run(["init", "-b", "main"])
        _ = try await repository.run(["config", "user.name", "Graph Presentation"])
        _ = try await repository.run(["config", "user.email", "graph-presentation@example.invalid"])
        _ = try await repository.run(["config", "commit.gpgsign", "false"])
        try Data("graph\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
        try await repository.stage(["file.txt"])
        _ = try await repository.commit(message: "Graph presentation subject\n\nBody with 🐢\nSecond body line")
        let baselineHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let baselineIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
        let baselineConfig = try Data(contentsOf: directory.appendingPathComponent(".git/config"))
        let suite = "TurtleGit.GraphPresentation." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/graph-layout-runtime/GraphLayout/graph-layout")
        let controller = RevisionGraphWindowController(repository: repository, access: nil, preferences: preferences, layoutExecutable: helper, automaticallyLoad: false)
        var owned = [controller]
        func closeOwned() async throws {
            for owner in owned { owner.window?.close() }
            for owner in owned { await owner.model.waitForCompletion() }
            try await wait { RevisionGraphWindowModel.activeOperations == 0 && RevisionGraphFilterController.activeOperations == 0 && RevisionGraphFindController.activeOperations == 0 }
            try require(owned.allSatisfy { $0.model.closed && $0.window?.isVisible != true }, "Graph owned windows must close")
        }
        do {
            let window = controller.window!, model = controller.model
            window.alphaValue = 0; window.orderFront(nil)
            func command(_ owner: RevisionGraphWindowController, _ name: String) -> NSMenuItem {
                views(owner.window!.contentView!).compactMap { $0 as? NSPopUpButton }.flatMap(\.itemArray).first { ($0.representedObject as? String) == name }!
            }
            let popups = views(window.contentView!).compactMap { $0 as? NSPopUpButton }.filter { $0.itemArray.contains { $0.representedObject is String } }
            try require(popups.count == 4 && popups[0].itemArray.filter(\.isSeparatorItem).count == 1 && popups[1].itemArray.filter(\.isSeparatorItem).count == 2, "Source File/View menu grouping")
            for name in ["save", "zoomIn", "zoomOut", "zoom100", "fitHeight", "fitWidth", "fit", "filter", "find", "overview", "compare", "compareHead", "unified", "unifiedHead", "help"] {
                try require(command(controller, name).image != nil, "Original command icon missing: " + name)
            }
            for (name, key) in [("zoomIn", "+"), ("zoomOut", "-"), ("find", "f")] {
                let item = command(controller, name)
                try require(item.keyEquivalent == key && item.keyEquivalentModifierMask == .command, "Native accelerator metadata: " + name)
            }
            preferences.set(false, forKey: "ShowAppContextMenuIcons")
            let plain = RevisionGraphWindowController(repository: repository, access: nil, preferences: preferences, layoutExecutable: helper, automaticallyLoad: false)
            plain.window!.alphaValue = 0; owned.append(plain)
            try require(["save", "zoomIn", "filter", "compare", "unified", "help"].allSatisfy { command(plain, $0).image == nil }, "Captured menu icon preference")
            preferences.set(true, forKey: "ShowAppContextMenuIcons")
            try require(command(controller, "zoomIn").image != nil && command(plain, "zoomIn").image == nil, "Owning preference suite is retained")
            for popup in views(plain.window!.contentView!).compactMap({ $0 as? NSPopUpButton }) {
                if let menu = popup.menu, menu.delegate === plain { plain.menuNeedsUpdate(menu) }
            }
            try require(command(plain, "zoomIn").image != nil && command(plain, "help").image != nil, "Later menu open reflects enabled icon setting")
            preferences.set(false, forKey: "ShowAppContextMenuIcons")
            for popup in popups {
                try require(popup.menu?.delegate === controller, "Controller owns menu update callbacks")
                controller.menuNeedsUpdate(popup.menu!)
            }
            try require(command(controller, "zoomIn").image == nil && command(controller, "compare").image == nil, "Later menu open reflects disabled icon setting")
            preferences.set(true, forKey: "ShowAppContextMenuIcons")
            for popup in popups { controller.menuNeedsUpdate(popup.menu!) }
            model.load(); try await wait { !model.busy }
            try require(model.error == nil && !model.nodes.isEmpty, "Load actual graph")
            let filterItem = command(controller, "filter")
            let filterButton = views(window.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "filter" }!
            func filterState(_ active: Bool) throws {
                controller.update()
                _ = controller.validateMenuItem(filterItem)
                try require(filterItem.state == (active ? .on : .off) && filterButton.state == (active ? .on : .off), "Applied filter menu/toolbar state")
            }
            try filterState(false)
            window.contentView!.layoutSubtreeIfNeeded()
            try verifyPersistentMark(filterButton)
            let overviewButton = views(window.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "overview" }!
            try verifyPersistentMark(overviewButton)
            controller.showFilter(); try await wait { controller.filter != nil }
            controller.filter!.toField.stringValue = "HEAD"
            try filterState(false) // Unaccepted text is not an applied filter.
            try require(!controller.validateMenuItem(command(controller, "zoomOut")) && !filterButton.isEnabled, "Filter owner blocks competing menu actions")
            let initialNode = model.geometry!.nodes[0]
            let initialPoint = NSPoint(x: initialNode.rect.midX * model.zoom + 10, y: initialNode.rect.midY * model.zoom + 10)
            try require(controller.canvas.view(controller.canvas, stringForToolTip: 0, point: initialPoint, userData: nil).isEmpty, "Owned sheet suppresses stale graph tooltip")
            let previousZoom = model.zoom
            controller.perform("zoomOut"); try require(model.zoom == previousZoom, "Owned sheet rejects direct zoom")
            controller.filter!.accept(); try await wait { controller.filter == nil && !model.busy && window.attachedSheet == nil }
            try require(model.options.to == "HEAD" && model.error == nil, "Apply range filter")
            try filterState(true)
            controller.showFilter(); try await wait { controller.filter != nil }
            controller.filter!.toField.stringValue = ""
            controller.filter!.abort(); try await wait { controller.filter == nil && window.attachedSheet == nil }
            try require(model.options.to == "HEAD", "Cancel preserves applied scope")
            try filterState(true)
            controller.showFilter(); try await wait { controller.filter != nil }
            controller.filter!.resetFilter(); try await wait { controller.filter == nil && !model.busy && window.attachedSheet == nil }
            try filterState(false)
            for scope in ["current", "local", "from", "to"] {
                model.options = RevisionGraphOptions()
                switch scope {
                case "current": model.options.onlyCurrentBranch = true
                case "local": model.options.onlyLocalBranches = true
                case "from": model.options.from = "HEAD"
                default: model.options.to = "HEAD"
                }
                try filterState(true)
            }
            model.options = RevisionGraphOptions(); try filterState(false)
            let node = model.nodes[0]
            let actualTip = RevisionGraphTooltip.text(node, timeZone: TimeZone(secondsFromGMT: 0)!)
            try require(actualTip.contains("Graph Presentation <graph-presentation@example.invalid>") && actualTip.contains("\n\nGraph presentation subject\n\nBody with 🐢\nSecond body line"), "Tooltip full captured author/email and multiline body")
            let fixed = RevisionGraphNode(hash: "0123456789", author: "Name 🐢", authorDate: "2026-10-20T12:34:56+02:00", message: "Subject\n\nBody\nMore", authorEmail: "name@example.invalid")
            try require(RevisionGraphTooltip.text(fixed, timeZone: TimeZone(secondsFromGMT: 0)!) == "0123456789\nName 🐢 <name@example.invalid> 2026-10-20 10:34\n\nSubject\n\nBody\nMore", "Tooltip local minute date precision and source grouping")
            let prefix = RevisionGraphTooltip.text(RevisionGraphNode(hash: "h", author: "a", authorDate: "date", message: "s\n\n", authorEmail: "e"))
            let prefixLength = (prefix as NSString).length
            let longMessage = "s\n\n" + String(repeating: "x", count: 7_999 - prefixLength) + "🐢" + String(repeating: "y", count: 100)
            let bounded = RevisionGraphTooltip.text(RevisionGraphNode(hash: "h", author: "a", authorDate: "date", message: longMessage, authorEmail: "e"))
            try require((bounded as NSString).length <= 8_003 && bounded.hasSuffix("...") && !bounded.contains("�"), "Tooltip UTF-16 limit preserves surrogate pair")
            window.makeFirstResponder(controller.canvas)
            func key(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            }
            let nativeWindow = window as! RevisionGraphNativeWindow
            var routed: [String] = []; let original = nativeWindow.command
            nativeWindow.command = { routed.append($0) }
            defer { nativeWindow.command = original }
            _ = nativeWindow.performKeyEquivalent(with: key(27, "-", .command))
            _ = nativeWindow.performKeyEquivalent(with: key(24, "+", [.command, .shift]))
            _ = nativeWindow.performKeyEquivalent(with: key(3, "f", [.command, .option]))
            _ = nativeWindow.performKeyEquivalent(with: key(96, "", .option))
            _ = nativeWindow.performKeyEquivalent(with: key(96, "", []))
            try require(routed == ["zoomOut", "zoomIn", "refresh"], "Exact modifiers route Graph accelerators")
            nativeWindow.command = original
            let zoomItem = command(controller, "zoomOut")
            try require(NSApp.sendAction(zoomItem.action!, to: zoomItem.target, from: zoomItem) && model.zoom < previousZoom, "Menu accelerator action shares guarded dispatcher")
            let geometry = model.geometry!.nodes.first { $0.hash == node.hash }!
            let point = NSPoint(x: geometry.rect.midX * model.zoom + 10, y: geometry.rect.midY * model.zoom + 10)
            let visibleTip = controller.canvas.view(controller.canvas, stringForToolTip: 0, point: point, userData: nil)
            try require(visibleTip.contains(node.authorEmail), "Actual canvas tooltip routes complete metadata")
            try await closeOwned()
            try require(controller.canvas.view(controller.canvas, stringForToolTip: 0, point: point, userData: nil).isEmpty, "Retired graph rejects tooltip callbacks")
            let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
            let afterIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
            let afterConfig = try Data(contentsOf: directory.appendingPathComponent(".git/config"))
            try require(afterHead == baselineHead && afterIndex == baselineIndex && afterConfig == baselineConfig, "Graph presentation preserves repository")
            print("PASS: Graph source menu groups/icons/accelerators, applied range/scope/reset state, bounded author/date/body tooltips and owned closure")
        } catch {
            try? await closeOwned()
            throw error
        }
    }
}
