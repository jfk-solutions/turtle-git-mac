import AppKit
import SwiftUI
import TurtleGitCore

struct CleanDialogRequest {
    let options: CleanOptions
    let paths: [String]
    let dryRun: Bool
    let submodules: Bool
    let permanently: Bool
}

@MainActor final class CleanWindowModel: ObservableObject {
    let repository: GitRepository
    private let defaults: UserDefaults
    private let typeKey: String
    private let directoryKey: String
    private var paths: [String] = []
    @Published var options: CleanOptions
    @Published var dryRun = false
    @Published var submodules = false
    @Published var permanently: Bool
    @Published var error: String?
    var close: () -> Void = {}
    var onAccepted: (CleanDialogRequest) -> Void = { _ in }
    init(repository: GitRepository, defaults: UserDefaults = .standard) {
        self.repository = repository; self.defaults = defaults
        let path = repository.root.standardizedFileURL.path
        typeKey = "History.CleanType." + path; directoryKey = "History.CleanDir." + path
        let type = CleanType(rawValue: defaults.integer(forKey: typeKey)) ?? .all
        let directories = defaults.object(forKey: directoryKey) == nil || defaults.bool(forKey: directoryKey)
        options = CleanOptions(type: type, directories: directories)
        permanently = defaults.object(forKey: "RevertWithRecycleBin") != nil && !defaults.bool(forKey: "RevertWithRecycleBin")
    }
    func setScope(_ paths: [String]) { self.paths = paths }
    /// Validate before translating files to parent folders: an invalid path must
    /// never become an empty path and silently widen cleanup to the whole tree.
    func directoryScopes() throws -> [String] {
        guard paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains(where: { $0 == ".." || $0 == ".git" }) }) else { throw CleanFailure.path }
        var result: [String] = []
        for path in paths {
            let normalized = path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
            if normalized.isEmpty { return [] }
            let location = repository.root.appendingPathComponent(normalized)
            let type = (try? FileManager.default.attributesOfItem(atPath: location.path)[.type]) as? FileAttributeType
            let scope = type == .typeDirectory ? normalized : (normalized as NSString).deletingLastPathComponent
            if scope.isEmpty { return [] }
            if !result.contains(scope) { result.append(scope) }
        }
        return result
    }
    func accept() {
        do {
            let scopes = try directoryScopes()
            defaults.set(options.type.rawValue, forKey: typeKey); defaults.set(options.directories, forKey: directoryKey)
            let request = CleanDialogRequest(options: options, paths: scopes, dryRun: dryRun, submodules: submodules, permanently: permanently)
            onAccepted(request); close()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class CleanWindowController: NSWindowController, NSWindowDelegate {
    let model: CleanWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, defaults: UserDefaults = .standard) {
        model = CleanWindowModel(repository: repository, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Clean – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CleanDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { onClosed() }
}

private struct CleanDialog: View {
    @ObservedObject var model: CleanWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Clean Type") {
                Picker("Clean Type", selection: $model.options.type) {
                    Text("Remove all untracked files (-fx)").tag(CleanType.all)
                    Text("Remove non-ignored untracked files (-f)").tag(CleanType.nonIgnored)
                    Text("Remove ignored files (-fX)").tag(CleanType.ignored)
                }.pickerStyle(.radioGroup).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Remove untracked directories (-d)", isOn: $model.options.directories)
            Toggle("Remove unmanaged directories with .git folder (-f)", isOn: $model.options.unmanagedRepositories).padding(.leading, 16).disabled(!model.options.directories)
            Toggle("Do not use Trash", isOn: $model.permanently)
            Toggle("Dry run", isOn: $model.dryRun)
            Toggle("Submodules", isOn: $model.submodules)
            Text("Attention: This command affects the whole working tree!").font(.callout).foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("OK") { model.accept() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-cleanup.html")!) }
            }
        }.padding(12)
        .alert("Clean failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

@MainActor final class CleanProgressWindowModel: ObservableObject {
    private let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let request: CleanDialogRequest
    private var cancellation: OperationCancellation?
    private var started = false
    private var lastPreviewOnly = false
    private var lastPermanent = false
    @Published var busy = false
    @Published var cancelRequested = false
    @Published var failed = false
    @Published var previewSucceeded = false
    @Published var output = ""
    @Published var current = "Preparing Clean…"
    @Published var trashedFiles: [URL] = []
    var close: () -> Void = {}
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var permanentFirst: Bool { request.permanently }
    init(repository: GitRepository, access: RepositoryAccessLease?, request: CleanDialogRequest) {
        self.repository = repository; self.access = access; self.request = request
    }
    func start() { guard !started else { return }; started = true; run(previewOnly: request.dryRun, permanently: request.permanently) }
    func retry() { guard failed else { return }; run(previewOnly: lastPreviewOnly, permanently: lastPermanent) }
    func remove(permanently: Bool) { guard previewSucceeded else { return }; run(previewOnly: false, permanently: permanently) }
    func cancel() { guard busy else { return }; cancelRequested = true; cancellation?.cancel(); current = "Cancelling…" }
    private func run(previewOnly: Bool, permanently: Bool) {
        guard !busy else { return }
        lastPreviewOnly = previewOnly; lastPermanent = permanently
        busy = true; failed = false; previewSucceeded = false; cancelRequested = false; output = ""; trashedFiles = []
        current = previewOnly ? "Previewing cleanup…" : permanently ? "Removing files…" : "Moving files to Trash…"
        let cancellation = OperationCancellation(); self.cancellation = cancellation
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let plan = try await repository.cleanBatchPreview(options: request.options, paths: request.paths, includeSubmodules: request.submodules, cancellation: cancellation)
                if GitRuntime.isAppStoreBuild && !plan.repositories.allSatisfy({ item in item.requiredAccess.allSatisfy { access?.contains($0) == true } }) { throw RepositoryAccessFailure.securityScopeUnavailable }
                output = plan.repositories.map { $0.repository.path + "\n" + String(decoding: $0.preview.output, as: UTF8.self) }.joined(separator: "\n")
                if previewOnly { previewSucceeded = true; current = "Dry run finished" }
                else {
                    let results = try await repository.executeCleanBatch(plan, permanently: permanently, cancellation: cancellation)
                    trashedFiles = results.flatMap { $0.result.trashedFiles }
                    output += "\n" + results.flatMap { item in item.result.removedPaths.map { "Removed: " + item.repository.appendingPathComponent($0).path } }.joined(separator: "\n")
                    if !trashedFiles.isEmpty { output += "\nRecoverable Trash items:\n" + trashedFiles.map(\.path).joined(separator: "\n") }
                    current = "Finished"
                }
                busy = false; self.cancellation = nil; onFinished(output, !previewOnly)
            } catch {
                if let failure = error as? CleanBatchExecutionFailure {
                    trashedFiles = failure.completed.flatMap { $0.result.trashedFiles } + (failure.partial?.trashedFiles ?? [])
                }
                failed = true; current = cancelRequested || error is OperationCancellationFailure ? "Cancelled" : "Clean failed"
                output += "\n" + error.localizedDescription
                busy = false; self.cancellation = nil; onFinished(output, !previewOnly)
            }
        }
    }
}

@MainActor final class CleanProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: CleanProgressWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, request: CleanDialogRequest) {
        model = CleanProgressWindowModel(repository: repository, access: access, request: request)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Clean Progress – TurtleGit"
        window.contentMinSize = NSSize(width: 650, height: 330); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CleanProgressDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self, weak window] in if self?.model.busy == true { self?.model.cancel() } else { window?.close() } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return true }
    func windowWillClose(_ notification: Notification) { onClosed() }
}

private struct CleanProgressDialog: View {
    @ObservedObject var model: CleanProgressWindowModel
    var body: some View {
        VStack(spacing: 12) {
            OutputView(text: model.output)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.current).foregroundStyle(model.failed ? Color.red : Color.primary)
                Spacer()
                if model.failed { Button("Retry") { model.retry() }.disabled(model.busy) }
                if model.previewSucceeded {
                    if model.permanentFirst { permanentButton; trashButton } else { trashButton; permanentButton }
                }
                if !model.trashedFiles.isEmpty { Button("Show in Trash") { NSWorkspace.shared.activateFileViewerSelecting(model.trashedFiles) } }
                Button(model.busy ? "Cancel" : "Close") { model.close() }.keyboardShortcut(.cancelAction)
            }
        }.padding(12)
    }
    private var trashButton: some View { Button("Move to Trash") { model.remove(permanently: false) } }
    private var permanentButton: some View { Button("Delete permanently") { model.remove(permanently: true) } }
}
