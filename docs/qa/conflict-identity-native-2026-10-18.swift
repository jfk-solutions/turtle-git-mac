import AppKit
import TurtleGitCore

struct ConflictIdentityVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Conflict identity native state did not settle")
    }
    @MainActor static func tables(_ view: NSView?) -> [NSTableView] {
        guard let view else { return [] }; return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables($0) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Conflict QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] { _ = try await repo.run(["config",key,value]) }
        let file = root.appendingPathComponent("ordinary")
        try Data("base\n".utf8).write(to:file);try await repo.stage(["ordinary"]);_ = try await repo.commit(message:"base")
        let base = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch","-c","upstream"]);try Data("upstream\n".utf8).write(to:file);try await repo.stage(["ordinary"]);_ = try await repo.commit(message:"upstream")
        _ = try await repo.run(["switch","-c","topic",base.hash]);try Data("topic\n".utf8).write(to:file);try await repo.stage(["ordinary"]);_ = try await repo.commit(message:"topic")
        var options = RebaseOptions();options.branch="topic";options.upstream="upstream"
        let editor = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        _ = try await repo.startRebase(try await repo.rebasePlan(options),editorExecutable:editor)
        let a="café\n.txt",b="cafe\u{301}\n.txt",paths=GitPathSet([a,b])
        var indexRecords=Data()
        for (position,path) in [a,b].enumerated() {
            for stage in 1...3 {
                let hash=try await repo.run(["hash-object","-w","--stdin"],input:Data("item\(position) stage\(stage)\n".utf8)).text.trimmingCharacters(in:.newlines)
                indexRecords.append(Data("100644 \(hash) \(stage)\t\(path)\0".utf8))
            }
        }
        _ = try await repo.run(["update-index","-z","--index-info"],input:indexRecords)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.ConflictIdentity."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"EnableLogCache")
        let owner=ResolveWindowController(repository:repo,access:nil,paths:[a,b],preferences:prefs),resolve=owner.model
        defer {owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil);resolve.load()
        try await wait {!resolve.busy && resolve.entries.count==2 && tables(owner.window?.contentView).first?.numberOfRows==2}
        try require(resolve.checked==paths && Set(resolve.entries.map {ResolveConflictRow(entry:$0).id}).count==2,"Resolve collapsed canonical peers")
        let table=tables(owner.window?.contentView).first!
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integersIn:0..<2))
        try await wait {resolve.selection==paths && resolve.nativeSelection.count==2}
        resolve.setFileChecked(a,value:false);try require(resolve.checked.isEmpty,"Resolve checkbox did not apply to both highlighted exact paths")
        resolve.selection=[b];resolve.setFileChecked(a,value:true)
        try require(resolve.checked==[a] && !resolve.checked.contains(b),"Unhighlighted checkbox changed its canonical peer")
        let menu=resolve.fileMenu([b],markedPath:b)
        try require(menu.entries.count==1 && Data(menu.paths[0].utf8)==Data(b.utf8) && Data(menu.mark.utf8)==Data(b.utf8),"Resolve menu retargeted canonical peer")
        var requested:[ConflictEntry]=[];resolve.confirm={_,items in requested=items}
        resolve.request(.theirs,ids:[b]);try require(requested.count==1 && Data(requested[0].path.utf8)==Data(b.utf8),"Resolve confirmation lost exact target");resolve.rejectConfirmation()
        resolve.load();try await wait {!resolve.busy}
        try require(resolve.checked==[a] && resolve.selection==[b],"Resolve refresh merged check/highlight memory")
        owner.close();resolve.withFileMenu(menu) { throwFailureMarker() }
        let replay=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=replay.model
        defer {replay.close()};replay.window!.alphaValue=0;replay.window!.orderFront(nil);model.load()
        try await wait {!model.busy && model.fileRecovery && model.conflicts.count==3}
        try require(model.conflictTableRows.filter {paths.contains($0.entry.path)}.count==2 && Set(model.conflictTableRows.map(\.id)).count==model.conflictTableRows.count,"Replay table lost distinct IDs")
        model.selectedConflicts=paths
        let ordinaryChecks=model.checkedConflicts.subtracting(paths)
        model.setConflictChecked(a,checked:false)
        try require(model.checkedConflicts==ordinaryChecks,"Replay checkbox missed selected peer or changed other rows")
        model.selectedConflicts=[b];model.setConflictChecked(a,checked:true)
        try require(model.checkedConflicts.contains(a) && !model.checkedConflicts.contains(b),"Replay checkbox inherited alias membership")
        let captured=model.conflictFileMenu([b],markedPath:b)
        try require(captured.rows.count==1 && captured.conflicts.count==1 && Data(captured.paths[0].utf8)==Data(b.utf8) && Data(captured.mark.utf8)==Data(b.utf8),"Replay menu retargeted canonical peer")
        model.refreshState();try await wait {!model.busy}
        try require(model.checkedConflicts.contains(a) && !model.checkedConflicts.contains(b) && model.selectedConflicts==[b],"Replay refresh merged independent checks/highlights")
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()};model.conflictPasteboard=board
        model.copyConflictFiles(model.conflictFileMenu([b]),copy:.relativePaths)
        try require(board.string(forType:.string).map {Data($0.utf8)}==Data((b+"\n").utf8),"Replay clipboard changed path spelling")
        replay.close()
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Conflict selection/menu reads changed index")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(after==head,"Conflict selection changed HEAD")
        _ = try await repo.abortRebase()
        print("PASS: exact Resolve/Rebase native row IDs, independent checked/highlighted canonical paths, source highlighted-checkbox rule, captured marked menu/confirmation, refresh memory, private clipboard, closed refusal and unchanged index/HEAD; owned windows closed")
    }
    static func throwFailureMarker() { preconditionFailure("Closed Resolve menu accepted") }
}
