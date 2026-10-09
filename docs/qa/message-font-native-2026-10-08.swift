import AppKit
import SwiftUI
import TurtleGitCore

@main struct MessageFontVerification {
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let text = editor(in: child) { return text } }
        return nil
    }
    @MainActor static func position(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityLabel() == "Message line and column" { return field }
        for child in view.subviews { if let field = position(in: child) { return field } }
        return nil
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.MessageFont.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        let commit = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        let merge = MergeWindowModel(repository: repo, access: nil, preferences: prefs)
        commit.formattingEnabled = true; commit.message = "*bold* normal"; merge.message = "Merge draft 雪"
        let commitHost = NSHostingView(rootView: VStack { CommitMessageEditor(model: commit); CommitMessagePositionIndicator(model: commit) }.defaultAppStorage(prefs))
        let mergeHost = NSHostingView(rootView: MergeMessageEditor(model: merge).defaultAppStorage(prefs))
        let c = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        let m = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        c.isReleasedWhenClosed = false; m.isReleasedWhenClosed = false; c.contentView = commitHost; m.contentView = mergeHost
        defer { c.close(); m.close() }
        try await settle(commitHost); try await settle(mergeHost)
        let ce = editor(in: commitHost)!, me = editor(in: mergeHost)!
        precondition((ce.typingAttributes[.font] as? NSFont)?.pointSize == 9 && me.font?.pointSize == 9)
        ce.setSelectedRange(.init(location: 7, length: 3)); me.setSelectedRange(.init(location: 6, length: 5))
        ce.undoManager?.removeAllActions(); me.undoManager?.removeAllActions()
        let commitUndo = ce.undoManager!, mergeUndo = me.undoManager!
        let marker = NSMutableString(string: "")
        commitUndo.beginUndoGrouping(); commitUndo.registerUndo(withTarget: marker) { $0.append("commit") }; commitUndo.endUndoGrouping()
        mergeUndo.beginUndoGrouping(); mergeUndo.registerUndo(withTarget: marker) { $0.append("merge") }; mergeUndo.endUndoGrouping()
        prefs.set("Monaco", forKey: "LogFontName"); prefs.set(17, forKey: "LogFontSize")
        try await settle(commitHost); try await settle(mergeHost)
        let cf = ce.typingAttributes[.font] as! NSFont
        precondition(cf.familyName == "Monaco" && cf.pointSize == 17 && me.font?.familyName == "Monaco" && me.font?.pointSize == 17)
        precondition(ce.string == "*bold* normal" && me.string == "Merge draft 雪")
        precondition(ce.selectedRange() == .init(location: 7, length: 3) && me.selectedRange() == .init(location: 6, length: 5))
        precondition(commitUndo.canUndo && mergeUndo.canUndo)
        commitUndo.undo(); mergeUndo.undo(); precondition(marker as String == "commitmerge")
        prefs.set("Menlo", forKey: "LogFontName"); try await settle(commitHost)
        precondition(commit.issueMessageStyles.contains { $0.kind == .bold })
        let styled = ce.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        precondition(styled.pointSize == 17 && NSFontManager.shared.traits(of: styled).contains(.boldFontMask))
        let fallback = MessageEditorFont.resolve(name: "No Such Font TurtleGit", size: -9)
        precondition(fallback.pointSize == 9 && fallback.isFixedPitch)
        let settings = NSHostingView(rootView: MessageEditorFontSettings().defaultAppStorage(prefs))
        settings.frame = .init(x: 0, y: 0, width: 600, height: 130); settings.layoutSubtreeIfNeeded(); precondition(settings.fittingSize.width > 0)
        commit.message = "ab\tX\ne\u{301}😀"; try await settle(commitHost)
        for (offset, expected) in [(0, "1/1"), (3, "1/9"), (4, "1/10"), (5, "2/1"), (9, "2/4")] {
            ce.setSelectedRange(NSRange(location: offset, length: 0)); try await settle(commitHost)
            precondition(commit.messageCaretPosition.text == expected)
            precondition(position(in: commitHost)?.stringValue == expected && position(in: commitHost)?.accessibilityValue() as? String == expected)
        }
        ce.setSelectedRange(NSRange(location: 5, length: 0)); try await settle(commitHost)
        ce.setSelectedRange(NSRange(location: 5, length: 4)); try await settle(commitHost); precondition(commit.messageCaretPosition.text == "2/4")
        ce.setSelectedRange(NSRange(location: 2, length: 3)); try await settle(commitHost); precondition(commit.messageCaretPosition.text == "1/3")
        let paragraph = ce.typingAttributes[.paragraphStyle] as! NSParagraphStyle
        let space = (" " as NSString).size(withAttributes: [.font: ce.typingAttributes[.font] as! NSFont]).width
        precondition(abs(paragraph.defaultTabInterval - space * 8) < 0.01 && paragraph.tabStops.isEmpty)
        commit.message = "caf\u{e9}"; try await settle(commitHost)
        commit.message = "cafe\u{301}"; try await settle(commitHost)
        precondition(ce.string.utf8.elementsEqual(commit.message.utf8))
        ce.setSelectedRange(NSRange(location: 5, length: 0)); try await settle(commitHost); precondition(commit.messageCaretPosition.text == "1/6")
        print("PASS: source-style native Commit caret label, live caret/selection/Unicode/tab updates and actual accessibility value; actual hidden Commit/Merge editors load source default size and update native fonts live from isolated preferences, preserve Unicode drafts/selected ranges/existing undo, retain bold styling and typing font; invalid/missing font fallback and native settings layout; no main app")
    }
}
