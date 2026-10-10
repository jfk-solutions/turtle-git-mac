import AppKit
import SwiftUI
import ImageIO
import TurtleGitCore
import Darwin

@main struct ImageFramesVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func settle() async throws { for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line: line)
    }
    static func sequence(type: CFString, colors: [NSColor], sizes: [CGSize]? = nil) throws -> Data {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data,type,colors.count,nil) else { throw Failure(line: #line) }
        for (index,color) in colors.enumerated() {
            let size = sizes?[index] ?? CGSize(width: 80,height: 60)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: Int(size.width),pixelsHigh: Int(size.height),bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
            let rgb = color.usingColorSpace(.deviceRGB)!
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                bitmap.bitmapData![offset] = UInt8(rgb.redComponent * 255); bitmap.bitmapData![offset + 1] = UInt8(rgb.greenComponent * 255)
                bitmap.bitmapData![offset + 2] = UInt8(rgb.blueComponent * 255); bitmap.bitmapData![offset + 3] = 255
            } }
            let metadata: [CFString: Any] = type as String == "com.compuserve.gif" ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.35]] : [:]
            CGImageDestinationAddImage(writer,bitmap.cgImage!,metadata as CFDictionary)
        }
        try require(CGImageDestinationFinalize(writer)); return data as Data
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func pixel(_ view: NSView) -> NSColor {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds,to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2,y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    }
    @MainActor static func main() async {
        do { try await verify() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root,executable: git)
        _ = try await repo.run(["init","-b","main"])
        _ = try await repo.run(["config","user.name","Image Frame Tests"])
        _ = try await repo.run(["config","user.email","image-frames@example.invalid"])
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let left = root.appendingPathComponent("first.dat"), right = root.appendingPathComponent("second.dat")
        let a = try sequence(type: "com.compuserve.gif" as CFString,colors: [.red,.green,.blue])
        let b = try sequence(type: "com.compuserve.gif" as CFString,colors: [.blue,.red])
        try a.write(to: left); try b.write(to: right); try await repo.stage(["first.dat","second.dat"]); _ = try await repo.commit(message: "frames")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: left,destination: right),permissions: [])
        let window = controller.window!
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000,y: -10000)); window.appearance = NSAppearance(named: .aqua)
        defer { (window as? ImageComparisonKeyRouting)?.imageKeyModel?.stopAllPlayback(); window.close() }
        controller.model.load(); try await wait { !controller.model.busy }
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait { (window as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        let model = (window as! ImageComparisonKeyRouting).imageKeyModel!, host = window.contentView!
        window.orderFront(nil); window.orderOut(nil); try await settle()
        func button(_ title: String) throws -> NSButton {
            guard let button = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == title }) else { throw Failure(line: #line) }
            return button
        }
        func press(_ title: String) throws { try button(title).performClick(nil) }
        func frame(_ base: Bool) -> Int { model.currentImage(base: base)!.frameIndex }
        func scrolls() -> [ImageComparisonScrollView] { descendants(host).compactMap { $0 as? ImageComparisonScrollView } }
        try require(frame(true) == 0 && frame(false) == 0)
        try press("Next image (Base)"); try await settle()
        try require(frame(true) == 1 && frame(false) == 1)
        let green = pixel(scrolls()[0].documentView!), red = pixel(scrolls()[1].documentView!)
        try require(green.greenComponent > 0.9 && red.redComponent > 0.9)
        try press("Next image (Base)"); try press("Next image (Base)")
        try require(frame(true) == 2 && frame(false) == 1)
        try press("Previous image (Base)"); try require(frame(true) == 1 && frame(false) == 0)
        model.linked = false
        try press("Next image (Second image)"); try require(frame(false) == 1 && frame(true) == 1)
        try press("Previous image (Base)"); try require(frame(true) == 0 && frame(false) == 1)
        try press("Previous image (Second image)"); try require(frame(false) == 0)
        if CommandLine.arguments.count > 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[3])
            for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance); model.showInfo = true
                try await settle(); host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds,to: bitmap)
                try bitmap.representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("image-frames-native-" + name + "-2026-10-10.png"))
            }
            model.showInfo = false; window.appearance = NSAppearance(named: .aqua)
        }
        try press("Play images (Base)")
        try require(model.playing == [true])
        try await wait { frame(true) == 1 }; try await wait { frame(true) == 2 }; try await wait { frame(true) == 0 }
        try await settle(); try press("Stop images (Base)")
        let stopped = frame(true); try await Task.sleep(nanoseconds: 450_000_000)
        try require(model.playing.isEmpty && frame(true) == stopped && frame(false) == 0)
        model.linked = true; try press("Play images (Base)")
        try require(model.playing == [true,false]); try await wait { frame(true) == 1 && frame(false) == 1 }
        try await settle(); try press("Stop images (Second image)")
        let linkedLeft = frame(true), linkedRight = frame(false)
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(model.playing.isEmpty && frame(true) == linkedLeft && frame(false) == linkedRight)
        try press("Play images (Base)"); model.overlay = true
        let overlayLeft = frame(true), overlayRight = frame(false)
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(model.playing.isEmpty && frame(true) == overlayLeft && frame(false) == overlayRight)
        model.overlay = false; try await settle()
        try press("Play images (Base)"); controller.model.load()
        try await wait { !controller.model.busy && (window as? ImageComparisonKeyRouting)?.imageKeyModel != nil && (window as? ImageComparisonKeyRouting)?.imageKeyModel !== model }
        try await wait { model.playing.isEmpty }
        let replacement = (window as! ImageComparisonKeyRouting).imageKeyModel!
        replacement.togglePlayback(base: true); try require(!replacement.playing.isEmpty)
        window.close(); try require(replacement.playing.isEmpty)
        // TIFF pages and ICO variants share navigation; ICO has no Play button.
        let pages = root.appendingPathComponent("pages.dat"), icon = root.appendingPathComponent("icon.dat")
        try sequence(type: "public.tiff" as CFString,colors: [.red,.blue],sizes: [CGSize(width: 80,height: 60),CGSize(width: 20,height: 90)]).write(to: pages)
        let sourceIcon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TurtleGitCore/Resources/Icons/fitinwindow.ico")
        try Data(contentsOf: sourceIcon).write(to: icon)
        let pageController = FileComparisonWindowController(comparison: try WorkingFileComparison(base: pages,destination: icon),permissions: [])
        let pageWindow = pageController.window!
        pageWindow.alphaValue = 0; pageWindow.setFrameOrigin(NSPoint(x: -10000,y: -10000))
        defer { (pageWindow as? ImageComparisonKeyRouting)?.imageKeyModel?.stopAllPlayback(); pageWindow.close() }
        pageController.model.load(); try await wait { !pageController.model.busy }
        pageWindow.contentView?.layoutSubtreeIfNeeded()
        try await wait { (pageWindow as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        let pageModel = (pageWindow as! ImageComparisonKeyRouting).imageKeyModel!, pageHost = pageWindow.contentView!
        try await settle(); pageModel.linked = false; pageModel.originalSize()
        let controls = descendants(pageHost).compactMap { $0 as? NSButton }
        try require(!controls.contains { $0.accessibilityLabel() == "Play images (Second image)" })
        controls.first { $0.accessibilityLabel() == "Next image (Base)" }!.performClick(nil)
        controls.first { $0.accessibilityLabel() == "Next image (Second image)" }!.performClick(nil)
        try await settle()
        try require(pageModel.currentImage(base: true)?.size == CGSize(width: 20,height: 90))
        try require(pageModel.currentImage(base: false)?.size == CGSize(width: 24,height: 24) && pageModel.zoom == 1)
        let blue = pixel(descendants(pageHost).compactMap { $0 as? ImageComparisonScrollView }[0].documentView!)
        try require(blue.blueComponent > 0.9)
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterA = try Data(contentsOf: left), afterB = try Data(contentsOf: right)
        try require(afterHead == head && afterIndex == index && afterA == a && afterB == b)
        // A real multi-frame conflict: selecting a later visible frame must
        // copy the original full GIF and retain unmerged stages on No.
        _ = try await repo.run(["switch","-c","frame-side"])
        try b.write(to: left); try await repo.stage(["first.dat"]); _ = try await repo.commit(message: "theirs frames")
        _ = try await repo.run(["switch","main"])
        let mine = try sequence(type: "com.compuserve.gif" as CFString,colors: [.green,.red,.blue])
        try mine.write(to: left); try await repo.stage(["first.dat"]); _ = try await repo.commit(message: "mine frames")
        do { _ = try await repo.run(["merge","frame-side"]); throw Failure(line: #line) } catch is GitFailure {}
        let conflictHead = try await repo.run(["rev-parse","HEAD"]).stdout
        let conflictIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        guard let document = try await repo.imageConflictDocument(path: "first.dat") else { throw Failure(line: #line) }
        let conflict = ImageConflictWindowController(repository: repo,access: nil,document: document)
        let conflictWindow = conflict.window!, conflictHost = conflictWindow.contentView!
        conflictWindow.alphaValue = 0; conflictWindow.setFrameOrigin(NSPoint(x: -10000,y: -10000))
        defer { if let sheet = conflictWindow.attachedSheet { conflictWindow.endSheet(sheet,returnCode: .abort) }; conflictWindow.close() }
        conflictWindow.orderFront(nil); conflictWindow.orderOut(nil); try await settle()
        func conflictButton(_ title: String) throws -> NSButton {
            guard let button = descendants(conflictHost).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == title }) else { throw Failure(line: #line) }
            return button
        }
        let minePane = conflict.model.panes[.mine]!, basePane = conflict.model.panes[.base]!, theirsPane = conflict.model.panes[.theirs]!
        try conflictButton("Next image (Mine)").performClick(nil); try await settle()
        try require(minePane.currentImage(base: true)?.frameIndex == 1 && basePane.currentImage(base: true)?.frameIndex == 0 && theirsPane.currentImage(base: true)?.frameIndex == 0)
        let minePixel = pixel(descendants(conflictHost).compactMap { $0 as? ImageComparisonScrollView }[0].documentView!)
        try require(minePixel.redComponent > 0.9)
        try conflictButton("Play images (Mine)").performClick(nil)
        try require(minePane.playing == [true] && basePane.playing.isEmpty && theirsPane.playing.isEmpty)
        try await wait { minePane.currentImage(base: true)?.frameIndex == 2 }; try await settle()
        try conflictButton("Stop images (Mine)").performClick(nil); try require(minePane.playing.isEmpty)
        try conflictButton("Select Mine").performClick(nil)
        try await wait { conflictWindow.attachedSheet != nil }
        let sheet = conflictWindow.attachedSheet!
        sheet.alphaValue = 0; conflictWindow.orderOut(nil); sheet.orderOut(nil)
        try require(!conflictWindow.isVisible && !sheet.isVisible)
        guard let no = descendants(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "No" }) else { throw Failure(line: #line) }
        no.performClick(nil); try await wait { !conflict.model.busy }
        let copied = try Data(contentsOf: left), unmergedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(conflict.model.error == nil && copied == mine && ComparisonImage(bytes: copied)?.frameCount == 3 && unmergedIndex == conflictIndex)
        try await wait { (try? conflictButton("Play images (Mine)").isEnabled) == true }
        try conflictButton("Play images (Mine)").performClick(nil); try require(!minePane.playing.isEmpty)
        conflictWindow.close(); try require(conflict.model.retired && conflict.model.panes.values.allSatisfy { $0.playing.isEmpty })
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout, untouched = try Data(contentsOf: right)
        try require(finalHead == conflictHead && untouched == b)
        print("PASS: Native linked/unlinked frame buttons with unequal counts and actual GIF frame pixels; Play/Stop, wrapping, independent/linked timers, stop from second pane, overlay/source replacement/window-close retirement; TIFF page pixels and dimensions, ICO variants without Play, unchanged HEAD/index/encoded files; real multi-frame conflict with independent Mine controls, original full-GIF selection on No, unmerged stages and close cancellation. All owned windows closed.")
    }
}
