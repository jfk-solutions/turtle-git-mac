// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class AddRemoteWindowController: NSWindowController, NSWindowDelegate {
    let model: AddRemoteWindowModel
    var onClosed: () -> Void = {}
    private var closed = false
    private var errorOwner: RemoteDialogErrorOwner?
    private var observation: AnyCancellable?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = AddRemoteWindowModel(repository: repository, access: access, preferences:preferences)
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 570,height: 180),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.title = "Add Remote – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width:570,height:180);window.contentMaxSize = .init(width:570,height:180)
        window.contentViewController = NSHostingController(rootView: AddRemoteDialog(model: model))
        super.init(window: window); window.delegate = self
        errorOwner = RemoteDialogErrorOwner(window:window, title:"Could not add remote.", value:{ [weak model] in
            guard let model, !model.retired, !model.busy, let text = model.error else { return nil }; return (model.formContext,text)
        }, acknowledge:{ [weak model] in model?.acknowledgeError(context:$0) })
        observation = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.errorOwner?.update() } }
        model.close = { [weak self] in
            guard let self, !self.closed, !self.model.busy, self.model.error == nil, let window = self.window else { return }
            if let parent = window.sheetParent { parent.endSheet(window) }; window.close()
        }
        window.center()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.requestClose(); return false }; return sender.attachedSheet == nil && model.error == nil }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; model.retire(); errorOwner?.retire(); observation = nil
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class AddRemoteWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    @Published private(set) var formContext = UUID()
    private(set) var retired = false
    @Published var name = ""
    @Published var url = ""
    @Published private(set) var busy = false
    @Published private(set) var cancelling = false
    @Published var error: String?
    private var token: OperationCancellation?
    private var pendingClose = false
    var close: () -> Void = {}
    var persist: (RemoteSettings, OperationCancellation) async throws -> Void
    var canEdit: Bool { !retired && !busy && !pendingClose && error == nil }
    func accepts(_ context:UUID) -> Bool { context == formContext && canEdit }
    func field(_ key:ReferenceWritableKeyPath<AddRemoteWindowModel,String>,context:UUID) -> Binding<String> {
        Binding(get:{self[keyPath:key]},set:{ if self.accepts(context) {self[keyPath:key]=$0} })
    }
    func acknowledgeError(context:UUID) { guard context == formContext, !retired, !busy else {return}; error=nil; formContext=UUID() }
    var canSave: Bool { canEdit && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !url.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences
        persist = { try await repository.applyRemoteSettings($0, changed: [.name, .url], cancellation: $1) }
    }
    func save(context:UUID) {guard accepts(context) else {return};save()}
    func save() {
        guard canSave else { return }
        var settings = RemoteSettings(name: name); settings.url = url
        let token = OperationCancellation(); self.token = token; formContext = UUID(); busy = true; error = nil; Self.activeOperations += 1
        let repository = repository, access = access, persist = persist
        Task { [self] in
            var success = false
            defer { Self.activeOperations -= 1; busy = false; cancelling = false; self.token = nil; formContext = UUID(); if !retired && (success || pendingClose) { close() }; withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try token.check(); guard !retired else { return }
                try await persist(settings, token)
                success = !token.isCancelled
            } catch { if !retired,!token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func requestClose(context:UUID) {guard context == formContext else {return};requestClose()}
    func requestClose() { guard !retired, error == nil else { return }; if busy { pendingClose = true; formContext=UUID(); cancelling = true; token?.cancel() } else { close() } }
    func retire() { guard !retired else { return }; retired = true; formContext=UUID(); token?.cancel() }
}
private struct AddRemoteDialog: View {
    @ObservedObject var model: AddRemoteWindowModel
    var body: some View {
        let context = model.formContext
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("Name:").frame(width:65,alignment:.trailing); RemoteDialogTextField(value:model.field(\.name,context:context),label:"Remote name",preferences:model.preferences,available:{model.accepts(context)}) }.id("name-"+context.uuidString)
            HStack { Text("URL:").frame(width:65,alignment:.trailing); RemoteDialogTextField(value:model.field(\.url,context:context),label:"Remote URL",preferences:model.preferences,available:{model.accepts(context)}) }.id("url-"+context.uuidString)
            HStack { if model.busy { ProgressView().controlSize(.small); Text(model.cancelling ? "Cancelling…" : "Saving…") }; Spacer() }.frame(height:18)
            HStack { Spacer()
                Button("OK") {model.save(context:context)}.keyboardShortcut(.defaultAction).disabled(!model.canSave)
                Button("Cancel") {model.requestClose(context:context)}.keyboardShortcut(.cancelAction).disabled(model.cancelling || model.error != nil)
                Button("Help") {if model.accepts(context) {TurtleGitHelp.show(.settings)}}.disabled(!model.canEdit)
            }
        }.frame(minWidth:542,minHeight:152).padding(14)
    }
}

/// Native source edit fields preserve selection and use the shared Git URL/path
/// word commands. Dismantled or replaced controls cannot publish old text.
struct RemoteDialogTextField: NSViewRepresentable {
    @Binding var value:String
    let label:String
    var readOnly=false
    let preferences:UserDefaults
    let available:()->Bool
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSTextField {
        let field=NSTextField();field.delegate=context.coordinator;field.setAccessibilityLabel(label)
        field.setContentHuggingPriority(.defaultLow,for:.horizontal);context.coordinator.field=field;return field
    }
    func updateNSView(_ field:NSTextField,context:Context) {
        context.coordinator.owner=self
        if Data(field.stringValue.utf8) != Data(value.utf8) {field.stringValue=value}
        field.isEditable = !readOnly && available();field.isSelectable=true;field.isEnabled=readOnly || available()
        field.toolTip=value
    }
    static func dismantleNSView(_ field:NSTextField,coordinator:Coordinator) {coordinator.retired=true;field.delegate=nil;coordinator.field=nil}
    @MainActor final class Coordinator:NSObject,NSTextFieldDelegate {
        var owner:RemoteDialogTextField
        weak var field:NSTextField?
        var retired=false
        private let words=GitInputWordCommands()
        init(_ owner:RemoteDialogTextField) {self.owner=owner}
        private func accepts(_ control:NSControl)->Bool {!retired && !owner.readOnly && owner.available() && field === control && control.window != nil && control.window?.attachedSheet == nil}
        func controlTextDidChange(_ notification:Notification) {guard let field=notification.object as? NSTextField,accepts(field) else {return};owner.value=field.stringValue}
        func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
            guard accepts(control) else {return false};words.policy=GitInputWordBreak(defaults:owner.preferences)
            return words.handle(control,text:textView,selector:selector,combo:false,owner:self)
        }
    }
}

/// An owned source error box does not grow the compact form or acknowledge a
/// newer error when an old modal reply arrives.
@MainActor final class RemoteDialogErrorOwner {
    private weak var window:NSWindow?
    private let title:String
    private let value:()->(UUID,String)?
    private let acknowledge:(UUID)->Void
    private var alert:NSAlert?
    private var request:UUID?
    private var retired=false
    private var sheetObserver:NSObjectProtocol?
    init(window:NSWindow,title:String,value:@escaping ()->(UUID,String)?,acknowledge:@escaping (UUID)->Void) {
        self.window=window;self.title=title;self.value=value;self.acknowledge=acknowledge
        sheetObserver=NotificationCenter.default.addObserver(forName:NSWindow.didEndSheetNotification,object:window,queue:.main) { [weak self] _ in DispatchQueue.main.async {self?.update()} }
    }
    func update() {
        guard !retired,alert == nil,let window,window.attachedSheet == nil,let (context,text)=value() else {return}
        let id=UUID(),box=NSAlert();box.alertStyle = .critical;box.messageText=title;box.informativeText=text;box.addButton(withTitle:"OK")
        request=id;alert=box;box.window.alphaValue=window.alphaValue;box.window.appearance=window.appearance
        box.beginSheetModal(for:window) { [weak self] _ in
            guard let self,!self.retired,self.request == id else {return};self.request=nil;self.alert=nil
            if let current=self.value(),current.0 == context,Data(current.1.utf8)==Data(text.utf8) {self.acknowledge(context)}
            self.update()
        }
    }
    func retire() {
        guard !retired else {return};retired=true;request=nil
        if let observer=sheetObserver {NotificationCenter.default.removeObserver(observer)};sheetObserver=nil
        if let alert {window?.endSheet(alert.window,returnCode:.abort);alert.window.orderOut(nil)};alert=nil
    }
    deinit {if let observer=sheetObserver {NotificationCenter.default.removeObserver(observer)}}
}
