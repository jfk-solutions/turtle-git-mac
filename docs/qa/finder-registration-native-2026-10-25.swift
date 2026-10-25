// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

final class RegistrationBookmarks:RepositoryBookmarkProvider {
    var created=[String]()
    func create(for url:URL)throws->Data {created.append(url.path);return Data(("PRIVATE:"+url.path).utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {let text=String(decoding:data,as:UTF8.self);guard text.hasPrefix("PRIVATE:") else {throw RepositoryAccessFailure.unknownRepository};return .init(url:URL(fileURLWithPath:String(text.dropFirst(8))),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}
private extension NSWindow {
    @objc func registrationOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));registrationOrder(mode,relativeTo:number)}
}
@MainActor
@main enum FinderRegistrationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"Finder registration \(line): "+message)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Finder registration timeout \(line)")}
    @MainActor final class Context {
        // Match RepositoryAccessStore's canonical namespace once, before deriving
        // linked/Clone paths. The runner's POSIX /private/var spelling is an alias.
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath(),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let provider=RegistrationBookmarks(),suite="TurtleGit.Registration."+UUID().uuidString,prefs:UserDefaults
        let recent:RepositoryAccessStore,watched:RepositoryAccessStore,manager:FinderWatchManager,workspace:RepositoryModel
        let cache:FinderSnapshotStore
        let parent:NSWindow
        var clones=[CloneWindowController](),panels=0
        var other:GitRepository!,source:GitRepository!,third:GitRepository!
        var selected:URL?,permissionReply:((NSApplication.ModalResponse)->Void)?
        var hold:URL {root.appendingPathComponent("hold")};var release:URL {root.appendingPathComponent("release")};var started:URL {root.appendingPathComponent("started")}
        init()throws {
            prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"EnableGravatar")
            recent=try RepositoryAccessStore(storageURL:root.appendingPathComponent("recents.json"),provider:provider)
            watched=try RepositoryAccessStore(storageURL:root.appendingPathComponent("watches.json"),provider:provider)
            let wrapper=root.appendingPathComponent("held-helper")
            cache=FinderSnapshotStore(url:root.appendingPathComponent("private-status.json"))
            manager=FinderWatchManager(permissions:watched,cache:cache,requireScope:true,scopeProvider:provider,repositoryFactory:{GitRepository(root:$0,executable:wrapper,libgit2Configuration:.init(enabled:false))},notify:{})
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))},finderWatches:manager,savedAccessStore:recent)
            workspace.requiresRepositoryScope=true;workspace.repositoryBookmarkProvider=provider;workspace.fileComparisonPreferences=prefs
            parent=NSWindow(contentRect:.init(x:-24000,y:-24000,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false);parent.isReleasedWhenClosed=false;parent.alphaValue=0;workspace.workspaceWindow=parent;parent.orderFront(nil)
            workspace.selectedFinderServiceFolderURL={ [weak self] _ in self?.selected }
            workspace.presentFinderServiceFolderPanel={ [weak self] panel,owner,reply in
                self?.panels += 1;self?.permissionReply=reply;owner?.beginSheet(panel,completionHandler:reply)
            }
        }
        func repo(_ name:String)async throws->GitRepository {
            let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let value=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false));_=try await value.run(["init","--template=","-b","main"])
            for (key,text) in [("user.name","Registration QA"),("user.email","registration@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await value.run(["config",key,text])}
            try Data("baseline\n".utf8).write(to:folder.appendingPathComponent("file"));try await value.stage(["file"]);_=try await value.commit(message:"registration fixture");return value
        }
        func prepare()async throws {
            func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            let shell="""
            #!/bin/sh
            inspect() {
              while [ "$#" -gt 0 ]; do
                case "$1" in -C|-c|--git-dir|--work-tree) shift; shift;; --*) shift;; *) break;; esac
              done
              if [ "${1-}" = status ] && [ -f \(quote(root.appendingPathComponent("fail-status").path)) ]; then
                echo 'controlled first publication failure' >&2
                exit 73
              fi
              if [ "${1-}" = status ] && [ -f \(quote(root.appendingPathComponent("hold-status").path)) ]; then
                exec 9>\(quote(root.appendingPathComponent("owned-resource").path))
                : >\(quote(started.path))
                while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.02; done
              fi
              if [ "${1-}" = rev-parse ] && [ -f \(quote(hold.path)) ]; then
                exec 9>\(quote(root.appendingPathComponent("owned-resource").path))
                : >\(quote(started.path))
                while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.02; done
              fi
            }
            inspect "$@"
            exec \(quote(git.path)) "$@"
            """
            let wrapper=root.appendingPathComponent("held-helper");try Data(shell.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            other=try await repo("other");source=try await repo("source café");third=try await repo("third")
            await manager.add(other.root);try await FinderRegistrationVerification.wait {manager.pendingOperations==0 && FinderSnapshot.readLive(from:cache.url)?.roots.contains(other.root.path)==true}
            try FinderRegistrationVerification.require(manager.rows.count==1 && manager.backgroundService==nil,"Private baseline watch missing or service enabled")
        }
        func submit(_ folder:URL)async throws {
            selected=folder;permissionReply=nil
            try FinderRegistrationVerification.require(workspace.handleFinderService(FinderRequest(action:.registerRepository,paths:[folder])),"Accepted folder registration refused")
            if permissionReply==nil && workspace.hasPendingFinderServiceWork {try await FinderRegistrationVerification.wait {permissionReply != nil || !workspace.hasPendingFinderServiceWork}}
        }
        func answer(_ response:NSApplication.ModalResponse) {permissionReply?(response);permissionReply=nil}
        func block()throws {try? FileManager.default.removeItem(at:release);try? FileManager.default.removeItem(at:started);try Data().write(to:hold)}
        func unblock() {try? Data().write(to:release);try? FileManager.default.removeItem(at:hold)}
        func cleanup()async throws {
            unblock();answer(.cancel);workspace.stopMonitoringForTermination()
            for clone in clones {clone.progressController?.model.invalidate();clone.progressController?.close();clone.model.invalidate();clone.close()}
            await manager.shutdown();parent.close()
            try await FinderRegistrationVerification.wait {!workspace.hasPendingFinderServiceWork && !workspace.busy && manager.pendingOperations==0 && CloneWindowModel.activeOperations==0 && CloneProgressWindowModel.activeOperations==0 && CloneWindowController.activeChildReleases==0}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func registration(_ c:Context)async throws {
        let original=c.watched.repositories[0]
        try await c.submit(c.source.root);try require(c.permissionReply != nil && c.parent.attachedSheet != nil,"First use did not own actual folder sheet");c.answer(.cancel)
        try await wait {!c.workspace.hasPendingFinderServiceWork};try require(c.watched.repositories.count==1 && c.recent.repositories.isEmpty,"Cancelled Add saved grants")
        try await c.submit(c.source.root);c.answer(.OK);try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.workspace.error==nil && c.workspace.root==nil,"Add failed or switched unrelated workspace: \(c.workspace.error ?? "")")
        try require(c.watched.repositories.count==2 && c.recent.repositories.count==1 && c.provider.created.contains(c.source.root.path),"Add did not persist exact child watch+recent bookmarks")
        let id=c.watched.repositories.first {$0.lastKnownPath==c.source.root.path}?.id,panels=c.panels
        try await c.submit(c.source.root);if c.permissionReply != nil {c.answer(.OK)};try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.watched.repositories.count==2 && c.watched.repositories.contains{$0.id==id} && c.panels==panels,"Duplicate Add duplicated watch or demanded unnecessary picker")
        try require(c.watched.repositories.contains{$0.id==original.id && $0.bookmark==original.bookmark} && c.manager.backgroundService==nil,"Add changed unrelated watch or enabled service")
        let reopened=try c.recent.acquire(c.recent.repositories[0].id,requireSecurityScope:true);try require(reopened.contains(c.source.root),"Persisted registration grant cannot reopen root")
        try await c.submit(c.source.root.appendingPathComponent("file"));if c.permissionReply != nil {c.answer(.OK)};try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.workspace.error != nil && c.watched.repositories.count==2,"File candidate silently registered parent")
        let linked=c.root.appendingPathComponent("linked worktree")
        _=try await c.source.run(["worktree","add","-b","linked-fixture",linked.path])
        var metadataChoices=[URL]()
        c.workspace.chooseRepositoryMetadataFolder={requirement,token in try token.check();metadataChoices.append(requirement.folder);return c.source.root}
        try await c.submit(linked);c.answer(.OK);try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.workspace.error==nil && !metadataChoices.isEmpty,"Linked metadata access was not requested/retained: \(c.workspace.error ?? "")")
        let linkedWatch=c.watched.repositories.first {$0.lastKnownPath==linked.path},linkedRecent=c.recent.repositories.first {$0.lastKnownPath==linked.path}
        try require(linkedWatch?.additionalPermissions?.contains {$0.path==c.source.root.path} == true && linkedRecent?.additionalPermissions?.contains {$0.path==c.source.root.path} == true,"Linked repository metadata grants were not persisted in both independent stores; requested=\(linked.path); source=\(c.source.root.path); choices=\(metadataChoices.map(\.path)); watches=\(c.watched.repositories.map {($0.lastKnownPath,($0.additionalPermissions ?? []).map(\.path))}); recents=\(c.recent.repositories.map {($0.lastKnownPath,($0.additionalPermissions ?? []).map(\.path))})")
        try require(c.watched.repositories.count==3 && c.manager.backgroundService==nil,"Linked registration affected unrelated watches/service")
    }
    static func clone(_ c:Context)async throws {
        try c.block();let mutating=Task {await c.manager.add(c.other.root)}
        defer {c.unblock()};try await wait {FileManager.default.fileExists(atPath:c.started.path) && c.manager.busy}
        let grant=RepositoryAccessLease(url:c.root,provider:c.provider),owner=CloneWindowController(directory:c.root,access:grant,preferences:c.prefs,executable:c.git,clipboardText:"");c.clones.append(owner)
        owner.window?.isReleasedWhenClosed=false;owner.showWindow(nil);c.workspace.configureCloneInteractions(owner)
        let destination=c.root.appendingPathComponent("cloned child");owner.model.source=c.source.root.path;owner.model.directory=destination.path
        var extraPickers=0;owner.model.presentOpenPanel={_,_,reply in extraPickers += 1;reply(.cancel)}
        owner.model.clone();try await wait {owner.model.completed != nil && c.workspace.hasPendingFinderServiceWork}
        try require(c.watched.repositories.count==1,"Queued Clone registration wrote during other watch mutation")
        c.parent.close() // Only workspace adoption is revoked; accepted Clone still registers.
        c.unblock();await mutating.value;try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(owner.model.error==nil && owner.model.completionWarning==nil,"Successful Clone registration lost result: \(owner.model.error ?? owner.model.completionWarning ?? "")")
        try require(c.watched.repositories.contains{$0.lastKnownPath==destination.path} && c.recent.repositories.contains{$0.lastKnownPath==destination.path},"Completed Clone lost persistent registration after parent close")
        try require(extraPickers==0 && c.panels==0 && c.manager.backgroundService==nil,"Clone requested second permission or enabled background service")
        let head=try await GitRepository(root:destination,executable:c.git).run(["rev-parse","HEAD"]).stdout,source=try await c.source.run(["rev-parse","HEAD"]).stdout
        try require(head==source && c.provider.created.contains(destination.path),"Clone content/child bookmark differs")
        // A completed transport remains available when registration itself fails.
        c.manager.retire()
        let refused=CloneWindowController(directory:c.root,access:grant,preferences:c.prefs,executable:c.git,clipboardText:"");c.clones.append(refused);refused.window?.isReleasedWhenClosed=false;refused.showWindow(nil)
        c.workspace.configureCloneInteractions(refused)
        let second=c.root.appendingPathComponent("clone registration failure");refused.model.source=c.source.root.path;refused.model.directory=second.path
        refused.model.clone();try await wait {refused.model.completed != nil && refused.model.completionWarning != nil && !c.workspace.hasPendingFinderServiceWork}
        try require(refused.model.error==nil && refused.model.output != nil && FileManager.default.fileExists(atPath:second.appendingPathComponent(".git").path),"Registration failure discarded successful Clone")
        try require(refused.model.completionWarning?.contains("Finder registration") == true && !c.watched.repositories.contains {$0.lastKnownPath==second.path},"Registration failure was silent or saved through retired watch owner")
    }
    static func services(_ c:Context)async throws {
        let selected=NSPasteboard.withUniqueName();defer{selected.releaseGlobally()}
        let paths=[c.source.root.appendingPathComponent("file"),c.third.root]
        selected.writeObjects(paths.map {url in let item=NSPasteboardItem();item.setString(url.absoluteString,forType:.fileURL);return item})
        let original=selected.changeCount,expected=try FinderServiceCommand.status.request(paths:paths).paths
        var opens=[[URL]](),legacy=[FinderRequest]()
        let provider=TurtleGitFinderServicesProvider(open:{opens.append($0)},submit:{legacy.append($0)})
        var error:NSString?
        provider.openInTurtleGit(selected,userData:"open",error:&error)
        try require(error==nil && opens.count==1 && opens[0].map{Data($0.path.utf8)}==expected.map{Data($0.path.utf8)} && selected.changeCount==original,"Single public Service did not capture literal selected file/folder URLs")
        let wire=try TurtleGitFinderServicesProvider.openSelectionURL(expected),decoded=try TurtleGitFinderServicesProvider.openSelection(from:wire)
        try require(decoded.map{Data($0.path.utf8)}==expected.map{Data($0.path.utf8)},"Standalone generic Open forwarding changed selected paths")
        error=nil;provider.openInTurtleGit(selected,userData:"log",error:&error)
        try require(error != nil && opens.count==1,"Generic public Service accepted arbitrary command UserData")
        let one=NSPasteboard.withUniqueName();defer{one.releaseGlobally()};one.writeObjects([c.source.root as NSURL])
        error=nil;provider.performFinderAction(one,userData:"log",error:&error)
        try require(error==nil && legacy.count==1 && legacy[0].action == .log,"Unregistered legacy handler compatibility changed")
        provider.retire();error=nil;provider.openInTurtleGit(selected,userData:"open",error:&error)
        try require(error != nil && opens.count==1,"Retired public Service delivered late selection")
        let malformed=NSPasteboard.withUniqueName();defer{malformed.releaseGlobally()};malformed.setString("plain text is not a file URL",forType:.string)
        let fresh=TurtleGitFinderServicesProvider(open:{opens.append($0)},submit:{legacy.append($0)});defer{fresh.retire()}
        error=nil;fresh.openInTurtleGit(malformed,userData:"open",error:&error)
        try require(error != nil && opens.count==1,"Public Service silently admitted text-only pasteboard")
        let actual=TurtleGitFinderServicesProvider(open:{paths in
            guard c.workspace.handleOpenServiceSelection(paths) else{throw Failure(description:"Actual generic Open refused")}
        },submit:{_ in throw Failure(description:"Generic Open entered legacy action route")});defer{actual.retire()}
        let fileBoard=NSPasteboard.withUniqueName();defer{fileBoard.releaseGlobally()};fileBoard.writeObjects([c.source.root.appendingPathComponent("file") as NSURL])
        c.selected=c.source.root;c.permissionReply=nil;error=nil
        actual.openInTurtleGit(fileBoard,userData:"open",error:&error)
        try await wait{c.permissionReply != nil}
        try require(error==nil && c.workspace.root==nil && c.workspace.error==nil && c.parent.attachedSheet is NSOpenPanel,"Ungrantable first-use selection did not enter owned Open Repository chooser")
        c.answer(.cancel);try await wait{!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy}
        try require(c.workspace.root==nil && c.recent.repositories.isEmpty,"Cancelled generic Open adopted repository or persisted permission")
        error=nil;actual.openInTurtleGit(fileBoard,userData:"open",error:&error);try await wait{c.permissionReply != nil};c.answer(.OK)
        try await wait{!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.workspace.root?.path==c.source.root.path}
        try require(error==nil && c.workspace.error==nil && c.workspace.workspaceWindow===c.parent,"Explicit generic Open failed to adopt chosen repository in existing workspace")
    }
    static func launch(_ c:Context)async throws {
        // Exercise the actual cold Finder URL -> private action router, not just
        // RepositoryModel's registration method. Permission remains explicit.
        let action=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:c.git,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in true},finderWatches:c.manager,savedAccessStore:c.recent)
        action.requiresRepositoryScope=true;action.repositoryBookmarkProvider=c.provider;action.fileComparisonPreferences=c.prefs
        action.selectedFinderServiceFolderURL={_ in c.selected}
        action.presentFinderServiceFolderPanel={panel,_,reply in c.panels += 1;c.permissionReply=reply;panel.orderFront(nil)}
        let delegate=TurtleGitApplicationDelegate();delegate.startupArguments=["--turtlegit-action-only"];delegate.makeStandaloneWorkspace={action};delegate.configureStandaloneServices={_,_ in}
        var presentations=0,activations=0;delegate.presentWorkspace={presentations += 1};delegate.activateStandaloneApplication={activations += 1}
        defer{delegate.retireFinderServices();action.stopMonitoringForTermination()}
        delegate.startupDidFinishLaunching()
        let baselineWindows=Set(NSApp.windows.map(ObjectIdentifier.init)),baselineWatches=c.watched.repositories.map(\.id)
        c.selected=c.third.root;c.permissionReply=nil
        guard let url=FinderRequest(action:.registerRepository,paths:[c.third.root]).url else{throw Failure(description:"Cold registration URL unavailable")}
        delegate.application(NSApp,open:[url])
        try await wait{c.permissionReply != nil}
        try require(action.root==nil && action.workspaceWindow==nil && presentations==0 && activations==0,"Cold registration opened workspace before folder grant")
        c.answer(.cancel)
        try await wait{!action.hasPendingFinderServiceWork && !action.busy}
        try require(action.root==nil && action.workspaceWindow==nil && presentations==0 && activations==0 && c.recent.repositories.isEmpty && c.watched.repositories.map(\.id)==baselineWatches && action.error==nil && delegate.actionErrorController==nil,"Cancelled cold registration saved/presented a workspace or surfaced an error")
        delegate.application(NSApp,open:[url]);try await wait{c.permissionReply != nil}
        c.answer(.OK)
        try await wait{!action.hasPendingFinderServiceWork && !action.busy && c.manager.pendingOperations==0}
        try require(delegate.actionRepositoryModel === action && action.root==nil && action.workspaceWindow==nil && presentations==0 && activations==0 && action.error==nil && delegate.actionErrorController==nil,"Cold registration adopted/presented a workspace or failed")
        try require(c.watched.repositories.contains{$0.lastKnownPath==c.third.root.path} && baselineWatches.allSatisfy{old in c.watched.repositories.contains{$0.id==old}} && c.manager.rows.contains{$0.path==c.third.root.path},"Cold registration failed exact watch/status publication")
        try require(c.recent.repositories.count==1 && c.recent.repositories[0].lastKnownPath==c.third.root.path && action.recentRepositories.contains{$0.lastKnownPath==c.third.root.path} && c.manager.backgroundService==nil && NSApp.windows.filter{!baselineWindows.contains(ObjectIdentifier($0))}.allSatisfy{!$0.isVisible && $0.sheetParent==nil},"Cold registration failed captured recent record, enabled background service or retained permission window")
        delegate.retireFinderServices();action.stopMonitoringForTermination()
        c.workspace.open(c.other.root);try await wait{!c.workspace.busy && c.workspace.root?.path==c.other.root.path}
        try await DialogLaunchVerification.verify(repository:c.source,existing:c.workspace,preferences:c.prefs)
    }
    static func warmRegistration(_ c:Context)async throws {
        c.workspace.open(c.other.root)
        try await wait{!c.workspace.busy && c.workspace.root?.path==c.other.root.path}
        let originalRoot=c.workspace.root,originalWindow=c.workspace.workspaceWindow,originalWatch=c.watched.repositories[0]
        let windowCount=NSApp.windows.filter(\.isVisible).count
        try await c.submit(c.source.root)
        if c.permissionReply != nil {c.answer(.OK)}
        try await wait{!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.manager.pendingOperations==0}
        try require(c.workspace.error==nil && c.workspace.root==originalRoot && c.workspace.workspaceWindow===originalWindow,"Explicit Add adopted/switched the live workspace")
        try require(NSApp.windows.filter(\.isVisible).count==windowCount && c.parent.isVisible,"Explicit Add presented a duplicate workspace")
        try require(c.watched.repositories.contains{$0.lastKnownPath==c.source.root.path} && c.watched.repositories.contains{$0.id==originalWatch.id && $0.bookmark==originalWatch.bookmark},"Explicit Add did not retain exact new/unrelated watches")
        try require(c.manager.rows.contains{$0.path==c.source.root.path} && c.manager.backgroundService==nil,"Explicit Add did not publish owned watch status or enabled background mode")
    }
    static func publication(_ c:Context)async throws {
        let hold=c.root.appendingPathComponent("hold-status"),fail=c.root.appendingPathComponent("fail-status")
        try Data().write(to:hold);defer {c.unblock();try? FileManager.default.removeItem(at:hold);try? FileManager.default.removeItem(at:fail)}
        try await c.submit(c.source.root);c.answer(.OK)
        try await wait {FileManager.default.fileExists(atPath:c.started.path)}
        try require(c.workspace.busy && c.workspace.hasPendingFinderServiceWork && c.recent.repositories.isEmpty,"Add completed before actual first status read/publication")
        try require(c.watched.repositories.contains{$0.lastKnownPath==c.source.root.path},"Accepted watch was not persisted before owned first publication")
        c.unblock();try? FileManager.default.removeItem(at:hold)
        try await wait {!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.manager.pendingOperations==0}
        try require(c.workspace.error==nil && c.recent.repositories.contains{$0.lastKnownPath==c.source.root.path},"Successful first publication lost saved recent: \(c.workspace.error ?? "")")
        let published=FinderSnapshot.readLive(from:c.cache.url)
        try require(published?.roots.contains(c.source.root.path)==true && published?.roots.contains(c.other.root.path)==true,"Successful Add did not publish both actual repository roots")
        try Data().write(to:fail)
        try await c.submit(c.third.root);if c.permissionReply != nil {c.answer(.OK)}
        try await wait {!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.manager.pendingOperations==0}
        try require(c.workspace.error?.contains("controlled first publication failure")==true,"First collection failure was silently reported as Add success")
        try require(c.watched.repositories.contains{$0.lastKnownPath==c.third.root.path} && !c.recent.repositories.contains{$0.lastKnownPath==c.third.root.path},"Failed publication lost captured saved watch or falsely completed recent pairing")
        try require(c.workspace.root==nil && c.workspace.workspaceWindow===c.parent && c.manager.backgroundService==nil,"Headless publication adopted workspace or enabled background service")
    }
    static func ownership(_ c:Context)async throws {
        try c.block();let mutating=Task {await c.manager.add(c.other.root)};defer {c.unblock()}
        try await wait {c.manager.busy && FileManager.default.fileExists(atPath:c.started.path)}
        try await c.submit(c.source.root);c.answer(.OK)
        try await wait {c.workspace.hasPendingFinderServiceWork && c.workspace.busy && c.permissionReply==nil}
        c.workspace.confirmingQuit=true;try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.watched.repositories.count==1 && c.recent.repositories.isEmpty,"Cancelled queued registration persisted late")
        c.unblock();await mutating.value;c.workspace.confirmingQuit=false
        try c.block();try await c.submit(c.third.root);c.answer(.OK);try await wait {FileManager.default.fileExists(atPath:c.started.path) && c.manager.busy}
        c.workspace.stopMonitoringForTermination();c.unblock();try await wait {!c.workspace.hasPendingFinderServiceWork && !c.manager.busy}
        try require(c.watched.repositories.count==1 && c.recent.repositories.isEmpty,"Retired registration published or saved late")
    }
    static func main()async {
        NSApp.setActivationPolicy(.prohibited)
        if let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.registrationOrder(_:relativeTo:))) {method_exchangeImplementations(original,replacement)}
        var context:Context?
        do {let c=try Context();context=c;try await c.prepare();switch CommandLine.arguments[3] {case "publication":try await publication(c);case "registration":try await registration(c);case "clone":try await clone(c);case "ownership":try await ownership(c);case "warm":try await warmRegistration(c);case "services":try await services(c);case "launch":try await launch(c);default:throw Failure(description:"Unknown case")};try await c.cleanup();print("PASS: Finder registration \(CommandLine.arguments[3])")}
        catch {try? await context?.cleanup();fputs("Finder registration failed: \(error)\n",stderr);exit(1)}
    }
}
