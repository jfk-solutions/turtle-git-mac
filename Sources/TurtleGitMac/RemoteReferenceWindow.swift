// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor private final class RemoteReferenceNativeWindow: NSWindow {
    weak var model: RemoteReferenceWindowModel?
    private func refresh(_ event:NSEvent)->Bool {
        guard event.keyCode == 96,event.window === self,attachedSheet == nil,
              event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty else {return false}
        model?.refresh();return true
    }
    override func keyDown(with event:NSEvent) {if !refresh(event) {super.keyDown(with:event)}}
    override func performKeyEquivalent(with event:NSEvent)->Bool {refresh(event) || super.performKeyEquivalent(with:event)}
}
@MainActor final class RemoteReferenceWindowController: NSWindowController, NSWindowDelegate {
    let model: RemoteReferenceWindowModel
    private var completion: ((String?) -> Void)?
    private var accepted: String?
    private var closed = false
    private var errorOwner:RemoteDialogErrorOwner?
    private var observation:AnyCancellable?
    var makeSSH: SSHTransportFactory?
    init(repository: GitRepository, access: RepositoryAccessLease?, remote: String, preferences: UserDefaults = .standard, completion: @escaping (String?) -> Void) {
        model = RemoteReferenceWindowModel(repository: repository, access: access, remote: remote, preferences:preferences); self.completion = completion
        let window = RemoteReferenceNativeWindow(contentRect: .init(x: 0,y: 0,width: 640,height: 155), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "Select remote ref – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 480,height: 155); window.contentMaxSize = .init(width:CGFloat.greatestFiniteMagnitude,height:155)
        window.contentViewController = NSHostingController(rootView: RemoteReferenceDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.model = model
        errorOwner = RemoteDialogErrorOwner(window:window,title:"Could not retrieve remote refs.",value:{ [weak model] in
            guard let model,!model.retired,!model.busy,let text=model.error else {return nil};return (model.formContext,text)
        },acknowledge:{ [weak model] in model?.acknowledgeError(context:$0) })
        observation = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {self?.errorOwner?.update()} }
        model.close = { [weak self] in self?.dismiss(nil) }
        model.accept = { [weak self] value in self?.dismiss(value) }
        let model = self.model
        model.query = { [weak self,weak model] remote, token in
            guard let model else { throw OperationCancellationFailure.cancelled }
            let coordinator = self?.makeSSH?(); defer { coordinator?.close() }
            if let coordinator { coordinator.present = { [weak self] prompt in
                guard let owner = self?.window, owner.attachedSheet == nil, let child = prompt.window else { return false }
                child.alphaValue = owner.alphaValue; child.appearance = owner.appearance; owner.beginSheet(child); return true
            } }
            return try await repository.remoteReferenceChoices(remote: remote, cancellation: token, prepareTransport: coordinator?.preparation, backend: model.operationBackend)
        }
        DialogGeometry.attach(window, identifier: "SelectRemoteRefDlg"); window.center()
    }
    private func dismiss(_ value: String?) {
        guard !closed, !model.busy, model.error == nil, let window, window.attachedSheet == nil else { return }
        accepted = value
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: value == nil ? .cancel : .OK) }
        window.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.requestClose(); return false }; return sender.attachedSheet == nil && model.error == nil
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; model.retire(); errorOwner?.retire(); observation=nil
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        if let window, let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }
        let callback = completion; completion = nil; callback?(accepted)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RemoteReferenceWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let remote: String
    let preferences:UserDefaults
    private(set) var operationBackend:GitLibGit2Configuration
    var captureBackend:()->GitLibGit2Configuration
    @Published private(set) var formContext=UUID()
    private(set) var retired = false
    private var token: OperationCancellation?
    private var pendingClose = false
    private var accepted = false
    @Published private(set) var refs: [String] = []
    @Published var branch = ""
    @Published private(set) var busy = false
    @Published private(set) var cancelling = false
    @Published var error: String?
    var query: @MainActor (String,OperationCancellation) async throws -> [String]
    var close: () -> Void = {}
    var accept: (String) -> Void = { _ in }
    var canEdit:Bool {!retired && !busy && !pendingClose && !accepted && error == nil}
    func accepts(_ context:UUID)->Bool {context == formContext && canEdit}
    func setBranch(_ value:String,context:UUID) {guard accepts(context) else {return};branch=value}
    func acknowledgeError(context:UUID) {guard context == formContext,!retired,!busy else {return};error=nil;formContext=UUID()}
    var canAccept: Bool { canEdit && !refs.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?, remote: String, preferences:UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.remote = remote;self.preferences=preferences;operationBackend = .load(from:preferences);captureBackend={.load(from:preferences)}
        query = { _,_ in throw OperationCancellationFailure.cancelled }
        query = { [weak self] remote,token in
            guard let self else { throw OperationCancellationFailure.cancelled }
            return try await repository.remoteReferenceChoices(remote:remote,cancellation:token,backend:self.operationBackend)
        }
    }
    func refresh() {
        guard canEdit else { return }
        operationBackend = captureBackend()
        let token = OperationCancellation(); self.token = token; formContext=UUID(); busy = true; cancelling = false; refs = []; branch = ""; error = nil
        Self.activeOperations += 1
        let query = query, remote = remote, access = access, repository = repository
        Task { [self] in
            defer {
                Self.activeOperations -= 1; busy = false; self.token = nil; cancelling = false;formContext=UUID()
                if pendingClose && !retired { close() }; withExtendedLifetime(access) {}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try token.check(); guard !retired else { return }
                let values = try await query(remote,token)
                guard !retired, !token.isCancelled else { return }; refs = values; branch = values.first ?? ""
            } catch { if !retired, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func choose(context:UUID) {guard accepts(context) else {return};choose()}
    func choose() { guard canAccept else { return }; accepted = true;formContext=UUID(); accept(branch) }
    func requestClose(context:UUID) {guard context == formContext else {return};requestClose()}
    func requestClose() { guard !retired,error == nil else { return }; if busy { pendingClose = true;formContext=UUID(); cancelling = true; token?.cancel() } else { close() } }
    func retire() { guard !retired else { return }; retired = true;formContext=UUID(); token?.cancel() }
}
private struct RemoteReferenceDialog: View {
    @ObservedObject var model:RemoteReferenceWindowModel
    var body:some View {
        let context=model.formContext
        VStack(alignment:.leading,spacing:10) {
            HStack {Text("Remote:").frame(width:110,alignment:.leading);RemoteDialogTextField(value:.constant(model.remote),label:"Remote",readOnly:true,preferences:model.preferences,available:{!model.retired})}
            HStack {Text("Remote Branch:").frame(width:110,alignment:.leading);RemoteReferenceCombo(model:model,context:context).id(context)}
            HStack {if model.busy {ProgressView().controlSize(.small);Text(model.cancelling ? "Cancelling…" : "Loading…")};Spacer()}.frame(height:18)
            HStack {Spacer();Button("OK") {model.choose(context:context)}.keyboardShortcut(.defaultAction).disabled(!model.canAccept)
                Button("Cancel") {model.requestClose(context:context)}.keyboardShortcut(.cancelAction).disabled(model.cancelling || model.error != nil)}
        }.padding(14)
    }
}
private struct RemoteReferenceCombo:NSViewRepresentable {
    @ObservedObject var model:RemoteReferenceWindowModel
    let context:UUID
    func makeCoordinator()->Coordinator {Coordinator(model,context:context)}
    func makeNSView(context:Context)->NSComboBox {
        let field=NSComboBox();field.delegate=context.coordinator;field.setAccessibilityLabel("Remote Branch")
        field.completes=false;field.numberOfVisibleItems=15;field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        context.coordinator.field=field;return field
    }
    func updateNSView(_ field:NSComboBox,context:Context) {
        let coordinator=context.coordinator;coordinator.updating=true;defer {coordinator.updating=false}
        if coordinator.values.map({Data($0.utf8)}) != model.refs.map({Data($0.utf8)}) {field.removeAllItems();field.addItems(withObjectValues:model.refs);coordinator.values=model.refs}
        if Data(field.stringValue.utf8) != Data(model.branch.utf8) {field.stringValue=model.branch}
        field.isEnabled=model.accepts(self.context)
    }
    static func dismantleNSView(_ field:NSComboBox,coordinator:Coordinator) {coordinator.retired=true;field.delegate=nil;coordinator.field=nil}
    @MainActor final class Coordinator:NSObject,NSComboBoxDelegate {
        let model:RemoteReferenceWindowModel,context:UUID
        var updating=false,retired=false
        var values:[String]=[]
        weak var field:NSComboBox?
        private let words=GitInputWordCommands()
        init(_ model:RemoteReferenceWindowModel,context:UUID) {self.model=model;self.context=context}
        private func accepts(_ control:NSControl)->Bool {!updating && !retired && model.accepts(context) && field === control && control.window != nil && control.window?.attachedSheet == nil}
        func controlTextDidChange(_ notification:Notification) {guard let field=notification.object as? NSComboBox,accepts(field) else {return};model.setBranch(field.stringValue,context:context)}
        func comboBoxSelectionDidChange(_ notification:Notification) {guard let field=notification.object as? NSComboBox,accepts(field) else {return};model.setBranch(field.stringValue,context:context)}
        func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
            guard accepts(control) else {return false};words.policy=GitInputWordBreak(defaults:model.preferences)
            return words.handle(control,text:textView,selector:selector,combo:true,owner:self)
        }
    }
}
