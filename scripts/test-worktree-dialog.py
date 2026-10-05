#!/usr/bin/env python3
"""Exercise the actual native dialog model; does not prove visual/click acceptance."""
import pathlib
import platform
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
frameworks = root / 'build/Build/Products/Debug'
sources = [root / 'Sources/TurtleGitMac' / name for name in (
    'CommandLabel.swift', 'SwitchWindow.swift', 'BranchTagWindow.swift', 'WorktreeCreateWindow.swift')]
driver = r'''
import Foundation
import TurtleGitCore

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
