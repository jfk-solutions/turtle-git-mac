import AppKit
import TurtleGitCore

@main struct RebaseConditionalVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool,_ message: String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(description:"Conditional Rebase columns did not settle")
    }
    @MainActor static func settle(_ owner:RebaseWindowController) async throws -> RebaseColumnLayout.Probe {
        var probe:RebaseColumnLayout.Probe?
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); probe=descendants(owner.window!.contentView!).compactMap { $0 as? RebaseColumnLayout.Probe }.first; probe?.configure(); return !owner.model.busy && !owner.model.loadingColumnMetadata && owner.model.entries.count==2 && probe?.table?.numberOfRows==2 }
        return probe!
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Rebase conditional failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Conditional QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        _ = try await repo.run(["commit","--allow-empty","-m","Issue #10 #2"])
        let records=try await repo.history(),hashes=records.map(\.hash)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.RebaseConditional.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let helper=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs); defer { owner.close() }
        let model=owner.model; model.readColumnMetadata={ try await repo.replayColumnMetadata($0,executable:helper,cancellation:$1) }
        model.load(cherryPick:hashes); let probe=try await settle(owner)
        try require(probe.headerMenu().item(withTitle:"Bug-ID")==nil && probe.headerMenu().item(withTitle:"SVN Rev")==nil,"Unconfigured columns exposed")
        _ = try await repo.run(["config","bugtraq.logregex","#([0-9]+)"])
        let metadata=root.appendingPathComponent(".git/svn/.metadata")
        try FileManager.default.createDirectory(at:metadata.deletingLastPathComponent(),withIntermediateDirectories:true); try Data().write(to:metadata)
        model.refreshColumnMetadata(force:true); _ = try await settle(owner)
        try require(model.showsIssueColumn && model.hasGitSVN && model.issueColumnValues[hashes[0]]=="2 10","Configured values or availability wrong")
        let menu=probe.headerMenu(); try require(menu.item(withTitle:"Bug-ID")?.state == .on && menu.item(withTitle:"SVN Rev")?.state == .on,"Source conditional defaults wrong")
        probe.toggle(menu.item(withTitle:"Bug-ID")!)
        try require(prefs.object(forKey:"Rebase.Columns.Visible.Bug-ID") as? Bool == false,"Conditional visibility not saved")
        _ = try await repo.run(["config","--unset","bugtraq.logregex"]); try FileManager.default.removeItem(at:metadata)
        model.refreshColumnMetadata(force:true); _ = try await settle(owner)
        try require(probe.headerMenu().item(withTitle:"Bug-ID")==nil && probe.headerMenu().item(withTitle:"SVN Rev")==nil && model.issueColumnValues.isEmpty,"Removed configuration retained columns/values")
        _ = try await repo.run(["config","bugtraq.logregex","#([0-9]+)"])
        model.refreshColumnMetadata(force:true); _ = try await settle(owner)
        try require(probe.headerMenu().item(withTitle:"Bug-ID")?.state == .off,"Availability change lost saved hidden choice")
        probe.resetLayout(); try require(probe.headerMenu().item(withTitle:"Bug-ID")?.state == .on,"Reset lost contextual default")
        let snapshot=try await repo.replayColumnMetadata(model.entries.map(\.commit),executable:helper)
        let gate=RebaseColumnGate(); model.readColumnMetadata={ _,token in try await gate.read(token) }
        model.refreshColumnMetadata(force:true)
        for _ in 0..<1000 { if await gate.ready { break }; try await Task.sleep(nanoseconds:1_000_000) }
        try require(await gate.ready,"Held metadata read did not start")
        owner.close(); try require(await gate.cancelled && RebaseWindowModel.activeColumnReads>0,"Close lost cancellation/Quit ownership")
        await gate.release(snapshot); try await wait { RebaseWindowModel.activeColumnReads==0 }
        try require(!model.loadingColumnMetadata,"Late reply revived closed loading state")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Metadata/layout altered HEAD/index")
        print("Rebase conditional: real Bug-ID configuration/values, SVN metadata availability, saved hidden/restored/default columns, forced-close cancellation and late reply/Quit accounting passed. Owned window closed; HEAD/index preserved.")
    }
}
actor RebaseColumnGate {
    var continuation:CheckedContinuation<ReplayColumnMetadata,Error>?
    var token:OperationCancellation?
    var ready:Bool { continuation != nil }
    var cancelled:Bool { token?.isCancelled == true }
    func read(_ token:OperationCancellation) async throws -> ReplayColumnMetadata { self.token=token; return try await withCheckedThrowingContinuation { continuation=$0 } }
    func release(_ result:ReplayColumnMetadata) { continuation?.resume(returning:result); continuation=nil }
}
