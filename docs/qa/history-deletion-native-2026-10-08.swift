import AppKit
import SwiftUI
import TurtleGitCore

@main struct HistoryDeletionVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while busy() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Model load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); _ = try await repo.run(["config", "user.name", "Deletion QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let suite = "TurtleGit.HistoryDeletion.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let fetch = FetchWindowModel(repository: repo, access: nil, isPull: false, preferences: preferences); fetch.clipboardText = { nil }; fetch.load(); try await wait { fetch.busy }; precondition(fetch.error == nil)
        fetch.urls = ["one", "two", "three"]; preferences.set(fetch.urls, forKey: "History.PullURLS")
        fetch.deleteURLHistory(at: 1); precondition(fetch.urls == ["one", "three"] && fetch.url == "three" && preferences.stringArray(forKey: "History.PullURLS") == fetch.urls)
        fetch.deleteURLHistory(at: 1); precondition(fetch.urls == ["one"] && fetch.url == "one")
        fetch.deleteURLHistory(at: 0); precondition(fetch.urls.isEmpty && fetch.url.isEmpty && preferences.stringArray(forKey: "History.PullURLS") == [])
        fetch.urls = ["retained"]; preferences.set(fetch.urls, forKey: "History.PullURLS"); fetch.busy = true; fetch.deleteURLHistory(at: 0); fetch.busy = false
        fetch.deleteURLHistory(at: 99); precondition(fetch.urls == ["retained"] && preferences.stringArray(forKey: "History.PullURLS") == ["retained"])
        fetch.branchHistory = ["A", "B", "C"]; preferences.set(fetch.branchHistory, forKey: "History.PullRemoteBranch"); fetch.deleteBranchHistory(at: 1)
        precondition(fetch.branchHistory == ["A", "C"] && fetch.options.branch == "C")
        let pull = FetchWindowModel(repository: repo, access: nil, isPull: true, preferences: preferences); pull.clipboardText = { nil }; pull.load(); try await wait { pull.busy }
        precondition(pull.urls == ["retained"] && pull.branchHistory.prefix(2).elementsEqual(["A", "C"]))
        pull.deleteURLHistory(at: 0); precondition(preferences.stringArray(forKey: "History.PullURLS") == [])
        let push = PushWindowModel(repository: repo, access: nil, preferences: preferences); push.load(); try await wait { push.busy }; precondition(push.error == nil)
        push.urls = ["Z", "a", "A"]; preferences.set(push.urls, forKey: push.urlHistoryKey); push.deleteURLHistory(at: 1)
        precondition(push.urls == ["Z", "A"] && push.url == "A" && preferences.stringArray(forKey: push.urlHistoryKey) == push.urls)
        push.destinationHistory = ["first", "last"]; preferences.set(push.destinationHistory, forKey: push.destinationHistoryKey); push.deleteDestinationHistory(at: 1)
        precondition(push.destinationHistory == ["first"] && push.options.destination == "first")
        push.pushOptionHistory = ["one"]; preferences.set(push.pushOptionHistory, forKey: push.pushOptionHistoryKey); push.deletePushOptionHistory(at: 0)
        precondition(push.options.pushOption.isEmpty && preferences.stringArray(forKey: push.pushOptionHistoryKey) == [])
        var closed = 0; push.close = { closed += 1 }; push.cancel(); precondition(closed == 1)
        let reopened = PushWindowModel(repository: repo, access: nil, preferences: preferences); reopened.load(); try await wait { reopened.busy }
        precondition(reopened.urls == ["Z", "A"] && reopened.destinationHistory == ["first"] && reopened.pushOptionHistory.isEmpty)
        // Inspect actual editable control and direct native key receiver, without injecting events into the app.
        func find(_ view: NSView) -> EditableHistoryCombo? { if let field = view as? EditableHistoryCombo { return field }; return view.subviews.compactMap { find($0) }.first }
        var removed: [Int] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 80), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FetchHistoryCombo(value: .constant("a"), choices: ["Z", "a", "A"], label: "History", onDelete: { removed.append($0) })); window.contentView?.layoutSubtreeIfNeeded()
        guard let field = window.contentView.flatMap({ find($0) }), let delegate = field.delegate as? FetchHistoryCombo.Coordinator else { preconditionFailure("History control missing") }
        precondition(field.indexOfSelectedItem == 1 && field.stringValue == "a")
        func event(_ key: UInt16, shift: Bool) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)! }
        precondition(!field.handleHistoryKey(event(117, shift: true)) && removed.isEmpty)
        delegate.comboBoxWillPopUp(Notification(name: NSComboBox.willPopUpNotification, object: field))
        precondition(!field.handleHistoryKey(event(117, shift: false)))
        precondition(field.handleHistoryKey(event(117, shift: true)) && removed == [1])
        precondition(field.handleHistoryKey(event(51, shift: true)) && removed == [1, 1])
        field.isEnabled = false; precondition(!field.handleHistoryKey(event(117, shift: true))); field.isEnabled = true
        field.deleteHistory = nil; precondition(field.handleHistoryKey(event(117, shift: true)) && removed == [1, 1])
        field.replaceHistory(["Z", "A"])
        precondition(field.numberOfItems == 2 && field.itemObjectValue(at: 1) as? String == "A" && field.historyPopupOpen)
        delegate.comboBoxWillDismiss(Notification(name: NSComboBox.willDismissNotification, object: field))
        precondition(!field.handleHistoryKey(event(51, shift: true))); window.close()
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        precondition(head == afterHead && index == afterIndex && config == afterConfig)
        print("History deletion: immediate ordered persistence, next/previous/empty selection, invalid/busy gates, Pull/Fetch sharing and Push scoped keys, cancel/reopen retention; actual hidden control selection and native Shift+Delete/Forward Delete receiver open/closed/disabled/permission gates; exact HEAD/index/config unchanged passed")
    }
}
