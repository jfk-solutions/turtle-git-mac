// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of ContextMenu's active DropMove/DropMoveRename/DropCopyAdd family.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class FileDropTransferWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var activeReleases = 0
    let model: FileDropTransferModel
    var onAccepted: (FileDropTransferModel.Choice, [URL], URL) -> Void = { _, _, _ in }
    var onClosed: () -> Void = {}
    var receiveAllowed: () -> Bool = { true }
    var makeOpenPanel: () -> NSOpenPanel = { NSOpenPanel() }
    private var picker: (UUID, NSOpenPanel)?
    private var ownerObserver: NSObjectProtocol?
    private weak var presentingOwner: NSWindow?
    private var releasing = false
    private var finished = false
    private var accepted: (FileDropTransferModel.Choice, [URL], URL)?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, destination: URL? = nil) {
        model = FileDropTransferModel(repository: repository, access: access, preferences: preferences, destination: destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 340), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Transfer files – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 580, height: 300)
        window.contentViewController = NSHostingController(rootView: FileDropTransferDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.center()
        model.browse = { [weak self] in self?.browse() }
        model.cancel = { [weak self] in guard let self, !self.model.confirmingQuit else { return }; self.close() }
        model.accept = { [weak self] choice in
            guard let self, self.receiveAllowed(), self.model.canChoose(choice), self.window?.attachedSheet == nil else { return }
            self.accepted = (choice, self.model.sources, self.model.folder)
            self.close()
        }
        DialogGeometry.attach(window, identifier: "TurtleGit.DropTransfer")
    }
    func present(owner: NSWindow?) -> Bool {
        guard !model.retired, !model.confirmingQuit, receiveAllowed(), owner?.attachedSheet == nil, let window else { return false }
        self.presentingOwner = owner
        guard let owner else {
            let appearance = model.presentationPreferences.string(forKey: "appearance") ?? "system"
            window.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
            showWindow(nil); return true
        }
        window.alphaValue = owner.alphaValue; window.appearance = owner.appearance
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accepted = nil; self?.close() }
        }
        owner.beginSheet(window, completionHandler: nil); return true
    }
    private func browse() {
        guard model.canEdit, receiveAllowed(), picker == nil, let window, window.attachedSheet == nil else { return }
        let panel = makeOpenPanel(), id = UUID(); panel.title = "Drop destination"; panel.prompt = "Choose destination"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = model.folder
        panel.alphaValue = window.alphaValue; panel.appearance = window.appearance
        panel.message = "Choose a folder in the captured working tree."
        picker = (id, panel); model.choosingFolder = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.picker?.0 == id else { return }
            let destination = response == .OK ? panel.url : nil
            Task { @MainActor [self] in
                while panel.sheetParent != nil || window.attachedSheet === panel { try? await Task.sleep(nanoseconds: 10_000_000) }
                guard self.picker?.0 == id else { return }
                self.picker = nil; self.model.choosingFolder = false
                if !self.model.retired, self.receiveAllowed(), let destination { self.model.prepare(folder: destination) }
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit, !model.choosingFolder, sender.attachedSheet == nil else { return false }
        close(); return false
    }
    override func close() { finish() }
    private func finish(closeWindow: Bool = true) {
        guard !releasing else { return }; releasing = true; model.retire(); Self.activeReleases += 1
        let parent = window?.sheetParent ?? presentingOwner, panel = picker?.1
        if let panel { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil); if closeWindow { window.close() } }
        Task { @MainActor [self] in
            while model.hasPendingPreparation || panel?.sheetParent != nil || window?.attachedSheet != nil || window?.sheetParent != nil || (window != nil && parent?.attachedSheet === window) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard !finished else { return }; finished = true; picker = nil; model.choosingFolder = false
            if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil
            Self.activeReleases -= 1
            let receipt = accepted, completion = onAccepted, closed = onClosed
            accepted = nil; onAccepted = { _, _, _ in }; onClosed = {}
            // The receiver can immediately attach the selected operation to this owner.
            // Never hand a cancelled/quit-blocked capture to a newer repository context.
            if let receipt, !model.confirmingQuit, receiveAllowed() { completion(receipt.0, receipt.1, receipt.2) }
            closed()
            withExtendedLifetime(model.access) {}
        }
    }
    func windowWillClose(_ notification: Notification) { if !releasing { accepted = nil; finish(closeWindow: false) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class FileDropTransferModel: ObservableObject {
    enum Choice: String, CaseIterable { case move = "Move here", moveRename = "Move and rename here", copyAdd = "Copy and add here" }
    static private(set) var activePreparations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let presentationPreferences: UserDefaults
    @Published var confirmingQuit = false
    @Published private(set) var recentDestinations: [URL] = []
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
    var hasPendingPreparation: Bool { task != nil }
    var resolveDestination: (URL, OperationCancellation) async throws -> URL
    var canEdit: Bool { !retired && !confirmingQuit && !busy && !choosingFolder }
    var choices: [Choice] { guard ready else { return [] }; if !canMove { return [.copyAdd] }; return sources.count == 1 ? [.move, .moveRename] : [.move] }
    func canChoose(_ choice: Choice) -> Bool { canEdit && ready && !sources.isEmpty && choices.contains(choice) }
    private var historyKey: String { "FileTransfer.Destinations." + repository.root.standardizedFileURL.path }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, destination: URL? = nil) {
        self.repository = repository; self.access = access; presentationPreferences = preferences; folder = destination ?? repository.root
        resolveDestination = { folder, token in try await repository.fileMoveDestination(folder, cancellation: token) }
        recentDestinations = Array((preferences.stringArray(forKey: historyKey) ?? []).prefix(12)).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    func loadSources(_ urls: [URL], destination: URL? = nil) {
        guard canEdit, sources.isEmpty, !urls.isEmpty, urls.count <= 256 else { return }
        guard urls.allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }) else { error = CommitFileURLReader.Failure.invalid.localizedDescription; return }
        sources = FileTransferPaths.uniqueURLs(urls)
        let request = begin(), proposed = destination ?? folder
        task = Task {
            defer { finish(request) }
            do { try await resolve(proposed, request: request) }
            catch { if !retired && !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func load(_ providers: [NSItemProvider]) {
        guard canEdit, sources.isEmpty, !providers.isEmpty, providers.count <= 256, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return }
        let request = begin()
        task = Task {
            defer { finish(request) }
            do {
                var urls: [URL] = [], seen = GitPathSet()
                for provider in providers { try request.check(); let url = try await readURL(provider); guard url.isFileURL, !url.path.contains("\0") else { throw CommitFileURLReader.Failure.invalid }; if seen.insert(FileTransferPaths.lexicalPath(url.path)).inserted { urls.append(url) } }
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
        let destination = try await resolveDestination(folder, request)
        let eligible: Bool
        do { eligible = try await repository.clipboardMovePaths(sources, cancellation: request).count == sources.count }
        catch { try request.check(); eligible = false }
        try request.check(); guard !retired, token === request else { return }; self.folder = destination; canMove = eligible; ready = true
        recentDestinations = [destination] + recentDestinations.filter { FileTransferPaths.lexicalPath($0.path) != FileTransferPaths.lexicalPath(destination.path) }
        recentDestinations = Array(recentDestinations.prefix(12))
        presentationPreferences.set(recentDestinations.map(\.path), forKey: historyKey)
    }
    private func finish(_ request: OperationCancellation) {
        Self.activePreparations -= 1; withExtendedLifetime(access) {}
        if token === request { token = nil; task = nil; if !retired { busy = false } }
    }
    func retire() { guard !retired else { return }; retired = true; token?.cancel(); task?.cancel(); ready = false; busy = false }
}

private struct FileDropTransferDialog: View {
    @ObservedObject var model: FileDropTransferModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how to transfer the selected files").font(.headline)
            HStack { Text("Destination:"); Text(model.folder.path).lineLimit(2).textSelection(.enabled); Spacer()
                Menu { ForEach(model.recentDestinations, id: \.path) { folder in Button(folder.path) { model.prepare(folder: folder) } } } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Recent destinations").disabled(!model.canEdit || model.recentDestinations.isEmpty)
                Button("…") { model.browse() }.disabled(!model.canEdit) }
            List(model.sources.map { GitReferenceName($0.path) }, id: \.self) { Text($0.rawValue).textSelection(.enabled) }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            if model.ready && !model.canMove { Text("Move requires versioned sources in this working tree.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                ForEach(model.choices, id: \.self) { choice in
                    Button { model.accept(choice) } label: { CommandLabel(title: choice.rawValue, icon: choice == .copyAdd ? .add : .rename) }.disabled(!model.canChoose(choice))
                }
                Spacer(); Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.choosingFolder || model.confirmingQuit)
            }
        }.padding(16)
    }
}
