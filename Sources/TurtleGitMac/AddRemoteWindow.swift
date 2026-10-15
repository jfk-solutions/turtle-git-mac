// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class AddRemoteWindowController: NSWindowController, NSWindowDelegate {
    let model: AddRemoteWindowModel
    var onClosed: () -> Void = {}
    private var closed = false
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = AddRemoteWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 570,height: 180),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.title = "Add Remote – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AddRemoteDialog(model: model))
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in
            guard let self, !self.closed, !self.model.busy, let window = self.window else { return }
            if let parent = window.sheetParent { parent.endSheet(window) }; window.close()
        }
        window.center()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.requestClose(); return false }; return true }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; model.retire()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class AddRemoteWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    private(set) var retired = false
    @Published var name = ""
    @Published var url = ""
    @Published private(set) var busy = false
    @Published var error: String?
    private var token: OperationCancellation?
    private var pendingClose = false
    var close: () -> Void = {}
    var canSave: Bool { !retired && !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !url.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    func save() {
        guard canSave else { return }
        var settings = RemoteSettings(name: name); settings.url = url
        let token = OperationCancellation(); self.token = token; busy = true; error = nil; Self.activeOperations += 1
        let repository = repository, access = access
        Task { [self] in
            var success = false
            defer { Self.activeOperations -= 1; busy = false; self.token = nil; if !retired && (success || pendingClose) { close() }; withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await repository.applyRemoteSettings(settings,changed: [.name,.url],cancellation: token)
                success = !token.isCancelled
            } catch { if !retired,!token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func requestClose() { guard !retired else { return }; if busy { pendingClose = true; token?.cancel() } else { close() } }
    func retire() { guard !retired else { return }; retired = true; token?.cancel() }
}
private struct AddRemoteDialog: View {
    @ObservedObject var model: AddRemoteWindowModel
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            HStack { Text("Name:").frame(width: 65,alignment: .leading); TextField("",text: $model.name).accessibilityLabel("Remote name") }
            HStack { Text("URL:").frame(width: 65,alignment: .leading); TextField("",text: $model.url).accessibilityLabel("Remote URL") }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).lineLimit(3).help(error) }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer()
                Button("OK") { model.save() }.keyboardShortcut(.defaultAction).disabled(!model.canSave)
                Button("Cancel") { model.requestClose() }.keyboardShortcut(.cancelAction)
                Button("Help") { TurtleGitHelp.show(.settings) }
            }
        }.textFieldStyle(.roundedBorder).padding(14)
    }
}
