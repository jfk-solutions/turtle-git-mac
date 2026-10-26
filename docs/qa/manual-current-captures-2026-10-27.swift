import AppKit
import Darwin
import ScreenCaptureKit
import TurtleGitCore

@main struct ManualCurrentWindowCapture {
    @MainActor static var owners:[NSWindowController]=[]
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
        print("CAPTURE \(file.path) \(image.width)x\(image.height) windowID=\(window.windowNumber) title=\(window.title)");fflush(stdout)
    }
    @MainActor static func clean()async throws {
        owners.forEach{$0.close()}
        try await wait {CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activePreferenceOperations==0 && LogDocumentOpenSession.activeRequests==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeActionReads==0 && PatchWindowModel.activeOperations==0 && PatchDocumentSession.activeOperations==0}
        try await wait {owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil}}
        guard NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) else {throw Failure(description:"Owned native capture window/sheet leaked")}
        print("CLEANUP \(owners.count) native owners closed; no visible windows/sheets; Git/document workers drained");fflush(stdout)
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    @MainActor static func main() async {do {try await run();try await clean();print("Captured \(owners.count) real current native windows; owned cleanup complete");fflush(stdout)}catch {try? await clean();fputs("Primary capture failed: \(error)\n",stderr);fflush(stderr);exit(1)}}
    @MainActor static func run() async throws {
        NSApp.setActivationPolicy(.accessory)
        print("RECEIVER pid=\(getpid()) source=958455b78d0e93b4a50d6078b77d49f8c7c8fc72");fflush(stdout)
        let fixture=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),root=fixture.appendingPathComponent("Harbor"),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git),output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PREVIEW_CAPTURE_DIR"] ?? "build/qa/manual-current-captures-2026-10-27")
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
        let indexBytes=try Data(contentsOf:root.appendingPathComponent(".git/index")),configBytes=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let suite="TurtleGit.PrimaryCaptures."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(12,forKey:"LogFontSize");prefs.set("Menlo",forKey:"LogFontName")
        prefs.set(false,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"RelativeTimes");prefs.set(true,forKey:"UseSystemLocaleForDates")
        prefs.set(0,forKey:"CommitShowUnversionedFilesHint");prefs.set(false,forKey:"TurtleGit.Commit.GitGuiInterface")
        let unifiedOnly=CommandLine.arguments.contains("unified-diff-only")
        for (appearance,theme) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            if !unifiedOnly {
            let log=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false);owners.append(log)
            log.window!.appearance=NSAppearance(named:appearance);log.window!.setFrameOrigin(NSPoint(x:-12000,y:-12000))
            log.model.reload();try await wait {!log.model.busy && !log.model.entries.isEmpty}
            guard let merge=log.model.entries.first(where:{$0.parents.count==2}) else {throw Failure(description:"Synthetic merge absent from history")}
            log.model.select([merge.hash]);try await wait {!log.model.busy && log.model.fileGroups.count==2}
            log.model.setChangedFileColumn(.removed,visible:true)
            try await png(log.window!,output.appendingPathComponent("mac-log-"+theme+"-2026-10-27.png"));log.close()
            for (gui,kind) in [(false,"commit-classic"),(true,"commit-staging")] {
                prefs.set(gui,forKey:"TurtleGit.Commit.GitGuiInterface")
                let commit=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(commit)
                commit.window!.appearance=NSAppearance(named:appearance);commit.window!.setFrameOrigin(NSPoint(x:-12000,y:-12000))
                commit.model.confirmCancel={$0(true)};commit.model.reload();try await wait {!commit.model.busy && commit.model.hasHead && commit.model.gitGuiInterface==gui}
                commit.model.message="Improve repository status display\n\nKeep familiar colors and original icons in native Mac dialogs."
                commit.model.checked=["README.md","Sources/Repository.swift"]
                if gui {
                    commit.model.selectGuiFiles(["Sources/Repository.swift"],staged:false)
                    try await wait {commit.model.guiPatch != nil && commit.model.guiPatch?.busy==false && commit.model.guiPatch?.document.files.isEmpty==false}
                }
                try await png(commit.window!,output.appendingPathComponent("mac-"+kind+"-"+theme+"-2026-10-27.png"));commit.close()
            }
            }
            let patch=PatchWindowController(repository:nil,access:nil,preferences:prefs,documentDirectory:root);owners.append(patch)
            patch.window!.setContentSize(NSSize(width:1000,height:480))
            patch.window!.appearance=NSAppearance(named:appearance);patch.window!.setFrameOrigin(NSPoint(x:-12000,y:-12000))
            patch.documentSession.askChanges={_,reply in reply(.discard)}
            let diff="""
            diff --git a/Sources/Repository.swift b/Sources/Repository.swift
            index e72e8a0..f19a4a2 100644
            --- a/Sources/Repository.swift
            +++ b/Sources/Repository.swift
            @@ -1,8 +1,12 @@
             struct Repository {
                 var name = "Harbor"
            -    var showsStatus = false
            +    var showsStatus = true
            +    var showsBadges = true
            +    var usesNativeMenus = true
            \u{20}
                 func refresh() {
            -        loadFiles()
            +        loadFiles(includingUnversioned: true)
            +        updateFinderBadges()
                 }
             }

            """
            patch.presentDocument(Data(diff.utf8),title:"Repository changes",comparison:"Sources/Repository.swift",information:"Native Unified Diff · column selection")
            try await wait {patch.model.canEditText && patch.window!.contentView.map{descendants($0).contains{$0 is PatchTextView.PatchText}}==true}
            let text=descendants(patch.window!.contentView!).compactMap{$0 as? PatchTextView.PatchText}.first!
            try await wait{text.string==diff};patch.window!.contentView!.layoutSubtreeIfNeeded();patch.window!.makeFirstResponder(text)
            guard let columns=text.columnSelection else {throw Failure(description:"Native column controller missing")}
            let index=PatchLineIndex(text:text.string)
            guard let a=columns.point(atUTF16:index.lineStarts[8]+5),let b=columns.point(atUTF16:index.lineStarts[10]+9),columns.beginRectangle(at:a),columns.continueRectangle(at:b) else {throw Failure(description:"Native rectangle selection setup failed")}
            columns.endRectangle()
            guard columns.snapshot().rectangular && columns.snapshot().rows.count==3 else {throw Failure(description:"Current column selection did not retain native ranges")}
            try await png(patch.window!,output.appendingPathComponent("mac-unified-diff-"+theme+"-2026-10-27.png"));patch.close()
        }
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout,afterStatus=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        guard head == afterHead,index == afterIndex,status == afterStatus,try Data(contentsOf:root.appendingPathComponent(".git/index"))==indexBytes,try Data(contentsOf:root.appendingPathComponent(".git/config"))==configBytes else {throw Failure(description:"Capture changed HEAD/index tree/working status")}
        _ = base
        print("CAPTURE baseline HEAD/index tree/status preserved; \(owners.count) current native appearances; standalone editable Unified Diff document with native rectangle selection; no Commit/apply actions");fflush(stdout)
    }
}
