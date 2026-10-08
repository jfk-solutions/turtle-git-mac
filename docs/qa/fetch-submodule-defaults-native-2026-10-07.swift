import AppKit
import TurtleGitCore

@main struct SubmoduleDefaultVerification {
    @MainActor static func wait(_ model: FetchWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "Pull/Fetch timed out")
    }
    static func configure(_ repo: GitRepository) async throws {
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Submodule Default QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let parentRoot = root.appendingPathComponent("parent"), producerRoot = root.appendingPathComponent("producer")
        for location in [parentRoot, producerRoot] { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true) }
        let parent = GitRepository(root: parentRoot, executable: git), producer = GitRepository(root: producerRoot, executable: git)
        try await configure(parent); try await configure(producer)
        try Data("base".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "base")
        let path = "group/module 雪\nname", name = "named.module 雪", key = "submodule." + name
        _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", name, "--", producerRoot.path, path])
        try await parent.stage([".gitmodules", path]); _ = try await parent.commit(message: "add module")
        let child = GitRepository(root: parentRoot.appendingPathComponent(path), executable: git)
        _ = try await child.run(["config", "--unset-all", "branch.main.merge"], successfulExitCodes: 0...5)
        _ = try await parent.run(["config", "--file", ".gitmodules", key + ".branch", "stable/雪"])
        _ = try await parent.run(["config", key + ".branch", "ignored-local-override"])
        _ = try await producer.run(["checkout", "-b", "stable/雪"])
        try Data("stable".utf8).write(to: producerRoot.appendingPathComponent("remote-only")); try await producer.stage(["remote-only"]); _ = try await producer.commit(message: "stable")
        let target = try await producer.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("dirty remains".utf8).write(to: child.root.appendingPathComponent("file"))
        let suite = "TurtleGit.SubmoduleDefaults.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "NamedRemoteFetchAll")
        let parentFiles = [".gitmodules", ".git/index", ".git/config", ".git/HEAD", ".git/refs/heads/main"]
        let beforeParent = try parentFiles.map { try Data(contentsOf: parentRoot.appendingPathComponent($0)) }
        let indexPath = try await child.run(["rev-parse", "--path-format=absolute", "--git-path", "index"]).text.trimmingCharacters(in: .newlines)
        let beforeIndex = try Data(contentsOf: URL(fileURLWithPath: indexPath)), beforeHead = try await child.run(["rev-parse", "HEAD"]).stdout
        let fetch = FetchWindowModel(repository: child, access: nil, isPull: false, preferences: preferences)
        fetch.load(); try await wait(fetch)
        precondition(fetch.options.branch == "stable/雪" && fetch.branchHistory.contains("stable/雪") && fetch.canChooseBranch)
        let loadedParent = try parentFiles.map { try Data(contentsOf: parentRoot.appendingPathComponent($0)) }
        precondition(loadedParent == beforeParent)
        fetch.fetch(); try await wait(fetch)
        let fetched = try await child.run(["rev-parse", "FETCH_HEAD"]).text.trimmingCharacters(in: .newlines)
        let afterIndex = try Data(contentsOf: URL(fileURLWithPath: indexPath)), afterHead = try await child.run(["rev-parse", "HEAD"]).stdout
        precondition(fetched == target && beforeIndex == afterIndex && beforeHead == afterHead)
        preferences.set(true, forKey: "NamedRemoteFetchAll")
        let pull = FetchWindowModel(repository: child, access: nil, isPull: true, preferences: preferences)
        pull.load(); try await wait(pull); precondition(pull.options.branch == "stable/雪" && pull.options.namedRemoteFetchAll)
        pull.fastForwardOnly = true; pull.fetch(); try await wait(pull)
        let pulled = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), branch = try await child.branch()
        let contents = try Data(contentsOf: child.root.appendingPathComponent("file"))
        let finalParent = try parentFiles.map { try Data(contentsOf: parentRoot.appendingPathComponent($0)) }
        precondition(pulled == target && branch == "main" && contents == Data("dirty remains".utf8) && finalParent == beforeParent)
        _ = try await child.run(["config", "branch.main.merge", "refs/heads/tracked"])
        fetch.finishFetch(fetch.fetchProgress!)
        fetch.load(); try await wait(fetch); precondition(fetch.options.branch == "tracked")
        print("Submodule Pull/Fetch: named Unicode/newline path, .gitmodules branch over parent override, native defaults/history, actual selected-branch Fetch and ff-only Pull, child branch/dirty file retained, parent metadata byte-identical, child tracking priority passed")
    }
}
