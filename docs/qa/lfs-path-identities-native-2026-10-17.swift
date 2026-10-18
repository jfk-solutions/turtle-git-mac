// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct LFSPathIdentityVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws { if !value {throw Failure(description:message)} }
    @MainActor static func wait(_ condition:()->Bool) async throws {
        for _ in 0..<2000 {if condition(){return};try await Task.sleep(nanoseconds:5_000_000)}
        throw Failure(description:"LFS identity state did not settle")
    }
    @MainActor static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2])
        let repo=GitRepository(root:root,executable:engine),a="caf\u{00e9}.bin",b="cafe\u{0301}.bin"
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","LFS Identity QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        let hash=try await repo.run(["hash-object","-w","--stdin"],input:Data("base\n".utf8)).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["update-index","-z","--index-info"],input:Data([a,b].map {"100644 \(hash)\t\($0)\0"}.joined().utf8))
        _=try await repo.run(["commit","-m","exact LFS index spellings"])
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
        let beforeIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),beforeHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let suite="TurtleGit.LFSIdentity."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        var server=[LFSLock(id:"1",path:a,owner:"Alice"),LFSLock(id:"2",path:b,owner:"Bob")]
        let owner=LFSLocksWindowController(repository:repo,access:nil,defaults:prefs),model=owner.model
        defer {owner.close()}
        owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.query={_ in server}
        await model.refresh()
        try require(model.checked.count==2,"Lost initial locks")
        model.setChecked("1",false)
        server=[LFSLock(id:"new-a",path:a,owner:"Alice"),LFSLock(id:"new-b",path:b,owner:"Bob")]
        await model.refresh()
        try require(model.checked == ["new-b"],"Unchecked path contaminated its canonical neighbor after refresh")
        let table=views(owner.window!.contentView!).compactMap {$0 as? LFSLocksNativeTable}.first!
        let coordinator=table.delegate as! LFSLocksTable.Coordinator
        model.selection=["new-b"];coordinator.refresh()
        try require(table.selectedRowIndexes.count==1 && GitReferenceName.equal(coordinator.itemIDs![table.selectedRow],"new-b"),"Native selection lost exact row")
        model.checkClicked("new-b",value:false);try require(model.checked.isEmpty,"Checkbox affected another path")
        model.checkClicked("new-b",value:true);try require(model.checked == ["new-b"],"Checkbox failed to restore one path")
        var copied=[String]();model.publishClipboard={copied.append($0)}
        let target=model.menuTarget(["new-a","new-b"])!
        model.selection=["new-a"];model.setSortOrder([.init(column:.path,order:.reverse)])
        model.copy(target,information:.relativePaths);model.copy(target,information:.relativePaths)
        try require(copied.count==1 && GitPathSet(copied[0].split(separator:"\n").map(String.init)).count==2,"Captured menu lost a path or ran twice")
        try require(model.pathHelp(a).contains("UTF-8:") && model.pathHelp(b).contains("UTF-8:"),"Indistinguishable paths lack byte help")
        // Publish opaque IDs without folding them through Swift String equality.
        server=[LFSLock(id:a,path:"one.bin",owner:"One"),LFSLock(id:b,path:"two.bin",owner:"Two")]
        await model.refresh();model.selection=GitPathSet([a,b]);model.selectAll(true)
        coordinator.refresh()
        try require(model.selection.count==2 && model.checked.count==2 && table.selectedRowIndexes.count==2,"Opaque server IDs merged in model/native selection")
        model.refreshLocksAfterOperation=false
        var attempts=[[String]](),forces=[Bool]()
        model.change={paths,force,_,report in
            attempts.append(paths);forces.append(force)
            report(.init(path:"not-requested.bin",success:true,output:"ignore"))
            let files=paths.enumerated().map {LFSFileResult(path:$0.element,success:force || $0.offset==0,output:"fixture")}
            for file in files {report(file);report(file)}
            try await Task.sleep(nanoseconds:50_000_000)
            try require(model.results.count==2 && model.notifications.filter {$0.kind == .file}.count==2,"Live progress accepted a duplicate or foreign callback")
            return .init(files:files)
        }
        await model.perform(paths:[a,b,a],locked:false)
        try require(model.results.count==2 && model.notifications.filter {$0.kind == .file}.count==2,"Progress lost, duplicated or accepted foreign target")
        try require(model.results.map {Data($0.path.utf8)} == [Data(a.utf8),Data(b.utf8)],"Progress normalized target paths")
        model.selection=[];model.checked=[];await model.unlock(forceRetry:true)
        try require(attempts.count==2 && attempts.allSatisfy {$0.map {Data($0.utf8)} == [Data(a.utf8),Data(b.utf8)]} && forces == [false,true],"Force retry changed captured targets")
        model.finishProgress()
        model.change={_,_,_,_ in .init(files:[.init(path:"foreign.bin",success:true,output:"")])}
        await model.perform(paths:[a],locked:false)
        try require(model.results.isEmpty && model.error != nil,"Foreign final batch was accepted")
        model.finishProgress()
        // Incomplete terminal replies cannot erase already-reported effects or
        // claim success. Force retries the entire captured original selection.
        var pulls=0,partialAttempts=[[String]]()
        model.onPullAfterLock={pulls += 1}
        model.change={paths,force,_,report in
            partialAttempts.append(paths)
            if force {return .init(files:paths.map {.init(path:$0,success:true,output:"forced")})}
            report(.init(path:paths[0],success:true,output:"completed before disconnect"))
            return .init(files:[])
        }
        await model.perform(paths:[a,b],locked:false)
        try require(model.error != nil && model.canForceRetry && model.results.count==1 && GitReferenceName.equal(model.results[0].path,a),"Incomplete reply erased completed effects or disabled captured Force recovery")
        try require(model.notifications.last?.kind == .finishedFailure && model.actionLogFailed && pulls==0,"Incomplete unlock reported successful completion")
        await model.unlock(forceRetry:true)
        try require(partialAttempts.count==2 && partialAttempts.allSatisfy {$0.map {Data($0.utf8)} == [Data(a.utf8),Data(b.utf8)]} && model.results.count==2 && !model.canForceRetry && !model.actionLogFailed,"Force recovery changed original targets or retained an old failure")
        model.finishProgress()
        model.lockChange={paths,_,report in
            report(.init(path:paths[0],success:true,output:"locked before disconnect"))
            return .init(files:[])
        }
        await model.perform(paths:[a,b],locked:true)
        try require(model.error != nil && model.results.count==1 && !model.canForceRetry && pulls==0 && model.notifications.last?.kind == .finishedFailure,"Incomplete Lock opened Pull or discarded server effects")
        model.finishProgress()
        model.lockChange={paths,token,report in
            report(.init(path:paths[0],success:true,output:"locked before Cancel"));token.cancel()
            return .init(files:[],cancelled:true)
        }
        await model.perform(paths:[a,b],locked:true)
        try require(model.error==nil && model.actionLogCancelled && model.results.count==1 && pulls==0 && model.notifications.last?.kind == .finishedFailure,"Cancelled partial reply erased completed effects or opened Pull")
        model.finishProgress()
        // The real status reads expose two index names that may alias one disk path.
        let locks=[LFSLock(id:"1",path:a,owner:"Alice"),LFSLock(id:"2",path:b,owner:"Bob")]
        let commit=CommitWindowController(repository:repo,access:nil,defaults:prefs),status=StatusWindowController(repository:repo,access:nil,defaults:prefs)
        defer {commit.close();status.close()}
        commit.window!.alphaValue=0;commit.window!.orderFront(nil);status.window!.alphaValue=0;status.window!.orderFront(nil)
        commit.model.queryLFSOwners={_ in locks};status.model.queryLFSOwners={_ in locks}
        commit.model.reload();status.model.reload();try await wait {!commit.model.busy && !status.model.busy}
        commit.model.setFileColumn(.lfsOwner,visible:true);status.model.setShowLFSOwners(true)
        try await wait {!commit.model.busy && !status.model.busy && commit.model.lfsOwnershipKnown && status.model.lfsOwnershipKnown}
        try require(commit.model.lfsOwners.count==2 && status.model.lfsOwners.count==2,"Owner query collapsed keys")
        for (path,name) in [(a,"Alice"),(b,"Bob")] {
            try require(commit.model.lfsOwners[path]==name && status.model.lfsOwners[path]==name,"Owner followed the wrong filename")
        }
        let entries=StatusEntry.parse(Data([a,b].map {" D \($0)\0"}.joined().utf8))
        try require(StatusListClipboard.text(entries,root:root,statistics:[:],copy:.column(.lfsOwner),lfsOwners:commit.model.lfsOwners)=="Alice\nBob\n","Owner clipboard merged exact keys")
        model.retire();let staleCopies=copied.count;model.copy(["new-a"],information:.relativePaths)
        try require(copied.count==staleCopies && LFSLocksWindowModel.activeOperations==0,"Retired LFS owner accepted work or leaked operation ownership")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==beforeIndex,"LFS family changed the index")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout;try require(afterHead==beforeHead,"LFS family changed HEAD")
        print("PASS: LFS exact checked paths/opaque IDs, native selection, owned menus, progress/Force receipts, incomplete/cancelled terminal effects and Commit/Working Tree ownership columns; private windows closed")
    }
}
