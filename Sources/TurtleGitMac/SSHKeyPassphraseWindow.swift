// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Owned native response dialog for the encrypted-key transport coordinator.
/// Its response is one-shot; closing clears the field and answers Cancel.
@MainActor final class SSHKeyPassphraseWindowController: NSWindowController, NSWindowDelegate {
    let keyName: String
    let passphrase = NSSecureTextField()
    let accept = NSButton(title: "OK", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let saveAuthentication = NSButton(checkboxWithTitle: "Save authentication", target: nil, action: nil)
    private(set) var acceptedSave = false
    private var response: ((String?) -> Void)?
    private(set) var finished = false
    var onClosed: () -> Void = {}
    init(keyName: String, retry: Bool = false, warning: String? = nil, response: @escaping (String?) -> Void) {
        self.keyName = keyName; self.response = response
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: warning == nil ? 190 : 235), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SSH key passphrase – TurtleGit"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let label = NSTextField(wrappingLabelWithString: (retry ? "Incorrect passphrase. Try again.\n" : "") + "Enter the passphrase for \"" + keyName + "\":")
        passphrase.setAccessibilityLabel("SSH key passphrase"); passphrase.placeholderString = "Passphrase"
        accept.target = self; accept.action = #selector(submit); accept.bezelStyle = .rounded; accept.keyEquivalent = "\r"
        cancel.target = self; cancel.action = #selector(abort); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(),accept,cancel]); buttons.orientation = .horizontal; buttons.spacing = 8
        var views: [NSView] = [label,passphrase,saveAuthentication]
        if let warning { views.append(NSTextField(wrappingLabelWithString: warning)) }
        views.append(buttons)
        let layout = NSStackView(views: views); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 14; layout.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(layout); window.contentView = content
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant:16),layout.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant:-16),layout.topAnchor.constraint(equalTo: content.topAnchor,constant:16),layout.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant:-16),label.widthAnchor.constraint(equalTo:layout.widthAnchor),passphrase.widthAnchor.constraint(equalTo:layout.widthAnchor),buttons.widthAnchor.constraint(equalTo:layout.widthAnchor)])
        window.initialFirstResponder = passphrase; window.defaultButtonCell = accept.cell as? NSButtonCell
    }
    @objc func submit() {
        guard !finished else { return }
        let value = passphrase.stringValue
        guard !value.utf8.contains(0), !value.contains("\n"), !value.contains("\r"), value.utf8.count + "TurtleGitSSHAskpass\0".utf8.count <= 65_536 else { NSSound.beep(); return }
        acceptedSave = saveAuthentication.state == .on
        finish(value)
    }
    @objc func abort() { finish(nil) }
    private func finish(_ value: String?) {
        guard !finished else { return }; finished = true
        passphrase.stringValue = ""; passphrase.isEnabled = false; accept.isEnabled = false; cancel.isEnabled = false
        saveAuthentication.isEnabled = false
        let response = response; self.response = nil
        if let window { window.sheetParent?.endSheet(window) }; close(); response?(value)
    }
    func windowWillClose(_ notification: Notification) {
        if !finished { finished = true; passphrase.stringValue = ""; let response = response; self.response = nil; response?(nil) }
        passphrase.isEnabled = false; accept.isEnabled = false; cancel.isEnabled = false
        if let window { window.sheetParent?.endSheet(window, returnCode: .abort) }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
