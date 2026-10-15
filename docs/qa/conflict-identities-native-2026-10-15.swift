import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct ConflictIdentityNativeVerification {
    @MainActor static func wait(_ windows: [NSWindow], _ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Conflict identity receiver did not settle at line \(line)")
    }
    @MainActor static func assertLeadingGlyphs(_ window: NSWindow) async throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editors = descendants(window.contentView!).compactMap { $0 as? NSTextView }.filter { $0.enclosingScrollView != nil }
        precondition(editors.count == 3)
        try await wait([window]) {
            editors.allSatisfy { view in
                let clip = view.enclosingScrollView!.contentView
                return abs(clip.bounds.minX + clip.contentInsets.left) < 0.5
            }
        }
        for view in editors {
            let scroll = view.enclosingScrollView!, clip = scroll.contentView
            precondition(clip.contentInsets.left > 0 && scroll.rulersVisible)
            let leading = view.convert(NSPoint(x: view.textContainerOrigin.x, y: view.textContainerOrigin.y), to: clip)
            precondition(leading.x >= clip.bounds.minX + clip.contentInsets.left, "First glyph is hidden beneath ruler")
        }
    }
    static func png(_ red: UInt8) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<32 { for x in 0..<32 { let offset = y * bitmap.bytesPerRow + x * 4; bitmap.bitmapData![offset] = red; bitmap.bitmapData![offset + 1] = UInt8(x * 7); bitmap.bitmapData![offset + 2] = UInt8(y * 7); bitmap.bitmapData![offset + 3] = 255 } }
        return bitmap.representation(using: .png, properties: [:])!
    }
    @MainActor static func capture(_ controller: NSWindowController, name: String, directory: URL?) async throws {
        guard let directory, let window = controller.window else { return }
        guard #available(macOS 14.4, *) else { throw NSError(domain: "Owned-window capture needs macOS 14.4", code: 1) }
        NSApp.setActivationPolicy(.regular); controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); NSApp.setActivationPolicy(.prohibited) }
        for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named: appearance); window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NSError(domain: "Owned conflict window unavailable", code: 1) }
            let configuration = SCStreamConfiguration(); configuration.width = Int(window.frame.width * window.backingScaleFactor); configuration.height = Int(window.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try data.write(to: directory.appendingPathComponent(name + "-" + suffix + ".png"))
        }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let captures = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
        let suite = "TurtleGit.ConflictIdentities." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); MergeToolApplication.discardAll() }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let repo = GitRepository(root: root, executable: git), textPath = "file 雪.txt", imagePath = "picture.png", deletePath = "deleted.txt"
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Conflict QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        func write(_ text: String, _ red: UInt8) throws {
            try Data((text + "\n").utf8).write(to: root.appendingPathComponent(textPath))
            try png(red).write(to: root.appendingPathComponent(imagePath))
            try Data((text + "\n").utf8).write(to: root.appendingPathComponent(deletePath))
        }
        try write("base",30); try await repo.stage([textPath,imagePath,deletePath]); _ = try await repo.commit(message:"base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["switch","-c","feature/incoming"])
        try write("incoming",180); try await repo.stage([textPath,imagePath,deletePath]); _ = try await repo.commit(message:"incoming")
        let incoming = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["switch","main"])
        try Data("mine\n".utf8).write(to:root.appendingPathComponent(textPath)); try png(90).write(to:root.appendingPathComponent(imagePath)); _ = try await repo.run(["rm","--",deletePath]); try await repo.stage([textPath,imagePath]); _ = try await repo.commit(message:"mine")
        let head = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        do { _ = try await repo.run(["merge","feature/incoming"]); preconditionFailure("Expected conflict") } catch is GitFailure {}
        // Real index gitlink fixture, using known commit objects without a child
        // checkout. No claim of physical initialized-submodule acceptance.
        let module = "module"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(module), withIntermediateDirectories:true)
        let stages = "160000 \(base) 1\t\(module)\0" + "160000 \(head) 2\t\(module)\0" + "160000 \(incoming) 3\t\(module)\0"
        _ = try await repo.run(["update-index","-z","--index-info"], input:Data(stages.utf8))
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index")), original = try Data(contentsOf:root.appendingPathComponent(textPath)), imageBytes = try Data(contentsOf:root.appendingPathComponent(imagePath))
        let expected = "MERGE_HEAD (feature/incoming, " + incoming.prefix(8) + ")"
        let controller = TextConflictWindowController(repository:repo,access:nil,path:textPath,preferences:prefs)
        defer { controller.close() }; let model = controller.model, window = controller.window!
        model.load(); try await wait([window]) { !model.busy && model.document != nil }
        precondition(model.sourceCaption(mine:true) == "HEAD" && model.sourceCaption(mine:false) == expected)
        let editorIDs = model.editorConfigEnabled.keys.sorted()
        try await assertLeadingGlyphs(window)
        try await capture(controller,name:"conflict-identities-text",directory:captures)
        let delete = DeleteConflictWindowController(repository:repo,access:nil,path:deletePath,preferences:prefs)
        defer { delete.close() }; delete.model.load(); try await wait([delete.window!]) { !delete.model.busy && delete.model.details != nil }
        precondition(delete.model.details!.first.reference == "HEAD" && delete.model.details!.second.reference == expected)
        var logged: String?; delete.model.onLog = { logged = $0 }; delete.model.log(incoming)
        try await wait([delete.window!]) { !delete.model.busy }
        precondition(logged == incoming)
        try await capture(delete,name:"conflict-identities-delete",directory:captures)
        let moduleController = SubmoduleConflictWindowController(repository:repo,access:nil,path:module,preferences:prefs)
        defer { moduleController.close() }; moduleController.model.load()
        try await wait([moduleController.window!]) { !moduleController.model.busy && moduleController.model.details != nil }
        precondition(moduleController.model.details!.mine.title == "HEAD" && moduleController.model.details!.theirs.title == expected)
        let image = try await repo.imageConflictDocument(path:imagePath,identityOptions:.init(defaults:prefs))!
        let imageController = ImageConflictWindowController(repository:repo,access:nil,document:image,preferences:prefs)
        defer { imageController.close() }
        precondition(imageController.model.title(for:.mine) == "Mine — HEAD" && imageController.model.title(for:.theirs) == "Theirs — " + expected)
        var settings = MergeToolPreferences(); settings.program.enabled = true; settings.program.applicationPath = "/private/Conflict Identity Fixture.app"
        settings.program.arguments = "%bname %tname %yname %mname %base %theirs %mine %merged"
        var arguments: [String]?
        let opened = try await MergeToolApplication.open(repository:repo,access:nil,path:textPath,alternate:false,owner:window,preferences:settings,identityOptions:.init(defaults:prefs),launch:{ _, configuration in arguments = configuration.arguments; return .current })
        precondition(opened && arguments?.prefix(4) == [textPath + " : Base",textPath + " : " + expected,textPath + " : HEAD",textPath][...])
        precondition(arguments?.count == 8 && !FileManager.default.fileExists(atPath:root.appendingPathComponent(textPath + ".BASE").path))
        prefs.set(true,forKey:"ConflictDontGuessBranchNames")
        model.load(); delete.model.load(); moduleController.model.load(); imageController.model.reload()
        try await wait([window,delete.window!,moduleController.window!,imageController.window!]) { !model.busy && !delete.model.busy && !moduleController.model.busy && !imageController.model.busy }
        let plain = "MERGE_HEAD (" + incoming.prefix(8) + ")"
        precondition(model.sourceCaption(mine:false) == plain && delete.model.details!.second.reference == plain && moduleController.model.details!.theirs.title == plain && imageController.model.title(for:.theirs) == "Theirs — " + plain)
        precondition(model.editorConfigEnabled.keys.sorted() == editorIDs && model.document!.mineStage == 2 && model.document!.theirsStage == 3)
        let retained = try Data(contentsOf:root.appendingPathComponent(".git/index")), retainedText = try Data(contentsOf:root.appendingPathComponent(textPath)), retainedImage = try Data(contentsOf:root.appendingPathComponent(imagePath))
        precondition(retained == index && retainedText == original && retainedImage == imageBytes)
        let finalHead = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        precondition(finalHead == head)
        controller.close(); delete.close(); moduleController.close(); imageController.close()
        _ = try await repo.run(["merge","--abort"])
        do { _ = try await repo.run(["rebase","feature/incoming"]); preconditionFailure("Expected rebase conflict") } catch is GitFailure {}
        prefs.set(false,forKey:"ConflictDontGuessBranchNames")
        let replay = TextConflictWindowController(repository:repo,access:nil,path:textPath,preferences:prefs)
        defer { replay.close() }; replay.model.load()
        try await wait([replay.window!]) { !replay.model.busy && replay.model.document != nil }
        let onto = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        precondition(replay.model.sourceCaption(mine:true) == "main" && replay.model.sourceCaption(mine:false) == "feature/incoming, " + onto.prefix(8))
        precondition(replay.model.document!.mineStage == 3 && replay.model.document!.theirsStage == 2)
        let replayIndex = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try await assertLeadingGlyphs(replay.window!)
        try await capture(replay,name:"conflict-identities-rebase",directory:captures)
        let afterReplayIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")); precondition(afterReplayIndex == replayIndex)
        replay.close(); _ = try await repo.run(["rebase","--abort"])
        try await MergeWrappingVerification.verify()
        print("PASS: native text/image/delete/submodule captions share merge identity and preference; captured Log pointer and external tool title arguments retain correct sides; Reload keeps pane keys and index/workfiles/HEAD unchanged; private prefs/files, no external app launched")
    }
}
