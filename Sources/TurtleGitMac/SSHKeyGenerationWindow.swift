// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SSHKeyGenerationModel: ObservableObject {
    static var activeOperations = 0
    @Published var childActive=false
    var active:Bool { !retired }
    var loadExisting:()->Void={}
    @Published var algorithm: SSHKeyAlgorithm = .ed25519
    @Published var bits = 3072
    @Published var filename = "id_ed25519"
    @Published var comment = ""
    @Published var passphrase = ""
    @Published var confirmation = ""
    @Published private(set) var folder: URL?
    @Published private(set) var busy = false
    @Published private(set) var result: SSHKeyGenerationResult?
    @Published var error: String?
    private var access: RepositoryAccessLease?
    private var panel: NSOpenPanel?
    private var token: OperationCancellation?
    private var retired = false
    weak var window: NSWindow?
    var valid: Bool {
        guard let folder, !filename.isEmpty, !filename.contains("/"), !filename.contains("\0"), ![".", ".."].contains(filename), passphrase == confirmation else { return false }
        var request = SSHKeyGenerationRequest(destination: folder.appendingPathComponent(filename)); request.algorithm = algorithm; request.bits = bits; request.comment = comment; request.passphrase = passphrase
        return request.valid
    }
    func hasDestinationAccess(_ file:URL)->Bool { access?.contains(file) == true }
    func chooseFolder() {
        guard !busy, !childActive, !retired, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = "Choose SSH key folder"; panel.prompt = "Choose folder"
        panel.directoryURL = folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        self.panel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.panel === panel else { return }; self.panel = nil
            guard !self.retired, response == .OK, let directory = panel.url else { return }
            let access = RepositoryAccessLease(url: directory)
            guard !GitRuntime.isAppStoreBuild || access.hasSecurityScope else { self.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
            self.access = access; self.folder = directory; self.result = nil; self.error = nil
        }
    }
    func generate() {
        guard valid, !busy, !childActive, !retired, let folder else { return }
        var request = SSHKeyGenerationRequest(destination: folder.appendingPathComponent(filename))
        request.algorithm = algorithm; request.bits = bits; request.comment = comment; request.passphrase = passphrase
        passphrase = ""; confirmation = ""; result = nil; error = nil; busy = true
        let token = OperationCancellation(); self.token = token; let access = access
        Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1; busy = false; self.token = nil }
            do {
                let executable = try SSHKeyGeneration.executable(), helper = try SSHAgentRuntime.resolve().askpass
                let captured = request
                let result = try await Task.detached(priority: .userInitiated) {
                    guard !GitRuntime.isAppStoreBuild || access?.hasSecurityScope == true && access?.contains(captured.destination) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    return try SSHKeyGeneration.generate(captured, executable: executable, askpass: helper, cancellation: token)
                }.value
                if !retired { self.result = result }
            } catch { if !retired { self.error = token.isCancelled ? "Key generation cancelled." : error.localizedDescription } }
        }
    }
    func acceptImported(_ result:SSHKeyGenerationResult,access:RepositoryAccessLease?) {
        guard !retired,!busy else { return }
        self.access=access
        self.result=result;error=nil;folder=result.privateKey.deletingLastPathComponent();filename=result.privateKey.lastPathComponent
        passphrase="";confirmation=""
    }
    func cancel() { token?.cancel() }
    func retire() {
        retired = true; token?.cancel(); passphrase = ""; confirmation = ""
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
    }
    func copyPublicKey() { guard !retired,!busy,!childActive,let result else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.publicText, forType: .string) }
    func reveal() { guard !retired,!busy,!childActive,let result else { return }; NSWorkspace.shared.activateFileViewerSelecting([result.privateKey, result.publicKey]) }
}
@MainActor final class SSHKeyGenerationWindowController: NSWindowController, NSWindowDelegate {
    let model = SSHKeyGenerationModel()
    private(set) var importController:SSHKeyImportWindowController?
    var onClosed: () -> Void = {}
    init() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 690, height: 590), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SSH Key Generator – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width: 660, height: 560)
        window.contentViewController = NSHostingController(rootView: SSHKeyGenerationDialog(model: model))
        super.init(window: window); window.delegate = self; model.window = window; window.center()
        model.loadExisting={ [weak self] in self?.loadExisting() }
        DialogGeometry.attach(window, identifier: "SSHKeyGenerator")
    }
    private func loadExisting() {
        guard model.active,!model.busy,importController == nil,let window,window.attachedSheet == nil else { return }
        let child=SSHKeyImportWindowController();importController=child;model.childActive=true
        child.model.imported={ [weak model,weak importedModel=child.model] result in model?.acceptImported(result,access:importedModel?.resultAccess) }
        child.onClosed={ [weak self,weak child] in
            guard let self,self.importController === child else { return }
            self.importController=nil;self.model.childActive=false
        }
        if let sheet=child.window { sheet.alphaValue=window.alphaValue;sheet.appearance=window.appearance;window.beginSheet(sheet) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && importController == nil && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.retire();importController?.close();importController=nil
        if let window, let parent = window.sheetParent { parent.endSheet(window) }; onClosed()
    }
}
private struct SSHKeyGenerationDialog: View {
    @ObservedObject var model: SSHKeyGenerationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Parameters") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Type of key:", selection: $model.algorithm) { ForEach(SSHKeyAlgorithm.allCases, id: \.self) { Text($0.rawValue == "ed25519" ? "Ed25519" : $0.rawValue.uppercased()).tag($0) } }
                    if model.algorithm != .ed25519 {
                        Picker("Number of bits:", selection: $model.bits) { ForEach(model.algorithm == .rsa ? [2048, 3072, 4096] : [256, 384, 521], id: \.self) { Text(String($0)).tag($0) } }
                    }
                    TextField("Key comment:", text: $model.comment)
                    SecureField("Key passphrase:", text: $model.passphrase)
                    SecureField("Confirm passphrase:", text: $model.confirmation)
                    Text("An empty passphrase creates an unencrypted private key.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(model.busy || model.childActive)
            GroupBox("Save key pair") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(model.folder?.path ?? "Choose a folder…").lineLimit(2).textSelection(.enabled); Spacer(); Button("Browse…", action: model.chooseFolder) }
                    TextField("Private key filename:", text: $model.filename)
                    Text("Public key: " + model.filename + ".pub").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(model.busy || model.childActive)
            if let result = model.result {
                GroupBox("Public key for pasting into your Git server") {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView { Text(result.publicText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 55, maxHeight: 90)
                        Text(result.fingerprint).font(.caption).textSelection(.enabled)
                        HStack { Button("Copy public key", action: model.copyPublicKey); Button("Show in Finder", action: model.reveal) }
                    }.padding(8)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text("Generating key…") }
                Button("Load existing key…",action:model.loadExisting).disabled(model.busy || model.childActive)
                Spacer()
                Button("Generate", action: model.generate).keyboardShortcut(.defaultAction).disabled(model.busy || model.childActive || !model.valid)
                Button(model.busy ? "Cancel generation" : "Close") { if model.busy { model.cancel() } else { model.window?.performClose(nil) } }.keyboardShortcut(.cancelAction)
            }
        }.padding(20)
        .onChange(of: model.algorithm) { algorithm in model.bits = algorithm == .ecdsa ? 256 : 3072; model.filename = "id_" + algorithm.rawValue }
    }
}
@MainActor final class SSHKeyGenerationService {
    static let shared = SSHKeyGenerationService()
    private var controller: SSHKeyGenerationWindowController?
    func show() {
        if let controller { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let controller = SSHKeyGenerationWindowController(); self.controller = controller
        controller.onClosed = { [weak self, weak controller] in if self?.controller === controller { self?.controller = nil } }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}
