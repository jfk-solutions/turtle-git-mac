// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of ContextMenu's active DropMove/DropMoveRename/DropCopyAdd family.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class FileDropTransferWindowController: NSWindowController, NSWindowDelegate {
    let model: FileDropTransferModel
    var onAccepted: (FileDropTransferModel.Choice, [URL], URL) -> Void = { _, _, _ in }
    var onClosed: () -> Void = {}
    private var picker: (UUID, NSOpenPanel)?
    private var ownerObserver: NSObjectProtocol?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = FileDropTransferModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 340), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Dropped files – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 580, height: 300)
        window.contentViewController = NSHostingController(rootView: FileDropTransferDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.center()
        model.browse = { [weak self] in self?.browse() }
        model.cancel = { [weak self] in self?.close() }
        model.accept = { [weak self] choice in
            guard let self, self.model.canChoose(choice) else { return }
            let sources = self.model.sources, folder = self.model.folder, completion = self.onAccepted
            self.close(); completion(choice, sources, folder)
        }
        DialogGeometry.attach(window, identifier: "TurtleGit.DropTransfer")
    }
    func present(owner: NSWindow) -> Bool {
        guard owner.attachedSheet == nil, let window else { return false }
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in Task { @MainActor in self?.close() } }
        owner.beginSheet(window); return true
    }
    private func browse() {
        guard model.canEdit, picker == nil, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(), id = UUID(); panel.title = "Drop destination"; panel.prompt = "Choose destination"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = model.folder
        panel.message = "Choose a folder in the captured working tree."
        picker = (id, panel); model.choosingFolder = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.picker?.0 == id else { return }; self.picker = nil; self.model.choosingFolder = false
            if !self.model.retired, response == .OK, let folder = panel.url { self.model.prepare(folder: folder) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.choosingFolder }
    override func close() { if let window { window.sheetParent?.endSheet(window); window.close() } }
    func windowWillClose(_ notification: Notification) {
        guard !model.retired else { return }; model.retire()
        if let (_, panel) = picker { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; picker = nil
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class FileDropTransferModel: ObservableObject {
    enum Choice: String, CaseIterable { case move = "Move here", moveRename = "Move and rename here", copyAdd = "Copy and add here" }
    static private(set) var activePreparations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    @Published private(set) var sources: [URL] = []
    @Published private(set) var folder: URL
    @Published private(set) var busy = false
    @Published private(set) var canMove = false
    @Published private(set) var ready = false
    @Published var choosingFolder = false
    @Published var error: String?
    private(set) var retired = false
    private var token: OperationCancellation?
    private var task: Task<Void, Never>?
    var readURL: (NSItemProvider) async throws -> URL = CommitFileURLReader.read
    var browse: () -> Void = {}
    var cancel: () -> Void = {}
    var accept: (Choice) -> Void = { _ in }
    var canEdit: Bool { !retired && !busy && !choosingFolder }
    var choices: [Choice] { guard ready else { return [] }; if !canMove { return [.copyAdd] }; return sources.count == 1 ? [.move, .moveRename] : [.move] }
    func canChoose(_ choice: Choice) -> Bool { canEdit && ready && !sources.isEmpty && choices.contains(choice) }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access; folder = repository.root }
    func load(_ providers: [NSItemProvider]) {
        guard canEdit, !providers.isEmpty, providers.count <= 256, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return }
        let request = begin()
        task = Task {
            defer { finish(request) }
            do {
                var urls: [URL] = [], seen = Set<String>()
                for provider in providers { try request.check(); let url = try await readURL(provider); guard url.isFileURL, !url.path.contains("\0") else { throw CommitFileURLReader.Failure.invalid }; if seen.insert(url.path).inserted { urls.append(url) } }
                try request.check(); guard !retired else { return }; sources = urls
                try await resolve(folder, request: request)
            } catch { if !retired && !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func prepare(folder: URL) {
        guard canEdit, !sources.isEmpty else { return }; let request = begin()
        task = Task { defer { finish(request) }; do { try await resolve(folder, request: request) } catch { if !retired && !request.isCancelled { self.error = error.localizedDescription } } }
    }
    private func begin() -> OperationCancellation {
        let request = OperationCancellation(); token = request; busy = true; ready = false; canMove = false; error = nil; Self.activePreparations += 1; return request
    }
    private func resolve(_ folder: URL, request: OperationCancellation) async throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
        let destination = try await repository.fileMoveDestination(folder, cancellation: request)
        let eligible: Bool
        do { eligible = try await repository.clipboardMovePaths(sources, cancellation: request).count == sources.count }
        catch { try request.check(); eligible = false }
        try request.check(); guard !retired, token === request else { return }; self.folder = destination; canMove = eligible; ready = true
    }
    private func finish(_ request: OperationCancellation) {
        Self.activePreparations -= 1; withExtendedLifetime(access) {}
        if token === request { token = nil; task = nil; if !retired { busy = false } }
    }
    func retire() { retired = true; token?.cancel(); task?.cancel(); ready = false; busy = false }
}

private struct FileDropTransferDialog: View {
    @ObservedObject var model: FileDropTransferModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how to transfer the dropped files").font(.headline)
            HStack { Text("Destination:"); Text(model.folder.path).lineLimit(2).textSelection(.enabled); Spacer(); Button("…") { model.browse() }.disabled(!model.canEdit) }
            List(model.sources, id: \.path) { Text($0.path).textSelection(.enabled) }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            if model.ready && !model.canMove { Text("Move requires versioned sources in this working tree.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                ForEach(model.choices, id: \.self) { choice in
                    Button { model.accept(choice) } label: { CommandLabel(title: choice.rawValue, icon: choice == .copyAdd ? .add : .rename) }.disabled(!model.canChoose(choice))
                }
                Spacer(); Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.choosingFolder)
            }
        }.padding(16)
    }
}
