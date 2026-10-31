// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CoreGraphics
import Darwin
import ScreenCaptureKit
import TurtleGitCore

/// Deliberate, brief visual captures of normal native windows, one at a time.
/// No runtime window adaptation or view-bitmap approximation is used.
@main struct ManualCommitWindowCapture {
    @MainActor static var owners:[CommitWindowController]=[]
    struct Failure:Error,CustomStringConvertible{let description:String}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Current Commit capture timeout at line \(line)")
    }
    @MainActor static func contained(_ window:NSWindow,on screen:NSScreen)throws {
        guard screen.visibleFrame.contains(window.frame) else{throw Failure(description:"Owned visual capture exceeds screen: frame=\(window.frame), visibleFrame=\(screen.visibleFrame)")}
    }
    @MainActor static func soleVisible(_ window:NSWindow)throws {
        let visible=NSApp.windows.filter(\.isVisible)
        guard visible.count==1,visible.first === window,window.attachedSheet==nil else{throw Failure(description:"Visual capture requires exactly one owned visible native window")}
    }
    @MainActor static func png(_ window:NSWindow,_ file:URL)async throws {
        guard #available(macOS 14.4,*)else{throw Failure(description:"ScreenCaptureKit compositor capture unavailable")}
        guard let screen=NSScreen.main ?? NSScreen.screens.first else{throw Failure(description:"Visible visual-capture screen unavailable")}
        window.alphaValue=0;window.contentView?.layoutSubtreeIfNeeded()
        let area=screen.visibleFrame,size=window.frame.size
        guard size.width<=area.width,size.height<=area.height else{throw Failure(description:"Native capture frame does not fit the deliberate visual-acceptance screen")}
        window.setFrameOrigin(.init(x:area.midX-size.width/2,y:area.midY-size.height/2));try contained(window,on:screen)
        window.alphaValue=1;window.orderFront(nil)
        defer{window.orderOut(nil);window.alphaValue=0}
        try contained(window,on:screen);try soleVisible(window)
        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        try await Task.sleep(nanoseconds:600_000_000)
        try contained(window,on:screen);try soleVisible(window)
        let available=try await SCShareableContent.currentProcess
        guard let owned=available.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)})else{throw Failure(description:"Own compositor window missing")}
        let settings=SCStreamConfiguration();settings.width=Int(window.frame.width*2);settings.height=Int(window.frame.height*2)
        settings.showsCursor=false;settings.ignoreShadowsSingleWindow=true;settings.includeChildWindows=false
        let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:settings)
        guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])else{throw Failure(description:"Actual native PNG encoding unavailable")}
        try data.write(to:file)
        print("CAPTURE \(file.lastPathComponent) \(image.width)x\(image.height) windowID=\(window.windowNumber) frame=\(window.frame.width)x\(window.frame.height) deliberate-visible-one-owner");fflush(stdout)
    }
    @MainActor static func drained()->Bool {
        CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeIssueProviderOperations==0 && CommitWindowModel.activeCommitPreflights==0 && PatchWindowModel.activeOperations==0 && PatchDocumentSession.activeOperations==0
    }
    @MainActor static func clean()async throws {
        owners.forEach{$0.close()}
        try await wait{drained()}
        try await wait{owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil}}
        guard NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil})else{throw Failure(description:"Owned capture window/sheet leaked")}
        print("CLEANUP \(owners.count) Commit owners closed; no visible windows/sheets; actual workers drained");fflush(stdout)
    }
    @MainActor static func main()async {
        do{try await run();try await clean();print("Captured four real current Commit windows; owned cleanup complete");fflush(stdout)}
        catch{try? await clean();fputs("Current Commit capture failed: \(error)\n",stderr);fflush(stderr);exit(1)}
    }
    @MainActor static func requireUnlockedSession()throws {
        guard let session=CGSessionCopyCurrentDictionary() as? [String:Any] else{throw Failure(description:"Screenshots are waiting for an available, unlocked macOS desktop session; no demo repository or window was created.")}
        let locked=session["CGSSessionScreenIsLocked"] as? NSNumber
        print("CAPTURE_SESSION available=true screenLocked=\(locked.map{String($0.boolValue)} ?? "unknown")");fflush(stdout)
        if locked?.boolValue==true {throw Failure(description:"Screenshots are waiting for the macOS screen to be unlocked; no demo repository or window was created.")}
    }
    @MainActor static func run()async throws {
        NSApp.setActivationPolicy(.accessory)
        print("RECEIVER pid=\(getpid())");fflush(stdout)
        try requireUnlockedSession()
        let fixture=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),root=fixture.appendingPathComponent("Harbor"),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git),output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PREVIEW_CAPTURE_DIR"] ?? "build/qa/manual-commit-captures-2026-10-29")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","TurtleGit Team"),("user.email","demo@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","false"),("tgit.showpatch","false"),("bugtraq.label","Issue number:"),("bugtraq.message","Issue: %BUGID%")] {_ = try await repo.run(["config",key,value])}
        for folder in ["Sources","Tests"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(folder),withIntermediateDirectories:true)}
        let initial:[String:String]=["README.md":"# Harbor\n\nA native Git client example.\n","Sources/Repository.swift":"struct Repository {\n    var name = \"Harbor\"\n}\n","Sources/Colors.swift":"enum Colors {\n    static let status = \"blue\"\n}\n","Tests/RepositoryTests.swift":"func testRepository() {\n    // Sample test\n}\n",".gitignore":"*.ignored\n"]
        for (path,text) in initial {try Data(text.utf8).write(to:root.appendingPathComponent(path))};try await repo.stage(["."]);_ = try await repo.commit(message:"Create the Harbor project")
        _ = try await repo.run(["switch","-c","feature/status-badges"])
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
        prefs.set(1,forKey:"DialogTitles");prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"Autocompletion");prefs.set(false,forKey:"Gravatar")
        prefs.set(true,forKey:"HintStagingMode");prefs.set(true,forKey:"HintHierarchicalConfig")
        prefs.set(true,forKey:"Commit.SkipCancelConfirmation")
        try NativeIssueAssociations.save([NativeIssueAssociation(path:root.path,parameters:#"{"linkText":"Choose issues…","messageTemplate":"Issue: %BUGID%","requireIssue":false,"issues":[{"id":"42","summary":"Improve native repository status"}]}"#)],to:prefs)

        let captureStamp=ProcessInfo.processInfo.environment["TURTLEGIT_PREVIEW_CAPTURE_STAMP"] ?? "2026-10-29"
        for (appearance,theme) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            for (gui,kind) in [(false,"commit-classic"),(true,"commit-staging")] {
                prefs.set(gui,forKey:"TurtleGit.Commit.GitGuiInterface")
                let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(owner)
                guard let window=owner.window else{throw Failure(description:"Actual Commit window missing")}
                window.alphaValue=0
                window.appearance=NSAppearance(named:appearance)
                window.setContentSize(.init(width:1160,height:840));window.contentView?.layoutSubtreeIfNeeded()
                owner.model.confirmCancel={$0(true)};owner.model.reload()
                try await wait{!owner.model.busy && owner.model.hasHead && owner.model.gitGuiInterface==gui && owner.model.nativeIssueProvider != nil && !owner.model.inputsBlocked}
                owner.model.message="Improve repository status display\n\nKeep familiar colors and original icons in native Mac dialogs."
                owner.model.issueID="42"
                owner.model.checked=["README.md","Sources/Repository.swift"]
                owner.model.setFormOption(.authorDate,value:true,receipt:owner.model.formReceipt)
                try await wait{!owner.model.loadingAuthorDate && !owner.model.inputsBlocked}
                owner.model.authorDate=Date(timeIntervalSince1970:1793266200)
                if gui {
                    owner.model.selectGuiFiles(["Sources/Repository.swift"],staged:false)
                    try await wait{owner.model.guiPatch != nil && owner.model.guiPatch?.busy==false && owner.model.guiPatch?.document.files.isEmpty==false}
                }
                owner.model.supersedeFocusIntent()
                try await png(window,output.appendingPathComponent("mac-"+kind+"-"+theme+"-"+captureStamp+".png"))
                owner.close();try await wait{!owner.canReuse && owner.window?.isVisible != true && drained()}
            }
        }
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout,afterStatus=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        guard head==afterHead,index==afterIndex,status==afterStatus,try Data(contentsOf:root.appendingPathComponent(".git/index"))==indexBytes,try Data(contentsOf:root.appendingPathComponent(".git/config"))==configBytes else{throw Failure(description:"Capture changed private HEAD/index/config/working status")}
        print("CAPTURE baseline HEAD/index tree/raw index/config/working status preserved; no Commit/stage/apply/save actions");fflush(stdout)
    }
}
