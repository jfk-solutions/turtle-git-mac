// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SyncChildProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor final class Gate {
        var entered = false
        private var reply: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { reply = $0 } }
        func open() { let callback = reply; reply = nil; callback?.resume() }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<6000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Sync child progress wait at \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func capture(_ window: NSWindow, name: String) async throws {
        guard let output = ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_CHILD_CAPTURE"] else { return }
        if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_RECOVERY_ONLY_CAPTURE"] == "1", !name.hasPrefix("sync-recovery") { return }
        if #available(macOS 14.4, *) {
            let folder = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 250_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Missing owned progress window") }
                let config = SCStreamConfiguration(); config.width = Int(window.frame.width*2); config.height = Int(window.frame.height*2); config.showsCursor = false; config.includeChildWindows = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name+"-"+suffix+".png"))
            }
            window.alphaValue = 0
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.SyncChildQA."+UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); NSApp.windows.forEach { $0.close() } }
        preferences.set(0, forKey: "AutoCloseGitProgress"); preferences.set(true, forKey: "ShowAppContextMenuIcons")
        let repo = GitRepository(root: root, executable: executable)
        _ = try await repo.run(["init", "--initial-branch=main", "--template="])
        for (key,value) in [("user.name","Sync QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        let remote = root.appendingPathComponent("server.git")
        _ = try await repo.run(["clone","--bare","--template=","--",root.path,remote.path])
        _ = try await repo.run(["remote","add","origin",remote.path])
        let server = GitRepository(root: remote, executable: executable)
        _ = try await server.run(["config","core.hooksPath",remote.appendingPathComponent("hooks").path])
        let store = ActionLogStore(storageURL: root.appendingPathComponent("private-action-log.txt"))
        ProgressActionLog.install(store: store, preferences: preferences)
        _ = try await repo.run(["tag","qa-local"])
        let initial = try await repo.synchronizationTags(remote: "origin")
        let row = initial.rows.first { $0.name.rawValue == "qa-local" }!
        var pushed = 0
        let push = SynchronizationProgressController(repository: repo, operation: .tag(.push,row,initial,false), cancellation: OperationCancellation(), preferences: preferences) { result in
            if case .success(.tag) = result { pushed += 1 }
        }
        push.window!.alphaValue = 0; push.window!.orderFront(nil); push.model.start()
        try await wait { !push.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(push.model.success && push.model.percentage == 100 && push.model.currentWork == "Success" && push.model.completionRange != nil && pushed == 0, "Manual Push result did not retain completion")
        let saved = try store.read(); push.model.saveActionLog(); try require(try store.read() == saved, "Duplicate Action log entry")
        try await wait { views(push.window!.contentView!).contains { $0 is SubmoduleProgressTextView } }
        let text = views(push.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.first!
        let clipboard = NSPasteboard.withUniqueName(); text.clipboard = clipboard
        text.setSelectedRange(NSRange(location:0,length:min(4,(text.string as NSString).length)))
        let selection = text.selectedRange(), menu = text.outputMenu()
        try require(menu.items.first?.image != nil && menu.items.last?.image != nil, "Source Copy icons missing")
        text.copyAllInformation(nil)
        try require(clipboard.string(forType:.string) == text.string && text.selectedRange() == selection, "Copy all changed selection or lost output")
        clipboard.releaseGlobally(); push.close(); try await wait { pushed == 1 }; push.close(); try require(pushed == 1, "Progress completion repeated")

        // Source tag progress captures the preference; later Settings edits cannot change this attempt.
        _ = try await server.run(["tag","qa-remote"])
        let incoming = try await repo.synchronizationTags(remote:"origin"), incomingRow = incoming.rows.first { $0.name.rawValue == "qa-remote" }!
        preferences.set(2,forKey:"AutoCloseGitProgress"); var fetched = 0
        let fetch = SynchronizationProgressController(repository:repo,operation:.tag(.fetch,incomingRow,incoming,false),cancellation:OperationCancellation(),preferences:preferences) { result in if case .success(.tag) = result { fetched += 1 } }
        fetch.window!.alphaValue = 0; fetch.window!.orderFront(nil); preferences.set(0,forKey:"AutoCloseGitProgress"); fetch.model.start()
        try await wait { fetched == 1 && SynchronizationProgressModel.activeOperations == 0 }
        _ = try await repo.run(["rev-parse","--verify","refs/tags/qa-remote"])

        // Real transport rejection retains its raw diagnostics, terminal code, native footer and failure window.
        let hook = remote.appendingPathComponent("hooks/pre-receive")
        try FileManager.default.createDirectory(at:hook.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("#!/bin/sh\necho 'fatal: QA remote rejected the tag' >&2\nexit 1\n".utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _ = try await repo.run(["tag","qa-rejected"])
        let rejecting = try await repo.synchronizationTags(remote:"origin"), rejectedRow = rejecting.rows.first { $0.name.rawValue == "qa-rejected" }!
        var rejected = 0
        let failure = SynchronizationProgressController(repository:repo,operation:.tag(.push,rejectedRow,rejecting,false),cancellation:OperationCancellation(),preferences:preferences) { result in if case .failure = result { rejected += 1 } }
        failure.window!.alphaValue = 0; failure.window!.orderFront(nil); failure.model.start()
        try await wait { !failure.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(!failure.model.success && !failure.model.cancelled && failure.model.percentage == 100 && failure.model.currentWork.contains("exit code") && failure.model.output.contains("QA remote rejected") && failure.model.completionRange != nil && rejected == 0,"Real rejection lost Git result/footer")
        try await capture(failure.window!,name:"sync-child-progress-failure"); failure.close(); try await wait { rejected == 1 }

        let state = try await repo.synchronizationRebaseState(target:"HEAD")
        preferences.set(true,forKey:"ConfirmKillProcess")
        let gate = Gate(), token = OperationCancellation(); var closed = 0; var answer: ((Bool)->Void)?
        let live = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:token,preferences:preferences) { _ in closed += 1 }
        live.model.executeOperation = { onOutput in
            onOutput(GitOutputChunk(stream:.stderr,data:Data("Receiving objects:  42% (42/100)\r".utf8)))
            await gate.wait(); return .merge(try await repo.run(["status","--short"]))
        }
        live.model.confirmCancel = { answer = $0 }; live.window!.alphaValue = 0; live.window!.orderFront(nil); live.model.start()
        try await wait { gate.entered && live.model.percentage == 42 }
        try require(live.model.currentWork.contains("Receiving objects"), "Live parser current work lost")
        try await capture(live.window!,name:"sync-child-progress-live")
        live.model.cancel(); try require(live.model.confirmingCancellation && answer != nil,"Abort question was not owned")
        gate.open(); try await wait { !live.model.busy }
        try require(live.model.success && closed == 0 && !token.isCancelled,"Natural success closed behind Abort question")
        answer?(true); answer?(true); try await wait { closed == 1 }
        try require(!token.isCancelled,"Late Abort cancelled natural success")

        // Forced closure retires the presentation but keeps parent continuation and Quit fenced until actual drain.
        let drain = Gate(), forcedToken = OperationCancellation(); var delivered = 0, didClose = 0
        let forced = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:forcedToken,preferences:preferences) { result in if case .failure = result { delivered += 1 } }
        forced.onClosed = { didClose += 1 }
        forced.model.executeOperation = { onOutput in await drain.wait(); onOutput(GitOutputChunk(stream:.stderr,data:Data("late output\n".utf8))); return .merge(try await repo.run(["status","--short"])) }
        forced.window!.alphaValue = 0; forced.window!.orderFront(nil); forced.model.start(); try await wait { drain.entered }
        let before = forced.model.output; forced.abortPresentation()
        try require(SynchronizationProgressModel.activeOperations == 1 && delivered == 0 && didClose == 0 && forcedToken.isCancelled,"Forced close released worker ownership early")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored closed live worker")
        drain.open(); try await wait { SynchronizationProgressModel.activeOperations == 0 && delivered == 1 && didClose == 1 }
        try require(forced.model.output == before && forced.model.completionRange == nil && forced.model.result == nil,"Retired worker republished late output/result/footer")
        forced.abortPresentation(); try require(delivered == 1 && didClose == 1,"Forced-close callback repeated")

        preferences.set(false,forKey:"ConfirmKillProcess")
        let cancelGate = Gate(), cancelToken = OperationCancellation(); var cancelled = 0
        let abort = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:cancelToken,preferences:preferences) { _ in cancelled += 1 }
        abort.model.executeOperation = { _ in await cancelGate.wait(); try cancelToken.check(); return .merge(try await repo.run(["status","--short"])) }
        abort.window!.alphaValue = 0; abort.window!.orderFront(nil); abort.model.start(); try await wait { cancelGate.entered }
        abort.model.cancel(); abort.model.cancel(); try require(cancelToken.isCancelled && abort.model.cancelling,"Direct Abort did not cancel captured worker")
        cancelGate.open(); try await wait { !abort.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(abort.model.cancelled && abort.model.currentWork == "User cancelled" && abort.model.percentage == 100 && cancelled == 0,"Cancelled failure lost retained terminal state")
        abort.close(); try await wait { cancelled == 1 }
        var compact = 0; let compactToken = OperationCancellation()
        let tags = SynchronizationProgressController(repository:repo,operation:.tags("origin"),cancellation:compactToken,preferences:preferences) { result in if case .success(.tags) = result { compact += 1 } }
        tags.window!.alphaValue = 0; tags.window!.orderFront(nil); tags.model.start(); try await wait { compact == 1 && SynchronizationProgressModel.activeOperations == 0 }
        try require(!compactToken.isCancelled, "Successful compact close cancelled parent request")
        try await verifyRecovery(repo:repo,root:root,preferences:preferences)
        try require(NSApp.windows.filter { $0.isVisible }.isEmpty,"Owned progress window remained visible")
        print("PASS Sync child progress: real tag Push/Fetch/rejection, captured auto-close, native Copy icons/private clipboard, one Action log, live parser, completion/timing/footer, question/natural-success race, direct Abort, compact results, forced close/late output/drain/Quit and once-only parent callbacks")
    }

    @MainActor static func verifyRecovery(repo:GitRepository,root:URL,preferences:UserDefaults) async throws {
        let state=try await repo.synchronizationRebaseState(target:"HEAD")
        let beforeHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let beforeFile=try Data(contentsOf:root.appendingPathComponent("file.txt"))
        func blob(_ text:String) async throws -> String {
            String(decoding:try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        }
        let base=try await blob("base\n"), mine=try await blob("mine\n"), theirs=try await blob("theirs\n")
        let index="0 0000000000000000000000000000000000000000\tfile.txt\n100644 "+base+" 1\tfile.txt\n100644 "+mine+" 2\tfile.txt\n100644 "+theirs+" 3\tfile.txt\n"
        _=try await repo.run(["update-index","--index-info"],input:Data(index.utf8))
        let unresolved=try await repo.run(["ls-files","--unmerged"]).stdout
        try require(!unresolved.isEmpty,"Missing actual unmerged index fixture")
        var events=[String](), commit:CommitWindowController?
        let parent=SynchronizationWindowController(repository:repo,access:nil,preferences:preferences)
        parent.window!.alphaValue=0;parent.window!.orderFront(nil)
        defer {parent.close()}
        parent.model.onCommit={ [weak parent] in
            guard let parent else {return}
            events.append("recovery")
            precondition(SynchronizationProgressModel.activeOperations == 0 && parent.commandProgress == nil && parent.window!.attachedSheet == nil)
            let child=CommitWindowController(repository:repo,access:nil,defaults:preferences)
            child.window!.alphaValue=0;child.window!.orderFront(nil);child.model.reload();commit=child
        }
        let handoff=Task { await parent.model.performFastForward!(state,OperationCancellation()) }
        try await wait {parent.commandProgress != nil}
        let failure=parent.commandProgress!, clear=parent.commandProgress!.onClosed
        failure.onClosed={clear();events.append("closed")}
        failure.window!.alphaValue=0;failure.window!.orderFront(nil);failure.model.start()
        try await wait{!failure.model.busy && SynchronizationProgressModel.activeOperations == 0}
        guard let recovery=failure.model.captureRecovery() else {throw Failure(description:"Failed ff-only with real unmerged index did not offer Resolve")}
        try require(!failure.model.success && failure.model.currentWork.contains("exit code") && failure.model.completionRange != nil,"Recovery inspection replaced original Git failure")
        try await capture(failure.window!,name:"sync-recovery-conflict")
        let nested=NSWindow(contentRect:.init(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        nested.isReleasedWhenClosed=false;nested.alphaValue=0;failure.window!.beginSheet(nested,completionHandler:nil)
        failure.model.performRecovery(recovery)
        try require(events.isEmpty && !failure.model.recoveryConsumed,"Attached sheet consumed or dispatched recovery")
        failure.window!.endSheet(nested);nested.close()
        failure.model.performRecovery(recovery);failure.model.performRecovery(recovery)
        try await wait{commit != nil && !commit!.model.busy && CommitWindowModel.activeReloads == 0}
        try require(events == ["closed","recovery"] && !failure.window!.isVisible && commit!.model.entries.contains{$0.state == .conflicted},"Resolve did not close/drain then open whole-project Commit exactly once")
        try await capture(commit!.window!,name:"sync-recovery-commit")
        commit!.close();commit=nil;failure.model.performRecovery(recovery)
        try require(events.count == 2,"Retired recovery receipt launched another Commit")
        let originalOutcome=await handoff.value
        if case .failure(let error)=originalOutcome {try require(error is GitFailure,"Recovery lost original Git error")}
        else {throw Failure(description:"Recovery rewrote failed parent result")}
        parent.close()
        let afterUnmerged=try await repo.run(["ls-files","--unmerged"]).stdout
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterUnmerged == unresolved && afterHead == beforeHead,"Recovery action changed index entries or HEAD")

        // Secondary inspection errors retain the actual failed Git result and footer.
        let probeFailure=SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:OperationCancellation(),preferences:preferences) {_ in}
        probeFailure.model.inspectConflicts={_ in throw NSError(domain:"TurtleGit.SyncRecoveryQA",code:1,userInfo:[NSLocalizedDescriptionKey:"QA conflict inspection failed"])}
        probeFailure.window!.alphaValue=0;probeFailure.window!.orderFront(nil);probeFailure.model.start()
        try await wait{!probeFailure.model.busy && SynchronizationProgressModel.activeOperations == 0}
        try require(probeFailure.model.captureRecovery() == nil && probeFailure.model.output.contains("QA conflict inspection failed") && probeFailure.model.currentWork.contains("exit code"),"Inspection failure clobbered the original failure or offered unverified recovery")
        probeFailure.close()

        // An old Git Abort question cannot cancel the later read. A new read question can.
        preferences.set(true,forKey:"ConfirmKillProcess")
        let gitGate=Gate(), readGate=Gate(), originalToken=OperationCancellation()
        var readToken:OperationCancellation?, answers=[(Bool)->Void]()
        let staged=SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:originalToken,preferences:preferences) {_ in}
        staged.model.executeOperation={output in await gitGate.wait();return .merge(try await repo.run(["merge","--ff-only","--","HEAD"],onOutput:output))}
        staged.model.inspectConflicts={token in readToken=token;await readGate.wait();return true}
        staged.model.confirmCancel={answers.append($0)}
        staged.window!.alphaValue=0;staged.window!.orderFront(nil);staged.model.start();try await wait{gitGate.entered}
        staged.model.cancel();try require(answers.count == 1,"Git cancellation question missing")
        gitGate.open();try await wait{readGate.entered}
        answers[0](true);answers[0](true)
        try require(!originalToken.isCancelled && readToken?.isCancelled == false && !staged.model.confirmingCancellation,"Late Git answer cancelled a replacement inspection")
        staged.model.cancel();try require(answers.count == 2,"Inspection cancellation question missing")
        answers[1](true);answers[1](true);try require(readToken?.isCancelled == true,"New inspection answer did not cancel its own read")
        readGate.open();try await wait{!staged.model.busy && SynchronizationProgressModel.activeOperations == 0}
        try require(staged.model.captureRecovery() == nil && !staged.model.cancelled && staged.model.currentWork.contains("exit code"),"Cancelled secondary read invented recovery or rewrote Git outcome")
        staged.close()

        let forcedGate=Gate();var forcedRead:OperationCancellation?, completed=0
        let forced=SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:OperationCancellation(),preferences:preferences) {_ in completed += 1}
        forced.model.inspectConflicts={token in forcedRead=token;await forcedGate.wait();return true}
        forced.window!.alphaValue=0;forced.window!.orderFront(nil);forced.model.start();try await wait{forcedGate.entered}
        forced.abortPresentation()
        try require(forcedRead?.isCancelled == true && completed == 0 && SynchronizationProgressModel.activeOperations == 1,"Forced close released recovery inspection before real drain")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed recovery inspection did not fence Quit")
        forcedGate.open();try await wait{completed == 1 && SynchronizationProgressModel.activeOperations == 0}
        try require(forced.model.captureRecovery() == nil && forced.model.completionRange == nil,"Retired probe published recovery/footer")
        _=try await repo.run(["reset","--hard","HEAD"])
        let noConflicts=SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:OperationCancellation(),preferences:preferences) {_ in}
        noConflicts.model.executeOperation={output in .merge(try await repo.run(["merge","--ff-only","--","refs/heads/qa-missing"],onOutput:output))}
        noConflicts.window!.alphaValue=0;noConflicts.window!.orderFront(nil);noConflicts.model.start()
        try await wait{!noConflicts.model.busy && SynchronizationProgressModel.activeOperations == 0}
        try require(!noConflicts.model.success && noConflicts.model.captureRecovery() == nil,"Non-conflict failure offered Resolve")
        noConflicts.close()
        try require(try Data(contentsOf:root.appendingPathComponent("file.txt")) == beforeFile,"Recovery inspection changed worktree bytes")
        print("PASS Sync recovery: real ff-only failure/unmerged index, source Resolve-to-Commit handoff after drain, unchanged index/HEAD/working bytes, nested sheet/duplicate/retired receipts, secondary read error, old/new cancellation stage ownership, forced read drain/Quit/late footer and non-conflict refusal")
    }
}
