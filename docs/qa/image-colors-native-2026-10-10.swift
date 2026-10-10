import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct ImageColorsVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line: line)
    }
    @MainActor static func settle() async throws { try await Task.sleep(nanoseconds: 200_000_000) }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func png(_ channel: Int) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        for y in 25..<35 { for x in 35..<45 {
            let offset = y * bitmap.bytesPerRow + x * 4
            bitmap.bitmapData![offset + channel] = 255; bitmap.bitmapData![offset + 3] = 255
        } }
        return bitmap.representation(using: .png, properties: [:])!
    }
    @MainActor static func colors(_ window: NSWindow) -> [NSColor] {
        descendants(window.contentView!).compactMap { $0 as? ImageComparisonScrollView }.map { scroll in
            let view = scroll.documentView!, bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // This lies within the source image's transparent pixels at 100%.
            return bitmap.colorAt(x: bitmap.pixelsWide / 2 - Int(30 * (window.backingScaleFactor)),
                                  y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
        }
    }
    @MainActor final class Swatch: NSView {
        let color: NSColor
        init(color: NSColor) { self.color = color; super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8)) }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) { color.setFill(); dirtyRect.fill() }
    }
    @MainActor static func reference(_ color: NSColor, window: NSWindow) -> NSColor {
        let view = Swatch(color: color); window.contentView!.addSubview(view)
        defer { view.removeFromSuperview() }
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.colorAt(x: 2, y: 2)!.usingColorSpace(.deviceRGB)!
    }
    static func matches(_ actual: [NSColor], _ expected: NSColor) -> Bool {
        !actual.isEmpty && actual.allSatisfy {
            abs($0.redComponent - expected.redComponent) < 0.03 && abs($0.greenComponent - expected.greenComponent) < 0.03 && abs($0.blueComponent - expected.blueComponent) < 0.03
        }
    }
    @MainActor static func choose(_ presentation: ImageWindowPresentation, window: NSWindow, color: NSColor, answer: String) async throws {
        presentation.chooseTransparentColor(); try await wait { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        let canClose = (window.delegate as? FileComparisonWindowController)?.windowShouldClose(window) ?? (window.delegate as? ImageConflictWindowController)?.windowShouldClose(window)
        try require(canClose == false)
        sheet.alphaValue = 0; window.orderOut(nil); sheet.orderOut(nil)
        try require(!sheet.isVisible && !window.isVisible)
        guard let well = descendants(sheet.contentView!).compactMap({ $0 as? NSColorWell }).first else { throw Failure(line: #line) }
        well.color = color
        if let model = (window as? ImageComparisonKeyRouting)?.imageKeyModel {
            model.showInfo.toggle(); try await settle()
            try require(window.attachedSheet === sheet)
        }
        guard let button = descendants(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == answer }) else { throw Failure(line: #line) }
        button.performClick(nil); try await wait { window.attachedSheet == nil }; try await settle()
    }
    @MainActor static func keyD(_ window: NSWindow) throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)!
        try require(window.performKeyEquivalent(with: event))
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let originalAppearance = NSApp.appearance
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Image Color Tests"])
        _ = try await repo.run(["config", "user.email", "image-colors@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let first = root.appendingPathComponent("first.dat"), second = root.appendingPathComponent("second.dat")
        let red = png(0), blue = png(2), green = png(1)
        try red.write(to: first); try blue.write(to: second); try await repo.stage(["first.dat", "second.dat"])
        _ = try await repo.commit(message: "transparent images")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: first, destination: second), permissions: [])
        let window = controller.window!
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        controller.model.load(); try await wait { !controller.model.busy }
        window.contentView?.layoutSubtreeIfNeeded(); try await wait { (window as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        let model = (window as! ImageComparisonKeyRouting).imageKeyModel!
        window.orderFront(nil); window.orderOut(nil); model.originalSize(); try await settle()
        try await choose(model.presentation, window: window, color: .green, answer: "Cancel")
        try require(model.presentation.transparentColor == nil)
        try await choose(model.presentation, window: window, color: .green, answer: "OK")
        let greenReference = reference(.green, window: window)
        try require(colors(window).count == 2 && matches(colors(window), greenReference))
        model.overlay = true; try await settle()
        try require(matches(colors(window), greenReference))
        model.blendAlpha = false; try await settle()
        try require(colors(window).allSatisfy { $0.redComponent > 0.9 && $0.greenComponent > 0.9 && $0.blueComponent > 0.9 })
        model.overlay = false; try keyD(window); try await settle()
        try require(model.presentation.darkMode && model.presentation.transparentColor == nil && colors(window).allSatisfy { $0.redComponent < 0.3 && $0.greenComponent < 0.3 })
        try await choose(model.presentation, window: window, color: .white, answer: "OK")
        try require(colors(window).allSatisfy { $0.redComponent < 0.3 && $0.greenComponent < 0.3 })
        let custom = NSColor(deviceRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        try await choose(model.presentation, window: window, color: custom, answer: "OK")
        // Fixed RGB expected from the pinned CTheme HSL inversion for 26/51/77.
        let expected = reference(NSColor(deviceRed: 178.0 / 255, green: 203.0 / 255, blue: 229.0 / 255, alpha: 1), window: window)
        try require(matches(colors(window), expected))
        try keyD(window); try await settle(); try require(!model.presentation.darkMode && model.presentation.transparentColor == nil)
        try require(NSApp.appearance === originalAppearance)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let afterFirst = try Data(contentsOf: first), afterSecond = try Data(contentsOf: second)
        try require(afterHead == head && afterIndex == index && afterFirst == red && afterSecond == blue)
        // Source SetPic retains the chosen background; the new pane model
        // must share its owning window's presentation after reloading.
        try await choose(model.presentation, window: window, color: .green, answer: "OK")
        controller.model.load(); try await wait { !controller.model.busy }
        try await wait { (window as? ImageComparisonKeyRouting)?.imageKeyModel != nil && (window as? ImageComparisonKeyRouting)?.imageKeyModel !== model }
        let replacement = (window as! ImageComparisonKeyRouting).imageKeyModel!
        replacement.originalSize(); try await settle()
        try require(replacement.presentation === model.presentation && matches(colors(window), greenReference))
        try keyD(window); try await settle(); try require(replacement.presentation.darkMode && replacement.presentation.transparentColor == nil)
        try keyD(window); try await settle()
        _ = try await repo.run(["switch", "-c", "color-side"])
        try blue.write(to: first); try await repo.stage(["first.dat"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try green.write(to: first); try await repo.stage(["first.dat"]); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge", "color-side"]); throw Failure(line: #line) } catch is GitFailure {}
        guard let document = try await repo.imageConflictDocument(path: "first.dat") else { throw Failure(line: #line) }
        let conflictIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), conflictBytes = try Data(contentsOf: first)
        let conflict = ImageConflictWindowController(repository: repo, access: nil, document: document), conflictWindow = conflict.window!
        conflictWindow.alphaValue = 0; conflictWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000)); conflictWindow.appearance = NSAppearance(named: .aqua)
        defer { conflictWindow.close() }
        conflictWindow.orderFront(nil); conflictWindow.orderOut(nil); conflict.model.originalSize(); try await settle()
        try await choose(conflict.model.presentation, window: conflictWindow, color: .cyan, answer: "OK")
        try require(colors(conflictWindow).count == 3 && matches(colors(conflictWindow), reference(.cyan, window: conflictWindow)))
        try keyD(conflictWindow); try await settle()
        try require(conflict.model.presentation.darkMode && conflict.model.presentation.transparentColor == nil && !model.presentation.darkMode)
        if CommandLine.arguments.count > 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[3])
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                conflictWindow.appearance = NSAppearance(named: appearance)
                try await choose(conflict.model.presentation, window: conflictWindow, color: .cyan, answer: "OK")
                conflict.model.showInfo = true; try await settle()
                let host = conflictWindow.contentView!, bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("image-colors-native-" + name + "-2026-10-10.png"))
            }
        }
        let finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), finalBytes = try Data(contentsOf: first)
        try require(finalIndex == conflictIndex && finalBytes == conflictBytes)
        let priorColor = conflict.model.presentation.transparentColor
        conflict.model.presentation.chooseTransparentColor(); try await wait { conflictWindow.attachedSheet != nil }
        let pending = conflictWindow.attachedSheet!
        pending.alphaValue = 0; pending.orderOut(nil); conflictWindow.orderOut(nil)
        let pendingWell = descendants(pending.contentView!).compactMap { $0 as? NSColorWell }.first!
        pendingWell.color = .red
        conflictWindow.close(); try await settle()
        try require(conflict.model.retired && conflictWindow.attachedSheet == nil && conflict.model.presentation.transparentColor == priorColor)
        conflict.model.presentation.chooseTransparentColor(); try require(conflictWindow.attachedSheet == nil)
        print("PASS: Actual native color wells and OK/Cancel sheets; transparent pixels in both comparison panes, alpha/XOR background; scoped D light/dark and theme reset, white/custom dark colors; shared three-pane conflict colors and independent window appearance; unchanged Git/image bytes; native close/Quit guards, sheet survival across native view updates, color retention across source reload and pending-sheet retirement without applying draft color. All owned windows closed.")
    }
}
