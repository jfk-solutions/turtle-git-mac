import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct MessageStylesVerification {
    struct Failure: Error { let line: Int }
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws { if try !value() { throw Failure(line: line) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line: line)
    }
    @MainActor static func views(_ view: NSView?) -> [ProjectMessageTextView] {
        guard let view else { return [] }; return (view as? ProjectMessageTextView).map { [$0] } ?? view.subviews.flatMap { views($0) }
    }
    @MainActor static func link(_ editor: NSTextView, _ word: String) -> String? {
        let range = (editor.string as NSString).range(of: word)
        guard range.location != NSNotFound else { return nil }
        return editor.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? String
    }
    @MainActor static func styled(_ editor: NSTextView) -> Bool {
        let bold = (editor.string as NSString).range(of: "bold"), italic = (editor.string as NSString).range(of: "italic"), underline = (editor.string as NSString).range(of: "underlined")
        guard bold.location != NSNotFound, italic.location != NSNotFound, underline.location != NSNotFound,
              let b = editor.textStorage?.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont,
              let i = editor.textStorage?.attribute(.font, at: italic.location, effectiveRange: nil) as? NSFont else { return false }
        return NSFontManager.shared.traits(of: b).contains(.boldFontMask) && NSFontManager.shared.traits(of: i).contains(.italicFontMask) && (editor.textStorage?.attribute(.underlineStyle, at: underline.location, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue
    }
    @MainActor static func capture(_ owner: NSWindowController) async throws {
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_MESSAGE_STYLE_CAPTURE"], let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw Failure(line: #line) }
        NSApp.setActivationPolicy(.accessory); owner.showWindow(nil); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(line: #line) }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width * window.backingScaleFactor); options.height = Int(window.frame.height * window.backingScaleFactor)
            options.showsCursor = false; options.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent("notes-message-styles-" + suffix + ".png"))
        }
    }
    actor Gate {
        var token: OperationCancellation?, reply: CheckedContinuation<Void, Never>?
        func hold(_ token: OperationCancellation) async { self.token = token; await withCheckedContinuation { reply = $0 } }
        func started() -> Bool { reply != nil }
        func cancelled() -> Bool { token?.isCancelled == true }
        func release() { reply?.resume(); reply = nil }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.MessageStyles." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set("Menlo", forKey: "LogFontName"); prefs.set(15, forKey: "LogFontSize"); prefs.set(true, forKey: "StyleCommitMessages"); prefs.set(false, forKey: "Spellchecker")
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name","Message Styles"),("user.email","message-styles@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.projectlanguage","-1"),("tgit.logwidthmarker","72"),("bugtraq.logregex","issue #([0-9]+)"),("bugtraq.url","https://example.invalid/tickets/%BUGID%")]{ _ = try await repo.run(["config",key,value]) }
        for message in ["base", "next"] { _ = try await repo.run(["commit","--allow-empty","-m",message]) }
        let text = "🐢 issue #42\n*bold* ^italic^ _underlined_ https://example.invalid/source"
        _ = try await repo.run(["notes","add","-m",text])
        let head = try await repo.run(["rev-parse","HEAD"]).text, index = try? Data(contentsOf: root.appendingPathComponent(".git/index"))
        let notes = HistoryNotesWindowController(repository: repo, access: nil, revision: "HEAD", preferences: prefs)
        defer { notes.close() }; notes.model.load()
        try await wait { !notes.model.loading && notes.model.snapshot != nil }
        try await wait { link(notes.editor,"42") == "https://example.invalid/tickets/42" && styled(notes.editor) }
        let original = notes.editor.string, selection = NSRange(location: 3, length: 5)
        notes.editor.setSelectedRange(selection)
        let undo = notes.editor.undoManager?.canUndo
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: prefs)
        try await wait { styled(notes.editor) && MessageEditorStylingSession.activeOperations == 0 }
        try require(notes.editor.string.utf8.elementsEqual(original.utf8) && notes.editor.selectedRange() == selection && notes.editor.undoManager?.canUndo == undo)
        try require(!notes.editor.isContinuousSpellCheckingEnabled && notes.editor.font?.pointSize == 15)
        prefs.set(false, forKey: "StyleCommitMessages"); NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: prefs)
        try await wait { !styled(notes.editor) && link(notes.editor,"42") != nil }
        prefs.set(true, forKey: "StyleCommitMessages"); prefs.set(18, forKey: "LogFontSize"); NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: prefs)
        try await wait { styled(notes.editor) && notes.editor.font?.pointSize == 18 }
        try require(notes.editor.selectedRange() == selection && notes.editor.undoManager?.canUndo == undo)
        try await capture(notes)
        notes.editor.setSelectedRange(NSRange(location: notes.editor.string.utf16.count, length: 0))
        notes.editor.insertText(" extra", replacementRange: notes.editor.selectedRange())
        let edited = notes.editor.string; try await wait { styled(notes.editor) }; try require(notes.editor.undoManager?.canUndo == true)
        notes.editor.undoManager?.undo(); try await wait { notes.editor.string == original }; try require(edited != notes.editor.string)
        notes.cancel()
        let saved = try await repo.editableCommitNote(revision: "HEAD"); try require(saved.text == original)

        let log = LogWindowController(repository: repo, access: nil, labelDefaults: prefs); defer { log.close() }
        log.model.reload(); try await wait { !log.model.busy && log.model.entries.contains { $0.hash == head.trimmingCharacters(in: .newlines) } }
        log.model.selected = [head.trimmingCharacters(in: .newlines)]; log.model.editNotes()
        try await wait { log.noteEditor != nil }
        try await wait { link(log.noteEditor!.editor,"42") != nil && styled(log.noteEditor!.editor) }
        log.noteEditor?.cancel()
        let description = ReferenceDescriptionWindowController(text: text, preferences: prefs) { _,_ in }; defer { description.close() }
        try await wait { styled(description.editor) && link(description.editor,"https://example.invalid/source") != nil }
        try require(link(description.editor,"42") == nil, line: #line)

        let merge = MergeWindowController(repository: repo, access: nil, preferences: prefs); defer { merge.close() }
        merge.model.load(); try await wait { !merge.model.busy }; merge.model.message = text
        merge.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { views(merge.window?.contentView).contains { link($0,"42") != nil && styled($0) } }
        let rebase = RebaseWindowController(repository: repo, access: nil, preferences: prefs); defer { rebase.close() }
        rebase.model.load(upstream: "HEAD~1"); try await wait { !rebase.model.busy }
        try require(!rebase.model.issueProperties.checkExpression.isEmpty)
        let host = NSHostingView(rootView: ProjectMessageEditor(text: .constant(text), settings: rebase.model.projectSettings, label: "Rebase message", preferences: prefs, issueProperties: rebase.model.issueProperties))
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:600,height:200), styleMask: [.titled,.closable], backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }; host.layoutSubtreeIfNeeded()
        try await wait { views(host).contains { link($0,"42") != nil && styled($0) } }

        let composition = InputWindowController(text: "prefix ", preferences: prefs) { _,_,_ in }
        defer { composition.close() }
        composition.focusEditor()
        composition.editor.setMarkedText("*bold* ^italic^ _underlined_ https://example.invalid/ime", selectedRange: NSRange(location: 0, length: 0), replacementRange: composition.editor.selectedRange())
        let markedBytes = Data(composition.editor.string.utf8)
        try require(composition.editor.hasMarkedText())
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(Data(composition.editor.string.utf8) == markedBytes && composition.editor.hasMarkedText())
        composition.editor.unmarkText()
        try await wait { styled(composition.editor) && link(composition.editor,"https://example.invalid/ime") != nil }
        try require(Data(composition.editor.string.utf8) == markedBytes && !composition.editor.hasMarkedText())
        composition.cancel()

        let stale = ProjectMessageTextView(frame: NSRect(x:0,y:0,width:400,height:100)); stale.string = "https://example.invalid/late"
        let gate = Gate(), worker = MessageEditorStylingSession(editor: stale, query: { properties,message,formatting,token in
            await gate.hold(token)
            return try properties.messageStyles(in: message, formattingEnabled: formatting)
        })
        worker.configure(properties: IssueTrackerProperties(), preferences: prefs, font: .monospacedSystemFont(ofSize: 15, weight: .regular))
        for _ in 0..<1000 { if await gate.started() { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let started = await gate.started(); try require(started); worker.retire()
        let cancelled = await gate.cancelled(); try require(cancelled && MessageEditorStylingSession.activeOperations > 0)
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        await gate.release(); try await wait { MessageEditorStylingSession.activeOperations == 0 }
        try require(link(stale,"https://example.invalid/late") == nil)
        let finalHead = try await repo.run(["rev-parse","HEAD"]).text
        try require(finalHead == head && (try? Data(contentsOf: root.appendingPathComponent(".git/index"))) == index)
        print("PASS: Message styles completed: real Notes/Log/Merge issue properties and attributed links/formatting, Rebase shared editor, non-project descriptions, private live font/style settings, Undo/selection/raw text, cancelled stale queries and Quit accounting, unchanged HEAD/index/note. Owners closed.")
    }
}
