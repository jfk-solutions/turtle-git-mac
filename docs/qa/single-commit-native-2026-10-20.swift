// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum SingleCommitVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Single commit native deadline at \(line)")
    }
    static func drained()->Bool {CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0 && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && RebaseWindowModel.activeReplayOperations==0 && CommitContainingReferencesWindowController.activeOperations==0 && RevisionComparisonWindowModel.activeFileOperations==0 && ReferenceLogWindowModel.activeRevisionReads==0 && ReferenceLogWindowModel.activeOwnedOperations==0 && LogWindowModel.activeActionReads==0}
    struct Fixture {let repo:GitRepository,seed:String,legacy:String,subjectOnly:String;let message:String;var subject:String{"Café résumé"};var editorMessage:String{message}}
    @MainActor final class Context {
        let root:URL,git:URL,helper:URL,editor:URL,prefs:UserDefaults,suite:String,wrapper:URL,calls:URL,hold:URL,ready:URL
        var cleanup:[()->Void]=[]
        init(root:URL,git:URL,helper:URL,editor:URL)throws {
            self.root=root;self.git=git;self.helper=helper;self.editor=editor
            suite="TurtleGit.SingleCommit.QA."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(true,forKey:"HintStagingMode")
            wrapper=root.appendingPathComponent("details-helper");calls=root.appendingPathComponent("details-helper.calls");hold=root.appendingPathComponent("details-helper.hold");ready=root.appendingPathComponent("details-helper.ready")
            func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            let script="""
            #!/bin/sh
            printf '%s\\n' "$@" >> "$0.calls"
            if [ -f "$0.hold" ]; then
              /bin/sh -c 'while [ -f "$1" ]; do /bin/sleep 0.1; done' hold "$0.hold" &
              child=$!
              trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$child" > "$0.ready.tmp"
              /bin/mv "$0.ready.tmp" "$0.ready"
              wait "$child"
            fi
            exec \(quote(helper.path)) "$@"
            """
            try script.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        }
        func use(_ value:Bool){prefs.set(value,forKey:"UseLibgit2");prefs.set(UInt32(1)<<14,forKey:"UseLibgit2_mask")}
        func clear()throws{try Data().write(to:calls)}
        func log()throws->String {FileManager.default.fileExists(atPath:calls.path) ? try String(contentsOf:calls):""}
        func holdRead()throws {try? FileManager.default.removeItem(at:ready);try Data().write(to:hold)}
        func release()throws{try FileManager.default.removeItem(at:hold)}
        func owns(_ repo:GitRepository)->GitRepository {GitRepository(root:repo.root,executable:repo.executable,libgit2Configuration:.init(helperURL:wrapper))}
        func retire(){cleanup.reversed().forEach{$0()};cleanup=[];prefs.removePersistentDomain(forName:suite)}
        func object(_ repo:GitRepository,tree:String,parents:[String],message:String)async throws ->String {
            let source="tree "+tree+"\n"+parents.map{"parent "+$0+"\n"}.joined()+"author André <andre@example.invalid> 981173106 -0330\ncommitter Zoë <zoe@example.invalid> 990000000 +0545\nencoding ISO-8859-1\n\n"+message
            guard let raw=source.data(using:.isoLatin1) else{throw Failure(description:"Latin1 private source encoding failed")}
            return try await repo.run(["hash-object","-t","commit","-w","--stdin"],input:raw).text.trimmingCharacters(in:.newlines)
        }
        func fixture(_ name:String)async throws->Fixture {
            let path=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            let repo=GitRepository(root:path,executable:git,libgit2Configuration:.init(enabled:false))
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Configured User"),("user.email","configured@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            try Data("immutable worktree\n".utf8).write(to:path.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"seed")
            let seed=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),tree=try await repo.run(["write-tree"]).text.trimmingCharacters(in:.newlines)
            // Literal no-final-LF body; blank/leading body whitespace is significant.
            let message="Café résumé\n\n  leading body whitespace\nsecond paragraph café"
            let legacy=try await object(repo,tree:tree,parents:[seed],message:message),only=try await object(repo,tree:tree,parents:[seed],message:"Subject without final LF")
            _ = try await repo.run(["update-ref","refs/heads/main",legacy,seed]);_ = try await repo.run(["update-ref","refs/heads/upstream",seed])
            return .init(repo:repo,seed:seed,legacy:legacy,subjectOnly:only,message:message)
        }
        func commit(_ repo:GitRepository)->CommitWindowController {
            let owner=CommitWindowController(repository:owns(repo),access:RepositoryAccessLease(url:repo.root),defaults:prefs)
            cleanup.append{owner.model.invalidateForClose();owner.close()};owner.window?.orderFront(nil);return owner
        }
        func rebase(_ repo:GitRepository)->RebaseWindowController {
            let owner=RebaseWindowController(repository:owns(repo),access:RepositoryAccessLease(url:repo.root),preferences:prefs)
            owner.model.editorExecutable=editor;cleanup.append{owner.model.retire();owner.close()};owner.window?.orderFront(nil);return owner
        }
    }
    static func verify(caseName:String,root:URL,git:URL,helper:URL,editor:URL)async throws {
        let c=try Context(root:root,git:git,helper:helper,editor:editor);defer{c.retire()}
        switch caseName {case "commit":try await commit(c);case "rebase":try await rebase(c);case "endpoints":try await endpoints(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown single-commit case")}
    }
    static func metadataReady(_ model:CommitWindowModel)->Bool {!model.busy && !model.savingPreferences && !model.loadingAmendMessage && !model.loadingAuthorIdentity && !model.loadingAuthorDate && !model.loadingImportedMessage && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeReloads==0}
    static func commit(_ c:Context)async throws {
        for enabled in [false,true] {
            let f=try await c.fixture("commit-\(enabled)");c.use(enabled);let owner=c.commit(f.repo),model=owner.model
            model.reload();try await wait{metadataReady(model) && model.hasHead}
            let head=try await f.repo.run(["rev-parse","HEAD"]).stdout,index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
            model.message="retained normal draft";model.setAuthor=true;model.setAuthorDate=true;try c.clear();model.amend=true;model.amendChanged();try await wait{metadataReady(model)}
            try require(model.message==f.editorMessage && model.author=="André <andre@example.invalid>" && Int(model.authorDate.timeIntervalSince1970)==981173106,"Amend details lost raw identity/date/full decoded body: \(model.message) / \(model.author)")
            try require((try c.log()).contains("turtlegit-single-commit")==enabled,"Amend author/date/message did not use accepted14")
            model.message="User amended draft\n\nprivate body";model.setStagingEnabled(true);try await wait{metadataReady(model) && model.stagingEnabled};model.reload();try await wait{metadataReady(model)}
            try require(model.message=="User amended draft\n\nprivate body","Staging/refresh replaced edited amend draft")
            model.amend=false;model.amendChanged();try await wait{metadataReady(model)};try require(model.message=="retained normal draft","Amend toggle lost normal draft")
            var imported:String?;try c.clear();model.importLogMessage(f.legacy){imported=$0};try await wait{!model.loadingImportedMessage && CommitWindowModel.activeMetadataOperations==0}
            try require(imported==f.editorMessage && (try c.log()).contains("turtlegit-single-commit")==enabled,"Source2206 fresh message import lost legacy body/engine")
            imported=nil;model.importLogMessage(f.subjectOnly){imported=$0};try await wait{!model.loadingImportedMessage && CommitWindowModel.activeMetadataOperations==0}
            try require(imported=="Subject without final LF\n","Source message editor omitted mandatory subject/body separator")
            let after=try await f.repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await f.repo.run(["ls-files","--stage","-z"]).stdout,bytes=try Data(contentsOf:f.repo.root.appendingPathComponent("file"))
            try require(head==after && index==afterIndex && bytes==Data("immutable worktree\n".utf8),"Commit metadata reads changed HEAD/index/worktree")
            model.invalidateForClose();owner.close()
            let short=try await c.fixture("short-amend-\(enabled)")
            _ = try await short.repo.run(["update-ref","refs/heads/main",short.subjectOnly,short.legacy])
            c.use(enabled);let shortOwner=c.commit(short.repo);shortOwner.model.reload();try await wait{metadataReady(shortOwner.model)}
            shortOwner.model.message="normal short draft";shortOwner.model.amend=true;shortOwner.model.amendChanged();try await wait{metadataReady(shortOwner.model)}
            try require(shortOwner.model.message=="Subject without final LF\n","Source2753 amend omitted mandatory subject/body separator")
            shortOwner.model.invalidateForClose();shortOwner.close()
        }
    }
    static func rebase(_ c:Context)async throws {
        for enabled in [false,true] {
            let f=try await c.fixture("rebase-\(enabled)");c.use(enabled);try c.clear();let owner=c.rebase(f.repo),model=owner.model
            model.load(upstream:"refs/heads/upstream",force:true);try await wait{!model.busy && !model.loadingPlan && model.plan != nil && model.canAdd && !model.loadingColumnMetadata && RebaseWindowModel.activeColumnReads==0 && RebaseWindowModel.activePreparationReads==0}
            try require(model.referenceTooltip(branch:true).contains("André <andre@example.invalid>") && model.referenceTooltip(branch:true).contains(f.message) && (try c.log()).contains("turtlegit-single-commit")==enabled,"Rebase reference tooltip lost source14 full metadata")
            // Hold a real accepted Add receipt while an independent cosmetic
            // column refresh finishes. That refresh must not discard the Add.
            let acceptedRepository=c.owns(f.repo).capturingDiffBackend(preferences:c.prefs)
            var releaseAdd:(()->Void)?
            defer { releaseAdd?() }
            model.readAddedPlan={plan,revisions,token in
                let receipt=try await acceptedRepository.addingRebaseCommits(plan,revisions:revisions,cancellation:token)
                return await withCheckedContinuation { continuation in
                    releaseAdd={continuation.resume(returning:receipt)}
                }
            }
            try c.clear();model.addCommits([f.subjectOnly])
            try require(model.addingCommits && model.busy,"Ready Add was not accepted")
            try await wait{releaseAdd != nil}
            let acceptedContext=model.formContext
            model.refreshColumnMetadata(force:true)
            try await wait{!model.loadingColumnMetadata && RebaseWindowModel.activeColumnReads==0}
            try require(model.formContext.controls != acceptedContext.controls && model.formContext.generation==acceptedContext.generation,"Controlled column refresh did not exercise cosmetic-only Add race")
            releaseAdd?();releaseAdd=nil
            try await wait{!model.addingCommits && !model.busy && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}
            model.readAddedPlan=nil
            try require(model.entries.contains{$0.commit.hash==f.subjectOnly && $0.commit.subject=="Subject without final LF"} && (try c.log()).contains("turtlegit-single-commit")==enabled,"Rebase accepted Add revision omitted source14 metadata: \(model.error ?? "none")")
            model.retire();owner.close()
            // The legacy metadata-only objects above deliberately have the
            // parent's tree. Exercise actual -x Edit with a distinct content
            // commit rather than relying on an originally-empty replay stop.
            _ = try await f.repo.run(["reset","--hard",f.seed])
            try Data("actual Edit replay content\n".utf8).write(to:f.repo.root.appendingPathComponent("file"))
            try await f.repo.stage(["file"])
            let editTree=try await f.repo.run(["write-tree"]).text.trimmingCharacters(in:.newlines)
            let editObject="tree "+editTree+"\nparent "+f.seed+"\nauthor André <andre@example.invalid> 981173106 -0330\ncommitter Zoë <zoe@example.invalid> 990000000 +0545\n\n"+f.message
            let editHash=try await f.repo.run(["hash-object","-t","commit","-w","--stdin"],input:Data(editObject.utf8)).text.trimmingCharacters(in:.newlines)
            _ = try await f.repo.run(["reset","--hard",f.seed])
            var plan:RebasePlan
            do {plan=try await f.repo.cherryPickPlan(revisions:[editHash])}
            catch {throw Failure(description:"Private -x Edit plan (engine14=\(enabled), commit=\(editHash)): \(error)")}
            plan.options.addCherryPickedFrom=true;plan.entries[0].action = .edit
            let stopped:RebaseExecution
            do {stopped=try await f.repo.startRebase(plan,editorExecutable:c.editor)}
            catch {throw Failure(description:"Private -x Edit start (engine14=\(enabled), commit=\(editHash)): \(error)")}
            try require(stopped.state.isEditPause,"Private -x Edit failed: \(stopped.output)")
            c.use(enabled);try c.clear();let edit=c.rebase(f.repo);edit.model.load();try await wait{!edit.model.busy && edit.model.state?.isEditPause==true && RebaseWindowModel.activePreparationReads==0}
            try require(edit.model.replayMessageCommit?.author=="André" && edit.model.amendMessage.contains("leading body whitespace") && edit.model.amendMessage.contains("cherry picked from commit "+editHash) && (try c.log()).contains("turtlegit-single-commit")==enabled,"Active -x Edit lost selected HEAD metadata/draft")
            edit.model.retire();edit.close();_ = try await f.repo.abortRebase()
        }
    }
    static func endpoints(_ c:Context)async throws {
        for enabled in [false,true] {
            let f=try await c.fixture("endpoints-\(enabled)");c.use(enabled);try c.clear()
            let refs=CommitContainingReferencesWindowController(repository:c.owns(f.repo),access:RepositoryAccessLease(url:f.repo.root),revision:f.legacy,preferences:c.prefs)
            c.cleanup.append{refs.close()};refs.window?.orderFront(nil);refs.refresh();try await wait{!refs.busy}
            try require(refs.snapshot?.subject==f.subject && refs.snapshot?.author=="André" && refs.subject.stringValue.contains(f.subject) && (try c.log()).contains("turtlegit-single-commit")==enabled,"Containing refs displayed wrong single-commit details")
            let comparison=RevisionComparisonWindowModel(repository:c.owns(f.repo),access:RepositoryAccessLease(url:f.repo.root),from:.revision(f.seed),to:.revision(f.legacy),preferences:c.prefs)
            c.cleanup.append{comparison.invalidate()};try c.clear();comparison.load();try await wait{!comparison.busy}
            try require(comparison.error==nil && comparison.snapshot?.toDetails?.subject==f.subject && comparison.snapshot?.toDetails?.author=="André" && comparison.snapshot?.files.isEmpty==true && (try c.log()).contains("turtlegit-single-commit")==enabled,"Changed Files endpoint metadata lost14")
            let tree=try await f.repo.run(["write-tree"]).text.trimmingCharacters(in:.newlines),merge=try await c.object(f.repo,tree:tree,parents:[f.legacy,f.seed],message:"Parent menu\n\nbody")
            _ = try await f.repo.run(["update-ref","refs/heads/main",merge,f.legacy])
            let log=LogWindowModel(repository:c.owns(f.repo),access:RepositoryAccessLease(url:f.repo.root),labelDefaults:c.prefs);c.cleanup.append{log.invalidate()}
            log.entries=try await f.repo.history();log.graph=CommitGraph.layout(log.entries);try c.clear();log.select([merge])
            try await wait{log.parentMetadata[merge] != nil && LogWindowModel.activeActionReads==0}
            guard let row=log.entries.first(where:{$0.hash==merge}) else{throw Failure(description:"Native merge row missing")}
            try require(log.parentChoices(for:row).first?.subject==f.subject && (try c.log()).contains("turtlegit-single-commit")==enabled,"Log parent caption did not use full decoded14 subject")
            let priorIdentity=log.parentMetadataBackendIdentity;c.use(!enabled);log.select([merge]);try await wait{log.parentMetadata[merge] != nil && LogWindowModel.activeActionReads==0}
            try require(log.parentMetadataBackendIdentity != priorIdentity,"Log parent caption cache reused another backend")
            c.use(enabled)
            let reflog=ReferenceLogWindowModel(repository:c.owns(f.repo),access:RepositoryAccessLease(url:f.repo.root),reference:"HEAD",preferences:c.prefs);c.cleanup.append{reflog.invalidate()};reflog.reload();try await wait{!reflog.busy}
            guard let entry=reflog.entries.first(where:{$0.hash==merge}) else{throw Failure(description:"Native Reflog merge entry missing")}
            try c.clear();reflog.requestDiffParents(entry);try await wait{reflog.diffParents[merge] != nil && ReferenceLogWindowModel.activeOwnedOperations==0}
            try require(reflog.diffParents[merge]?.first?.subject==f.subject && (try c.log()).contains("turtlegit-single-commit")==enabled,"Reflog parent captions lost14")
            let identity=reflog.diffParentsBackendIdentity;c.use(!enabled);reflog.requestDiffParents(entry);try await wait{reflog.diffParents[merge] != nil && ReferenceLogWindowModel.activeOwnedOperations==0}
            try require(reflog.diffParentsBackendIdentity != identity,"Reflog reused another backend's cached captions")
            if enabled {
                // A replaced/broken selected helper must not leave old-engine
                // captions visible when a fresh details read cannot complete.
                let source=try String(contentsOf:c.wrapper,encoding:.utf8)
                defer{try? source.write(to:c.wrapper,atomically:true,encoding:.utf8);try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:c.wrapper.path)}
                try "#!/bin/sh\nprintf 'invalid private metadata\\n'\n".write(to:c.wrapper,atomically:true,encoding:.utf8)
                try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:c.wrapper.path)
                c.use(true);log.select([merge]);reflog.requestDiffParents(entry)
                try await wait{LogWindowModel.activeActionReads==0 && ReferenceLogWindowModel.activeOwnedOperations==0}
                try require(log.parentChoices(for:row).allSatisfy{$0.subject==nil} && (reflog.diffParents[merge] ?? []).allSatisfy{$0.subject==nil},"Failed new metadata engine retained old parent captions")
            }
            log.invalidate();reflog.invalidate();refs.close()
        }
    }
    static func ownership(_ c:Context)async throws {
        let f=try await c.fixture("ownership");c.use(true);let owner=c.commit(f.repo),model=owner.model;model.reload();try await wait{metadataReady(model)}
        model.message="normal draft";model.setAuthor=true;model.setAuthorDate=true;try c.clear();try c.holdRead();model.amend=true;model.amendChanged()
        try await wait{FileManager.default.fileExists(atPath:c.ready.path) && model.loadingAmendMessage}
        model.message="User changed draft while metadata was pending";let before=try c.log();try require(before.contains("turtlegit-single-commit"),"Accepted amend did not dispatch14")
        try c.clear();c.use(false);try c.release();try await wait{metadataReady(model)}
        let after=try c.log(),reads=after.components(separatedBy:"turtlegit-single-commit").count-1
        try require(reads>=2 && model.message=="User changed draft while metadata was pending" && model.author=="André <andre@example.invalid>" && Int(model.authorDate.timeIntervalSince1970)==981173106,"Amend cascade changed captured engine or overwrote draft")
        // Late importer from a real held helper must drain its process group.
        c.use(true);try c.holdRead();var inserts=0;model.importLogMessage(f.legacy){_ in inserts += 1}
        try await wait{FileManager.default.fileExists(atPath:c.ready.path) && model.loadingImportedMessage}
        let pids=try String(contentsOf:c.ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Owned details import lost Quit/process lifetime")
        model.invalidateForClose();owner.close();try await wait{CommitWindowModel.activeMetadataOperations==0 && pids.allSatisfy{kill($0,0) != 0}}
        try require(inserts==0,"Retired details importer inserted stale message");try c.release()
        // Existing query hooks remain injectable and retain late-read ownership.
        let late=c.commit(f.repo);late.model.reload();try await wait{metadataReady(late.model)}
        var reply:CheckedContinuation<String?,Error>?,token:OperationCancellation?;defer{reply?.resume(throwing:OperationCancellationFailure.cancelled)}
        late.model.message="late protected draft";late.model.queryAmendMessage={request in token=request;return try await withCheckedThrowingContinuation{reply=$0}}
        late.model.amend=true;late.model.amendChanged();try await wait{reply != nil};late.model.invalidateForClose();late.close()
        try require(token?.isCancelled==true && CommitWindowModel.activeMetadataOperations>0,"Injected metadata ownership ended before reply drained")
        reply?.resume(returning:"obsolete message");reply=nil;try await wait{CommitWindowModel.activeMetadataOperations==0}
        try require(late.model.message=="late protected draft","Closed injected metadata read replaced draft")
    }
}
