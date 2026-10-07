import AppKit
import TurtleGitCore

@main struct ClipboardFetchVerification {
    @MainActor static func wait(_ model: FetchWindowModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && (allowError || model.error == nil), model.error ?? "Fetch/Pull timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let source = root.appendingPathComponent("producer"), client = root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let producer = GitRepository(root: source, executable: git)
        _ = try await producer.run(["init", "-b", "main"])
        _ = try await producer.run(["config", "user.name", "Clipboard QA"]); _ = try await producer.run(["config", "user.email", "qa@example.invalid"])
        _ = try await producer.run(["config", "commit.gpgsign", "false"]); _ = try await producer.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base".utf8).write(to: source.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "base")
        _ = try await producer.run(["clone", source.path, client.path])
        let repo = GitRepository(root: client, executable: git)
        let suite = "TurtleGit.FetchClipboard.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(["history URL"], forKey: "History.PullURLS")
        var text: String? = "unrecognized text", reads = 0
        let fetch = FetchWindowModel(repository: repo, access: nil, isPull: false, preferences: preferences)
        fetch.clipboardText = { reads += 1; return text }
        fetch.load(); try await wait(fetch); precondition(reads == 0, "Do not read clipboard before URL selection")
        let index = try Data(contentsOf: client.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        fetch.selectArbitraryURL(); precondition(fetch.url == "history URL" && fetch.options.branch == "main" && reads == 1)
        text = "git pull '\(source.path)' 'main' extra"; fetch.launchRebase = true; fetch.selectArbitraryURL()
        precondition(fetch.url == source.path && fetch.options.branch == "main" && !fetch.launchRebase)
        precondition(preferences.stringArray(forKey: "History.PullURLS") == ["history URL"], "Selection must not save history")
        let afterSelectionIndex = try Data(contentsOf: client.appendingPathComponent(".git/index")), afterSelectionHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        precondition(index == afterSelectionIndex && head == afterSelectionHead)
        fetch.fetch(); try await wait(fetch)
        precondition(preferences.stringArray(forKey: "History.PullURLS")?.first == source.path)
        // The native file URL adaptation is fed to a real Git fetch literally.
        text = source.absoluteString; fetch.options.branch = "main"; fetch.selectArbitraryURL()
        precondition(fetch.url == source.absoluteString); fetch.fetch(); try await wait(fetch)
        // Pull accepts the alternate command, follows the selected branch and ignores extra tokens.
        try Data("next".utf8).write(to: source.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "next")
        let pull = FetchWindowModel(repository: repo, access: nil, isPull: true, preferences: preferences)
        pull.clipboardText = { "git fetch \(source.path) main ignored" }
        pull.load(); try await wait(pull); pull.selectArbitraryURL(); precondition(pull.url == source.path && pull.options.branch == "main")
        pull.fastForwardOnly = true; pull.fetch(); try await wait(pull)
        let contents = try Data(contentsOf: client.appendingPathComponent("file")); precondition(contents == Data("next".utf8))
        text = "git fetch \(root.appendingPathComponent("missing.git").path) main ignored"; fetch.selectArbitraryURL()
        let chosenURL = fetch.url, chosenBranch = fetch.options.branch
        fetch.fetch(); try await wait(fetch, allowError: true)
        precondition(fetch.error != nil && fetch.url == chosenURL && fetch.options.branch == chosenBranch)
        print("Pull/Fetch clipboard: reads only at URL selection; history fallback and selection-only preservation; alternate copied commands/quotes/extra tokens; actual path and file-URL Fetch, ff-only Pull and failed destination input retention passed without reading or writing the user's pasteboard")
    }
}
