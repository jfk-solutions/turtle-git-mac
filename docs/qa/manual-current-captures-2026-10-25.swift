import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct ManualWindowCapture {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Primary dialog capture timeout at line \(line)")}
    @MainActor static func png(_ window:NSWindow,_ file:URL) async throws {
        guard #available(macOS 14.4,*) else {throw Failure(description:"ScreenCaptureKit capture unavailable")}
        window.setFrameOrigin(NSPoint(x:-12000,y:-12000));window.alphaValue=1;window.orderFront(nil)
        defer {window.orderOut(nil)}
        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        try await Task.sleep(nanoseconds:600_000_000)
        let content=try await SCShareableContent.currentProcess
        guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned native window missing")}
        let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
        let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
        guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw Failure(description:"Native PNG encoding failed")}
        try png.write(to:file)
        print("CAPTURE \(file.path) \(image.width)x\(image.height) title=\(window.title)")
    }
    @MainActor static func main() async {do {try await run()}catch {NSApp.windows.forEach{$0.orderOut(nil);$0.close()};fputs("Primary capture failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func run() async throws {
        NSApp.setActivationPolicy(.accessory)
        let fixture=URL(fileURLWithPath:"/tmp/TurtleGit-Manual-"+UUID().uuidString.prefix(8)),root=fixture.appendingPathComponent("Harbor"),git=URL(fileURLWithPath:CommandLine.arguments[2])
        defer {try? FileManager.default.removeItem(at:fixture)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git),output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PREVIEW_CAPTURE_DIR"] ?? "build/qa/manual-current-captures-2026-10-25")
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
        prefs.set(false,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"RelativeTimes");prefs.set(true,forKey:"UseSystemLocaleForDates")
        let commit=CommitWindowController(repository:repo,access:nil,defaults:prefs);defer {commit.close()};commit.model.confirmCancel={ $0(true) };commit.model.reload();try await wait {!commit.model.busy && commit.model.hasHead}
        commit.model.message="Improve repository status display\n\nKeep familiar colors and original icons in native Mac dialogs."
        commit.model.checked=["README.md","Sources/Repository.swift"]
        for (appearance,name) in [(NSAppearance.Name.aqua,"mac-commit-light-2026-10-25"),(.darkAqua,"mac-commit-dark-2026-10-25")] {commit.window!.appearance=NSAppearance(named:appearance);try await png(commit.window!,output.appendingPathComponent(name+".png"))}
        commit.close()
        let log=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false);defer {log.close()};log.model.reload();try await wait {!log.model.busy && !log.model.entries.isEmpty}
        let merge=log.model.entries.first {$0.parents.count == 2}!;log.model.select([merge.hash]);try await wait {!log.model.busy && log.model.fileGroups.count == 2}
        log.model.setChangedFileColumn(.removed,visible:true)
        for (appearance,name) in [(NSAppearance.Name.aqua,"mac-log-light-2026-10-25"),(.darkAqua,"mac-log-dark-2026-10-25")] {log.window!.appearance=NSAppearance(named:appearance);try await png(log.window!,output.appendingPathComponent(name+".png"))};log.close()
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout,afterStatus=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        guard head == afterHead,index == afterIndex,status == afterStatus else {throw Failure(description:"Capture changed HEAD/index tree/working status")}
        _ = base
        print("Captured four real current Commit/Log windows in light/dark. Private fixture/preferences; no Commit/apply actions; HEAD/index tree/status preserved; owned windows closed.")
    }
}
