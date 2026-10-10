import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct ImageConflictVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func settle() async throws { for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line: line)
    }
    static func png(_ color: NSColor) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let rgb = color.usingColorSpace(.deviceRGB)!
        for y in 0..<60 { for x in 0..<80 {
            let offset = y * bitmap.bytesPerRow + x * 4
            bitmap.bitmapData![offset] = UInt8(rgb.redComponent * 255); bitmap.bitmapData![offset + 1] = UInt8(rgb.greenComponent * 255)
            bitmap.bitmapData![offset + 2] = UInt8(rgb.blueComponent * 255); bitmap.bitmapData![offset + 3] = 255
        } }
        return bitmap.representation(using: .png, properties: [:])!
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
        _ = try await repo.run(["config","user.name","Image Conflict Tests"])
        _ = try await repo.run(["config","user.email","image-conflict@example.invalid"])
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let path = "image.dat", file = root.appendingPathComponent(path)
        let base = png(.red), mine = png(.green), theirs = png(.blue)
        try base.write(to: file); try await repo.stage([path]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch","-c","side"])
        try theirs.write(to: file); try await repo.stage([path]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch","main"])
        try mine.write(to: file); try await repo.stage([path]); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge","side"]); throw Failure(line: #line) } catch is GitFailure {}
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        guard let document = try await repo.imageConflictDocument(path: path) else { throw Failure(line: #line) }
        let controller = ImageConflictWindowController(repository: repo,access: nil,document: document)
        let window = controller.window!, host = window.contentView!
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet,returnCode: .abort) }; window.close() }
        // AppKit orders a sheet parent even when it was initially hidden.
        // Keep this private receiver transparent/offscreen throughout that path.
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000,y: -10000))
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded(); try await settle()
        func scrolls() -> [NSScrollView] { descendants(host).compactMap { $0 as? ImageComparisonScrollView } }
        try require(scrolls().count == 3)
        let colors = scrolls().map { pixel($0.documentView!) }
        try require(colors[0].greenComponent > 0.9 && colors[1].redComponent > 0.9 && colors[2].blueComponent > 0.9)
        let selectButtons = descendants(host).compactMap { $0 as? NSButton }.filter { $0.title == "Select" }
        try require(selectButtons.count == 3)
        func key(_ characters: String, _ code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
            let event = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: flags,timestamp: 0,windowNumber: window.windowNumber,context: nil,characters: characters,charactersIgnoringModifiers: characters,isARepeat: false,keyCode: code)!
            try require(window.performKeyEquivalent(with: event))
        }
        try key("v",9,flags: .command); try require(controller.model.vertical); try await settle()
        try require(scrolls().count == 3)
        try key("s",1); try require(controller.model.panes.values.allSatisfy { !$0.fit && $0.zoom == 1 })
        try key("+",24,flags: .shift); try require(controller.model.panes.values.allSatisfy { abs($0.zoom - 1.2) < 0.001 })
        try key("f",3); try require(controller.model.panes.values.allSatisfy { $0.fit })
        try key("v",9,flags: .command); try await settle()
        func button(_ index: Int) -> NSButton { descendants(host).compactMap { $0 as? NSButton }.filter { $0.title == "Select" }[index] }
        func click(_ index: Int, line: UInt = #line) async throws {
            // Published operation completion precedes SwiftUI applying the
            // enabled environment to its native buttons. Wait for the actual
            // control, then exercise its target/action without bypassing it.
            try await wait({ button(index).isEnabled }, line: line)
            button(index).performClick(nil)
            try require(controller.model.busy, line: line)
        }
        func answer(_ title: String, line: UInt = #line) async throws {
            try await wait({ window.attachedSheet != nil }, line: line)
            let sheet = window.attachedSheet!
            try require(controller.model.busy && !controller.windowShouldClose(window))
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
            sheet.alphaValue = 0; window.orderOut(nil); sheet.orderOut(nil)
            try require(!window.isVisible && !sheet.isVisible)
            guard let answer = descendants(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw Failure(line: #line) }
            answer.performClick(nil)
            try await wait { !controller.model.busy }
        }
        var closed = 0; controller.onClosed = { closed += 1 }
        try await click(1)
        try await wait { window.attachedSheet != nil }
        let baseWorking = try Data(contentsOf: file), baseIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(baseWorking == base && baseIndex == beforeIndex)
        try await answer("No"); try require(closed == 0 && controller.model.error == nil)
        if CommandLine.arguments.count > 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[3])
            for (name, appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance); controller.model.showInfo = true
                try await settle(); host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds,to: bitmap)
                try bitmap.representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("image-conflict-native-" + name + "-2026-10-10.png"))
            }
            controller.model.showInfo = false; window.appearance = NSAppearance(named: .aqua)
        }
        try await click(0); try await answer("No")
        let mineWorking = try Data(contentsOf: file), mineIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(mineWorking == mine && mineIndex == beforeIndex)
        // Change bytes while the confirmation is pending: Yes must not stage them.
        try await click(2); try await wait { window.attachedSheet != nil }
        try base.write(to: file); try await answer("Yes")
        try require(controller.model.error != nil && closed == 0)
        let rejectedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(rejectedIndex == beforeIndex)
        controller.model.reload(); try await wait { !controller.model.busy }; try require(controller.model.error == nil)
        try await click(2); try await answer("Yes")
        try require(closed == 1 && controller.model.retired && controller.model.error == nil)
        let remaining = try await repo.conflicts(), staged = try await repo.run(["show",":" + path]).stdout
        try require(remaining.isEmpty && staged == theirs)
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout; try require(afterHead == head)
        print("PASS: Mine/Base/Theirs native pixels/order, independent fit/zoom and vertical layout; actual Select buttons and Yes/No sheets; copied bytes with unmerged index on No, stale working bytes rejected on Yes, Reload recovery, scoped close/quit fencing, resolved bytes and unchanged HEAD. All owned windows closed.")
    }
}
