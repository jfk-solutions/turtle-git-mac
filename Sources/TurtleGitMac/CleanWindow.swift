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
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let request: CleanDialogRequest
    private var cancellation: OperationCancellation?
    private var started = false
    private var invalidated = false
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var lastPreviewOnly = false
    private var lastPermanent = false
    @Published var busy = false
    @Published private(set) var confirmingCancellation = false
    @Published var cancelRequested = false
    @Published var failed = false
    @Published var previewSucceeded = false
    @Published var output = ""
    @Published var completed = 0
    @Published var total = 0
    @Published var current = "Preparing Clean…"
    @Published var trashedFiles: [URL] = []
    var close: () -> Void = {}
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var permanentFirst: Bool { request.permanently }
    var canCancel: Bool { busy && !cancelRequested && !confirmingCancellation && !invalidated }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var postActions: [CleanPostAction] {
        if failed { return [.retry] }
        if previewSucceeded { return permanentFirst ? [.permanent, .trash] : [.trash, .permanent] }
        return []
    }
    func invalidate() { invalidated = true }
    init(repository: GitRepository, access: RepositoryAccessLease?, request: CleanDialogRequest, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.request = request; self.preferences = preferences; autoClosePolicy = GitProgressAutoClose(preferences: preferences)
    }
    func start() { guard !started, !invalidated else { return }; started = true; run(previewOnly: request.dryRun, permanently: request.permanently) }
    func retry() { guard failed, !confirmingCancellation, !invalidated else { return }; ProgressActionLog.nextAttempt(self); run(previewOnly: lastPreviewOnly, permanently: lastPermanent) }
    func remove(permanently: Bool) { guard previewSucceeded, !confirmingCancellation, !invalidated else { return }; ProgressActionLog.nextAttempt(self); run(previewOnly: false, permanently: permanently) }
    func perform(_ action: CleanPostAction) {
        guard !busy, !confirmingCancellation, !invalidated, postActions.contains(action) else { return }
        switch action { case .retry: retry(); case .trash: remove(permanently: false); case .permanent: remove(permanently: true) }
    }
    func cancel() {
        guard canCancel, let token = cancellation else { return }
        if (lastPreviewOnly || lastPermanent) && preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, self.confirmingCancellation, !self.invalidated else { return }; self.confirmingCancellation = false
                if self.busy, self.cancellation === token, accepted { self.stop(token) }
                self.finishAutomaticClose()
            }
        } else { stop(token) }
    }
    private func stop(_ token: OperationCancellation) { cancelRequested = true; token.cancel(); current = "Cancelling…" }
    private func finishAutomaticClose() {
        // Trash uses CSysProgressDlg upstream and ends on successful completion.
        // Git progress settings apply only to dry runs and permanent removal.
        guard !busy, !confirmingCancellation, !invalidated, !failed else { return }
        if !lastPreviewOnly && !lastPermanent || autoClosePolicy.shouldClose(success: true, postActionCount: postActions.count) { close() }
    }
    private func run(previewOnly: Bool, permanently: Bool) {
        guard !busy, !confirmingCancellation, !invalidated else { return }
        lastPreviewOnly = previewOnly; lastPermanent = permanently
        busy = true; failed = false; previewSucceeded = false; cancelRequested = false; output = ""; trashedFiles = []
        completed = 0; total = 0
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
                    total = plan.repositories.reduce(0) { $0 + $1.preview.candidates.count }
                    current = "Checking cleanup candidates…"
                    let (stream, continuation) = AsyncStream<CleanProgress>.makeStream()
                    let operation = Task {
                        defer { continuation.finish() }
                        return try await repository.executeCleanBatch(plan, permanently: permanently, cancellation: cancellation) { continuation.yield($0) }
                    }
                    for await event in stream {
                        completed = event.completed; total = event.total
                        if !cancelRequested { current = (permanently ? "Deleting: " : "Moving to Trash: ") + event.repository.appendingPathComponent(event.path).path }
                        if event.finished { output += "\nRemoved: " + event.repository.appendingPathComponent(event.path).path }
                    }
                    let results = try await operation.value
                    trashedFiles = results.flatMap { $0.result.trashedFiles }
                    output += "\n\(completed) item(s) cleaned."
                    if !trashedFiles.isEmpty { output += "\nRecoverable Trash items:\n" + trashedFiles.map(\.path).joined(separator: "\n") }
                    current = "Finished"
                }
                busy = false; self.cancellation = nil; onFinished(output, !previewOnly); finishAutomaticClose()
            } catch {
                if let failure = error as? CleanBatchExecutionFailure {
                    trashedFiles = failure.completed.flatMap { $0.result.trashedFiles } + (failure.partial?.trashedFiles ?? [])
                }
                failed = true; current = cancelRequested || error is OperationCancellationFailure ? "Cancelled" : "Clean failed"
                output += "\n" + error.localizedDescription
                busy = false; self.cancellation = nil; onFinished(output, !previewOnly); finishAutomaticClose()
            }
        }
    }
}

@MainActor final class CleanProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: CleanProgressWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, request: CleanDialogRequest, preferences: UserDefaults = .standard) {
        model = CleanProgressWindowModel(repository: repository, access: access, request: request, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Clean Progress – TurtleGit"
        window.contentMinSize = NSSize(width: 650, height: 330); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CleanProgressDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self, weak window] in
            guard let self, !self.model.confirmingCancellation, window?.attachedSheet == nil else { return }
            if self.model.busy { self.model.cancel() } else { window?.close() }
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.confirmingCancellation && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.saveActionLog(); model.invalidate(); onClosed() }
}

enum CleanPostAction: String, Hashable {
    case retry, trash, permanent
    var title: String { switch self { case .retry: return "Retry"; case .trash: return "Move to Trash"; case .permanent: return "Delete permanently" } }
    var icon: MenuIcon { switch self { case .retry: return .refresh; case .trash: return .clean; case .permanent: return .remove } }
}

struct CleanProgressDialog: View {
    @ObservedObject var model: CleanProgressWindowModel
    var body: some View {
        VStack(spacing: 12) {
            OutputView(text: model.output)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.current).lineLimit(1).help(model.current).foregroundStyle(model.failed ? Color.red : Color.primary)
                Spacer()
                if model.total > 0 { ProgressView(value: Double(model.completed), total: Double(model.total)).frame(width: 120); Text("\(model.completed)/\(model.total)").monospacedDigit() }
                if let first = model.postActions.first {
                    Button { model.perform(first) } label: { CommandLabel(title: first.title, icon: first.icon) }
                    Menu { ForEach(model.postActions, id: \.self) { action in Button { model.perform(action) } label: { CommandLabel(title: action.title, icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Clean post-actions") }.menuStyle(.borderlessButton).fixedSize()
                }
                if !model.trashedFiles.isEmpty { Button("Show in Trash") { NSWorkspace.shared.activateFileViewerSelecting(model.trashedFiles) } }
                Button(model.busy ? model.cancelRequested ? "Cancelling…" : "Cancel" : "Close") { model.close() }.keyboardShortcut(.cancelAction).disabled(model.busy && !model.canCancel)
            }.disabled(model.confirmingCancellation)
        }.padding(12)
    }
}
