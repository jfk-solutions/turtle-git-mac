// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum HistorySubmoduleInspectionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"History/submodule native deadline at \(line)")
    }
    static func sameFilesystemRoot(_ actual: URL?, _ expected: URL) -> Bool {
        guard let actual else { return false }
        return actual.resolvingSymlinksInPath().standardizedFileURL.path.utf8.elementsEqual(expected.resolvingSymlinksInPath().standardizedFileURL.path.utf8)
    }
    static func drained() -> Bool {
        LogWindowModel.activeActionReads==0 && LogWindowModel.activeHistoryDeletions==0 && LogWindowModel.activeFileOpenReads==0 &&
        ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeMutations==0 &&
        SubmoduleDiffWindowModel.activeReads==0 && SubmoduleWorkingLogSession.activeReads==0 &&
        ConflictReviewOperation.activeOperations==0 && RevisionComparisonWindowModel.activeFileOperations==0 && HistoryCombineWindowModel.activeOperations==0 && HistoryCombineSelectionReader.activeReads==0
    }
    @MainActor final class Context {
        let root:URL, git:URL, prefs:UserDefaults, suite:String, wrapper:URL, calls:URL, hold:URL, ready:URL
        var cleanup:[()->Void]=[]
        init(root:URL,git:URL,helper:URL)throws {
            self.root=root;self.git=git;suite="TurtleGit.HistorySubmodule.QA."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress")
            wrapper=root.appendingPathComponent("inspection-helper");calls=root.appendingPathComponent("inspection-helper.calls");hold=root.appendingPathComponent("inspection-helper.hold");ready=root.appendingPathComponent("inspection-helper.ready")
            func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
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
        func use(_ enabled:Bool) {prefs.set(enabled,forKey:"UseLibgit2");prefs.set(UInt32((1<<7)|(1<<12)),forKey:"UseLibgit2_mask")}
        func log()throws->String {FileManager.default.fileExists(atPath:calls.path) ? try String(contentsOf:calls):""}
        func clear()throws {try Data().write(to:calls)}
        func block()throws {try? FileManager.default.removeItem(at:ready);try Data().write(to:hold)}
        func release()throws {try FileManager.default.removeItem(at:hold)}
        func owns(_ repo:GitRepository)->GitRepository {GitRepository(root:repo.root,executable:git,libgit2Configuration:.init(helperURL:wrapper))}
        func repo(_ name:String)async throws->GitRepository {
            let path=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            let repo=GitRepository(root:path,executable:git,libgit2Configuration:.init(enabled:false))
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Inspection QA"),("user.email","inspection@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            return repo
        }
        func commit(_ repo:GitRepository,_ value:String)async throws->String {
            try Data((value+"\n").utf8).write(to:repo.root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:value)
            return try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        }
        func retire(){cleanup.reversed().forEach{$0()};cleanup=[];prefs.removePersistentDomain(forName:suite)}
    }
    static func verify(caseName:String,root:URL,git:URL,helper:URL)async throws {
        let c=try Context(root:root,git:git,helper:helper);defer{c.retire()}
        switch caseName {case "history":try await history(c);case "submodule":try await submodule(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown native history/submodule case")}
    }
    static func history(_ c:Context)async throws {
        let plain=try await c.repo("history"),base=try await c.commit(plain,"base")
        _ = try await plain.run(["branch","old",base]);let middle=try await c.commit(plain,"middle"),head=try await c.commit(plain,"head")
        _ = try await plain.run(["checkout","-b","unmerged",base]);let side=try await c.commit(plain,"side");_ = try await plain.run(["checkout","main"])
        let repo=c.owns(plain),grant=RepositoryAccessLease(url:plain.root)
        for enabled in [false,true] {
            c.use(enabled);try c.clear()
            let log=LogWindowModel(repository:repo,access:grant,labelDefaults:c.prefs);c.cleanup.append{log.invalidate()}
            log.entries=try await plain.history();log.graph=CommitGraph.layout(log.entries);log.select([middle]);try await wait{!log.busy && LogWindowModel.activeActionReads==0}
            log.jumpKind = .branchFF;log.jump(up:false);try await wait{!log.jumping}
            try require(log.selected==[base] && (try c.log()).contains("turtlegit-merge-base")==enabled,"FF Jump lost ancestry policy or selected wrong branch")
            log.select([base]);try await wait{!log.busy && LogWindowModel.activeActionReads==0}
            var deletion:HistoryReferenceDeletion?
            log.confirmReferenceDeletion={deletion=$0;return .abort};try c.clear()
            log.deleteReferences([LogReferenceMenuTarget(hash:base,name:"refs/heads/old")])
            try await wait{!log.busy && LogWindowModel.activeHistoryDeletions==0}
            try require(deletion?.name=="refs/heads/old" && deletion?.unmerged==false && (try c.log()).contains("turtlegit-merge-base")==enabled,"Shared local-head deletion warning lost captured source7")
            log.invalidate()
            let owner=ReferenceBrowserWindowController(repository:repo,access:grant,initial:"refs/heads/unmerged",preferences:c.prefs,picking:false){_ in};c.cleanup.append{owner.model.invalidate();owner.close()};owner.window?.orderFront(nil);owner.model.load()
            try await wait{!owner.model.busy && ReferenceBrowserWindowModel.activeReads==0}
            guard let snapshot=owner.model.snapshot else{throw Failure(description:owner.model.error ?? "Browser snapshot missing")}
            owner.model.setFolder(snapshot.initialSelection("refs/heads/unmerged").folder);owner.model.select([GitReferenceName("refs/heads/unmerged")],last:GitReferenceName("refs/heads/unmerged"))
            var warning:ReferenceBrowserDeletionConfirmation?
            owner.model.confirmDeletion={warning=$0;return false};try c.clear();owner.model.deleteChosen();try await wait{!owner.model.busy && ReferenceBrowserWindowModel.activeMutations==0}
            try require(warning?.unmerged==true && (try c.log()).contains("turtlegit-merge-base")==enabled,"Browser single-branch warning lost source7")
            owner.model.invalidate();owner.close()
            let remaining=try await plain.run(["rev-parse","refs/heads/unmerged"]).text.trimmingCharacters(in:.newlines);try require(remaining==side,"Declined warning deleted branch")
            // Actual Combine performs two separate cleanliness checks. Hold the
            // first selected read and change preferences before both settle.
            let entries=try await plain.history().filter{$0.hash==head || $0.hash==middle}
            let combine=HistoryCombineWindowModel(repository:repo,access:grant,entries:entries,firstOffset:0,expectedHead:head,preferences:c.prefs);c.cleanup.append{combine.invalidate()}
            var asked=false;combine.presentCommit={_ in asked=true;return false}
            try c.clear();if enabled {try c.block()};combine.start()
            if enabled {try await wait{FileManager.default.fileExists(atPath:c.ready.path)};c.use(false);try c.release()}
            try await wait{!combine.busy && HistoryCombineWindowModel.activeOperations==0}
            let requests=try c.log().components(separatedBy:"turtlegit-check-clean").count-1
            try require(asked && requests==(enabled ? 2:0),"Combine prepare/begin did not retain one accepted source12 policy: \(combine.output)")
            let restored=try await plain.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            try require(restored==head,"Cancelled Combine failed exact HEAD rollback")
        }
    }
    struct ModuleFixture {let parent:GitRepository,child:GitRepository,path:String,base:String,next:String}
    static func module(_ c:Context,_ name:String)async throws->ModuleFixture {
        let parent=try await c.repo(name);_ = try await c.commit(parent,"parent")
        let path="literal[*] 雪",location=parent.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at:location,withIntermediateDirectories:false)
        let child=GitRepository(root:location,executable:c.git,libgit2Configuration:.init(enabled:false));_ = try await child.run(["init","-b","main"])
        for (key,value) in [("user.name","Child QA"),("user.email","child@example.invalid"),("commit.gpgsign","false")] {_ = try await child.run(["config",key,value])}
        let base=try await c.commit(child,"child base")
        _ = try await parent.run(["update-index","--add","--cacheinfo","160000,"+base+","+path]);_ = try await parent.commit(message:"attach child")
        let next=try await c.commit(child,"child next")
        return .init(parent:parent,child:child,path:path,base:base,next:next)
    }
    static func submodule(_ c:Context)async throws {
        let f=try await module(c,"submodule"),repo=c.owns(f.parent),grant=RepositoryAccessLease(url:f.parent.root)
        let originalIndex=try await f.parent.run(["ls-files","--stage","-z"]).stdout
        for enabled in [false,true] {
            c.use(enabled);try c.clear()
            let owner=SubmoduleDiffWindowController(repository:repo,access:grant,path:f.path,from:"HEAD",preferences:c.prefs);c.cleanup.append{owner.model.invalidate();owner.close()};owner.window?.orderFront(nil);owner.model.load()
            try await wait{!owner.model.busy && SubmoduleDiffWindowModel.activeReads==0}
            try require(owner.model.details?.change == .fastForward && (try c.log()).contains("turtlegit-merge-base")==enabled,"Submodule Diff lost child ancestry: \(owner.model.error ?? "no details")")
            try c.clear();var received:GitRepository?,hash:String?
            owner.model.onLog={received=$0;hash=$1};owner.model.log(owner.model.details!.to)
            try await wait{!owner.model.busy && SubmoduleDiffWindowModel.activeReads==0}
            try require(sameFilesystemRoot(received?.root,f.child.root) && received?.libgit2Configuration?.enabled==enabled && hash==f.next && !(try c.log()).contains("turtlegit-merge-base"),"Submodule action lost captured child repository/validation: enabled=\(enabled), root=\(received?.root.path ?? "nil"), expectedRoot=\(f.child.root.path), backend=\(String(describing:received?.libgit2Configuration)), hash=\(hash ?? "nil"), expectedHash=\(f.next), error=\(owner.model.error ?? "none"), calls=\(try c.log())")
            let changed=RevisionComparisonWindowModel(repository:repo,access:grant,from:.revision("HEAD"),to:.workingTree,preferences:c.prefs)
            c.cleanup.append{changed.invalidate()};changed.load();try await wait{!changed.busy}
            try require(changed.error==nil && changed.visibleFiles.contains{$0.path==f.path && $0.isSubmodule},"Changed Files omitted actual child gitlink")
            var logRoot:URL?,logHash:String?
            changed.onSubmoduleLog={logRoot=$0;logHash=$1};try c.clear();changed.logSubmodules([f.path]);try await wait{!changed.busy && RevisionComparisonWindowModel.activeFileOperations==0}
            try require(sameFilesystemRoot(logRoot,f.child.root) && logHash==nil && (try c.log()).contains("turtlegit-merge-base")==enabled,"Changed Files child Log inspection lost accepted source7")
            changed.invalidate()
            let session=SubmoduleWorkingLogSession(repository:repo,access:grant,preferences:c.prefs);let child=try await session.load(f.path);session.retire()
            try require(sameFilesystemRoot(child.root,f.child.root) && child.libgit2Configuration?.enabled==enabled,"Working-submodule Log lost configured child")
            owner.model.invalidate();owner.close()
        }
        // Real conflict stages against the checkout's base; both differing
        // sides inspect ancestry without changing those immutable stages.
        _ = try await f.child.run(["checkout","--detach",f.base])
        _ = try await f.parent.run(["update-index","--force-remove","--",f.path])
        let stages="160000 "+f.base+" 1\t"+f.path+"\n160000 "+f.next+" 2\t"+f.path+"\n160000 "+f.next+" 3\t"+f.path+"\n"
        _ = try await f.parent.run(["update-index","--index-info"],input:Data(stages.utf8))
        let conflictIndex=try await f.parent.run(["ls-files","--stage","-z"]).stdout
        for enabled in [false,true] {
            c.use(enabled);try c.clear();let owner=SubmoduleConflictWindowController(repository:repo,access:grant,path:f.path,preferences:c.prefs);c.cleanup.append{owner.model.invalidate();owner.close()};owner.window?.orderFront(nil);owner.model.load()
            try await wait{!owner.model.busy && ConflictReviewOperation.activeOperations==0}
            try require(owner.model.details?.mine.change == .fastForward && owner.model.details?.theirs.change == .fastForward && (try c.log()).contains("turtlegit-merge-base")==enabled,"Submodule conflict labels lost source7: \(owner.model.error ?? "none")")
            var child:GitRepository?;owner.model.onLog={child=$0;_=$1};owner.model.log(owner.model.details!.mine);try await wait{!owner.model.busy}
            try require(sameFilesystemRoot(child?.root,f.child.root) && child?.libgit2Configuration?.enabled==enabled,"Conflict Log dropped accepted child configuration")
            owner.model.invalidate();owner.close()
        }
        let finalIndex=try await f.parent.run(["ls-files","--stage","-z"]).stdout
        try require(finalIndex==conflictIndex && originalIndex != finalIndex,"Child inspections changed conflict stages")
    }
    static func ownership(_ c:Context)async throws {
        let f=try await module(c,"ownership"),grant=RepositoryAccessLease(url:f.parent.root);c.use(true);try c.clear();try c.block()
        let owner=SubmoduleDiffWindowController(repository:c.owns(f.parent),access:grant,path:f.path,from:"HEAD",preferences:c.prefs);c.cleanup.append{owner.model.invalidate();owner.close()};owner.window?.orderFront(nil);owner.model.load()
        try await wait{FileManager.default.fileExists(atPath:c.ready.path) && owner.model.busy}
        c.use(false);try c.release();try await wait{!owner.model.busy && SubmoduleDiffWindowModel.activeReads==0}
        try require(owner.model.details?.change == .fastForward && (try c.log()).contains("turtlegit-merge-base"),"Accepted child read changed backend mid-flight")
        owner.model.invalidate();owner.close()
        c.use(true);let missing=GitRepository(root:f.parent.root,executable:c.git,libgit2Configuration:.init(helperURL:c.root.appendingPathComponent("missing-helper")))
        let refused=SubmoduleDiffWindowController(repository:missing,access:grant,path:f.path,from:"HEAD",preferences:c.prefs);c.cleanup.append{refused.model.invalidate();refused.close()};refused.model.load();try await wait{!refused.model.busy}
        try require(refused.model.details==nil && refused.model.error != nil,"Missing selected helper silently used CLI child classification")
        refused.model.invalidate();refused.close()
        try c.block();let retired=SubmoduleDiffWindowController(repository:c.owns(f.parent),access:grant,path:f.path,from:"HEAD",preferences:c.prefs);c.cleanup.append{retired.model.invalidate();retired.close()};retired.model.load();try await wait{FileManager.default.fileExists(atPath:c.ready.path) && retired.model.busy}
        let pids=try String(contentsOf:c.ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        retired.model.invalidate();retired.close();try await wait{SubmoduleDiffWindowModel.activeReads==0}
        try require(retired.model.details==nil && pids.count==2,"Retired child read published late results")
        try await wait{pids.allSatisfy{kill($0,0) != 0}}
        try require(drained(),"Retired inspection leaked owned reads")
    }
}
