import AppKit
import SwiftUI
import TurtleGitCore

@main struct PushHistoryVerification {
    @MainActor static func wait(_ model: PushWindowModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && (allowError || model.error == nil), model.error ?? "Push timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.PushHistory.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let client = root.appendingPathComponent("client"), bare = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        let repo = GitRepository(root: client, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Push History QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base".utf8).write(to: client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["clone", "--bare", client.path, bare.path]); _ = try await repo.run(["remote", "add", "origin", bare.path])
        let remote = GitRepository(root: bare, executable: git); _ = try await remote.run(["config", "receive.advertisePushOptions", "true"])
        _ = try await repo.run(["config", "branch.main.merge", "refs/heads/main"]); _ = try await repo.run(["config", "branch.main.remote", "origin"])
        _ = try await repo.run(["config", "branch.main.pushbranch", "target"])
        let model = PushWindowModel(repository: repo, access: nil, preferences: preferences)
        let urlKey = model.urlHistoryKey, branchKey = model.destinationHistoryKey, optionKey = model.pushOptionHistoryKey
        preferences.set(["last", "Last"], forKey: urlKey); preferences.set(["older", "TARGET"], forKey: branchKey); preferences.set(["option", "Option"], forKey: optionKey)
        model.clipboardText = { nil }; model.load(); try await wait(model)
        precondition(model.options.source == "main")
        precondition(model.urls == ["last", "Last"] && model.pushOptionHistory == ["option", "Option"] && model.url.isEmpty && model.options.pushOption.isEmpty)
        precondition(model.destinationHistory == ["older", "TARGET"] && model.options.destination == "TARGET")
        model.selectDestination("browse"); precondition(model.destinationHistory.first == "browse" && preferences.stringArray(forKey: branchKey) == ["older", "TARGET"])
        let index = try Data(contentsOf: client.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        model.selectArbitraryURL(); precondition(model.url == "last" && model.options.destination == "browse" && !model.options.setUpstream)
        var reads = 0; model.clipboardText = { reads += 1; return "git pull \"\(bare.path)\" 'published' --extra ignored" }
        model.selectArbitraryURL(); precondition(reads == 1 && model.url == bare.path && model.options.destination == "published")
        precondition(preferences.stringArray(forKey: urlKey) == ["last", "Last"] && preferences.stringArray(forKey: branchKey) == ["older", "TARGET"])
        let selectedHead = try await repo.run(["rev-parse", "HEAD"]).stdout; precondition(selectedHead == head)
        var successes = 0; model.onPushed = { _ in successes += 1 }
        model.options.pushOption = "  review=two words; literal  "
        model.push()
        // A queued field/default update must not replace the submitted history or transport values.
        model.options.destination = "later-display"; model.options.pushOption = "later-display-option"
        try await wait(model)
        let received = try await remote.run(["rev-parse", "refs/heads/published"]).stdout; precondition(received == head && successes == 1)
        precondition(preferences.stringArray(forKey: urlKey) == [bare.path, "last", "Last"] && preferences.stringArray(forKey: branchKey)?.first == "published")
        precondition(preferences.stringArray(forKey: optionKey) == ["review=two words; literal", "option", "Option"])
        // Failed transport retains histories; invalid submission must not add entries.
        model.url = root.appendingPathComponent("missing.git").path; model.options.destination = "failed"; model.options.pushOption = "Option"
        model.push(); try await wait(model, allowError: true); precondition(model.error != nil && model.options.destination == "failed")
        precondition(preferences.stringArray(forKey: urlKey)?.first == model.url && preferences.stringArray(forKey: branchKey)?.first == "failed")
        precondition(preferences.stringArray(forKey: optionKey)?.prefix(2).elementsEqual(["Option", "review=two words; literal"]) == true)
        let savedURLs = preferences.stringArray(forKey: urlKey), savedBranches = preferences.stringArray(forKey: branchKey), savedOptions = preferences.stringArray(forKey: optionKey)
        model.options.destination = "../invalid"; model.options.pushOption = "not-saved"; model.push(); try await wait(model, allowError: true)
        precondition(preferences.stringArray(forKey: urlKey) == savedURLs && preferences.stringArray(forKey: branchKey) == savedBranches && preferences.stringArray(forKey: optionKey) == savedOptions)
        // A short branch/tag collision must reject before histories or config change.
        _ = try await repo.run(["branch", "collision"]); _ = try await repo.run(["tag", "collision"])
        model.options.source = "collision"; model.options.destination = "collision-target"
        model.push(); try await wait(model, allowError: true)
        precondition(model.error == "Choose an unambiguous local reference or revision.")
        precondition(preferences.stringArray(forKey: urlKey) == savedURLs && preferences.stringArray(forKey: branchKey) == savedBranches && preferences.stringArray(forKey: optionKey) == savedOptions)
        let unchangedRefs = try await remote.checkoutReferences(); precondition(!unchangedRefs.contains { $0.name == "refs/heads/collision-target" })
        // Initial selections and browser picks normalize branch identity but retain tag/hash inputs.
        let sourceSelection = PushWindowModel(repository: repo, access: nil, preferences: preferences)
        sourceSelection.load(source: "refs/heads/collision"); try await wait(sourceSelection)
        precondition(sourceSelection.options.source == "collision" && sourceSelection.localBranch == "collision")
        if let branch = sourceSelection.references.first(where: { $0.name == "refs/heads/collision" }) { sourceSelection.pick(branch, destination: false); precondition(sourceSelection.options.source == "collision") } else { preconditionFailure("Missing local branch") }
        sourceSelection.options.remote = "origin"; sourceSelection.options.destination = "blocked-sourceSelection"; sourceSelection.push(); try await wait(sourceSelection, allowError: true)
        precondition(sourceSelection.error == "Choose an unambiguous local reference or revision.")
        precondition(preferences.stringArray(forKey: branchKey) == savedBranches)
        sourceSelection.load(source: "refs/tags/collision"); try await wait(sourceSelection, allowError: true)
        precondition(sourceSelection.options.source == "refs/tags/collision" && sourceSelection.localBranch == nil)
        sourceSelection.error = nil; sourceSelection.load(source: String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines)); try await wait(sourceSelection)
        precondition(sourceSelection.options.source == String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines))
        _ = try await repo.run(["tag", "main"])
        sourceSelection.load(source: "refs/heads/main"); try await wait(sourceSelection)
        precondition(sourceSelection.options.source == "main" && sourceSelection.localBranch == "main" && sourceSelection.options.remote == "origin")
        _ = try await repo.run(["tag", "-d", "main"])
        model.options.source = "refs/heads/main"
        // All branches asks before saving and excludes URL/branch entries, but saves server options.
        model.url = bare.path; model.options.allBranches = true; model.options.pushOption = "all-option"; model.push()
        precondition(!model.busy && model.confirmation != nil && preferences.stringArray(forKey: optionKey) == savedOptions)
        model.confirmation = nil; model.push(confirmed: true); try await wait(model)
        precondition(preferences.stringArray(forKey: urlKey) == savedURLs && preferences.stringArray(forKey: branchKey) == savedBranches && preferences.stringArray(forKey: optionKey)?.first == "all-option")
        // Deleting a remote branch similarly excludes URL/branch history.
        model.options.allBranches = false; model.options.destination = "published"; model.options.source = ""; model.sourceChanged()
        precondition(model.options.destination == "published" && !model.canTrack)
        model.options.pushOption = "delete-option"
        model.push(confirmed: true); try await wait(model)
        let refs = try await remote.checkoutReferences(); precondition(!refs.contains { $0.name == "refs/heads/published" })
        precondition(preferences.stringArray(forKey: urlKey) == savedURLs && preferences.stringArray(forKey: branchKey) == savedBranches && preferences.stringArray(forKey: optionKey)?.first == "delete-option")
        // Named-remote submission saves destination but not an unused URL.
        model.load(); try await wait(model); model.options.destination = "named"; model.url = "unused URL"; model.push(); try await wait(model)
        precondition(preferences.stringArray(forKey: urlKey) == savedURLs && preferences.stringArray(forKey: branchKey)?.first == "named")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try Data(contentsOf: client.appendingPathComponent(".git/index"))
        precondition(head == afterHead && index == afterIndex)
        // Histories are scoped to repository paths, unlike Pull/Fetch histories.
        let other = PushWindowModel(repository: remote, access: nil, preferences: preferences); other.clipboardText = { nil }; other.load(); try await wait(other)
        precondition(other.urls.isEmpty && other.destinationHistory.isEmpty && other.pushOptionHistory.isEmpty)
        preferences.set((0..<25).map { "url-\($0)" }, forKey: urlKey)
        let loaded = FetchDialogHistory.load(preferences, key: urlKey, caseSensitive: true)
        let saved = FetchDialogHistory.save("new", entries: loaded, preferences: preferences, key: urlKey, caseSensitive: true)
        precondition(saved.count == 26 && FetchDialogHistory.load(preferences, key: urlKey, caseSensitive: true).count == 25)
        precondition(FetchDialogHistory.inserting(" x\r\ny ", into: [], atFront: true, caseSensitive: true) == ["x  y"])
        // Exercise the native ordered combo and actual selection delegate without displaying a window.
        var selected = ""; let combo = FetchHistoryCombo.Coordinator(); combo.choices = ["Z", "a", "A"]; combo.change = { selected = $0 }
        let control = NSComboBox(); control.addItems(withObjectValues: combo.choices); control.selectItem(at: 2)
        combo.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: control)); precondition(selected == "A")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = NSHostingController(rootView: FetchHistoryCombo(value: .constant("A"), choices: ["Z", "a", "A"], label: "Push option")); window.contentView?.layoutSubtreeIfNeeded(); window.close()
        func findCombo(_ view: NSView) -> NSComboBox? { if let combo = view as? NSComboBox { return combo }; return view.subviews.compactMap { findCombo($0) }.first }
        for normalize in [false, true] {
            var chosen = "refs/heads/main"
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 80), styleMask: [.titled], backing: .buffered, defer: false); host.isReleasedWhenClosed = false
            host.contentViewController = NSHostingController(rootView: PushRefCombo(value: Binding(get: { chosen }, set: { chosen = $0 }), choices: ["refs/heads/main", "refs/remotes/origin/main"], local: true, normalizeSource: normalize))
            host.contentView?.layoutSubtreeIfNeeded()
            guard let field = host.contentView.flatMap({ findCombo($0) }), let delegate = field.delegate as? PushRefCombo.Coordinator else { preconditionFailure("Native Push source combo missing") }
            precondition(field.stringValue == (normalize ? "refs/heads/main" : "main"))
            let index = delegate.values.firstIndex(of: normalize ? "main" : "refs/heads/main")!; field.selectItem(at: index)
            delegate.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: field))
            precondition(chosen == (normalize ? "main" : "refs/heads/main")); host.close()
        }
        print("Push history: repository-scoped URL/branch/option ordering and case rules; source default selection, browse without saving, copied Pull/Fetch prefilling; real URL/named push and deletion; validation/confirmation/exclusion gates, failed transport persistence, unchanged HEAD/index, 26-save/25-load and hidden native combo selection passed")
    }
}
