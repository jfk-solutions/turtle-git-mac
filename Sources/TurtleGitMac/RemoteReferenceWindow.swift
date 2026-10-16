// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor private final class RemoteReferenceNativeWindow: NSWindow {
    weak var model: RemoteReferenceWindowModel?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 96 { model?.refresh(); return }; super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96 { model?.refresh(); return true }; return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class RemoteReferenceWindowController: NSWindowController, NSWindowDelegate {
    let model: RemoteReferenceWindowModel
    private var completion: ((String?) -> Void)?
    private var accepted: String?
    private var closed = false
    var makeSSH: SSHTransportFactory?
    init(repository: GitRepository, access: RepositoryAccessLease?, remote: String, preferences: UserDefaults = .standard, completion: @escaping (String?) -> Void) {
        model = RemoteReferenceWindowModel(repository: repository, access: access, remote: remote); self.completion = completion
        let window = RemoteReferenceNativeWindow(contentRect: .init(x: 0,y: 0,width: 640,height: 155), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "Select remote ref – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 480,height: 155)
        window.contentViewController = NSHostingController(rootView: RemoteReferenceDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.model = model
        model.close = { [weak self] in self?.dismiss(nil) }
        model.accept = { [weak self] value in self?.dismiss(value) }
        model.query = { [weak self] remote, token in
            let coordinator = self?.makeSSH?(); defer { coordinator?.close() }
            if let coordinator { coordinator.present = { [weak self] prompt in
                guard let owner = self?.window, owner.attachedSheet == nil, let child = prompt.window else { return false }
                child.alphaValue = owner.alphaValue; child.appearance = owner.appearance; owner.beginSheet(child); return true
            } }
            return try await repository.remoteReferenceChoices(remote: remote, cancellation: token, prepareTransport: coordinator?.preparation)
        }
        DialogGeometry.attach(window, identifier: "SelectRemoteRefDlg"); window.center()
    }
    private func dismiss(_ value: String?) {
        guard !closed, !model.busy, let window, window.attachedSheet == nil else { return }
        accepted = value
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: value == nil ? .cancel : .OK) }
        window.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.requestClose(); return false }; return sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; model.retire()
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
    var canAccept: Bool { !retired && !busy && !pendingClose && !accepted && !refs.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?, remote: String) {
        self.repository = repository; self.access = access; self.remote = remote
        query = { try await repository.remoteReferenceChoices(remote: $0,cancellation: $1) }
    }
    func refresh() {
        guard !retired, !busy, !pendingClose, !accepted else { return }
        let token = OperationCancellation(); self.token = token; busy = true; cancelling = false; refs = []; branch = ""; error = nil
        Self.activeOperations += 1
        let query = query, remote = remote, access = access, repository = repository
        Task { [self] in
            defer {
                Self.activeOperations -= 1; busy = false; self.token = nil; cancelling = false
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
    func choose() { guard canAccept else { return }; accepted = true; accept(branch) }
    func requestClose() { guard !retired else { return }; if busy { pendingClose = true; cancelling = true; token?.cancel() } else { close() } }
    func retire() { guard !retired else { return }; retired = true; token?.cancel() }
}
private struct RemoteReferenceDialog: View {
    @ObservedObject var model: RemoteReferenceWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Remote:").frame(width: 110,alignment: .leading); Text(model.remote).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading) }
            HStack { Text("Remote Branch:").frame(width: 110,alignment: .leading); RemoteReferenceCombo(model: model) }.disabled(model.busy)
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.cancelling ? "Cancelling…" : "Loading…") } }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("OK") { model.choose() }.keyboardShortcut(.defaultAction).disabled(!model.canAccept)
                Button("Cancel") { model.requestClose() }.keyboardShortcut(.cancelAction).disabled(model.cancelling) }
        }.padding(14)
    }
}
private struct RemoteReferenceCombo: NSViewRepresentable {
    @ObservedObject var model: RemoteReferenceWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSComboBox { let view = NSComboBox(); view.delegate = context.coordinator; view.setAccessibilityLabel("Remote Branch"); return view }
    func updateNSView(_ view: NSComboBox, context: Context) {
        context.coordinator.updating = true; defer { context.coordinator.updating = false }
        if context.coordinator.values.count != model.refs.count || !zip(context.coordinator.values,model.refs).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) {
            view.removeAllItems(); view.addItems(withObjectValues: model.refs); context.coordinator.values = model.refs
        }
        view.stringValue = model.branch; view.isEnabled = !model.busy && !model.retired
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        let model: RemoteReferenceWindowModel; var updating = false; var values: [String] = []
        init(_ model: RemoteReferenceWindowModel) { self.model = model }
        func controlTextDidChange(_ notification: Notification) { guard !updating,!model.busy,!model.retired,let view = notification.object as? NSComboBox else { return }; model.branch = view.stringValue }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating,!model.busy,!model.retired,let view = notification.object as? NSComboBox else { return }; model.branch = view.stringValue }
    }
}
