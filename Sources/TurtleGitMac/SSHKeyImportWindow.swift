// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SSHKeyImportModel: ObservableObject {
    static var activeOperations=0
    @Published private(set) var source:URL?
    @Published private(set) var folder:URL?
    @Published var filename="id_imported"
    @Published var oldPassphrase=""
    @Published var changePassphrase=false
    @Published var newPassphrase=""
    @Published var confirmation=""
    @Published var changeComment=false
    @Published var comment=""
    @Published private(set) var busy=false
    @Published private(set) var result:SSHKeyGenerationResult?
    @Published var error:String?
    private var sourceAccess:RepositoryAccessLease?
    private var folderAccess:RepositoryAccessLease?
    private var panel:NSOpenPanel?
    private var token:OperationCancellation?
    private(set) var retired=false
    weak var window:NSWindow?
    var resultAccess:RepositoryAccessLease? { result == nil ? nil : folderAccess }
    var imported:(SSHKeyGenerationResult)->Void={ _ in }
    var converter:() throws -> URL = SSHKeyConversion.executable
    var keygen:() throws -> URL = { try SSHKeyGeneration.executable() }
    var valid:Bool {
        guard !retired, let source,let folder,!filename.isEmpty,![".",".."].contains(filename),!filename.contains("/"), !changePassphrase || newPassphrase==confirmation else { return false }
        var request=SSHKeyConversionRequest(source:source,destination:folder.appendingPathComponent(filename))
        request.oldPassphrase=oldPassphrase;request.newPassphrase=changePassphrase ? newPassphrase : nil;request.comment=changeComment ? comment : nil
        return request.valid
    }
    func chooseSource() {
        guard !retired,!busy,let window,window.attachedSheet==nil else { return }
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.canChooseFiles=true
        panel.title="Load existing SSH key";panel.prompt="Load";self.panel=panel
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self,self.panel===panel else { return };self.panel=nil
            guard !self.retired,response == .OK,let file=panel.url else { return }
            let lease=RepositoryAccessLease(url:file,provider:SystemSSHIdentityBookmarkProvider())
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { self.error=RepositoryAccessFailure.securityScopeUnavailable.localizedDescription;return }
            self.selectSource(file,access:lease)
        }
    }
    func selectSource(_ file:URL,access:RepositoryAccessLease?) {
        guard !retired,!busy else { return }
        do {
            guard file.isFileURL,try FileManager.default.attributesOfItem(atPath:file.path)[.type] as? FileAttributeType == .typeRegular else { throw SSHKeyConversionFailure.input }
            source=file;sourceAccess=access;oldPassphrase="";newPassphrase="";confirmation="";result=nil;error=nil
            filename=file.deletingPathExtension().lastPathComponent+"_openssh"
        } catch { self.error=error.localizedDescription }
    }
    func chooseFolder() {
        guard !retired,!busy,let window,window.attachedSheet==nil else { return }
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true
        panel.title="Save imported SSH key pair";panel.prompt="Choose folder"
        panel.directoryURL=folder ?? source?.deletingLastPathComponent();self.panel=panel
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self,self.panel===panel else { return };self.panel=nil
            guard !self.retired,response == .OK,let folder=panel.url else { return }
            let lease=RepositoryAccessLease(url:folder)
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { self.error=RepositoryAccessFailure.securityScopeUnavailable.localizedDescription;return }
            self.selectFolder(folder,access:lease)
        }
    }
    func selectFolder(_ folder:URL,access:RepositoryAccessLease?) {
        guard !retired,!busy else { return };self.folder=folder;folderAccess=access;result=nil;error=nil
    }
    func convert() {
        guard valid,!busy,let source,let folder else { return }
        var request=SSHKeyConversionRequest(source:source,destination:folder.appendingPathComponent(filename))
        request.oldPassphrase=oldPassphrase;request.newPassphrase=changePassphrase ? newPassphrase : nil;request.comment=changeComment ? comment : nil
        let inputLease=sourceAccess,outputLease=folderAccess,token=OperationCancellation();self.token=token
        oldPassphrase="";newPassphrase="";confirmation="";result=nil;error=nil;busy=true
        Self.activeOperations += 1
        Task {
            defer { busy=false;self.token=nil;Self.activeOperations -= 1;withExtendedLifetime(inputLease) {};withExtendedLifetime(outputLease) {} }
            do {
                guard !GitRuntime.isAppStoreBuild || inputLease?.hasSecurityScope == true && inputLease?.contains(source) == true && outputLease?.hasSecurityScope == true && outputLease?.contains(request.destination) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let tool=try converter(),ssh=try keygen(),captured=request
                let value=try await Task.detached(priority:.userInitiated) { try SSHKeyConversion.convert(captured,converter:tool,keygen:ssh,cancellation:token) }.value
                guard !retired else { return };result=value;imported(value)
            } catch { if !retired { self.error=token.isCancelled ? "Key import cancelled. Original key retained." : error.localizedDescription } }
        }
    }
    func copyPublicKey() { guard !retired,let result else { return };NSPasteboard.general.clearContents();NSPasteboard.general.setString(result.publicText,forType:.string) }
    func reveal() { guard !retired,let result else { return };NSWorkspace.shared.activateFileViewerSelecting([result.privateKey,result.publicKey]) }
    func cancel() { token?.cancel() }
    func retire() {
        retired=true;token?.cancel();oldPassphrase="";newPassphrase="";confirmation=""
        if let panel { panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.orderOut(nil) };panel=nil
    }
}
@MainActor final class SSHKeyImportWindowController:NSWindowController,NSWindowDelegate {
    let model:SSHKeyImportModel
    var onClosed:()->Void={}
    init(model supplied:SSHKeyImportModel?=nil) {
        let model=supplied ?? SSHKeyImportModel();self.model=model
        let window=NSWindow(contentRect:.init(x:0,y:0,width:700,height:690),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Import SSH Key – TurtleGit for Mac";window.isReleasedWhenClosed=false
        window.contentMinSize = .init(width:670,height:650)
        window.contentViewController=NSHostingController(rootView:SSHKeyImportDialog(model:model))
        super.init(window:window);window.delegate=self;model.window=window;window.center()
        DialogGeometry.attach(window,identifier:"SSHKeyImport")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender:NSWindow)->Bool { !model.busy && sender.attachedSheet==nil }
    func windowWillClose(_ notification:Notification) { model.retire();if let window { window.sheetParent?.endSheet(window) };onClosed() }
}
private struct SSHKeyImportDialog:View {
    @ObservedObject var model:SSHKeyImportModel
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            ScrollView { VStack(alignment:.leading,spacing:14) {
            GroupBox("Existing key") {
                VStack(alignment:.leading,spacing:10) {
                    HStack { Text(model.source?.path ?? "Choose a PuTTY or OpenSSH private key…").lineLimit(2).textSelection(.enabled);Spacer();Button("Load…",action:model.chooseSource) }
                    SecureField("Current passphrase (if encrypted):",text:$model.oldPassphrase)
                    Text("The original key remains unchanged.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(model.busy)
            GroupBox("Key settings") {
                VStack(alignment:.leading,spacing:10) {
                    Toggle("Change passphrase",isOn:$model.changePassphrase)
                    if model.changePassphrase {
                        SecureField("New passphrase:",text:$model.newPassphrase)
                        SecureField("Confirm passphrase:",text:$model.confirmation)
                        Text("An empty new passphrase saves an unencrypted key.").font(.caption).foregroundStyle(.secondary)
                    } else { Text("Retain the existing key's encryption and passphrase.").font(.caption).foregroundStyle(.secondary) }
                    Toggle("Change key comment",isOn:$model.changeComment)
                    if model.changeComment { TextField("Key comment:",text:$model.comment) }
                }.padding(8)
            }.disabled(model.busy)
            GroupBox("Save OpenSSH key pair") {
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text(model.folder?.path ?? "Choose an output folder…").lineLimit(2).textSelection(.enabled);Spacer();Button("Browse…",action:model.chooseFolder) }
                    TextField("Private key filename:",text:$model.filename)
                    Text("Public key: "+model.filename+".pub").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(model.busy)
            if let result=model.result {
                GroupBox("Public key for pasting into your Git server") {
                    VStack(alignment:.leading,spacing:8) {
                        ScrollView { Text(result.publicText).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }.frame(minHeight:50,maxHeight:80)
                        Text(result.fingerprint).font(.caption).textSelection(.enabled)
                        HStack { Button("Copy public key",action:model.copyPublicKey);Button("Show in Finder",action:model.reveal) }
                    }.padding(8)
                }
            }
            if let error=model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.frame(maxWidth:.infinity,alignment:.leading) }
            HStack {
                if model.busy { ProgressView().controlSize(.small);Text("Importing key…") }
                Spacer();Button("Save key pair",action:model.convert).keyboardShortcut(.defaultAction).disabled(model.busy || !model.valid)
                Button(model.busy ? "Cancel import" : "Close") { if model.busy { model.cancel() } else { model.window?.performClose(nil) } }.keyboardShortcut(.cancelAction)
            }
        }.padding(20)
        .disabled(model.retired)
    }
}
