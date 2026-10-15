// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct UnifiedDocumentVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Unified document did not settle at fixture line \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func capture(_ owner: PatchWindowController, _ text: PatchTextView.PatchText) async throws {
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_UNIFIED_DOCUMENT_CAPTURE"], let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Native screenshot API unavailable") }
        let fixture = "diff --git a/settings.swift b/settings.swift\nindex 28efaaa..9a81bbb 100644\n--- a/settings.swift\n+++ b/settings.swift\n@@ -1,3 +1,4 @@\n let application = \"TurtleGit\"\n-let theme = \"light\"\n+let theme = \"system\"\n+let colorfulStatus = true\n let nativeDialogs = true\n"
        let old = owner.model.exportDocument.bytes
        window.title = "settings.swift – Unified Diff – TurtleGit"
        owner.model.readOnlyInformation = "Patch document. Save As exports it without changing repository files."
        owner.model.setReadOnlyDiff(Data(fixture.utf8)); try await wait { text.string == fixture }
        owner.model.showFind(); owner.model.changeFindText("theme")
        try await Task.sleep(nanoseconds: 650_000_000) // Let the preceding source boundary flash settle.
        NSApp.setActivationPolicy(.accessory); window.alphaValue = 1; window.makeKeyAndOrderFront(nil)
        defer { window.alphaValue = 0; owner.model.setReadOnlyDiff(old); owner.model.hideFind() }
        for (name, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named: name); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Own patch window unavailable to compositor") }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width * window.backingScaleFactor); options.height = Int(window.frame.height * window.backingScaleFactor)
            options.showsCursor = false; options.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent("unified-document-" + suffix + ".png"))
        }
    }
    @MainActor static func main() async throws { try await verify() }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: engine)
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","UDiff QA"),("user.email","udiff@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("working\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "baseline")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.UnifiedDocument.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = PatchWindowController(repository: repo, access: nil, preferences: prefs), model = owner.model, window = owner.window!, session = owner.documentSession!
        defer { owner.close() }
        window.alphaValue = 0; window.orderFront(nil)
        model.allowsDocumentEditing = true
        let initial = Data("needle 雪\nNEEDLE two\nlast needle".utf8)
        model.setReadOnlyDiff(initial); window.contentView?.layoutSubtreeIfNeeded()
        func source() -> PatchTextView.PatchText? { descendants(window.contentView!).compactMap { $0 as? PatchTextView.PatchText }.first }
        try await wait { source()?.isEditable == true && source()?.string == model.document.text }
        let text = source()!
        @MainActor func readyForInput(line: UInt = #line) async throws {
            // Session counters settle before SwiftUI updates NSTextView's
            // isEditable after Save/Open. Drive native input only when both
            // model and view agree; keep the existing bounded wait/assertions.
            do { try await wait(line: line) { model.canEditText && text.isEditable && text.string == model.document.text } }
            catch {
                print("UDiff input readiness", line, "editable", text.isEditable, "model", model.canEditText, "busy", model.busy, "operations", PatchDocumentSession.activeOperations, "textMatches", text.string == model.document.text)
                throw error
            }
        }
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 6)); text.find(.showFindInterface)
        try require(model.findVisible && model.findText == "needle", "Source bottom Find did not seed selection")
        model.changeFindText("needle"); model.search(previous: false)
        try require((text.string as NSString).substring(with: text.selectedRange()) == "NEEDLE", "Next ignored source case-insensitive search")
        model.search(previous: false); let last = text.selectedRange(), boundary = model.findBoundaryCount
        model.search(previous: false)
        try require(text.selectedRange() == NSRange(location: NSMaxRange(last), length: 0) && model.findBoundaryCount == boundary + 1, "Find wrapped at boundary")
        model.search(previous: true); try require(text.selectedRange() == last, "Reverse Find cursor")
        model.findMatchCase = true; model.changeFindText("NEEDLE")
        try require(text.selectedRange().location == 9, "Find UTF-16 offsets or Match case")
        text.cancelOperation(nil); try require(!model.findVisible, "Escape did not hide Find first")
        try await capture(owner, text); try await wait { text.string == String(decoding: initial, as: UTF8.self) }
        let original = text.string
        try await readyForInput()
        text.insertText(" edited", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        try await wait { model.documentDirty && window.isDocumentEdited }
        try require(!model.canApplyLines && !model.canApplyHunks, "Document edits enabled staging")
        text.breakUndoCoalescing(); text.undoManager?.undo()
        try await wait { text.string == original && !model.documentDirty }
        try require(model.exportDocument.bytes == initial, "Undo to source savepoint lost original bytes")
        text.undoManager?.redo(); try await wait { model.documentDirty }
        // A cancelled close and cancelled Save As retain the edit and its Undo.
        session.askChanges = { _, reply in reply(.cancel) }
        try require(!owner.windowShouldClose(window), "Dirty close bypassed question")
        try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(!model.retired && model.documentDirty, "Cancel close discarded document")
        let quit = TurtleGitApplicationDelegate(); var quitReply: Bool?
        quit.replyToTermination = { _, allow in quitReply = allow }
        try require(quit.applicationShouldTerminate(NSApplication.shared) == .terminateLater, "Dirty UDiff bypassed Quit sequence")
        try await wait { quitReply != nil }
        try require(quitReply == false && model.documentDirty && !model.confirmingQuit, "Cancel Quit discarded or froze patch")
        session.chooseSave = { _, _, reply in reply(nil) }
        session.saveDocument(as: true); try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(model.documentDirty && text.undoManager?.canUndo == true, "Cancelled Save As damaged edits")
        let saved = root.appendingPathComponent("saved.patch")
        session.chooseSave = { _, _, reply in reply(saved) }
        session.saveDocument(); try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(!model.documentDirty && session.fileURL == saved && Data(contentsOf: saved) == Data(text.string.utf8), "First Save did not establish file/savepoint")
        // Open owns a selected file and preserves original encoding/BOM on edits.
        let encoded = root.appendingPathComponent("utf16.patch"), body = "diff --git a/a b/a\n+needle 雪\n"
        var raw = Data([0xff,0xfe]); raw.append(body.data(using: .utf16LittleEndian)!)
        try raw.write(to: encoded)
        session.chooseOpen = { _, reply in reply(encoded) }; session.openDocument()
        try await wait { PatchDocumentSession.activeOperations == 0 && text.string == body }
        try require(session.fileURL == encoded && model.exportDocument.bytes == raw && text.undoManager?.canUndo != true, "Open changed original bytes or kept prior Undo")
        try await readyForInput()
        text.insertText("+more\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0)); try await wait { model.documentDirty }
        let modified = text.string; session.saveDocument(); try await wait { PatchDocumentSession.activeOperations == 0 }
        var expected = Data([0xff,0xfe]); expected.append(modified.data(using: .utf16LittleEndian)!)
        try require(try Data(contentsOf: encoded) == expected && !model.documentDirty, "Save changed original UTF-16 encoding")
        // An external write must not be silently overwritten by Save.
        try await readyForInput()
        text.insertText("+local\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0)); try await wait { model.documentDirty }
        try Data("external\n".utf8).write(to: encoded)
        session.saveDocument(); try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(try Data(contentsOf: encoded) == Data("external\n".utf8) && model.documentDirty && model.error != nil, "Save overwrote external change")
        model.error = nil; try await wait { window.attachedSheet == nil }
        // Reject characters that cannot be represented by the original legacy encoding.
        session.askChanges = { _, reply in reply(.discard) }
        let legacy = root.appendingPathComponent("legacy.patch"), legacyBytes = Data([0x2b,0x63,0x61,0x66,0xe9,0x0a])
        try legacyBytes.write(to: legacy); session.chooseOpen = { _, reply in reply(legacy) }; session.openDocument()
        try await wait { PatchDocumentSession.activeOperations == 0 && session.fileURL == legacy }
        try await wait { text.string == "+café\n" && text.isEditable }
        try await readyForInput()
        text.insertText("雪", replacementRange: NSRange(location: text.string.utf16.count, length: 0)); try await wait { model.documentDirty }
        session.saveDocument(); try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(try Data(contentsOf: legacy) == legacyBytes && model.error != nil && model.documentDirty, "Unrepresentable legacy Save wrote lossy bytes")
        model.error = nil; try await wait { window.attachedSheet == nil }
        // Shared app menu routing cannot save a background patch.
        var focused: NSWindow? = window
        let menu = PatchMenuContext(keyWindow: { focused })
        try await wait { menu.documentAvailable }
        focused = nil; menu.saveDocument(); try require(PatchDocumentSession.activeOperations == 0, "Background patch Save ran")
        focused = window
        // Dirty replacement cancellation retains the entire document.
        let retained = model.document.text
        var replacementAsked = false
        session.askChanges = { _, reply in replacementAsked = true; reply(.cancel) }; model.setReadOnlyDiff(Data("replacement\n".utf8))
        try await wait { replacementAsked && PatchDocumentSession.activeOperations == 0 }
        try require(model.document.text == retained && model.documentDirty, "Cancelled replacement lost edits")
        // Forced closure fences an uncooperative file read until settlement.
        let slow = PatchWindowController(repository: repo, access: nil, preferences: prefs), slowModel = slow.model, slowSession = slow.documentSession!
        slowModel.allowsDocumentEditing = true; slowModel.setReadOnlyDiff(initial)
        var release: CheckedContinuation<Data, Error>?, started = false
        slowSession.chooseOpen = { _, reply in reply(saved) }
        slowSession.readFile = { _, _ in started = true; return try await withCheckedThrowingContinuation { release = $0 } }
        slowSession.openDocument(); try await wait { started }
        slow.close(); try require(PatchDocumentSession.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Closed read lost Quit ownership")
        release?.resume(returning: Data("late\n".utf8)); try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(slowModel.retired && slowModel.document.text == String(decoding: initial, as: UTF8.self), "Late file read published after close")
        // Import/Review embeds have no standalone bottom bar and retain AppKit Find.
        let embeddedModel = PatchWindowModel(repository: repo, access: nil, appearancePreferences: prefs)
        embeddedModel.setReadOnlyDiff(initial)
        let embeddedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        embeddedWindow.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: PatchTextView(model: embeddedModel)); host.sizingOptions = []
        embeddedWindow.contentViewController = host
        defer { embeddedModel.retire(); embeddedWindow.close() }
        embeddedWindow.contentView?.layoutSubtreeIfNeeded()
        func embeddedText() -> PatchTextView.PatchText? { descendants(embeddedWindow.contentView!).compactMap { $0 as? PatchTextView.PatchText }.first }
        try await wait { embeddedText() != nil }
        let embedded = embeddedText()!
        try require(embedded.usesFindBar && !embedded.isEditable && !embeddedModel.usesSourceFindBar, "Embedded import preview lost native Find or became editable")
        embedded.find(.showFindInterface)
        try await wait { embedded.enclosingScrollView?.isFindBarVisible == true }
        embedded.find(.hideFindInterface)
        try await wait { embedded.enclosingScrollView?.isFindBarVisible == false }
        try require(!embeddedModel.findVisible, "Embedded preview tried to show an absent source bar")
        owner.close()
        let after = try await repo.run(["rev-parse","HEAD"]).stdout
        try require(head == after && Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: root.appendingPathComponent("file.txt")) == Data("working\n".utf8), "UDiff document changed repository state")
        print("PASS: Unified document native editing/Undo, original bytes and encodings, Save/Open/cancel/stale-file refusal, source Find, focused menus and retired file-read accounting")
    }
}
