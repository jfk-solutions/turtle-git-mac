// Native adaptation of LogOrdering. SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

private final class OrderingSurface: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class OrderingWindow: NSWindow {
    var cancel: () -> Void = {}
    var acceptSelection: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 { acceptSelection(); return true }
            if event.keyCode == 53 { cancel(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { cancel() }
}

@MainActor final class LogOrderingWindowController: NSWindowController, NSWindowDelegate {
    let ordering = NSPopUpButton(frame: .zero, pullsDown: false)
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let preferences: UserDefaults
    private(set) var finished = false
    var completion: (HistoryOrdering?) -> Void = { _ in }
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let window = OrderingWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Log commit ordering – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentView = OrderingSurface(frame: window.contentView!.frame)
        super.init(window: window); window.delegate = self
        for value in HistoryOrdering.allCases { ordering.addItem(withTitle: value.title); ordering.lastItem?.tag = value.rawValue }
        ordering.selectItem(withTag: HistoryOrdering.load(defaults: preferences).rawValue)
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        cancel.target = self; cancel.action = #selector(cancelSelection); cancel.keyEquivalent = "\u{1b}"
        window.defaultButtonCell = ok.cell as? NSButtonCell
        window.cancel = { [weak self] in self?.finish(nil) }
        window.acceptSelection = { [weak self] in self?.accept() }
        let label = NSTextField(labelWithString: "Commit Ordering:")
        let row = NSStackView(views: [label, ordering]); row.orientation = .horizontal; row.distribution = .fill
        let buttons = NSStackView(views: [ok, cancel]); buttons.orientation = .horizontal; buttons.spacing = 8
        for view in [row, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(view) }
        ordering.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 14), row.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -14), row.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: row.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -14),
            ok.widthAnchor.constraint(equalToConstant: 80), cancel.widthAnchor.constraint(equalToConstant: 80)
        ])
        ordering.setAccessibilityLabel("Commit Ordering")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func accept() {
        guard let item = ordering.selectedItem, let value = HistoryOrdering(rawValue: item.tag) else { return }
        finish(value)
    }
    @objc private func cancelSelection() { finish(nil) }
    private func finish(_ value: HistoryOrdering?) {
        guard !finished else { return }; finished = true
        if let value { value.save(defaults: preferences) }
        if let parent = window?.sheetParent, let window { parent.endSheet(window) }
        window?.close(); completion(value)
    }
    override func close() { finish(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(nil); return false }
    func windowWillClose(_ notification: Notification) { if !finished { finish(nil) } }
}
