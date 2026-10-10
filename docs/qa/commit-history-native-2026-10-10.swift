import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct CommitHistoryVerification {
    struct Failure: Error { let line: UInt }
    @MainActor final class OffscreenHistoryWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
    @MainActor final class IssueGate {
        struct Request { let token: OperationCancellation; var continuation: CheckedContinuation<String, Error>? }
        var requests: [Request] = []
        func query(_ token: OperationCancellation) async throws -> String {
            try await withCheckedThrowingContinuation { requests.append(Request(token: token, continuation: $0)) }
        }
        func finish(_ index: Int, _ value: String) {
            let continuation = requests[index].continuation; requests[index].continuation = nil
            continuation?.resume(returning: value)
        }
        func finishAll() { for index in requests.indices { finish(index, "discarded") } }
    }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line: line)
    }
    @MainActor static func settle() async throws { try await Task.sleep(nanoseconds: 200_000_000) }
    @MainActor static func press(_ title: String, in window: NSWindow) async throws {
        // Exercise the native default/cancel shortcuts on the actual sheet.
        let cancel = title == "Cancel"
        let text = cancel ? "\u{1b}" : "\r"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: cancel ? 53 : 36)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await verify(); fflush(stdout); exit(0) }
            catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.CommitHistory.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "History Test"])
        _ = try await repo.run(["config", "user.email", "history@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let file = root.appendingPathComponent("file.txt"), template = root.appendingPathComponent("template.txt")
        try Data("original\n".utf8).write(to: file); try Data("Template message".utf8).write(to: template)
        try await repo.stage(["file.txt", "template.txt"]); _ = try await repo.commit(message: "baseline")
        try Data("working edit\n".utf8).write(to: file)
        _ = try await repo.run(["config", "commit.template", template.path])
        _ = try await repo.run(["config", "bugtraq.message", "Refs: %BUGID%"] )
        _ = try await repo.run(["config", "bugtraq.label", "Ticket:"] )
        _ = try await repo.run(["config", "bugtraq.logregex", ""] )
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), working = try Data(contentsOf: file)
        let controller = CommitWindowController(repository: repo, access: nil, defaults: prefs)
        let window = controller.window!, model = controller.model
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        controller.makeHistoryWindow = {
            let child = OffscreenHistoryWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled,.resizable], backing: .buffered, defer: false)
            child.alphaValue = 0; return child
        }
        defer { window.close() }
        model.reload(); try await wait { !model.busy && !model.loadingAuthorIdentity && model.messageHistory != nil }
        window.contentView!.layoutSubtreeIfNeeded(); try await settle()
        guard let editor = views(window.contentView!).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Commit message" }), let history = model.messageHistory else { throw Failure(line: #line) }
        // GetBugIDFromLog trims trailing LF even without an issue match. Keep
        // that source behavior; explicitly restore the raw template to test its
        // equality/replacement branch while the issue field is enabled.
        try require(model.messageTemplate == "Template message\n" && editor.string == "Template message")
        editor.insertText(model.messageTemplate, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try await settle()
        try require(model.messageTemplate == "Template message\n" && editor.string == model.messageTemplate)
        let values = ["tail\r\nbody\nRefs: 73,42,73", "middle é\n" + String(repeating: "wide ", count: 60), "first 🐢\nbody"]
        for text in values { history.add(text) }
        let expected = history.entries
        window.orderFront(nil) // Keep native sheet ownership; alpha remains zero offscreen.
        @MainActor func open() async throws -> (NSWindow,NSTableView) {
            window.makeFirstResponder(editor)
            let insertion = editor.selectedRange()
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            guard let menu = editor.menu(for: event), let item = menu.items.first(where: { $0.title == "Recent messages…" }), let action = item.action else { throw Failure(line: #line) }
            // Querying a native text menu can select the clicked word. Choose the
            // intended selection before invoking the menu action in this receiver.
            editor.setSelectedRange(insertion)
            try require(item.image != nil && NSApp.sendAction(action, to: item.target, from: item))
            try await wait { window.attachedSheet != nil }
            let child = window.attachedSheet!
            try require(window.alphaValue == 0 && child.alphaValue == 0 && child.sheetParent === window)
            child.contentView!.layoutSubtreeIfNeeded(); try await settle()
            guard let table = views(child.contentView!).compactMap({ $0 as? NSTableView }).first else { throw Failure(line: #line) }
            try require(child.firstResponder === table)
            return (child,table)
        }
        var (child,table) = try await open()
        try require(table.numberOfRows == 3 && table.allowsMultipleSelection && table.enclosingScrollView?.hasHorizontalScroller == true)
        let displayed = (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue
        try require(displayed == expected[0].replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " "))
        var competing = false
        model.showMessageHistory { _ in competing = true }; model.pickRevision(false) { _ in competing = true }
        try require(window.attachedSheet === child && !competing)
        var cancellationRequested = false; model.confirmCancel = { _ in cancellationRequested = true }
        try require(!controller.windowShouldClose(window) && !cancellationRequested)
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        try await press("Cancel", in: child); try await wait { window.attachedSheet == nil }
        try require(model.messageTemplate == "Template message\n" && editor.string == model.messageTemplate)
        (child,table) = try await open()
        table.selectRowIndexes([0,2], byExtendingSelection: false); try await settle()
        try await press("OK", in: child); try await wait { window.attachedSheet == nil }; try await settle()
        let joined = expected[0] + "\n\n" + expected[2]
        try require(editor.string == joined && model.message == joined && window.firstResponder === editor)
        try await wait { model.issueID == "42 73" }
        try require(model.issueProperties.showsIssueField && model.issueProperties.label == "Ticket:")
        // An existing prefix must not be inserted again, even at another caret.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        (child,table) = try await open(); table.selectRowIndexes([0], byExtendingSelection: false); try await settle()
        try await press("OK", in: child); try await wait { window.attachedSheet == nil }; try await settle()
        try require(editor.string == joined)
        editor.insertText("draft", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length)); try await settle(); editor.setSelectedRange(NSRange(location: 0,length: 0))
        (child,table) = try await open(); table.selectRowIndexes([1], byExtendingSelection: false); try await settle()
        try await press("OK", in: child); try await wait { window.attachedSheet == nil }; try await settle()
        if editor.string != expected[1] + "\ndraft" || model.message != editor.string || window.firstResponder !== editor { print("INSERT RESULT", editor.string.debugDescription, model.message == editor.string, window.firstResponder === editor) }
        try require(editor.string == expected[1] + "\ndraft" && model.message == editor.string && window.firstResponder === editor)
        let draft = editor.string
        (child,table) = try await open(); table.selectRowIndexes([1], byExtendingSelection: false)
        let deletion = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: child.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        table.keyDown(with: deletion); try await settle()
        try require(table.numberOfRows == 2 && table.selectedRowIndexes == [1] && history.entries == [expected[0],expected[2]])
        let persisted = CommitMessageHistory(repositoryIdentity: try await repo.commitMessageHistoryIdentity(), defaults: prefs)
        try require(persisted.entries == history.entries)
        try await press("Cancel", in: child); try await wait { window.attachedSheet == nil }; try require(editor.string == draft)
        model.busy = true; model.showMessageHistory { _ in competing = true }; try require(window.attachedSheet == nil); model.busy = false
        // Deliberately delayed providers ignore cancellation, so publication guards
        // must also reject ABA input changes and superseded requests.
        let gate = IssueGate(); defer { gate.finishAll() }
        model.queryHistoryIssue = { _, _, token in try await gate.query(token) }
        @MainActor func pending() async throws -> Int {
            let index = gate.requests.count
            model.updateIssueFromHistory("Refs: 42", insertedInto: model.message)
            try await wait { gate.requests.count == index + 1 }; return index
        }
        let stableID = model.issueID, stableMessage = model.message, stableProperties = model.issueProperties
        try require(stableID == "42 73")
        var request = try await pending()
        model.issueID = "manual edit"; model.issueID = stableID
        try require(gate.requests[request].token.isCancelled)
        gate.finish(request, "stale field"); try await settle(); try require(model.issueID == stableID)
        request = try await pending()
        model.message = "temporary edit"; model.message = stableMessage
        try require(gate.requests[request].token.isCancelled)
        gate.finish(request, "stale message"); try await settle(); try require(model.issueID == stableID)
        request = try await pending()
        model.issueProperties = IssueTrackerProperties(); model.issueProperties = stableProperties
        try require(gate.requests[request].token.isCancelled)
        gate.finish(request, "stale properties"); try await settle(); try require(model.issueID == stableID)
        let old = try await pending(), latest = try await pending()
        try require(gate.requests[old].token.isCancelled && !gate.requests[latest].token.isCancelled)
        gate.finish(old, "old request"); try await settle(); try require(model.issueID == stableID)
        gate.finish(latest, "latest request"); try await wait { model.issueID == "latest request" }
        request = try await pending()
        // Forced parent teardown retires its sheet and blocks later requests.
        (child,table) = try await open(); window.close(); try await settle()
        try require(child.sheetParent == nil && !child.isVisible && window.attachedSheet == nil)
        try require(gate.requests[request].token.isCancelled)
        gate.finish(request, "closed request"); try await settle(); try require(model.issueID == "latest request")
        let queryCount = gate.requests.count
        model.updateIssueFromHistory("Refs: 42", insertedInto: model.message); try await settle()
        try require(gate.requests.count == queryCount)
        model.showMessageHistory { _ in competing = true }; model.pickRevision(true) { _ in competing = true }
        try require(window.attachedSheet == nil && !competing)
        let finalWorking = try Data(contentsOf: file), finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        try require(finalWorking == working && finalIndex == index && finalConfig == config)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; try require(finalHead == head)
        print("PASS: Native Commit Recent messages menu/icons, actual owned sheet, flattened Unicode rows and horizontal scrolling, table focus, multi-selection OK/template replacement, prefix suppression, caret insertion/editor focus, natural/deduplicated issue IDs and preserved IDs for messages without issues, cancelled/stale ABA/superseded/closed issue extraction, keyboard Delete/persistence/Cancel, competing picker/busy/close/Quit fences and forced-parent retirement; unchanged HEAD/index/config/working bytes. Owned windows closed.")
    }
}
