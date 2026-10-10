import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct CommitAmendFocusVerification {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static func require(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        if !value() { throw Failure(description: "Requirement failed at \(file):\(line)") }
    }
    @MainActor final class SheetGuardWindow: NSWindow {
        var injectedSheet: NSWindow?
        override var attachedSheet: NSWindow? { injectedSheet ?? super.attachedSheet }
    }
    @MainActor static func wait(_ host: NSView, until ready: () -> Bool) async throws {
        for _ in 0..<500 {
            host.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Timed out waiting for focus")
    }
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func find<T: NSView>(_ type: T.Type, in view: NSView, label: String) -> T? {
        if let result = view as? T, result.accessibilityLabel() == label { return result }
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
        let suite = "TurtleGit.CommitAmendFocus.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Focus Author"])
        _ = try await repo.run(["config", "user.email", "focus@example.test"])
        _ = try await repo.run(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "HEAD focus draft"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        model.message = "Normal focus draft"; model.messageOnly = true
        let host = NSHostingView(rootView: AnyView(CommitDialog(model: model).defaultAppStorage(prefs)))
        let window = SheetGuardWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        model.reload(); try await wait(host) { ready(model) && model.canCommit }
        guard let message = find(NSTextView.self, in: host, label: "Commit message"), let author = find(NSTextField.self, in: host, label: "Author identity") else { throw Failure(description: "Commit controls missing") }
        author.selectText(nil)
        guard let authorEditor = author.currentEditor() as? NSTextView else { throw Failure(description: "Author editor missing") }
        try require(window.firstResponder === authorEditor)
        model.amend = true
        try await wait(host) { ready(model) && window.firstResponder === message }
        try require(message.string.trimmingCharacters(in: .newlines) == "HEAD focus draft")
        message.setSelectedRange(NSRange(location: 4, length: 2))
        let undo = message.undoManager!, marker = NSMutableString(string: "")
        undo.beginUndoGrouping(); undo.registerUndo(withTarget: marker) { $0.append("retained") }; undo.endUndoGrouping()
        author.selectText(nil); model.newBranch = "Ordinary update"; try await settle(host)
        try require(window.firstResponder === authorEditor && message.selectedRange() == NSRange(location: 4, length: 2) && undo.canUndo)
        undo.undo(); try require(marker as String == "retained")
        model.amend = false
        try await wait(host) { ready(model) && window.firstResponder === message }
        try require(message.string == "Normal focus draft")
        author.selectText(nil); model.confirmingQuit = true; model.amend = true
        try await wait(host) { ready(model) }; try await settle(host)
        print("QUIT GATE:", window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil", "message:", window.firstResponder === message, "editable:", message.isEditable, "request/applied:", model.messageFocusRequest, model.appliedMessageFocusRequest)
        try require(window.firstResponder !== message && !message.isEditable && model.appliedMessageFocusRequest < model.messageFocusRequest)
        model.confirmingQuit = false
        try await wait(host) { window.firstResponder === message }
        author.selectText(nil)
        let sheet = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; defer { sheet.close() }
        // Inject ownership without beginning/ordering a physical sheet.
        window.injectedSheet = sheet; model.amend = false
        try await wait(host) { ready(model) }; try await settle(host)
        try require(window.firstResponder !== message && model.appliedMessageFocusRequest < model.messageFocusRequest)
        window.injectedSheet = nil
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        try await wait(host) { window.firstResponder === message }
        author.selectText(nil)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        model.newBranch = "Another ordinary update"; try await settle(host)
        try require(window.firstResponder === authorEditor)
        model.confirmingQuit = true; model.amend = true
        try await wait(host) { ready(model) }; try await settle(host)
        host.rootView = AnyView(Text("Removed editor")); try await settle(host)
        try require(message.window == nil)
        model.confirmingQuit = false
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        try await settle(host); try require(window.firstResponder !== message)
        // Error ownership is checked with editor-only controls, avoiding the
        // full dialog's actual alert presentation in this hidden receiver.
        model.error = "Owned QA error gate"
        host.rootView = AnyView(HStack {
            CommitMessageEditor(model: model)
            CommitAuthorField(author: Binding(get: { model.author }, set: { model.author = $0 }), editable: false)
        }.defaultAppStorage(prefs))
        try await settle(host)
        guard let replacement = find(NSTextView.self, in: host, label: "Commit message"), let replacementAuthor = find(NSTextField.self, in: host, label: "Author identity") else { throw Failure(description: "Replacement controls missing") }
        replacementAuthor.selectText(nil); try await settle(host)
        try require(window.firstResponder !== replacement)
        model.error = nil; try await wait(host) { window.firstResponder === replacement }
        try require(model.appliedMessageFocusRequest == model.messageFocusRequest)
        host.rootView = AnyView(Text("Recreate consumed editor")); try await settle(host)
        window.makeFirstResponder(nil)
        host.rootView = AnyView(CommitMessageEditor(model: model).defaultAppStorage(prefs)); try await settle(host)
        guard let recreated = find(NSTextView.self, in: host, label: "Commit message") else { throw Failure(description: "Recreated message editor missing") }
        try require(window.firstResponder !== recreated)
        let errorModel = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        errorModel.message = "Error-path draft"; errorModel.messageOnly = true
        host.rootView = AnyView(CommitMessageEditor(model: errorModel).defaultAppStorage(prefs)); try await settle(host)
        errorModel.reload(); try await wait(host) { ready(errorModel) && errorModel.canCommit }
        guard let errorEditor = find(NSTextView.self, in: host, label: "Commit message") else { throw Failure(description: "Error-path editor missing") }
        window.makeFirstResponder(nil)
        errorModel.queryAmendMessage = { _ in throw Failure(description: "Owned Amend read error") }
        errorModel.amend = true; errorModel.amendChanged()
        try await wait(host) { ready(errorModel) && errorModel.error != nil }; try await settle(host)
        try require(errorModel.messageFocusRequest > errorModel.appliedMessageFocusRequest && window.firstResponder !== errorEditor)
        errorModel.error = nil; try await wait(host) { window.firstResponder === errorEditor }
        try require(errorEditor.string == "Error-path draft")
        // The actual production controller's willClose invalidates focus even
        // when an initial Amend message read replies after the window closes.
        let controller = CommitWindowController(repository: repo, access: nil, defaults: prefs)
        let closing = controller.model
        guard let closingWindow = controller.window else { throw Failure(description: "Controller window missing") }
        closingWindow.contentViewController = nil
        let closingHost = NSHostingView(rootView: AnyView(CommitDialog(model: closing).defaultAppStorage(prefs)))
        closingWindow.contentView = closingHost; defer { controller.close() }
        closing.message = "Closing draft"; closing.messageOnly = true; closing.reload()
        try await wait(closingHost) { ready(closing) && closing.canCommit }
        guard let closingMessage = find(NSTextView.self, in: closingHost, label: "Commit message"), let closingAuthor = find(NSTextField.self, in: closingHost, label: "Author identity") else { throw Failure(description: "Closing controls missing") }
        closingAuthor.selectText(nil)
        var reply: CheckedContinuation<String?, Error>?
        var closingToken: OperationCancellation?
        closing.queryAmendMessage = { token in closingToken = token; return try await withCheckedThrowingContinuation { reply = $0 } }
        closing.amend = true; try await wait(closingHost) { reply != nil }
        controller.close()
        try require(!closing.messageFocusAvailable && closing.messageFocusRequest == 0 && closingToken?.isCancelled == true && !closing.canCommit)
        reply!.resume(returning: "Late HEAD draft"); reply = nil
        try await wait(closingHost) { ready(closing) }; try await settle(closingHost)
        try require(closing.messageFocusRequest == 0 && closingWindow.firstResponder !== closingMessage && closing.message == "Closing draft")
        let headAfter = try await repo.run(["rev-parse", "HEAD"]).text
        let configAfter = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        try require(headAfter == head && configAfter == config)
        try require(!window.isVisible && !closingWindow.isVisible && !sheet.isVisible && NSApplication.shared.activationPolicy() == .prohibited)
        print("PASS: hidden native Commit Amend on/off focuses message after defaults/refresh, ordinary updates retain other focus/selection/undo, Quit/error gates defer focus, injected sheet ownership and didEndSheet resume once, removed editors and closed real controllers reject late focus; HEAD/config unchanged; no main app or physical sheet")
    }
}
