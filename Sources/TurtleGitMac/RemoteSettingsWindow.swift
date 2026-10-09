// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RemoteSettingsWindowModel: ObservableObject {
    enum Prompt {
        case saveDiscard, overwrite(String), noTags, fetch, remove(String)
        var message: String {
            switch self {
            case .saveDiscard: return "The Remote Config was changed.\nDo you want to save now or discard changes?"
            case .overwrite(let name): return "The remote \"\(name)\" already exists.\nDo you want to overwrite it?"
            case .noTags: return "To avoid fetching wrong tags, if this is not an official remote,\nyou are advised to disable tag fetching for this remote.\nDisable tag fetching?"
            case .fetch: return "Do you want to fetch remote branches from the newly added remote?"
            case .remove(let name): return "Do you really want to remove \"\(name)\"?"
            }
        }
    }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    let noFetch: Bool
    let identityAccess: SSHIdentityAccessStore
    @Published private(set) var names: [GitReferenceName] = []
    @Published private(set) var selected: GitReferenceName?
    @Published private(set) var draft = RemoteSettings()
    @Published private(set) var changed: RemoteSettingsFields = []
    @Published private(set) var hasChild = false
    @Published private(set) var busy = false
    @Published private(set) var closed = false
    @Published var error: String?
    @Published private(set) var collision = false
    var updated: () -> Void = {}
    var close: () -> Void = {}
    var onFetch: (String) -> Void = { _ in }
    var onRemotesChanged: ([String]) -> Void = { _ in }
    var onReferencesChanged: (([CheckoutReference]) -> Void)?
    var confirm: (Prompt) async -> (yes: Bool, suppress: Bool) = { _ in (false, false) }
    private var token: OperationCancellation?
    private var collisionToken: OperationCancellation?
    private var pendingClose = false
    private var pendingFetch: String?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, noFetch: Bool = false, identityAccess: SSHIdentityAccessStore = SSHIdentityAccessStore()) {
        self.repository = repository; self.access = access; self.preferences = preferences; self.noFetch = noFetch; self.identityAccess = identityAccess
    }
    func selectIdentity(_ url: URL) {
        guard !closed, !busy, !hasChild else { return }
        do { try identityAccess.remember(url, requireSecurityScope: GitRuntime.isAppStoreBuild); error = nil; edit(.sshKeyFile) { $0.sshKeyFile = url.path } }
        catch { self.error = error.localizedDescription; updated() }
    }
    var canSave: Bool { !closed && !busy && !hasChild && !draft.name.isEmpty && !draft.url.isEmpty }
    var canRename: Bool { !closed && !busy && !hasChild && selected != nil }
    var canApply: Bool { !closed && !busy && !hasChild && !changed.isEmpty }
    private func live(_ request: OperationCancellation) -> Bool { !closed && token === request && !request.isCancelled }
    private func checkAccess() throws { if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable } }
    func setChild(_ value: Bool) { hasChild = value; updated() }
    func invalidate() { hasChild = false; closed = true; token?.cancel(); collisionToken?.cancel(); token = nil; collisionToken = nil; pendingFetch = nil; busy = false; updated() }
    func edit(_ field: RemoteSettingsFields, _ change: (inout RemoteSettings) -> Void) {
        guard !closed, !busy, !hasChild else { return }; change(&draft); changed.formUnion(field)
        if field == .url, names.isEmpty, draft.name.isEmpty, !draft.url.isEmpty { draft.name = "origin"; changed.insert(.name) }
        if field == .name || field == .url { checkCollision() }; updated()
    }
    private func checkCollision() {
        collisionToken?.cancel(); let request = OperationCancellation(); collisionToken = request; let name = draft.name
        Task {
            defer { if collisionToken === request { collisionToken = nil } }
            do { try checkAccess(); let value = try await repository.remoteNameCollidesWithRefspec(name, cancellation: request); guard !closed, collisionToken === request, !request.isCancelled else { return }; collision = value; updated() }
            catch { if !closed, collisionToken === request, !request.isCancelled { self.error = error.localizedDescription; updated() } }
        }
    }
    private func perform(_ body: @escaping (OperationCancellation) async throws -> Void) {
        guard !closed, !busy, !hasChild else { return }; collisionToken?.cancel(); collisionToken = nil
        let request = OperationCancellation(); token = request; busy = true; error = nil; updated()
        Task {
            defer {
                if token === request { token = nil; busy = false; updated(); if pendingClose, !closed { pendingClose = false; close() }; if let remote = pendingFetch, !closed { pendingFetch = nil; onFetch(remote) } }
            }
            do { try checkAccess(); try await body(request) }
            catch { if live(request) { self.error = error.localizedDescription; updated() } }
        }
    }
    private func reloadNames(_ request: OperationCancellation) async throws {
        let values = try await repository.remoteNames(cancellation: request); guard live(request) else { return }
        names = values.map { GitReferenceName($0) }; onRemotesChanged(values)
        if let onReferencesChanged { let references = try await repository.checkoutReferences(cancellation: request); guard live(request) else { return }; onReferencesChanged(references) }
    }
    func load() { perform { [self] request in try await reloadNames(request) } }
    private func read(_ name: GitReferenceName?, _ request: OperationCancellation) async throws {
        let value: RemoteSettings
        if let name { value = try await repository.remoteSettings(name: name.rawValue, cancellation: request) } else { value = RemoteSettings() }
        guard live(request) else { return }; selected = name; draft = value; changed = []; collision = false; updated()
    }
    func select(_ name: GitReferenceName?) {
        guard !closed, !busy, !hasChild, name != selected else { return }
        perform { [self] request in
            if !changed.isEmpty { let choice = await confirm(.saveDiscard); guard live(request) else { return }; if choice.yes { do { try await apply(request) } catch { guard live(request) else { return }; self.error = error.localizedDescription } } }
            guard live(request) else { return }; try await read(name, request)
        }
    }
    func apply(closeAfter: Bool = false) {
        guard canApply else { if closeAfter, !closed, !busy, !hasChild { close() }; return }
        perform { [self] request in try await apply(request); if closeAfter, live(request) { pendingClose = true } }
    }
    func save() {
        guard canSave else { return }
        perform { [self] request in
            changed = .all
            if names.contains(GitReferenceName(draft.name)) {
                let answer = await confirm(.overwrite(draft.name)); guard live(request), answer.yes else { return }; changed.remove(.name)
            }
            try await apply(request)
        }
    }
    private func apply(_ request: OperationCancellation) async throws {
        if changed.contains(.pushDefault) { try await repository.applyRemoteSettings(draft, changed: [.pushDefault], cancellation: request); guard live(request) else { return }; changed.remove(.pushDefault) }
        // CString::Trim mutates the source name during OnApply.
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !changed.isEmpty, draft.name.isEmpty { throw RemoteSettingsFailure.name }
        if changed.contains(.name) {
            guard !draft.url.isEmpty else { throw RemoteSettingsFailure.url }
            if !names.isEmpty, draft.tags != .none {
                let key = "TagOptNoTagsWarning"
                let answer: (yes: Bool, suppress: Bool)
                if preferences.object(forKey: key) != nil { answer = (preferences.bool(forKey: key), false) }
                else { answer = await confirm(.noTags) }
                guard live(request) else { return }
                if answer.suppress { preferences.set(answer.yes, forKey: key) }
                if answer.yes { draft.tags = .none; changed.insert(.tags) }
            }
            try await repository.applyRemoteSettings(draft, changed: [.name], cancellation: request); guard live(request) else { return }
            changed.remove(.url); selected = GitReferenceName(draft.name); try await reloadNames(request)
            if !noFetch { let answer = await confirm(.fetch); guard live(request) else { return }; if answer.yes { pendingFetch = draft.name } }
        }
        let fields = changed.subtracting([.name, .pushDefault])
        try await repository.applyRemoteSettings(draft, changed: fields, cancellation: request); guard live(request) else { return }
        changed = []; try await reloadNames(request); try await read(GitReferenceName(draft.name), request)
    }
    func rename() {
        guard canRename, let old = selected else { return }; let name = draft.name
        perform { [self] request in
            try await repository.renameRemote(from: old.rawValue, to: name, cancellation: request); guard live(request) else { return }
            selected = GitReferenceName(name); changed.remove(.name); try await reloadNames(request)
        }
    }
    func remove() {
        guard canRename, let captured = selected else { return }
        perform { [self] request in
            let answer = await confirm(.remove(captured.rawValue)); guard live(request), answer.yes else { return }
            try await repository.removeRemote(name: captured.rawValue, cancellation: request); guard live(request) else { return }
            try await reloadNames(request); try await read(nil, request)
        }
    }
}

@MainActor final class RemoteSettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: RemoteSettingsWindowModel
    var onClosed: () -> Void = {}
    private(set) var fetchDialog: FetchWindowController?
    var configureFetch: (FetchWindowController) -> Void = { _ in }
    var presentFetch: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, noFetch: Bool = false) {
        model = RemoteSettingsWindowModel(repository: repository, access: access, preferences: preferences, noFetch: noFetch)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 730, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Remote – TurtleGit"; window.contentMinSize = .init(width: 680, height: 420); window.isReleasedWhenClosed = false
        window.contentView = RemoteSettingsNativeView(model: model)
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.hasChild, self.window?.attachedSheet == nil else { return }; self.close() }
        model.onFetch = { [weak self] remote in self?.showFetch(remote) }
        DialogGeometry.attach(window, identifier: "SettingGitRemote")
    }
    private func showFetch(_ remote: String) {
        guard !model.closed, let owner = window, owner.attachedSheet == nil, fetchDialog == nil else { return }
        let child = FetchWindowController(repository: model.repository, access: model.access, preferences: model.preferences); fetchDialog = child; model.setChild(true); configureFetch(child)
        child.onClosed = { [weak self, weak child] in guard let self, let child, self.fetchDialog === child else { return }; if let window = child.window { window.sheetParent?.endSheet(window) }; self.fetchDialog = nil; self.model.setChild(false) }
        guard let window = child.window, presentFetch(owner, window) else { child.close(); return }; child.model.load(remote: remote)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && !model.hasChild && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); fetchDialog?.close(); fetchDialog = nil; if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort); sheet.close() }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class RemoteSettingsNativeView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let model: RemoteSettingsWindowModel
    let table = NSTableView()
    let remote = NSTextField(), url = NSTextField(), pushURL = NSTextField(), key = NSTextField(), sshKey = NSTextField()
    let browse = NSButton(title: "…", target: nil, action: nil), browseSSH = NSButton(title: "…", target: nil, action: nil)
    let tags = NSPopUpButton(frame: .zero, pullsDown: false)
    let prune = NSButton(checkboxWithTitle: "Prune", target: nil, action: nil), pushDefault = NSButton(checkboxWithTitle: "Push Default", target: nil, action: nil)
    let warning = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let rename = NSButton(title: "Rename", target: nil, action: nil), add = NSButton(title: "Add New/Save", target: nil, action: nil), remove = NSButton(title: "Remove", target: nil, action: nil)
    let apply = NSButton(title: "Apply", target: nil, action: nil), ok = NSButton(title: "OK", target: nil, action: nil), cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var updating = false
    init(model: RemoteSettingsWindowModel) {
        self.model = model; super.init(frame: .zero)
        table.headerView = nil; table.delegate = self; table.dataSource = self; table.rowHeight = 22; table.addTableColumn(NSTableColumn(identifier: .init("remote"))); table.setAccessibilityLabel("Configured remotes")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let list = NSStackView(views: [NSTextField(labelWithString: "Remote:"), scroll]); list.orientation = .vertical; list.alignment = .leading
        list.widthAnchor.constraint(equalToConstant: 180).isActive = true; scroll.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        for (field, label) in [(remote,"Remote"),(url,"URL"),(pushURL,"Push URL"),(key,"PuTTY Key (Windows)"),(sshKey,"SSH Key (macOS)")] { field.delegate = self; field.setAccessibilityLabel(label); field.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        key.toolTip = "Preserves remote.<name>.puttykeyfile for Windows interoperability. PuTTY keys cannot be loaded by OpenSSH."
        sshKey.toolTip = "OpenSSH key for macOS. Use Browse to grant access. Automatic loading for Fetch/Push is not connected yet."
        tags.addItems(withTitles: ["Reachable", "None", "All"]); tags.target = self; tags.action = #selector(tagChanged); tags.toolTip = "remote.<name>.tagopt"
        prune.allowsMixedState = true; prune.toolTip = "remote.<name>.prune: mixed inherits the configured global policy."; pushDefault.toolTip = "remote.pushdefault"
        for (button, action) in [(prune,#selector(pruneChanged)),(pushDefault,#selector(defaultChanged)),(rename,#selector(renameClicked)),(add,#selector(saveClicked)),(remove,#selector(removeClicked)),(apply,#selector(applyClicked)),(ok,#selector(okClicked)),(cancel,#selector(cancelClicked))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        ok.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
        browse.target = self; browse.action = #selector(browseKey); browse.bezelStyle = .rounded; browse.setAccessibilityLabel("Browse PuTTY key file")
        browseSSH.target = self; browseSSH.action = #selector(browseSSHKey); browseSSH.bezelStyle = .rounded; browseSSH.setAccessibilityLabel("Browse OpenSSH private key file")
        func row(_ label: String, _ views: [NSView]) -> NSStackView { let title = NSTextField(labelWithString: label); title.widthAnchor.constraint(equalToConstant: 90).isActive = true; let stack = NSStackView(views: [title] + views); stack.orientation = .horizontal; stack.spacing = 8; return stack }
        warning.textColor = .systemOrange; warning.setAccessibilityLabel("Remote name warning")
        let form = NSStackView(views: [row("Remote:",[remote,rename]),row("URL:",[url]),row("Push URL:",[pushURL]),row("PuTTY Key:",[key,browse]),row("SSH Key:",[sshKey,browseSSH]),row("Tags:",[tags,pushDefault]),prune,warning,NSView(),add,remove]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 10
        for view in form.arrangedSubviews.prefix(6) { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        let body = NSStackView(views: [list,form]); body.orientation = .horizontal; body.alignment = .top; body.spacing = 20
        list.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true; form.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let help = NSButton(title: "Help", target: self, action: #selector(helpClicked)); help.bezelStyle = .rounded
        let buttons = NSStackView(views: [help,status,NSView(),ok,cancel,apply]); buttons.orientation = .horizontal; buttons.spacing = 8
        let layout = NSStackView(views: [body,buttons]); layout.orientation = .vertical; layout.spacing = 16; layout.translatesAutoresizingMaskIntoConstraints = false; addSubview(layout)
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),layout.topAnchor.constraint(equalTo: topAnchor, constant: 16),layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),body.widthAnchor.constraint(equalTo: layout.widthAnchor),buttons.widthAnchor.constraint(equalTo: layout.widthAnchor)])
        model.updated = { [weak self] in self?.render() }; render()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); guard let window else { return }
        model.confirm = { [weak window] prompt in
            guard let window, window.attachedSheet == nil else { return (false, false) }
            return await withCheckedContinuation { continuation in
                let alert = Self.alert(prompt)
                alert.beginSheetModal(for: window) { continuation.resume(returning: ($0 == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)) }
            }
        }
    }
    static func alert(_ prompt: RemoteSettingsWindowModel.Prompt) -> NSAlert {
        let alert = NSAlert(); alert.messageText = "TurtleGit"; alert.informativeText = prompt.message; alert.alertStyle = .informational
        let yes: NSButton, no: NSButton
        if case .saveDiscard = prompt { yes = alert.addButton(withTitle: "Save"); no = alert.addButton(withTitle: "Discard") }
        else { yes = alert.addButton(withTitle: "Yes"); no = alert.addButton(withTitle: "No") }
        if case .overwrite = prompt { yes.keyEquivalent = ""; no.keyEquivalent = "\r"; alert.window.defaultButtonCell = no.cell as? NSButtonCell }
        else { yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell }
        if case .noTags = prompt { alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show this message again" }
        return alert
    }
    func render() {
        updating = true; defer { updating = false }
        for (field,value) in [(remote,model.draft.name),(url,model.draft.url),(pushURL,model.draft.pushURL),(key,model.draft.puttyKeyFile),(sshKey,model.draft.sshKeyFile)] { if field.stringValue != value { field.stringValue = value }; field.isEnabled = !model.busy && !model.closed && !model.hasChild }
        browse.isEnabled = key.isEnabled; browseSSH.isEnabled = sshKey.isEnabled
        table.reloadData(); table.selectRowIndexes(IndexSet(model.names.indices.filter { model.names[$0] == model.selected }), byExtendingSelection: false); table.isEnabled = !model.busy && !model.closed && !model.hasChild
        tags.selectItem(at: model.draft.tags == .none ? 1 : model.draft.tags == .all ? 2 : 0); tags.isEnabled = !model.busy && !model.closed && !model.hasChild
        prune.state = model.draft.prune == .enabled ? .on : model.draft.prune == .disabled ? .off : .mixed; pushDefault.state = model.draft.pushDefault ? .on : .off
        prune.isEnabled = !model.busy && !model.closed && !model.hasChild; pushDefault.isEnabled = prune.isEnabled; rename.isEnabled = model.canRename; remove.isEnabled = model.canRename; add.isEnabled = model.canSave; apply.isEnabled = model.canApply; ok.isEnabled = !model.busy && !model.closed && !model.hasChild; cancel.isEnabled = ok.isEnabled
        warning.stringValue = model.collision ? "This remote name collides with fetch refspec of other remotes. Please use another name." : ""
        status.stringValue = model.busy ? "Please wait…" : model.error ?? ""; status.textColor = model.error == nil ? .secondaryLabelColor : .systemRed
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.names.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSTextField(labelWithString: model.names[row].rawValue) }
    func tableViewSelectionDidChange(_ notification: Notification) { guard !updating else { return }; model.select(model.names.indices.contains(table.selectedRow) ? model.names[table.selectedRow] : nil) }
    func controlTextDidChange(_ notification: Notification) {
        guard !updating, let field = notification.object as? NSTextField else { return }; let value = field.stringValue
        if field === remote { model.edit(.name) { $0.name = value } }; if field === url { model.edit(.url) { $0.url = value } }; if field === pushURL { model.edit(.pushURL) { $0.pushURL = value } }; if field === key { model.edit(.puttyKeyFile) { $0.puttyKeyFile = value } }
        if field === sshKey { model.edit(.sshKeyFile) { $0.sshKeyFile = value } }
    }
    @objc func tagChanged() { let value: RemoteTagPolicy = tags.indexOfSelectedItem == 1 ? .none : tags.indexOfSelectedItem == 2 ? .all : .reachable; model.edit(.tags) { $0.tags = value } }
    @objc func pruneChanged() { let value: FetchOverride = prune.state == .mixed ? .configured : prune.state == .on ? .enabled : .disabled; model.edit(.prune) { $0.prune = value } }
    @objc func defaultChanged() { let value = pushDefault.state == .on; model.edit(.pushDefault) { $0.pushDefault = value } }
    @objc func renameClicked() { model.rename() }
    @objc func saveClicked() { model.save() }
    @objc func removeClicked() { model.remove() }
    @objc func applyClicked() { model.apply() }
    @objc func okClicked() { model.apply(closeAfter: true) }
    @objc func cancelClicked() { if !model.busy { model.close() } }
    @objc func helpClicked() { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-settings.html#tgit-dug-settings-remote")!) }
    @objc func browseKey() {
        guard !model.busy, !model.closed, !model.hasChild, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.title = "Select PuTTY key file for Windows interoperability"
        model.setChild(true)
        panel.beginSheetModal(for: window) { [weak self] response in guard let self, !self.model.closed else { return }; self.model.setChild(false); guard response == .OK, let url = panel.url else { return }; self.model.edit(.puttyKeyFile) { $0.puttyKeyFile = url.path } }
    }
    static func identityPanel(path: String) -> NSOpenPanel {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Select OpenSSH private key"; panel.prompt = "Select"
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) { let url = URL(fileURLWithPath: path); panel.directoryURL = url.deletingLastPathComponent(); panel.nameFieldStringValue = url.lastPathComponent }
        return panel
    }
    @objc func browseSSHKey() {
        guard !model.busy, !model.closed, !model.hasChild, let window, window.attachedSheet == nil else { return }
        let panel = Self.identityPanel(path: model.draft.sshKeyFile); model.setChild(true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.model.closed else { return }; self.model.setChild(false)
            guard response == .OK, let url = panel.url else { return }; self.model.selectIdentity(url)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct RemoteSettingsEmbeddedPage: NSViewRepresentable {
    let model: RemoteSettingsWindowModel
    func makeNSView(context: Context) -> RemoteSettingsNativeView { RemoteSettingsNativeView(model: model) }
    func updateNSView(_ view: RemoteSettingsNativeView, context: Context) { view.render() }
    static func dismantleNSView(_ view: RemoteSettingsNativeView, coordinator: ()) { view.model.invalidate(); if let sheet = view.window?.attachedSheet { view.window?.endSheet(sheet, returnCode: .abort); sheet.close() } }
}
struct PushRemoteSettings: View {
    var onClose: (() -> Void)?
    @ObservedObject var model: PushWindowModel
    @StateObject private var settings: RemoteSettingsWindowModel
    init(onClose: (() -> Void)? = nil, model: PushWindowModel) {
        self.onClose = onClose; self.model = model
        _settings = StateObject(wrappedValue: RemoteSettingsWindowModel(repository: model.repository, access: model.repositoryAccess, preferences: model.settingsPreferences, noFetch: true))
    }
    var body: some View {
        RemoteSettingsEmbeddedPage(model: settings).frame(minWidth: 730, minHeight: 440)
            .onAppear { settings.close = { if let onClose { onClose() } else { model.managingRemotes = false } }; settings.onRemotesChanged = { model.remotes = $0; if !model.remotes.contains(model.options.remote) { model.options.remote = model.remotes.first ?? "" } }; settings.onReferencesChanged = { model.references = $0 }; settings.load() }
            .onDisappear { settings.invalidate() }
    }
}
