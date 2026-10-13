// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

@MainActor final class SavedSSHAuthenticationModel: ObservableObject {
    static private(set) var activeOperations = 0
    let store: any SSHAuthenticationStore
    @Published private(set) var entries: [SSHAuthenticationEntry] = []
    @Published var selection = Set<String>()
    @Published private(set) var busy = false
    @Published var error: String?
    private var retired = false
    var confirm: ([SSHAuthenticationEntry]) async -> Bool = { _ in false }
    init(store: any SSHAuthenticationStore = SSHKeychainAuthenticationStore.shared) { self.store = store }
    func refresh() {
        guard !busy, !retired else { return }
        busy = true; error = nil; Self.activeOperations += 1
        Task {
            defer { busy = false; Self.activeOperations -= 1 }
            do {
                let rows = try await store.entries()
                guard !retired else { return }
                entries = rows; selection.formIntersection(Set(rows.map(\.id)))
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }
    func removeSelected() {
        guard !busy, !retired else { return }
        let rows = entries.filter { selection.contains($0.id) }
        guard !rows.isEmpty else { return }
        busy = true; error = nil; Self.activeOperations += 1
        Task {
            defer { busy = false; Self.activeOperations -= 1 }
            guard await confirm(rows), !retired else { return }
            do {
                for row in rows {
                    guard !retired else { return }
                    try await store.remove(identity: row.id)
                }
                let rows = try await store.entries()
                guard !retired else { return }
                entries = rows; selection.formIntersection(Set(rows.map(\.id)))
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }
    func retire() { retired = true; confirm = { _ in false } }
}

@MainActor final class SavedSSHAuthenticationWindowController: NSWindowController, NSWindowDelegate {
    let model: SavedSSHAuthenticationModel
    private var confirmation: NSAlert?
    var onClosed: () -> Void = {}
    init(store: any SSHAuthenticationStore = SSHKeychainAuthenticationStore.shared) {
        model = SavedSSHAuthenticationModel(store: store)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 540, height: 390), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "Saved SSH Authentication – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width: 440, height: 320)
        super.init(window: window); window.delegate = self
        window.contentViewController = NSHostingController(rootView: SavedSSHAuthenticationDialog(model: model, close: { [weak window] in window?.performClose(nil) }))
        model.confirm = { [weak self] rows in
            guard let self, let window = self.window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Remove saved SSH authentication?"
            alert.informativeText = "Remove \(rows.count) saved passphrase(s) from TurtleGit’s Keychain entries? Future key loading will ask again. A key already loaded in a running operation remains loaded."
            alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
            alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
            alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
            self.confirmation = alert
            let answer = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            self.confirmation = nil
            return answer == .alertFirstButtonReturn
        }
        window.center(); model.refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.retire()
        if let alert = confirmation, let window { window.endSheet(alert.window, returnCode: .abort); alert.window.orderOut(nil) }
        confirmation = nil; onClosed()
    }
}
private struct SavedSSHAuthenticationDialog: View {
    @ObservedObject var model: SavedSSHAuthenticationModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved authentication for SSH keys").font(.headline)
            Text("Passphrases saved after successful key loading are kept in this Mac’s Keychain. Key bytes and passphrases are not displayed here.").font(.caption).foregroundStyle(.secondary)
            List(model.entries, selection: $model.selection) { entry in Text(entry.name).tag(entry.id) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Refresh", action: model.refresh)
                Button("Remove…", action: model.removeSelected).disabled(model.selection.isEmpty)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction)
            }.disabled(model.busy)
        }.padding(16)
    }
}
@MainActor final class SavedSSHAuthenticationService {
    static let shared = SavedSSHAuthenticationService()
    private var controller: SavedSSHAuthenticationWindowController?
    func show() {
        if let controller { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let controller = SavedSSHAuthenticationWindowController(); self.controller = controller
        controller.onClosed = { [weak self, weak controller] in if self?.controller === controller { self?.controller = nil } }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}
