// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation
import Security
import SecurityInterface
import UniformTypeIdentifiers

@MainActor private final class GitSVNAuthenticationWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class GitSVNPromptWindowController: NSWindowController, NSWindowDelegate {
    let prompt: GitSVNAuthenticationPrompt
    let transportName:String
    private var isGit:Bool{transportName == "Git"}
    private var remoteCancelled=false
    private(set) var remoteCancelButton:NSButton?,remoteAcceptButton:NSButton?,remoteOpenButton:NSButton?
    let username = NSTextField()
    let password = NSSecureTextField()
    let save = NSButton(checkboxWithTitle: "Save authentication", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var response: ((GitSVNAuthenticationResponse?) -> Void)?
    private var panel: NSOpenPanel?
    private(set) var certificateViewer: GitCertificateDetailsWindowController?
    private var drainingCertificate: GitCertificateDetailsWindowController?
    var makeCertificateViewer: (GitCertificateDetails) -> GitCertificateDetailsWindowController = { GitCertificateDetailsWindowController(details: $0) }
    let certificateDetails: GitCertificateDetails?
    let sha1 = NSTextField(wrappingLabelWithString: "")
    let sha256 = NSTextField(wrappingLabelWithString: "")
    private(set) var finished = false
    var certificateDirectory: URL?
    init(prompt: GitSVNAuthenticationPrompt, icon: NSImage? = nil,transportName:String="SVN", response: @escaping (GitSVNAuthenticationResponse?) -> Void) {
        self.prompt = prompt; self.transportName=transportName;self.response = response; certificateDetails = try? prompt.certificateDetails()
        let window = GitSVNAuthenticationWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: prompt.kind == .trust ? 440 : 220), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = transportName+" "+(prompt.kind == .trust ? "Certificate Check" : prompt.kind == .clientCertificate ? "Client Certificate" : "Authentication")
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 530, height: prompt.kind == .trust ? 350 : 190)
        super.init(window: window); window.delegate = self; window.center()
        if isGit,prompt.kind == .trust{configureGitTrust(icon:icon);return}
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
            if prompt.kind != .clientCertificate,!isGit { stack.addArrangedSubview(save) }
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
    private func configureGitTrust(icon:NSImage?){
        guard let window else{return};window.title="TurtleGit";window.setContentSize(NSSize(width:650,height:430))
        let heading=NSTextField(wrappingLabelWithString:"Certificate verification failed!")
        let image=NSImageView(image:icon ?? NSImage());image.imageScaling = .scaleProportionallyUpOrDown;image.widthAnchor.constraint(equalToConstant:32).isActive=true;image.heightAnchor.constraint(equalToConstant:32).isActive=true
        let header=NSStackView(views:[image,heading]);header.orientation = .horizontal;header.spacing=12
        let host=NSTextField(wrappingLabelWithString:"Error validating server certificate for \""+(prompt.hostname ?? "")+"\":");host.isSelectable=true
        let error=NSTextField(wrappingLabelWithString:prompt.realm+"\n"+prompt.failureDescriptions.joined(separator:"\n"));error.textColor = .systemRed;error.isSelectable=true
        func field(_ value:String)->NSTextField{let field=NSTextField();field.stringValue=value;field.isEditable=false;field.isSelectable=true;field.isBezeled=true;field.drawsBackground=true;field.backgroundColor = .textBackgroundColor;return field}
        let identity=NSGridView(views:[[NSTextField(labelWithString:"Common Name:"),field(certificateDetails?.subject ?? "")],[NSTextField(labelWithString:"Issuer:"),field(prompt.issuer ?? "")]]);identity.rowSpacing=8;identity.columnSpacing=12;identity.column(at:0).width=132;identity.heightAnchor.constraint(equalToConstant:52).isActive=true;for row in 0..<2{identity.row(at:row).height=22}
        sha1.stringValue=certificateDetails?.sha1 ?? prompt.fingerprint ?? "";let hash=certificateDetails?.sha256 ?? "";sha256.stringValue=String(hash.prefix(57))+"\n"+String(hash.dropFirst(57))
        for view in [sha1,sha256]{view.isSelectable=true;view.isEditable=false;view.isBezeled=true;view.drawsBackground=true;view.backgroundColor = .textBackgroundColor}
        let hashes=NSGridView(views:[[NSTextField(labelWithString:"SHA-1:"),sha1],[NSTextField(labelWithString:"SHA-256:"),sha256]]);hashes.columnSpacing=12;hashes.rowSpacing=8;hashes.column(at:0).width=132;hashes.translatesAutoresizingMaskIntoConstraints=false
        let group=NSBox();group.title="Fingerprints";group.contentViewMargins=NSSize(width:10,height:10);group.heightAnchor.constraint(equalToConstant:115).isActive=true
        if let content=group.contentView{content.addSubview(hashes);NSLayoutConstraint.activate([hashes.leadingAnchor.constraint(equalTo:content.leadingAnchor),hashes.trailingAnchor.constraint(equalTo:content.trailingAnchor),hashes.topAnchor.constraint(equalTo:content.topAnchor),hashes.bottomAnchor.constraint(equalTo:content.bottomAnchor)])}
        let cancel=NSButton(title:"Cancel",target:self,action:#selector(abort)),accept=NSButton(title:"Accept certificate",target:self,action:#selector(trustTemporary)),open=NSButton(title:"Open certificate",target:self,action:#selector(openCertificate));for button in [cancel,accept,open]{button.bezelStyle = .rounded};open.isEnabled=certificateDetails != nil;cancel.keyEquivalent="\r";window.defaultButtonCell=cancel.cell as? NSButtonCell;window.initialFirstResponder=cancel;remoteCancelButton=cancel;remoteAcceptButton=accept;remoteOpenButton=open
        let footer=NSStackView(views:[open,NSView(),accept,cancel]);footer.orientation = .horizontal;footer.spacing=8
        let rows:[NSView]=[header,host,error,identity,group,footer],body=NSStackView(views:rows);body.orientation = .vertical;body.alignment = .leading;body.spacing=12;body.translatesAutoresizingMaskIntoConstraints=false;window.contentView?.addSubview(body)
        if let content=window.contentView{NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),body.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),body.topAnchor.constraint(equalTo:content.topAnchor,constant:16),body.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-16)]);for row in rows{row.widthAnchor.constraint(equalTo:body.widthAnchor).isActive=true}}
    }
    @objc func openCertificate() {
        guard !finished, prompt.kind == .trust, certificateViewer == nil, drainingCertificate == nil, let certificateDetails, let window, window.attachedSheet == nil else { return }
        let child = makeCertificateViewer(certificateDetails)
        child.window?.appearance = window.appearance
        certificateViewer = child
        child.onClosed = { [weak self, weak child] in guard self?.certificateViewer === child else { return }; self?.certificateViewer = nil }
        if let sheet = child.window { window.beginSheet(sheet) }
    }
    @objc func submit() {
        guard !finished, panel == nil else { return }
        let result = GitSVNAuthenticationResponse(username: prompt.kind == .secret ? nil : username.stringValue, password: prompt.kind == .username ? nil : password.stringValue, save: !isGit && prompt.maySave && save.state == .on)
        do { _ = try result.encoded(for: prompt); finish(result) } catch { errorLabel.stringValue = error.localizedDescription }
    }
    @objc func trustTemporary() { guard !finished, prompt.kind == .trust, window?.attachedSheet == nil else { return }; finish(GitSVNAuthenticationResponse(decision: .temporary)) }
    @objc func trustPermanent() { guard !isGit,!finished, prompt.kind == .trust, prompt.maySave, window?.attachedSheet == nil else { return }; finish(GitSVNAuthenticationResponse(save: true, decision: .permanent)) }
    @objc func abort() {if isGit{remoteCancelled=true}; if prompt.kind == .trust { finish(GitSVNAuthenticationResponse(decision: .reject)) } else { finish(nil) } }
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
        let callback = response; response = nil
        if isGit{
            if let child=certificateViewer{certificateViewer=nil;drainingCertificate=child;child.onClosed={ [self,weak child] in guard self.drainingCertificate === child else{return};self.drainingCertificate=nil;self.finishRemote(result,callback:callback)};child.close()}
            else{finishRemote(result,callback:callback)}
            return
        }
        if let child = certificateViewer {
            certificateViewer = nil; drainingCertificate = child
            child.onClosed = { [self, weak child] in
                guard drainingCertificate === child else { return }
                drainingCertificate = nil; close(); callback?(result)
            }
            child.close()
        } else { close(); callback?(result) }
    }
    private func finishRemote(_ result:GitSVNAuthenticationResponse?,callback:((GitSVNAuthenticationResponse?)->Void)?){
        if let window{window.sheetParent?.endSheet(window);window.orderOut(nil);window.close()}
        func drain(){if self.window?.sheetParent != nil || self.window?.attachedSheet != nil || self.drainingCertificate != nil{DispatchQueue.main.asyncAfter(deadline:.now()+0.01,execute:drain);return};callback?(self.remoteCancelled ? self.prompt.kind == .trust ? GitSVNAuthenticationResponse(decision:.reject):nil:result)}
        DispatchQueue.main.async(execute:drain)
    }
    func windowWillClose(_ notification: Notification) { if !finished { abort() } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class GitCertificateDetailsWindowController: NSWindowController, NSWindowDelegate {
    @MainActor private final class ExportChoice {
        let panel: NSSavePanel
        let bytes: Data
        var responded = false
        var destination: URL?
        var observer: NSObjectProtocol?
        init(panel: NSSavePanel, bytes: Data) { self.panel = panel; self.bytes = bytes }
    }
    let details: GitCertificateDetails
    let text = NSTextView()
    let certificateView = SFCertificateView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
    let tabs = NSTabView()
    let format = NSPopUpButton()
    let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy fingerprints", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    private let pasteboard: NSPasteboard
    private var choice: ExportChoice?
    private(set) var exporting = false
    private(set) var retired = false
    private var notified = false
    var onClosed: () -> Void = {}
    var presentExport: ((NSSavePanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var exportDestination: (NSSavePanel) -> URL? = { $0.url }
    var writeExport: @Sendable (Data, URL) async throws -> Void = { bytes, url in
        try await Task.detached { try bytes.write(to: url, options: .atomic) }.value
    }
    init(details: GitCertificateDetails, pasteboard: NSPasteboard = .general, images: ((String) -> NSImage?)? = nil) {
        self.details = details; self.pasteboard = pasteboard
        let window = GitSVNAuthenticationWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = details.subject + " – Certificate"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 650, height: 420)
        super.init(window: window); window.delegate = self
        certificateView.setEditableTrust(false); certificateView.setDisplayTrust(false)
        certificateView.setDisplayDetails(true); certificateView.setDetailsDisclosed(true)
        if let certificate = SecCertificateCreateWithData(nil, details.der as CFData) { certificateView.setCertificate(certificate) }
        certificateView.autoresizingMask = [.width]
        let nativeScroll = NSScrollView(); nativeScroll.hasVerticalScroller = true; nativeScroll.documentView = certificateView
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        let nativeTab = NSTabViewItem(identifier: "certificate"); nativeTab.label = "Certificate"; nativeTab.view = nativeScroll; tabs.addTabViewItem(nativeTab)
        let rawScroll = NSScrollView(); rawScroll.hasVerticalScroller = true; rawScroll.documentView = text
        text.string = details.description; text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); text.textContainerInset = NSSize(width: 12, height: 12)
        let rawTab = NSTabViewItem(identifier: "text"); rawTab.label = "Text"; rawTab.view = rawScroll; tabs.addTabViewItem(rawTab)
        format.addItems(withTitles: ["DER certificate (.cer)", "PEM certificate (.pem)"]); format.setAccessibilityLabel("Certificate export format")
        copyButton.target = self; copyButton.action = #selector(copyFingerprints); copyButton.bezelStyle = .rounded; copyButton.image = images?("copy") ?? Self.sourceIcon("copy"); copyButton.imagePosition = .imageLeading
        exportButton.target = self; exportButton.action = #selector(exportCertificate); exportButton.bezelStyle = .rounded; exportButton.image = images?("saveas") ?? Self.sourceIcon("saveas"); exportButton.imagePosition = .imageLeading
        let close = NSButton(title: "Close", target: self, action: #selector(closeInspector)); close.bezelStyle = .rounded; close.keyEquivalent = "\r"
        window.defaultButtonCell = close.cell as? NSButtonCell; window.initialFirstResponder = close
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let footer = NSStackView(views: [copyButton, format, exportButton, progress, NSView(), close]); footer.orientation = .horizontal; footer.spacing = 8
        status.textColor = .systemRed; status.setAccessibilityLabel("Certificate export status")
        let body = NSStackView(views: [tabs, status, footer]); body.orientation = .vertical; body.alignment = .leading; body.spacing = 8; body.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(body)
        if let content = window.contentView { NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            tabs.widthAnchor.constraint(equalTo: body.widthAnchor), tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            status.widthAnchor.constraint(equalTo: body.widthAnchor), status.heightAnchor.constraint(equalToConstant: 32), footer.widthAnchor.constraint(equalTo: body.widthAnchor)]) }
    }
    /// The command-line helper shares source models but deliberately does not
    /// link the application's Core framework. Read its packaged command artwork
    /// through the containing application, as the helper entry point does.
    private static func sourceIcon(_ name: String) -> NSImage? {
        var application = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while application.path != "/" && application.pathExtension != "app" { application.deleteLastPathComponent() }
        guard application.pathExtension == "app",
              let image = NSImage(contentsOf: application.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/" + name + ".ico")) else { return nil }
        image.size = NSSize(width: 16, height: 16); return image
    }
    @objc func copyFingerprints() {
        guard !retired else { return }; pasteboard.clearContents(); pasteboard.setString(details.fingerprints, forType: .string)
    }
    @objc func exportCertificate() {
        guard !retired, !exporting, choice == nil, let window, window.attachedSheet == nil else { return }
        let encoding: GitCertificateDetails.ExportFormat = format.indexOfSelectedItem == 1 ? .pem : .der
        let panel = NSSavePanel(); panel.title = "Export certificate"; panel.nameFieldStringValue = "Certificate." + encoding.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: encoding.fileExtension) ?? .data]; panel.canCreateDirectories = true
        let pending = ExportChoice(panel: panel, bytes: details.encoded(as: encoding)); choice = pending; updateControls(); status.stringValue = ""
        pending.observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self, weak pending] _ in
            DispatchQueue.main.async { if let pending { self?.drain(pending) } }
        }
        let reply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.choice === pending, !pending.responded else { return }
            pending.responded = true; pending.destination = !self.retired && response == .OK ? self.exportDestination(panel) : nil
            self.release(pending, response: response)
        }
        if let presentExport { presentExport(panel, window, reply) } else { panel.beginSheetModal(for: window, completionHandler: reply) }
    }
    private func release(_ pending: ExportChoice, response: NSApplication.ModalResponse) {
        if let parent = pending.panel.sheetParent { parent.endSheet(pending.panel, returnCode: response) }
        pending.panel.orderOut(nil)
        DispatchQueue.main.async { [self] in drain(pending) }
    }
    private func drain(_ pending: ExportChoice) {
        guard choice === pending, pending.responded, pending.panel.sheetParent == nil, window?.attachedSheet !== pending.panel else { return }
        choice = nil
        if let observer = pending.observer { NotificationCenter.default.removeObserver(observer); pending.observer = nil }
        guard !retired, let destination = pending.destination, destination.isFileURL else { updateControls(); notifyRetired(); return }
        exporting = true; updateControls(); progress.startAnimation(nil)
        let bytes = pending.bytes, writer = writeExport, scoped = destination.startAccessingSecurityScopedResource()
        Task { [self] in
            defer { if scoped { destination.stopAccessingSecurityScopedResource() }; exporting = false; progress.stopAnimation(nil); updateControls(); notifyRetired() }
            do { try await writer(bytes, destination) }
            catch { if !retired { status.stringValue = error.localizedDescription } }
        }
    }
    private func updateControls() { format.isEnabled = !retired && !exporting && choice == nil; exportButton.isEnabled = format.isEnabled; copyButton.isEnabled = !retired }
    @objc private func closeInspector() { close() }
    override func close() {
        retire()
        if let window { window.sheetParent?.endSheet(window); window.close() }
        notifyRetired()
    }
    private func retire() {
        guard !retired else { return }; retired = true; updateControls()
        if let choice { choice.responded = true; choice.destination = nil; release(choice, response: .cancel) }
    }
    private func notifyRetired() {
        guard retired, !exporting, choice == nil, !notified else { return }; notified = true
        let callback = onClosed; onClosed = {}; callback()
    }
    func windowWillClose(_ notification: Notification) {
        if let window { window.sheetParent?.endSheet(window) }; retire()
        DispatchQueue.main.async { [self] in notifyRetired() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
