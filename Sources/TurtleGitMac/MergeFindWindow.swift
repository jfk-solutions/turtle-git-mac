import AppKit
import TurtleGitCore

@MainActor protocol MergeFindProviding: AnyObject {
    var mergeFindController: MergeFindWindowController? { get set }
    var mergeFindHighlights: MergeFindHighlights { get }
    var mergeFindDefaults: UserDefaults { get }
    var mergeFindAllowed: Bool { get }
    var mergeFindWritable: Bool { get }
    var mergeFindLines: [MergeFindLine] { get }
    @discardableResult func replaceFindMatches(_ ranges: [NSRange], with replacement: String) -> Bool
}

/// Search paint belongs to the pane, so closing Find does not discard it.
/// Temporary layout attributes leave file bytes, source styles and Undo intact.
@MainActor final class MergeFindHighlights {
    private(set) var query = ""
    private(set) var options = MergeFindOptions()
    private(set) var ranges: [NSRange] = []
    private(set) var paintRanges: [NSRange] = []
    private(set) var markedWord = ""
    var previousMarkedWord = ""
    private(set) var markedRanges: [NSRange] = []
    private(set) var locatorHighlights = MergeLocatorHighlights()
    var annotationsChanged: () -> Void = {}
    private var cachedMarkedWord = "", cachedSeparators = ""
    func mark(_ word: String, in text: NSTextView) { markedWord = word; refresh(in: text) }
    private var cachedText: String?
    private var cachedStates: [MergeSourceState] = []
    private var cachedQuery = ""
    private var cachedOptions = MergeFindOptions()
    func set(_ query: String, options: MergeFindOptions, in text: NSTextView) {
        self.query = query; self.options = options; refresh(in: text)
    }
    static func intense(_ color: NSColor, scale: Int = 30) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved: NSColor = color
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            let units = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent].map { Int(($0 * 255).rounded()) }
            let darken = units.reduce(0, +) / 3 > 127
            let strength = min(255, max(0, scale))
            let values = units.map { darken ? ($0 * (255 - strength) + 127) / 255 : $0 + ((255 - $0) * strength + 127) / 255 }
            return NSColor(srgbRed: CGFloat(values[0]) / 255, green: CGFloat(values[1]) / 255, blue: CGFloat(values[2]) / 255, alpha: resolved.alphaComponent)
        }
    }
    func refresh(in text: NSTextView) {
        guard let target = text as? MergeFindProviding, let storage = text.textStorage, let layout = text.layoutManager else { return }
        let all = NSRange(location: 0, length: storage.length)
        for key in [NSAttributedString.Key.backgroundColor, .foregroundColor, .mergeFindMatch, .mergeMarkedWord] { layout.removeTemporaryAttribute(key, forCharacterRange: all) }
        let lines = target.mergeFindLines, states = lines.map(\.state)
        let contentChanged = cachedText?.utf8.elementsEqual(text.string.utf8) != true || cachedStates != states
        if contentChanged || !cachedQuery.utf8.elementsEqual(query.utf8) || cachedOptions != options {
            ranges = MergeFind.matches(query, in: lines, options: options)
            var painting = options; painting.modifiedOnly = false
            paintRanges = options.modifiedOnly ? MergeFind.matches(query, in: lines, options: painting) : ranges
            cachedQuery = query; cachedOptions = options
        }
        let separators = MergeFindOptions.load(from: target.mergeFindDefaults).wordSeparators
        if contentChanged || !cachedMarkedWord.utf8.elementsEqual(markedWord.utf8) || !cachedSeparators.utf8.elementsEqual(separators.utf8) {
            markedRanges = MergeMarkedWord.matches(markedWord, in: lines, wordSeparators: separators)
            cachedMarkedWord = markedWord; cachedSeparators = separators
        }
        cachedText = text.string; cachedStates = states
        func paint(_ ranges: [NSRange], scale: Int, key: NSAttributedString.Key) {
            for range in ranges where NSMaxRange(range) <= storage.length {
                var cursor = range.location
                while cursor < NSMaxRange(range) {
                    var originalRun = NSRange(), temporaryRun = NSRange()
                    let original = storage.attributes(at: cursor, effectiveRange: &originalRun)
                    let temporary = layout.temporaryAttributes(atCharacterIndex: cursor, effectiveRange: &temporaryRun)
                    let end = min(NSMaxRange(range), NSMaxRange(originalRun), NSMaxRange(temporaryRun))
                    guard end > cursor else { break }
                    defer { cursor = end }
                    guard original[.mergeFoldHidden] == nil, original[.mergeFoldMarker] == nil else { continue }
                    let background = temporary[.backgroundColor] as? NSColor ?? original[.backgroundColor] as? NSColor ?? text.backgroundColor
                    let foreground = temporary[.foregroundColor] as? NSColor ?? original[.foregroundColor] as? NSColor ?? text.textColor ?? .textColor
                    layout.addTemporaryAttributes([.backgroundColor: Self.intense(background, scale: scale), .foregroundColor: Self.intense(foreground, scale: scale), key: true], forCharacterRange: NSRange(location: cursor, length: end - cursor))
                }
            }
        }
        // Source draws marked words first, then Find over that transformed color.
        paint(markedRanges, scale: 200, key: .mergeMarkedWord)
        paint(paintRanges, scale: 30, key: .mergeFindMatch)
        let highlights = MergeLocatorHighlights(search: MergeMarkedWord.rows(for: ranges, in: lines), marked: MergeMarkedWord.rows(for: markedRanges, in: lines))
        if locatorHighlights != highlights { locatorHighlights = highlights; annotationsChanged() }
        text.needsDisplay = true
    }
}
extension NSAttributedString.Key {
    static let mergeFindMatch = NSAttributedString.Key("TurtleGit.MergeFindMatch")
    static let mergeMarkedWord = NSAttributedString.Key("TurtleGit.MergeMarkedWord")
}
@MainActor enum MergeMarkedWordInterface {
    static func panes(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        if let text = view as? NSTextView, text is MergeFindProviding { return [text] }
        return view.subviews.flatMap { panes(in: $0) }
    }
    static func apply(_ word: String, local: Bool, in text: NSTextView) {
        guard let target = text as? MergeFindProviding, target.mergeFindAllowed else { return }
        for pane in local ? [text] : panes(in: text.window?.contentView) {
            guard let owner = pane as? MergeFindProviding, owner.mergeFindAllowed else { continue }
            owner.mergeFindHighlights.mark(word, in: pane)
        }
    }
    static func select(at offset: Int, local: Bool, in text: NSTextView) {
        guard let target = text as? MergeFindProviding, target.mergeFindAllowed else { return }
        let separators = MergeFindOptions.load(from: target.mergeFindDefaults).wordSeparators
        guard let line = target.mergeFindLines.first(where: { $0.offset <= offset && offset <= $0.offset + $0.text.utf16.count }),
              line.state != .empty, let range = MergeMarkedWord.selection(at: offset - line.offset, in: line.text, wordSeparators: separators) else { return }
        text.setSelectedRange(NSRange(location: line.offset + range.location, length: range.length))
        let word = (line.text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = target.mergeFindHighlights.markedWord
        target.mergeFindHighlights.previousMarkedWord = previous
        apply(word.utf8.elementsEqual(previous.utf8) ? "" : word, local: local, in: text)
    }
    static func mouse(_ event: NSEvent, in text: NSTextView) -> Bool {
        guard let target = text as? MergeFindProviding, target.mergeFindAllowed else { return false }
        if event.clickCount == 3 {
            apply(target.mergeFindHighlights.previousMarkedWord, local: false, in: text)
            return false // AppKit retains its native triple-click line selection.
        }
        guard event.clickCount == 2 else { return false }
        select(at: text.characterIndexForInsertion(at: text.convert(event.locationInWindow, from: nil)), local: event.modifierFlags.contains(.option), in: text)
        return true
    }
    static func appendCommands(to menu: NSMenu, text: NSTextView, defaults: UserDefaults) {
        guard let target = text as? MergeFindProviding else { return }
        for (title, selector) in [("Mark Word at Caret in All Panes", #selector(NSTextView.turtleMarkWord(_:))), ("Clear Marked Word", #selector(NSTextView.turtleClearMarkedWord(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = text; item.image = MenuIcon.mergeFind.contextImage(defaults: defaults)
            item.isEnabled = target.mergeFindAllowed && (selector != #selector(NSTextView.turtleClearMarkedWord(_:)) || !target.mergeFindHighlights.markedWord.isEmpty)
            menu.addItem(item)
        }
    }
}
extension NSTextView {
    @objc func turtleMarkWord(_ sender: Any?) { MergeMarkedWordInterface.select(at: selectedRange().location, local: false, in: self) }
    @objc func turtleClearMarkedWord(_ sender: Any?) { MergeMarkedWordInterface.apply("", local: false, in: self) }
    @objc func turtleShowMergeFind(_ sender: Any?) { MergeFindInterface.perform(.showFindInterface, in: self) }
    @objc func turtleFindSelectionNext(_ sender: Any?) { MergeFindInterface.selection(upwards: false, in: self) }
    @objc func turtleFindSelectionPrevious(_ sender: Any?) { MergeFindInterface.selection(upwards: true, in: self) }
    @objc func turtleClearFindHighlights(_ sender: Any?) {
        guard let target = self as? MergeFindProviding, target.mergeFindAllowed else { return }
        target.mergeFindHighlights.set("", options: target.mergeFindHighlights.options, in: self)
    }
}

@MainActor enum MergeFindInterface {
    /// Source FindnextStart/FindprevStart mean selected-text search, not a jump
    /// to the start/end of the document. No selection clears the search paint.
    static func selection(upwards: Bool, in text: NSTextView) {
        guard let target = text as? MergeFindProviding, target.mergeFindAllowed else { return }
        (text as? MergeLineNavigationProviding)?.beginUserNavigation()
        let selected = text.selectedRange(), value = text.string as NSString
        let query = selected.length > 0 && NSMaxRange(selected) <= value.length ? value.substring(with: selected) : ""
        var options = MergeFindOptions.load(from: target.mergeFindDefaults)
        options.matchCase = false; options.modifiedOnly = false; options.wholeWord = false
        target.mergeFindHighlights.set(query, options: options, in: text)
        guard !query.isEmpty, let match = MergeFind.next(in: target.mergeFindHighlights.ranges, selection: selected, upwards: upwards) else { return }
        text.setSelectedRange(match.range); text.scrollRangeToVisible(match.range); (text as? MergeLineNavigationProviding)?.didNavigateViewport()
    }
    static func performKey(_ event: NSEvent, in text: NSTextView?) -> Bool {
        guard let text, !text.isFieldEditor, text is MergeFindProviding else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 99, flags.isSubset(of: [.control, .shift]) {
            if flags.contains(.control) { selection(upwards: flags.contains(.shift), in: text) }
            else { perform(flags.contains(.shift) ? .previousMatch : .nextMatch, in: text) }
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "g", flags == [.command, .option] || flags == [.command, .option, .shift] {
            selection(upwards: flags.contains(.shift), in: text); return true
        }
        return false
    }
    static func appendSelectionCommands(to menu: NSMenu, text: NSTextView, defaults: UserDefaults) {
        guard let target = text as? MergeFindProviding else { return }
        for (title, selector, icon) in [("Find Next Selected Text", #selector(NSTextView.turtleFindSelectionNext(_:)), MenuIcon.jumpDown), ("Find Previous Selected Text", #selector(NSTextView.turtleFindSelectionPrevious(_:)), .jumpUp), ("Clear Search Highlights", #selector(NSTextView.turtleClearFindHighlights(_:)), .mergeFind)] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = text; item.image = icon.contextImage(defaults: defaults); item.isEnabled = target.mergeFindAllowed
            if selector == #selector(NSTextView.turtleClearFindHighlights(_:)) { item.isEnabled = item.isEnabled && !target.mergeFindHighlights.query.isEmpty }
            else { item.keyEquivalent = "g"; item.keyEquivalentModifierMask = selector == #selector(NSTextView.turtleFindSelectionNext(_:)) ? [.command, .option] : [.command, .option, .shift] }
            menu.addItem(item)
        }
        MergeMarkedWordInterface.appendCommands(to: menu, text: text, defaults: defaults)
    }

    static func perform(_ action: NSTextFinder.Action, in text: NSTextView) {
        guard let target = text as? MergeFindProviding else { return }
        if action == .hideFindInterface { target.mergeFindController?.close(); return }
        guard target.mergeFindAllowed else { return }
        (text as? MergeLineNavigationProviding)?.beginUserNavigation()
        if action == .previousMatch || action == .nextMatch {
            let state = target.mergeFindHighlights; state.refresh(in: text)
            let upwards = action == .previousMatch
            guard let match = MergeFind.next(in: state.ranges, selection: text.selectedRange(), upwards: upwards) else { return }
            text.setSelectedRange(match.range); text.scrollRangeToVisible(match.range); (text as? MergeLineNavigationProviding)?.didNavigateViewport()
            target.mergeFindController?.reportNavigation(wrapped: match.wrapped, upwards: upwards)
            return
        }
        if target.mergeFindController == nil { target.mergeFindController = MergeFindWindowController(text: text, defaults: target.mergeFindDefaults) }
        if action == .showFindInterface { target.mergeFindController?.present() }
    }
}

private final class MergeFindNativeWindow: NSWindow {
    weak var findController: MergeFindWindowController?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            findController?.find(upwards: flags.contains(.shift)); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Modeless, pane-local counterpart of IDD_FIND and CFindDlg.
@MainActor final class MergeFindWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate, NSTextFieldDelegate {
    private weak var text: NSTextView?
    private let defaults: UserDefaults
    let search = NSComboBox(), replacement = NSComboBox()
    let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let modifiedOnly = NSButton(checkboxWithTitle: "Limit search to modified lines", target: nil, action: nil)
    let searchUp = NSButton(checkboxWithTitle: "Search up", target: nil, action: nil)
    let wholeWord = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    private(set) var findButton: NSButton!, replaceButton: NSButton!, replaceAllButton: NSButton!
    private var ownerObserver: NSObjectProtocol?
    private var textObserver: NSObjectProtocol?
    private var options: MergeFindOptions {
        var value = MergeFindOptions.load(from: defaults)
        value.matchCase = matchCase.state == .on; value.modifiedOnly = modifiedOnly.state == .on
        value.wholeWord = wholeWord.state == .on; value.searchUp = searchUp.state == .on
        return value
    }
    init(text: NSTextView, defaults: UserDefaults) {
        self.text = text; self.defaults = defaults
        let window = MergeFindNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Find – TurtleGitMerge"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.findController = self
        let saved = MergeFindOptions.load(from: defaults)
        matchCase.state = saved.matchCase ? .on : .off; modifiedOnly.state = saved.modifiedOnly ? .on : .off
        wholeWord.state = saved.wholeWord ? .on : .off
        for (combo, key, label) in [(search, "Search", "Search for"), (replacement, "Replace", "Replace with")] {
            combo.addItems(withObjectValues: history(key)); combo.stringValue = history(key).first ?? ""
            combo.delegate = self; combo.setAccessibilityLabel(label)
            combo.widthAnchor.constraint(equalToConstant: 290).isActive = true
        }
        let labels = NSGridView(views: [[NSTextField(labelWithString: "Search for:"), search], [NSTextField(labelWithString: "Replace with:"), replacement]])
        labels.rowSpacing = 8; labels.columnSpacing = 10
        let left = NSStackView(views: [labels, matchCase, modifiedOnly, searchUp, wholeWord])
        left.orientation = .vertical; left.alignment = .leading; left.spacing = 8
        let right = NSStackView(); right.orientation = .vertical; right.alignment = .width; right.spacing = 6
        func button(_ title: String, _ action: Selector) -> NSButton {
            let value = NSButton(title: title, target: self, action: action); value.widthAnchor.constraint(equalToConstant: 112).isActive = true
            right.addArrangedSubview(value); return value
        }
        findButton = button("Find", #selector(findClicked)); findButton.keyEquivalent = "\r"
        replaceButton = button("Replace", #selector(replaceClicked))
        replaceAllButton = button("Replace All", #selector(replaceAllClicked))
        _ = button("Count", #selector(countClicked))
        let cancel = button("Cancel", #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [left, right]); row.orientation = .horizontal; row.alignment = .top; row.spacing = 16
        status.textColor = .systemBlue; status.isSelectable = true; status.setAccessibilityLabel("Search status")
        let content = NSStackView(views: [row, status]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        let host = NSView(); host.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14), content.topAnchor.constraint(equalTo: host.topAnchor, constant: 14), content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -12)])
        window.contentView = host
        DialogGeometry.attach(window, identifier: "TurtleGitMerge.Find", legacyName: "FindDlg")
        if let owner = text.window {
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        }
        textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: text, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateGates(); self?.refreshHighlights() } }
        updateGates()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; if let textObserver { NotificationCenter.default.removeObserver(textObserver) } }
    private var target: MergeFindProviding? { text as? MergeFindProviding }
    private func history(_ key: String) -> [String] { Array((defaults.stringArray(forKey: "TurtleGitMerge.History.Find." + key) ?? []).prefix(25)) }
    private func remember(_ key: String, combo: NSComboBox) {
        let value = combo.stringValue.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard !value.isEmpty else { return }
        var values = history(key).filter { $0 != value }; values.insert(value, at: 0); values = Array(values.prefix(25))
        defaults.set(values, forKey: "TurtleGitMerge.History.Find." + key)
        combo.removeAllItems(); combo.addItems(withObjectValues: values); combo.stringValue = value
    }
    func refreshHighlights() { if let text { target?.mergeFindHighlights.refresh(in: text) } }
    func updateGates() {
        let allowed = target?.mergeFindAllowed == true, writable = target?.mergeFindWritable == true
        findButton.isEnabled = allowed && !search.stringValue.isEmpty
        replacement.isEnabled = writable
        replaceButton.isEnabled = findButton.isEnabled && writable; replaceAllButton.isEnabled = replaceButton.isEnabled
    }
    func comboBoxSelectionDidChange(_ notification: Notification) { updateGates() }
    func controlTextDidChange(_ notification: Notification) { updateGates() }
    func present(show: Bool = true) {
        guard let text, let window, target?.mergeFindAllowed == true else { return }
        let range = text.selectedRange()
        if range.length > 0, NSMaxRange(range) <= (text.string as NSString).length { search.stringValue = (text.string as NSString).substring(with: range) }
        updateGates()
        if let owner = text.window {
            if window.parent !== owner { owner.addChildWindow(window, ordered: .above) }
            if !window.isVisible { window.setFrameOrigin(NSPoint(x: owner.frame.minX + 35, y: owner.frame.maxY - window.frame.height - 50)) }
        }
        if show { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(search) }
    }
    func windowWillClose(_ notification: Notification) { if let window { window.parent?.removeChildWindow(window) }; text?.window?.makeFirstResponder(text) }
    private func prepare(replacing: Bool = false) -> [NSRange]? {
        updateGates()
        guard target?.mergeFindAllowed == true, !search.stringValue.isEmpty, !replacing || target?.mergeFindWritable == true else { return nil }
        status.stringValue = ""; options.save(to: defaults); remember("Search", combo: search)
        if replacing { remember("Replace", combo: replacement) }
        guard let text else { return nil }
        target?.mergeFindHighlights.set(search.stringValue, options: options, in: text)
        return target?.mergeFindHighlights.ranges ?? []
    }
    func find(upwards: Bool? = nil) {
        guard let text, let matches = prepare() else { return }
        (text as? MergeLineNavigationProviding)?.beginUserNavigation()
        guard let match = MergeFind.next(in: matches, selection: text.selectedRange(), upwards: upwards ?? options.searchUp) else {
            status.stringValue = "\"\(search.stringValue)\" not found."; status.textColor = .systemRed; return
        }
        text.setSelectedRange(match.range); text.scrollRangeToVisible(match.range); (text as? MergeLineNavigationProviding)?.didNavigateViewport()
        reportNavigation(wrapped: match.wrapped, upwards: upwards ?? options.searchUp)
    }
    func reportNavigation(wrapped: Bool, upwards: Bool) {
        status.stringValue = wrapped ? (upwards ? "Top reached. Search continued from the bottom." : "Bottom reached. Search continued from the top.") : ""
        status.textColor = .systemGreen
    }
    func count() {
        guard let matches = prepare() else { return }
        status.stringValue = "\(matches.count) match(es)."; status.textColor = .systemBlue
    }
    func replace(all: Bool) {
        guard let text, let matches = prepare(replacing: true) else { return }
        let selected = all ? matches : MergeFind.next(in: matches, selection: text.selectedRange(), upwards: options.searchUp, includeSelection: true).map { [$0.range] } ?? []
        guard !selected.isEmpty else { status.stringValue = all ? "0 match(es) replaced." : "\"\(search.stringValue)\" not found."; status.textColor = all ? .labelColor : .systemRed; return }
        if target?.replaceFindMatches(selected, with: replacement.stringValue) == true {
            status.stringValue = "\(selected.count) match(es) replaced."; status.textColor = .labelColor
        }
    }
    @objc private func findClicked() { find() }
    @objc private func countClicked() { count() }
    @objc private func replaceClicked() { replace(all: false) }
    @objc private func replaceAllClicked() { replace(all: true) }
    @objc private func cancelClicked() { close() }
}
