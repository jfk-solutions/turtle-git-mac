import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct CommitMetadataVerification {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static func require(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        if !value() { throw Failure(description: "Requirement failed at \(file):\(line)") }
    }
    @MainActor final class Replies<Value> {
        private(set) var count = 0
        private(set) var pending: [Int: CheckedContinuation<Value?, Error>] = [:]
        func next() async throws -> Value? {
            try await withCheckedThrowingContinuation { continuation in
                pending[count] = continuation; count += 1
            }
        }
        func resolve(_ index: Int, _ value: Value?) throws {
            guard let continuation = pending.removeValue(forKey: index) else { throw Failure(description: "Missing query \(index)") }
            continuation.resume(returning: value)
        }
        func fail(_ index: Int) throws {
            guard let continuation = pending.removeValue(forKey: index) else { throw Failure(description: "Missing query \(index)") }
            continuation.resume(throwing: Failure(description: "Obsolete query error"))
        }
    }
    @MainActor static func wait(_ host: NSView, until ready: () -> Bool) async throws {
        for _ in 0..<500 {
            host.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Timed out waiting for native transition")
    }
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func find<T: NSView>(_ type: T.Type, in view: NSView, label: String? = nil) -> T? {
        if let result = view as? T, label == nil || result.accessibilityLabel() == label { return result }
        for child in view.subviews { if let result = find(type, in: child, label: label) { return result } }
        return nil
    }
    @MainActor static func ready(_ model: CommitWindowModel) -> Bool {
        !model.busy && !model.loadingAuthorIdentity && !model.loadingAuthorDate && !model.loadingAmendMessage
    }
    @MainActor static func main() async {
        do { try await verify() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.CommitMetadata.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let clipboard = NSPasteboard.withUniqueName(); defer { clipboard.releaseGlobally() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Configured Author"])
        _ = try await repo.run(["config", "user.email", "configured@example.test"])
        _ = try await repo.run(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "user.name=HEAD Author", "-c", "user.email=head@example.test", "commit", "--allow-empty", "--date=2001-02-03T04:05:06Z", "-m", "HEAD draft"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let headDate = Date(timeIntervalSince1970: 981173106)
        let configured = "Configured Author <configured@example.test>"
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        model.message = "Normal draft"; model.messageOnly = true
        let host = NSHostingView(rootView: CommitDialog(model: model).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        model.reload(); try await wait(host) { ready(model) && model.hasHead && model.canCommit }
        model.setAuthor = true; model.setAuthorDate = true; try await settle(host)
        try await wait(host) { ready(model) && model.author == configured }
        model.amend = true; try await settle(host)
        try await wait(host) { ready(model) && model.author == "HEAD Author <head@example.test>" && model.authorDate == headDate }
        try require(model.message.trimmingCharacters(in: .newlines) == "HEAD draft" && model.canCommit)
        let beforeUnamend = Date()
        model.amend = false; try await settle(host)
        try await wait(host) { ready(model) && model.author == configured }
        try require(model.message == "Normal draft" && model.authorDate >= beforeUnamend && model.authorDate <= Date())
        try require(!model.resetAuthorDate && model.canCommit)
        model.amend = true; try await settle(host)
        try await wait(host) { ready(model) && model.authorDate == headDate }
        guard let author = find(NSTextField.self, in: host, label: "Author identity") else { throw Failure(description: "Author field missing") }
        let authors = Replies<String>()
        model.queryCommitAuthor = { amend in
            try require(amend)
            return try await authors.next()
        }
        model.authorChanged(); try await wait(host) { authors.count == 1 }; try await settle(host)
        try require(model.loadingAuthorIdentity && !model.canCommit && !author.isEditable && author.isSelectable)
        author.selectText(nil)
        guard let readonly = author.currentEditor() as? NSTextView else { throw Failure(description: "Read-only editor missing") }
        try require(readonly.writeSelection(to: clipboard, types: readonly.writablePasteboardTypes))
        try require(clipboard.string(forType: .string) == model.author)
        model.authorChanged(); try await wait(host) { authors.count == 2 }
        try authors.resolve(1, "Latest Author <latest@example.test>")
        try await wait(host) { !model.loadingAuthorIdentity && model.author == "Latest Author <latest@example.test>" }
        try authors.resolve(0, "Old Author <old@example.test>"); try await settle(host)
        try require(model.author == "Latest Author <latest@example.test>" && model.canCommit)
        model.authorChanged(); try await wait(host) { authors.count == 3 }
        model.authorChanged(); try await wait(host) { authors.count == 4 }
        try authors.resolve(3, "Newest Author <newest@example.test>")
        try await wait(host) { !model.loadingAuthorIdentity }
        try authors.fail(2); try await settle(host)
        try require(model.error == nil && model.author == "Newest Author <newest@example.test>")
        model.author = "caf\u{e9} <unicode@example.test>"
        model.authorChanged(); try await wait(host) { authors.count == 5 }
        model.author = "cafe\u{301} <unicode@example.test>"
        try authors.resolve(4, "Would replace draft <overwrite@example.test>"); try await settle(host)
        try require(model.author.utf8.elementsEqual("cafe\u{301} <unicode@example.test>".utf8) && !model.loadingAuthorIdentity)
        let dates = Replies<Date>()
        model.queryCommitAuthorDate = { try await dates.next() }
        model.dateChanged(); try await wait(host) { dates.count == 1 }; try await settle(host)
        try require(model.loadingAuthorDate && !model.canCommit)
        guard let picker = find(NSDatePicker.self, in: host) else { throw Failure(description: "Author date picker missing") }
        try require(!picker.isEnabled)
        model.dateChanged(); try await wait(host) { dates.count == 2 }
        try dates.resolve(0, .distantPast); try await settle(host)
        try require(model.loadingAuthorDate && model.authorDate == headDate && !model.canCommit)
        let latestDate = Date(timeIntervalSince1970: 1600000000)
        try dates.resolve(1, latestDate); try await settle(host)
        try require(!model.loadingAuthorDate && model.authorDate == latestDate && model.canCommit && picker.isEnabled)
        model.dateChanged(); try await wait(host) { dates.count == 3 }
        model.setAuthorDate = false; try await settle(host)
        try require(!model.loadingAuthorDate && model.canCommit)
        try dates.fail(2); try await settle(host)
        try require(model.error == nil && model.authorDate == latestDate)
        try require(authors.pending.isEmpty && dates.pending.isEmpty)
        // A fresh dialog has no cached amend draft. Exercise on/off/on while
        // first and second HEAD-message requests are both suspended.
        let fresh = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        fresh.message = "Fresh normal draft"; fresh.messageOnly = true
        let freshHost = NSHostingView(rootView: CommitDialog(model: fresh).defaultAppStorage(prefs))
        let freshWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        freshWindow.isReleasedWhenClosed = false; freshWindow.contentView = freshHost; defer { freshWindow.close() }
        fresh.reload(); try await wait(freshHost) { ready(fresh) && fresh.canCommit }
        let messages = Replies<String>()
        fresh.queryAmendMessage = { try await messages.next() }
        fresh.amend = true; try await wait(freshHost) { messages.count == 1 }; try await settle(freshHost)
        guard let messageEditor = find(NSTextView.self, in: freshHost, label: "Commit message") else { throw Failure(description: "Message editor missing") }
        try require(fresh.loadingAmendMessage && !fresh.canCommit && !messageEditor.isEditable)
        fresh.amend = false; try await settle(freshHost)
        try await wait(freshHost) { ready(fresh) && fresh.canCommit }
        try require(fresh.message == "Fresh normal draft")
        fresh.amend = true; try await wait(freshHost) { messages.count == 2 }
        try messages.resolve(1, "Latest amend message")
        try await wait(freshHost) { ready(fresh) && fresh.message == "Latest amend message" && fresh.canCommit }
        try messages.resolve(0, "Obsolete amend message"); try await settle(freshHost)
        try require(fresh.message == "Latest amend message" && messageEditor.isEditable)
        fresh.amend = false; try await settle(freshHost); try await wait(freshHost) { ready(fresh) }
        fresh.amend = true; try await settle(freshHost); try await wait(freshHost) { ready(fresh) }
        try require(fresh.message == "Latest amend message" && messages.count == 2 && messages.pending.isEmpty)
        // This is a supplied Replay Split control-state fixture, not a real
        // rebase execution. No Commit is performed in this receiver.
        model.setAuthorDate = true; try await wait(host) { dates.count == 4 }
        model.authorChanged(); try await wait(host) { authors.count == 6 }
        let replayAuthor = "Replay Author <replay@example.test>"
        let replayDateText = "2007-01-02T03:04:05Z"
        let replayDate = ISO8601DateFormatter().date(from: replayDateText)!
        let payload: [String: Any] = ["entryID": "QA supplied split", "step": 0, "expectedHead": head.trimmingCharacters(in: .newlines), "parts": 0, "firstAuthor": replayAuthor, "firstDate": replayDateText, "squashDate": 0]
        let split = try JSONDecoder().decode(RebaseSplitState.self, from: JSONSerialization.data(withJSONObject: payload))
        model.loadReplaySplit(split, message: "Replay supplied draft")
        try await wait(host) { ready(model) }; try await settle(host)
        try authors.resolve(5, "Obsolete ordinary author <old@example.test>")
        try dates.resolve(3, .distantPast); try await settle(host)
        model.authorChanged(); model.dateChanged(); try await settle(host)
        try require(model.author == replayAuthor && model.authorDate == replayDate && model.message == "Replay supplied draft")
        try require(!model.loadingAuthorIdentity && !model.loadingAuthorDate && authors.count == 6 && dates.count == 4)
        try require(authors.pending.isEmpty && dates.pending.isEmpty && author.stringValue == replayAuthor)
        guard let replayPicker = find(NSDatePicker.self, in: host) else { throw Failure(description: "Replay date picker missing") }
        try require(replayPicker.dateValue == replayDate)
        // Presets suppress their installation notification, not future user
        // checkbox changes: those must still run the ordinary source handlers.
        model.setAuthor = false; try await wait(host) { authors.count == 7 }
        try authors.resolve(6, "HEAD Author <head@example.test>"); try await settle(host)
        try require(model.author == "HEAD Author <head@example.test>" && !author.isEditable)
        model.setAuthor = true; try await wait(host) { authors.count == 8 }
        try authors.resolve(7, "HEAD Author <head@example.test>"); try await settle(host)
        try require(author.isEditable && !model.loadingAuthorIdentity)
        model.setAuthorDate = false; try await settle(host)
        model.setAuthorDate = true; try await wait(host) { dates.count == 5 }
        try dates.resolve(4, headDate); try await settle(host)
        try require(model.authorDate == headDate && !model.loadingAuthorDate && !model.resetAuthorDate)
        try require(authors.pending.isEmpty && dates.pending.isEmpty)
        // Here both checkboxes start unchecked, so installing the preset
        // generates real SwiftUI onChange callbacks rather than manual ones.
        fresh.loadReplaySplit(split, message: "Fresh replay supplied draft")
        try await wait(freshHost) { ready(fresh) }; try await settle(freshHost)
        try require(fresh.setAuthor && fresh.setAuthorDate && fresh.author == replayAuthor && fresh.authorDate == replayDate)
        fresh.setAuthor = false; try await settle(freshHost)
        try await wait(freshHost) { ready(fresh) && fresh.author == "HEAD Author <head@example.test>" }
        fresh.setAuthor = true; try await settle(freshHost); try await wait(freshHost) { ready(fresh) }
        fresh.setAuthorDate = false; try await settle(freshHost)
        fresh.setAuthorDate = true; try await settle(freshHost)
        try await wait(freshHost) { ready(fresh) && fresh.authorDate == headDate }
        try require(fresh.author == "HEAD Author <head@example.test>" && fresh.message == "Fresh replay supplied draft")
        let headAfter = try await repo.run(["rev-parse", "HEAD"]).text
        let configAfter = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        try require(headAfter == head && configAfter == config)
        try require(!window.isVisible && !freshWindow.isVisible && NSApplication.shared.activationPolicy() == .prohibited)
        print("PASS: actual hidden Commit Amend/default author/date transitions, current date on unamend, generation-guarded author/date/message replies and obsolete errors, byte-distinct draft preservation, pending Commit/editor/picker gates, read-only copy and cached amend drafts; supplied Replay Split control-state preserves first author/date against old ordinary replies; HEAD/config unchanged; no main app")
    }
}
