import AppKit
import TurtleGitCore

@MainActor protocol MergeFindProviding: AnyObject {
    var mergeFindController: MergeFindWindowController? { get set }
    var mergeFindDefaults: UserDefaults { get }
    var mergeFindAllowed: Bool { get }
    var mergeFindWritable: Bool { get }
    var mergeFindLines: [MergeFindLine] { get }
    @discardableResult func replaceFindMatches(_ ranges: [NSRange], with replacement: String) -> Bool
}

@MainActor enum MergeFindInterface {
    static func perform(_ action: NSTextFinder.Action, in text: NSTextView) {
        guard let target = text as? MergeFindProviding else { return }
        if action == .hideFindInterface { target.mergeFindController?.close(); return }
        guard target.mergeFindAllowed else { return }
        if target.mergeFindController == nil { target.mergeFindController = MergeFindWindowController(text: text, defaults: target.mergeFindDefaults) }
        let controller = target.mergeFindController!
        if action == .showFindInterface { controller.present() }
        else if action == .previousMatch || action == .nextMatch { controller.find(upwards: action == .previousMatch) }
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
        textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: text, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateGates() } }
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
        return MergeFind.matches(search.stringValue, in: target?.mergeFindLines ?? [], options: options)
    }
    func find(upwards: Bool? = nil) {
        guard let text, let matches = prepare() else { return }
        guard let match = MergeFind.next(in: matches, selection: text.selectedRange(), upwards: upwards ?? options.searchUp) else {
            status.stringValue = "\"\(search.stringValue)\" not found."; status.textColor = .systemRed; return
        }
        text.setSelectedRange(match.range); text.scrollRangeToVisible(match.range)
        status.stringValue = match.wrapped ? ((upwards ?? options.searchUp) ? "Top reached. Search continued from the bottom." : "Bottom reached. Search continued from the top.") : ""
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
