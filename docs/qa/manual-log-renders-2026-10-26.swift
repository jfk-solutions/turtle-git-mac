// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct ManualLogRender {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Primary dialog capture timeout at line \(line)")}
    @MainActor static func clipLayers(_ view:NSView)->[(CALayer,Bool)] {
        var result=[(CALayer,Bool)]()
        if view is NSClipView,let layer=view.layer {result.append((layer,layer.masksToBounds));layer.masksToBounds=true}
        for child in view.subviews {result += clipLayers(child)}
        return result
    }
    @MainActor static func png(_ window:NSWindow,_ file:URL) async throws {
        window.setFrameOrigin(NSPoint(x:-24000,y:-24000));window.alphaValue=1;window.orderFront(nil)
        defer {window.orderOut(nil)}
        guard let view=window.contentView else {throw Failure(description:"Native content view unavailable")}
        view.layoutSubtreeIfNeeded();window.displayIfNeeded()
        try await Task.sleep(nanoseconds:600_000_000)
        view.layoutSubtreeIfNeeded()
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.bounds.width*2),pixelsHigh:Int(view.bounds.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:bitmap) else {throw Failure(description:"Native view backing image unavailable")}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        defer {NSGraphicsContext.restoreGraphicsState()}
        let clips=clipLayers(view);defer {for (layer,previous) in clips {layer.masksToBounds=previous}}
        let cg=context.cgContext;cg.scaleBy(x:2,y:2);cg.translateBy(x:0,y:view.bounds.height);cg.scaleBy(x:1,y:-1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill();view.bounds.fill()
            view.layer?.displayIfNeeded()
            view.layer?.render(in:cg)
        }
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw Failure(description:"Native PNG encoding failed")}
        try png.write(to:file)
        print("RENDER \(file.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) actual native content; no window chrome")
    }
    @MainActor static func main() async {do {try await run()}catch {NSApp.windows.forEach{$0.orderOut(nil);$0.close()};fputs("Primary capture failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func run() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let fixture=URL(fileURLWithPath:CommandLine.arguments[1]),root=fixture.appendingPathComponent("Harbor"),git=URL(fileURLWithPath:CommandLine.arguments[2])
        defer {try? FileManager.default.removeItem(at:fixture)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git),output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PREVIEW_CAPTURE_DIR"] ?? "build/qa/manual-current-captures-2026-10-26")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","TurtleGit Team"),("user.email","demo@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","false"),("tgit.showpatch","false")] {_ = try await repo.run(["config",key,value])}
        for folder in ["Sources","Tests"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(folder),withIntermediateDirectories:true)}
        let initial:[String:String]=["README.md":"# Harbor\n\nA native Git client example.\n","Sources/Repository.swift":"struct Repository {\n    var name = \"Harbor\"\n}\n","Sources/Colors.swift":"enum Colors {\n    static let status = \"blue\"\n}\n","Tests/RepositoryTests.swift":"func testRepository() {\n    // Sample test\n}\n",".gitignore":"*.ignored\n"]
        for (path,text) in initial {try Data(text.utf8).write(to:root.appendingPathComponent(path))};try await repo.stage(["."]);_ = try await repo.commit(message:"Create the Harbor project")
        let base=try await repo.rebaseCommit("HEAD");_ = try await repo.run(["switch","-c","feature/status-badges"])
        try Data("struct BadgePalette {\n    let modified = \"blue\"\n    let added = \"purple\"\n}\n".utf8).write(to:root.appendingPathComponent("Sources/BadgePalette.swift"));try await repo.stage(["."]);_ = try await repo.commit(message:"Add colorful status badges")
        _ = try await repo.run(["switch","main"]);try Data("# Harbor\n\nA native Git client example.\n\nInspect history with its compact commit graph.\n".utf8).write(to:root.appendingPathComponent("README.md"));try await repo.stage(["README.md"]);_ = try await repo.commit(message:"Describe the history view")
        _ = try await repo.run(["merge","--no-ff","feature/status-badges","-m","Merge native status badges\n\nKeep familiar colors and original icons in native macOS dialogs."])
        _ = try await repo.run(["tag","v1.0"])
        try Data("# Harbor\n\nA native Git client example.\n\nInspect history with its compact commit graph.\n\nKeep the familiar Commit workflow on macOS.\n".utf8).write(to:root.appendingPathComponent("README.md"));try await repo.stage(["README.md"])
        try Data("# Harbor\n\nA native Git client example.\n\nInspect history with its compact commit graph.\n\nKeep the familiar Commit workflow on macOS.\nShow original status icons in Finder.\n".utf8).write(to:root.appendingPathComponent("README.md"))
        try Data("struct Repository {\n    var name = \"Harbor\"\n    var showsStatus = true\n}\n".utf8).write(to:root.appendingPathComponent("Sources/Repository.swift"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("Tests/RepositoryTests.swift"))
        try Data("struct StatusBadge {\n    let title: String\n}\n".utf8).write(to:root.appendingPathComponent("Sources/StatusBadge.swift"))
        try Data("Private ignored example\n".utf8).write(to:root.appendingPathComponent("sample.ignored"))
        _ = try await repo.assignChangelist(paths:["Sources/Repository.swift"],name:"Native dialogs")
        _ = try await repo.assignChangelist(paths:["Tests/RepositoryTests.swift"],name:"ignore-on-commit")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["write-tree"]).stdout,status=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        let suite="TurtleGit.PrimaryCaptures."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(12,forKey:"LogFontSize");prefs.set("Menlo",forKey:"LogFontName")
        prefs.set(true,forKey:"HintStagingMode");prefs.set(1,forKey:"CommitMergeHint");prefs.set(7,forKey:"NothingToCommitShowUnversioned");prefs.set(false,forKey:"Autocompletion")
        prefs.set(false,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"RelativeTimes");prefs.set(true,forKey:"UseSystemLocaleForDates")
        let log=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false);defer {log.close()};log.model.reload();try await wait {!log.model.busy && !log.model.entries.isEmpty}
        let merge=log.model.entries.first {$0.parents.count == 2}!;log.model.select([merge.hash]);try await wait {!log.model.busy && log.model.fileGroups.count == 2}
        log.model.setChangedFileColumn(.removed,visible:true)
        for (appearance,name) in [(NSAppearance.Name.aqua,"mac-log-light-2026-10-26"),(.darkAqua,"mac-log-dark-2026-10-26")] {log.window!.appearance=NSAppearance(named:appearance);try await png(log.window!,output.appendingPathComponent(name+".png"))};log.close()
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout,afterStatus=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        guard head == afterHead,index == afterIndex,status == afterStatus else {throw Failure(description:"Capture changed HEAD/index tree/working status")}
        try await wait {LogWindowModel.activeHistoryLoads==0}
        _ = base
        print("Rendered two current native Log content views in light/dark. Private fixture/preferences; no Commit/apply actions; HEAD/index tree/status preserved; owned windows closed.")
    }
}
