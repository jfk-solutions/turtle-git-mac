// Native replacement of IDD_REVGRAPHFILTER / CRevGraphFilterDlg.
// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor final class RevisionGraphFilterController: NSWindowController, NSWindowDelegate {
    let model: RevisionGraphWindowModel
    let fromField = NSTextField(string: ""), toField = NSTextField(string: "")
    let current = NSButton(checkboxWithTitle: "Only Current Branch", target: nil, action: nil)
    let local = NSButton(checkboxWithTitle: "Only Local Branches", target: nil, action: nil)
    let fromBrowse = NSButton(title: "RefBrowser", target: nil, action: nil)
    let toBrowse = NSButton(title: "RefBrowser", target: nil, action: nil)
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let reset = NSButton(title: "Reset filter", target: nil, action: nil)
    private var completion: ((RevisionGraphOptions?) -> Void)?
    private(set) var picker: ReferenceBrowserWindowController?
    private var finished = false
    private var pickerRequest: UUID?
    private weak var pendingFocus: NSTextField?
    init(model: RevisionGraphWindowModel, completion: @escaping (RevisionGraphOptions?) -> Void) {
        self.model = model; self.completion = completion
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 510, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Revision Graph Filter"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        fromField.stringValue = model.options.from; toField.stringValue = model.options.to
        current.state = model.options.onlyCurrentBranch ? .on : .off; local.state = model.options.onlyLocalBranches ? .on : .off
        fromField.setAccessibilityLabel("From revision"); toField.setAccessibilityLabel("To revision")
        let grid = NSGridView(views: [[NSTextField(labelWithString: "From:"), fromField, fromBrowse], [NSTextField(labelWithString: "To:"), toField, toBrowse]])
        grid.rowSpacing = 10; grid.columnSpacing = 10; grid.column(at: 1).width = 295
        let scopes = NSStackView(views: [current, local]); scopes.orientation = .horizontal; scopes.spacing = 24
        let buttons = NSStackView(views: [ok, cancel, reset]); buttons.orientation = .horizontal; buttons.spacing = 8
        let stack = NSStackView(views: [NSTextField(labelWithString: "Include only the following revision range:"), grid, scopes, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12); stack.translatesAutoresizingMaskIntoConstraints = false
        let content = RevisionGraphSurface(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        for button in [current, local] { button.target = self; button.action = #selector(scopeChanged(_:)) }
        fromBrowse.target = self; fromBrowse.action = #selector(browseFrom); toBrowse.target = self; toBrowse.action = #selector(browseTo)
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"; window.defaultButtonCell = ok.cell as? NSButtonCell
        cancel.target = self; cancel.action = #selector(abort); cancel.keyEquivalent = "\u{1b}"
        reset.target = self; reset.action = #selector(resetFilter)
        NotificationCenter.default.addObserver(self, selector: #selector(sheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        scopeChanged(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc func scopeChanged(_ sender: NSButton?) {
        guard !finished, picker == nil, window?.attachedSheet == nil else { return }
        if current.state == .on { local.state = .off }
        else if local.state == .on { current.state = .off }
        current.isEnabled = local.state == .off; local.isEnabled = current.state == .off
        toField.isEnabled = current.state == .off && local.state == .off; toBrowse.isEnabled = toField.isEnabled
        if !toField.isEnabled { toField.stringValue = "" }
    }
    @objc func accept() {
        guard !finished, picker == nil, window?.attachedSheet == nil else { return }
        window?.makeFirstResponder(nil)
        var options = model.options; options.from = fromField.stringValue; options.to = toField.stringValue
        options.onlyCurrentBranch = current.state == .on; options.onlyLocalBranches = local.state == .on
        finish(options)
    }
    @objc func abort() { guard picker == nil, window?.attachedSheet == nil else { return }; finish(nil) }
    @objc func resetFilter() {
        guard picker == nil, window?.attachedSheet == nil else { return }
        fromField.stringValue = ""; toField.stringValue = ""; current.state = .off; local.state = .off; accept()
    }
    private func finish(_ result: RevisionGraphOptions?) {
        guard !finished else { return }; finished = true
        let callback = completion; completion = nil
        if let window { window.sheetParent?.endSheet(window); window.close() }; callback?(result)
    }
    @objc private func browseFrom() { browse(fromField) }
    @objc private func browseTo() { guard toField.isEnabled else { return }; browse(toField) }
    private func browse(_ field: NSTextField) {
        guard !finished, picker == nil, let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(nil)
        let request = UUID(); pickerRequest = request
        let picker = ReferenceBrowserWindowController(repository: model.repository, access: model.access, initial: "HEAD", preferences: model.preferences, pickMultiple: true) { [weak self, weak field] value in
            guard let self, !self.finished, self.pickerRequest == request else { return }
            self.pickerRequest = nil; self.picker = nil
            if let value, !value.isEmpty { field?.stringValue = value }
            self.pendingFocus = field; self.restoreInputFocus()
        }
        self.picker = picker; if let child = picker.window { child.alphaValue = window.alphaValue; window.beginSheet(child) }
        picker.model.load()
    }
    @objc private func sheetEnded() { restoreInputFocus() }
    private func restoreInputFocus() {
        guard !finished, picker == nil, let window, window.attachedSheet == nil, let field = pendingFocus else { return }
        pendingFocus = nil; window.makeFirstResponder(field)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { guard picker == nil, sender.attachedSheet == nil else { return false }; finish(nil); return false }
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        pickerRequest = nil; pendingFocus = nil; picker?.abandonPresentation(); picker = nil
        if !finished { finished = true; let callback = completion; completion = nil; callback?(nil) }
    }
}
