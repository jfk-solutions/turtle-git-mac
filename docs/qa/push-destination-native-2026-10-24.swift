// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct PushDestinationVerification {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Push destination workflow timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2]), scenario = CommandLine.arguments[3]
        let suite = "TurtleGit.PushDestination.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let client = root.appendingPathComponent("client"), bare = root.appendingPathComponent("remote.git")
        for directory in [client,bare] { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
        let repo = GitRepository(root:client,executable:git), remote = GitRepository(root:bare,executable:git)
        _ = try await repo.run(["init","-b","main"]); _ = try await remote.run(["init","--bare"])
        for (key,value) in [("user.name","Push destination QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let file = client.appendingPathComponent("file")
        try Data("base\n".utf8).write(to:file); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        let first = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("second\n".utf8).write(to:file); try await repo.stage(["file"]); _ = try await repo.commit(message:"second")
        let second = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["remote","add","origin",bare.path])
        _ = try await repo.run(["push","--","origin","refs/heads/main:refs/heads/main"])
        _ = try await remote.run(["update-ref","refs/tags/release",first])
        let index = try Data(contentsOf:client.appendingPathComponent(".git/index"))
        let config = try Data(contentsOf:client.appendingPathComponent(".git/config"))
        var owners:[PushWindowModel] = []
        defer { owners.forEach { $0.invalidate() } }
        func make() async throws -> PushWindowModel {
            let owner = PushWindowModel(repository:repo,access:nil,preferences:prefs)
            owners.append(owner); owner.clipboardText = { nil }; owner.load()
            try await wait { !owner.busy && !owner.preparing }
            precondition(owner.error == nil)
            owner.options.setUpstream = false; owner.options.remote = "origin"
            return owner
        }
        func perform(_ owner:PushWindowModel,success:Bool,confirmed:Bool=false) async throws -> PushProgressWindowModel {
            var progress:PushProgressWindowModel?, reports = 0, successes = 0
            owner.onProgress = { progress = $0 }
            owner.onTransportResult = { [weak owner] _,value in precondition(owner?.transportRunning == false && value == success); reports += 1 }
            owner.onPushed = { _ in successes += 1 }
            owner.push(confirmed:confirmed)
            try await wait { progress?.busy == false && owner.pendingOperations == 0 }
            precondition(reports == 1 && successes == (success ? 1:0) && progress!.success == success)
            precondition(owner.busy && owner.progress === progress && !owner.transportRunning)
            precondition(progress!.options.destination == owner.options.destination)
            return progress!
        }
        if scenario == "namespace" {
            let update = try await make()
            update.options.source = "main"; update.options.destination = "release"; update.options.force = true
            let result = try await perform(update,success:true)
            let received = try await remote.run(["rev-parse","refs/tags/release"]).text.trimmingCharacters(in:.newlines)
            precondition(received == second && result.output.contains("release"))
            let refs = try await remote.checkoutReferences(); precondition(!refs.contains { $0.name == "refs/heads/release" })
            precondition(prefs.stringArray(forKey:update.destinationHistoryKey)?.first == "release")
            precondition(prefs.string(forKey:"Push." + client.path + ".remote") == "origin")
            update.finish(result)

            _ = try await remote.run(["update-ref","refs/heads/release",first])
            let ambiguous = try await make()
            ambiguous.options.source = "main"; ambiguous.options.destination = "release"; ambiguous.options.force = true
            let failed = try await perform(ambiguous,success:false)
            precondition(!failed.output.isEmpty && failed.postActions.contains(.push))
            let unchanged = try await remote.run(["rev-parse","refs/heads/release"]).text.trimmingCharacters(in:.newlines)
            precondition(unchanged == first)
            ambiguous.finish(failed)

            let hash = try await make(); hash.chooseSourceRevision(first)
            try await wait { !hash.preparing }
            precondition(hash.localBranch == nil && hash.canTrack && hash.canSave)
            hash.options.destination = "new-from-hash"
            let rejected = try await perform(hash,success:false)
            precondition(!rejected.output.isEmpty)
            hash.finish(rejected)
            let qualified = try await make(); qualified.chooseSourceRevision(first)
            try await wait { !qualified.preparing }
            qualified.options.destination = "refs/heads/new-from-hash"
            qualified.options.savePushRemote = true; qualified.options.savePushBranch = true
            precondition(qualified.canSave)
            let accepted = try await perform(qualified,success:true)
            let hashReceived = try await remote.run(["rev-parse","refs/heads/new-from-hash"]).text.trimmingCharacters(in:.newlines)
            let savedConfig = try Data(contentsOf:client.appendingPathComponent(".git/config"))
            precondition(hashReceived == first && savedConfig == config)
            qualified.finish(accepted)
        } else {
            let deletion = try await make()
            let remoteKey = "Push." + client.path + ".remote"
            prefs.set("previous-choice",forKey:remoteKey)
            prefs.set(["previous-destination"],forKey:deletion.destinationHistoryKey)
            prefs.set(["previous-url"],forKey:deletion.urlHistoryKey)
            deletion.options.source = ""; deletion.sourceChanged(); deletion.options.destination = "release"
            precondition(!deletion.canTrack && !deletion.canSave)
            var answers:[(Bool,Bool)->Void] = []
            deletion.confirmPush = { _,all,remove,choose in precondition(!all && remove); answers.append(choose) }
            deletion.push(); precondition(answers.count == 1 && !deletion.busy)
            answers.removeFirst()(false,false)
            precondition(deletion.confirmation == nil && prefs.string(forKey:remoteKey) == "previous-choice")
            deletion.push(); precondition(answers.count == 1)
            // A captured confirmation cannot authorize a newly edited target.
            deletion.options.destination = "refs/tags/other"; answers.removeFirst()(true,false)
            precondition(!deletion.busy && deletion.confirmation == nil)
            deletion.options.destination = "release"
            deletion.confirmPush = { _,all,remove,choose in precondition(!all && remove); choose(true,false) }
            let result = try await perform(deletion,success:true)
            let refs = try await remote.checkoutReferences(); precondition(!refs.contains { $0.name == "refs/tags/release" })
            precondition(prefs.string(forKey:remoteKey) == "previous-choice")
            precondition(prefs.stringArray(forKey:deletion.destinationHistoryKey) == ["previous-destination"] && prefs.stringArray(forKey:deletion.urlHistoryKey) == ["previous-url"])
            deletion.finish(result)

            _ = try await remote.run(["update-ref","refs/tags/release",first])
            let retired = try await make(); retired.options.source = ""; retired.sourceChanged(); retired.options.destination = "refs/tags/release"
            var late:((Bool,Bool)->Void)?
            retired.confirmPush = { _,_,_,reply in late = reply }
            retired.push(); precondition(late != nil); retired.invalidate(); late?(true,false)
            precondition(retired.closed && !retired.transportRunning)
            let kept = try await remote.run(["rev-parse","refs/tags/release"]).text.trimmingCharacters(in:.newlines); precondition(kept == first)

            let all = try await make(); all.options.allBranches = true
            all.confirmPush = { _,branches,remove,reply in precondition(branches && !remove); reply(true,false) }
            let allResult = try await perform(all,success:true)
            precondition(prefs.string(forKey:remoteKey) == "previous-choice")
            precondition(prefs.stringArray(forKey:all.destinationHistoryKey) == ["previous-destination"])
            all.finish(allResult)
        }
        owners.forEach { $0.invalidate() }
        try await wait { owners.allSatisfy { $0.pendingOperations == 0 } }
        let head = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let afterIndex = try Data(contentsOf:client.appendingPathComponent(".git/index")), afterFile = try Data(contentsOf:file)
        precondition(head == second && afterIndex == index)
        precondition(afterFile == Data("second\n".utf8))
        precondition(PushWindowModel.activePushWorkflows == 0 && PushWindowModel.activePreparationReads == 0)
        print("PASS: Push destination native " + scenario)
    }
}
