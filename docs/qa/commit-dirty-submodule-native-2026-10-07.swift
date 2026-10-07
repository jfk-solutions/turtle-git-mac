import AppKit
import TurtleGitCore

@main struct DirtySubmoduleVerification {
    @MainActor static func wait(_ model: CommitWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "Commit did not finish")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: executable)
        let childRoot = root.appendingPathComponent("child 雪")
        try FileManager.default.createDirectory(at: childRoot, withIntermediateDirectories: true)
        let child = GitRepository(root: childRoot, executable: executable)
        for repository in [repo, child] {
            _ = try await repository.run(["init", "-b", "main"])
            _ = try await repository.run(["config", "user.name", "Dirty Module QA"])
            _ = try await repository.run(["config", "user.email", "qa@example.invalid"])
            _ = try await repository.run(["config", "commit.gpgsign", "false"])
            _ = try await repository.run(["config", "core.hooksPath", "/dev/null"])
        }
        try Data("child base".utf8).write(to: childRoot.appendingPathComponent("file"))
        try await child.stage(["file"]); _ = try await child.commit(message: "child base")
        let base = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("parent base".utf8).write(to: root.appendingPathComponent("file"))
        try await repo.stage(["file"])
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + base + ",child 雪"])
        _ = try await repo.commit(message: "parent base")
        try Data("child next".utf8).write(to: childRoot.appendingPathComponent("file"))
        try await child.stage(["file"]); _ = try await child.commit(message: "child next")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("dirty content stays".utf8).write(to: childRoot.appendingPathComponent("file"))
        try Data("parent change".utf8).write(to: root.appendingPathComponent("file"))
        let model = CommitWindowModel(repository: repo, access: nil)
        let identity = try await repo.commitMessageHistoryIdentity()
        defer { UserDefaults.standard.removeObject(forKey: "Commit.MessageHistory." + Data(identity.utf8).base64EncodedString()) }
        model.reload(); try await wait(model); model.message = "parent selection"
        model.checked = ["file", "child 雪"]
        precondition(model.canCommit)
        var prompts: [String] = [], childRequests: [URL] = [], closed = 0
        model.close = { closed += 1 }; model.onCommitSubmodule = { childRequests.append($0) }
        let paths = [".git/index", ".git/HEAD", ".git/refs/heads/main", "file", "child 雪/.git/index", "child 雪/.git/refs/heads/main", "child 雪/file"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        model.confirmDirtySubmodule = { path, choose in prompts.append(path); choose(.cancel) }
        model.commit(); try await wait(model)
        precondition(prompts == ["child 雪"] && closed == 0 && childRequests.isEmpty)
        let cancelled = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(cancelled == before)
        model.confirmDirtySubmodule = { path, choose in prompts.append(path); choose(.commit) }
        model.commit(); try await wait(model)
        precondition(childRequests.map(\.path) == [childRoot.path] && closed == 0)
        let handedOff = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(handedOff == before)
        model.confirmDirtySubmodule = { path, choose in prompts.append(path); choose(.ignore) }
        model.commit(); try await wait(model); precondition(closed == 1)
        let committedLink = try await repo.run(["rev-parse", "HEAD:child 雪"]).text.trimmingCharacters(in: .newlines)
        precondition(committedLink == next)
        let dirtyContents = try Data(contentsOf: childRoot.appendingPathComponent("file")); precondition(dirtyContents == Data("dirty content stays".utf8))
        // Stage the changed gitlink while dirty contents remain; staged mode warns.
        try Data("third child".utf8).write(to: childRoot.appendingPathComponent("file"))
        try await child.stage(["file"]); _ = try await child.commit(message: "third child")
        try Data("still dirty".utf8).write(to: childRoot.appendingPathComponent("file"))
        try await repo.stage(["child 雪"])
        model.reload(); try await wait(model); model.stagingEnabled = true; model.message = "staged link"
        model.confirmDirtySubmodule = { path, choose in prompts.append(path); choose(.cancel) }
        let stagedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), count = prompts.count
        model.commit(); try await wait(model); precondition(prompts.count == count + 1 && closed == 1)
        let cancelledStage = try Data(contentsOf: root.appendingPathComponent(".git/index")); precondition(cancelledStage == stagedIndex)
        // Message-only mode bypasses dirty-child prompts, like CommitDlg.
        model.messageOnly = true; model.commit(); try await wait(model)
        precondition(prompts.count == count + 1 && closed == 2)
        let finalContents = try Data(contentsOf: childRoot.appendingPathComponent("file")); precondition(finalContents == Data("still dirty".utf8))
        print("Dirty submodule Commit: Cancel and child handoff preserve both repositories; Ignore commits only the child gitlink; staging warns and message-only bypasses; child dirty contents retained")
    }
}
