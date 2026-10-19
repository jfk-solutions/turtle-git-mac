// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum MissingStagedRecoveryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:@MainActor ()->Bool)async throws {
        var settled=0
        for _ in 0..<3000 {settled=ready() ? settled+1:0;if settled==2{return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Missing-staged recovery timeout at \(line)")
    }
    static func drain()async throws {
        try await wait {MissingStagedFileRecoverySession.activeRequests==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && StatusWindowModel.activeOperations==0 && NSApp.windows.allSatisfy {$0.sheetParent==nil && $0.attachedSheet==nil && !$0.isVisible}}
    }
    @MainActor final class HeldChoice {
        var reply:CheckedContinuation<MissingStagedFileRecoverySession.Choice?,Never>?
        var entered=false
        func choose()async->MissingStagedFileRecoverySession.Choice? {entered=true;return await withCheckedContinuation{reply=$0}}
        func resume(_ choice:MissingStagedFileRecoverySession.Choice?){let pending=reply;reply=nil;pending?.resume(returning:choice)}
    }
    @MainActor final class Fixture {
        let root:URL,repository:GitRepository,preferences:UserDefaults,suite:String
        var owners:[NSWindowController]=[],holds:[HeldChoice]=[]
        var unexpectedFailures:[String]=[]
        var expected:[String:Data]=[:]
        let added="a added[*] 雪\n.txt",modified="m modified.txt",renamed="z renamed? 雪.txt"
        init(root:URL,git:URL)async throws {
            self.root=root;repository=GitRepository(root:root,executable:git)
            suite="TurtleGit.MissingStaged.QA."+UUID().uuidString;preferences=UserDefaults(suiteName:suite)!
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            _=try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Missing Staged QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false"),("tgit.commitstagingsupport","false"),("tgit.showpatch","false")] {_=try await repository.run(["config",key,value])}
            try FileManager.default.createDirectory(at:root.appendingPathComponent("scope"),withIntermediateDirectories:false)
            for path in [modified,"rename.txt","ordinary.txt","outside.txt","scope/inside.txt"] {try Data("base \(path)\r\n".utf8).write(to:root.appendingPathComponent(path))}
            _=try await repository.run(["add","--all"]);_=try await repository.run(["commit","-m","base"]);_=try await repository.run(["commit","--allow-empty","-m","second"])
            try Data("unrelated staged bytes\n".utf8).write(to:root.appendingPathComponent("outside.txt"));_=try await repository.run(["add","--","outside.txt"])
            // This ordinary, unstaged deletion must never enter the recovery list.
            try FileManager.default.removeItem(at:root.appendingPathComponent("ordinary.txt"))
            preferences.set(true,forKey:"Commit.SkipCancelConfirmation");preferences.set(true,forKey:"HintStagingMode");preferences.set(7,forKey:"NothingToCommitShowUnversioned")
        }
        func addedMissing(_ path:String? = nil)async throws {
            let path=path ?? added,data=Data("new staged \(path)\n".utf8)
            try data.write(to:root.appendingPathComponent(path));_=try await repository.run(["add","--",path]);try FileManager.default.removeItem(at:root.appendingPathComponent(path));expected[path]=data
        }
        func modifiedMissing(_ path:String? = nil)async throws {
            let path=path ?? modified,data=Data("changed staged \(path)\r\n".utf8)
            try data.write(to:root.appendingPathComponent(path));_=try await repository.run(["add","--",path]);try FileManager.default.removeItem(at:root.appendingPathComponent(path));expected[path]=data
        }
        func allMissing()async throws {
            try await addedMissing();try await modifiedMissing()
            _=try await repository.run(["mv","--","rename.txt",renamed]);expected[renamed]=try Data(contentsOf:root.appendingPathComponent(renamed));try FileManager.default.removeItem(at:root.appendingPathComponent(renamed))
        }
        func index()async throws->Data {try await repository.run(["ls-files","--stage","-z"]).stdout}
        func head()async throws->Data {try await repository.run(["rev-parse","HEAD"]).stdout}
        func close() {
            holds.forEach{$0.resume(nil)}
            for owner in owners {if let sheet=owner.window?.attachedSheet {owner.window?.endSheet(sheet,returnCode:.cancel)};owner.close()}
            preferences.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:root.appendingPathComponent(".git/index.lock"))
        }
    }
    @MainActor struct Host {
        let owner:NSWindowController,session:MissingStagedFileRecoverySession
        let commit:CommitWindowController?,status:StatusWindowController?
        let reload:@MainActor ([String]?)->Void
        let entries:@MainActor ()->[StatusEntry]
        let busy:@MainActor ()->Bool
        let error:@MainActor ()->String?
        let allowsClose:@MainActor ()->Bool
        let failures:@MainActor ()->[String]
        init(_ kind:String,_ fixture:Fixture) {
            if kind=="commit" {
                let owner=CommitWindowController(repository:fixture.repository,access:nil,defaults:fixture.preferences)
                self.owner=owner;commit=owner;status=nil;session=owner.model.missingStagedRecovery
                reload={owner.model.reload(paths:$0)};entries={owner.model.entries};busy={owner.model.busy || owner.model.savingPreferences || owner.model.loadingAmendMessage}
                error={owner.model.error};allowsClose={owner.windowShouldClose(owner.window!)}
            }else{
                let owner=StatusWindowController(repository:fixture.repository,access:nil,defaults:fixture.preferences)
                self.owner=owner;commit=nil;status=owner;session=owner.model.missingStagedRecovery
                reload={if let paths=$0 {owner.model.setScope(paths)}else{owner.model.reload()}};entries={owner.model.files.map(\.entry)};busy={owner.model.busy}
                error={owner.model.error};allowsClose={owner.windowShouldClose(owner.window!)}
            }
            failures={fixture.unexpectedFailures}
            fixture.owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owner.window?.orderFront(nil)
        }
        func ready()async throws {try await wait {!busy() && !session.busy && MissingStagedFileRecoverySession.activeRequests==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && StatusWindowModel.activeOperations==0};try require(error()==nil && failures().isEmpty,"Read failed: "+(error() ?? failures().joined(separator:"\n")))}
    }
    static func verify(caseName:String,root:URL,git:URL)async throws {
        switch caseName {
        case "commit":try await commit(root:root,git:git)
        case "status":try await status(root:root,git:git)
        case "choices":for kind in ["commit","status"] {try await choices(kind,root:root.appendingPathComponent(kind),git:git)}
        case "ownership":for kind in ["commit","status"] {try await ownership(kind,root:root.appendingPathComponent(kind),git:git)}
        default:throw Failure(description:"Unknown missing-staged case")
        }
        try await drain()
    }
    static func commit(root:URL,git:URL)async throws {
        let f=try await Fixture(root:root,git:git);defer{f.close()};try await f.allMissing()
        let host=Host("commit",f),model=host.commit!.model,initialIndex=try await f.index(),head=try await f.head()
        var prompts:[String]=[],notices=0,reads=0
        model.queryCommitStatus={amend,token in reads+=1;return try await f.repository.commitDialogStatus(amendToParent:amend,cancellation:token)}
        host.session.choose={item in prompts.append(item.path);return .init(action:.ignore,doSameForRest:false)}
        host.session.showFailure={f.unexpectedFailures.append($0)};host.session.showRefreshNotice={notices+=1}
        host.reload(nil);try await host.ready()
        try require(Set(prompts)==Set(f.expected.keys) && prompts.count==3 && notices==0,"Commit initial read missed added/modified/rename recovery or prompted an ordinary deletion")
        let ignoredIndex=try await f.index();try require(ignoredIndex==initialIndex,"Ignore mutated the Commit index")
        model.message="retained native draft";prompts=[]
        host.session.choose={item in prompts.append(item.path);return .init(action:.restoreFromIndex,doSameForRest:true)}
        let readsBefore=reads;host.reload(nil);try await host.ready()
        try require(prompts.count==1 && notices==1 && reads==readsBefore+1 && model.message=="retained native draft","Commit sticky Restore reread automatically or lost draft")
        for (path,bytes) in f.expected {try require(try Data(contentsOf:f.root.appendingPathComponent(path))==bytes,"Commit Restore did not recover exact staged bytes")}
        try require(host.entries().filter{f.expected[$0.path] != nil}.allSatisfy{$0.worktree=="D"} && host.session.refreshRequired,"Commit silently refreshed its pre-recovery snapshot")
        prompts=[];host.reload(nil);try await host.ready();try require(prompts.isEmpty && !host.session.refreshRequired,"Explicit F5 did not clear recovery notice state")
        try await f.modifiedMissing();prompts=[];host.session.choose={item in prompts.append(item.path);return .init(action:.ignore,doSameForRest:false)}
        model.amend=true;model.amendChanged();try await host.ready();try require(prompts==[f.modified] && model.amendToParent,"Amend comparison read skipped missing-stage recovery")
        prompts=[];model.amendDiffToLastCommit=true;model.comparisonChanged();try await host.ready();try require(prompts==[f.modified],"Amend diff-to-last read skipped recovery")
        prompts=[];model.setStagingEnabled(true);try await host.ready();try require(model.stagingEnabled && prompts==[f.modified],"Staging-mode preference reload skipped recovery")
        prompts=[];model.refreshStagingState();try await host.ready();try require(prompts==[f.modified],"Incremental staging-state read skipped recovery")
        _=try await f.repository.run(["checkout","--",f.modified]);try await f.modifiedMissing("scope/inside.txt")
        prompts=[];host.reload(["scope"]);try await host.ready();try require(prompts==["scope/inside.txt"] && model.scopePaths==["scope"],"Commit scoped read lost recovery or path scope")
        let finalHead=try await f.head(),outside=try await f.repository.run(["show",":outside.txt"]).stdout
        try require(finalHead==head && outside==Data("unrelated staged bytes\n".utf8),"Commit recovery changed HEAD or unrelated staged content")
        host.owner.close()
    }
    static func status(root:URL,git:URL)async throws {
        let f=try await Fixture(root:root,git:git);defer{f.close()};try await f.allMissing()
        let host=Host("status",f),index=try await f.index(),head=try await f.head()
        var prompts:[String]=[],notices=0
        host.session.choose={item in prompts.append(item.path);return .init(action:.ignore,doSameForRest:false)}
        host.session.showFailure={f.unexpectedFailures.append($0)};host.session.showRefreshNotice={notices+=1}
        host.reload(nil);try await host.ready();try require(prompts.count==3 && notices==0,"Working Tree initial read omitted missing-stage rows")
        prompts=[];host.session.choose={item in prompts.append(item.path);return .init(action:.restoreFromIndex,doSameForRest:false)}
        host.reload(nil);try await host.ready();try require(prompts.count==3 && notices==1 && host.session.refreshRequired,"Working Tree Restore choices or refresh notice differ from source")
        for (path,bytes) in f.expected {try require(try Data(contentsOf:f.root.appendingPathComponent(path))==bytes,"Working Tree Restore changed staged bytes")}
        try require(host.entries().filter{f.expected[$0.path] != nil}.allSatisfy{$0.worktree=="D"},"Working Tree automatically replaced stale rows after recovery")
        prompts=[];host.reload(nil);try await host.ready();try require(prompts.isEmpty && !host.session.refreshRequired,"Working Tree explicit refresh did not accept the new snapshot")
        try await f.modifiedMissing("scope/inside.txt");prompts=[]
        host.session.choose={item in prompts.append(item.path);return .init(action:.ignore,doSameForRest:false)}
        host.reload(["scope"]);try await host.ready();try require(prompts==["scope/inside.txt"] && host.status!.model.filter.paths==["scope"],"Working Tree scope read skipped recovery")
        let finalIndex=try await f.index(),finalHead=try await f.head()
        try require(finalIndex != Data() && finalHead==head,"Working Tree recovery damaged repository identity")
        // Only the deliberate scope staging changed the otherwise preserved index.
        _=try await f.repository.run(["reset","HEAD","--","scope/inside.txt"])
        let restoredIndex=try await f.index();try require(restoredIndex==index,"Working Tree Restore changed another index entry")
        host.owner.close()
    }
    static func choices(_ kind:String,root:URL,git:URL)async throws {
        let f=try await Fixture(root:root,git:git);defer{f.close()};try await f.allMissing()
        let host=Host(kind,f),head=try await f.head(),unrelated=try await f.repository.run(["show",":outside.txt"]).stdout
        let lock=f.root.appendingPathComponent(".git/index.lock")
        var choices=0,errors:[String]=[],notices=0,failedPath=""
        host.session.choose={item in choices+=1;failedPath=item.path;do{try Data("owned obstruction".utf8).write(to:lock,options:.withoutOverwriting)}catch{f.unexpectedFailures.append(error.localizedDescription)};return .init(action:.restoreFromIndex,doSameForRest:true)}
        host.session.showFailure={message in errors.append(message);try? FileManager.default.removeItem(at:lock)}
        host.session.showRefreshNotice={notices+=1}
        host.reload(nil);try await host.ready()
        try require(choices==1 && errors.count==1 && errors[0].contains(failedPath) && errors[0].contains("Could not lock the Git index") && notices==1,"Per-item Restore failure did not continue with the current sticky choice")
        try require(!FileManager.default.fileExists(atPath:f.root.appendingPathComponent(failedPath).path),"Failed first item was silently retried")
        for (path,bytes) in f.expected where path != failedPath {try require(try Data(contentsOf:f.root.appendingPathComponent(path))==bytes,"Sticky Restore did not continue after the failed item")}
        choices=0;host.session.choose={_ in choices+=1;return .init(action:.removeFromIndex,doSameForRest:true)}
        host.reload(nil);try await host.ready();try require(choices==1 && notices==2 && host.entries().contains{$0.path==failedPath && $0.worktree=="D"},"Next read reused sticky state or Remove silently refreshed rows")
        let indexed=try await f.repository.run(["--literal-pathspecs","ls-files","--error-unmatch","--",failedPath],successfulExitCodes:0...1)
        try require(indexed.exitCode==1,"Remove from index retained the selected missing entry")
        try await f.addedMissing("again-a.txt");try await f.addedMissing("again-b.txt")
        choices=0;host.session.choose={_ in choices+=1;return .init(action:.ignore,doSameForRest:true)}
        let beforeIgnore=try await f.index();host.reload(nil);try await host.ready();try require(choices==1,"Ignore did not apply to the remaining items")
        choices=0;host.reload(nil);try await host.ready();try require(choices==1,"Sticky Ignore leaked into the next explicit read")
        let afterIgnore=try await f.index(),finalHead=try await f.head(),finalUnrelated=try await f.repository.run(["show",":outside.txt"]).stdout
        try require(beforeIgnore==afterIgnore && head==finalHead && unrelated==finalUnrelated,"Choice recovery mutated ignored or unrelated repository state")
        host.owner.close()
    }
    static func ownership(_ kind:String,root:URL,git:URL)async throws {
        let f=try await Fixture(root:root,git:git);defer{f.close()};try await f.addedMissing()
        let host=Host(kind,f),before=try await f.index()
        host.reload(nil);try await wait {host.session.alert?.window.sheetParent===host.owner.window}
        guard let prompt=host.session.alert else{throw Failure(description:"No actual missing-stage alert")}
        try require(prompt.buttons.map(\.title)==["Restore this file from index","Remove this file from index","Ignore"] && prompt.showsSuppressionButton,"Native recovery alert lost source choices or sticky checkbox")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Open recovery prompt lost close/Quit ownership")
        prompt.buttons[2].performClick(nil);try await host.ready()
        let ignored=try await f.index();try require(ignored==before && !FileManager.default.fileExists(atPath:f.root.appendingPathComponent(f.added).path),"Actual Ignore prompt changed disk/index")
        host.reload(nil);try await wait {host.session.alert?.window.sheetParent===host.owner.window}
        host.session.alert!.buttons[0].performClick(nil)
        try await wait {FileManager.default.fileExists(atPath:f.root.appendingPathComponent(f.added).path) && host.session.alert != nil}
        try require(host.busy() && host.session.refreshRequired,"Refresh notice released read ownership before acknowledgment")
        host.session.alert!.buttons[0].performClick(nil);try await host.ready()
        try require(host.entries().contains{$0.path==f.added && $0.worktree=="D"},"Notice acknowledgment triggered an automatic refresh")
        try FileManager.default.removeItem(at:f.root.appendingPathComponent(f.added))
        host.reload(nil);try await wait {host.session.alert?.window.sheetParent===host.owner.window}
        try require(!host.allowsClose(),"Red close accepted while recovery still owned the read")
        try await host.ready()
        try require(host.session.alert==nil && !host.session.retired && !FileManager.default.fileExists(atPath:f.root.appendingPathComponent(f.added).path),"Red close failed to cancel its owned sheet without retiring the window")
        let held=HeldChoice();f.holds.append(held);host.session.choose={_ in await held.choose()};host.session.showRefreshNotice={}
        let retained=host.entries();host.reload(nil);try await wait {held.entered && MissingStagedFileRecoverySession.activeRequests>0}
        host.session.cancel();held.resume(.init(action:.restoreFromIndex,doSameForRest:true));try await host.ready()
        try require(host.entries()==retained && !FileManager.default.fileExists(atPath:f.root.appendingPathComponent(f.added).path),"Cancelled owned choice performed a late mutation or replaced rows")
        let late=HeldChoice();f.holds.append(late);host.session.choose={_ in await late.choose()};host.reload(nil);try await wait {late.entered}
        host.owner.close()
        try require(MissingStagedFileRecoverySession.activeRequests>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close released pending chooser ownership before drain")
        late.resume(.init(action:.removeFromIndex,doSameForRest:true));try await wait {MissingStagedFileRecoverySession.activeRequests==0 && !host.busy()}
        let finalIndex=try await f.index();try require(finalIndex==before && !FileManager.default.fileExists(atPath:f.root.appendingPathComponent(f.added).path) && host.entries()==retained,"Retired stale chooser changed index/worktree/table")
    }
}
