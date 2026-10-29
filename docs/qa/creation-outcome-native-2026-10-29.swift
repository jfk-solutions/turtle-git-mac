// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func creationQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));creationQAOrder(mode,relativeTo:number)}
}
@MainActor @main enum CreationOutcomeVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Creation outcome \(line): "+message)}}
    static func wait(_ name:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Creation timeout: "+name)}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func sameItem(_ first:URL?,_ second:URL)->Bool {
        guard let first else{return false};var a=stat(),b=stat()
        return lstat(first.path,&a)==0 && lstat(second.path,&b)==0 && a.st_dev==b.st_dev && a.st_ino==b.st_ino
    }
    @MainActor final class Context {
        let suite="TurtleGit.CreationOutcome.QA."+UUID().uuidString,prefs:UserDefaults,folder:URL,git=URL(fileURLWithPath:CommandLine.arguments[2])
        var root:URL{folder.appendingPathComponent("repository")}
        var repo:GitRepository{GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(mask:0))}
        var branches:[BranchTagWindowController]=[],worktrees:[WorktreeCreateWindowController]=[],releases:[()->Void]=[],pids:[Int32]=[]
        var head="",index=Data(),working=Data()
        init(_ name:String)throws {
            prefs=UserDefaults(suiteName:suite)!;folder=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoClose")
        }
        func hash(_ revision:String)async throws->String{try await repo.run(["rev-parse","--verify",revision]).text.trimmingCharacters(in:.whitespacesAndNewlines)}
        func prepare()async throws {
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Creation QA"),("user.email","creation@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repo.run(["config",key,value])}
            try Data("[submodule \"optional\"]\n path = optional\n url = ../never-contacted\n".utf8).write(to:root.appendingPathComponent(".gitmodules"))
            try Data("base\n".utf8).write(to:root.appendingPathComponent("tracked.txt"));try Data("unrelated base\n".utf8).write(to:root.appendingPathComponent("unrelated.txt"));try await repo.stage(["."]);_=try await repo.commit(message:"private seed")
            head=try await hash("HEAD");try Data("unrelated staged\n".utf8).write(to:root.appendingPathComponent("unrelated.txt"));try await repo.stage(["unrelated.txt"])
            working=Data("unstaged user bytes\n".utf8);try working.write(to:root.appendingPathComponent("tracked.txt"));index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        }
        func branch(_ name:String,tag:Bool=false,repository:GitRepository?=nil)async throws->BranchTagWindowController {
            let owner=BranchTagWindowController(repository:repository ?? repo,access:nil,isTag:tag,preferences:prefs);branches.append(owner);owner.window?.alphaValue=0;owner.showWindow(nil);owner.model.load(revision:"HEAD",name:name)
            try await wait("branch/tag initial read"){!owner.model.busy && !owner.model.hasPendingWork && !owner.model.chooser.busy}
            try require(owner.model.error==nil,"Branch initial read failed: "+(owner.model.error ?? ""))
            owner.model.options.name=name;owner.model.useHead=true;owner.model.switchAfterCreation=false;owner.model.pushAfterCreation=false
            return owner
        }
        func worktree(_ name:String,repository:GitRepository?=nil)async throws->WorktreeCreateWindowController {
            let owner=WorktreeCreateWindowController(repository:repository ?? repo,access:nil,preferences:prefs,initialDirectory:folder.appendingPathComponent(name));worktrees.append(owner);owner.window?.alphaValue=0;owner.showWindow(nil);owner.model.load()
            try await wait("worktree initial read"){!owner.model.busy && !owner.model.chooser.busy}
            owner.model.requiresSecurityScope=false;owner.model.detach=true;owner.model.createBranch=false;return owner
        }
        func unchanged()async throws {
            let now=try await hash("HEAD"),after=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:root.appendingPathComponent("tracked.txt"))
            try require(now==head && after==index && bytes==working,"Creation changed original HEAD/index/working bytes")
        }
        func clean()async throws {
            releases.forEach{$0()};releases=[];branches.forEach{$0.close()};worktrees.forEach{$0.close()}
            try await wait("owned creation/read/child drain"){BranchTagWindowModel.activeReads==0 && BranchTagWindowModel.activeCreations==0 && BranchTagWindowController.activeReleases==0 && WorktreeCreateWindowModel.activeOperations==0 && SwitchWindowModel.activeReads==0 && LocalGitCommandProgress.activeOperations==0 && branches.allSatisfy{!$0.hasPendingWork} && worktrees.allSatisfy{!$0.finderServiceWorkPending} && pids.allSatisfy{kill($0,0) != 0}}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func reference(_ c:Context,tag:Bool)async throws {
        let name=tag ? "accepted-tag":"accepted-branch",owner=try await c.branch(name,tag:tag),model=owner.model
        var mutations=0,notifications=0,switches=0,pushes=0
        model.onCreated={_ in notifications += 1};model.onSwitch={_,done in switches += 1;done()};model.onPushTag={_ in pushes += 1}
        model.switchAfterCreation = !tag;model.pushAfterCreation=tag
        if tag{model.options.message="Original annotated tag message"}
        let repo=c.repo
        model.performReferenceAccepted={plan,token in mutations += 1;let receipt=try await repo.createReferenceAccepted(plan,cancellation:token);token.cancel();return receipt}
        model.create();try await wait("accepted reference canceled return drain"){!model.hasPendingWork && !model.busy}
        let ref=(tag ? "refs/tags/":"refs/heads/")+name,object=try await c.hash(ref),peeled=try await c.hash(ref+"^{commit}")
        try require(peeled==c.head && model.acceptedCreation?.actualObjectID==object && model.acceptedCreation?.reference==ref && model.acceptedCreation?.verified==true,"Actual accepted reference identity lost after late cancellation")
        try require(mutations==1 && notifications==1 && switches==0 && pushes==0,"Accepted late Cancel recreated/notified twice or started optional child")
        // An explicit subsequent action may resume post-creation work, but must
        // never rerun the already accepted branch/tag command.
        model.error=nil;model.create();try await wait("explicit reference continuation drain"){!owner.hasPendingWork && !model.hasPendingWork && !model.busy}
        let after=try await c.hash(ref)
        try require(after==object && mutations==1 && notifications==1,"Explicit reference continuation recreated or renotified accepted mutation")
        try require(switches==(tag ? 0:1) && pushes==(tag ? 1:0),"Explicit verified continuation failed to hand off its captured optional phase once")
        owner.close();try await c.unchanged()
    }
    static func referenceRetirement(_ c:Context)async throws {
        let owner=try await c.branch("closed-reference"),model=owner.model,repo=c.repo
        var held:CheckedContinuation<String,Never>?,release:(()->Void)?,notifications=0,children=0
        model.onCreated={_ in notifications += 1};model.onSwitch={_,done in children += 1;done()};model.switchAfterCreation=true
        model.performReferenceAccepted={plan,token in
            let receipt=try await repo.createReferenceAccepted(plan,cancellation:token)
            _=await withCheckedContinuation{(continuation:CheckedContinuation<String,Never>) in held=continuation;release={held?.resume(returning:"");held=nil}}
            return receipt
        }
        c.releases.append{release?();release=nil}
        model.create();try await wait("real reference receipt held"){held != nil}
        let before=try await c.hash("refs/heads/closed-reference")
        try require(before==c.head && model.hasPendingWork,"Held accepted mutation lost actual ref or worker ownership")
        let delegate=TurtleGitApplicationDelegate()
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit admitted actual held creation worker")
        owner.close();try require(model.hasPendingWork,"Close discarded held actual creation worker")
        release?();release=nil;try await wait("closed reference actual drain"){!owner.hasPendingWork && !model.hasPendingWork}
        try require(model.acceptedCreation?.actualObjectID==before && notifications==1 && children==0,"Closed owner lost accepted mutation or presented a late child")
        model.create();try require(notifications==1 && children==0,"Retired creation owner revived")
        try await c.unchanged()
    }
    static func referenceQuestion(_ c:Context,approve:Bool)async throws {
        c.prefs.set(true,forKey:"ConfirmKillProcess");defer{c.prefs.set(false,forKey:"ConfirmKillProcess")}
        let owner=try await c.branch(approve ? "question-yes":"question-no"),model=owner.model,repo=c.repo
        var held:CheckedContinuation<Void,Never>?,answer:((Bool)->Void)?,notifications=0,children=0
        model.onCreated={_ in notifications += 1};model.onSwitch={_,done in children += 1;done()};model.switchAfterCreation=true
        model.confirmCancellation={answer=$0}
        model.performReferenceAccepted={plan,token in
            let receipt=try await repo.createReferenceAccepted(plan,cancellation:token)
            await withCheckedContinuation{held=$0};return receipt
        }
        c.releases.append{held?.resume();held=nil;answer?(true);answer=nil}
        model.create();try await wait("actual reference complete before pending Cancel question"){held != nil}
        model.cancel();try await wait("owned Cancel question admitted"){answer != nil && model.confirmingCancellation}
        held?.resume();held=nil
        try await wait("accepted receipt waiting for current Cancel answer"){model.acceptedCreation != nil}
        try require(notifications==1 && children==0 && model.hasPendingWork && model.confirmingCancellation,"Pending Cancel answer allowed optional continuation or discarded actual work")
        answer?(approve);answer=nil
        try await wait("question answer and accepted creation drain"){!owner.hasPendingWork && !model.hasPendingWork}
        try require(notifications==1 && children==(approve ? 0:1),"Accepted Cancel answer replayed mutation or wrong optional continuation")
        owner.close();try await c.unchanged()
    }
    static func referenceRefusal(_ c:Context)async throws {
        let owner=try await c.branch("pre-cancel"),model=owner.model,repo=c.repo
        var notifications=0;model.onCreated={_ in notifications += 1}
        model.performReferenceAccepted={plan,token in token.cancel();return try await repo.createReferenceAccepted(plan,cancellation:token)}
        model.create();try await wait("precommand cancellation drain"){!model.busy && !model.hasPendingWork}
        let absent=try await repo.run(["show-ref","--verify","--quiet","refs/heads/pre-cancel"],successfulExitCodes:0...1)
        try require(absent.exitCode==1 && model.acceptedCreation==nil && model.createdBranch==nil && notifications==0,"Precommand cancellation falsely adopted reference")
        owner.close()
        let failed=try await c.branch("raced-existing"),failure=failed.model
        failure.onCreated={_ in notifications += 1}
        failure.performReferenceAccepted={plan,token in
            _=try await repo.run(["branch",plan.options.name,"HEAD"])
            return try await repo.createReferenceAccepted(plan,cancellation:token)
        }
        failure.create();try await wait("actual nonzero creation drain"){!failure.busy && !failure.hasPendingWork}
        let current=try await c.hash("refs/heads/raced-existing")
        try require(current==c.head && failure.acceptedCreation==nil && failure.createdBranch==nil && failure.error != nil && notifications==0,"Failed Git command claimed external reference creation")
        failed.close();try await c.unchanged()
    }
    static func heldWorktreeRepository(_ c:Context,label:String,afterCreation:Bool)throws->(GitRepository,URL) {
        let wrapper=c.folder.appendingPathComponent(label+"-git"),marker=URL(fileURLWithPath:wrapper.path+".started")
        let creationCommand=afterCreation ? """
        \(quote(c.git.path)) "$@"
        task_result=$?
        if [ "$task_result" -ne 0 ]; then exit "$task_result"; fi
        """ : ":"
        let script="""
        #!/bin/sh
        task_command() {
          if [ "${1-}" = --literal-pathspecs ] || [ "${1-}" = --no-literal-pathspecs ]; then shift; fi
          if [ "${1-}" = -C ]; then shift 2; fi
          while [ "${1-}" = -c ]; do shift 2; done
          test "${1-}" = worktree && test "${2-}" = add
        }
        if task_command "$@"; then
          \(creationCommand)
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit \(afterCreation ? "0":"143")' TERM INT
          printf '%s %s\\n' "$$" "$task_child" >> "$0.started"
          wait "$task_child"
          exit \(afterCreation ? "0":"143")
        fi
        exec \(quote(c.git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        return(GitRepository(root:c.root,executable:wrapper,askpass:nil,libgit2Configuration:.init(mask:0)),marker)
    }
    static func worktree(_ c:Context,closeOwner:Bool,afterCreation:Bool)async throws {
        let label=afterCreation ? (closeOwner ? "retired-worktree":"accepted-worktree"):"precommand-worktree"
        let (repository,marker)=try heldWorktreeRepository(c,label:label,afterCreation:afterCreation)
        let owner=try await c.worktree(label,repository:repository),model=owner.model,path=URL(fileURLWithPath:model.directory)
        var notifications=0,optional=0,submodulePath:URL?;model.onCreated={_ in notifications += 1};model.onSubmodules={path,_ in optional += 1;submodulePath=path}
        model.create();try await wait("actual worktree command held"){FileManager.default.fileExists(atPath:marker.path)}
        let processes=String(decoding:try Data(contentsOf:marker),as:UTF8.self).split(whereSeparator:{$0==" " || $0=="\n"}).compactMap{Int32($0)}
        try require(processes.count==2,"Owned worktree wrapper/sleep identities missing");c.pids += processes
        if afterCreation {
            let created=GitRepository(root:path,executable:c.git,askpass:nil,libgit2Configuration:.init(mask:0))
            let actual=try await created.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
            try require(actual==c.head && model.busy,"Wrapper gate did not follow actual successful worktree creation")
        }else{try require(!FileManager.default.fileExists(atPath:path.path),"Precommand gate mutated worktree")}
        let delegate=TurtleGitApplicationDelegate()
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit admitted actual held worktree command")
        if closeOwner{owner.close()}else{model.cancel()}
        try await wait("worktree accepted/canceled command and helpers drain"){!model.busy && WorktreeCreateWindowModel.activeOperations==0 && processes.allSatisfy{kill($0,0) != 0}}
        if afterCreation {
            try require(model.acceptedCreation?.verified==true && model.acceptedCreation?.worktree?.head==c.head && sameItem(model.acceptedCreation?.path,path) && notifications==1 && optional==0,"Actual created worktree lost accepted identity/refresh or launched optional child: receipt=\(String(describing:model.acceptedCreation)) expected=\(path.path) notices=\(notifications) optional=\(optional) active=\(model.active) output=\(String(reflecting:String(model.output.suffix(1600))))")
            let count=try await c.repo.worktrees().filter{sameItem($0.path,path)}.count
            try require(count==1,"Actual accepted worktree registration absent/duplicated")
            if !closeOwner {
                try require(model.success && !model.cancelled && model.percentage==100 && model.completionRange != nil,"Accepted worktree displayed false failure/cancellation")
                model.returnToOptions();model.create();await Task.yield()
                let invocations=String(decoding:try Data(contentsOf:marker),as:UTF8.self).split(separator:"\n").count
                try require(invocations==1 && notifications==1 && optional==0,"Return-to-options recreated already accepted worktree")
                try require(FileManager.default.fileExists(atPath:path.appendingPathComponent(".gitmodules").path) && model.canUpdateSubmodules,"Verified created worktree lost explicit Submodule action")
                model.updateSubmodules();try await wait("explicit Submodule handoff after owner drain"){optional==1 && !owner.finderServiceWorkPending}
                try require(sameItem(submodulePath,path) && notifications==1,"Explicit Submodule continuation targeted wrong worktree or repeated parent refresh")
            }
        }else{try require(model.acceptedCreation==nil && !model.success && notifications==0 && optional==0 && !FileManager.default.fileExists(atPath:path.path),"Precommand canceled worktree falsely adopted")}
        owner.close();try await c.unchanged()
    }
    static func worktreeFailure(_ c:Context)async throws {
        let owner=try await c.worktree("occupied-worktree"),model=owner.model,path=URL(fileURLWithPath:model.directory)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        let existing=path.appendingPathComponent("keep.txt"),bytes=Data("existing destination bytes\n".utf8);try bytes.write(to:existing)
        var notifications=0;model.onCreated={_ in notifications += 1}
        model.create();try await wait("actual nonzero worktree command drain"){!model.busy && WorktreeCreateWindowModel.activeOperations==0}
        let rows=try await c.repo.worktrees(),saved=try Data(contentsOf:existing)
        try require(model.acceptedCreation==nil && !model.success && notifications==0 && saved==bytes && !rows.contains{sameItem($0.path,path)},"Failed worktree command falsely adopted/mutated existing destination")
        owner.close();try await c.unchanged()
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let a=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let b=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.creationQAOrder(_:relativeTo:))){method_exchangeImplementations(a,b)}
        do {
            for name in ["reference","worktree"] {
                let c=try Context(name)
                do{try await c.prepare();if name=="reference"{try await reference(c,tag:false);try await reference(c,tag:true);try await referenceRetirement(c);try await referenceQuestion(c,approve:true);try await referenceQuestion(c,approve:false);try await referenceRefusal(c)}else{try await worktree(c,closeOwner:false,afterCreation:true);try await worktree(c,closeOwner:true,afterCreation:true);try await worktree(c,closeOwner:false,afterCreation:false);try await worktreeFailure(c)};try await c.clean()}
                catch{try? await c.clean();throw error}
            }
            print("PASS native creation outcomes: actual reference/worktree mutation identities, late cancellation/retirement adoption, parent refresh once, optional child gates, no recreation, precommand/nonzero refusal and owned helper drain")
        }catch{fputs("Native creation outcome failed: \(error)\n",stderr);exit(1)}
    }
}
