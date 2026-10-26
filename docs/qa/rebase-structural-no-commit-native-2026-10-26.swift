// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import SwiftUI
import TurtleGitCore

@MainActor enum RebaseStructuralNoCommitVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ yes:Bool,_ text:String)throws {if !yes {throw Failure(description:text)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Structural no-commit native timeout at \(line)")
    }
    static func drain()async throws {
        try await wait {RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeReplayOperations==0 && RebaseWindowModel.activeColumnReads==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeCommitPreflights==0}
    }
    static func views(_ view:NSView)->[NSView] {
        let selector = #selector(getter:NSView.subviews)
        typealias Getter = @convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let getter=unsafeBitCast(view.method(for:selector),to:Getter.self)
        let children=getter(view,selector).takeUnretainedValue().copy() as! NSArray
        var result=[view]
        for index in 0..<children.count {let object=children.object(at:index) as AnyObject;guard let native=object as? NSObject,native.isKind(of:NSView.self) else{continue};result += views(unsafeBitCast(object,to:NSView.self))}
        return result
    }
    @MainActor final class Fixture {
        let root:URL,repo:GitRepository,editor:URL,domain:String,prefs:UserDefaults
        var owners=[RebaseWindowController](),commits=[String:LogEntry](),originalHead="",upstream=""
        init(_ name:String)throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
            repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))
            editor=URL(fileURLWithPath:CommandLine.arguments[3]);domain="TurtleGit.StructuralNoCommit."+UUID().uuidString;prefs=UserDefaults(suiteName:domain)!
            for key in ["UseLibgit2","ConfirmKillProcess","EnableGravatar","HintStagingMode"] {prefs.set(false,forKey:key)}
        }
        func commit(_ name:String)async throws {
            try Data((name+"\n").utf8).write(to:root.appendingPathComponent(name+".txt"));try await repo.stage([name+".txt"])
            _=try await repo.commit(message:name);commits[name]=try await repo.rebaseCommit("HEAD")
        }
        func seed()async throws {
            _=try await repo.run(["init","-b","main"])
            for(key,value)in [("user.name","Structural Group QA"),("user.email","structural@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("rebase.updateRefs","false"),("rebase.rescheduleFailedExec","true")] {_=try await repo.run(["config",key,value])}
            try await commit("base")
            _=try await repo.run(["switch","-c","upstream"]);try await commit("upstream");upstream=commits["upstream"]!.hash
            _=try await repo.run(["switch","-c","side","main"]);try await commit("side")
            _=try await repo.run(["switch","-c","topic","main"])
            for name in ["leader","a","b"] {try await commit(name)}
            _=try await repo.run(["merge","--no-ff","side","-m","merge"]);commits["merge"]=try await repo.rebaseCommit("HEAD")
            try await commit("descendant");originalHead=commits["descendant"]!.hash
        }
        func open()async throws->RebaseWindowController {
            let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs);owners.append(owner)
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.window?.orderFront(nil)
            owner.model.editorExecutable=editor;owner.model.load(upstream:"refs/heads/upstream",preserveMerges:true)
            try await wait {!owner.model.busy && !owner.model.loadingPlan && (owner.model.plan != nil || owner.model.active)};try await drain()
            return owner
        }
        func prepare(_ model:RebaseWindowModel)throws {
            guard let plan=model.plan else{throw Failure(description:"Missing structural plan")}
            let ordered=try ["leader","a","b","side","merge","descendant"].map {name->RebaseEntry in
                guard let value=plan.entries.first(where:{$0.commit.hash==commits[name]?.hash}) else{throw Failure(description:"Missing structural row "+name)};return value
            }
            model.plan?.entries=ordered
            model.selection=[ordered[0].id];model.setAction(.edit);model.cycleActions()
            try require(model.plan?.entries[0].action == .pick,"Oldest structural row cycled to forbidden Squash")
            model.setAction(.skip,ids:[ordered[0].id]);model.setAction(.squash,ids:[ordered[1].id,ordered[2].id]);model.setAction(.edit,ids:[ordered[5].id])
            try require(model.canStart,"Source Skip→Squash plan was blocked by first-retained Start guard")
            try require(!model.canAdd && model.plan?.entries[4].action == .pick,"Structural Add/merge action policy changed")
            model.setAction(.squash,ids:[ordered[4].id]);try require(model.plan?.entries[4].action == .pick,"Merge itself accepted Squash")
        }
        func request(_ model:RebaseWindowModel,_ action:String) {
            model.request(action);if let question=model.pendingConfirmation {model.answerConfirmation(question,proceed:true)}
        }
        func cleanup()async {
            for owner in owners {owner.model.retire();owner.close()}
            try? await drain()
            try? await wait {owners.allSatisfy{!$0.transportBatchWorkPending && $0.window?.isVisible != true && $0.window?.attachedSheet==nil}}
            if (try? await repo.rebaseState().active)==true {_=try? await repo.abortRebase()}
            prefs.removePersistentDomain(forName:domain)
        }
    }
    static func splitAndDescendants()async throws {
        let f=try Fixture("split-descendants")
        do {
            try await f.seed();let owner=try await f.open(),model=owner.model;try f.prepare(model)
            f.request(model,"start");try await wait {!model.busy && model.state?.noCommitSquash?.phase == .approval};try await drain()
            try require(model.error==nil && model.canSplit && model.state?.noCommitSquash?.baseHead==f.upstream,"Structural orphan did not reach native new-commit approval: "+(model.error ?? "none"))
            let group=model.state!.noCommitSquash!.id,index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
            let draft="Structural pending draft\n\nKeep across future edit\n";model.messageBinding(model.formContext).wrappedValue=draft
            let future=model.entries.first{$0.commit.hash==f.commits["descendant"]!.hash}!.id
            model.selection=[future]
            var table:RebaseReplayNativeTable?
            try await wait {table=views(owner.window!.contentView!).compactMap{$0 as? RebaseReplayNativeTable}.first;return table?.owner?.available==true && model.revisionMenuAvailable}
            let menu=table!.owner!.menu(ids:[future],alternate:false)
            guard let pick=menu.item(withTitle:"Pick"),pick.isEnabled,pick.image != nil else{throw Failure(description:"Structural future Pick/icon missing at group approval")}
            _=NSApp.sendAction(pick.action!,to:pick.target,from:pick)
            try await wait {!model.busy && !model.editingPendingActions};try await drain()
            let unchanged=try await f.repo.run(["ls-files","--stage","-z"]).stdout
            try require(model.error==nil && model.state?.noCommitSquash?.id==group && model.amendMessage==draft && unchanged==index && model.entries.first{$0.id==future}?.action == .pick,"Native future action changed staged group/draft/identity: "+(model.error ?? "none"))
            var children=[CommitWindowModel]();model.configureCommitSelection={child in children.append(child);child.confirmCancel={$0(true)}};model.chooseAnotherSplit={false}
            model.splitBinding(model.formContext).wrappedValue=true;model.request("continue")
            try await wait {children.count==1 && !children[0].busy && children[0].replaySplit != nil};try await drain()
            let first=children[0],firstWindow=owner.window?.attachedSheet
            try require(first.replaySplit?.isNewCommit==true && !first.amend && !first.stagingEnabled && firstWindow?.alphaValue==0,"Structural first child was not a hidden normal selected Commit")
            first.checked=["a.txt"];first.message="Structural first part";first.commit()
            try await wait {children.count==2 && !children[1].busy && children[1].replaySplit?.parts==1};try await drain()
            let firstPart=try await f.repo.rebaseCommit("HEAD")
            try require(firstPart.parents==[f.upstream] && firstPart.subject=="Structural first part" && firstWindow?.isVisible==false && firstWindow?.sheetParent==nil,"First structural part lost parent/message or child-release ownership")
            let second=children[1];second.checked=["b.txt"];second.message="Structural final part";second.commit()
            try await wait {!model.busy && model.finished};try await drain()
            let final=try await f.repo.rebaseCommit("HEAD")
            try require(final.parents.count==1,"Final structural descendant lost single parent")
            let merge=try await f.repo.rebaseCommit(final.parents[0])
            try require(model.error==nil && model.completedSuccessfully && final.subject=="descendant" && merge.parents.count==2,"Native structural completion lost descendant merge: "+(model.error ?? "none"))
            let groupTip=try await f.repo.rebaseCommit(merge.parents[0]),side=try await f.repo.rebaseCommit(merge.parents[1])
            try require(groupTip.subject=="Structural final part" && groupTip.parents==[firstPart.hash] && side.subject=="side" && side.parents==[f.upstream],"Structural labels did not map final split HEAD/side branch exactly")
            let names=try await f.repo.run(["ls-tree","--name-only","HEAD"]).text.split(separator:"\n").map(String.init)
            try require(Set(names)==Set(["base.txt","upstream.txt","a.txt","b.txt","side.txt","descendant.txt"]),"Native preserved DAG final tree lost/added payload: "+names.joined(separator:","))
            try require(owner.window?.attachedSheet==nil && children.allSatisfy{!$0.attemptWorkPending},"Final native Split child/sheet/work survived completion")
            await f.cleanup()
        }catch{await f.cleanup();throw error}
    }
    static func cancelReopenAbort()async throws {
        let f=try Fixture("cancel-reopen-abort")
        do {
            try await f.seed();let owner=try await f.open(),model=owner.model;try f.prepare(model)
            f.request(model,"start");try await wait {!model.busy && model.state?.noCommitSquash?.phase == .approval};try await drain()
            let original=model.state!.noCommitSquash!.id,index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
            var child:CommitWindowModel?;model.configureCommitSelection={child=$0;$0.confirmCancel={$0(true)}}
            model.splitBinding(model.formContext).wrappedValue=true;model.request("continue")
            try await wait {child?.replaySplit != nil && child?.busy==false};try await drain();child!.cancel()
            try await wait {!model.busy && !model.selectingSplit};try await drain()
            try require(model.state?.split==nil && model.splitCommit && model.state?.noCommitSquash?.id==original,"Unstarted structural Split Cancel lost durable approval/choice")
            owner.close();try await drain();let reopened=try await f.open(),next=reopened.model
            let fresh=try await f.repo.run(["ls-files","--stage","-z"]).stdout
            try require(next.state?.noCommitSquash?.id==original && fresh==index && next.canSplit,"Reopening structural approval changed accumulator/identity")
            f.request(next,"abort");try await wait {!next.busy && !next.active};try await drain()
            let head=try await f.repo.rebaseCommit("HEAD"),branch=try await f.repo.run(["symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines)
            try require(head.hash==f.originalHead && branch=="refs/heads/topic" && reopened.window?.attachedSheet==nil,"Structural Abort did not restore original branch/topology")
            await f.cleanup()
        }catch{await f.cleanup();throw error}
    }
    static func verify()async throws {
        try await splitAndDescendants();try await cancelReopenAbort()
        print("PASS: native structural Skip→Squash Start, future action menu/icon and draft/index receipt, actual normal Split children/release, exact descendant DAG/tree, Cancel/reopen/Abort; owned windows and workers drained")
    }
}
