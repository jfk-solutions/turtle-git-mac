// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation

@MainActor private final class GitSVNAuthenticationWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class GitSVNPromptWindowController: NSWindowController, NSWindowDelegate {
    let prompt: GitSVNAuthenticationPrompt
    let username = NSTextField()
    let password = NSSecureTextField()
    let save = NSButton(checkboxWithTitle: "Save authentication", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var response: ((GitSVNAuthenticationResponse?) -> Void)?
    private var panel: NSOpenPanel?
    private(set) var certificateViewer: GitCertificateDetailsWindowController?
    let certificateDetails: GitCertificateDetails?
    let sha1 = NSTextField(wrappingLabelWithString: "")
    let sha256 = NSTextField(wrappingLabelWithString: "")
    private(set) var finished = false
    var certificateDirectory: URL?
    init(prompt: GitSVNAuthenticationPrompt, icon: NSImage? = nil, response: @escaping (GitSVNAuthenticationResponse?) -> Void) {
        self.prompt = prompt; self.response = response; certificateDetails = try? prompt.certificateDetails()
        let window = GitSVNAuthenticationWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: prompt.kind == .trust ? 440 : 220), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = prompt.kind == .trust ? "SVN Certificate Check" : prompt.kind == .clientCertificate ? "SVN Client Certificate" : "SVN Authentication"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 530, height: prompt.kind == .trust ? 350 : 190)
        super.init(window: window); window.delegate = self; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document; document.addSubview(stack)
        window.contentView?.addSubview(scroll)
        if let content = window.contentView { NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)]) }
        let realm = NSTextField(wrappingLabelWithString: prompt.realm); realm.setAccessibilityLabel("Authentication realm"); stack.addArrangedSubview(realm); realm.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        username.stringValue = prompt.username ?? ""; username.setAccessibilityLabel("Username"); password.setAccessibilityLabel("Password"); save.isEnabled = prompt.maySave; save.state = .off
        if prompt.kind == .trust {
            if let icon { let image = NSImageView(image: icon); image.imageScaling = .scaleProportionallyUpOrDown; image.widthAnchor.constraint(equalToConstant: 32).isActive = true; image.heightAnchor.constraint(equalToConstant: 32).isActive = true; stack.addArrangedSubview(image) }
            for (title, value) in [("Hostname", prompt.hostname), ("Issuer", prompt.issuer), ("Valid from", prompt.validFrom), ("Valid until", prompt.validUntil)] + (certificateDetails == nil ? [("Fingerprint", prompt.fingerprint)] : []) {
                let field = NSTextField(wrappingLabelWithString: title + ": " + (value ?? "")); field.isSelectable = true; field.setAccessibilityLabel(title); stack.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            if let certificateDetails {
                sha1.stringValue = "SHA-1: " + certificateDetails.sha1; sha256.stringValue = "SHA-256: " + certificateDetails.sha256
                for (field, label) in [(sha1, "SHA-1"), (sha256, "SHA-256")] { field.isSelectable = true; field.setAccessibilityLabel(label); stack.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            }
            for text in prompt.failureDescriptions { let field = NSTextField(wrappingLabelWithString: text); field.textColor = .systemRed; stack.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        } else {
            if prompt.kind == .credentials || prompt.kind == .username { stack.addArrangedSubview(NSTextField(labelWithString: "Username:")); stack.addArrangedSubview(username); username.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            if prompt.kind == .credentials || prompt.kind == .secret { stack.addArrangedSubview(NSTextField(labelWithString: "Password:")); stack.addArrangedSubview(password); password.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            if prompt.kind != .clientCertificate { stack.addArrangedSubview(save) }
        }
        errorLabel.textColor = .systemRed; stack.addArrangedSubview(errorLabel)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 8
        let cancel = NSButton(title: prompt.kind == .trust ? "Reject" : "Cancel", target: self, action: #selector(abort)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"; buttons.addArrangedSubview(cancel)
        if prompt.kind == .trust {
            let open = NSButton(title: "Open certificate", target: self, action: #selector(openCertificate)); open.bezelStyle = .rounded; open.isEnabled = certificateDetails != nil; buttons.addArrangedSubview(open)
            let temporary = NSButton(title: "Accept temporarily", target: self, action: #selector(trustTemporary)); temporary.bezelStyle = .rounded; buttons.addArrangedSubview(temporary)
            if prompt.maySave { let permanent = NSButton(title: "Accept permanently", target: self, action: #selector(trustPermanent)); permanent.bezelStyle = .rounded; buttons.addArrangedSubview(permanent) }
            window.defaultButtonCell = cancel.cell as? NSButtonCell; cancel.keyEquivalent = "\r"; window.initialFirstResponder = cancel
        } else {
            let accept = NSButton(title: prompt.kind == .clientCertificate ? "Choose certificate…" : "OK", target: self, action: prompt.kind == .clientCertificate ? #selector(chooseCertificate) : #selector(submit)); accept.bezelStyle = .rounded; accept.keyEquivalent = "\r"; buttons.addArrangedSubview(accept); window.defaultButtonCell = accept.cell as? NSButtonCell
            window.initialFirstResponder = prompt.kind == .credentials || prompt.kind == .username ? username : prompt.kind == .secret ? password : accept
        }
        stack.addArrangedSubview(buttons)
        if let icon { window.miniwindowImage = icon }
    }
    @objc func openCertificate() {
        guard !finished, prompt.kind == .trust, let certificateDetails, let window, window.attachedSheet == nil else { return }
        let child = GitCertificateDetailsWindowController(details: certificateDetails)
        certificateViewer = child
        child.onClosed = { [weak self, weak child] in guard self?.certificateViewer === child else { return }; self?.certificateViewer = nil }
        if let sheet = child.window { window.beginSheet(sheet) }
    }
    @objc func submit() {
        guard !finished, panel == nil else { return }
        let result = GitSVNAuthenticationResponse(username: prompt.kind == .secret ? nil : username.stringValue, password: prompt.kind == .username ? nil : password.stringValue, save: prompt.maySave && save.state == .on)
        do { _ = try result.encoded(for: prompt); finish(result) } catch { errorLabel.stringValue = error.localizedDescription }
    }
    @objc func trustTemporary() { guard !finished, prompt.kind == .trust, window?.attachedSheet == nil else { return }; finish(GitSVNAuthenticationResponse(decision: .temporary)) }
    @objc func trustPermanent() { guard !finished, prompt.kind == .trust, prompt.maySave, window?.attachedSheet == nil else { return }; finish(GitSVNAuthenticationResponse(save: true, decision: .permanent)) }
    @objc func abort() { if prompt.kind == .trust { finish(GitSVNAuthenticationResponse(decision: .reject)) } else { finish(nil) } }
    @objc private func chooseCertificate() {
        guard !finished, prompt.kind == .clientCertificate, panel == nil, let window, window.attachedSheet == nil else { return }
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false; picker.prompt = "Use certificate"; panel = picker
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.finished, self.panel === picker else { return }; self.panel = nil
            if response == .OK, let source = picker.url { self.acceptCertificate(source) }
        }
    }
    func acceptCertificate(_ source: URL) {
        guard !finished, prompt.kind == .clientCertificate, let directory = certificateDirectory else { errorLabel.stringValue = GitSVNAuthenticationFailure.certificateDirectory.localizedDescription; return }
        do { let copy = try GitSVNClientCertificate.copy(source, directory: directory); finish(GitSVNAuthenticationResponse(file: copy.path)) }
        catch { errorLabel.stringValue = error.localizedDescription }
    }
    private func finish(_ result: GitSVNAuthenticationResponse?) {
        guard !finished else { return }; finished = true
        username.stringValue = ""; password.stringValue = ""; username.isEnabled = false; password.isEnabled = false; save.isEnabled = false
        if let panel { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        certificateViewer?.close(); certificateViewer = nil
        let callback = response; response = nil; close(); callback?(result)
    }
    func windowWillClose(_ notification: Notification) { if !finished { abort() } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class GitCertificateDetailsWindowController: NSWindowController, NSWindowDelegate {
    let text = NSTextView()
    var onClosed: () -> Void = {}
    init(details: GitCertificateDetails) {
        let window = GitSVNAuthenticationWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = details.subject + " – Certificate"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 500, height: 320)
        super.init(window: window); window.delegate = self
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]; scroll.documentView = text
        text.string = details.description; text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); text.textContainerInset = NSSize(width: 12, height: 12)
        window.contentView = scroll
    }
    override func close() { if let window { window.sheetParent?.endSheet(window); window.close() } }
    func windowWillClose(_ notification: Notification) { if let window { window.sheetParent?.endSheet(window) }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
