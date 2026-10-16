import AppKit
import TurtleGitCore

@main struct LogCanonicalIntegrationVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Canonical integration timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Canonical integration failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.warnAmbiguousRefs","true")] { _ = try await repo.run(["config",key,value]) }
        for message in ["base","tag commit","head"] {
            try Data((message + "\n").utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:message)
        }
        var rows = try await repo.history(options:HistoryOptions())
        try require(rows.count == 3,"Fixture must have three distinct commits")
        let branchHash = rows[2].hash, tagHash = rows[1].hash
        _ = try await repo.run(["update-ref","refs/heads/topic",branchHash]); _ = try await repo.run(["update-ref","refs/tags/topic",tagHash])
        rows[2].references = [.init(name:"refs/heads/topic")]; rows[1].references = [.init(name:"refs/tags/topic")]
        let beforeHead = try await repo.run(["rev-parse","HEAD"]).stdout, beforeIndex = try await repo.run(["write-tree"]).stdout, beforeStatus = try await repo.run(["status","--porcelain=v1","-z"]).stdout
        let suite = "TurtleGit.LogCanonicalIntegration." + UUID().uuidString
        guard let prefs = UserDefaults(suiteName:suite) else { throw Failure(description:"Private preferences unavailable") }
        defer { prefs.removePersistentDomain(forName:suite) }
        let log = LogWindowModel(repository:repo,access:nil,labelDefaults:prefs)
        log.graph = CommitGraph.layout(rows); log.entries = rows; log.selected = [branchHash]; log.bare = try await repo.isBare()
        let workspace = RepositoryModel(startMonitoring:false,initializePreferences:false)
        workspace.configureLogIntegration(log,repository:repo,access:nil)
        try require(log.onPreparedRebase != nil && log.canIntegrate(.rebase),"Repository adapter did not install canonical handoff")
        let rebase = RebaseWindowController(repository:repo,access:nil,preferences:prefs), merge = MergeWindowController(repository:repo,access:nil,preferences:prefs)
        defer { log.invalidate(); rebase.model.retire(); rebase.close(); merge.model.invalidate(); merge.close() }
        var prepared: LogIntegrationPreparation?, legacyCalls = 0
        log.onRebaseRevision = { _ in legacyCalls += 1 }
        log.onPreparedRebase = { value in prepared = value; rebase.model.load(upstream:value.canonicalRevision) }
        log.requestIntegration(.rebase)
        try await wait { prepared != nil && !log.busy && LogWindowModel.activeReferenceReads == 0 && !rebase.model.busy && !rebase.model.loadingPlan && RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 }
        try require(prepared?.revision == "topic" && prepared?.reference == "refs/heads/topic" && legacyCalls == 0,"Typed handoff lost local branch identity or dispatched twice")
        try require(rebase.model.error == nil && rebase.model.options.upstream == "refs/heads/topic" && rebase.model.plan?.upstreamHash == branchHash,"Native Rebase resolved the same-named tag: \(rebase.model.error ?? "no error")")
        let ambiguous = try await repo.rebaseCommit("topic")
        try require(ambiguous.hash == tagHash,"Typed revisions must retain Git's own resolution while excluding warning text")
        merge.model.load(revision:"refs/tags/topic")
        try await wait { !merge.model.busy }
        try require(merge.model.error == nil && merge.model.target == .tag && merge.model.revision == "refs/tags/topic","Merge lost canonical tag choice")
        rebase.model.chooseUpstream("refs/tags/topic")
        try await wait { !rebase.model.loadingPlan && RebaseWindowModel.activePreparationReads == 0 }
        try require(rebase.model.options.upstream == "refs/tags/topic" && rebase.model.plan?.upstreamHash == tagHash,"Rebase dropdown did not keep distinct tag")
        rebase.model.chooseUpstream("refs/heads/topic")
        try await wait { !rebase.model.loadingPlan && RebaseWindowModel.activePreparationReads == 0 }
        try require(rebase.model.plan?.upstreamHash == branchHash,"Returning to branch reused tag plan")
        log.selected = [tagHash]; prepared = nil; log.requestIntegration(.rebase)
        try await wait { prepared != nil && !log.busy && !rebase.model.busy && !rebase.model.loadingPlan && LogWindowModel.activeReferenceReads == 0 && RebaseWindowModel.activePreparationReads == 0 }
        try require(prepared?.canonicalRevision == "refs/tags/topic" && rebase.model.plan?.upstreamHash == tagHash,"Tag-only Log selection changed namespace")
        log.entries[2].references = []; log.selected = [branchHash]; prepared = nil; log.requestIntegration(.rebase)
        try await wait { prepared != nil && !log.busy && !rebase.model.busy && !rebase.model.loadingPlan && LogWindowModel.activeReferenceReads == 0 && RebaseWindowModel.activePreparationReads == 0 }
        try require(prepared?.canonicalRevision == branchHash && rebase.model.options.upstream == branchHash && rebase.model.plan?.upstreamHash == branchHash,"Unlabelled selection lost exact commit")
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterIndex = try await repo.run(["write-tree"]).stdout, afterStatus = try await repo.run(["status","--porcelain=v1","-z"]).stdout
        try require(beforeHead == afterHead && beforeIndex == afterIndex && beforeStatus == afterStatus,"Options preparation mutated repository")
        print("PASS: canonical Log branch/tag/hash handoff, typed callback precedence, native Merge/Rebase selectors and warning-safe identity; HEAD/index/worktree preserved; owned windows closed.")
    }
}
