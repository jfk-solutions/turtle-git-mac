// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct WorkspaceFilesVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func views(_ view:NSView?) -> [NSView] {guard let view else{return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func wait(_ window:NSWindow? = nil,line:Int = #line,_ ready:()->Bool) async throws {
        var settled=0
        for _ in 0..<3000 {window?.contentView?.layoutSubtreeIfNeeded();settled = ready() ? settled+1:0;if settled==2{return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Workspace wait at \(line)")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_WORKSPACE_CAPTURE"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned capture unavailable")}
        try require(window.frame.width>=920 && window.frame.height>=650,"Workspace capture host collapsed")
        window.alphaValue=1;window.orderFront(nil);defer{window.alphaValue=0}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned workspace unavailable")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Capture encoding")}
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("workspace-files-"+name+".png"))
        }
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do {try await verify();print("PASS Workspace files: exact native rows/selection, captured menu ownership, private text/URL clipboard and reveal handoff, staged Diff and Stage/Unstage, Finder reopening, independent historical comparison/Blame windows, conflict peer routing and Move selection restoration; owned windows closed")}
        catch{fputs("Workspace files failed: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Workspace QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] {_ = try await repo.run(["config",key,value])}
        let a="café.txt",b="cafe\u{301}.txt",unique="unique.txt"
        func entry(_ path:String,index:Character,worktree:Character) -> StatusEntry {StatusEntry.parse(Data((String([index,worktree])+" "+path+"\0").utf8))[0]}
        func install(_ path:String,_ text:String) async throws {
            let hash=try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).text.trimmingCharacters(in:.newlines)
            _ = try await repo.run(["update-index","-z","--index-info"],input:Data("100644 \(hash)\t\(path)\0".utf8))
        }
        try await install(a,"base A\n");try await install(b,"base B\n");try await install(unique,"base unique\n");_ = try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try await install(a,"tip A\n");try await install(b,"tip B\n");_ = try await repo.commit(message:"tip")
        let tip=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try await install(a,"staged A\n");try await install(b,"staged B\n")
        try Data("working shared\n".utf8).write(to:root.appendingPathComponent(a));try Data("working unique\n".utf8).write(to:root.appendingPathComponent(unique))
        let suite="TurtleGit.WorkspaceFiles."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        defer{prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        for key in ["EnableLogCache","EnableGravatar","LogIncludeWorkingTreeChanges"] {prefs.set(false,forKey:key)}
        let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:repo.executable)},snapshotWriter:{_ in false},snapshotStore:FinderSnapshotStore(url:root.appendingPathComponent(".git/qa-cache.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent(".git/qa-mark.json")))
        model.fileComparisonPreferences=prefs;model.workspaceClipboard=clipboard;model.blameRecentDocuments=try BlameRecentDocuments(url:root.appendingPathComponent(".git/qa-recent.json"))
        model.open(root);try await wait {!model.busy && model.root != nil};try require(model.error==nil,"Workspace adoption failed: "+(model.error ?? "nil"))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="TurtleGit for Mac";window.isReleasedWhenClosed=false;window.alphaValue=0
        let host=NSHostingController(rootView:RepositoryWindow(model:model).defaultAppStorage(prefs));host.sizingOptions=[];window.contentViewController=host
        window.contentMinSize=NSSize(width:920,height:650)
        NSLayoutConstraint.activate([host.view.widthAnchor.constraint(greaterThanOrEqualToConstant:920),host.view.heightAnchor.constraint(greaterThanOrEqualToConstant:650)])
        window.setContentSize(NSSize(width:1120,height:800));window.orderFront(nil)
        defer{Array(model.fileComparisonWindows.values).forEach {$0.close()};Array(model.blameWindows.values).forEach {$0.close()};Array(model.moveWindows.values).forEach {$0.close()};window.close()}
        model.entries=[entry(a,index:"M",worktree:" "),entry(b,index:"M",worktree:" ")]
        try await wait(window) {window.frame.width >= 920 && window.frame.height >= 650 && views(window.contentView).compactMap {$0 as? NSTableView}.contains {$0.tableColumns.count==3 && $0.numberOfRows==2}}
        let table=views(window.contentView).compactMap {$0 as? NSTableView}.first {$0.tableColumns.count==3}!
        func select(_ paths:GitPathSet) async throws {
            let indexes=IndexSet(model.visibleEntries.enumerated().compactMap {paths.contains($0.element.path) ? $0.offset:nil})
            CommitFileInteraction.replaceSelection(in:table,with:indexes)
            try await wait(window) {model.selection==paths && table.selectedRowIndexes==indexes}
        }
        try await select([a]);let stale=model.captureWorkspaceMenu()
        try await select([b]);try require(!model.claimWorkspaceMenu(stale),"Context survived canonical-only selection change")
        let original=model.captureWorkspaceMenu();try await select([a]);try await select([b]);try require(!model.claimWorkspaceMenu(original),"Away/back revived context")
        let clicked=model.captureWorkspaceMenu([a]);try require(clicked.paths.map {GitReferenceName($0)} == [GitReferenceName(a)] && model.claimWorkspaceMenu(clicked) && !model.claimWorkspaceMenu(clicked),"Clicked target or one-use ownership wrong")
        let foreign=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotWriter:{_ in false})
        try require(!foreign.claimWorkspaceMenu(model.captureWorkspaceMenu()),"Foreign workspace claimed context")
        let busy=model.captureWorkspaceMenu();model.busy=true;model.busy=false;try require(!model.claimWorkspaceMenu(busy),"Busy context revived")
        let filtered=model.captureWorkspaceMenu();model.showIgnored=true;model.showIgnored=false;try require(!model.claimWorkspaceMenu(filtered),"Filter context revived")
        model.copyWorkspacePaths([b]);try require(Data((clipboard.string(forType:.string) ?? "").utf8)==Data(b.utf8),"Relative copy changed spelling")
        model.copyWorkspacePaths([b],full:true);try require(Data((clipboard.string(forType:.string) ?? "").utf8)==Data((root.path+"/"+b).utf8),"Full copy changed spelling")
        model.copyWorkspaceFiles([a,b]);try require(FileTransferClipboard.urls(clipboard).map {GitReferenceName($0.lastPathComponent)} == [GitReferenceName(a),GitReferenceName(b)],"File URL copy merged peers")
        var revealed:[URL]=[];model.revealWorkspaceFiles={revealed=$0};model.revealWorkspaceFiles(model.workspaceURLs([b]));try require(revealed.map {GitReferenceName($0.lastPathComponent)} == [GitReferenceName(b)],"Reveal handoff changed target")
        model.stagedDiff=true;model.submodules=[b];model.showDiff(paths:[a]);try await wait(window) {!model.busy};try require(model.output.contains("staged A") && model.submoduleDiffWindows.isEmpty,"Ordinary peer routed to a gitlink")
        model.submodules=[]
        model.showDiff(paths:[b]);try await wait(window) {!model.busy};try require(model.output.contains("staged B") && !model.output.contains("staged A"),"Staged Diff changed target")
        try await capture(window)
        model.stage(paths:[b]);try await wait(window) {!model.busy}
        try require(try await repo.run(["-c","core.precomposeunicode=false","show",":"+a]).stdout==Data("staged A\n".utf8),"Stage changed the unselected peer")
        try require(try await repo.run(["-c","core.precomposeunicode=false","show",":"+b]).stdout==Data("working shared\n".utf8),"Stage missed the selected peer")
        model.unstage(paths:[b]);try await wait(window) {!model.busy};try require(try await repo.run(["-c","core.precomposeunicode=false","show",":"+b]).stdout==Data("tip B\n".utf8),"Unstage missed selected peer")
        let finder=FinderRequest(action:.diff,paths:[FileTransferPaths.fileURL(root.path+"/"+b)])
        var finderOpened:[String]=[];model.fileComparisonPresentation={_,file in finderOpened.append(file.path)}
        model.handle(finder.url!);try await wait(window) {!model.busy && !finderOpened.isEmpty}
        try require(model.selection==GitPathSet([b]) && finderOpened.map {GitReferenceName($0)} == [GitReferenceName(b)],"Finder reopening selected or compared a canonical peer")
        model.fileComparisonPresentation=nil
        let snapshot=try await repo.revisionComparison(from:.revision(base),to:.revision(tip))
        model.showFileComparisons(repository:repo,access:nil,snapshot:snapshot,owner:window)
        try await wait(window) {!model.busy && model.fileComparisonWindows.count==2 && model.fileComparisonWindows.values.allSatisfy {!$0.model.busy && !$0.model.filtering}}
        try require(GitPathSet(model.fileComparisonWindows.values.map {$0.model.path})==GitPathSet([a,b]),"Comparison cache reused a peer")
        for child in model.fileComparisonWindows.values {try require(child.model.document?.destination.bytes==Data((GitReferenceName.equal(child.model.path,a) ? "tip A\n":"tip B\n").utf8),"Comparison loaded peer bytes")}
        Array(model.fileComparisonWindows.values).forEach {$0.close()};try await wait {model.fileComparisonWindows.isEmpty}
        model.activate(.blame,paths:[a]);model.activate(.blame,paths:[b])
        try await wait(window) {model.blameWindows.count==2 && model.blameWindows.values.allSatisfy {!$0.model.busy && $0.model.snapshot != nil}}
        for child in model.blameWindows.values {try require(child.model.snapshot?.contents==Data((GitReferenceName.equal(child.model.path,a) ? "tip A\n":"tip B\n").utf8),"Blame cache loaded peer bytes")}
        Array(model.blameWindows.values).forEach {$0.close()};try await wait {model.blameWindows.isEmpty}
        model.entries=[entry(a,index:"M",worktree:" "),entry(b,index:"U",worktree:"U")]
        var opened:[String]=[];model.fileComparisonPresentation={_,file in opened.append(file.path)}
        model.showWorkingFiles(repository:repo,access:nil,paths:[a],owner:window);try await wait(window) {!model.busy && FileListComparisonSession.activeOperations==0}
        try require(opened.map {GitReferenceName($0)} == [GitReferenceName(a)],"Ordinary comparison routed to conflict peer")
        model.fileComparisonPresentation=nil;await model.refresh();try await wait(window) {!model.busy}
        model.selection=[b,unique];model.activate(.move,paths:[unique]);let moving=model.moveWindows.values.first!
        moving.window?.alphaValue=0;let destination=root.appendingPathComponent("moved");try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        moving.model.setFolder(destination);try await wait {!moving.model.busy};moving.model.move()
        try await wait(window) {!moving.model.busy && !model.busy && model.selection==GitPathSet([b,"moved/"+unique])}
        try require(moving.model.moved==1 && model.error==nil,"Move failed workspace selection restoration")
        moving.close();try require(try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)==tip,"Workspace commands changed HEAD")
        let retired=model.captureWorkspaceMenu();window.close();try require(!model.claimWorkspaceMenu(retired),"Closed workspace retained file menu authority")
    }
}
