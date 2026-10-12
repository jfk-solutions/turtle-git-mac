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
        pending.window?.close(); continuation?.resume(returning: false); continuation = nil
        try await idle(pending.model); precondition(finished == 1 && SVNWindowModel.activeOperations == 0)
        print("Native SVN: captured Fetch range, DCommit radio/remember/stash/pop, Ignore destinations, fast-forward information, duplicate-start and forced-close/Quit ownership verified with private Git and injected SVN transport.")
    }
}
