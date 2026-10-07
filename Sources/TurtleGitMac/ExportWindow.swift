// Native adaptation of TortoiseGit ExportDlg.cpp and IDD_EXPORT.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class ExportWindowController: NSWindowController, NSWindowDelegate {
    let model: ExportWindowModel
    var onClosed: () -> Void = {}
    private var picker: LogWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, directory: String = "") {
        model = ExportWindowModel(repository: repository, access: access, directory: directory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Export – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ExportDialog(model: model))
        super.init(window: window); window.delegate = self
        window.contentMinSize = NSSize(width: 600, height: 360); window.setFrameAutosaveName("ExportDialog"); window.center()
        model.close = { [weak window] in window?.performClose(nil) }
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
    var activeOperation: Bool { model.busy || window?.attachedSheet != nil }
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
    private var cancellation: OperationCancellation?
    var close: () -> Void = {}
    var chooseDestination: () -> Void = {}
    var chooseCommit: () -> Void = {}
    var confirmOverwrite: (String) async -> Bool = { _ in false }
    var branches: [CheckoutReference] { references.filter { ($0.name.hasPrefix("refs/heads/") || $0.remote) && $0.symbolicTarget == nil } }
    var tags: [CheckoutReference] { references.filter { $0.name.hasPrefix("refs/tags/") } }
    var revision: String { switch target { case .head: return "HEAD"; case .branch: return branch; case .tag: return tag; case .commit: return commit } }
    func canReuseForRevision(_ requestedRevision: String, directory requestedDirectory: String) -> Bool {
        !busy && revision == requestedRevision && directory == requestedDirectory && destination.isEmpty && exported == nil && wholeProject == requestedDirectory.isEmpty
    }
    static func directoryScope(root: URL, paths: [String]) -> String {
        guard paths.count == 1, paths[0] != ".", !paths[0].isEmpty,
              (try? root.appendingPathComponent(paths[0]).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return "" }
        return paths[0]
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, directory: String = "") {
        self.repository = repository; self.access = access; self.directory = directory; wholeProject = directory.isEmpty
    }
    func load(revision preset: String) {
        guard !busy else { return }; busy = true
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
        guard !busy, !destination.isEmpty, !revision.isEmpty else { return }
        var url = URL(fileURLWithPath: destination)
        if url.pathExtension.isEmpty { url.appendPathExtension("zip") }
        if GitRuntime.isAppStoreBuild {
            guard access?.hasSecurityScope == true, let outputAccess, outputAccess.hasSecurityScope,
                  outputAccess.url.standardizedFileURL == url.standardizedFileURL else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
        }
        let chosen = revision, scope = wholeProject ? "" : directory
        let token = OperationCancellation(); cancellation = token; busy = true; error = nil; exported = nil; output = ""
        Task {
            defer { busy = false; cancellation = nil }
            do {
                if FileManager.default.fileExists(atPath: url.path), !(await confirmOverwrite(url.path)) { return }
                output = try await repository.archiveRevision(chosen, directory: scope, to: url, cancellation: token)
                destination = url.path; exported = url
            } catch { if !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func cancel() { cancellation?.cancel() }
}

private struct ExportDialog: View {
    @ObservedObject var model: ExportWindowModel
    private func radio(_ title: String, _ target: ExportWindowModel.Target) -> some View {
        Button { model.target = target } label: {
            HStack { Image(systemName: model.target == target ? "largecircle.fill.circle" : "circle"); Text(title) }
        }.buttonStyle(.plain).accessibilityValue(model.target == target ? "Selected" : "Not selected")
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
