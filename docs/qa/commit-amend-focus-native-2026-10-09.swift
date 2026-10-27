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
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -18000, y: -18000)); window.contentView = host
        window.orderFront(nil); defer { model.invalidateForClose(); window.orderOut(nil); window.close() }
        try require(window.isVisible && window.alphaValue == 0)
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
        try require(window.firstResponder !== message && !message.isEditable && model.appliedMessageFocusRequest == model.messageFocusRequest)
        model.confirmingQuit = false; try await settle(host)
        try require(window.firstResponder !== message)
        model.focusMessage(); try await wait(host) { window.firstResponder === message }
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
        model.error = "Owned QA error gate"; model.focusMessage()
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
        defer { errorModel.invalidateForClose() }
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
        closingWindow.alphaValue = 0; closingWindow.setFrameOrigin(NSPoint(x: -18000, y: -18000))
        closingWindow.contentView = closingHost; closingWindow.orderFront(nil); defer { closingWindow.orderOut(nil); controller.close() }
        closing.message = "Closing draft"; closing.messageOnly = true; closing.reload()
        try await wait(closingHost) { ready(closing) && closing.canCommit }
        guard let closingMessage = find(NSTextView.self, in: closingHost, label: "Commit message"), let closingAuthor = find(NSTextField.self, in: closingHost, label: "Author identity") else { throw Failure(description: "Closing controls missing") }
        closingAuthor.selectText(nil)
        var reply: CheckedContinuation<String?, Error>?
        var closingToken: OperationCancellation?
        defer { reply?.resume(throwing: OperationCancellationFailure.cancelled) }
        closing.queryAmendMessage = { token in closingToken = token; return try await withCheckedThrowingContinuation { reply = $0 } }
        closing.amend = true; try await wait(closingHost) { reply != nil }
        controller.close()
        try require(!closing.messageFocusAvailable && closing.messageFocusRequest == 0 && closingToken?.isCancelled == true && !closing.canCommit)
        reply!.resume(returning: "Late HEAD draft"); reply = nil
        try await wait(closingHost) { ready(closing) }; try await settle(closingHost)
        try require(closing.messageFocusRequest == 0 && closingWindow.firstResponder !== closingMessage && closing.message == "Closing draft")
        // No successful late read may steal a newer native focus intent. These
        // editor-only hosts exercise publication without presenting real alerts.
        let superseded = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        defer { superseded.invalidateForClose() }
        superseded.message = "Superseded draft"; superseded.messageOnly = true
        host.rootView = AnyView(HStack {
            CommitMessageEditor(model: superseded)
            CommitAuthorField(author: Binding(get: { superseded.author }, set: { superseded.author = $0 }), editable: true)
        }.defaultAppStorage(prefs))
        superseded.reload(); try await wait(host) { ready(superseded) && superseded.canCommit }
        guard let supersededMessage = find(NSTextView.self, in: host, label: "Commit message"),
              let supersededAuthor = find(NSTextField.self, in: host, label: "Author identity") else { throw Failure(description: "Supersession controls missing") }
        var amendReply: CheckedContinuation<String?, Error>?
        var signOffReply: CheckedContinuation<String, Error>?
        defer {
            amendReply?.resume(throwing: OperationCancellationFailure.cancelled)
            signOffReply?.resume(throwing: OperationCancellationFailure.cancelled)
        }
        superseded.queryAmendMessage = { _ in try await withCheckedThrowingContinuation { amendReply = $0 } }
        superseded.amend = true; superseded.amendChanged()
        try await wait(host) { amendReply != nil }
        let oldAmendIntent = superseded.focusIntent, amendFocusRequests = superseded.messageFocusRequest
        superseded.supersedeFocusIntent(); supersededAuthor.selectText(nil)
        guard let newerResponder = supersededAuthor.currentEditor() else { throw Failure(description: "Superseding native field editor missing") }
        try require(window.firstResponder === newerResponder && !superseded.acceptsFocusIntent(oldAmendIntent))
        amendReply!.resume(returning: "New HEAD read"); amendReply = nil
        try await wait(host) { ready(superseded) }; try await settle(host)
        try require(superseded.message == "New HEAD read" && window.firstResponder === newerResponder && superseded.messageFocusRequest == amendFocusRequests)
        superseded.querySignOff = { _ in try await withCheckedThrowingContinuation { signOffReply = $0 } }
        superseded.addSignOff(); try await wait(host) { signOffReply != nil }
        let oldSignOffIntent = superseded.focusIntent, signOffFocusRequests = superseded.messageFocusRequest
        superseded.supersedeFocusIntent(); supersededAuthor.selectText(nil)
        try require(!superseded.acceptsFocusIntent(oldSignOffIntent))
        signOffReply!.resume(returning: "Signed-off-by: Focus Author <focus@example.test>"); signOffReply = nil
        try await wait(host) { ready(superseded) }; try await settle(host)
        try require(superseded.message.contains("Signed-off-by: Focus Author <focus@example.test>") && window.firstResponder === supersededAuthor.currentEditor() && superseded.messageFocusRequest == signOffFocusRequests)
        // A hidden owner must not consume even an explicit request. The same
        // live owner can accept a fresh explicit request once ordered again.
        window.makeFirstResponder(nil); window.orderOut(nil); superseded.focusMessage()
        try await settle(host)
        try require(window.firstResponder !== supersededMessage && superseded.appliedMessageFocusRequest < superseded.messageFocusRequest)
        window.orderFront(nil); superseded.focusMessage()
        try await wait(host) { window.firstResponder === supersededMessage }
        try require(superseded.appliedMessageFocusRequest == superseded.messageFocusRequest)
        // Actual editor menu commands retain insertion authority while focus
        // restoration belongs to the intent captured when the picker opened.
        guard let menuEditor = supersededMessage as? CommitMessageTextView else { throw Failure(description: "Native Commit editor type missing") }
        var picked: ((String) -> Void)?, historyPicked: ((String) -> Void)?
        var pickerMessageModes: [Bool] = []
        superseded.pickRevision = { isMessage, insert in
            pickerMessageModes.append(isMessage); picked = insert
        }
        superseded.showMessageHistory = { historyPicked = $0 }
        for command in [CommitCommandMenu.Command.message, .history] {
            superseded.message = "Picker target"; try await settle(host)
            menuEditor.setSelectedRange(NSRange(location: 0, length: 0))
            menuEditor.performCommitMenuCommand(command)
            try require(command == .message ? picked != nil && pickerMessageModes.last == true : historyPicked != nil)
            let pendingIntent = superseded.focusIntent, focusRequests = superseded.messageFocusRequest
            superseded.supersedeFocusIntent(); supersededAuthor.selectText(nil)
            guard let target = supersededAuthor.currentEditor() else { throw Failure(description: "Picker superseding native field missing") }
            try require(window.firstResponder === target && !superseded.acceptsFocusIntent(pendingIntent))
            let callback = command == .message ? picked : historyPicked
            callback!(command == .message ? "Picked message" : "History message")
            picked = nil; historyPicked = nil
            try await settle(host)
            try require(menuEditor.string.contains(command == .message ? "Picked message" : "History message") && superseded.message == menuEditor.string)
            try require(window.firstResponder === target && superseded.messageFocusRequest == focusRequests)
        }
        // A retained callback must not gain insertion authority over a replaced
        // model or a detached editor, regardless of its old focus receipt.
        menuEditor.performCommitMenuCommand(.message)
        menuEditor.performCommitMenuCommand(.history)
        try require(picked != nil && historyPicked != nil)
        let beforeReplacement = superseded.message
        let callbackModel = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        defer { callbackModel.invalidateForClose() }
        callbackModel.message = "Replacement model draft"; callbackModel.messageOnly = true
        host.rootView = AnyView(CommitMessageEditor(model: callbackModel).defaultAppStorage(prefs))
        try await settle(host)
        picked!("Stale picked text"); historyPicked!("Stale history text")
        picked = nil; historyPicked = nil; try await settle(host)
        try require(superseded.message == beforeReplacement && callbackModel.message == "Replacement model draft")
        guard let callbackEditor = find(CommitMessageTextView.self, in: host, label: "Commit message") else { throw Failure(description: "Callback replacement editor missing") }
        callbackModel.reload(); try await wait(host) { ready(callbackModel) && callbackModel.canCommit }
        callbackModel.pickRevision = { _, insert in picked = insert }
        callbackEditor.performCommitMenuCommand(.message); try require(picked != nil)
        let beforeRemoval = callbackModel.message, beforeRemovalEditor = callbackEditor.string
        host.rootView = AnyView(Text("Removed picker owner")); try await settle(host)
        try require(callbackEditor.window == nil)
        picked!("Detached picked text"); picked = nil; try await settle(host)
        try require(callbackModel.message == beforeRemoval && callbackEditor.string == beforeRemovalEditor)
        window.orderOut(nil)
        let headAfter = try await repo.run(["rev-parse", "HEAD"]).text
        let configAfter = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        try require(headAfter == head && configAfter == config)
        try require(!window.isVisible && !closingWindow.isVisible && !sheet.isVisible && NSApplication.shared.activationPolicy() == .prohibited)
        print("PASS: alpha0/offscreen ordered native Commit Amend on/off focuses message after defaults/refresh; ordinary updates retain focus/selection/undo; Quit supersedes old intent, error/sheet gates retain owned requests, removed editors and closed controllers reject late focus; held Amend/signoff publish content without superseding newer native focus; hidden owners reject delivery; picker/history insert without stealing newer focus and reject replaced/detached owners; HEAD/config unchanged; no visible owned windows, deferred native close cleanup, no main app or physical sheet")
    }
}
