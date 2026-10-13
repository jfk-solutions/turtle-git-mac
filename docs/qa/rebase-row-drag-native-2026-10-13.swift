import AppKit
import TurtleGitCore

@main struct RebaseRowDragVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(description:"Row drag did not settle")
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
        model.options.preserveMerges=true; try require(model.beginRowDrag(current) != nil,"Preserve-merges drag unavailable"); model.options.preserveMerges=false
        model.busy=true; try require(model.beginRowDrag(current)==nil,"Busy drag allowed"); model.busy=false
        let retiredDrag=model.beginRowDrag(current)!
        owner.close(); try require(!model.dropRows(retiredDrag,before:5),"Closed owner applied retained drag")
        try await wait { RebaseWindowModel.activeColumnReads==0 }
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Plan drag modified HEAD/index")
        print("Rebase row drag: actual native insertion/finish, contiguous block/order/selection and reverse execution order, structural availability and no-op/discontinuous/busy/stale/closed refusal passed. Owned window closed; HEAD/index preserved.")
    }
}
