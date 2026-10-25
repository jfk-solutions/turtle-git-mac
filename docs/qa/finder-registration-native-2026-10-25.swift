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
            manager=FinderWatchManager(permissions:watched,cache:nil,requireScope:true,scopeProvider:provider,repositoryFactory:{GitRepository(root:$0,executable:wrapper,libgit2Configuration:.init(enabled:false))},notify:{})
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
            await manager.add(other.root);try await FinderRegistrationVerification.wait {manager.pendingOperations==0}
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
            manager.retire();parent.close()
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
        do {let c=try Context();context=c;try await c.prepare();switch CommandLine.arguments[3] {case "registration":try await registration(c);case "clone":try await clone(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown case")};try await c.cleanup();print("PASS: Finder registration \(CommandLine.arguments[3])")}
        catch {try? await context?.cleanup();fputs("Finder registration failed: \(error)\n",stderr);exit(1)}
    }
}
