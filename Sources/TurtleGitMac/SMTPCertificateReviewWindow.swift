// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Security
import SecurityInterface
import UniformTypeIdentifiers
import TurtleGitCore

/// An SMTP decision belongs to the actual suspended handshake, never to a
/// preflight probe or a persistent system/Git trust override.
@MainActor final class SMTPCertificateReviewWindowController:NSWindowController,NSWindowDelegate{
    let details:GitCertificateDetails
    let hostname:String
    let acceptButton=NSButton(title:NSLocalizedString("Accept certificate",comment:""),target:nil,action:nil)
    let cancelButton=NSButton(title:NSLocalizedString("Cancel",comment:""),target:nil,action:nil)
    let openButton=NSButton(title:NSLocalizedString("Open certificate",comment:""),target:nil,action:nil)
    private(set) var inspector:SMTPCertificateInspectorWindowController?
    var presentInspector:(NSWindow,NSWindow)->Bool={parent,child in guard parent.attachedSheet == nil else{return false};parent.beginSheet(child);return true}
    var makeInspector:(GitCertificateDetails)->SMTPCertificateInspectorWindowController={SMTPCertificateInspectorWindowController(details:$0)}
    var confirmingQuit=false{didSet{inspector?.confirmingQuit=confirmingQuit;updateControls();if confirmingQuit{invalidate()}}}
    private var result=false,finishing=false,retired=false
    private var release:SMTPCertificateSheetDrain?
    private var completion:((Bool)->Void)?
    private let accepts:()->Bool
    init(hostname:String,der:Data,validationError:String,accepts:@escaping()->Bool,completion:@escaping(Bool)->Void)throws{
        self.hostname=hostname;self.details=try GitCertificateDetails(base64DER:der.base64EncodedString());self.accepts=accepts;self.completion=completion
        let window=SMTPCertificateNativeWindow(contentRect:NSRect(x:0,y:0,width:650,height:430),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="TurtleGit";window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self
        window.escapeAction={ [weak self] in self?.reject() }
        let icon=NSImageView(image:MenuIcon.originalImage(resource:"certcheck") ?? NSImage());icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant:32).isActive=true;icon.heightAnchor.constraint(equalToConstant:32).isActive=true
        let heading=NSTextField(wrappingLabelWithString:NSLocalizedString("Certificate verification failed!",comment:""));heading.font = .systemFont(ofSize:NSFont.systemFontSize,weight:.semibold)
        let header=NSStackView(views:[icon,heading]);header.orientation = .horizontal;header.spacing=12;header.alignment = .centerY
        let host=NSTextField(wrappingLabelWithString:String(format:NSLocalizedString("Error validating server certificate for \"%@\":",comment:""),hostname));host.isSelectable=true;host.setAccessibilityLabel(NSLocalizedString("Hostname",comment:""))
        let error=NSTextField(wrappingLabelWithString:validationError);error.textColor = .systemRed;error.isSelectable=true
        func readOnly(_ value:String,label:String,multiline:Bool=false)->NSTextField{
            let field=NSTextField();field.stringValue=value;field.isEditable=false;field.isSelectable=true;field.isBezeled=true;field.drawsBackground=true;field.backgroundColor = .textBackgroundColor;field.setAccessibilityLabel(NSLocalizedString(label,comment:""))
            field.cell?.usesSingleLineMode = !multiline;field.cell?.wraps=multiline;field.cell?.isScrollable = !multiline
            if multiline{field.lineBreakMode = .byCharWrapping;field.heightAnchor.constraint(equalToConstant:42).isActive=true}
            return field
        }
        func labeledGrid(_ rows:[(String,NSTextField)])->NSGridView{
            let grid=NSGridView(views:rows.map{[NSTextField(labelWithString:NSLocalizedString($0.0,comment:"")+":"),$0.1]});grid.columnSpacing=12;grid.rowSpacing=8;grid.xPlacement = .fill;grid.column(at:0).width=132;grid.column(at:0).xPlacement = .leading;grid.column(at:1).xPlacement = .fill
            return grid
        }
        let issuer: String
        if let cert=SecCertificateCreateWithData(nil,details.der as CFData){issuer=Self.issuer(cert)}else{issuer=""}
        let identity=labeledGrid([("Common Name",readOnly(details.subject,label:"Common Name")),("Issuer",readOnly(issuer,label:"Issuer"))])
        // NSStackView otherwise distributes spare height into this grid's rows,
        // separating the source's adjacent Common Name and Issuer fields.
        identity.heightAnchor.constraint(equalToConstant:52).isActive=true
        identity.setContentHuggingPriority(.required,for:.vertical)
        for row in 0..<identity.numberOfRows{identity.row(at:row).height=22}
        let sha256=String(details.sha256.prefix(57))+"\n"+String(details.sha256.dropFirst(57))
        let hashes=labeledGrid([("SHA-1",readOnly(details.sha1,label:"SHA-1")),("SHA-256",readOnly(sha256,label:"SHA-256",multiline:true))]);hashes.translatesAutoresizingMaskIntoConstraints=false
        let fingerprints=NSBox();fingerprints.title=NSLocalizedString("Fingerprints",comment:"");fingerprints.boxType = .primary;fingerprints.contentViewMargins=NSSize(width:10,height:10)
        if let content=fingerprints.contentView{content.addSubview(hashes);NSLayoutConstraint.activate([hashes.leadingAnchor.constraint(equalTo:content.leadingAnchor),hashes.trailingAnchor.constraint(equalTo:content.trailingAnchor),hashes.topAnchor.constraint(equalTo:content.topAnchor),hashes.bottomAnchor.constraint(equalTo:content.bottomAnchor)])}
        fingerprints.heightAnchor.constraint(equalToConstant:115).isActive=true
        for button in [cancelButton,openButton,acceptButton]{button.bezelStyle = .rounded;button.target=self}
        cancelButton.action=#selector(reject);cancelButton.keyEquivalent="\r";openButton.action=#selector(openCertificate);acceptButton.action=#selector(acceptTemporary)
        window.defaultButtonCell=cancelButton.cell as? NSButtonCell;window.initialFirstResponder=cancelButton
        let footer=NSStackView(views:[openButton,NSView(),acceptButton,cancelButton]);footer.orientation = .horizontal;footer.spacing=8
        let fields:[NSView]=[header,host,error,identity,fingerprints,footer]
        let body=NSStackView(views:fields);body.orientation = .vertical;body.alignment = .leading;body.spacing=12;body.translatesAutoresizingMaskIntoConstraints=false
        window.contentView?.addSubview(body)
        if let content=window.contentView{NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),body.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),body.topAnchor.constraint(equalTo:content.topAnchor,constant:16),body.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-16)]);for field in fields{field.widthAnchor.constraint(equalTo:body.widthAnchor).isActive=true}}
    }
    private static func issuer(_ cert:SecCertificate)->String{
        guard let values=SecCertificateCopyValues(cert,[kSecOIDX509V1IssuerName] as CFArray,nil) as? [String:Any],let property=values[kSecOIDX509V1IssuerName as String] as? [String:Any],let components=property[kSecPropertyKeyValue as String] as? [[String:Any]] else{return ""}
        return components.compactMap{$0[kSecPropertyKeyValue as String] as? String}.joined(separator:", ")
    }
    @objc func openCertificate(){
        guard !retired,!finishing,!confirmingQuit,accepts(),inspector == nil,let window,window.attachedSheet == nil else{return}
        let child=makeInspector(details);inspector=child
        if let target=child.window{MergeWindowPresentation(window).apply(to:target)}
        child.onClosed={ [weak self,weak child] in guard let self,self.inspector === child else{return};self.inspector=nil;self.updateControls() }
        guard let target=child.window,presentInspector(window,target) else{child.close();return};updateControls()
    }
    @objc func reject(){finish(false)}
    @objc func acceptTemporary(){guard accepts(),!confirmingQuit else{return};finish(true)}
    func invalidate(){result=false;finish(false,forced:true)}
    private func finish(_ accepted:Bool,forced:Bool=false){
        if forced{result=false}
        guard !retired else{return}
        if finishing{if forced{inspector?.close()};return}
        guard forced || !accepted || inspector == nil && !confirmingQuit && accepts() else{return}
        finishing=true;result=accepted && !forced;updateControls();inspector?.close()
        let release=SMTPCertificateSheetDrain(window:window,ready:{ [self] in self.inspector == nil }){ [self] in
            self.release=nil;self.retired=true;self.window?.close()
            let done=self.completion;self.completion=nil;done?(self.result && !self.confirmingQuit && self.accepts())
        };self.release=release;release.start()
    }
    private func updateControls(){let available = !retired && !finishing && !confirmingQuit && inspector == nil && accepts();acceptButton.isEnabled=available;cancelButton.isEnabled=available;openButton.isEnabled=available}
    override func close(){invalidate()}
    func windowShouldClose(_ sender:NSWindow)->Bool{reject();return false}
    func windowWillClose(_ notification:Notification){if !retired{invalidate()}}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}

@MainActor final class SMTPCertificateInspectorWindowController:NSWindowController,NSWindowDelegate{
    let details:GitCertificateDetails
    let certificateView=SFCertificateView(frame:NSRect(x:0,y:0,width:700,height:800))
    let text=NSTextView(),tabs=NSTabView(),format=NSPopUpButton()
    let exportButton=NSButton(title:NSLocalizedString("Export…",comment:""),target:nil,action:nil)
    let copyButton=NSButton(title:NSLocalizedString("Copy fingerprints",comment:""),target:nil,action:nil)
    private let closeButton=NSButton(title:NSLocalizedString("Close",comment:""),target:nil,action:nil)
    let status=NSTextField(wrappingLabelWithString:"")
    private let spinner=NSProgressIndicator(),pasteboard:NSPasteboard
    private(set) var exporting=false,retired=false
    var hasPendingWork:Bool{exporting || choice != nil}
    private var epoch=0
    var confirmingQuit=false{didSet{if oldValue != confirmingQuit{epoch += 1};updateControls()}}
    var onClosed:()->Void={}
    var presentExport:((NSSavePanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var exportDestination:(NSSavePanel)->URL?={$0.url}
    var writeExport:@Sendable(Data,URL)async throws->Void={data,url in try await Task.detached{try data.write(to:url,options:.atomic)}.value}
    @MainActor private final class Choice{
        let panel:NSSavePanel,bytes:Data
        var replied=false
        init(_ panel:NSSavePanel,_ bytes:Data){self.panel=panel;self.bytes=bytes}
    }
    private var choice:Choice?,release:SMTPCertificateSheetDrain?
    init(details:GitCertificateDetails,pasteboard:NSPasteboard = .general){
        self.details=details;self.pasteboard=pasteboard
        let window=SMTPCertificateNativeWindow(contentRect:NSRect(x:0,y:0,width:760,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title=details.subject+" – "+NSLocalizedString("Certificate",comment:"");window.isReleasedWhenClosed=false;window.contentMinSize=NSSize(width:650,height:420)
        super.init(window:window);window.delegate=self;window.escapeAction={ [weak self] in self?.close() }
        certificateView.setEditableTrust(false);certificateView.setDisplayTrust(false);certificateView.setDisplayDetails(true);certificateView.setDetailsDisclosed(true)
        if let cert=SecCertificateCreateWithData(nil,details.der as CFData){certificateView.setCertificate(cert)};certificateView.autoresizingMask = [.width]
        let native=NSScrollView();native.hasVerticalScroller=true;native.documentView=certificateView
        let raw=NSScrollView();raw.hasVerticalScroller=true;raw.documentView=text;text.string=details.description;text.isEditable=false;text.isSelectable=true;text.isRichText=false;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.isVerticallyResizable=true;text.autoresizingMask = [.width];text.textContainer?.widthTracksTextView=true;text.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        for (label,view) in [("Certificate",native),("Text",raw)]{let tab=NSTabViewItem(identifier:label);tab.label=NSLocalizedString(label,comment:"");tab.view=view;tabs.addTabViewItem(tab)}
        format.addItems(withTitles:[NSLocalizedString("DER certificate (.cer)",comment:""),NSLocalizedString("PEM certificate (.pem)",comment:"")]);format.setAccessibilityLabel(NSLocalizedString("Certificate export format",comment:""))
        for button in [copyButton,exportButton,closeButton]{button.target=self;button.bezelStyle = .rounded}
        copyButton.action=#selector(copyFingerprints);copyButton.image=MenuIcon.originalImage(resource:"copy");copyButton.imagePosition = .imageLeading;exportButton.action=#selector(exportCertificate);exportButton.image=MenuIcon.originalImage(resource:"saveas");exportButton.imagePosition = .imageLeading;closeButton.action=#selector(closeInspector);closeButton.keyEquivalent="\r";window.defaultButtonCell=closeButton.cell as? NSButtonCell
        spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped=false;status.textColor = .systemRed
        let footer=NSStackView(views:[copyButton,format,exportButton,spinner,NSView(),closeButton]);footer.orientation = .horizontal;footer.spacing=8
        let body=NSStackView(views:[tabs,status,footer]);body.orientation = .vertical;body.alignment = .leading;body.spacing=8;body.translatesAutoresizingMaskIntoConstraints=false;window.contentView?.addSubview(body)
        if let content=window.contentView{NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),body.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-12),body.topAnchor.constraint(equalTo:content.topAnchor,constant:12),body.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12),tabs.widthAnchor.constraint(equalTo:body.widthAnchor),tabs.heightAnchor.constraint(greaterThanOrEqualToConstant:280),status.widthAnchor.constraint(equalTo:body.widthAnchor),status.heightAnchor.constraint(equalToConstant:32),footer.widthAnchor.constraint(equalTo:body.widthAnchor)])}
    }
    @objc func copyFingerprints(){guard !retired,!confirmingQuit else{return};pasteboard.clearContents();pasteboard.setString(details.fingerprints,forType:.string)}
    @objc func exportCertificate(){
        guard !retired,!confirmingQuit,!hasPendingWork,let window,window.attachedSheet == nil else{return}
        let encoding:GitCertificateDetails.ExportFormat=format.indexOfSelectedItem==1 ? .pem:.der
        let panel=NSSavePanel();panel.title=NSLocalizedString("Export certificate",comment:"");panel.nameFieldStringValue="Certificate."+encoding.fileExtension;panel.allowedContentTypes=[UTType(filenameExtension:encoding.fileExtension) ?? .data];panel.canCreateDirectories=true;panel.appearance=window.appearance;panel.alphaValue=window.alphaValue
        let choice=Choice(panel,details.encoded(as:encoding)),generation=epoch;self.choice=choice;updateControls();status.stringValue=""
        let reply:(NSApplication.ModalResponse)->Void={ [weak self] response in
            guard let self,self.choice === choice,!choice.replied else{return};choice.replied=true
            let target = !self.retired && !self.confirmingQuit && self.epoch==generation && response == .OK ? self.exportDestination(panel):nil
            let release=SMTPCertificateSheetDrain(window:panel){ [self] in
                self.choice=nil
                guard !self.retired,!self.confirmingQuit,self.epoch==generation,let target,target.isFileURL else{self.updateControls();return}
                self.exporting=true;self.updateControls();self.spinner.startAnimation(nil)
                let writer=self.writeExport,bytes=choice.bytes,scoped=target.startAccessingSecurityScopedResource()
                Task{ [self] in
                    defer{if scoped{target.stopAccessingSecurityScopedResource()};self.exporting=false;self.spinner.stopAnimation(nil);self.updateControls()}
                    do{try await writer(bytes,target)}catch{if !self.retired{self.status.stringValue=error.localizedDescription}}
                }
            };release.start()
        }
        if let presentExport{presentExport(panel,window,reply)}else{panel.beginSheetModal(for:window,completionHandler:reply)}
    }
    private func updateControls(){let enabled = !retired && !confirmingQuit && !hasPendingWork;format.isEnabled=enabled;exportButton.isEnabled=enabled;copyButton.isEnabled = !retired && !confirmingQuit;closeButton.isEnabled = !confirmingQuit}
    @objc private func closeInspector(){guard !confirmingQuit else{return};close()}
    override func close(){
        guard !retired else{return};retired=true;updateControls()
        if let choice,!choice.replied{choice.replied=true;let release=SMTPCertificateSheetDrain(window:choice.panel){ [self] in self.choice=nil };release.start()}
        let release=SMTPCertificateSheetDrain(window:window,ready:{ [self] in !self.hasPendingWork }){ [self] in self.release=nil;self.window?.close();let done=self.onClosed;self.onClosed={};done() };self.release=release;release.start()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{guard !confirmingQuit else{return false};close();return false}
    func windowWillClose(_ notification:Notification){if !retired{close()}}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}

@MainActor final class SMTPCertificateNativeWindow:NSWindow{
    var escapeAction:()->Void={}
    override func performKeyEquivalent(with event:NSEvent)->Bool{if event.type == .keyDown,event.keyCode==53{escapeAction();return true};return super.performKeyEquivalent(with:event)}
}

/// Poll actual native detach and accepted export drain, including hidden sheets.
@MainActor final class SMTPCertificateSheetDrain{
    static private(set) var activeCount=0
    private let window:NSWindow?,parent:NSWindow?,ready:()->Bool
    private var completion:()->Void,waiter:Task<Void,Never>?
    private var started=false,finished=false
    init(window:NSWindow?,ready:@escaping()->Bool={true},completion:@escaping()->Void){self.window=window;parent=window?.sheetParent;self.ready=ready;self.completion=completion}
    func start(){guard !started else{return};started=true;Self.activeCount += 1
        if let window{window.sheetParent?.endSheet(window,returnCode:.abort);window.orderOut(nil)}
        DispatchQueue.main.async{ [self] in self.drain();if !self.finished{self.waiter=Task{ @MainActor [self] in while !self.finished{try? await Task.sleep(nanoseconds:5_000_000);self.drain()} }} }
    }
    private func drain(){guard !finished,window?.sheetParent == nil,window?.attachedSheet == nil,window == nil || parent?.attachedSheet !== window,ready() else{return};finished=true;Self.activeCount -= 1;waiter?.cancel();waiter=nil;let done=completion;completion={};done()}
}
