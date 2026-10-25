// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SavedSSHAuthenticationModel: ObservableObject {
    static private(set) var activeOperations = 0
    let store: any SSHAuthenticationStore
    @Published private(set) var entries: [SSHAuthenticationEntry] = []
    @Published var selection = Set<String>()
    @Published var section = SavedSSHAuthenticationSection.passphrases
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
    let permissions: SSHIdentityPermissionsModel
    private var panel: NSOpenPanel?
    private var panelRequest: UUID?
    private var retired = false
    private var confirmation: NSAlert?
    var onClosed: () -> Void = {}
    init(store: any SSHAuthenticationStore = SSHKeychainAuthenticationStore.shared, identities: SSHIdentityAccessStore = SSHIdentityAccessStore(), section: SavedSSHAuthenticationSection = .passphrases) {
        model = SavedSSHAuthenticationModel(store: store); model.section = section
        permissions = SSHIdentityPermissionsModel(store: identities)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "SSH Authentication and Permissions – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width: 700, height: 460)
        super.init(window: window); window.delegate = self
        window.contentViewController = NSHostingController(rootView: SavedSSHAuthenticationTabs(model: model, permissions: permissions, close: { [weak window] in window?.performClose(nil) }))
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
        permissions.chooseFile = { [weak self] in self?.authorizeFile() }
        permissions.confirm = { [weak self] rows in
            guard let self, !self.retired, let window = self.window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Forget SSH key file permissions?"
            alert.informativeText = "Forget \(rows.count) listed file permission(s)? Key files, saved passphrases and Git configuration stay in place. Running operations keep access until they finish. Future key loading may require Browse again."
            alert.addButton(withTitle: "Forget"); alert.addButton(withTitle: "Cancel")
            alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"; alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
            self.confirmation = alert
            let answer = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            self.confirmation = nil; return !self.retired && answer == .alertFirstButtonReturn
        }
        window.center(); if section == .passphrases { model.refresh() }; permissions.refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var presentFile: (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, window, completion in panel.beginSheetModal(for: window, completionHandler: completion) }
    var selectedFile: (NSOpenPanel) -> URL? = { $0.url }
    func authorizeFile() {
        guard !retired, !model.busy, permissions.available, let window, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = false; chooser.canChooseFiles = true
        chooser.allowsMultipleSelection = false; chooser.prompt = "Authorize"; chooser.title = "Authorize SSH Key File"
        chooser.message = "Choose the OpenSSH private key file TurtleGit may read."
        if let path = permissions.selected.first?.configuredPath { chooser.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        let request = UUID(); panelRequest = request; panel = chooser; permissions.panelOpen = true
        presentFile(chooser, window) { [weak self, weak chooser] response in
            guard let self, !self.retired, self.panelRequest == request, self.panel === chooser else { return }
            self.panelRequest = nil; self.panel = nil; self.permissions.panelOpen = false
            if response == .OK, let chooser, let file = self.selectedFile(chooser) { self.permissions.authorize(file) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !permissions.busy && !permissions.panelOpen && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        guard !retired else { return }; retired = true
        model.retire(); permissions.retire(); panelRequest = nil
        if let panel { panel.sheetParent?.endSheet(panel, returnCode: .abort); panel.cancel(nil); panel.orderOut(nil) }; panel = nil
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


enum SavedSSHAuthenticationSection: Hashable { case passphrases, keyFiles }

@MainActor final class SSHIdentityPermissionsModel: ObservableObject {
    private(set) static var activeOperations = 0
    let store: SSHIdentityAccessStore
    @Published private(set) var entries: [SSHIdentityGrant] = []
    @Published var selection = Set<GitReferenceName>()
    @Published private(set) var busy = false
    @Published var panelOpen = false
    @Published var error: String?
    private var retired = false
    var requireSecurityScope = GitRuntime.isAppStoreBuild
    var chooseFile: () -> Void = {}
    var confirm: ([SSHIdentityGrant]) async -> Bool = { _ in false }
    init(store: SSHIdentityAccessStore = SSHIdentityAccessStore()) { self.store = store }
    var available: Bool { !retired && !busy && !panelOpen }
    var selected: [SSHIdentityGrant] { entries.filter { selection.contains($0.id) } }
    func refresh() {
        guard available else { return }
        do { try reload(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func reload() throws {
        entries = try store.grants().sorted {
            let result = $0.configuredPath.localizedStandardCompare($1.configuredPath)
            return result == .orderedSame ? $0.configuredPath.utf8.lexicographicallyPrecedes($1.configuredPath.utf8) : result == .orderedAscending
        }
        selection.formIntersection(Set(entries.map(\.id)))
    }
    func authorize(_ file: URL) {
        guard available else { return }
        do {
            try store.remember(file, requireSecurityScope: requireSecurityScope); try reload()
            selection = [GitReferenceName(file.path)]; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func forget(all: Bool = false) {
        guard available else { return }
        let reviewed = all ? entries : selected
        guard !reviewed.isEmpty else { return }; busy = true; error = nil; Self.activeOperations += 1
        Task {
            defer { busy = false; Self.activeOperations -= 1 }
            guard await confirm(reviewed), !retired else { return }
            do { try store.forget(reviewed); try reload() }
            catch { self.error = error.localizedDescription; try? reload() }
        }
    }
    func copyPaths(to pasteboard: NSPasteboard = .general) {
        guard available, !selected.isEmpty else { return }
        pasteboard.clearContents(); pasteboard.setString(selected.map(\.configuredPath).joined(separator: "\n"), forType: .string)
    }
    func retire() { retired = true; panelOpen = false; chooseFile = {}; confirm = { _ in false } }
}

private struct SavedSSHAuthenticationTabs: View {
    @ObservedObject var model: SavedSSHAuthenticationModel
    @ObservedObject var permissions: SSHIdentityPermissionsModel
    let close: () -> Void
    var body: some View {
        TabView(selection: $model.section) {
            SavedSSHAuthenticationDialog(model: model, close: close).tabItem { Text("Saved Passphrases") }.tag(SavedSSHAuthenticationSection.passphrases)
            SSHIdentityPermissionsPage(model: permissions, close: close).tabItem { Text("Key File Permissions") }.tag(SavedSSHAuthenticationSection.keyFiles)
        }.padding(8).disabled(model.busy || permissions.busy || permissions.panelOpen)
            .onChange(of: model.section) { section in if section == .passphrases { model.refresh() } else { permissions.refresh() } }
    }
}

struct SSHIdentityPermissionsPage: View {
    @ObservedObject var model: SSHIdentityPermissionsModel
    let close: () -> Void
    private func commands() -> some View {
        Group {
            Button { model.copyPaths() } label: { CommandLabel(title: "Copy Path", icon: .copy) }.disabled(model.selected.isEmpty)
            Button { model.forget() } label: { CommandLabel(title: "Forget Selected…", icon: .remove) }.disabled(model.selected.isEmpty)
            Button { model.chooseFile() } label: { CommandLabel(title: "Authorize File…", icon: .add) }
        }.disabled(!model.available)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH key file permissions").font(.headline)
            Text("Files selected with Browse can be read when loading an SSH key. This list shows remembered paths without reading private keys or resolving their bookmarks.").font(.caption).foregroundStyle(.secondary)
            Table(model.entries, selection: $model.selection) {
                TableColumn("Key File") { row in
                    HStack { if let image = MenuIcon.lock.image() { Image(nsImage: image) }; Text(URL(fileURLWithPath: row.configuredPath).lastPathComponent) }.help(row.configuredPath)
                }.width(min: 120, ideal: 180)
                TableColumn("Configured Path") { row in Text(row.configuredPath).help(row.configuredPath) }
            }.contextMenu { TurtleGitContextMenu { commands() } }.onDeleteCommand { model.forget() }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Forgetting a permission keeps the key file, Git settings, saved passphrases and already running operations.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.refresh() } label: { CommandLabel(title: "Refresh", icon: .refresh) }
                Button { model.chooseFile() } label: { CommandLabel(title: "Authorize File…", icon: .add) }
                Button { model.forget() } label: { CommandLabel(title: "Forget Selected…", icon: .remove) }.disabled(model.selected.isEmpty)
                Button("Forget All…") { model.forget(all: true) }.disabled(model.entries.isEmpty)
                Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction)
            }.disabled(!model.available)
        }.padding(16)
    }
}
