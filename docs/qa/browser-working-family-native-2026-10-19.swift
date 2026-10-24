import AppKit
import TurtleGitCore

struct BrowserWorkingFamilyVerification {
    struct BookmarkProvider:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark{ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{true}
        func stopAccessing(_ url:URL){}
    }
    @MainActor static func verify()async throws {
        func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
        func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:message,code:2)}
        func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),fm=FileManager.default
        let folder=root.appendingPathComponent("route-repository"),childFolder=folder.appendingPathComponent("module")
        try fm.createDirectory(at:childFolder,withIntermediateDirectories:true)
        func initialize(_ location:URL)async throws->GitRepository{
            let repo=GitRepository(root:location,executable:git);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Browser Routes"),("user.email","routes@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")]{_ = try await repo.run(["config",key,value])};return repo
        }
        let child=try await initialize(childFolder)
        try Data("child historical\n".utf8).write(to:childFolder.appendingPathComponent("child.txt"));try await child.stage(["child.txt"]);_ = try await child.commit(message:"Child snapshot")
        let childHash=try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let repo=try await initialize(folder),historical=Data("historical parent\n".utf8),working=Data("changed current parent\n".utf8),file=folder.appendingPathComponent("file.txt")
        try historical.write(to:file)
        try Data("[submodule \"module\"]\npath = module\nurl = ../unused-local-module\n[submodule \"missing\"]\npath = missing\nurl = ../unused-local-missing\n".utf8).write(to:folder.appendingPathComponent(".gitmodules"))
        try await repo.stage(["file.txt",".gitmodules","module"])
        _ = try await repo.run(["update-index","--add","--cacheinfo","160000,"+childHash+",missing"])
        _ = try await repo.commit(message:"Browser source snapshots")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,pinned=String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines),index=try await repo.run(["ls-files","--stage","-z"]).stdout
        try working.write(to:file)
        let suite="TurtleGit.BrowserRoutes."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,other=UserDefaults(suiteName:suite+".replacement")!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        defer{prefs.removePersistentDomain(forName:suite);other.removePersistentDomain(forName:suite+".replacement")}
        let marks=WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("private-mark.json"),provider:BookmarkProvider())
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},comparisonMarks:marks)
        defer{workspace.stopMonitoringForTermination()}
        workspace.fileComparisonPreferences=other;workspace.comparisonMarkPublication={_ in false}
        let permission=RepositoryAccessLease(url:folder,provider:BookmarkProvider())
        let source=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        source.isReleasedWhenClosed=false;source.alphaValue=0;source.appearance=NSAppearance(named:.darkAqua);defer{source.close()}
        var browsers:[RepositoryBrowserWindowController]=[],comparisons:[FileComparisonWindowController]=[],logs:[LogWindowController]=[],updates:[SubmoduleUpdateWindowController]=[]
        workspace.browserWindowPresentation={browsers.append($0);$0.showWindow(nil)}
        workspace.fileComparisonWindowPresentation={comparisons.append($0);$0.showWindow(nil)}
        workspace.logWindowPresentation={logs.append($0);$0.showWindow(nil)}
        workspace.submoduleUpdateWindowPresentation={updates.append($0);$0.showWindow(nil)}
        defer{updates.forEach{$0.close()};logs.forEach{$0.close()};comparisons.forEach{$0.close()};browsers.forEach{$0.close()}}
        workspace.showRepositoryBrowser(repository:repo,access:permission,revision:pinned,preferences:prefs,sourceWindow:source)
        try await wait("Actual root Browser did not load"){browsers.count==1 && !browsers[0].model.busy && browsers[0].model.snapshot != nil}
        let owner=browsers[0],model=owner.model,window=owner.window!
        try require(model.preferences===prefs && model.access===permission && window.alphaValue==0 && window.appearance?.name==source.appearance?.name,"Root Browser lost captured preferences/access/appearance")
        owner.commandKeyWindow={window};window.contentView?.layoutSubtreeIfNeeded()
        try await wait("Native Browser contents table did not attach"){owner.contentsTable != nil}
        owner.focusInitialContentsIfNeeded();try require(window.firstResponder===owner.contentsTable,"Initial Browser focus did not enter native contents")
        let path=views(window.contentView).compactMap{$0 as? NSTextField}.first{$0.accessibilityLabel()=="Repository path"}!
        window.makeFirstResponder(path);let focused=window.firstResponder
        model.refresh();try await wait("Browser focus refresh did not settle"){!model.busy && model.snapshot != nil};owner.focusInitialContentsIfNeeded()
        try require(window.firstResponder===focused,"Refresh stole deliberate Browser field focus")
        let entry=model.entries.first{$0.name=="file.txt"}!
        model.compareEntryToWorkingTree(entry)
        try await wait("Actual Compare WC controller missing"){comparisons.count==1 && !workspace.busy && comparisons[0].model.document != nil}
        let compare=comparisons[0]
        try require(compare.model.comparisonDefaults===prefs && compare.model.openPermissions.contains{$0===permission} && compare.window?.appearance?.name==window.appearance?.name,"Compare WC lost originating preferences/access/appearance")
        try require(compare.model.document?.base.bytes==historical && compare.model.document?.destination.bytes==working,"Compare WC lost historical/current file bytes")
        compare.close()
        let externalA=root.appendingPathComponent("marked-one.txt"),externalB=root.appendingPathComponent("marked-two.txt"),markedBytes=Data("external marked source\n".utf8)
        try markedBytes.write(to:externalA);try Data("replacement marked source\n".utf8).write(to:externalB)
        let externalPermission=RepositoryAccessLease(url:root,provider:BookmarkProvider())
        let first=try marks.remember(file:externalA,permission:externalPermission);try workspace.refreshWorkingComparisonMark()
        try require(model.comparisonMark?.workingAccess?.mark.id==first.id,"Existing Browser missed new working mark")
        model.markForComparison(entry)
        try await wait("Historical Browser mark resolution did not settle"){!model.busy && model.comparisonMark?.workingAccess==nil && model.comparisonMark?.revision==pinned}
        let localMark=model.comparisonMark;try workspace.refreshWorkingComparisonMark()
        try require(model.comparisonMark?.workingAccess==nil && model.comparisonMark?.revision==localMark?.revision,"Same working mark displaced newer local historical mark")
        let second=try marks.remember(file:externalB,permission:externalPermission);try workspace.refreshWorkingComparisonMark()
        try require(model.comparisonMark?.workingAccess?.mark.id==second.id,"Existing Browser missed replacement global mark")
        let stale=model.menuTarget([entry])!;_ = try marks.remember(file:externalA,permission:externalPermission);model.prepareComparisonMenu()
        try require(!model.acceptsComparisonMark(stale) && model.comparisonMark?.workingAccess?.file==externalA,"Actual menu refresh kept stale comparison-mark receipt")
        try marks.clear();try workspace.refreshWorkingComparisonMark();try require(model.comparisonMark==nil,"Global clear retained imported Browser mark")
        model.markForComparison(entry)
        try await wait("Replacement historical Browser mark resolution did not settle"){!model.busy && model.comparisonMark?.workingAccess==nil && model.comparisonMark?.revision==pinned}
        try workspace.refreshWorkingComparisonMark()
        try require(model.comparisonMark?.workingAccess==nil && model.comparisonMark?.revision==pinned,"Empty global refresh erased Browser historical mark")
        _ = try marks.remember(file:externalA,permission:externalPermission);try workspace.refreshWorkingComparisonMark();model.compareWithMarkedFile(entry)
        try await wait("Actual marked comparison controller missing"){comparisons.count==2 && !model.busy && !workspace.busy && comparisons[1].model.document != nil}
        let marked=comparisons[1]
        try require(marked.model.comparisonDefaults===prefs && marked.model.openPermissions.contains{$0===permission} && marked.model.openPermissions.contains{$0.contains(externalA)} && marked.window?.appearance?.name==window.appearance?.name,"Marked compare lost captured preferences/permissions/appearance")
        try require(marked.model.document?.base.bytes==markedBytes && marked.model.document?.destination.bytes==historical && model.comparisonMark==nil && (try marks.snapshot())==nil,"Marked compare changed bytes or did not consume published mark")
        marked.close()
        let module=model.entries.first{$0.name=="module"}!,missing=model.entries.first{$0.name=="missing"}!
        model.showSubmoduleLog(module)
        try await wait("Initialized gitlink Log route missing"){logs.count==1 && !model.busy}
        try require(GitReferenceName.equal(logs[0].model.repository.root.path,child.root.path) && logs[0].model.endRevision==childHash && logs[0].model.repositoryAccess===permission && logs[0].model.colorPreferences===prefs && logs[0].window?.appearance?.name==window.appearance?.name,"Gitlink Log lost pinned child root/revision/appearance: root=\(logs[0].model.repository.root.path.debugDescription), expected=\(child.root.path.debugDescription), original=\(childFolder.path.debugDescription), revision=\(String(describing:logs[0].model.endRevision)), expectedRevision=\(childHash), sameAccess=\(logs[0].model.repositoryAccess===permission), samePreferences=\(logs[0].model.colorPreferences===prefs), appearance=\(String(describing:logs[0].window?.appearance?.name)), expectedAppearance=\(String(describing:window.appearance?.name))")
        model.open(module)
        try await wait("Initialized gitlink Browser route missing"){browsers.count==2 && !model.busy && browsers[1].model.snapshot != nil && !browsers[1].model.busy}
        try require(GitReferenceName.equal(browsers[1].model.repository.root.path,child.root.path) && browsers[1].model.snapshot?.objectID==childHash && browsers[1].model.preferences===prefs && browsers[1].model.access===permission && browsers[1].window?.appearance?.name==window.appearance?.name,"Gitlink Browser lost child revision/preferences/access/appearance")
        var alert:NSAlert?,updateReply:((NSApplication.ModalResponse)->Void)?
        owner.presentSubmoduleUpdate={question,parent,reply in alert=question;updateReply=reply;question.beginSheetModal(for:parent,completionHandler:reply)}
        model.open(missing);try await wait("Missing gitlink Update offer did not attach"){alert?.window.sheetParent===window}
        try require(alert?.window.alphaValue==0 && alert?.window.appearance?.name==window.appearance?.name && RepositoryBrowserFileOperation.activeRequests==1,"Missing gitlink offer lost source appearance or sheet ownership")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped actual Browser Update offer ownership")
        updateReply?(.alertFirstButtonReturn);updateReply?(.alertFirstButtonReturn)
        try await wait("Missing gitlink Update route did not detach before handoff"){updates.count==1 && window.attachedSheet==nil && RepositoryBrowserFileOperation.activeRequests==0}
        try await wait("Submodule Update choices did not load"){!updates[0].model.busy}
        try require(GitReferenceName.equal(updates[0].model.repository.root.path,repo.root.path) && updates[0].model.repositoryAccess===permission && updates[0].model.presentationPreferences===prefs && updates[0].model.selection.contains(GitReferenceName("missing")) && updates[0].window?.appearance?.name==window.appearance?.name,"Gitlink Update lost captured repository/preferences/selection/appearance")
        updates[0].close();try await wait("Submodule Update read did not drain"){SubmoduleUpdateWindowModel.activeReads==0}
        alert=nil;model.open(missing);try await wait("Retired Update offer missing"){alert?.window.sheetParent===window}
        owner.close();updateReply?(.alertFirstButtonReturn)
        try await wait("Retired Browser child did not drain"){!model.active && window.attachedSheet==nil && RepositoryBrowserFileOperation.activeRequests==0 && RepositoryBrowserWindowModel.activeOperations==0}
        try require(updates.count==1,"Late retired Update response opened a child")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(finalHead==head && finalIndex==index && (try Data(contentsOf:file))==working,"Browser routes changed source HEAD/index/working bytes")
        print("Browser actual root captured Compare WC/marked compare, working mark publication, gitlink routes, initial focus and retired-child ownership passed.")
    }
}
