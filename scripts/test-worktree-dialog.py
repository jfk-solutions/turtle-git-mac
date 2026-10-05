#!/usr/bin/env python3
"""Exercise actual native worktree models; does not prove visual/click acceptance."""
import pathlib
import platform
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
frameworks = root / 'build/Build/Products/Debug'
sources = [root / 'Sources/TurtleGitMac' / name for name in (
    'CommandLabel.swift', 'SwitchWindow.swift', 'BranchTagWindow.swift', 'WorktreeCreateWindow.swift', 'WorktreeListWindow.swift')]
driver = r'''
import Foundation
import TurtleGitCore

// Policy simulation only: these do not provide real macOS sandbox grants.
struct TestScopes: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

@main struct WorktreeDialogVerification {
    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = folder.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Dialog QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "Initial"])
        _ = try await repo.run(["tag", "v1"])
        _ = try await repo.run(["branch", "available"])
        _ = try await repo.run(["remote", "add", "origin", root.path])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/topic", "HEAD"])
        let model = WorktreeCreateWindowModel(repository: repo, access: nil)
        precondition(model.directory == root.path + "-worktree")
        precondition(model.checkout && !model.force && !model.detach && !model.createBranch)
        model.load(); try await wait(model)
        precondition(model.error == nil && model.currentBranch == "main")
        model.useHead = false; model.chooser.options.target = .branch
        model.chooser.branchRevision = "refs/heads/main"; model.changedBase()
        precondition(model.branchName == "Branch_main" && !model.createBranch && !model.detach)
        model.chooser.branchRevision = "refs/remotes/origin/topic"; model.changedBase()
        precondition(model.branchName == "topic" && model.createBranch && !model.detach)
        model.createBranch = false; model.changedBranch()
        precondition(model.detach && model.automaticDetach)
        model.createBranch = true; model.changedBranch()
        precondition(!model.detach && !model.automaticDetach)
        model.chooser.options.target = .tag; model.chooser.tagRevision = "refs/tags/v1"; model.changedBase()
        precondition(model.branchName == "Branch_v1" && model.createBranch)
        model.createBranch = false; model.changedBranch(); precondition(model.detach && model.automaticDetach)
        model.chooser.options.target = .commit; model.chooser.commitRevision = "HEAD"; model.changedBase()
        precondition(model.branchName == "Branch_HEAD" && model.createBranch && !model.detach)
        model.detach = true; model.changedDetach(); precondition(!model.createBranch && model.detach)
        model.useHead = true; model.changedBase(); precondition(!model.createBranch && !model.detach)
        model.createBranch = true; model.changedBranch()
        model.detach = true; model.changedDetach(); precondition(!model.createBranch && model.detach)
        model.detach = false
        model.directory = folder.appendingPathComponent("dialog-topic").path
        var notified = false; model.onCreated = { _ in notified = true }
        model.create(); try await wait(model)
        precondition(model.success && model.progress && notified && !model.cancelled)
        let worktrees = try await repo.worktrees()
        precondition(worktrees.count == 2 && worktrees.last?.branch == "refs/heads/dialog-topic")
        let branch = try await repo.branch(); precondition(branch == "main")
        let local = WorktreeCreateWindowModel(repository: repo, access: nil)
        local.load(); try await wait(local)
        local.useHead = false; local.chooser.options.target = .branch
        local.chooser.branchRevision = "refs/heads/available"; local.changedBase()
        local.directory = folder.appendingPathComponent("existing-branch").path
        local.create(); try await wait(local); precondition(local.success)
        let attached = try await GitRepository(root: URL(fileURLWithPath: local.directory)).branch()
        precondition(attached == "available", "An explicit local branch must remain attached")
        let remote = WorktreeCreateWindowModel(repository: repo, access: nil)
        remote.load(); try await wait(remote)
        remote.useHead = false; remote.chooser.options.target = .branch
        remote.chooser.branchRevision = "refs/remotes/origin/topic"; remote.changedBase()
        remote.directory = folder.appendingPathComponent("remote-branch").path
        remote.create(); try await wait(remote); precondition(remote.success)
        let tracking = try await repo.run(["config", "--get", "branch.topic.remote"]).text
        precondition(tracking == "origin\n", "Remote base must preserve automatic tracking")
        let list = WorktreeListWindowModel(repository: repo, access: nil)
        list.reload(); try await waitList(list)
        precondition(list.error == nil && list.rows.count == 4)
        let main = list.rows.first!; let linked = Array(list.rows.dropFirst())
        precondition(main.isMain && !list.showRemove([main.id]) && list.showLock([main.id]))
        let batch: Set<String> = [main.id, linked[0].id, linked[1].id]
        precondition(list.showLock(batch) && list.showUnlock(batch) && list.showRemove(batch))
        list.modify(.lock, ids: [main.id, linked[0].id]); try await waitList(list)
        precondition(list.result == "Locked 1 worktree(s).")
        precondition(list.rows.first?.lockReason == nil && list.rows.first(where: { $0.id == linked[0].id })?.lockReason == "")
        precondition(!list.showLock([linked[0].id]) && list.showUnlock([linked[0].id]))
        var decisions = 0
        list.continueAfterError = { _ in decisions += 1; return true }
        list.modify(.lock, ids: batch); try await waitList(list)
        precondition(decisions == 1 && list.result == "Locked 1 worktree(s).")
        list.continueAfterError = { _ in decisions += 1; return false }
        list.modify(.lock, ids: [linked[0].id, linked[2].id]); try await waitList(list)
        precondition(decisions == 2 && list.rows.first(where: { $0.id == linked[2].id })?.lockReason == nil)
        list.modify(.unlock, ids: [linked[0].id, linked[1].id]); try await waitList(list)
        precondition(list.result == "Successfully unlocked 2 worktree(s).")
        var explored: URL?
        list.explore = { explored = $0 }; list.open([main.id]); precondition(explored == main.path)
        explored = nil; list.open(batch); precondition(explored == nil)
        list.confirmRemoval = { _, _ in false }
        list.modify(.remove, ids: [linked[0].id]); try await waitList(list)
        precondition(FileManager.default.fileExists(atPath: linked[0].path.path))
        list.confirmRemoval = { _, _ in true }
        try Data("dirty".utf8).write(to: linked[0].path.appendingPathComponent("untracked.txt"))
        list.modify(.remove, ids: [linked[0].id, linked[1].id]); try await waitList(list)
        precondition(list.failedRemoval?.id == linked[0].id)
        precondition(FileManager.default.fileExists(atPath: linked[1].path.path), "Removal must stop after its first failure")
        list.retryRemovalWithForce(); try await waitList(list)
        precondition(!FileManager.default.fileExists(atPath: linked[0].path.path))
        precondition(!FileManager.default.fileExists(atPath: linked[1].path.path), "Force retry must resume the original batch")
        try FileManager.default.removeItem(at: linked[2].path)
        list.reload(); try await waitList(list)
        guard let missing = list.rows.first(where: { $0.id == linked[2].id }) else {
            fatalError("Missing checkout identity changed: expected \(linked[2].id), got \(list.rows.map(\.id))")
        }
        precondition(list.hashLabel(missing).isEmpty && list.branchLabel(missing).isEmpty)
        list.prune(); try await waitList(list)
        precondition(list.result == "Prune completed" && list.rows.count == 1)
        // Force retry must not silently force the next originally-normal removal.
        let forceFirst = folder.appendingPathComponent("force-one"), forceSecond = folder.appendingPathComponent("force-two")
        _ = try await repo.createWorktree(at: forceFirst); _ = try await repo.createWorktree(at: forceSecond)
        for path in [forceFirst, forceSecond] { try Data("dirty".utf8).write(to: path.appendingPathComponent("untracked.txt")) }
        list.reload(); try await waitList(list)
        let forceIDs = Set(list.rows.filter { $0.path.lastPathComponent.hasPrefix("force-") }.map(\.id))
        list.modify(.remove, ids: forceIDs); try await waitList(list)
        list.retryRemovalWithForce(); try await waitList(list)
        precondition(!FileManager.default.fileExists(atPath: forceFirst.path))
        precondition(FileManager.default.fileExists(atPath: forceSecond.appendingPathComponent("untracked.txt").path))
        precondition(list.failedRemoval?.path.lastPathComponent == "force-two")
        list.abortRemovalBatch()
        // Closing an error's progress resumes the batch; Cancel stops it.
        for prefix in ["continue", "abort"] {
            let first = folder.appendingPathComponent(prefix + "-one"), second = folder.appendingPathComponent(prefix + "-two")
            _ = try await repo.createWorktree(at: first); _ = try await repo.createWorktree(at: second)
            try Data("dirty".utf8).write(to: first.appendingPathComponent("untracked.txt"))
            list.reload(); try await waitList(list)
            let ids = Set(list.rows.filter { $0.path.lastPathComponent.hasPrefix(prefix + "-") }.map(\.id))
            list.modify(.remove, ids: ids); try await waitList(list)
            precondition(list.remainingRemovals.count == 1)
            if prefix == "continue" { list.closeProgress(); try await waitList(list); precondition(!FileManager.default.fileExists(atPath: second.path)) }
            else { list.abortRemovalBatch(); precondition(FileManager.default.fileExists(atPath: second.path) && list.remainingRemovals.isEmpty) }
            precondition(FileManager.default.fileExists(atPath: first.path))
        }
        let barePath = folder.appendingPathComponent("copy.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, barePath.path])
        let bareList = WorktreeListWindowModel(repository: GitRepository(root: barePath), access: nil)
        bareList.reload(); try await waitList(bareList)
        precondition(bareList.rows.first?.isBare == true && bareList.branchLabel(bareList.rows.first!) == "main" && !bareList.hashLabel(bareList.rows.first!).isEmpty)
        let unchanged = try await repo.branch(); precondition(unchanged == "main")
        _ = try await repo.run(["switch", "--detach", "HEAD"])
        list.reload(); try await waitList(list)
        precondition(list.branchLabel(list.rows.first!) == "HEAD", "Main detached label follows the separate upstream base-row construction")
        let scopeMissing = folder.appendingPathComponent("scope-missing"), scopeLocked = folder.appendingPathComponent("scope-locked")
        _ = try await repo.createWorktree(at: scopeMissing); _ = try await repo.createWorktree(at: scopeLocked)
        _ = try await repo.lockWorktree(at: scopeLocked)
        try FileManager.default.removeItem(at: scopeMissing)
        let scoped = WorktreeListWindowModel(repository: repo, access: RepositoryAccessLease(url: root, provider: TestScopes()), requiresScope: true)
        scoped.reload(); try await waitList(scoped)
        let ungranted = scoped.rows.first(where: { $0.path.lastPathComponent == "scope-missing" })!
        precondition(!scoped.hashLabel(ungranted).isEmpty, "Ungrantable existence checks must not blank metadata as if a folder were known missing")
        var requested: [URL] = []
        scoped.authorizeWorktrees = { paths, purpose in precondition(purpose == .prune); requested = paths; return [] }
        scoped.prune(); try await waitList(scoped)
        precondition(scoped.error != nil && requested.contains(where: { $0.lastPathComponent == "scope-missing" }))
        precondition(!requested.contains(where: { $0.lastPathComponent == "scope-locked" }))
        let protected = try await repo.worktrees()
        precondition(protected.contains(where: { $0.path.lastPathComponent == "scope-missing" }), "No grant must mean no prune mutation")
        scoped.error = nil
        scoped.authorizeWorktrees = { _, _ in [RepositoryAccessLease(url: root, provider: TestScopes())] }
        scoped.prune(); try await waitList(scoped)
        precondition(scoped.error != nil, "An unrelated grant must not authorize pruning sibling worktrees")
        scoped.error = nil
        scoped.authorizeWorktrees = { _, _ in throw OperationCancellationFailure.cancelled }
        scoped.prune(); try await waitList(scoped)
        precondition(scoped.error == nil && !scoped.showProgress, "Cancelled authorization must not start Prune")
        let permissionBlocked = folder.appendingPathComponent("scope-permission-blocked")
        _ = try await repo.createWorktree(at: permissionBlocked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: permissionBlocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissionBlocked.path) }
        scoped.authorizeWorktrees = { _, _ in [RepositoryAccessLease(url: folder, provider: TestScopes())] }
        scoped.prune(); try await waitList(scoped)
        precondition(scoped.error != nil && !scoped.showProgress, "A retained grant cannot turn POSIX permission denial into known absence")
        let afterDeniedStat = try await repo.worktrees()
        precondition(afterDeniedStat.contains(where: { $0.path.lastPathComponent == "scope-missing" }), "Denied stat must abort before any pruning")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissionBlocked.path)
        scoped.error = nil
        scoped.prune(); try await waitList(scoped)
        precondition(scoped.result == "Prune completed" && !scoped.rows.contains(where: { $0.path.lastPathComponent == "scope-missing" }))
        precondition(scoped.rows.contains(where: { $0.path.lastPathComponent == "scope-locked" }))
        print("Scope-policy simulation: ungranted rows retain metadata; absent/wrong/cancelled grants and actual POSIX denial abort before Prune; parent grant enables Prune; locked directories need no grant. Real signed sandbox remains pending.")
        let cancellationPath = folder.appendingPathComponent("cancel-running-removal")
        _ = try await repo.createWorktree(at: cancellationPath)
        let wrapper = folder.appendingPathComponent("delayed-git"), started = folder.appendingPathComponent("started")
        try """
        #!/bin/sh
        if [ "$4" = worktree ] && [ "$5" = remove ]; then
            : > "$(/usr/bin/dirname "$0")/started"
            /bin/sleep 30
        fi
        exec /usr/bin/git "$@"

        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let cancellable = WorktreeListWindowModel(repository: GitRepository(root: root, executable: wrapper), access: nil)
        cancellable.reload(); try await waitList(cancellable)
        cancellable.confirmRemoval = { _, _ in true }
        let cancelID = cancellable.rows.first(where: { $0.path.lastPathComponent == "cancel-running-removal" })!.id
        cancellable.modify(.remove, ids: [cancelID])
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(FileManager.default.fileExists(atPath: started.path) && cancellable.busy, "Cancellation test must observe an active owned Git process")
        let cancelledAt = Date(); cancellable.cancel(); try await waitList(cancellable)
        precondition(Date().timeIntervalSince(cancelledAt) < 10 && cancellable.result == "Cancelled")
        precondition(FileManager.default.fileExists(atPath: cancellationPath.appendingPathComponent(".git").path))
        let afterCancel = try await repo.worktrees()
        precondition(afterCancel.contains(where: { $0.path.lastPathComponent == "cancel-running-removal" }))
        print("Actual native model cancellation: observed running removal, stopped its owned process group before mutation, preserved checkout and registration.")
        print("Actual native list model: menus, main skip, lock/unlock batches, Continue/Abort, confirmation rejection, dirty failure/Force retry, missing rows, prune and bare HEAD passed.")
        let bare = WorktreeCreateWindowModel(repository: GitRepository(root: folder.appendingPathComponent("source.git")), access: nil)
        precondition(bare.directory == folder.appendingPathComponent("source").path)
        print("Actual native model: defaults, local/remote/tag/commit suggestions, forced detach, mutual exclusion and creation callback passed.")
    }
    @MainActor static func wait(_ model: WorktreeCreateWindowModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.busy || model.chooser.busy {
            guard Date() < deadline else { fatalError("Dialog operation timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func waitList(_ model: WorktreeListWindowModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.busy {
            guard Date() < deadline else { fatalError("Worktree List operation timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='TurtleGitWorktreeDialogTest-') as directory:
    folder = pathlib.Path(directory)
    main = folder / 'Driver.swift'; main.write_text(driver)
    binary = folder / 'verify'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-target', platform.machine() + '-apple-macosx13.0',
                    '-F', str(frameworks), '-framework', 'TurtleGitCore',
                    '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                    *map(str, sources), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'fixture')], check=True)
