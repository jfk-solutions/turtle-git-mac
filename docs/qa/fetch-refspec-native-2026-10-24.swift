// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct FetchRefspecVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(description:message)}}
    static func exact(_ a:String,_ b:String)->Bool {a.utf8.elementsEqual(b.utf8)}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Fetch refspec native workflow did not settle")
    }
    @MainActor static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),mode=CommandLine.arguments[3]
        let suite="TurtleGit.FetchRefspec."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar")
        defer{prefs.removePersistentDomain(forName:suite)}
        let producerRoot=root.appendingPathComponent("producer"),clientRoot=root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at:producerRoot,withIntermediateDirectories:true)
        let producer=GitRepository(root:producerRoot,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await producer.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Refspec native QA"),("user.email","refspec@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await producer.run(["config",key,value])}
        try Data("base\n".utf8).write(to:producerRoot.appendingPathComponent("file"));try await producer.stage(["file"]);_=try await producer.commit(message:"base")
        let base=try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await producer.run(["clone","--template=",producerRoot.path,clientRoot.path])
        let repo=GitRepository(root:clientRoot,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        for (key,value) in [("user.name","Refspec client"),("user.email","client@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false"),("pull.rebase","false")] {_=try await repo.run(["config",key,value])}
        try Data("next\n".utf8).write(to:producerRoot.appendingPathComponent("file"));try await producer.stage(["file"]);_=try await producer.commit(message:"next")
        let remoteHead=try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let initialHead=try await repo.run(["rev-parse","HEAD"]).stdout,initialIndex=try Data(contentsOf:clientRoot.appendingPathComponent(".git/index")),initialWorking=try Data(contentsOf:clientRoot.appendingPathComponent("file"))
        var owners:[FetchWindowController]=[],rebaseOwners:[RebaseWindowController]=[]
        defer{for owner in owners {owner.model.invalidate();owner.window?.attachedSheet?.orderOut(nil);owner.window?.orderOut(nil);owner.close()};for owner in rebaseOwners{owner.model.retire();owner.window?.orderOut(nil);owner.close()}}
        func open(_ pull:Bool=false,_ url:Bool=false)async throws->FetchWindowController {
            let owner=FetchWindowController(repository:repo,access:nil,isPull:pull,preferences:prefs);owners.append(owner)
            owner.model.clipboardText={nil};owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(NSPoint(x:-30000,y:-30000));owner.window?.orderFront(nil)
            owner.presentFetchProgress={parent,child in child.isReleasedWhenClosed=false;child.alphaValue=0;child.setFrameOrigin(NSPoint(x:-30000,y:-30000));parent.beginSheet(child);return true}
            owner.presentPullProgress={parent,child in child.isReleasedWhenClosed=false;child.alphaValue=0;child.setFrameOrigin(NSPoint(x:-30000,y:-30000));parent.beginSheet(child);return true}
            owner.model.load();try await wait{!owner.model.busy && !owner.model.preparing && !owner.model.preparationNeedsRetry}
            owner.model.options.remote="origin";owner.model.options.namedRemoteFetchAll=false;owner.model.options.arbitraryURL=url
            if url {owner.model.url=producerRoot.path}
            owner.window?.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:30_000_000);return owner
        }
        func input(_ owner:FetchWindowController,_ value:String)async throws {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            try await wait{views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.contains{$0.accessibilityLabel()=="Remote branch" && $0.isEnabled}}
            let combo=views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.first{$0.accessibilityLabel()=="Remote branch"}!
            guard let delegate=combo.delegate as? FetchHistoryCombo.Coordinator else{throw Failure(description:"Shipping history combo delegate missing")}
            combo.stringValue=value;delegate.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:combo))
            try require(exact(owner.model.options.branch,value),"Native Remote branch input changed literal refspec")
        }
        func submitFetch(_ owner:FetchWindowController)async throws->FetchProgressWindowModel {
            owner.model.fetch();try await wait{owner.model.fetchProgress != nil}
            let progress=owner.model.fetchProgress!;try await wait{!progress.busy && progress.pendingOperations==0 && !progress.confirmingRebaseDecision};return progress
        }
        func submitPull(_ owner:FetchWindowController)async throws->PullProgressWindowModel {
            owner.model.fetch();try await wait{owner.model.progress != nil}
            let progress=owner.model.progress!;try await wait{!progress.busy && progress.pendingOperations==0 && !progress.confirmingConflictHint};return progress
        }
        func ref(_ name:String)async throws->String? {
            let value=try await repo.run(["rev-parse","--verify","--quiet","--end-of-options",name],successfulExitCodes:0...1)
            return value.exitCode==0 ? value.text.trimmingCharacters(in:.newlines):nil
        }
        func historyContains(_ value:String)->Bool {FetchDialogHistory.load(prefs,key:"History.PullRemoteBranch",caseSensitive:true).contains{exact($0,value)}}
        if mode == "fetch" {
            for (number,url) in [false,true].enumerated() {
                let owner=try await open(false,url),literal="+refs/heads/main:refs/tags/native-雪/cafe\u{301}-\(number)"
                try await input(owner,"  "+literal+"  ");let progress=try await submitFetch(owner)
                try require(progress.success && exact(progress.options.branch,literal),"Literal named/URL Fetch failed: "+progress.output)
                try require(try await ref(String(literal.split(separator:":")[1]))==remoteHead,"Literal mapped destination not updated")
                try require(historyContains(literal),"Literal accepted mapping missing from shared native history")
                try require(progress.output.contains(literal),"Progress lost exact mapped refspec command")
            }
            let malformed="refs/heads/main::refs/remotes/origin/not-valid",failedOwner=try await open()
            try await input(failedOwner,malformed);let failed=try await submitFetch(failedOwner)
            try require(!failed.success && failed.postActions.contains(.retry) && failed.output.contains(malformed),"Malformed literal lost real Git diagnostic/Retry: "+failed.output)
            try require(!failed.output.contains(FetchFailure.branch.localizedDescription),"Malformed Git refspec replaced by generic branch-name validation")
            try require(historyContains(malformed),"Submitted malformed literal was replaced in native history")
            failedOwner.model.options.branch="refs/heads/main:refs/tags/changed-draft"
            failed.perform(.retry);failed.perform(.retry);try await wait{!failed.busy && failed.pendingOperations==0}
            try require(!failed.success && exact(failed.options.branch,malformed) && failed.output.contains(malformed),"Retry substituted current form text for captured malformed refspec")
            try require(try await ref("refs/tags/changed-draft")==nil,"Retry executed a newer unaccepted draft")
            _=try await repo.run(["update-ref","refs/tags/refused",base])
            let refusedOwner=try await open(),refused="refs/heads/main:refs/tags/refused"
            try await input(refusedOwner,refused);let refusal=try await submitFetch(refusedOwner)
            try require(!refusal.success && refusal.output.contains(refused) && refusal.postActions.contains(.retry),"Refused tag update lost exact server diagnostic")
            try require(try await ref("refs/tags/refused")==base,"Refused tag update mutated target")
        } else if mode == "pull" {
            for (number,url) in [false,true].enumerated() {
                _=try await repo.run(["reset","--hard",base])
                let owner=try await open(true,url),literal="refs/heads/main:refs/remotes/origin/native-pull-\(number)"
                try await input(owner,literal);let progress=try await submitPull(owner)
                try require(progress.success && exact(progress.options.fetch.branch,literal),"Literal named/URL Pull failed: "+progress.output)
                try require(try await ref("HEAD")==remoteHead,"Pull did not merge literal refspec FETCH_HEAD")
                try require(historyContains(literal) && progress.output.contains(literal),"Pull history/progress changed literal mapped argument")
            }
            let owner=try await open(true),malformed="refs/heads/main::refs/remotes/origin/pull-invalid"
            try await input(owner,malformed);let failed=try await submitPull(owner)
            try require(!failed.success && failed.output.contains(malformed) && !failed.output.contains(FetchFailure.branch.localizedDescription),"Malformed Pull did not retain actual Git diagnostic")
            try require(historyContains(malformed) && exact(failed.options.fetch.branch,malformed),"Failed Pull lost captured literal/history")
            try require(try await ref("HEAD")==remoteHead,"Failed Pull changed current commit")
        } else if mode == "rebase" {
            _=try await repo.run(["config","branch.main.rebase","true"])
            let owner=try await open(true),literal="refs/heads/main:refs/remotes/origin/rebase-literal"
            owner.model.options.namedRemoteFetchAll=true
            var handoffs:[String]=[],automatic:[Bool]=[]
            let preset="remotes/origin/"+literal
            owner.model.onOwnedRebase={target,auto,preserve in
                handoffs.append(target);automatic.append(auto)
                let editor=RebaseWindowController(repository:repo,access:nil,preferences:prefs);rebaseOwners.append(editor)
                editor.window?.isReleasedWhenClosed=false;editor.window?.alphaValue=0;editor.window?.setFrameOrigin(NSPoint(x:-30000,y:-30000))
                editor.model.load(upstream:target.isEmpty ? nil:target,autoStart:auto,preserveMerges:preserve)
                try await wait{!editor.model.busy && editor.model.pendingBatchWorkers==0}
                try require(exact(editor.model.options.upstream,preset) && editor.model.editable && !editor.model.canStart && editor.model.error != nil,"Unresolved source preset did not remain editable with Start disabled")
            }
            try await input(owner,literal);let progress=try await submitFetch(owner)
            try require(progress.success && progress.isPull && progress.options.namedRemoteFetchAll && same(handoffs,[preset]) && automatic==[true],"Configured Pull Rebase inferred a different target from raw refspec")
            try require(historyContains(literal) && exact(progress.options.branch,literal),"Rebase Fetch replaced literal mapping")
            try require(try await ref("refs/remotes/origin/rebase-literal")==remoteHead,"Rebase transport failed to apply literal destination")
            // A conventional branch still resolves to an immutable revision. The
            // injected callback records the source handoff without starting replay.
            let resolved=try await open(true)
            resolved.model.options.namedRemoteFetchAll=true
            resolved.model.onOwnedRebase={target,auto,_ in handoffs.append(target);automatic.append(auto)}
            try await input(resolved,"main");let resolvedProgress=try await submitFetch(resolved)
            try require(resolvedProgress.success && resolvedProgress.isPull && resolvedProgress.options.namedRemoteFetchAll && same(handoffs,[preset,remoteHead]) && automatic==[true,true],"Ordinary configured Rebase branch no longer resolves its immutable target")
            let emptyPull=try await open(true)
            emptyPull.model.options.namedRemoteFetchAll=true
            try await input(emptyPull,"");emptyPull.model.fetch()
            try require(emptyPull.model.fetchProgress==nil && emptyPull.model.progress==nil && !emptyPull.model.busy && emptyPull.model.error != nil,"Empty configured Pull Rebase bypassed source branch requirement")
            let malformedOwner=try await open(true),malformed="refs/heads/main::refs/remotes/origin/rebase-invalid"
            malformedOwner.model.options.namedRemoteFetchAll=true
            try await input(malformedOwner,malformed);let failure=try await submitFetch(malformedOwner)
            try require(!failure.success && failure.isPull && failure.options.namedRemoteFetchAll && failure.postActions.contains(.retry) && failure.output.contains(malformed),"Configured Pull Rebase default checkbox omitted malformed literal or lost its origin")
            malformedOwner.model.options.branch="main";malformedOwner.model.options.namedRemoteFetchAll=false
            failure.perform(.retry);failure.perform(.retry);try await wait{!failure.busy && failure.pendingOperations==0}
            try require(!failure.success && failure.isPull && failure.options.namedRemoteFetchAll && exact(failure.options.branch,malformed) && failure.output.contains(malformed),"Rebase Retry changed captured Pull origin/default checkbox/refspec after draft edit")
            let allFetch=try await open(false)
            allFetch.model.options.namedRemoteFetchAll=true;allFetch.model.launchRebase=true
            let present=allFetch.model.onFetchProgress
            allFetch.model.onFetchProgress={progress in
                present?(progress)
                progress.presentRebasePrompt={prompt in FetchRebaseAnswer(value:prompt == .fastForward ? 2:6,suppress:false)}
            }
            allFetch.model.onOwnedRebase={target,auto,_ in handoffs.append(target);automatic.append(auto)}
            try await input(allFetch,"");let allProgress=try await submitFetch(allFetch)
            try require(allProgress.success && !allProgress.isPull && same(handoffs,[preset,remoteHead,remoteHead]) && automatic==[true,true,false],"Empty named Fetch Rebase lost configured tracked fallback/explicit editable handoff")

        } else {throw Failure(description:"Unknown Fetch refspec case")}
        if mode != "pull" {
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==initialHead,"Fetch/Rebase handoff changed HEAD")
            try require(try Data(contentsOf:clientRoot.appendingPathComponent(".git/index"))==initialIndex && Data(contentsOf:clientRoot.appendingPathComponent("file"))==initialWorking,"Fetch/Rebase changed index or working file")
        }
        for owner in owners {owner.model.invalidate();if let child=owner.window?.attachedSheet {owner.window?.endSheet(child);child.orderOut(nil);child.close()};owner.window?.close()}
        for owner in rebaseOwners{owner.model.retire();if let child=owner.window?.attachedSheet{owner.window?.endSheet(child);child.orderOut(nil);child.close()};owner.window?.close()}
        try await wait{FetchWindowModel.activeProgressOperations==0 && FetchWindowController.activeProgressReleases==0 && RebaseWindowModel.activePreparationReads==0}
        print("PASS: Fetch refspec "+mode+"; literal native input/history, retained progress and owned windows closed")
    }
    static func same(_ a:[String],_ b:[String])->Bool {a.count==b.count && zip(a,b).allSatisfy{exact($0.0,$0.1)}}
}
