import AppKit
import TurtleGitCore

@main struct IgnoreWorkflowVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timed out at \(line)")
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS Ignore workflow: real captured rules/Keep Yes/No, per-path failure Continue/Abort and actual summary count, rejected/retired owned sheets and stale answers, retry, writer retirement/Quit accounting, retained HEAD/unrelated index/working bytes") }
        catch { fputs("FAIL Ignore workflow: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Ignore Workflow QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repository.run(["config",key,value]) }
        for path in ["keep.txt","remove.txt","after-error.txt","abort-next.txt","unrelated.txt"] { try Data(path.utf8).write(to: root.appendingPathComponent(path)) }
        try await repository.stage(["."]); _ = try await repository.run(["commit","-m","base"])
        try Data("retained staged".utf8).write(to: root.appendingPathComponent("unrelated.txt")); try await repository.stage(["unrelated.txt"])
        let retained = try await repository.run(["ls-files","--stage","-z","--","unrelated.txt"]).stdout, head = try await repository.run(["rev-parse","HEAD"]).stdout
        func runDelete(_ paths: [String], keep: Bool) async throws -> (IgnoreWindowController,[String]) {
            let owner = try IgnoreWindowController(repository: repository, access: nil, paths: paths, mask: false, delete: true)
            var questions: [String] = []
            owner.presentQuestion = { _,alert,reply in
                questions.append(alert.messageText); reply(alert.messageText == "Keep file locally?" && !keep ? .alertSecondButtonReturn : .alertFirstButtonReturn); return true
            }
            owner.model.apply(); owner.model.apply(); owner.model.options = try IgnoreOptions(paths: ["abort-next.txt"], mask: false)
            try await wait { IgnoreWindowModel.activeOperations == 0 }
            try require(!owner.model.busy, "Owned operation settled")
            return (owner,questions)
        }
        let (yes,yesQuestions) = try await runDelete(["keep.txt"], keep: true)
        try require(yesQuestions == ["Keep file locally?","1 files removed."] && yes.model.removed == 1 && FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path), "Captured Yes keeps local file and source summary")
        let keepIndex = try await repository.run(["ls-files","-z","--","keep.txt"]).stdout; try require(keepIndex.isEmpty, "Yes removes only index")
        let (no,noQuestions) = try await runDelete(["remove.txt"], keep: false)
        try require(noQuestions.last == "1 files removed." && !FileManager.default.fileExists(atPath: root.appendingPathComponent("remove.txt").path), "No removes working copy")
        try Data("untracked".utf8).write(to: root.appendingPathComponent("not-tracked.txt"))
        let (continued,continueQuestions) = try await runDelete(["not-tracked.txt","after-error.txt"], keep: true)
        try require(continueQuestions.count == 3 && continueQuestions[1].hasPrefix("Could not remove") && continueQuestions.last == "1 files removed." && continued.model.removed == 1, "Error continues and summary counts actual successes")
        let aborted = try IgnoreWindowController(repository: repository, access: nil, paths: ["not-tracked.txt","abort-next.txt"], mask: false, delete: true)
        aborted.presentQuestion = { _,alert,reply in reply(alert.messageText == "Keep file locally?" ? .alertFirstButtonReturn : .alertSecondButtonReturn); return true }
        aborted.model.apply(); try await wait { IgnoreWindowModel.activeOperations == 0 }
        let abortIndex = try await repository.run(["ls-files","-z","--","abort-next.txt"]).stdout
        try require(!abortIndex.isEmpty && aborted.model.removed == 0, "Error Abort does not process next path")

        let retired = try IgnoreWindowController(repository: repository, access: nil, paths: ["abort-next.txt"], mask: false, delete: true)
        var answer: ((NSApplication.ModalResponse) -> Void)?, closes = 0
        retired.onClosed = { closes += 1 }; retired.presentQuestion = { _,_,reply in answer = reply; return true }
        retired.model.apply(); try await wait { answer != nil }
        retired.close(); answer?(.alertSecondButtonReturn); answer?(.alertFirstButtonReturn)
        try await wait { IgnoreWindowModel.activeOperations == 0 }
        let stillTracked = try await repository.run(["ls-files","-z","--","abort-next.txt"]).stdout
        try require(closes == 1 && !stillTracked.isEmpty && FileManager.default.fileExists(atPath: root.appendingPathComponent("abort-next.txt").path), "Forced close resolves question once; late No/Yes cannot remove")
        let actualSheet = try IgnoreWindowController(repository: repository, access: nil, paths: ["abort-next.txt"], mask: false, delete: true)
        actualSheet.window?.alphaValue = 0
        let nativePresentation = actualSheet.presentQuestion
        actualSheet.presentQuestion = { owner, alert, reply in alert.window.alphaValue = 0; return nativePresentation(owner, alert, reply) }
        actualSheet.model.apply(); try await wait { actualSheet.window?.attachedSheet != nil }
        actualSheet.close(); try await wait { IgnoreWindowModel.activeOperations == 0 }
        try require(actualSheet.window?.attachedSheet == nil && actualSheet.model.removed == 0, "Actual owned NSAlert sheet torn down without destructive answer")
        let rejected = try IgnoreWindowController(repository: repository, access: nil, paths: ["abort-next.txt"], mask: false, delete: true)
        rejected.presentQuestion = { _,_,_ in false }; rejected.model.apply(); try await wait { IgnoreWindowModel.activeOperations == 0 }
        try require(rejected.model.removed == 0, "Rejected presentation does not imply No")

        let retry = IgnoreWindowModel(repository: repository, access: nil, options: try IgnoreOptions(paths: ["abort-next.txt"], mask: false))
        var fail = true, calls = 0
        retry.writeRules = { options,token in calls += 1; if fail { throw Failure(message: "Owned write error") }; return try await repository.addIgnoreRules(options,cancellation: token) }
        retry.apply(); try await wait { !retry.busy && IgnoreWindowModel.activeOperations == 0 }; try require(retry.error != nil && calls == 1, "Write failure keeps retryable draft")
        fail = false; retry.apply(); try await wait { !retry.busy && IgnoreWindowModel.activeOperations == 0 }; try require(retry.error == nil && calls == 2, "Retry succeeds")
        let held = IgnoreWindowModel(repository: repository, access: nil, options: try IgnoreOptions(paths: ["late.txt"], mask: false))
        var continuation: CheckedContinuation<Void,Never>?, emitted = 0
        held.writeRules = { options,_ in await withCheckedContinuation { continuation = $0 }; return try await repository.addIgnoreRules(options) }
        held.onRulesWritten = { _ in emitted += 1 }; held.apply(); try await wait { continuation != nil }
        held.invalidate(); try require(IgnoreWindowModel.activeOperations == 1, "Retired accepted write remains counted")
        continuation?.resume(); continuation = nil; try await wait { IgnoreWindowModel.activeOperations == 0 }
        try require(emitted == 0 && !held.busy && held.error == nil, "Late writer cannot publish")
        let finalHead = try await repository.run(["rev-parse","HEAD"]).stdout, finalRetained = try await repository.run(["ls-files","--stage","-z","--","unrelated.txt"]).stdout
        try require(finalHead == head && finalRetained == retained && (try Data(contentsOf: root.appendingPathComponent("abort-next.txt"))) == Data("abort-next.txt".utf8), "HEAD/unrelated index/aborted working bytes retained")
        [yes,no,continued,aborted,retired,rejected].forEach { $0.close() }
    }
}
