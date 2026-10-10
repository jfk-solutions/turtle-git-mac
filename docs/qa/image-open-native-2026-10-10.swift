import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct ImageOpenVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line: line)
    }
    @MainActor static func settle() async throws { try await Task.sleep(nanoseconds: 200_000_000) }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func png(_ channel: Int, width: Int = 80, height: Int = 60) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        for y in 0..<height { for x in 0..<width { let offset = y * bitmap.bytesPerRow + x * 4; bitmap.bitmapData![offset + channel] = 255; bitmap.bitmapData![offset + 3] = 255 } }
        return bitmap.representation(using: .png, properties: [:])!
    }
    @MainActor static func press(_ title: String, window: NSWindow) throws {
        guard let button = descendants(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title || $0.accessibilityLabel() == title }) else { throw Failure(line: #line) }
        try require(button.isEnabled); print("PRESS", title); fflush(stdout); button.performClick(nil); print("PRESSED", title); fflush(stdout)
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await verify(); fflush(stdout); exit(0) }
            catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
        }
        // Native file panels require a live AppKit event loop. A successful
        // process exit before verify returns is never acceptance evidence.
        NSApplication.shared.run()
    }
    final class ScopeRecorder { var starts = 0; var stops = 0 }
    struct ScopeProvider: RepositoryBookmarkProvider {
        let recorder: ScopeRecorder
        func create(for url: URL) throws -> Data { Data() }
        func resolve(_ data: Data) throws -> ResolvedBookmark { throw Failure(line: #line) }
        func startAccessing(_ url: URL) -> Bool { recorder.starts += 1; return true }
        func stopAccessing(_ url: URL) { recorder.stops += 1 }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Image Open Tests"])
        _ = try await repo.run(["config", "user.email", "image-open@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let left = root.appendingPathComponent("left.dat"), right = root.appendingPathComponent("right.dat"), other = root.appendingPathComponent("other.dat")
        let a = png(0), b = png(2), c = png(1, width: 120, height: 40)
        try a.write(to: left); try b.write(to: right); try c.write(to: other)
        try await repo.stage(["left.dat", "right.dat", "other.dat"]); _ = try await repo.commit(message: "images")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: left, destination: right), permissions: [])
        let window = controller.window!; window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        defer { window.close() }
        controller.model.makeImageLoader = { path, leases in
            let loader = ImageLoadWindowController(leftPath: path, permissions: leases)
            loader.window!.alphaValue = 0
            loader.makeOpenPanel = { let panel = NSOpenPanel(); panel.alphaValue = 0; return panel }
            return loader
        }
        controller.model.load(); try await wait { !controller.model.busy }; window.contentView?.layoutSubtreeIfNeeded()
        try await wait { (window as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        window.orderFront(nil); window.orderOut(nil); try await settle()
        let pane = (window as! ImageComparisonKeyRouting).imageKeyModel!
        pane.vertical = true; pane.linked = false; pane.showInfo = true; pane.alpha = 0.75
        pane.toggleWidths(); pane.toggleHeights()
        try require(pane.fitWidths && pane.fitHeights)
        @MainActor func open() async throws -> ImageLoadWindowController {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31)!
            try require(window.performKeyEquivalent(with: event)); try await wait { window.attachedSheet != nil }
            window.orderOut(nil); window.attachedSheet!.orderOut(nil)
            guard let loader = window.attachedSheet!.delegate as? ImageLoadWindowController else { throw Failure(line: #line) }
            try require(!window.isVisible && !loader.window!.isVisible && !controller.windowShouldClose(window))
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
            return loader
        }
        let initial = controller.model.document!
        print("FIRST OPEN"); fflush(stdout)
        var loader = try await open()
        try require(loader.left.stringValue == left.path && loader.right.stringValue.isEmpty)
        if CommandLine.arguments.count > 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[3])
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                loader.window!.appearance = NSAppearance(named: appearance); loader.window!.makeFirstResponder(nil)
                loader.window!.orderFront(nil); loader.window!.orderOut(nil); try await settle()
                let host = loader.window!.contentView!, bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("image-open-native-" + mode + "-2026-10-10.png"))
            }
        }
        loader.left.stringValue = other.path; try press("Cancel", window: loader.window!); try await wait { window.attachedSheet == nil }
        try require(controller.model.document?.base.bytes == initial.base.bytes && controller.model.document?.destination.bytes == initial.destination.bytes)
        loader = try await open(); loader.left.stringValue = root.appendingPathComponent("missing.dat").path
        try press("OK", window: loader.window!); try require(!loader.retired && window.attachedSheet != nil)
        try require(controller.model.document?.base.bytes == a)
        loader.left.stringValue = other.path; loader.right.stringValue = other.path
        try press("OK", window: loader.window!); try await wait { window.attachedSheet == nil && !controller.model.busy }; try await settle()
        try require(controller.model.document?.base.bytes == c && controller.model.document?.destination.bytes == c)
        try require(controller.model.imageComparison != nil && pane.vertical && !pane.linked && pane.showInfo && pane.alpha == 0.75 && pane.fit)
        try require(window.title.contains("other.dat") && (window as! ImageComparisonKeyRouting).imageKeyModel === pane)
        try require(pane.fitWidths && pane.fitHeights)
        try require(pane.displaySizing.base.pixels == CGSize(width: 120, height: 40))
        loader = try await open(); loader.left.stringValue = ""; loader.right.stringValue = right.path
        try press("OK", window: loader.window!); try await wait { window.attachedSheet == nil && !controller.model.busy }; try await settle()
        try require(controller.model.imageComparison?.base == nil && controller.model.imageComparison?.destination != nil)
        try require(pane.fitWidths && pane.fitHeights)
        loader = try await open(); loader.left.stringValue = ""; loader.right.stringValue = ""
        try press("OK", window: loader.window!); try await wait { window.attachedSheet == nil && !controller.model.busy }; try await settle()
        try require(controller.model.imageComparison != nil && controller.model.document?.base.bytes.isEmpty == true && controller.model.document?.destination.bytes.isEmpty == true)
        // An ungranted typed path must ask for a native file grant before acceptance.
        loader = try await open(); loader.requiresScopes = true; loader.left.stringValue = left.path
        var accepted = false; loader.onAccepted = { _, _ in accepted = true }
        try press("OK", window: loader.window!); try await wait { loader.window?.attachedSheet != nil }
        print("AUTHORIZATION PICKER"); fflush(stdout)
        let picker = loader.window!.attachedSheet as! NSOpenPanel
        picker.orderOut(nil); loader.window!.orderOut(nil); window.orderOut(nil)
        try require(!accepted && picker.allowsOtherFileTypes && !picker.canChooseDirectories && !loader.windowShouldClose(loader.window!))
        print("CANCEL PICKER"); fflush(stdout); picker.cancel(nil); print("CANCELLED PICKER"); fflush(stdout); try await wait { loader.window?.attachedSheet == nil }; try await settle()
        try require(!accepted && !loader.retired)
        try press("Cancel", window: loader.window!); try await wait { window.attachedSheet == nil }
        // Granted standalone acceptance keeps the lease in the receiving viewer.
        let recorder = ScopeRecorder()
        var lease: RepositoryAccessLease? = RepositoryAccessLease(url: other, provider: ScopeProvider(recorder: recorder))
        weak var witness = lease
        var granted: ImageLoadWindowController? = ImageLoadWindowController(leftPath: other.path, permissions: [lease!])
        granted!.requiresScopes = true; granted!.window!.alphaValue = 0
        granted!.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        var standalone: FileComparisonWindowController?
        granted!.onAccepted = { inputs, permissions in
            standalone = FileComparisonWindowController(images: inputs, permissions: permissions)
            standalone!.window!.alphaValue = 0
            standalone!.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            standalone!.model.load()
        }
        try press("OK", window: granted!.window!)
        try await wait { standalone != nil && standalone?.model.busy == false }
        try require(standalone?.model.imageComparison?.base != nil && standalone?.model.imageComparison?.destination == nil && recorder.starts == 1)
        granted = nil; lease = nil; try require(witness != nil && recorder.stops == 0)
        standalone?.window?.close(); standalone = nil
        try await wait { witness == nil }; try require(recorder.stops == 1)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let finalA = try Data(contentsOf: left), finalB = try Data(contentsOf: right), finalC = try Data(contentsOf: other)
        try require(finalHead == head && finalIndex == index && finalA == a && finalB == b && finalC == c)
        print("PASS: Native Cmd+O, left-only prefill, two path fields and actual OK/Cancel; missing path retains chooser/current images, identical and empty sides, replacement title/fit and retained view modes; ungranted typed path opens native file authorization and cancellation prevents acceptance; pregranted standalone acceptance retains and releases its lease; close/Quit guards; unchanged HEAD/index/file bytes. All owned windows closed.")
    }
}
