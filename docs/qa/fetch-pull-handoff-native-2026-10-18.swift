// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum FetchPullHandoffVerification {
    struct Failure: Error, LocalizedError, CustomStringConvertible { let description: String; var errorDescription: String? { description } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2400 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Fetch/Pull handoff did not settle at \(line)")
    }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let sourceRoot = root.appendingPathComponent("source"), checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = GitRepository(root: sourceRoot, executable: git)
        _ = try await source.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Fetch handoff QA"),("user.email","fetch@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await source.run(["config",key,value]) }
        func commit(_ value: String) async throws -> String {
            try Data((value + "\n").utf8).write(to: sourceRoot.appendingPathComponent("file"))
            try await source.stage(["file"]); _ = try await source.commit(message: value)
            return try await source.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        }
        let first = try await commit("first")
        _ = try await source.run(["clone",sourceRoot.path,checkout.path])
        let repo = GitRepository(root: checkout, executable: git)
        for (key,value) in [("user.name","Fetch handoff QA"),("user.email","fetch@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let suite = "TurtleGit.FetchPullHandoff.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress")
        defer {prefs.removePersistentDomain(forName:suite)}
        var owners: [FetchWindowController] = []
        var hosts: [NSWindow] = []
        var held: CheckedContinuation<Void,Error>?
        func drained() -> Bool { FetchWindowModel.activePreparationReads == 0 && FetchWindowModel.activeProgressOperations == 0 && FetchWindowController.activeProgressReleases == 0 }
        func owner(pull: Bool = false) async throws -> FetchWindowController {
            let value = FetchWindowController(repository:repo,access:nil,isPull:pull,preferences:prefs)
            owners.append(value); value.window?.alphaValue = 0; value.window?.orderFront(nil); value.model.load()
            try await wait {!value.model.operationActive && FetchWindowModel.activePreparationReads == 0}
            return value
        }
        func cleanup() async throws {
            owners.forEach {$0.close()}; hosts.forEach { if let sheet=$0.attachedSheet {$0.endSheet(sheet)}; $0.close() }; let continuation=held;held=nil;continuation?.resume(throwing:Failure(description:"retired"))
            try await wait {drained() && owners.allSatisfy {$0.window?.isVisible != true && $0.window?.attachedSheet == nil} && hosts.allSatisfy {!$0.isVisible && $0.attachedSheet == nil}}
            try require(owners.allSatisfy {$0.window?.isVisible != true && $0.window?.attachedSheet == nil},"Owned transport windows survived cleanup")
        }
        do {
            let second = try await commit("second")
            let fetch = try await owner()
            var fetchActions=0,fetchDetached=false
            fetch.model.onFetchPostAction = { action,_ in
                fetchActions += 1
                fetchDetached = action == .log && fetch.window?.attachedSheet == nil && fetch.window?.isVisible == false && fetch.model.closed && FetchWindowController.activeProgressReleases == 0
            }
            fetch.model.fetch()
            try await wait {fetch.fetchProgressController?.model.busy == false && FetchWindowModel.activeProgressOperations == 0}
            guard let fetchProgress=fetch.fetchProgressController else {throw Failure(description:"Fetch progress missing")}
            try require(fetchProgress.window?.sheetParent === fetch.window && fetchProgress.window?.alphaValue == 0 && fetchProgress.model.success,"Actual Fetch sheet hidden/attached/success state missing")
            try require(fetchProgress.model.postActions == [.log,.reset,.fetch,.rebase,.switchBranch],"Source successful Fetch post-action order changed")
            fetch.model.confirmingQuit=true
            fetchProgress.model.perform(.log); fetch.model.fetch()
            try require(fetchActions == 0 && fetchProgress.model.confirmingQuit && !fetchProgress.windowShouldClose(fetchProgress.window!) && !fetch.windowShouldClose(fetch.window!),"Deferred Quit allowed completed Fetch actions/close or another transport")
            fetch.model.confirmingQuit=false
            fetchProgress.model.perform(.log);fetchProgress.model.perform(.log)
            try await wait {fetchActions == 1 && fetch.model.closed && drained()}
            try require(fetchDetached,"Fetch callback preceded actual progress/outer window close")
            let headAfterFetch=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            try require(headAfterFetch == first,"Fetch unexpectedly integrated the working branch")

            let pull = try await owner(pull:true)
            var pullActions=0,pullDetached=false
            pull.model.onPullPostAction = {action,result in
                pullActions += 1
                pullDetached = action == .diff && result.oldHead == first && result.newHead == second && pull.window?.attachedSheet == nil && pull.window?.isVisible == false && pull.model.closed
            }
            pull.model.fetch()
            try await wait {pull.progressController?.model.busy == false && FetchWindowModel.activeProgressOperations == 0}
            guard let pullProgress=pull.progressController else {throw Failure(description:"Pull progress missing")}
            try require(pullProgress.window?.sheetParent === pull.window && pullProgress.window?.alphaValue == 0 && pullProgress.model.success,"Actual Pull sheet hidden/attached/success state missing")
            try require(pullProgress.model.postActions == [.diff,.log],"Source successful Pull post-action order changed")
            pullProgress.model.perform(.diff);pullProgress.model.perform(.diff)
            try await wait {pullActions == 1 && pull.model.closed && drained()}
            try require(pullDetached,"Pull handoff lost immutable before/after endpoints or preceded native detach")

            _ = try await repo.run(["config","pull.rebase","true"])
            let third = try await commit("third"), rebase = try await owner(pull:true)
            var attempts:[String]=[], rebasesClosed=0
            let host=NSWindow(contentRect:.init(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);hosts.append(host);host.beginSheet(rebase.window!, completionHandler: nil)
            rebase.onClosed = {if let window=rebase.window {window.sheetParent?.endSheet(window)};rebasesClosed += 1}
            rebase.model.onOwnedRebase = { target,automatic,preserve in
                attempts.append(target)
                try require(automatic && !preserve,"Configured Pull lost automatic/preserve semantics")
                if attempts.count == 1 {
                    // Sync suspends both nested sheets before awaiting Rebase.
                    // A rejected opening must reconstruct that actual chain.
                    if let progress=rebase.fetchProgressController?.window {rebase.window?.endSheet(progress);progress.orderOut(nil)}
                    host.endSheet(rebase.window!);rebase.window?.orderOut(nil)
                    throw Failure(description:"injected Rebase opening failure")
                }
            }
            rebase.model.fetch()
            try await wait {rebase.fetchProgressController?.model.busy == false && rebase.fetchProgressController?.model.dispatchingAction == false && FetchWindowModel.activeProgressOperations == 0}
            guard let recovery=rebase.fetchProgressController else {throw Failure(description:"Failed Rebase handoff closed its error")}
            print("Owned Rebase recovery: success=\(recovery.model.success), error=\(recovery.model.output.contains("injected Rebase opening failure")), actions=\(recovery.model.postActions), optionsVisible=\(rebase.window?.isVisible == true), optionsAttached=\(rebase.window?.sheetParent === host), progressAttached=\(recovery.window?.sheetParent === rebase.window), alpha=\(String(describing:recovery.window?.alphaValue)), closes=\(rebasesClosed)")
            try require(!recovery.model.success && recovery.model.output.contains("injected Rebase opening failure") && recovery.model.postActions == [.rebase] && rebase.window?.isVisible == true && rebase.window?.sheetParent === host && recovery.window?.sheetParent === rebase.window && recovery.window?.alphaValue == 0 && rebasesClosed == 0,"Failed owned Rebase did not preserve its error/recovery action")
            _ = try await commit("fourth")
            recovery.model.perform(.rebase); recovery.model.perform(.rebase)
            try await wait {rebase.model.closed && host.attachedSheet == nil && drained()}
            let fetchedTarget=try await repo.run(["rev-parse","FETCH_HEAD"]).text.trimmingCharacters(in:.newlines)
            try require(attempts == [third,third] && fetchedTarget == third && rebasesClosed == 1 && host.attachedSheet == nil,"Rebase retry repeated transport, changed captured target or dispatched twice")

            // Force retirement while an accepted asynchronous handoff ignores
            // cancellation. Actual work still owns Quit until its callback returns.
            let retiring=try await owner(pull:true)
            var lateEffects=0
            retiring.model.onOwnedRebase = {_,_,_ in try await withCheckedThrowingContinuation {held=$0};lateEffects += 1}
            retiring.model.fetch();try await wait {held != nil}
            retiring.close()
            try require(FetchWindowModel.activeProgressOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced retirement lost pending transport/Rebase operation ownership")
            let reply=held;held=nil;reply?.resume(throwing:Failure(description:"late handoff failure"))
            try await wait {drained()}
            try require(retiring.model.closed && lateEffects == 0 && retiring.model.error == nil,"Late retired Rebase completion revived transport UI")
            try await cleanup()
            print("PASS: actual hidden Fetch/Pull sheets detach and close before one-shot post-actions; immutable Pull endpoints; failed configured Rebase stays open and retries immutable fetched target without transport; retired async handoff retains Quit ownership and drains")
        } catch {
            let original=error
            do {try await cleanup()} catch {throw Failure(description:"\(original); cleanup: \(error)")}
            throw original
        }
    }
}
