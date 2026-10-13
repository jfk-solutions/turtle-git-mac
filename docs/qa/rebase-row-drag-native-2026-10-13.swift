import AppKit
import TurtleGitCore

@main struct RebaseRowDragVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func wait(_ stage:String="Row drag",_ ready:()->Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(description:stage + " did not settle")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Rebase row drag failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Drag QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        for index in 1...4 { _ = try await repo.run(["commit","--allow-empty","-m","revision \(index)"]) }
        let hashes=try await repo.history().map(\.hash), head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.RebaseDrag.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs); defer { owner.close() }
        let model=owner.model; model.load(cherryPick:hashes)
        var probe:RebaseListInteraction.Probe?, table:NSTableView?
        try await wait {
            owner.window!.contentView!.layoutSubtreeIfNeeded()
            probe=descendants(owner.window!.contentView!).compactMap { $0 as? RebaseListInteraction.Probe }.first
            table=descendants(owner.window!.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.count==12 }
            return !model.busy && !model.loadingColumnMetadata && model.entries.count==5 && table?.numberOfRows==5 && probe != nil
        }
        let native=table!, interaction=probe!, original=model.entries.map(\.id), selected=Set(original[1...2])
        try require(interaction.beginDrag(in:native,ids:selected),"Contiguous drag not accepted")
        let end=native.rect(ofRow:4)
        try require(interaction.updateDrag(at:NSPoint(x:native.visibleRect.midX,y:end.maxY-2)) && interaction.dropIndex==5,"End insertion marker missing")
        try require(interaction.finishDrag(),"Drag finish rejected")
        try require(model.entries.map(\.id)==[original[0],original[3],original[4],original[1],original[2]] && model.selection==selected,"Display order or selection changed incorrectly")
        try require(model.plan?.entries.map(\.id)==model.entries.reversed().map(\.id),"Execution order did not reverse display")
        try require(!interaction.beginDrag(in:native,ids:[model.entries[0].id,model.entries[2].id]),"Discontinuous drag allowed")
        try await wait { native.layoutSubtreeIfNeeded(); return native.numberOfRows==5 }
        let current=Set([model.entries[0].id])
        try require(interaction.beginDrag(in:native,ids:current),"Second drag not accepted")
        let first=native.rect(ofRow:0)
        try require(!interaction.updateDrag(at:NSPoint(x:native.visibleRect.midX,y:first.midY)) && !interaction.finishDrag(),"Source no-op span allowed")
        let drag=model.beginRowDrag(current)!
        model.setAction(.edit,ids:current); try require(!model.dropRows(drag,before:5),"Changed action reused a stale drag")
        model.options.preserveMerges=true; try require(model.beginRowDrag(current) != nil,"Preserve-merges drag unavailable")
        model.setAction(.skip,ids:current); try require(model.entries.first { current.contains($0.id) }?.action == .skip,"Structural Skip unavailable")
        model.setAction(.edit,ids:current); try require(model.entries.first { current.contains($0.id) }?.action == .edit,"Structural Edit unavailable")
        model.setAction(.squash,ids:current); try require(model.entries.first { current.contains($0.id) }?.action == .squash,"Structural Squash unavailable")
        model.cycleActions(); try require(model.entries.first { current.contains($0.id) }?.action == .pick,"Structural cycle Squash to Pick failed")
        model.cycleActions(); try require(model.entries.first { current.contains($0.id) }?.action == .skip,"Structural cycle Pick to Skip failed")
        model.cycleActions(); try require(model.entries.first { current.contains($0.id) }?.action == .edit,"Structural cycle Skip to Edit failed")
        model.options.preserveMerges=false
        model.busy=true; try require(model.beginRowDrag(current)==nil,"Busy drag allowed"); model.busy=false
        let retiredDrag=model.beginRowDrag(current)!
        owner.close(); try require(!model.dropRows(retiredDrag,before:5),"Closed owner applied retained drag")
        try await wait { RebaseWindowModel.activeColumnReads==0 }
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Plan drag modified HEAD/index")
        let replayRoot=root.appendingPathComponent("merge-edit-qa"); try FileManager.default.createDirectory(at:replayRoot,withIntermediateDirectories:true)
        let replay=GitRepository(root:replayRoot,executable:repo.executable)
        _ = try await replay.run(["init","-b","main"])
        for (key,value) in [("user.name","Merge Edit QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await replay.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:replayRoot.appendingPathComponent("base")); try await replay.stage(["base"]); _ = try await replay.commit(message:"base")
        _ = try await replay.run(["checkout","-b","upstream"])
        _ = try await replay.run(["commit","--allow-empty","-m","upstream"])
        _ = try await replay.run(["checkout","-b","side","main"])
        try Data("side\n".utf8).write(to:replayRoot.appendingPathComponent("side")); try await replay.stage(["side"]); _ = try await replay.commit(message:"side")
        _ = try await replay.run(["checkout","-b","topic","main"])
        try Data("topic\n".utf8).write(to:replayRoot.appendingPathComponent("topic")); try await replay.stage(["topic"]); _ = try await replay.commit(message:"topic")
        _ = try await replay.run(["merge","--no-ff","--no-edit","side"])
        let merge=try await replay.rebaseCommit("HEAD")
        var options=RebaseOptions(); options.branch="topic"; options.upstream="upstream"; options.preserveMerges=true
        var plan=try await replay.rebasePlan(options); plan.entries[plan.entries.firstIndex { $0.commit.hash==merge.hash }!].action = .edit
        let paused=try await replay.startRebase(plan,editorExecutable:URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_EDITOR"] ?? FileManager.default.currentDirectoryPath + "/build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac"))
        try require(paused.state.isStructuralMergeEdit,"Native receiver merge Edit did not pause: " + paused.output)
        let resumed=RebaseWindowController(repository:replay,access:nil,preferences:prefs); defer { resumed.close() }
        resumed.model.load(upstream:"upstream",preserveMerges:true)
        try await wait { !resumed.model.busy && resumed.model.state?.isStructuralMergeEdit==true }
        try require(resumed.model.tab==1 && resumed.model.amendMessage.contains("Merge") && resumed.model.canSplit,"Native recovery message or merge Split guard incorrect")
        var mergeSplitDialog: CommitWindowModel?
        resumed.model.configureCommitSelection = { mergeSplitDialog = $0; $0.confirmCancel = { $0(true) } }
        resumed.model.beginSplitSelection()
        try await wait("Merge Split load") { mergeSplitDialog?.entries.isEmpty == false && mergeSplitDialog?.busy == false }
        try require(mergeSplitDialog?.amend == true && mergeSplitDialog?.amendDiffToLastCommit == false,"Merge Split did not open the first-parent comparison/amend dialog")
        let beforeCancel = try await replay.rebaseCommit("HEAD")
        mergeSplitDialog!.cancel()
        try await wait("Merge Split Cancel") { !resumed.model.busy && !resumed.model.selectingSplit }
        try require(resumed.model.state?.split == nil && resumed.model.state?.isStructuralMergeEdit == true,"Cancel did not restore merge Edit")
        let afterCancel = try await replay.rebaseCommit("HEAD")
        try require(afterCancel.hash==beforeCancel.hash && afterCancel.parents.count==2,"Merge Split Cancel changed topology")
        resumed.model.amendMessage="native edited merge"; resumed.model.execute("continue")
        try await wait { !resumed.model.busy && resumed.model.finished }
        try require(resumed.model.error==nil && resumed.model.completedSuccessfully,"Native merge Edit Continue failed")
        let edited=try await replay.rebaseCommit("HEAD"); try require(edited.subject=="native edited merge" && edited.parents.count==2,"Native edit lost message or topology")
        resumed.close(); try await wait { RebaseWindowModel.activeColumnReads==0 }
        try Data("child\n".utf8).write(to:replayRoot.appendingPathComponent("child")); try await replay.stage(["child"]); _ = try await replay.commit(message:"squash child")
        options.force=true
        var squashPlan=try await replay.rebasePlan(options); squashPlan.entries[squashPlan.entries.count-1].action = .squash
        let squashPaused=try await replay.startRebase(squashPlan,editorExecutable:URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_EDITOR"] ?? FileManager.default.currentDirectoryPath + "/build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac"))
        try require(squashPaused.state.squashMessage != nil,"Native structural Squash did not request review: " + squashPaused.output)
        let grouped=RebaseWindowController(repository:replay,access:nil,preferences:prefs); defer { grouped.close() }
        grouped.model.load(upstream:"upstream",preserveMerges:true)
        try await wait { !grouped.model.busy && grouped.model.state?.squashMessage != nil }
        try require(grouped.model.canSplit && grouped.model.tab==1 && grouped.model.amendMessage.contains("native edited merge") && grouped.model.amendMessage.contains("squash child"),"Native Squash group messages not recovered")
        var groupSplitDialog: CommitWindowModel?
        grouped.model.configureCommitSelection = { groupSplitDialog = $0; $0.confirmCancel = { $0(true) } }
        grouped.model.beginSplitSelection()
        try await wait("Group Split load") { groupSplitDialog?.entries.isEmpty == false && groupSplitDialog?.busy == false }
        groupSplitDialog!.cancel()
        try await wait("Group Split Cancel") { !grouped.model.busy && !grouped.model.selectingSplit }
        try require(grouped.model.state?.squashMessage != nil && grouped.model.state?.split == nil,"Group Split Cancel lost pending message review")
        grouped.model.amendMessage="native approved structural group"; grouped.model.execute("continue")
        try await wait { !grouped.model.busy && grouped.model.finished }
        let combined=try await replay.rebaseCommit("HEAD")
        try require(grouped.model.completedSuccessfully && combined.subject=="native approved structural group" && combined.parents.count==2,"Native structural Squash approval lost topology/message")
        grouped.close(); try await wait { RebaseWindowModel.activeColumnReads==0 }

        print("Rebase row drag: actual native insertion/finish, contiguous block/order/selection and reverse execution order, structural Pick/Skip/Edit/Squash/cycle guards and no-op/discontinuous/busy/stale/closed refusal passed. Owned windows closed; plan HEAD/index preserved; actual merge Edit/Squash recovery/Continue and topology passed.")
    }
}
