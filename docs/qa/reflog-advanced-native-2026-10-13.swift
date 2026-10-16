import AppKit
import TurtleGitCore

actor RefLogCombineGate {
    var continuation:CheckedContinuation<ReferenceLogCombineCandidate?,Error>?
    var token:OperationCancellation?
    func read(_ token:OperationCancellation) async throws -> ReferenceLogCombineCandidate? { self.token=token; return try await withCheckedThrowingContinuation { continuation=$0 } }
    func release(_ value:ReferenceLogCombineCandidate?) { continuation?.resume(returning:value); continuation=nil }
}
@main struct RefLogAdvancedVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(_ ready:()->Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(description:"RefLog advanced did not settle") }
    @MainActor static func table(_ view:NSView)->ReferenceLogTableView? { (view as? ReferenceLogTableView) ?? view.subviews.compactMap(table).first }
    @MainActor static func invoke(_ item:NSMenuItem) throws { guard item.isEnabled,let action=item.action else { throw Failure(description:"Disabled advanced action") }; try require(NSApp.sendAction(action,to:item.target,from:item),"Advanced action did not dispatch") }
    @MainActor static func main() async { do { try await verify() } catch { fputs("RefLog advanced failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        let suite="TurtleGit.RefLogAdvanced.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Advanced QA"),("user.email","advanced@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        try Data("source\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"Base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["commit","--allow-empty","-m","Middle"])
        let middle=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines); _ = try await repo.run(["branch","middle",middle])
        _ = try await repo.run(["commit","--allow-empty","-m","Newest"])
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let owner=ReferenceLogWindowController(repository:repo,access:nil,reference:"HEAD",preferences:prefs); defer { owner.close() }
        let model=owner.model; var combined:[LogEntry]=[],offset:Int?,combinedHead="",bisect:ReferenceLogBisectRequest?
        model.onCombineRevisions={ combined=$0;offset=$1;combinedHead=$2 }; model.onBisect={bisect=$0}; model.reload()
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); return !model.busy && table(owner.window!.contentView!)?.numberOfRows == 3 }
        let native=table(owner.window!.contentView!)!
        native.selectRowIndexes(IndexSet([0,1]),byExtendingSelection:false)
        try await wait { model.combineCandidate != nil }
        let candidate=model.combineCandidate!
        let menu=native.owner!.menu(),combine=menu.item(withTitle:"Combine to one commit")!,start=menu.item(withTitle:LogBisectCommand.start.title)!
        try require(combine.image != nil && start.image != nil,"Advanced source icons missing")
        try invoke(combine);try require(combined.map(\.hash)==[head,middle] && offset==0 && combinedHead==head,"Combine lost source span")
        try invoke(native.owner!.menu().item(withTitle:LogBisectCommand.start.title)!);try await wait { !model.busy && bisect != nil }
        try require(bisect?.good=="refs/heads/middle" && bisect?.bad=="refs/heads/main" && bisect?.operation==nil,"Bisect Start presets changed")
        let after=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Review handoff mutated Git")
        _ = try await repo.startBisect(good:base,bad:head)
        model.reload();try await wait { !model.busy && model.bisectActive }
        let middleRow=model.entries.firstIndex { $0.hash==middle }!; native.selectRowIndexes(IndexSet(integer:middleRow),byExtendingSelection:false)
        try require(model.bisectAvailable(.good,ids:model.selection) && model.bisectAvailable(.bad,ids:model.selection) && model.bisectAvailable(.skip,ids:model.selection),"Active bisect choices missing")
        bisect=nil;try invoke(native.owner!.menu().item(withTitle:LogBisectCommand.good.title)!);try await wait { !model.busy && bisect != nil }
        try require(bisect?.operation == .good && bisect?.revisions==[middle],"Bisect Good redirected selected revision")
        let badRow=model.entries.firstIndex { $0.hash==head }!;native.selectRowIndexes(IndexSet(integer:badRow),byExtendingSelection:false)
        try require(!model.bisectAvailable(.good,ids:model.selection) && !model.bisectAvailable(.skip,ids:model.selection),"Marked bisect row remained eligible")
        _ = try await repo.bisect(.reset)
        model.reload();try await wait { !model.busy }
        let gate=RefLogCombineGate();model.readCombineCandidate={_,_,_,token in try await gate.read(token)}
        let rows=IndexSet(model.entries.indices.filter { $0>=0 && $0<2 });native.selectRowIndexes(rows,byExtendingSelection:false)
        while await gate.continuation == nil { try await Task.sleep(nanoseconds:1_000_000) }
        owner.window!.close();try require(await gate.token?.isCancelled==true && ReferenceLogWindowModel.activeRevisionReads>0,"Retired Combine read lost cancellation/accounting")
        await gate.release(candidate);try await wait { ReferenceLogWindowModel.activeRevisionReads==0 }
        try require(model.combineCandidate==nil,"Late Combine candidate revived closed model")
        print("RefLog advanced: source Combine span/icon/metadata, Bisect Start defaults and active Good/Bad/Skip/marked gates, review-only callbacks and forced-close ancestry reader cancellation passed. Owned windows closed; explicit fixture Bisect session reset.")
    }
}
