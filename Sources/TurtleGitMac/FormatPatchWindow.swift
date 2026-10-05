import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class FormatPatchWindowController: NSWindowController, NSWindowDelegate, NSSharingServiceDelegate {
    let model: FormatPatchWindowModel
    var onClosed: () -> Void = {}
    private var picker: LogWindowController?
    private var patch: PatchWindowController?
    private var mail: NSSharingService?
    var activeOperation: Bool { model.busy || model.composingMail || model.openingViewer }
    init(repository: GitRepository, access: RepositoryAccessLease?, preset: FormatPatchPreset? = nil) {
        model = FormatPatchWindowModel(repository: repository, access: access)
        model.apply(preset)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 365), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Format Patch – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FormatPatchDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 680, height: 365))
        window.contentMinSize = NSSize(width: 650, height: 365); window.contentMaxSize = NSSize(width: 4000, height: 365)
        window.setFrameAutosaveName("FormatPatchDialog"); window.center()
        model.close = { [weak self] in guard let self, !self.activeOperation else { return }; self.window?.performClose(nil) }
        model.chooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.chooseRevision = { [weak self] target in self?.chooseRevision(target) }
        model.showPatch = { [weak self] bytes, alternate in self?.showPatch(bytes, alternate: alternate) }
        model.composeMail = { [weak self] files in self?.composeMail(files) }
        model.load()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !activeOperation && sender.attachedSheet == nil && patch?.model.busy != true && patch?.window?.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { patch?.close(); onClosed() }
    private func chooseDirectory() {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = "Output Directory"; panel.directoryURL = URL(fileURLWithPath: model.directory)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url, let self else { return }
            let lease = RepositoryAccessLease(url: folder)
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { self.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
            self.model.outputAccess = lease; self.model.directory = folder.path
        }
    }
    private func chooseRevision(_ target: FormatPatchWindowModel.Mode) {
        guard let window, window.attachedSheet == nil else { return }
        let controller = LogWindowController(repository: model.repository, access: model.access) { [weak self] entry in
            self?.picker = nil
            guard let self, let entry else { return }
            if target == .since { self.model.since = entry.hash; self.model.mode = .since }
            else if target == .from { self.model.from = entry.hash; self.model.mode = .from }
            else { self.model.to = entry.hash; self.model.mode = .from }
        }
        picker = controller; controller.model.reload()
        if let child = controller.window { window.beginSheet(child) }
    }
    private func showPatch(_ bytes: Data, alternate: Bool) {
        let preferences = UnifiedDiffViewerPreferences.load()
        do {
            if case .external(let application) = try preferences.choice(alternate: alternate) {
                let preview = try UnifiedDiffPreview.create(bytes)
                UnifiedDiffPreviewFiles.retain(preview)
                model.openingViewer = true
                UnifiedDiffApplication.open(preview.file, application: application, bookmark: preferences.bookmark) { [weak model] error in
                    model?.openingViewer = false
                    if let error { UnifiedDiffPreviewFiles.discard(preview.file); model?.error = error }
                }
                return
            }
        } catch { model.error = error.localizedDescription; return }
        let controller = patch ?? PatchWindowController(repository: model.repository, access: model.access)
        controller.model.setReadOnlyDiff(bytes)
        controller.model.comparisonTitle = "HEAD → Working tree"
        controller.model.readOnlyInformation = "Unified diff since HEAD. Right-click to save the patch."
        controller.model.customRefresh = { [weak model = model, weak controller] in
            model?.unifiedDiff(onResult: { [weak controller] bytes in controller?.model.setReadOnlyDiff(bytes) })
        }
        controller.window?.title = "Unified Diff – TurtleGit"
        controller.onClosed = { [weak self] in self?.patch = nil }
        patch = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func composeMail(_ files: [URL]) {
        guard !files.isEmpty else { model.error = "No patches were created to attach."; return }
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) else { model.error = "No mail composition service is available. The patches were saved to the output directory."; return }
        mail = service; model.composingMail = true; service.delegate = self; service.subject = "Patch series"
        service.perform(withItems: files)
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { mail = nil; model.composingMail = false; model.close() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { mail = nil; model.composingMail = false; model.error = error.localizedDescription }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class FormatPatchWindowModel: ObservableObject {
    enum Mode { case since, number, from, to }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    var outputAccess: RepositoryAccessLease?
    @Published var directory: String
    @Published var since: String
    @Published var from: String
    @Published var to: String
    @Published var count = 1
    @Published var mode = Mode.since
    @Published var sendMail: Bool
    @Published var noPrefix: Bool
    @Published var busy = false
    @Published var composingMail = false
    @Published var openingViewer = false
    @Published var hasHead = false
    @Published var bare = false
    @Published var references: [String] = []
    @Published var error: String?
    @Published var progress = false
    @Published var output = ""
    @Published var success = false
    @Published var cancelRequested = false
    @Published var cancelled = false
    private var cancellation: OperationCancellation?
    private var files: [URL] = []
    private var exportSendMail = false
    var close: () -> Void = {}
    var chooseDirectory: () -> Void = {}
    var chooseRevision: (Mode) -> Void = { _ in }
    var showPatch: (Data, Bool) -> Void = { _, _ in }
    var composeMail: ([URL]) -> Void = { _ in }
    var onOutputChanged: (String) -> Void = { _ in }
    func apply(_ preset: FormatPatchPreset?) {
        guard let preset, !busy, !progress, !composingMail, !openingViewer else { return }
        from = preset.from; to = preset.to
        switch preset.selection {
        case .since(let value): since = value; mode = .since
        case .range: mode = .from
        case .number(let value): count = value; mode = .number
        }
    }
    var dirs: [String] { UserDefaults.standard.stringArray(forKey: "FormatPatchDirectories") ?? [] }
    var fromHistory: [String] { UserDefaults.standard.stringArray(forKey: "FormatPatchFrom") ?? [] }
    var toHistory: [String] { UserDefaults.standard.stringArray(forKey: "FormatPatchTo") ?? [] }
    private var sinceKey: String { "FormatPatchSince:" + repository.root.path }
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        self.repository = repository; self.access = access; directory = repository.root.path
        let defaults = UserDefaults.standard
        since = defaults.string(forKey: "FormatPatchSince:" + repository.root.path) ?? ""
        from = defaults.stringArray(forKey: "FormatPatchFrom")?.first ?? ""
        to = defaults.stringArray(forKey: "FormatPatchTo")?.first ?? ""
        sendMail = defaults.bool(forKey: "FormatPatchSendMail"); noPrefix = defaults.bool(forKey: "FormatPatchNoPrefix")
    }
    func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try checkAccess()
                hasHead = try await repository.run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], successfulExitCodes: 0...1).exitCode == 0
                bare = try await repository.isBare()
                references = try await repository.checkoutReferences().filter { !$0.name.hasPrefix("refs/tags/") && $0.symbolicTarget == nil }.map(\.name)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func remember(_ value: String, key: String) {
        guard !value.isEmpty else { return }
        let old = UserDefaults.standard.stringArray(forKey: key) ?? []
        UserDefaults.standard.set(Array(([value] + old.filter { $0 != value }).prefix(25)), forKey: key)
    }
    var valid: Bool { hasHead && !directory.isEmpty && (mode == .number || (mode == .since ? !since.isEmpty : !from.isEmpty && !to.isEmpty)) }
    var progressStatus: String {
        if busy { return cancelRequested ? "Stopping Git…" : "Creating patches…" }
        if cancelled { return "Cancelled" }
        return success ? "Finished" : "Failed"
    }
    func export() {
        guard !busy, !composingMail, !openingViewer, valid else { return }
        let folder = URL(fileURLWithPath: directory).standardizedFileURL
        if GitRuntime.isAppStoreBuild && !((access?.hasSecurityScope == true && access?.contains(folder) == true) || (outputAccess?.hasSecurityScope == true && outputAccess?.contains(folder) == true)) { chooseDirectory(); return }
        let selection: FormatPatchSelection = mode == .since ? .since(since) : mode == .number ? .number(count) : .range(from: from, to: to)
        let prefix = noPrefix; exportSendMail = sendMail
        remember(directory, key: "FormatPatchDirectories"); remember(from, key: "FormatPatchFrom"); remember(to, key: "FormatPatchTo")
        if mode == .since { UserDefaults.standard.set(since, forKey: sinceKey) }
        UserDefaults.standard.set(sendMail, forKey: "FormatPatchSendMail"); UserDefaults.standard.set(prefix, forKey: "FormatPatchNoPrefix")
        busy = true; progress = true; success = false; output = "Creating patch series…"; files = []
        cancelRequested = false; cancelled = false
        let token = OperationCancellation(); cancellation = token
        Task {
            defer { busy = false; cancellation = nil; onOutputChanged(output) }
            do {
                try checkAccess()
                let result = try await repository.formatPatch(selection: selection, to: folder, noPrefix: prefix, cancellation: token)
                guard !token.isCancelled else {
                    cancelled = true; output = result.text + "\nOperation cancelled. Any patches written before cancellation remain in the output directory."
                    return
                }
                output = result.text.isEmpty ? "No patches created for this selection." : result.text
                // Git sanitizes subject filenames. Split at the complete directory
                // prefix so a newline inside the chosen directory remains literal.
                let resolved = folder.resolvingSymlinksInPath()
                files = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: resolved.path + "/").dropFirst().compactMap { part in
                    let name = part.hasSuffix("\n") ? String(part.dropLast()) : part
                    guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), name != ".", name != ".." else { return nil }
                    let file = resolved.appendingPathComponent(name)
                    return FileManager.default.fileExists(atPath: file.path) ? file : nil
                }
                success = true
            } catch let failure as GitCommandCancellationFailure {
                cancelled = true
                output = failure.result.text + "\nOperation cancelled. Any patches written before cancellation remain in the output directory."
            } catch is OperationCancellationFailure {
                cancelled = true; output = "Operation cancelled. Any patches written before cancellation remain in the output directory."
            } catch { output = error.localizedDescription }
        }
    }
    func cancelExport() {
        guard busy, let cancellation, !cancelRequested else { return }
        cancelRequested = true; cancellation.cancel()
    }
    func finish() {
        guard !busy else { return }; progress = false
        guard success else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.exportSendMail { self.composeMail(self.files) } else { self.close() }
        }
    }
    func unifiedDiff(alternate: Bool = false, onResult: ((Data) -> Void)? = nil) {
        guard !busy, !composingMail, !openingViewer, hasHead, !bare else { return }
        let prefix = noPrefix
        UserDefaults.standard.set(prefix, forKey: "FormatPatchNoPrefix"); busy = true
        Task {
            defer { busy = false }
            do {
                try checkAccess()
                let result = try await repository.run(["diff", "--no-ext-diff", "--no-color", "--stat", "--patch"] + (prefix ? ["--no-prefix"] : []) + ["--end-of-options", "HEAD", "--"])
                if let onResult { onResult(result.stdout) } else { showPatch(result.stdout, alternate) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct FormatPatchDialog: View {
    @ObservedObject var model: FormatPatchWindowModel
    @State private var browseSince = false
    @State private var reference: String?
    @State private var referenceSearch = ""
    func radio(_ title: String, mode: FormatPatchWindowModel.Mode) -> some View {
        FormatPatchRadio(title: title, selected: model.mode == mode) { model.mode = mode }.frame(width: 145, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Output Directory") { HStack {
                Text("Directory:").frame(width: 90, alignment: .leading)
                FormatPatchCombo(value: $model.directory, choices: model.dirs, label: "Output directory")
                Button("…") { model.chooseDirectory() }.accessibilityLabel("Choose output directory")
            }.padding(8) }
            GroupBox("Version") { VStack(spacing: 8) {
                HStack { radio("Since", mode: .since)
                    FormatPatchCombo(value: $model.since, choices: model.references, label: "Since revision").disabled(model.mode != .since)
                    Button("…") { browseSince = true }.accessibilityLabel("Browse branches").disabled(model.mode != .since)
                }
                HStack { radio("Number Commits", mode: .number)
                    TextField("Commit count", value: $model.count, format: .number.grouping(.never)).disabled(model.mode != .number)
                    Stepper("", value: $model.count, in: 1...Int(Int32.max)).labelsHidden().disabled(model.mode != .number)
                }
                HStack { radio("Range", mode: .from); Text("From:").frame(width: 40, alignment: .leading)
                    FormatPatchCombo(value: $model.from, choices: model.fromHistory, label: "From revision").disabled(model.mode != .from)
                    Button("…") { model.chooseRevision(.from) }.accessibilityLabel("Choose From commit").disabled(model.mode != .from)
                }
                HStack { Color.clear.frame(width: 145); Text("To:").frame(width: 40, alignment: .leading)
                    FormatPatchCombo(value: $model.to, choices: model.toHistory, label: "To revision").disabled(model.mode != .from)
                    Button("…") { model.chooseRevision(.to) }.accessibilityLabel("Choose To commit").disabled(model.mode != .from)
                }
            }.padding(8) }
            Toggle("Send Mail after create", isOn: $model.sendMail)
            Toggle("No a/ and b/ prefixes", isOn: $model.noPrefix)
            HStack {
                Button("Save unified diff since HEAD") { model.unifiedDiff(alternate: NSEvent.modifierFlags.contains(.shift)) }.disabled(!model.hasHead || model.bare)
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
                Button("OK") { model.export() }.keyboardShortcut(.defaultAction).disabled(!model.valid)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-patch.html")!) }
            }
        }.padding(16).disabled(model.busy || model.composingMail || model.openingViewer)
        .alert("Format Patch", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $browseSince) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Browse references").font(.headline)
                TextField("Filter branches", text: $referenceSearch).onChange(of: referenceSearch) { _ in reference = nil }
                List(model.references.filter { referenceSearch.isEmpty || $0.localizedCaseInsensitiveContains(referenceSearch) }, id: \.self, selection: $reference) { Text($0) }.frame(minHeight: 250)
                HStack { Spacer(); Button("Cancel") { browseSince = false }.keyboardShortcut(.cancelAction)
                    Button("OK") { if let reference { model.since = reference; model.mode = .since }; browseSince = false }.keyboardShortcut(.defaultAction).disabled(reference == nil) }
            }.padding(16).frame(width: 500)
        }
        .sheet(isPresented: $model.progress) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Format Patch").font(.headline); Spacer(); if model.busy { ProgressView().controlSize(.small) } }
                ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 220)
                HStack { Text(model.progressStatus).foregroundStyle(model.success ? Color.green : model.cancelled ? .orange : .secondary); Spacer()
                    if model.busy { Button("Cancel") { model.cancelExport() }.keyboardShortcut(.cancelAction).disabled(model.cancelRequested) }
                    Button("Close") { model.finish() }.keyboardShortcut(.defaultAction).disabled(model.busy) }
            }.padding(16).frame(width: 620).disabled(false)
                .interactiveDismissDisabled()
                .onExitCommand { if model.busy { model.cancelExport() } else { model.finish() } }
        }
    }
}

private struct FormatPatchRadio: NSViewRepresentable {
    let title: String; let selected: Bool; let select: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked)) }
    func updateNSView(_ button: NSButton, context: Context) { button.state = selected ? .on : .off; button.isEnabled = enabled; context.coordinator.select = select }
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked() { select() } }
}

private struct FormatPatchCombo: NSViewRepresentable {
    @Binding var value: String; let choices: [String]; let label: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox { let view = NSComboBox(); view.delegate = context.coordinator; view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    func updateNSView(_ view: NSComboBox, context: Context) {
        let c = context.coordinator; c.updating = true; defer { c.updating = false }; c.change = { value = $0 }
        if c.choices != choices { view.removeAllItems(); view.addItems(withObjectValues: choices); c.choices = choices }
        if view.stringValue != value { view.stringValue = value }; view.isEnabled = enabled; view.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var updating = false; var choices: [String] = []; var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) { guard !updating, let view = notification.object as? NSComboBox else { return }; change(view.stringValue) }
        func comboBoxSelectionDidChange(_ notification: Notification) { guard !updating, let view = notification.object as? NSComboBox, choices.indices.contains(view.indexOfSelectedItem) else { return }; change(choices[view.indexOfSelectedItem]) }
    }
}
