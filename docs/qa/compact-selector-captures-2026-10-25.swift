import AppKit
import ScreenCaptureKit
import ObjectiveC
import TurtleGitCore

@main struct CompactSelectorCapture {
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
    @MainActor static func nativeViews(_ view:NSView?)->[NSView] {
        guard let view else{return []}
        let children=(view.subviews as NSArray).copy() as! NSArray
        var result=[view]
        for case let child as NSView in children {result += nativeViews(child)}
        return result
    }
    @MainActor static func main() async {do {try await run()}catch {NSApp.windows.forEach{$0.orderOut(nil);$0.close()};fputs("Primary capture failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func errorCaptures() async throws {
        NSApp.setActivationPolicy(.accessory)
        let output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PREVIEW_CAPTURE_DIR"]!)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let short="Could not add the repository to TurtleGit.\nFinder cache update does not belong to its repository."
        let long=short+"\n\n"+(1...80).map {"Repository /Volumes/Harbor/Workspace/Module\($0): a detailed diagnostic remains selectable and available without enlarging the entire window."}.joined(separator:"\n")
        var receipts=[[String:Any]]()
        for (name,appearance,message,isLong) in [("action-error-short-light",NSAppearance.Name.aqua,short,false),("action-error-short-dark",.darkAqua,short,false),("action-error-long-light",.aqua,long,true)] {
            var closed=0
            let owner=WorkspaceHandoffFailureController(message:message,heading:"TurtleGit could not complete the requested action",onClosed:{closed += 1})
            defer {owner.close()}
            guard let window=owner.window,let content=window.contentView else {throw Failure(description:"Owned error window missing")}
            window.appearance=NSAppearance(named:appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            let views=nativeViews(content)
            guard let button=views.compactMap({$0 as? NSButton}).first(where:{$0.title=="OK"}),let text=views.compactMap({$0 as? NSTextView}).first(where:{$0.string==message}),let scroll=text.enclosingScrollView else {throw Failure(description:"Error text/default OK missing")}
            let size=window.contentRect(forFrameRect:window.frame).size,buttonRect=button.convert(button.bounds,to:content)
            guard abs(size.width-500)<0.5,size.height<=(isLong ? 540:240),buttonRect.minY>=14,buttonRect.minY<=24,buttonRect.maxX>=size.width-110,buttonRect.maxX<=size.width-18,window.defaultButtonCell === button.cell else {throw Failure(description:"Error content/footer did not fit: size=\(size) OK=\(buttonRect)")}
            guard !text.isEditable,text.isSelectable,scroll.hasVerticalScroller==isLong,scroll.frame.height<=360 else {throw Failure(description:"Error diagnostic lost selectable/bounded scrolling behavior")}
            try await png(window,output.appendingPathComponent(name+".png"))
            button.performClick(nil)
            try await wait {closed==1 && !window.isVisible && window.sheetParent==nil}
            owner.close()
            guard closed==1 else {throw Failure(description:"Error acknowledgment completed more than once")}
            receipts.append(["name":name,"content_width":size.width,"content_height":size.height,"detail_viewport_height":scroll.frame.height,"default_OK":true,"close_callback_count":closed,"full_message_retained":text.string==message])
        }
        try JSONSerialization.data(withJSONObject:receipts,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("native-layout.json"))
        print("Captured three real compact action error windows; default OK; selectable full details; bounded long diagnostic; callbacks exactly once; owned windows closed.")
    }
    @MainActor static func run() async throws {
        if ProcessInfo.processInfo.environment["TURTLEGIT_CAPTURE_ONLY_ERRORS"] == "1" {try await errorCaptures();return}
        NSApp.setActivationPolicy(.accessory)
        let fixture=URL(fileURLWithPath:"/tmp/TurtleGit-Manual-"+UUID().uuidString.prefix(8)),root=fixture.appendingPathComponent("Harbor"),git=URL(fileURLWithPath:CommandLine.arguments[2])
        defer {try? FileManager.default.removeItem(at:fixture)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git),output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PREVIEW_CAPTURE_DIR"] ?? "build/qa/compact-selector-captures-2026-10-25")
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
        if ProcessInfo.processInfo.environment["TURTLEGIT_CAPTURE_COMPARE_ONLY"] == nil {
        for (appearance,name) in [(NSAppearance.Name.aqua,"commit-compact-light"),(.darkAqua,"commit-compact-dark")] {commit.window!.appearance=NSAppearance(named:appearance);try await png(commit.window!,output.appendingPathComponent(name+".png"))}
        }
        commit.close()
        let before=fixture.appendingPathComponent("Harbor-before.swift"),after=fixture.appendingPathComponent("Harbor-after.swift")
        let source="""
        import Foundation

        struct RepositoryStatus {
            let branch: String
            var modifiedFiles: [String]

            var summary: String {
                "Changes on \\(branch)"
            }

            func badgeTitle() -> String {
                "Modified"
            }
        }
        """
        let changed=source.replacingOccurrences(of:"Changes on",with:"Working tree changes on").replacingOccurrences(of:"\"Modified\"",with:"modifiedFiles.isEmpty ? \"Clean\" : \"Modified\"")
        try Data(source.utf8).write(to:before);try Data(changed.utf8).write(to:after)
        let originalBefore=try Data(contentsOf:before),originalAfter=try Data(contentsOf:after)
        let compare=FileComparisonWindowController(comparison:try WorkingFileComparison(base:before,destination:after),permissions:[],preferences:prefs)
        defer {compare.close()}
        compare.window!.setContentSize(NSSize(width:1200,height:720))
        compare.window!.alphaValue=0;compare.window!.setFrameOrigin(NSPoint(x:-12000,y:-12000));compare.showWindow(nil)
        try await wait {!compare.model.busy && compare.model.alignment != nil && compare.model.error == nil}
        for (appearance,name,curved) in [(NSAppearance.Name.aqua,"compare-compact-light-classic",false),(.darkAqua,"compare-compact-dark-p4merge",true)] {
            compare.window!.appearance=NSAppearance(named:appearance)
            compare.window!.contentView?.layoutSubtreeIfNeeded()
            prefs.set(curved,forKey:"TurtleGit.Comparison.CurvedInterface")
            NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:prefs)
            try await Task.sleep(nanoseconds:300_000_000)
            print("Private persisted comparison interface=\(curved ? "P4Merge-style":"Classic"); real SwiftUI AppStorage picker; no synthetic menu/action")
            try await png(compare.window!,output.appendingPathComponent(name+".png"))
        }
        compare.close()
        guard try Data(contentsOf:before)==originalBefore,try Data(contentsOf:after)==originalAfter else {throw Failure(description:"Capture changed comparison inputs")}
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout,afterStatus=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        guard head == afterHead,index == afterIndex,status == afterStatus else {throw Failure(description:"Capture changed HEAD/index tree/working status")}
        _ = base
        print("Captured four real compact Commit/Comparison windows in light/dark. Private fixture/preferences; no Commit/apply actions; HEAD/index tree/status preserved; owned windows closed.")
    }
}
