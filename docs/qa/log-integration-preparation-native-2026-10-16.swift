import AppKit
import TurtleGitCore

@main struct LogIntegrationPreparationVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(_ stage:String,_ ready:()->Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Log integration timeout: " + stage)
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Log integration preparation failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        let baseHash = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        for ref in ["refs/heads/topic","refs/tags/release","refs/remotes/origin/topic"] { _ = try await repo.run(["update-ref",ref,baseHash]) }
        try Data("head\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"head")
        var rows = try await repo.history(options:HistoryOptions())
        try require(rows.count == 2,"Fixture history differs")
        let head = rows[0].hash
        rows[1].references = [.init(name:"refs/tags/release"),.init(name:"refs/heads/topic"),.init(name:"refs/remotes/origin/topic")]
        let index = try await repo.run(["write-tree"]).stdout, status = try await repo.run(["status","--porcelain=v1","-z"]).stdout
        let suite = "TurtleGit.LogIntegrationPreparation." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let model = LogWindowModel(repository:repo,access:nil,labelDefaults:prefs)
        model.graph = CommitGraph.layout(rows); model.entries = rows; model.selected = [baseHash]; model.bare = try await repo.isBare()
        var merges:[String] = [], rebases:[String] = []
        model.onMergeRevision = { merges.append($0) }; model.onRebaseRevision = { rebases.append($0) }
        defer { model.invalidate() }
        func settle() async throws { try await wait("settle") { !model.busy && LogWindowModel.activeReferenceReads == 0 } }
        model.requestIntegration(.merge); try await settle()
        try require(merges == ["refs/tags/release"],"Merge did not use first captured reference: targets=\(merges), error=\(model.error ?? "none")")
        model.requestIntegration(.rebase); try await settle()
        try require(rebases == ["topic"],"Rebase did not prefer short local branch name")
        let pointed = LogReferenceMenuTarget(hash:baseHash,name:"refs/remotes/origin/topic")
        model.requestIntegration(.merge,target:pointed); try await settle()
        try require(merges.last == pointed.name,"Pointed Merge lost canonical reference")
        let mergeCount = merges.count, rebaseCount = rebases.count
        _ = try await repo.run(["update-ref","refs/tags/release",head])
        model.requestIntegration(.merge); try await settle()
        try require(merges.count == mergeCount && model.error?.contains("reference changed") == true,"Moved first ref fell through to another label/hash")
        model.requestIntegration(.rebase); try await settle()
        try require(rebases.count == rebaseCount + 1 && rebases.last == "topic","Moved nonpreferred tag blocked valid local Rebase")
        _ = try await repo.run(["update-ref","refs/heads/topic",head])
        model.requestIntegration(.rebase); try await settle()
        try require(rebases.count == rebaseCount + 1 && model.error?.contains("reference changed") == true,"Moved preferred local ref fell through to remote/hash")
        for ref in ["refs/heads/topic","refs/tags/release"] { _ = try await repo.run(["update-ref",ref,baseHash]) }
        model.entries[1].references = []
        model.requestIntegration(.merge); try await settle(); model.requestIntegration(.rebase); try await settle()
        try require(merges.last == baseHash && rebases.last == baseHash,"Unlabelled commit did not retain hash target")
        model.entries = rows
        // Real native option models consume the exact prepared presets without mutating Git.
        let merge = MergeWindowController(repository:repo,access:nil,preferences:prefs)
        let rebase = RebaseWindowController(repository:repo,access:nil,preferences:prefs)
        defer { merge.model.invalidate(); merge.close(); rebase.model.retire(); rebase.close() }
        merge.model.load(revision:merges[0]); rebase.model.load(upstream:"topic")
        try await wait("native presets") { !merge.model.busy && !rebase.model.busy }
        try require(merge.model.error == nil && merge.model.target == .tag && merge.model.revision == "refs/tags/release","Native Merge preset differs")
        try require(rebase.model.error == nil && rebase.model.options.upstream == "topic","Native Rebase preset differs")
        merge.close(); rebase.close()
        var held:CheckedContinuation<String,Error>?, readToken:OperationCancellation?, reads = 0
        model.readIntegration = { preparation,token in
            reads += 1; readToken = token
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        let before = merges.count
        model.requestIntegration(.merge); try await wait("held read") { held != nil }
        try require(model.busy && LogWindowModel.activeReferenceReads == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Preparation lost busy/Quit ownership")
        model.requestIntegration(.rebase); try require(reads == 1,"Duplicate preparation started")
        model.select([head]); model.select([baseHash])
        try require(readToken?.isCancelled == true,"Selection change did not cancel preparation")
        held?.resume(returning:"refs/tags/release"); held = nil; try await settle()
        try require(merges.count == before && model.error == nil,"Selection-away/return revived old handoff")
        // A child callback can own a newer busy state; old read cleanup must not clear it.
        model.readIntegration = nil; model.onMergeRevision = { merges.append($0); model.busy = true }
        model.requestIntegration(.merge); try await wait("handoff cleanup") { LogWindowModel.activeReferenceReads == 0 }
        try require(model.busy && merges.count == before + 1,"Old preparation cleared callback-owned busy state")
        model.busy = false; model.onMergeRevision = { merges.append($0) }
        // Native Log close asks cancellation and closes only when its owned read settles.
        let owner = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false)
        defer { owner.model.invalidate(); owner.close() }
        owner.window?.contentView?.layoutSubtreeIfNeeded(); owner.model.reload()
        try await wait("native Log history ready") { !owner.model.busy && !owner.model.loadingHistory && owner.model.entries.contains { $0.hash == baseHash } }
        owner.model.selected = [baseHash]; owner.model.onMergeRevision = { _ in throwawayHandoff = true }
        try require(owner.model.canIntegrate(.merge),"Native Log preparation unavailable after history load: " + (owner.model.error ?? "none"))
        var ownerHeld:CheckedContinuation<String,Error>?, ownerToken:OperationCancellation?, deferredClose = 0
        owner.model.readIntegration = { _,token in ownerToken = token; return try await withCheckedThrowingContinuation { ownerHeld = $0 } }
        let originalClose = owner.model.close; owner.model.close = { deferredClose += 1; originalClose() }
        owner.model.requestIntegration(.merge); try await wait("owner held read") { ownerHeld != nil }
        try require(!owner.windowShouldClose(owner.window!) && ownerToken?.isCancelled == true,"Native close did not wait/cancel read")
        ownerHeld?.resume(returning:"refs/tags/release"); ownerHeld = nil
        try await wait("deferred native close") { LogWindowModel.activeReferenceReads == 0 && deferredClose == 1 }
        try require(!throwawayHandoff,"Cancelled close opened a child")
        // Forced retirement retains Quit accounting until even an uncooperative read returns.
        model.readIntegration = { _,token in readToken = token; return try await withCheckedThrowingContinuation { held = $0 } }
        model.requestIntegration(.merge); try await wait("retirement read") { held != nil }
        let beforeRetire = merges.count; model.invalidate()
        try require(readToken?.isCancelled == true && LogWindowModel.activeReferenceReads == 1,"Retirement lost cancellation/read accounting")
        held?.resume(returning:"refs/tags/release"); held = nil
        try await wait("retired settlement") { LogWindowModel.activeReferenceReads == 0 }
        try require(merges.count == beforeRetire && !model.canIntegrate(.merge),"Retired handoff escaped")
        try require(try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines) == head,"Preparation changed HEAD")
        let finalIndex = try await repo.run(["write-tree"]).stdout, finalStatus = try await repo.run(["status","--porcelain=v1","-z"]).stdout
        try require(finalIndex == index && finalStatus == status,"Preparation changed index/status")
        print("PASS: source first-reference Merge/local-preferred Rebase, canonical pointer/hash targets, moved-ref refusal without fallback, actual native presets, cancellable owned reads/Quit/duplicate/selection/close/retirement fences and callback busy ownership; HEAD/index/status preserved and owned windows closed")
    }
    @MainActor static var throwawayHandoff = false
}
