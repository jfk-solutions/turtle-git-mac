import AppKit
import TurtleGitCore

private final class MaintenanceBookmarks: RepositoryBookmarkProvider {
    func create(for url:URL) throws -> Data {Data(url.path.utf8)}
    func resolve(_ data:Data) throws -> ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}

extension PrimaryCommandsVerification {
    @MainActor static func verifyMaintenance() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.MaintenanceCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        try await verifyCreationLaunches(container:container,git:git,prefs:prefs)
        try await verifyMaintenanceActions(container:container,git:git,prefs:prefs)
        print("PASS: repository maintenance command family: normal/bare/missing-parent Init; owned folder chooser duplicate/Cancel/wrong/late/retired/actual close; preserved Cleanup draft, scoped preview and permanent action; Ignore mask/delete keep and remove questions; linked exclude grant reuse and denial; private state and owned cleanup")
    }
    @MainActor private static func workspace(container:URL,git:URL,prefs:UserDefaults)->(RepositoryModel,NSWindow) {
        let bookmarks=MaintenanceBookmarks()
        let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent(UUID().uuidString+".json")))
        model.fileComparisonPreferences=prefs;model.repositoryBookmarkProvider=bookmarks;model.notifyFinder={};model.requiresRepositoryScope=true
        model.createWindowFactory={folder,access in let result=CreateRepositoryWindowController(folder:folder,access:access);result.model.executable=git;result.model.showSuccess={};return result}
        let host=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;model.workspaceWindow=host
        return(model,host)
    }
    @MainActor private static func visible<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
    private static func same(_ first:URL?,_ second:URL)->Bool {first?.resolvingSymlinksInPath().path==second.resolvingSymlinksInPath().path}
    @MainActor private static func verifyCreationLaunches(container:URL,git:URL,prefs:UserDefaults) async throws {
        let bookmarks=MaintenanceBookmarks()
        for bare in [false,true] {
            let (model,host)=workspace(container:container,git:git,prefs:prefs)
            defer {model.stopMonitoringForTermination();host.close()}
            let target=container.appendingPathComponent(bare ? "new-parent/bare.git":"new-parent/normal")
            model.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:container,provider:bookmarks)}
            model.handleCommandLine(arguments:["--command=repocreate","--path",target.path],currentDirectory:container.path)
            let owner=try requireOne(visible(CreateRepositoryWindowController.self));defer {owner.close()}
            try require(owner.model.folder==target && owner.model.bare==bare && owner.model.ready && model.root==nil && !FileManager.default.fileExists(atPath:target.path),"Create launch lost target/default mode or initialized without acceptance")
            owner.model.initialize();try await wait {owner.model.completed && !owner.model.busy && !model.busy && same(model.root,target)}
            try require(model.bare==bare && model.error==nil,"Create result did not adopt normal/bare root through parent permission")
            owner.model.acknowledgeSuccess();model.closeRepository()
        }
        let (model,host)=workspace(container:container,git:git,prefs:prefs)
        defer {model.stopMonitoringForTermination();host.close()}
        let target=container.appendingPathComponent("permission-child/new-repo")
        var reply:((NSApplication.ModalResponse)->Void)?,selected:URL?=container,panels=0,creations=0
        model.selectedCreationFolderURL={_ in selected}
        model.presentCreationFolderPanel={panel,owner,completion in panels += 1;reply=completion}
        model.createWindowFactory={folder,access in creations += 1;let result=CreateRepositoryWindowController(folder:folder,access:access);result.model.executable=git;result.model.showSuccess={};return result}
        func invoke() {model.handleCommandLine(arguments:["--command=repocreate","--path",target.path],currentDirectory:container.path)}
        invoke();try require(reply != nil && model.hasPendingRepositoryWork,"Creation folder chooser did not own request")
        let delegate=TurtleGitApplicationDelegate();delegate.repositoryModel=model
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Creation chooser did not block Quit")
        invoke();try require(panels==1 && model.error != nil,"Another launch replaced the pending folder choice")
        reply?(.cancel);reply=nil;model.error=nil
        try require(!model.hasPendingRepositoryWork && creations==0,"Cancelled chooser created a dialog")
        selected=container.appendingPathComponent("unrelated");try FileManager.default.createDirectory(at:selected!,withIntermediateDirectories:true)
        invoke();reply?(.OK);reply=nil
        try require(model.error != nil && creations==0 && !model.hasPendingRepositoryWork,"Unrelated parent grant was accepted")
        model.error=nil;selected=container;invoke();let duplicate=reply;duplicate?(.OK);duplicate?(.OK);reply=nil
        try require(creations==1 && !model.hasPendingRepositoryWork,"Folder callback was consumed more than once")
        let created=try requireOne(visible(CreateRepositoryWindowController.self));created.close()
        // Closing the original owner cancels a picker despite replacement workspace binding.
        invoke();let late=reply;reply=nil
        let replacement=NSWindow(contentRect:host.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false);replacement.isReleasedWhenClosed=false;defer {replacement.close()};model.workspaceWindow=replacement
        host.close();try await wait {!model.hasPendingRepositoryWork};late?(.OK)
        try require(creations==1 && visible(CreateRepositoryWindowController.self).isEmpty && !FileManager.default.fileExists(atPath:target.path),"Closed original chooser accepted a late reply")
        // Retirement also rejects an OK reply which arrives after cancellation.
        let (retired,retiredHost)=workspace(container:container,git:git,prefs:prefs);defer {retired.stopMonitoringForTermination();retiredHost.close()}
        var retiredReply:((NSApplication.ModalResponse)->Void)?
        retired.presentCreationFolderPanel={_,_,completion in retiredReply=completion};retired.selectedCreationFolderURL={_ in container}
        retired.handleCommandLine(arguments:["--command=repocreate","--path",target.path],currentDirectory:container.path)
        retired.stopMonitoringForTermination();retiredReply?(.OK)
        try require(!retired.hasPendingRepositoryWork && visible(CreateRepositoryWindowController.self).isEmpty,"Retired folder chooser published a dialog")
        // Exercise real native sheet attachment and forced owner closure.
        let (actual,actualHost)=workspace(container:container,git:git,prefs:prefs);defer {actual.stopMonitoringForTermination();actualHost.close()}
        actualHost.orderFront(nil)
        actual.handleCommandLine(arguments:["--command=repocreate","--path",target.path],currentDirectory:container.path)
        try await wait {actualHost.attachedSheet is NSOpenPanel}
        actualHost.close();try await wait {!actual.hasPendingRepositoryWork && actualHost.attachedSheet==nil}
        try require(visible(CreateRepositoryWindowController.self).isEmpty && !FileManager.default.fileExists(atPath:target.path),"Actual folder picker closure initialized or leaked a request")
        print("Creation commands: normal/bare nested destination and captured parent permissions; no implicit init; one owned chooser, private injected and actual sheet closure passed")
    }
    @MainActor private static func verifyMaintenanceActions(container:URL,git:URL,prefs:UserDefaults) async throws {
        let root=container.appendingPathComponent("working"),linked=container.appendingPathComponent("linked"),bookmarks=MaintenanceBookmarks()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Maintenance QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let tracked=root.appendingPathComponent("tracked.txt"),trackedBytes=Data("tracked\n".utf8)
        try trackedBytes.write(to:tracked);try Data("# retained\r\n".utf8).write(to:root.appendingPathComponent(".gitignore"));try await repo.stage(["tracked.txt",".gitignore"]);_ = try await repo.commit(message:"base")
        let head=try await repo.rebaseCommit("HEAD"),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let selected=root.appendingPathComponent("clean [1]"),sibling=root.appendingPathComponent("clean 1")
        for folder in [selected,sibling] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try Data("untracked\n".utf8).write(to:folder.appendingPathComponent("file"))}
        let (model,host)=workspace(container:container,git:git,prefs:prefs);defer {model.stopMonitoringForTermination();host.close();for window in NSApp.windows {window.close()}}
        model.commandLineRepositoryPermission={paths in RepositoryAccessLease(url:paths[0].path.hasPrefix(linked.path) ? linked:root,provider:bookmarks)}
        func invoke(_ args:[String]) {model.handleCommandLine(arguments:args,currentDirectory:root.path)}
        invoke(["--command=cleanup","--path",selected.appendingPathComponent("file").path])
        try await wait {!model.busy && !visible(CleanWindowController.self).isEmpty}
        let clean=try requireOne(visible(CleanWindowController.self));clean.model.dryRun=true;clean.model.options.type = .nonIgnored;clean.model.permanently=true
        invoke(["--command=cleanup","--path",sibling.path]);try await wait {!model.busy}
        try require(visible(CleanWindowController.self).count==1 && clean.model.dryRun && clean.model.scopePaths==["clean [1]/file"] && model.error != nil,"Cleanup command replaced existing options/scope")
        model.error=nil;clean.model.accept()
        try await wait {visible(CleanProgressWindowController.self).first?.model.busy == false && CleanProgressWindowModel.activeOperations==0}
        let progress=try requireOne(visible(CleanProgressWindowController.self))
        try require(progress.model.previewSucceeded && !progress.model.failed && FileManager.default.fileExists(atPath:selected.appendingPathComponent("file").path),"Cleanup dry run failed or removed files")
        progress.model.remove(permanently:true);try await wait {!progress.model.busy && CleanProgressWindowModel.activeOperations==0 && !model.busy}
        try require(!FileManager.default.fileExists(atPath:selected.appendingPathComponent("file").path) && FileManager.default.fileExists(atPath:sibling.appendingPathComponent("file").path),"Cleanup lost literal containing-directory scope")
        try require(try Data(contentsOf:tracked)==trackedBytes && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Cleanup changed tracked content or index");progress.close()
        let folder=root.appendingPathComponent("rules"),ignored=folder.appendingPathComponent("item.tmp")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try Data("keep\n".utf8).write(to:ignored)
        var question:((NSApplication.ModalResponse)->Void)?,alert:NSAlert?
        model.ignoreWindowFactory={repository,access,paths,mask,delete in
            let result=try IgnoreWindowController(repository:repository,access:access,paths:paths,mask:mask,delete:delete,preferences:prefs)
            result.model.requiresSecurityScope=true;result.presentQuestion={_,value,reply in alert=value;question=reply;return true};return result
        }
        invoke(["--command=ignore","--path",ignored.path,"--onlymask"])
        try await wait {!model.busy && !visible(IgnoreWindowController.self).isEmpty}
        let ignore=try requireOne(visible(IgnoreWindowController.self));ignore.model.options.destination = .containingFolders
        invoke(["--command=ignore","--path",ignored.path,"--onlymask"]);try await wait {!model.busy}
        try require(visible(IgnoreWindowController.self).count==1 && ignore.model.options.mask && ignore.model.options.destination == .containingFolders,"Ignore command replaced edited destination")
        ignore.model.apply();try await wait {IgnoreWindowModel.activeOperations==0 && visible(IgnoreWindowController.self).isEmpty && !model.busy}
        try require(try String(contentsOf:folder.appendingPathComponent(".gitignore"),encoding:.utf8)=="/*.tmp\n","Ignore mask/destination did not reach actual rule writer")
        for keep in [true,false] {
            invoke(["--command=ignore","--path",tracked.path,"--delete"]);try await wait {!model.busy && !visible(IgnoreWindowController.self).isEmpty}
            let deletion=try requireOne(visible(IgnoreWindowController.self));deletion.model.apply();try await wait {question != nil}
            try require(alert?.messageText=="Keep file locally?" && (try? Data(contentsOf:tracked))==trackedBytes,"Ignore-delete skipped keep-local review")
            question?(keep ? .alertFirstButtonReturn:.alertSecondButtonReturn);question=nil;alert=nil
            try await wait {question != nil}
            try require(deletion.model.removed==1 && FileManager.default.fileExists(atPath:tracked.path)==keep,"Ignore-delete mode did not reach removal plan")
            question?(.alertFirstButtonReturn);question=nil;alert=nil
            try await wait {IgnoreWindowModel.activeOperations==0 && visible(IgnoreWindowController.self).isEmpty && !model.busy}
            _ = try await repo.run(["reset","--hard","HEAD"]);try await wait {!model.busy}
        }
        _ = try await repo.run(["worktree","add","-b","linked",linked.path])
        let linkedFile=linked.appendingPathComponent("secret.tmp");try Data("linked\n".utf8).write(to:linkedFile)
        var asks=0
        model.chooseRepositoryMetadataFolder={_,_ in asks += 1;return root.appendingPathComponent(".git")}
        invoke(["--command=ignore","--path",linkedFile.path]);try await wait {!model.busy && !visible(IgnoreWindowController.self).isEmpty}
        let shared=try requireOne(visible(IgnoreWindowController.self));shared.model.options.destination = .exclude;shared.model.apply()
        try await wait {IgnoreWindowModel.activeOperations==0 && visible(IgnoreWindowController.self).isEmpty && !model.busy}
        let exclude=root.appendingPathComponent(".git/info/exclude"),excludeBytes=try Data(contentsOf:exclude)
        try require(asks==1 && String(decoding:excludeBytes,as:UTF8.self).contains("/secret.tmp"),"Ignore did not reuse linked common-metadata grant")
        var deniedOptions=try IgnoreOptions(paths:["denied.tmp"]);deniedOptions.destination = .exclude
        let denied=IgnoreWindowModel(repository:GitRepository(root:linked,executable:git),access:RepositoryAccessLease(url:linked,provider:bookmarks),options:deniedOptions)
        denied.requiresSecurityScope=true;denied.apply();try await wait {!denied.busy}
        try require(denied.error != nil && (try? Data(contentsOf:exclude))==excludeBytes,"Missing common-metadata grant wrote exclude anyway");denied.invalidate()
        try require(try await repo.rebaseCommit("HEAD").hash==head.hash && Data(contentsOf:tracked)==trackedBytes,"Maintenance workflows changed HEAD/tracked bytes")
        print("Maintenance actions: captured Cleanup options and real scoped preview/removal; Ignore mask/destination and keep/delete questions; linked exclude common-grant reuse and explicit denial passed")
    }
}
