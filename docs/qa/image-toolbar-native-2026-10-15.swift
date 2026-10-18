import AppKit
import ScreenCaptureKit
import TurtleGitCore

struct ImageToolbarVerification {
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws {
        if try !value() { throw NSError(domain: "ImageToolbar assertion", code: line) }
    }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw NSError(domain: "ImageToolbar timeout", code: line)
    }
    @MainActor static func item(_ command: ImageEditorCommand, _ owner: ImageEditorToolbar) throws -> NSToolbarItem {
        guard let item = owner.toolbar.items.first(where: { $0.itemIdentifier == command.identifier }) else { throw NSError(domain: "Missing " + command.rawValue, code: 1) }
        return item
    }
    @MainActor static func commandIsEnabled(_ command:ImageEditorCommand,_ owner:ImageEditorToolbar)->Bool {
        guard let native=try? item(command,owner),native.isEnabled,let control=native.view as? NSControl else{return false}
        return control.isEnabled
    }
    @MainActor static func send(_ item: NSMenuItem) throws {
        try require(NSApp.sendAction(item.action!, to: item.target, from: item))
    }
    @MainActor static func send(_ item: NSToolbarItem) throws {
        if let button = item.view as? NSButton { button.performClick(nil) }
        else { try require(NSApp.sendAction(item.action!, to: item.target, from: item)) }
    }
    @MainActor static func capture(_ owner: NSWindowController, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_IMAGE_TOOLBAR_CAPTURE"], let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw NSError(domain: "Capture requires macOS 14.4", code: 1) }
        NSApp.setActivationPolicy(.accessory); owner.showWindow(nil); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NSError(domain: "Missing owned image window", code: 1) }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width * window.backingScaleFactor); options.height = Int(window.frame.height * window.backingScaleFactor)
            options.showsCursor = false; options.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var coloredPixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       (c.redComponent > 0.8 && c.greenComponent < 0.2 && c.blueComponent < 0.2) || (c.blueComponent > 0.8 && c.redComponent < 0.2 && c.greenComponent < 0.2) { coloredPixels += 1 }
                }
            }
            try require(coloredPixels > 20)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + "-" + suffix + ".png"))
        }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.ImageToolbar." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        UserDefaults.standard.setVolatileDomain(["TurtleGit.DiffTools": try JSONEncoder().encode(DiffToolPreferences())], forName: "NSArgumentDomain")
        let left = root.appendingPathComponent("left.png"), right = root.appendingPathComponent("right.png")
        let a = ImageOpenVerification.png(0), b = ImageOpenVerification.png(2)
        try a.write(to: left); try b.write(to: right)
        let owner = FileComparisonWindowController(images: try ImageFileComparison(base: left, destination: right), permissions: [], preferences: prefs)
        defer { owner.close() }
        let window = owner.window!, parent = owner.model, image = parent.imageViewerModel, toolbar = owner.imageToolbar!
        parent.load(); try await wait { !parent.busy && parent.imageComparison != nil }
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait { image.nativeToolbarInstalled && toolbar.toolbar.items.count > 10 && (window as? ImageComparisonKeyRouting)?.imageKeyModel === image }
        try require(window.toolbar === toolbar.toolbar && owner.editorToolbar?.toolbar !== window.toolbar)
        let expected: [ImageEditorCommand] = [.overlay, .blend, .link, .widths, .heights, .fit, .original, .zoomIn, .zoomOut, .info, .vertical, .fileMenu, .viewMenu]
        try require(toolbar.toolbar.items.filter { $0.itemIdentifier != .space && $0.itemIdentifier != .flexibleSpace }.map(\.itemIdentifier) == expected.map(\.identifier))
        for command in expected where command.icon != nil {
            let entry = try item(command, toolbar)
            try require(entry.image != nil && entry.menuFormRepresentation?.image != nil && entry.toolTip == command.title)
        }
        try require(!toolbar.validateToolbarItem(try item(.blend, toolbar)))
        let staleBlend = try item(.blend, toolbar).menuFormRepresentation!
        let blend = image.blendAlpha; try send(staleBlend); try require(image.blendAlpha == blend)
        try send(try item(.overlay, toolbar)); try require(image.overlay && image.linked && image.alpha == 0.5)
        try require(!toolbar.validateToolbarItem(try item(.vertical, toolbar)) && !toolbar.validateToolbarItem(try item(.link, toolbar)))
        let oldVertical = image.vertical
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        try require(window.performKeyEquivalent(with: key) && image.vertical == oldVertical)
        try send(staleBlend); try require(image.blendAlpha != blend)
        try send(try item(.overlay, toolbar)); try require(!image.overlay)
        let oldInfo = image.showInfo
        owner.editorOpenWorkflow = MergeEditorOpenWorkflow(window: window, permissions: [], preferences: prefs)
        toolbar.refresh(); try send(try item(.info, toolbar).menuFormRepresentation!)
        let infoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
        _ = window.performKeyEquivalent(with: infoKey)
        owner.openMergeDocument(nil)
        try require(window.attachedSheet == nil)
        try require(image.showInfo == oldInfo && !toolbar.validateToolbarItem(try item(.info, toolbar)))
        owner.editorOpenWorkflow?.retire(); owner.editorOpenWorkflow = nil
        parent.busy = true; toolbar.refresh(); try send(try item(.info, toolbar).menuFormRepresentation!); try require(image.showInfo == oldInfo)
        parent.busy = false; toolbar.refresh()
        let sheet = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 200,height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000,y: -10000)); window.beginSheet(sheet, completionHandler: { _ in })
        toolbar.refresh(); try require(!toolbar.validateToolbarItem(try item(.info, toolbar)))
        try send(try item(.info, toolbar).menuFormRepresentation!); try require(image.showInfo == oldInfo)
        window.endSheet(sheet); sheet.orderOut(nil); window.orderOut(nil); window.alphaValue = 1; window.center(); toolbar.refresh()
        try send(try item(.info, toolbar)); try require(image.showInfo != oldInfo)
        try send(try item(.widths, toolbar)); try require(image.fitWidths)
        let viewMenu = ((try item(.viewMenu, toolbar)).view as! NSPopUpButton).menu!
        viewMenu.update(); try require(viewMenu.items.first(where: { $0.title == "Fit image widths" })?.state == .on)
        let wasDark = image.presentation.darkMode
        try send(viewMenu.items.first(where: { $0.title == "Dark Mode" })!); try require(image.presentation.darkMode != wasDark)
        // Retained native overflow leaves must become inert when the owner closes.
        let retainedInfo = try item(.info, toolbar).menuFormRepresentation!
        let beforeBytes = [try Data(contentsOf: left), try Data(contentsOf: right)]
        try await capture(owner, name: "image-toolbar-comparison")
        window.close(); let after = image.showInfo; try send(retainedInfo)
        try require(image.showInfo == after && !toolbar.validateMenuItem(retainedInfo) && image.playing.isEmpty)
        try require([try Data(contentsOf: left), try Data(contentsOf: right)] == beforeBytes)

        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); _ = try await repo.run(["config", "user.name", "Image Toolbar"])
        _ = try await repo.run(["config", "user.email", "image-toolbar@example.invalid"]); _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try await repo.stage(["left.png", "right.png"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "side"]); try b.write(to: left); try await repo.stage(["left.png"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"]); try ImageOpenVerification.png(1).write(to: left); try await repo.stage(["left.png"]); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge", "side"]); throw NSError(domain: "Expected conflict", code: 1) } catch is GitFailure {}
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let document = try await repo.imageConflictDocument(path: "left.png")!
        let conflict = ImageConflictWindowController(repository: repo, access: nil, document: document, preferences: prefs)
        defer { conflict.close() }
        let selection = conflict.imageToolbar!, selectionModel = conflict.model
        conflict.window?.contentView?.layoutSubtreeIfNeeded(); try await wait { !selectionModel.busy && selectionModel.nativeToolbarInstalled && selection.toolbar.items.count >= 8 && commandIsEnabled(.info,selection) && commandIsEnabled(.vertical,selection) }
        try require(selection.toolbar.items.filter { $0.itemIdentifier != .space && $0.itemIdentifier != .flexibleSpace }.map(\.itemIdentifier) == expected.filter { ![.overlay,.blend,.link,.widths,.heights].contains($0) }.map(\.identifier))
        try send(try item(.info, selection)); try require(selectionModel.showInfo)
        try send(try item(.vertical, selection)); try require(selectionModel.vertical)
        let stale = try item(.info, selection).menuFormRepresentation!
        selectionModel.reload(); let old = selectionModel.showInfo
        try send(stale); try require(selectionModel.showInfo == old && !selection.validateMenuItem(stale))
        try await wait { !selectionModel.busy && commandIsEnabled(.vertical,selection) }
        try send(try item(.vertical, selection)); try require(!selectionModel.vertical)
        try await capture(conflict, name: "image-toolbar-selection")
        conflict.close(); try send(stale); try require(selectionModel.retired && selectionModel.showInfo == old && !selection.validateMenuItem(stale))
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(finalHead == head)
        print("PASS: Image toolbar completed: native source order/artwork, check states, overlay/menu/key gates, busy/sheet/retired refusal, source preview controls and selection mode, immutable input/HEAD/index. Owners closed.")
    }
}
