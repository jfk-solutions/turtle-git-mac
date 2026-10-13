// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

@MainActor private final class GitAskpassNativeWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        #if DEBUG
        let flags = event.modifierFlags.intersection([.command,.option,.shift,.control])
        if flags == [.command,.option,.shift], event.charactersIgnoringModifiers?.lowercased() == "s",
           Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") == true {
            DocumentationCapture.saveWindow(); return true
        }
        #endif
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class GitAskpassWindowController: NSWindowController, NSWindowDelegate {
    let prompt: GitAskpassPrompt
    let field: NSTextField
    let accept = NSButton(title: "OK", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var response: ((String?) -> Void)?
    private(set) var finished = false
    init(prompt: GitAskpassPrompt, icon: NSImage? = nil, response: @escaping (String?) -> Void) {
        self.prompt = prompt; self.response = response
        field = prompt.secret ? NSSecureTextField() : NSTextField()
        let window = GitAskpassNativeWindow(contentRect: .init(x: 0, y: 0, width: 520, height: 170), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "Authentication – TurtleGit"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let label = NSTextField(wrappingLabelWithString: prompt.text)
        label.isSelectable = true
        label.setAccessibilityLabel("Git authentication request")
        field.setAccessibilityLabel(prompt.secret ? "Password or authentication response" : "Username")
        accept.target = self; accept.action = #selector(submit); accept.bezelStyle = .rounded; accept.keyEquivalent = "\r"
        cancel.target = self; cancel.action = #selector(abort); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(),accept,cancel]); buttons.orientation = .horizontal; buttons.spacing = 8
        var views: [NSView] = [label,field,buttons]
        if let icon {
            let image = NSImageView(image: icon); image.setContentHuggingPriority(.required, for: .horizontal)
            let header = NSStackView(views: [image,label]); header.orientation = .horizontal; header.spacing = 12
            NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 32),image.heightAnchor.constraint(equalToConstant: 32)])
            views[0] = header
        }
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),field.widthAnchor.constraint(equalTo: stack.widthAnchor),buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),views[0].widthAnchor.constraint(equalTo: stack.widthAnchor)])
        let width: CGFloat = icon == nil ? 488 : 444
        let bounds = (prompt.text as NSString).boundingRect(with: .init(width: width, height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13)])
        window.setContentSize(.init(width: 520, height: max(170, min(600, ceil(bounds.height) + 110))))
        window.contentMinSize = .init(width: 460, height: 170)
        window.initialFirstResponder = field; window.defaultButtonCell = accept.cell as? NSButtonCell; window.center()
    }
    @objc func submit() {
        guard !finished, GitAskpassPrompt.validResponse(field.stringValue) else { return }
        finish(field.stringValue)
    }
    @objc func abort() { finish(nil) }
    private func finish(_ value: String?) {
        guard !finished else { return }; finished = true
        field.stringValue = ""; field.isEnabled = false; accept.isEnabled = false; cancel.isEnabled = false
        let callback = response; response = nil; close(); callback?(value)
    }
    func windowWillClose(_ notification: Notification) { if !finished { finish(nil) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
