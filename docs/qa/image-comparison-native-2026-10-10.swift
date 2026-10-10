import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct ImageComparisonVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func settle() async throws { for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line: #line)
    }
    static func png(_ color: NSColor, width: Int, height: Int) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let rgb = color.usingColorSpace(.deviceRGB)!
        let pixels = bitmap.bitmapData!
        for y in 0..<height { for x in 0..<width {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = UInt8(rgb.redComponent * 255); pixels[offset + 1] = UInt8(rgb.greenComponent * 255)
            pixels[offset + 2] = UInt8(rgb.blueComponent * 255); pixels[offset + 3] = UInt8(rgb.alphaComponent * 255)
        } }
        return bitmap.representation(using: .png, properties: [:])!
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func pixel(_ view: NSView) throws -> NSColor {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    }
    @MainActor static func main() async {
        do { try await verify() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Image Tests"])
        _ = try await repo.run(["config", "user.email", "image@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let file = root.appendingPathComponent("image.dat")
        try png(.red, width: 80, height: 60).write(to: file)
        try await repo.stage(["image.dat"]); _ = try await repo.commit(message: "red")
        try png(.blue, width: 80, height: 60).write(to: file)
        _ = try await repo.status()
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let bytes = try Data(contentsOf: file)
        let snapshot = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
        let controller = FileComparisonWindowController(repository: repo, access: nil, snapshot: snapshot, path: "image.dat")
        defer { controller.window?.close() }
        controller.model.load()
        try await wait { !controller.model.busy }
        if let error = controller.model.error { print("Routing error: " + error) }; print("Comparison files: " + snapshot.files.map(\.path).joined(separator: ","))
        try require(controller.model.error == nil && controller.model.imageComparison != nil)
        try require(controller.window?.title.hasSuffix("TurtleGitIDiff") == true)
        try require(controller.model.alignment == nil && !controller.model.dirty)
        let images = controller.model.imageComparison!, document = controller.model.document!
        let model = ImageComparisonViewModel()
        let host = NSHostingView(rootView: ImageComparisonDialog(images: images, document: document, model: model))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded(); try await settle()
        func scrolls() -> [NSScrollView] { descendants(host).compactMap { $0 as? NSScrollView }.filter { String(describing: type(of: $0)).contains("ImageComparisonScrollView") } }
        try require(scrolls().count == 2)
        let colors = try scrolls().map { try pixel($0.documentView!) }
        try require(colors[0].redComponent > 0.9 && colors[1].blueComponent > 0.9)
        if CommandLine.arguments.count > 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[3])
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance); model.showInfo = true
                try await settle(); host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("image-comparison-native-" + name + "-2026-10-10.png"))
            }
            model.showInfo = false; window.appearance = NSAppearance(named: .aqua)
        }
        try await settle()
        let references = try scrolls().map { try pixel($0.documentView!) }
        let fitted = model.fittedZoom
        model.changeZoom(zoomIn: true); try require(fitted == 1 && abs(model.zoom - 1.2) < 0.001)
        model.originalSize(); try require(model.zoom == 1 && !model.fit)
        model.zoom = 16; try await settle()
        let panes = scrolls()
        panes[0].contentView.scroll(to: CGPoint(x: 120,y: 100)); panes[0].reflectScrolledClipView(panes[0].contentView)
        try await settle(); try require(panes[1].contentView.bounds.origin == panes[0].contentView.bounds.origin)
        model.linked = false
        panes[0].contentView.scroll(to: CGPoint(x: 180,y: 150)); try await settle()
        try require(panes[1].contentView.bounds.origin != panes[0].contentView.bounds.origin)
        model.vertical = true; model.fit = true; try await settle(); try require(scrolls().count == 2)
        model.overlay = true; try await settle(); try require(model.linked && scrolls().count == 1)
        guard let slider = descendants(host).compactMap({ $0 as? ImageComparisonAlphaSlider }).first,
              let sliderCell = slider.cell as? NSSliderCell else { throw Failure(line: #line) }
        try require(slider.numberOfTickMarks == 17 && slider.allowsTickMarkValuesOnly)
        let bar = sliderCell.barRect(flipped: slider.isFlipped)
        try require(bar.height > 0)
        for (fraction, type) in [(0.0, NSEvent.EventType.leftMouseDown), (0.5, .leftMouseDragged), (1.0, .leftMouseUp)] {
            let y = slider.isFlipped ? bar.minY + bar.height * fraction : bar.maxY - bar.height * fraction
            let point = slider.convert(NSPoint(x: bar.midX,y: y), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            switch type { case .leftMouseDown: slider.mouseDown(with: event); case .leftMouseDragged: slider.mouseDragged(with: event); default: slider.mouseUp(with: event) }
            try require(abs(model.alpha - fraction) < 0.001)
            try require(abs((slider.accessibilityValue() as! NSNumber).doubleValue - fraction * 100) < 0.001)
        }
        slider.doubleValue = 1
        let topKnob = sliderCell.knobRect(flipped: slider.isFlipped).midY
        slider.doubleValue = 0
        let bottomKnob = sliderCell.knobRect(flipped: slider.isFlipped).midY
        try require(slider.isFlipped ? topKnob < bottomKnob : topKnob > bottomKnob)
        slider.setAccessibilityValue(NSNumber(value: 50))
        try require(model.alpha == 0.5)
        try require(slider.accessibilityPerformIncrement() && model.alpha == 9.0 / 16)
        try require(slider.accessibilityPerformDecrement() && model.alpha == 0.5)
        let cgWheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        cgWheel.flags = [.maskControl, .maskShift]
        let wheel = NSEvent(cgEvent: cgWheel)!
        try require(!wheel.hasPreciseScrollingDeltas && wheel.scrollingDeltaY == 0 && wheel.scrollingDeltaX == 1)
        scrolls()[0].scrollWheel(with: wheel)
        try require(model.alpha == 0.25)
        model.blendAlpha = false
        scrolls()[0].scrollWheel(with: wheel)
        try require(model.alpha == 0 && !model.blendAlpha)
        model.blendAlpha = true
        model.alpha = 0; try await settle(); let red = try pixel(scrolls()[0].documentView!)
        model.alpha = 1; try await settle(); let blue = try pixel(scrolls()[0].documentView!)
        model.alpha = 0.5; try await settle(); let blend = try pixel(scrolls()[0].documentView!)
        print("Alpha raster colors: \(red), \(blue), \(blend)")
        // Compare endpoints with the same native rendering/color profile rather
        // than assuming display-device RGB is the PNG's source color space.
        for (actual, expected) in [(red, references[0]), (blue, references[1])] {
            try require(abs(actual.redComponent - expected.redComponent) < 0.04)
            try require(abs(actual.greenComponent - expected.greenComponent) < 0.04)
            try require(abs(actual.blueComponent - expected.blueComponent) < 0.04)
        }
        try require(blend.redComponent > 0.35 && blend.redComponent < 0.65 && blend.blueComponent > 0.35 && blend.blueComponent < 0.65)
        model.blendAlpha = false; try await settle()
        let xor = try pixel(scrolls()[0].documentView!)
        try require(xor.greenComponent > xor.redComponent + 0.3 && xor.greenComponent > xor.blueComponent + 0.3)
        try require(!descendants(host).contains { ($0 as? NSSlider)?.accessibilityLabel() == "Image blend alpha" })
        let equal = try WorkingFileComparison(base: file, destination: file).read()
        host.rootView = ImageComparisonDialog(images: ImageComparisonDocument(equal)!, document: equal, model: model)
        try await settle()
        let unchanged = try pixel(scrolls()[0].documentView!)
        try require(unchanged.redComponent > 0.95 && unchanged.greenComponent > 0.95 && unchanged.blueComponent > 0.95)
        host.rootView = ImageComparisonDialog(images: images, document: document, model: model)
        model.blendAlpha = true; model.alpha = 1; try await settle()
        let restored = try pixel(scrolls()[0].documentView!)
        try require(abs(restored.blueComponent - blue.blueComponent) < 0.04)
        let wideFile = root.appendingPathComponent("wide.dat")
        try png(.blue, width: 160, height: 20).write(to: wideFile)
        defer { try? FileManager.default.removeItem(at: wideFile) }
        let unequal = try WorkingFileComparison(base: file, destination: wideFile).read()
        let sizedModel = ImageComparisonViewModel()
        let sizedHost = NSHostingView(rootView: ImageComparisonDialog(images: ImageComparisonDocument(unequal)!, document: unequal, model: sizedModel))
        let sizedWindow = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1200,height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        sizedWindow.isReleasedWhenClosed = false; sizedWindow.appearance = NSAppearance(named: .aqua); sizedWindow.contentView = sizedHost
        defer { sizedWindow.close() }
        func extents() throws -> [CGSize] {
            try descendants(sizedHost).compactMap { $0 as? NSScrollView }.filter { String(describing: type(of: $0)).contains("ImageComparisonScrollView") }.map { scroll in
                let canvas = scroll.documentView!, bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                func blue(_ x: Int, _ y: Int) -> Bool {
                    let color = bitmap.colorAt(x: x,y: y)!.usingColorSpace(.deviceRGB)!
                    return color.blueComponent > color.redComponent + 0.4 && color.blueComponent > color.greenComponent + 0.4
                }
                let width = (0..<bitmap.pixelsWide).filter { blue($0,bitmap.pixelsHigh / 2) }.count
                let height = (0..<bitmap.pixelsHigh).filter { blue(bitmap.pixelsWide / 2,$0) }.count
                return CGSize(width: CGFloat(width) * canvas.bounds.width / CGFloat(bitmap.pixelsWide), height: CGFloat(height) * canvas.bounds.height / CGFloat(bitmap.pixelsHigh))
            }
        }
        func sizes(_ expected: [CGSize]) throws {
            let actual = try extents(); try require(actual.count == expected.count)
            for (a,b) in zip(actual,expected) { try require(abs(a.width-b.width) < 2 && abs(a.height-b.height) < 2) }
        }
        sizedHost.layoutSubtreeIfNeeded(); try await settle()
        try sizes([CGSize(width: 80,height: 60),CGSize(width: 160,height: 20)])
        sizedModel.toggleWidths(); try await settle(); try sizes([CGSize(width: 80,height: 60),CGSize(width: 80,height: 10)])
        sizedModel.toggleWidths(); sizedModel.toggleHeights(); try await settle(); try sizes([CGSize(width: 80,height: 60),CGSize(width: 480,height: 60)])
        sizedModel.toggleWidths(); try await settle(); try sizes([CGSize(width: 80,height: 10),CGSize(width: 80,height: 10)])
        sizedModel.changeZoom(zoomIn: true); try await settle(); try sizes([CGSize(width: 96,height: 72),CGSize(width: 96,height: 72)])
        sizedModel.originalSize(); try await settle(); try sizes([CGSize(width: 160,height: 20),CGSize(width: 160,height: 20)])
        // Exercise the real comparison window's scoped key bridge, rather than
        // calling the model directly or installing a global event monitor.
        let routedWindow = controller.window!
        routedWindow.contentView?.layoutSubtreeIfNeeded()
        try await wait { (routedWindow as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        let route = routedWindow as! ImageComparisonKeyRouting
        let routedModel = route.imageKeyModel!
        func key(_ characters: String, _ code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: routedWindow.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            try require(routedWindow.performKeyEquivalent(with: event))
        }
        try key("o",31); try require(routedModel.overlay && routedModel.alpha == 0.5)
        try key("",126); try require(routedModel.alpha == 0)
        try key("",125); try require(routedModel.alpha == 1)
        try key("",123); try require(routedModel.alpha == 0.5)
        try key(" ",49); try require(routedModel.alpha == 0)
        try key(" ",49); try require(routedModel.alpha == 1)
        try key("v",9,flags: .command); try require(routedModel.vertical)
        try key("o",31); try require(!routedModel.overlay)
        try key("s",1); try require(!routedModel.fit && routedModel.zoom == 1)
        try key("+",24,flags: .shift); try require(abs(routedModel.zoom - 1.2) < 0.001)
        try key("-",27); try require(routedModel.zoom == 1)
        try key("w",13); try require(routedModel.fitWidths)
        try key("h",4); try require(routedModel.fitHeights)
        try key("i",34); try require(routedModel.showInfo)
        try key("f",3); try require(routedModel.fit)
        try require(!model.fitWidths && !model.fitHeights && !model.showInfo)
        routedWindow.close()
        try require(route.imageKeysRetired && route.imageKeyModel == nil && route.imageKeyOwner == nil)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let afterBytes = try Data(contentsOf: file)
        try require(afterHead == head && afterIndex == index && afterBytes == bytes)
        print("PASS: Actual Git image routing without image extension, native pane raster colors, fit/manual zoom, linked/unlinked scrolling, vertical/overlay transitions, alpha endpoints/midpoint, XOR changed/unchanged pixels and slider removal/restoration, linked width/height/both native pixel extents with unequal aspect ratios, source stepped zoom, no enlargement on fit, 17-position native slider click/drag/release and accessibility actions, Control-Shift wheel in Alpha/XOR, real-window keyboard routing/retirement, and unchanged HEAD/index/file bytes.")
    }
}
