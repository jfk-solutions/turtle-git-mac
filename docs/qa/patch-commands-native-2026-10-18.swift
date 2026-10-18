import AppKit
import TurtleGitCore

private final class PatchCommandBookmarks: RepositoryBookmarkProvider {
    func create(for url:URL) throws -> Data {Data(url.path.utf8)}
    func resolve(_ data:Data) throws -> ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}
extension PrimaryCommandsVerification {
    @MainActor static func verifyPatchCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let source=container.appendingPathComponent("source"),target=container.appendingPathComponent("target"),outside=container.appendingPathComponent("mailboxes")
        for folder in [source,outside] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
        let repo=GitRepository(root:source,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch command QA"),("user.email","patch@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let file=source.appendingPathComponent("file.txt"),sub=source.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at:sub,withIntermediateDirectories:true)
        try Data("one\n".utf8).write(to:file);try Data("inside\n".utf8).write(to:sub.appendingPathComponent("inside.txt"))
        try await repo.stage(["file.txt","sub"]);_ = try await repo.commit(message:"base")
        let base=try await repo.rebaseCommit("HEAD")
        try Data("two 🐢\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_ = try await repo.commit(message:"second")
        let tip=try await repo.rebaseCommit("HEAD"),sourceIndex=try Data(contentsOf:source.appendingPathComponent(".git/index"))
        _ = try await repo.run(["clone","--no-local",source.path,target.path])
        let destination=GitRepository(root:target,executable:git)
        for (key,value) in [("user.name","Patch command QA"),("user.email","patch@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await destination.run(["config",key,value])}
        _ = try await destination.run(["reset","--hard",base.hash])
        let suite="TurtleGit.PatchCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,bookmarks=PatchCommandBookmarks()
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(true,forKey:"FormatPatchNoPrefix")
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope=true;workspace.repositoryBookmarkProvider=bookmarks;workspace.fileComparisonPreferences=prefs;workspace.notifyFinder={}
        workspace.commandLineRepositoryPermission={paths in RepositoryAccessLease(url:paths[0].path.hasPrefix(target.path) ? target:source,provider:bookmarks)}
        workspace.commandLinePatchPermission={_ in RepositoryAccessLease(url:outside,provider:bookmarks)}
        let host=NSWindow(contentRect:.init(x:0,y:0,width:700,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;workspace.workspaceWindow=host
        defer {workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()};host.close()}
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        func invoke(_ args:[String],cwd:URL?=nil) {workspace.handleCommandLine(arguments:args,currentDirectory:(cwd ?? source).path)}
        invoke(["--command=formatpatch","--startrev",base.hash,"--endrev",tip.hash])
        try await wait {!workspace.busy && windows(FormatPatchWindowController.self).first?.model.busy==false}
        let series=try requireOne(windows(FormatPatchWindowController.self))
        try require(series.model.mode == .from && series.model.from==base.hash && series.model.to==tip.hash && series.model.noPrefix,"Format Patch presets/private preferences were lost")
        series.model.count=7;series.model.noPrefix=false
        invoke(["--command=formatpatch","--startrev=HEAD"]);try await wait {!workspace.busy}
        try require(windows(FormatPatchWindowController.self).count==1 && series.model.count==7 && series.model.mode == .from && series.model.from==base.hash,"Repeated Format Patch command replaced draft")
        let patches=outside.appendingPathComponent("series");try FileManager.default.createDirectory(at:patches,withIntermediateDirectories:true)
        series.model.directory=patches.path;series.model.outputAccess=RepositoryAccessLease(url:outside,provider:bookmarks);series.model.export()
        try await wait {!series.model.busy && series.model.success}
        let created=try FileManager.default.contentsOfDirectory(at:patches,includingPropertiesForKeys:nil).filter {$0.pathExtension=="patch"}
        try require(created.count==1,"Accepted Format Patch did not create one real mail patch")
        series.model.finish();var finishPolls=0
        try await wait {
            finishPolls += 1
            if finishPolls==2999 {print("Format acknowledgement: visible=\(series.window?.isVisible == true), attached=\(series.window?.attachedSheet != nil), active=\(series.activeOperation), busy=\(series.model.busy), progress=\(series.model.progress), scheduled=\(series.model.finishScheduled), workspaceBusy=\(workspace.busy)");fflush(stdout)}
            return windows(FormatPatchWindowController.self).isEmpty && !workspace.busy
        }
        invoke(["--command=formatpatch","--startrev",base.hash]);try await wait {!workspace.busy && windows(FormatPatchWindowController.self).first?.model.busy==false}
        let since=try requireOne(windows(FormatPatchWindowController.self));try require(since.model.mode == .since && since.model.since==base.hash && since.model.from==base.hash+"~1" && since.model.to==base.hash,"Since did not retain inactive source range fields");since.close()
        invoke(["--command=export","--path",sub.path,"--rev",tip.hash]);try await wait {!workspace.busy && windows(ExportWindowController.self).first?.model.busy==false}
        let archive=try requireOne(windows(ExportWindowController.self))
        try require(archive.model.presentationPreferences===prefs && archive.model.revision==tip.hash && !archive.model.wholeProject,"Export lost revision, directory scope or preferences")
        let zip=outside.appendingPathComponent("sub.zip");archive.model.destination=zip.path;archive.model.outputAccess=RepositoryAccessLease(url:outside,provider:bookmarks)
        invoke(["--command=export","--path",source.path,"--rev",base.hash]);try await wait {!workspace.busy}
        try require(windows(ExportWindowController.self).count==1 && archive.model.destination==zip.path && archive.model.revision==tip.hash,"Repeated Export replaced edited draft")
        archive.model.onProgress=nil;archive.model.export();try await wait {!archive.model.busy && archive.model.exported != nil}
        try require(try Data(contentsOf:zip).starts(with:[0x50,0x4b]),"Accepted Export did not write a ZIP archive");archive.close()
        let mailbox=outside.appendingPathComponent("mailbox.dat");try FileManager.default.copyItem(at:created[0],to:mailbox)
        invoke(["--command=importpatch","--path",mailbox.path,"--droptarget",target.path])
        try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork && !windows(ImportPatchWindowController.self).isEmpty}
        let imported=try requireOne(windows(ImportPatchWindowController.self)),firstID=imported.model.items[0].id
        try require(imported.model.items.map(\.file)==[mailbox] && imported.model.items[0].access.hasSecurityScope && imported.model.items[0].access.contains(mailbox) && imported.model.previewDocument.appearancePreferences===prefs,"External arbitrary-extension patch/grant/preferences were lost")
        imported.model.options.signOff=true
        invoke(["--command=importpatch","--path",mailbox.path,"--droptarget",target.path]);try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
        try require(imported.model.items.count==1 && imported.model.items[0].id==firstID && imported.model.options.signOff,"Repeated Import replaced options or duplicated a path")
        let beforeApply=try await destination.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(beforeApply==base.hash && Data(contentsOf:target.appendingPathComponent("file.txt"))==Data("one\n".utf8),"Import command applied before native acceptance")
        imported.model.apply();try await wait {!imported.model.busy && imported.model.finished}
        try require(try Data(contentsOf:target.appendingPathComponent("file.txt"))==Data("two 🐢\n".utf8),"Accepted Import did not apply mail patch")
        imported.close()
        let finalSource=try await repo.rebaseCommit("HEAD")
        try require(finalSource.hash==tip.hash && Data(contentsOf:source.appendingPathComponent(".git/index"))==sourceIndex,"Patch commands modified source HEAD/index")
        try await verifyPatchCommandChooser(container:container,source:source,target:target,mailbox:mailbox,git:git,prefs:prefs)
        print("PASS: patch command family: source range/Since presets and inactive fields, real Format Patch and ZIP export, preserved command drafts/preferences, arbitrary-extension external Import with retained grants and real git am; chooser duplicate/Cancel/late/original-owner/retirement and wrong-grant fences; source HEAD/index unchanged and owned windows closed")
    }
    @MainActor private static func verifyPatchCommandChooser(container:URL,source:URL,target:URL,mailbox:URL,git:URL,prefs:UserDefaults) async throws {
        let bookmarks=PatchCommandBookmarks()
        func make()->(RepositoryModel,NSWindow) {
            let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent(UUID().uuidString+".json")))
            model.requiresRepositoryScope=true;model.repositoryBookmarkProvider=bookmarks;model.fileComparisonPreferences=prefs;model.notifyFinder={};model.commandLinePatchPermission={_ in RepositoryAccessLease(url:mailbox.deletingLastPathComponent(),provider:bookmarks)}
            let host=NSWindow(contentRect:.init(x:0,y:0,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;model.workspaceWindow=host
            return(model,host)
        }
        func owners()->[ImportPatchWindowController] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? ImportPatchWindowController}}
        for mode in ["accept","cancel","close","retire"] {
            let (model,host)=make();defer {model.stopMonitoringForTermination();host.close()}
            var reply:((NSApplication.ModalResponse)->Void)?,parent:NSWindow?,calls=0
            model.presentCommandImportFolderPanel={_,owner,answer in parent=owner;reply=answer;calls += 1};model.selectedCommandImportFolderURL={_ in target}
            model.handleCommandLine(arguments:["--command=importpatch","--path",mailbox.path],currentDirectory:container.path)
            try await wait {reply != nil}
            try require(model.hasPendingRepositoryWork && model.busy && parent === host && calls==1,"Import chooser did not capture its pending owner")
            model.handleCommandLine(arguments:["--command=importpatch","--path",mailbox.path],currentDirectory:container.path)
            try require(calls==1,"Pending chooser was replaced")
            if mode=="close" {let other=NSWindow();other.isReleasedWhenClosed=false;model.workspaceWindow=other;host.close();other.close()}
            else if mode=="retire" {model.stopMonitoringForTermination()}
            else {reply?(mode=="accept" ? .OK:.cancel)}
            try await wait {!model.hasPendingRepositoryWork && !model.busy}
            reply?(.OK)
            if mode=="accept" {try require(owners().count==1 && owners()[0].model.items.count==1,"Accepted duplicate reply opened wrong import list");owners()[0].close()}
            else {try require(owners().isEmpty && model.root==nil,"Cancelled/closed/retired import launched late")}
        }
        let (denied,host)=make();defer {denied.stopMonitoringForTermination();host.close()}
        denied.commandLinePatchPermission={_ in RepositoryAccessLease(url:source,provider:bookmarks)}
        denied.handleCommandLine(arguments:["--command=importpatch","--path",mailbox.path,"--droptarget",target.path],currentDirectory:container.path)
        try await wait {!denied.busy && !denied.hasPendingRepositoryWork}
        try require(owners().isEmpty && denied.error != nil,"Wrong file grant reached native Import")
        denied.commandLinePatchPermission={_ in nil};denied.error=nil
        denied.handleCommandLine(arguments:["--command=importpatch","--path",mailbox.path,"--droptarget",target.path],currentDirectory:container.path)
        try await wait {!denied.busy && !denied.hasPendingRepositoryWork}
        try require(owners().isEmpty && denied.root==nil,"Cancelled file permission adopted a repository")
        denied.commandLinePatchPermission={_ in RepositoryAccessLease(url:mailbox.deletingLastPathComponent(),provider:bookmarks)}
        denied.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:source,provider:bookmarks)};denied.error=nil
        denied.handleCommandLine(arguments:["--command=importpatch","--path",mailbox.path,"--droptarget",target.path],currentDirectory:container.path)
        try await wait {!denied.busy && !denied.hasPendingRepositoryWork}
        try require(owners().isEmpty && denied.root==nil && denied.error != nil,"Wrong repository grant reached native Import")
        denied.error=nil
        denied.handleCommandLine(arguments:["--command=importpatch","--path",mailbox.path,"--droptarget",target.appendingPathComponent(".git").path],currentDirectory:container.path)
        try await wait {!denied.busy && !denied.hasPendingRepositoryWork}
        try require(owners().isEmpty && denied.error?.contains("Git metadata")==true,"Explicit metadata target reached native Import")
    }
}
