import AppKit
import SwiftUI
import TurtleGitCore

@main struct FetchHistoryVerification {
    @MainActor static func wait(_ model: FetchWindowModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && (allowError || model.error == nil), model.error ?? "Fetch/Pull timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.FetchHistory.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let urlKey = "History.PullURLS", branchKey = "History.PullRemoteBranch"
        let source = root.appendingPathComponent("producer"), bare = root.appendingPathComponent("remote.git"), client = root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let producer = GitRepository(root: source, executable: git)
        _ = try await producer.run(["init", "-b", "main"])
        _ = try await producer.run(["config", "user.name", "History QA"]); _ = try await producer.run(["config", "user.email", "qa@example.invalid"])
        _ = try await producer.run(["config", "commit.gpgsign", "false"]); _ = try await producer.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base".utf8).write(to: source.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "base")
        _ = try await producer.run(["clone", "--bare", source.path, bare.path]); _ = try await producer.run(["clone", bare.path, client.path])
        let repo = GitRepository(root: client, executable: git)
        let fetch = FetchWindowModel(repository: repo, access: nil, isPull: false, preferences: preferences)
        fetch.clipboardText = { nil }
        fetch.load(); try await wait(fetch)
        precondition(fetch.urls.isEmpty && fetch.branchHistory == ["main"])
        // Failure persists selected URL/branch before transport while protecting Git state.
        fetch.selectArbitraryURL(); fetch.url = "  " + root.appendingPathComponent("missing.git").path + "  "; fetch.options.branch = "main"
        let index = try Data(contentsOf: client.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        fetch.fetch(); try await wait(fetch, allowError: true); precondition(fetch.error != nil)
        let missing = root.appendingPathComponent("missing.git").path
        precondition(preferences.stringArray(forKey: urlKey) == [missing] && preferences.stringArray(forKey: branchKey)?.first == "main")
        let afterIndex = try Data(contentsOf: client.appendingPathComponent(".git/index")), afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        precondition(index == afterIndex && head == afterHead)
        // Native Pull shares the histories and fetches/merges the exact chosen URL.
        try Data("next".utf8).write(to: source.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "next")
        _ = try await producer.run(["push", bare.path, "main"])
        let pull = FetchWindowModel(repository: repo, access: nil, isPull: true, preferences: preferences)
        pull.clipboardText = { nil }
        pull.load(); try await wait(pull); precondition(pull.urls == [missing])
        pull.selectArbitraryURL(); precondition(pull.url == missing)
        pull.url = bare.path; pull.options.branch = "main"; pull.fastForwardOnly = true
        pull.launchRebase = true; pull.onRebase = { _, _, _ in preconditionFailure("URL mode must not launch Rebase") }
        var completed = 0; pull.onFetched = { _ in completed += 1 }; pull.fetch(); try await wait(pull)
        let contents = try Data(contentsOf: client.appendingPathComponent("file"))
        precondition(contents == Data("next".utf8) && completed == 1 && preferences.stringArray(forKey: urlKey) == [bare.path, missing])
        // A different repository and Fetch window restore shared histories.
        let other = FetchWindowModel(repository: producer, access: nil, isPull: false, preferences: preferences)
        other.load(); try await wait(other); precondition(other.urls == [bare.path, missing])
        let storedBranches = preferences.stringArray(forKey: branchKey)
        other.selectBranch("topic"); precondition(other.options.branch == "topic" && other.branchHistory.first == "topic")
        precondition(preferences.stringArray(forKey: branchKey) == storedBranches, "Browse/cancel must not save branch history")
        let beforeUnusedURL = preferences.stringArray(forKey: urlKey)
        fetch.error = nil; fetch.options.arbitraryURL = false; fetch.options.remote = "origin"; fetch.url = "unused URL"
        fetch.fetch(); try await wait(fetch)
        precondition(preferences.stringArray(forKey: urlKey) == beforeUnusedURL)
        // Source order, duplicate behavior, line folding and the 26-save/25-load boundary.
        preferences.set((0..<25).map { "url-\($0)" }, forKey: urlKey)
        let loaded = FetchDialogHistory.load(preferences, key: urlKey, caseSensitive: true)
        let saved = FetchDialogHistory.save("new", entries: loaded, preferences: preferences, key: urlKey, caseSensitive: true)
        precondition(saved.count == 26 && saved.first == "new" && saved.last == "url-24")
        let reopened = FetchDialogHistory.load(preferences, key: urlKey, caseSensitive: true)
        precondition(reopened.count == 25 && reopened.last == "url-23")
        precondition(FetchDialogHistory.inserting("\t a\r\nb \t", into: [], atFront: true, caseSensitive: true) == ["a  b"])
        precondition(FetchDialogHistory.inserting("URL", into: ["url"], atFront: true, caseSensitive: true) == ["URL", "url"])
        precondition(FetchDialogHistory.inserting("MAIN", into: ["topic", "main"], atFront: true, caseSensitive: false) == ["MAIN", "topic"])
        precondition(FetchDialogHistory.inserting("MAIN", into: ["main"], atFront: true, caseSensitive: false) == ["main"])
        let unicode = FetchDialogHistory.inserting("é", into: ["e\u{301}"], atFront: true, caseSensitive: true)
        precondition(unicode.count == 2, "URL deduplication must compare UTF-16 units")
        // Exercise the actual native editable combo's ordered items and selection callback.
        var selected = "typed URL"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FetchHistoryCombo(value: Binding(get: { selected }, set: { selected = $0 }), choices: ["second", "first"], label: "Remote URL or path").frame(width: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        func combo(_ view: NSView) -> NSComboBox? { if let value = view as? NSComboBox { return value }; return view.subviews.compactMap { combo($0) }.first }
        let control = combo(window.contentView!)!
        precondition(control.objectValues as? [String] == ["second", "first"] && control.stringValue == "typed URL")
        control.selectItem(at: 1); (control.delegate as! FetchHistoryCombo.Coordinator).comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: control))
        precondition(selected == "first"); window.close()
        print("Pull/Fetch history: shared repositories/dialogs, failed URL preservation, real URL Pull and named Fetch, unused URL exclusion, ordering/case/UTF-16/line folding, 26-save/25-load and native hidden combo selection passed")
    }
}
