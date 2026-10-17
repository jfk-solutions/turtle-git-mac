import AppKit
import TurtleGitCore

struct MergePresentationVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor final class Counts { var edits = 0, geometry = 0 }
    @MainActor final class FindText: NSTextView, MergeFindProviding {
        var displayInvalidations = 0
        override var needsDisplay: Bool {
            get { super.needsDisplay }
            set { if newValue { displayInvalidations += 1 }; super.needsDisplay = newValue }
        }
        var mergeFindController: MergeFindWindowController?
        let mergeFindHighlights = MergeFindHighlights()
        var mergeFindDefaults = UserDefaults.standard
        var mergeFindPaneID: Int { 1 }
        var mergeFindAllowed: Bool { true }
        var mergeFindWritable: Bool { false }
        var mergeFindLines: [MergeFindLine] {
            MergeLineEndings.lineRanges(in: string).map { range in
                MergeFindLine(text: (string as NSString).substring(with: range), offset: range.location, state: .normal)
            }
        }
        func replaceFindMatches(_ ranges: [NSRange], with replacement: String) -> Bool { false }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func verify() async throws {
        let suite = "TurtleGit.Presentation." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); MergePalette.reload() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let text = FindText(frame: scroll.bounds); text.mergeFindDefaults = prefs
        text.isRichText = false; text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text; window.contentView!.addSubview(scroll); window.orderFront(nil)
        let original = (0..<40).map { "row \($0) alpha 🐢\t" + String(repeating: "long words ", count: 8) + "\n" }.joined()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        func value(_ font: NSFont) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []; paragraph.defaultTabInterval = 32
            return NSAttributedString(string: original, attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: MergePalette.foreground(.normal), .backgroundColor: MergePalette.color(.normal)])
        }
        let fold = MergeFoldingController(preferences: prefs), presentation = MergeFoldTextLayout(), wrapping = MergeLineWrapping(), counts = Counts()
        defer { wrapping.retire(); fold.retire() }
        fold.update(unchanged: Array(repeating: true, count: MergeLineEndings.lineRanges(in: original).count))
        let observation = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: text.textStorage, queue: nil) { _ in MainActor.assumeIsolated { counts.edits += 1 } }
        defer { NotificationCenter.default.removeObserver(observation) }
        try require(presentation.installPresentation(value(font), font: font, in: text, controller: fold), "Initial presentation was skipped")
        wrapping.geometryChanged = { counts.geometry += 1 }
        wrapping.update(scroll, key: "Only", aligned: false, enabled: true); wrapping.prepareForInput()
        for _ in 0..<100 where wrapping.isGeometryPending { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!wrapping.isGeometryPending, "Initial wrapping did not settle")
        let storage = text.textStorage!, saved = NSAttributedString(attributedString: storage)
        text.setSelectedRange(NSRange(location: 12, length: 5)); let selection = text.selectedRange()
        counts.edits = 0; counts.geometry = 0
        for _ in 0..<20 {
            try require(!presentation.installPresentation(value(font), font: font, in: text, controller: fold), "Identical presentation rewrote text storage")
            wrapping.update(scroll, key: "Only", aligned: false, enabled: true)
        }
        wrapping.prepareForInput()
        try require(counts.edits == 0 && counts.geometry == 0 && !wrapping.isGeometryPending, "No-op updates changed paragraph geometry")
        try require(storage.isEqual(to: saved) && text.selectedRange() == selection, "No-op updates lost source styles or selection")
        let highlights = text.mergeFindHighlights
        highlights.set("alpha", options: .init(), in: text)
        let offset = highlights.paintRanges.first!.location
        let painted = text.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: offset, effectiveRange: nil) as! NSColor
        text.displayInvalidations = 0
        for _ in 0..<20 { highlights.refresh(in: text) }
        let identicalPaint = text.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor === painted
        print("Find unchanged diagnostic: displayInvalidations=\(text.displayInvalidations), identicalPaint=\(identicalPaint), storageEdits=\(counts.edits)")
        try require(text.displayInvalidations == 0 && identicalPaint, "Identical Find refresh repainted temporary attributes")
        let changedColor = NSColor.systemPurple
        storage.addAttribute(.backgroundColor, value: changedColor, range: highlights.paintRanges[0])
        highlights.refresh(in: text)
        let refreshed = text.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: offset, effectiveRange: nil) as! NSColor
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                precondition(refreshed.usingColorSpace(.sRGB) == MergeFindHighlights.intense(changedColor).usingColorSpace(.sRGB))
            }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            text.appearance = NSAppearance(named: appearance)
            highlights.refresh(in: text)
            try require(text.layoutManager!.temporaryAttribute(.mergeFindMatch, atCharacterIndex: offset, effectiveRange: nil) as? Bool == true, "Appearance change lost Find paint")
        }
        highlights.mark("alpha", in: text)
        try require(!highlights.markedRanges.isEmpty, "Marked-word paint was not installed")
        highlights.set("", options: .init(), in: text); highlights.mark("", in: text)
        try require(text.layoutManager!.temporaryAttribute(.mergeFindMatch, atCharacterIndex: offset, effectiveRange: nil) == nil && text.layoutManager!.temporaryAttribute(.mergeMarkedWord, atCharacterIndex: offset, effectiveRange: nil) == nil, "Cleared search/marked paint survived")
        let large = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        try require(presentation.installPresentation(value(large), font: large, in: text, controller: fold), "Font change was skipped")
        fold.setCollapsed(true)
        try require(presentation.installPresentation(value(large), font: large, in: text, controller: fold), "Fold change was skipped")
        counts.edits = 0
        try require(!presentation.installPresentation(value(large), font: large, in: text, controller: fold) && counts.edits == 0, "Identical folded presentation restored hidden rows")
        try require(storage.attribute(.mergeFoldMarker, at: 0, effectiveRange: nil) != nil, "Prefix fold disappeared")
        highlights.set("alpha", options: .init(), in: text)
        try require(text.layoutManager!.temporaryAttribute(.mergeFindMatch, atCharacterIndex: offset, effectiveRange: nil) == nil, "Find painted a folded marker")
        fold.setCollapsed(false)
        _ = presentation.installPresentation(value(large), font: large, in: text, controller: fold)
        highlights.refresh(in: text)
        try require(text.layoutManager!.temporaryAttribute(.mergeFindMatch, atCharacterIndex: offset, effectiveRange: nil) as? Bool == true, "Find did not repaint after unfolding")
        storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "row")
        try require(presentation.installPresentation(value(large), font: large, in: text, controller: fold), "Same-text character replacement retained a stale presentation")
        MergePalette.reload(defaults: prefs)
        try require(presentation.installPresentation(value(large), font: large, in: text, controller: fold), "Palette replacement retained stale dynamic colors")
        try require(text.string.utf8.elementsEqual(original.utf8) && text.undoManager?.canUndo != true, "Presentation changed source bytes or Undo")
        print("PASS: unchanged presentation/Find/wrapping perform no storage or geometry work; font, palette, fold, search, marked-word and same-text edit invalidation retained")
    }
}
