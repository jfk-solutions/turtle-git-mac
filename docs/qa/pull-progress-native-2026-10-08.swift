import AppKit
import ObjectiveC
import TurtleGitCore

@main struct PullProgressVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func settled(_ value:()->Bool,line:Int = #line)async throws {
        for _ in 0..<3000 {if value(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Pull result close timed out at \(line)")
    }
    @MainActor static func views(_ view:NSView)->[NSView] {
        let selector=NSSelectorFromString("subviews")
        typealias Getter = @convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let children=unsafeBitCast(view.method(for:selector),to:Getter.self)(view,selector).takeUnretainedValue().copy() as! NSArray
        var result=[view]
        for index in 0..<children.count {if let child=children.object(at:index) as? NSView {result += views(child)}}
        return result
    }
    /// Each attempt runs an actual conflicting Pull. Answers never manufacture
    /// command success or conflict state; the native owner retains every reply.
    @MainActor static func resultClosing(repository:GitRepository,options:PullOptions,preferences:UserDefaults)async throws {
        preferences.set(0,forKey:"AutoCloseGitProgress")
        preferences.set(true,forKey:MergeProgressWindowModel.conflictHintPreference)
        var owners=[PullProgressWindowController](),outerOwners=[FetchWindowController](),held:CheckedContinuation<Bool,Never>?
        var callbacks=0,closed=0,detached=false
        func drained()->Bool {PullProgressWindowModel.activeOperations==0 && FetchWindowController.activeProgressReleases==0}
        func owner(using alternate:GitRepository?=nil,eligible:Bool=true)async throws->PullProgressWindowController {
            let model=PullProgressWindowModel(repository:alternate ?? repository,access:nil,options:options,followUp:PullFollowUp(),preferences:preferences)
            let controller=PullProgressWindowController(model:model);owners.append(controller)
            controller.window?.alphaValue=0;controller.window?.setFrameOrigin(.init(x:-24000,y:-24000));controller.window?.orderFront(nil)
            controller.onClosed={closed += 1}
            model.onPostAction={action,_ in
                callbacks += 1
                detached = action == .workingTree && controller.window?.isVisible==false && controller.window?.sheetParent==nil && controller.window?.attachedSheet==nil && drained()
            }
            await model.run()
            try await settled {drained()}
            try require(!model.success && !model.cancelled && model.postActions==[.resolve,.commit],"Actual conflict did not produce Resolve/Commit recovery")
            if eligible {try require(model.resultExitCode==1 && model.rawOutput.contains("CONFLICT"),"Actual conflict did not produce source close-question prerequisites")}
            return controller
        }
        func abort()async throws {_ = try await repository.abortMerge()}
        func cleanup()async {
            owners.forEach {$0.model.invalidate();$0.close();$0.model.onPostAction=nil;$0.model.presentSeeChanges=nil;$0.onClosed={}}
            outerOwners.forEach {$0.model.invalidate();$0.close();$0.model.onPullPostAction=nil}
            let answer=held;held=nil;answer?.resume(returning:false)
            try? await settled {drained() && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil} && outerOwners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil}}
            if (try? await repository.run(["rev-parse","--verify","MERGE_HEAD"])) != nil {_ = try? await repository.abortMerge()}
        }
        do {
            // No is a successful normal close, retaining exact conflict bytes.
            let no=try await owner(),head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try await repository.run(["ls-files","--stage"]).stdout
            var questions=0
            no.model.presentSeeChanges={questions += 1;return await withCheckedContinuation{held=$0}}
            no.model.requestClose();try await settled {held != nil && no.model.confirmingResultClose}
            no.model.requestClose();no.model.perform(.resolve)
            try require(questions==1 && callbacks==0 && no.window?.isVisible==true,"Held result question admitted duplicate close/post-action")
            let first=held;held=nil;first?.resume(returning:false)
            try await settled {closed==1 && !no.model.confirmingResultClose && drained()}
            let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repository.run(["ls-files","--stage"]).stdout
            try require(callbacks==0 && afterHead==head && afterIndex==index,"No dispatched Working Tree or altered stopped conflict")
            try await abort()

            // Yes dispatches once, after the actual native window release.
            let yes=try await owner();yes.model.presentSeeChanges={true}
            yes.model.requestClose();yes.model.requestClose()
            try await settled {callbacks==1 && closed==2 && drained()}
            try require(detached,"Working Tree handoff preceded native owner/sheet release")
            try await abort()

            // Cancel and the title-bar close use source IDCANCEL, never IDOK.
            let cancel=try await owner();cancel.model.presentSeeChanges={throwingQuestion();return true}
            cancel.model.requestClose(accepted:false);try await settled {closed==3 && drained()}
            try require(callbacks==1,"Cancel dispatched Working Tree")
            try await abort()
            let title=try await owner();title.model.presentSeeChanges={throwingQuestion();return true}
            title.window?.performClose(nil);try await settled {closed==4 && drained()}
            try require(callbacks==1,"Title-bar Cancel dispatched Working Tree")
            try await abort()

            // Explicit recovery buttons consume their own action, not Close.
            let action=try await owner();var resolves=0
            action.model.presentSeeChanges={throwingQuestion();return true}
            action.model.onPostAction={value,_ in resolves += 1;precondition(value == .resolve)}
            action.model.perform(.resolve);action.model.perform(.commit)
            try await settled {closed==5 && drained()}
            try require(resolves==1 && callbacks==1,"Recovery action repeated or became normal-close question")
            try await abort()

            // A forced owner retirement invalidates an outstanding accepted Yes.
            let retired=try await owner();retired.model.presentSeeChanges={await withCheckedContinuation{held=$0}}
            retired.model.requestClose();try await settled {held != nil}
            retired.close();let late=held;held=nil;late?.resume(returning:true)
            try await settled {closed==6 && drained() && !retired.model.confirmingResultClose}
            try require(callbacks==1 && retired.window?.isVisible==false,"Late result answer escaped retired owner")
            try await abort()

            // Deferred Quit/presentation ownership cannot start a result prompt.
            let blocked=try await owner();var blockedQuestions=0
            blocked.model.presentSeeChanges={blockedQuestions += 1;return false}
            blocked.model.confirmingQuit=true;blocked.model.requestClose()
            blocked.model.confirmingQuit=false;blocked.model.presentationAvailable={false};blocked.model.requestClose()
            try require(blockedQuestions==0 && blocked.window?.isVisible==true,"Unavailable/Quit owner admitted normal close")
            blocked.model.presentationAvailable={true};blocked.model.presentSeeChanges={await withCheckedContinuation{held=$0}}
            blocked.model.requestClose();try await settled {held != nil}
            blocked.model.presentationAvailable={false};let stale=held;held=nil;stale?.resume(returning:true)
            try await settled {!blocked.model.confirmingResultClose && drained()}
            try require(callbacks==1 && blocked.window?.isVisible==true,"Answer outlived current presentation authority")
            blocked.model.presentationAvailable={true};blocked.model.requestClose(accepted:false)
            try await settled {closed==7 && drained()};try await abort()

            // Actual production NSAlert: public controls, default answer, native
            // target/action and real sheet detachment (no synthetic UI events).
            let actual=try await owner();actual.model.requestClose()
            try await settled {actual.questionWindow != nil && actual.window?.attachedSheet != nil}
            guard let sheet=actual.questionWindow,let content=sheet.contentView else{throw Failure(description:"Actual See changes sheet missing")}
            let buttons=views(content).compactMap{$0 as? NSButton}.filter{!$0.isHiddenOrHasHiddenAncestor && !$0.title.isEmpty}
            let text=views(content).compactMap{$0 as? NSTextField}.map(\.stringValue).joined(separator:"\n")
            guard let yes=buttons.first(where:{$0.title=="Yes"}),let no=buttons.first(where:{$0.title=="No"}),let selector=no.action else{throw Failure(description:"Actual result Yes/No controls missing")}
            try require(buttons.count==2 && sheet.defaultButtonCell===yes.cell && sheet.alphaValue==0 && text.contains("Do you want to see changes?"),"Actual source question text/default/owned appearance changed")
            try require(NSApp.sendAction(selector,to:no.target,from:no),"Actual native result No action not dispatched")
            try await settled {closed==8 && drained() && actual.window?.attachedSheet==nil && !sheet.isVisible}
            try require(callbacks==1,"Native No dispatched Working Tree")
            try await abort()

            // Real Pull still creates a conflict; only its returned marker or
            // status is changed by the private executable, independently proving
            // both source gates rather than deriving them from postActions.
            func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            for (number,stripMarker) in [(9,true),(10,false)] {
                let wrapper=repository.root.appendingPathComponent(".git/result-close-"+String(number))
                let git=quote(CommandLine.arguments[2])
                let publication=stripMarker ? "sed 's/CONFLICT/merge issue/g' \"$capture\" >&2\nexit \"$status\"" : "cat \"$capture\" >&2\nexit 7"
                let script="#!/bin/sh\nis_pull=0\nfor arg in \"$@\"; do [ \"$arg\" = pull ] && is_pull=1; done\nif [ \"$is_pull\" = 1 ]; then\ncapture=$(mktemp) || exit 98\ntrap 'rm -f \"$capture\"' EXIT\n"+git+" \"$@\" >\"$capture\" 2>&1\nstatus=$?\n"+publication+"\nfi\nexec "+git+" \"$@\"\n"
                try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
                let alternate=GitRepository(root:repository.root,executable:wrapper,libgit2Configuration:.init(enabled:false))
                let gated=try await owner(using:alternate,eligible:false)
                gated.model.presentSeeChanges={throwingQuestion();return true}
                try require(stripMarker ? gated.model.resultExitCode==1 && !gated.model.rawOutput.contains("CONFLICT") : gated.model.resultExitCode==7 && gated.model.rawOutput.contains("CONFLICT"),"Private result gate did not preserve intended real command evidence")
                gated.model.requestClose();try await settled {closed==number && drained()}
                try require(callbacks==1,"Nonmatching source status/output dispatched Working Tree")
                try await abort();try FileManager.default.removeItem(at:wrapper)
            }
            let outer=FetchWindowController(repository:repository,access:nil,isPull:true,preferences:preferences);outerOwners.append(outer)
            outer.window?.alphaValue=0;outer.window?.setFrameOrigin(.init(x:-24000,y:-24000));outer.window?.orderFront(nil);outer.model.load()
            try await settled {!outer.model.busy && FetchWindowModel.activePreparationReads==0}
            outer.model.options.remote=options.fetch.remote;outer.model.options.branch=options.fetch.branch;outer.model.fastForwardOnly=false
            var outerCallbacks=0,outerDetached=false
            outer.model.onPullPostAction={action,_ in
                outerCallbacks += 1
                outerDetached=action == .workingTree && outer.model.closed && outer.window?.isVisible==false && outer.window?.attachedSheet==nil && drained()
            }
            outer.model.fetch();try await settled {outer.progressController?.model.busy==false && drained()}
            guard let progress=outer.progressController else{throw Failure(description:"Actual Pull options lost retained result")}
            try require(progress.window?.sheetParent===outer.window && progress.window?.alphaValue==0 && progress.model.resultExitCode==1,"Actual Pull options/result ownership changed")
            progress.model.presentSeeChanges={true};progress.model.requestClose();progress.model.requestClose()
            try await settled {outerCallbacks==1 && outer.model.closed && drained()}
            try require(outerDetached,"Working Tree escaped before actual outer options/progress sheets drained")
            try await abort()
            await cleanup()
            print("Pull result close: genuine conflict status/output; owned No/Yes, Cancel/title close, recovery actions, duplicate/late/retired answers, Quit/presentation gates and actual offscreen See changes sheet/default/detach")
        } catch {await cleanup();throw error}
    }
    static func throwingQuestion(){preconditionFailure("Cancel/post-action unexpectedly asked See changes")}
    @MainActor static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Pull progress timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let producerRoot = root.appendingPathComponent("producer"), clientRoot = root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at: producerRoot, withIntermediateDirectories: true)
        let producer = GitRepository(root: producerRoot, executable: git)
        _ = try await producer.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Pull QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "base")
        _ = try await producer.run(["clone", producerRoot.path, clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git)
        for (key,value) in [("user.name","Pull QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("pull.rebase","false")] { _ = try await repo.run(["config",key,value]) }
        let suite = "TurtleGit.PullProgress.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); preferences.synchronize() }
        let old = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("next\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "next")
        let next = try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        let owner = FetchWindowModel(repository: repo, access: nil, isPull: true, preferences: preferences)
        owner.load(); try await waitUntil { !owner.busy }
        owner.followUp = PullFollowUp(showPush: true, showStashPop: true); owner.fastForwardOnly = true
        var closes = 0, completions = 0, changes = 0, actions: [PullPostAction] = [], context: PullProgressContext?
        owner.close = { closes += 1 }; owner.onFetched = { _ in completions += 1 }; owner.onChanged = { _ in changes += 1 }
        owner.onPullPostAction = { action, result in actions.append(action); context = result }
        owner.fetch(); let retained = owner.progress!; owner.finish(retained); owner.fetch()
        owner.options.remote = "missing"; owner.followUp = PullFollowUp()
        try await waitUntil { !owner.busy }
        precondition(owner.progress === retained && closes == 0 && owner.operationActive && retained.success && completions == 1 && changes == 1)
        precondition(retained.options.fetch.remote == "origin" && retained.options.fastForwardOnly && retained.followUp.showPush && retained.followUp.showStashPop)
        precondition(retained.oldHead == old && retained.newHead == next && retained.postActions == [.stashPop,.diff,.log,.push])
        owner.fetch(); precondition(owner.progress === retained && !owner.busy)
        retained.perform(.diff); retained.perform(.log)
        precondition(actions == [.diff] && context?.oldHead == old && context?.newHead == next && closes == 1 && owner.progress == nil)
        var options = PullOptions(); options.fetch.remote = "origin"; options.fetch.branch = "main"
        let unchanged = PullProgressWindowModel(repository: repo, access: nil, options: options, followUp: PullFollowUp(), preferences: preferences)
        await unchanged.run(); precondition(unchanged.success && unchanged.oldHead == unchanged.newHead && unchanged.postActions == [.diff,.log])
        var successfulClose=0
        unchanged.close={successfulClose += 1};unchanged.presentSeeChanges={throwingQuestion();return true};unchanged.requestClose()
        precondition(successfulClose==1 && unchanged.resultExitCode==0)
        // Source Pull still offers Diff/Log when No Commit retains an unfinished merge.
        try Data("remote addition\n".utf8).write(to: producerRoot.appendingPathComponent("added")); try await producer.stage(["added"]); _ = try await producer.commit(message: "addition")
        var pending = options; pending.noCommit = true; pending.noFastForward = true
        let noCommit = PullProgressWindowModel(repository: repo, access: nil, options: pending, followUp: PullFollowUp(), preferences: preferences)
        await noCommit.run(); precondition(noCommit.success && noCommit.oldHead == noCommit.newHead && noCommit.postActions == [.diff,.log])
        _ = try await repo.run(["rev-parse","--verify","MERGE_HEAD"]); _ = try await repo.abortMerge()
        // Divergence creates a conflict; the hint blocks completion and source returns only Resolve/Commit.
        try Data("ours\n".utf8).write(to: clientRoot.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "ours")
        try Data("theirs\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "theirs")
        let conflict = PullProgressWindowModel(repository: repo, access: nil, options: options, followUp: PullFollowUp(showPush: true, showStashPop: true), preferences: preferences)
        var acknowledgement: CheckedContinuation<Bool,Never>?, hints = 0, finished = 0
        conflict.presentConflictHint = { hints += 1; return await withCheckedContinuation { acknowledgement = $0 } }; conflict.onCompleted = { finished += 1 }
        let operation = Task { await conflict.run() }
        try await waitUntil { conflict.confirmingConflictHint && acknowledgement != nil }
        precondition(conflict.busy && finished == 0 && conflict.postActions.isEmpty && !conflict.canCancel)
        conflict.cancel(); conflict.perform(.resolve); acknowledgement?.resume(returning: true); await operation.value
        precondition(!conflict.success && !conflict.cancelled && hints == 1 && finished == 1 && conflict.postActions == [.resolve,.commit])
        precondition(preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference))
        _ = try await repo.abortMerge()
        let suppressed = PullProgressWindowModel(repository: repo, access: nil, options: options, followUp: PullFollowUp(), preferences: preferences)
        suppressed.presentConflictHint = { preconditionFailure("Saved shared hint preference ignored") }; await suppressed.run()
        precondition(suppressed.postActions == [.resolve,.commit]); _ = try await repo.abortMerge()
        try await resultClosing(repository:repo,options:options,preferences:preferences)
        var ffOnly = options; ffOnly.fastForwardOnly = true
        let failure = PullProgressWindowModel(repository: repo, access: nil, options: ffOnly, followUp: PullFollowUp(), preferences: preferences)
        var reset: PullProgressContext?, resetClosed = 0
        failure.close = { resetClosed += 1 }; failure.onPostAction = { action, result in precondition(action == .reset); reset = result }
        await failure.run(); precondition(!failure.success && failure.postActions == [.pull,.stash,.reset])
        let beforeReset = try await repo.run(["rev-parse","HEAD"]).stdout
        failure.perform(.reset); failure.perform(.reset); try await waitUntil { !failure.dispatchingAction }
        let afterReset = try await repo.run(["rev-parse","HEAD"]).stdout
        precondition(reset?.resetRevision == "refs/remotes/origin/main" && resetClosed == 1 && beforeReset == afterReset)
        // Named unrelated remote offers an explicit retry; arbitrary URL does not.
        let otherRoot = root.appendingPathComponent("independent"); try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = GitRepository(root: otherRoot, executable: git); _ = try await other.run(["init","-b","main"])
        for (key,value) in [("user.name","Pull QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await other.run(["config",key,value]) }
        try Data("independent\n".utf8).write(to: otherRoot.appendingPathComponent("independent")); try await other.stage(["independent"]); _ = try await other.commit(message: "independent")
        _ = try await repo.run(["remote","add","other",otherRoot.path])
        var unrelated = options; unrelated.fetch.remote = "other"
        let retry = PullProgressWindowModel(repository: repo, access: nil, options: unrelated, followUp: PullFollowUp(showPush: true, showStashPop: true), preferences: preferences)
        await retry.run(); precondition(retry.postActions == [.mergeUnrelated,.pull,.stash,.reset] && !retry.success)
        retry.perform(.mergeUnrelated); retry.perform(.mergeUnrelated); try await waitUntil { !retry.busy }
        let parents = try await repo.run(["rev-list","--parents","-n","1","HEAD"]).text.split(whereSeparator: { $0.isWhitespace })
        precondition(retry.success && parents.count == 3 && !retry.options.allowUnrelatedHistories && retry.postActions == [.stashPop,.diff,.log,.push])
        var missing = options; missing.fetch.branch = "missing"
        let missingRef = PullProgressWindowModel(repository: repo, access: nil, options: missing, followUp: PullFollowUp(), preferences: preferences)
        await missingRef.run(); precondition(missingRef.postActions == [.mergeUnrelated,.pull,.stash,.reset])
        missing.fetch.arbitraryURL = true; missing.fetch.remote = producerRoot.path
        let arbitrary = PullProgressWindowModel(repository: repo, access: nil, options: missing, followUp: PullFollowUp(), preferences: preferences)
        await arbitrary.run(); precondition(arbitrary.postActions == [.pull,.stash,.reset])
        // Production follow-up conversion is shared by the native factory and this real-model chain.
        _ = try await repo.run(["config","branch.main.remote","other"]); _ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        try Data("stashed local edit\n".utf8).write(to: clientRoot.appendingPathComponent("independent"))
        var saveOptions = StashSaveOptions(); saveOptions.message = "Pull follow-up"
        var saveFollowUp = StashSaveFollowUp(); saveFollowUp.showPull = true; saveFollowUp.pullShowPush = true
        let save = StashSaveProgressWindowModel(repository: repo, access: nil, options: saveOptions, followUp: saveFollowUp)
        var chained: FetchWindowModel?
        save.onPostAction = { action, request in
            precondition(action == .pull && request.showPull && request.pullShowPush)
            let model = FetchWindowModel(repository: repo, access: nil, isPull: true, preferences: preferences)
            model.followUp = PullFollowUp(stashSave: request); chained = model
        }
        await save.run(); precondition(save.success && save.result?.created == true && save.postActions == [.pull,.pop,.apply])
        save.perform(.pull); let chainedOwner = chained!; chainedOwner.load(); try await waitUntil { !chainedOwner.busy }
        var popRequested = false
        chainedOwner.onPullPostAction = { action, result in precondition(action == .stashPop && result.followUp.showPush && result.followUp.showStashPop); popRequested = true }
        chainedOwner.fetch(); try await waitUntil { !chainedOwner.busy }
        precondition(chainedOwner.progress!.success && chainedOwner.progress!.postActions == [.stashPop,.diff,.log,.push])
        chainedOwner.progress!.perform(.stashPop); precondition(popRequested && chainedOwner.progress == nil)
        let popped = try await repo.restoreStash(pop: true)
        let restored = try Data(contentsOf: clientRoot.appendingPathComponent("independent")), stashes = try await repo.run(["stash","list"]).stdout
        precondition(!popped.conflicted && restored == Data("stashed local edit\n".utf8) && stashes.isEmpty)
        retry.invalidate(); retry.perform(.push)
        print("Pull progress: actual options/follow-up capture, retained result/close and duplicate gates; old/new HEAD Compare/Log, unchanged and No Commit cases; conflict hint waits/suppression with exact Resolve/Commit-only actions; source normal-close See changes workflow and native owner drain; non-conflict recovery and fresh tracked Hard-reset default without mutation; named unrelated retry creates two parents and preserves follow-ups. Only offscreen owned windows; private preferences, no clipboard writes.")
    }
}
