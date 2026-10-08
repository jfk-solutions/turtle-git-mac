// Native adaptation of TortoiseGit ExportDlg.cpp and IDD_EXPORT.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class ExportWindowController: NSWindowController, NSWindowDelegate {
    let model: ExportWindowModel
    var onClosed: () -> Void = {}
    private var picker: LogWindowController?
    private var progressController: ExportProgressWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, directory: String = "", preferences: UserDefaults = .standard) {
        model = ExportWindowModel(repository: repository, access: access, directory: directory, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Export – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ExportDialog(model: model))
        super.init(window: window); window.delegate = self
        window.contentMinSize = NSSize(width: 600, height: 360); window.setFrameAutosaveName("ExportDialog"); window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, self.model.progress == nil, self.window?.attachedSheet == nil else { return }; self.window?.performClose(nil) }
        model.onProgress = { [weak self] result in
            guard let self, let window = self.window, window.attachedSheet == nil else { result.abandonPresentation(); return }
            let controller = ExportProgressWindowController(model: result)
            controller.onClosed = { [weak self, weak result] in guard let self, let result else { return }; self.progressController = nil; self.model.finish(result) }
            self.progressController = controller
            if let child = controller.window { window.beginSheet(child) } else { result.abandonPresentation() }
        }
        model.chooseDestination = { [weak self] in self?.chooseDestination() }
        model.chooseCommit = { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            let picker = LogWindowController(repository: repository, access: access, onChoose: { [weak self] entry in
                self?.picker = nil
                if let entry { self?.model.commit = entry.hash }
            })
            self.picker = picker; picker.model.reload()
            if let child = picker.window { window.beginSheet(child) }
        }
        model.confirmOverwrite = { [weak window] path in
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Replace existing ZIP file?"; alert.informativeText = path
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Replace")
            return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertSecondButtonReturn) } }
        }
        model.load(revision: revision)
    }
    private func chooseDestination() {
        guard let window, window.attachedSheet == nil, !model.busy else { return }
        let panel = NSSavePanel(); panel.title = "Export Zip File"; panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = model.destination.isEmpty ? "Export.zip" : URL(fileURLWithPath: model.destination).lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let lease = RepositoryAccessLease(url: url)
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { self.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
            self.model.outputAccess = lease; self.model.destination = url.path
        }
    }
    var activeOperation: Bool { model.busy || model.progress != nil || window?.attachedSheet != nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !activeOperation }
    func windowWillClose(_ notification: Notification) { picker?.close(); picker = nil; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ExportWindowModel: ObservableObject {
    enum Target { case head, branch, tag, commit }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let directory: String
    var outputAccess: RepositoryAccessLease?
    @Published var destination = ""
    @Published var target = Target.head
    @Published var branch = ""
    @Published var tag = ""
    @Published var commit = "HEAD"
    @Published var currentBranch = ""
    @Published var references: [CheckoutReference] = []
    @Published var wholeProject: Bool
    @Published var busy = false
    @Published var error: String?
    @Published var output = ""
    @Published var exported: URL?
    @Published var browseReferences = false
    private let preferences: UserDefaults
    @Published private(set) var progress: ExportProgressWindowModel?
    var onProgress: ((ExportProgressWindowModel) -> Void)?
    func finish(_ result: ExportProgressWindowModel) {
        guard progress === result, !result.busy, !result.confirmingCancellation else { return }
        progress = nil; result.invalidate(); busy = false; output = result.output; error = nil
        if result.success { destination = result.destination.path; exported = result.destination; close() }
    }
    private var cancellation: OperationCancellation?
    var close: () -> Void = {}
    var chooseDestination: () -> Void = {}
    var chooseCommit: () -> Void = {}
    var confirmOverwrite: (String) async -> Bool = { _ in false }
    var branches: [CheckoutReference] { references.filter { ($0.name.hasPrefix("refs/heads/") || $0.remote) && $0.symbolicTarget == nil } }
    var tags: [CheckoutReference] { references.filter { $0.name.hasPrefix("refs/tags/") } }
    var revision: String { switch target { case .head: return "HEAD"; case .branch: return branch; case .tag: return tag; case .commit: return commit } }
    func canReuseForRevision(_ requestedRevision: String, directory requestedDirectory: String) -> Bool {
        !busy && progress == nil && revision == requestedRevision && directory == requestedDirectory && destination.isEmpty && exported == nil && wholeProject == requestedDirectory.isEmpty
    }
    static func directoryScope(root: URL, paths: [String]) -> String {
        guard paths.count == 1, paths[0] != ".", !paths[0].isEmpty,
              (try? root.appendingPathComponent(paths[0]).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return "" }
        return paths[0]
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, directory: String = "", preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.directory = directory; self.preferences = preferences; wholeProject = directory.isEmpty
    }
    func load(revision preset: String) {
        guard !busy, progress == nil else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                references = try await repository.checkoutReferences(); currentBranch = try await repository.branch()
                branch = branches.first?.name ?? ""; tag = tags.first?.name ?? ""
                if preset == "HEAD" || preset.isEmpty { target = .head }
                else if tags.contains(where: { $0.name == preset }) { target = .tag; tag = preset }
                else if branches.contains(where: { $0.name == preset }) { target = .branch; branch = preset }
                else { target = .commit; commit = preset }
            } catch { self.error = error.localizedDescription }
        }
    }
    func export() {
        guard !busy, progress == nil, !browseReferences, !destination.isEmpty, !revision.isEmpty else { return }
        var url = URL(fileURLWithPath: destination)
        if url.pathExtension.isEmpty { url.appendPathExtension("zip") }
        if GitRuntime.isAppStoreBuild {
            guard access?.hasSecurityScope == true, access?.contains(repository.root) == true, let outputAccess, outputAccess.hasSecurityScope,
                  outputAccess.url.standardizedFileURL == url.standardizedFileURL else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
        }
        let chosen = revision, scope = wholeProject ? "" : directory
        let token = OperationCancellation(); cancellation = token; busy = true; error = nil; exported = nil; output = ""
        Task {
            defer { if progress == nil { busy = false }; cancellation = nil }
            do {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue { self.error = "You selected a folder.\nExports are only possible to a (zip) file."; return }
                    guard await confirmOverwrite(url.path) else { return }
                }
                guard !token.isCancelled else { return }
                if let onProgress {
                    let result = ExportProgressWindowModel(repository: repository, access: access, outputAccess: outputAccess, revision: chosen, directory: scope, destination: url, preferences: preferences)
                    result.close = { [weak self, weak result] in guard let result else { return }; self?.finish(result) }
                    progress = result; onProgress(result); result.start(); return
                }
                output = try await repository.archiveRevision(chosen, directory: scope, to: url, cancellation: token)
                destination = url.path; exported = url
            } catch { if !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func cancel() { if let progress { progress.cancel() } else { cancellation?.cancel() } }
}

struct ExportDialog: View {
    @ObservedObject var model: ExportWindowModel
    private func radio(_ title: String, _ target: ExportWindowModel.Target) -> some View {
        ExportRadio(title: title, value: target, selection: $model.target)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Export Zip File") {
                VStack(alignment: .leading) { Text("Zip File")
                    HStack { TextField("ZIP file", text: $model.destination); Button("…") { model.chooseDestination() }.accessibilityLabel("Choose ZIP file") }
                }.padding(8)
            }
            .disabled(model.busy)
            GroupBox("Revision") {
                VStack(alignment: .leading, spacing: 10) {
                    radio("HEAD" + (model.currentBranch.isEmpty ? "" : " (" + model.currentBranch + ")"), .head).frame(maxWidth: .infinity, alignment: .leading)
                    HStack { radio("Branch", .branch).frame(width: 100, alignment: .leading); ReferencePopup(references: model.branches, selection: $model.branch).disabled(model.target != .branch); Button("…") { model.browseReferences = true }.disabled(model.target != .branch).accessibilityLabel("Browse references") }
                    HStack { radio("Tag", .tag).frame(width: 100, alignment: .leading); ReferencePopup(references: model.tags, selection: $model.tag).disabled(model.target != .tag); Color.clear.frame(width: 29) }
                    HStack { radio("Commit", .commit).frame(width: 100, alignment: .leading); TextField("Commit", text: $model.commit).disabled(model.target != .commit); Button("…") { model.chooseCommit() }.disabled(model.target != .commit).accessibilityLabel("Choose commit") }
                }.padding(8)
            }
            .disabled(model.busy)
            Toggle("Whole Project", isOn: $model.wholeProject).toggleStyle(.checkbox).disabled(model.directory.isEmpty || model.busy)
            if let exported = model.exported { HStack { Text("Export completed").foregroundStyle(.green); Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported]) } } }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.export() }.disabled(model.busy || model.destination.isEmpty || model.revision.isEmpty).keyboardShortcut(.defaultAction)
                Button(model.busy ? "Cancel export" : (model.exported == nil ? "Cancel" : "Done")) { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-export.html")!) }
            }
        }.padding(16)
        .alert("Export failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.browseReferences) {
            VStack { Text("Browse references").font(.headline)
                List { ForEach(model.branches, id: \.name) { ref in Button(ref.label) { model.branch = ref.name; model.browseReferences = false } } }
                Button("Cancel") { model.browseReferences = false }.keyboardShortcut(.cancelAction)
            }.padding(16).frame(width: 500, height: 350)
        }
    }
}

@MainActor final class ExportProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let destination: URL
    private let access: RepositoryAccessLease?, outputAccess: RepositoryAccessLease?
    private let revision: String, directory: String
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private let cancellation = OperationCancellation()
    private var started = false, invalidated = false, dispatched = false, abandoned = false
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var output = ""
    var close: () -> Void = {}
    var showInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { busy && !cancelling && !confirmingCancellation && !invalidated }
    init(repository: GitRepository, access: RepositoryAccessLease?, outputAccess: RepositoryAccessLease?, revision: String, directory: String, destination: URL, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.outputAccess = outputAccess; self.revision = revision; self.directory = directory; self.destination = destination; self.preferences = preferences; autoClosePolicy = GitProgressAutoClose(preferences: preferences)
    }
    func invalidate() { invalidated = true }
    func abandonPresentation() { abandoned = true; cancellation.cancel() }
    func start() { Task { await run() } }
    func run() async {
        guard !started, !invalidated else { return }; started = true
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true || outputAccess?.hasSecurityScope != true || outputAccess?.url.standardizedFileURL != destination.standardizedFileURL) { throw RepositoryAccessFailure.securityScopeUnavailable }
            output = try await repository.archiveRevision(revision, directory: directory, to: destination, cancellation: cancellation); success = true
        } catch { output = error.localizedDescription; cancelled = cancellation.isCancelled }
        busy = false; cancelling = false; finishAutomatically()
    }
    private func finishAutomatically() { if !busy, !confirmingCancellation, !invalidated, abandoned || autoClosePolicy.shouldClose(success: success, postActionCount: success ? 1 : 0) { close() } }
    func cancel() {
        guard canCancel else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, self.confirmingCancellation, !self.invalidated else { return }; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.cancellation.cancel() }
                self.finishAutomatically()
            }
        } else { cancelling = true; cancellation.cancel() }
    }
    func explore() {
        guard !busy, success, !invalidated, !confirmingCancellation, !dispatched else { return }; dispatched = true
        close(); showInFinder(destination)
    }
}
@MainActor final class ExportProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: ExportProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: ExportProgressWindowModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:430), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        window.title = "Export – \(model.repository.root.lastPathComponent) – TurtleGit"; window.minSize = NSSize(width:650,height:320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:ExportProgressDialog(model:model)); super.init(window:window); window.delegate = self
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.confirmingCancellation, self.window?.attachedSheet == nil else { return }; if let window = self.window { window.sheetParent?.endSheet(window); window.close() } }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle:"Yes"); alert.addButton(withTitle:"No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for:window) { choose($0 == .alertFirstButtonReturn) }
        }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if model.busy { model.cancel(); return false }; guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }; sender.sheetParent?.endSheet(sender); return true }
    func windowWillClose(_ notification:Notification) { model.invalidate(); onClosed() }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}
struct ExportProgressDialog: View {
    @ObservedObject var model: ExportProgressWindowModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ScrollView { Text(model.output).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(8).background(Color(nsColor:.textBackgroundColor))
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Exporting…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Export failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red); Spacer() }
            HStack {
                if model.success { Button { model.explore() } label: { CommandLabel(title:"Show in Finder",icon:.explore) }; Menu { Button { model.explore() } label: { CommandLabel(title:"Show in Finder",icon:.explore) } } label: { Image(systemName:"chevron.down").accessibilityLabel("Export post-actions") }.menuStyle(.borderlessButton).fixedSize() }
                Spacer()
                if model.busy { Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }.disabled(model.confirmingCancellation)
        }.padding(12)
    }
}

private struct ExportRadio: NSViewRepresentable {
    let title: String
    let value: ExportWindowModel.Target
    @Binding var selection: ExportWindowModel.Target
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked)) }
    func updateNSView(_ button: NSButton, context: Context) { button.title = title; button.state = selection == value ? .on : .off; button.isEnabled = enabled; context.coordinator.select = { selection = value } }
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked(_ sender: NSButton) { select() } }
}
