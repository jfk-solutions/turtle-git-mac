import AppKit
import TurtleGitCore

struct SVNNativeVerification {
    @MainActor static func idle(_ model: SVNWindowModel) async throws {
        for _ in 0..<1500 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("SVN workflow did not become idle")
    }
    @MainActor static func verify() async throws {
        let (root, repository, old, next) = try await GitSVNFixture.create()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "TurtleGit.SVN.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let fetch = SVNWindowController(repository: repository, access: nil, operation: .fetch, preferences: preferences)
        fetch.model.load(); fetch.model.load(); try await idle(fetch.model)
        precondition(fetch.model.phase == .finished && fetch.model.error == nil)
        precondition(fetch.model.fetched?.oldHash == old && fetch.model.fetched?.newHash == next)
        var compare = false, log = false
        fetch.model.onCompare = { compare = $0 == old && $1 == next }
        fetch.model.onLog = { log = $0.range == old + ".." + next }
        fetch.model.onCompare(old, next); fetch.model.onLog(fetch.model.fetched!)
        precondition(compare && log); fetch.window?.close()
        let dcommit = SVNWindowController(repository: repository, access: nil, operation: .dcommit, preferences: preferences)
        dcommit.model.load(); try await idle(dcommit.model)
        precondition(dcommit.model.phase == .options && !dcommit.model.removeEmptyDirectories && !dcommit.model.remember)
        dcommit.model.removeEmptyDirectories = true; dcommit.model.remember = true
        try Data("private edit\n".utf8).write(to: root.appendingPathComponent("file"))
        var stashed = 0, restored = 0
        dcommit.model.confirmStash = { stashed += 1; return true }
        dcommit.model.confirmPop = { restored += 1; return true }
        dcommit.model.start(); dcommit.model.start(); try await idle(dcommit.model)
        precondition(dcommit.model.error == nil && stashed == 1 && restored == 1)
        let bytes = try Data(contentsOf: root.appendingPathComponent("file")); precondition(bytes == Data("private edit\n".utf8))
        let type = try await repository.svnCommitType(); precondition(type == true)
        dcommit.window?.close()
        _ = try await repository.run(["restore", "--", "file"])
        let ignore = SVNWindowController(repository: repository, access: nil, operation: .ignore, preferences: preferences)
        ignore.model.load(); try await idle(ignore.model); precondition(ignore.model.phase == .options && ignore.model.ignoreDestination == .exclude)
        ignore.model.start(); try await idle(ignore.model); precondition(ignore.model.error == nil)
        let exclude = try await repository.svnIgnoreExcludeURL(), patterns = try Data(contentsOf: exclude)
        precondition(patterns == Data("ignored*\n雪*\n".utf8)); ignore.window?.close()
        let rebase = SVNWindowController(repository: repository, access: nil, operation: .rebase, preferences: preferences)
        var information = 0
        rebase.model.confirmInformation = { _ in information += 1 }
        rebase.model.load(); try await idle(rebase.model)
        precondition(rebase.model.error == nil && information == 1)
        let head = try await repository.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(head == next); rebase.window?.close()
        // Force-close a retained prompt while the operation count still fences Quit.
        let pending = SVNWindowController(repository: repository, access: nil, operation: .dcommit, preferences: preferences)
        var continuation: CheckedContinuation<Bool, Never>?, finished = 0
        pending.model.confirmStash = { await withCheckedContinuation { continuation = $0 } }
        pending.onClosed = { finished += 1 }
        try Data("pending edit\n".utf8).write(to: root.appendingPathComponent("file"))
        pending.model.load()
        for _ in 0..<1000 { if continuation != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(continuation != nil && SVNWindowModel.activeOperations == 1)
        let delegate = TurtleGitApplicationDelegate(); precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        let frozenPhase = pending.model.phase, frozenStatus = pending.model.status, frozenOutput = pending.model.output
        pending.window?.close(); continuation?.resume(returning: false); continuation = nil
        try await idle(pending.model); precondition(finished == 1 && SVNWindowModel.activeOperations == 0)
        precondition(pending.model.phase == frozenPhase && pending.model.status == frozenStatus && pending.model.output == frozenOutput && pending.model.error == nil)
        // A controller-owned question must settle on close without waiting for its presenter.
        let owned = SVNWindowController(repository: repository, access: nil, operation: .dcommit, preferences: preferences)
        var response: ((NSApplication.ModalResponse) -> Void)?, questions = 0, closed = 0
        owned.presentQuestion = { alert, _, callback in questions += 1; response = callback; precondition(alert.informativeText == repository.root.path) }
        owned.onClosed = { closed += 1 }
        let question = Task { await owned.ask("Private owned question", yes: "Yes", no: "No") }
        for _ in 0..<1000 { if response != nil { break }; try await Task.sleep(nanoseconds:10_000_000) }
        precondition(response != nil && questions == 1)
        let duplicate = await owned.ask("Duplicate", yes: "Yes", no: "No"); precondition(!duplicate && questions == 1)
        owned.window?.close(); let answer = await question.value; response?(.alertFirstButtonReturn)
        precondition(!answer && closed == 1)
        let stale = await owned.ask("Closed", yes:"Yes", no:nil); precondition(!stale && questions == 1)
        // Repeated Cancel owns one request and cannot publish after retirement.
        let cancelling = SVNWindowController(repository:repository,access:nil,operation:.dcommit,preferences:preferences)
        var heldStash:CheckedContinuation<Bool,Never>?,heldCancel:CheckedContinuation<Bool,Never>?,cancelQuestions=0
        cancelling.model.confirmStash = {await withCheckedContinuation{heldStash=$0}}
        cancelling.model.confirmCancel = {cancelQuestions += 1;return await withCheckedContinuation{heldCancel=$0}}
        cancelling.model.load()
        for _ in 0..<1000 {if heldStash != nil {break};try await Task.sleep(nanoseconds:10_000_000)}
        precondition(heldStash != nil)
        cancelling.model.cancel();cancelling.model.cancel()
        for _ in 0..<1000 {if heldCancel != nil {break};try await Task.sleep(nanoseconds:10_000_000)}
        precondition(cancelQuestions==1 && cancelling.model.confirmingCancellation)
        let cancelledStatus=cancelling.model.status,cancelledPhase=cancelling.model.phase
        cancelling.window?.close();heldCancel?.resume(returning:true);heldStash?.resume(returning:true)
        try await idle(cancelling.model)
        for _ in 0..<1000 {if !cancelling.model.confirmingCancellation {break};try await Task.sleep(nanoseconds:10_000_000)}
        precondition(cancelling.model.status==cancelledStatus && cancelling.model.phase==cancelledPhase && cancelling.model.error==nil && cancelQuestions==1 && SVNWindowModel.activeOperations==0)
        // A scoped Commit handoff must ignore another main-window repository/refresh.
        let workspace = RepositoryModel(startMonitoring:false), otherRoot=root.appendingPathComponent("other-workspace")
        let lease=RepositoryAccessLease(url:root)
        workspace.root=otherRoot;workspace.busy=true
        var scoped:SVNWindowController?,presentations=0
        workspace.svnPresentation={controller in scoped=controller;presentations += 1}
        workspace.showSVN(.ignore,repository:repository,access:lease)
        guard let routed=scoped else {throw NSError(domain:"Scoped SVN presentation missing",code:1)}
        defer{routed.window?.close();workspace.svnPresentation=nil}
        try await idle(routed.model)
        guard routed.model.operation == .ignore, routed.model.repository === repository, routed.model.repository.root==repository.root, routed.model.repository.executable==repository.executable, routed.model.access === lease, workspace.root==otherRoot, routed.model.phase == .options else { throw NSError(domain:"Scoped SVN ownership: phase=\(routed.model.phase), error=\(routed.model.error ?? "none"), repo=\(routed.model.repository.root.path), expected=\(repository.root.path)",code:1) }
        workspace.showSVN(.ignore,repository:repository,access:lease)
        precondition(scoped === routed && presentations==2)
        workspace.showSVN(.dcommit,repository:repository,access:lease)
        precondition(scoped === routed && presentations==3 && workspace.error?.contains("Finish Import SVN Ignore") == true)
        routed.window?.close()
        workspace.showSVN(.dcommit,repository:repository,access:lease)
        guard let replacement=scoped else {throw NSError(domain:"SVN replacement missing",code:1)}
        defer{replacement.window?.close()}
        replacement.model.confirmStash={false}
        precondition(replacement !== routed && replacement.model.operation == .dcommit && replacement.model.repository === repository && replacement.model.repository.root==repository.root && replacement.model.access === lease)
        try await idle(replacement.model)
        precondition(replacement.model.error==nil && workspace.root==otherRoot && SVNWindowModel.activeOperations==0)
        print("Native SVN: captured Fetch range, DCommit radio/remember/stash/pop, Ignore destinations, fast-forward information, duplicate-start and forced-close frozen presentation/Quit ownership, controller-owned question settlement and duplicate/late Cancel fencing, captured repository/lease under another busy workspace, options reuse and conflicting-operation refusal verified with private Git and injected SVN transport.")
    }
}
