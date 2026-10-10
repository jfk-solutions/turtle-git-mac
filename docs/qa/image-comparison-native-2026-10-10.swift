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
        model.changeZoom(1.25); try require(abs(model.zoom - min(16, fitted * 1.25)) < 0.001)
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
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let afterBytes = try Data(contentsOf: file)
        try require(afterHead == head && afterIndex == index && afterBytes == bytes)
        print("PASS: Actual Git image routing without image extension, native pane raster colors, fit/manual zoom, linked/unlinked scrolling, vertical/overlay transitions, alpha endpoints/midpoint and unchanged HEAD/index/file bytes.")
    }
}
