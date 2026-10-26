import AppKit
import SwiftUI
import TurtleGitCore

enum WorkingFileRevertPresentation {
    static func disposition(_ policy:WorkingFileRevertPolicy)->String {
        if !policy.recycle {return "Replaced working contents will not be saved to Trash. This cannot be undone."}
        if !policy.recycleRenamedFiles {return "Replaced working contents move to Trash, except renamed files. Replaced contents of renamed files will not be saved."}
        return "Existing replaced file contents are moved to Trash."
    }
    static func confirmation(_ policy:WorkingFileRevertPolicy)->String {
        disposition(policy)+" "+"Added files remain on disk as unversioned files."
    }
    static func cancellation(_ policy:WorkingFileRevertPolicy)->String {
        "Stop Revert after its current filesystem or Git step? Completed working-file changes remain. "+disposition(policy)
    }
}

private final class RevertProgressNativeWindow: NSWindow {
    var escape: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "\u{1b}" { escape(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class RevertProgressWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var activeReleases=0
    let model: RevertProgressWindowModel
    let progressFiles:FileOperationProgressFiles
    var onProgressLog:(String)->Void = {_ in}
    private var closed=false,finishing=false
    private var handoff:((Bool)->Void)?
    var presentQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool = {window,alert,reply in guard window.attachedSheet==nil else{return false};alert.beginSheetModal(for:window,completionHandler:reply);return true}
    var onClosed: () -> Void = {}
    private var question: (UUID, NSAlert, (Bool) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool, againstHead: Bool, autoCloseSuccess: Bool, preferences: UserDefaults = .standard, policy: WorkingFileRevertPolicy? = nil) {
        model = RevertProgressWindowModel(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: autoCloseSuccess, preferences: preferences, policy: policy)
        progressFiles=FileOperationProgressFiles(repository:repository,access:access)
        let window = RevertProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 550), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Revert Progress", preferences: preferences)
        window.contentMinSize = NSSize(width: 800, height: 410); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RevertProgressDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 550)); window.center()
        model.close = { [weak self] in self?.finish() }
        model.finishAndPerform = { [weak self] reply in guard let self else {reply(false);return};self.finish(reply) }
        progressFiles.window=window
        progressFiles.available={ [weak model] in model?.progressOwnerAvailable==true }
        progressFiles.onBusy={ [weak model] in model?.fileActionBusy=$0 }
        progressFiles.onLog={ [weak self] in self?.onProgressLog($0) }
        progressFiles.onError={ [weak model] in model?.information=$0 }
        model.onProgressFileAction={ [weak self] action,path in self?.progressFiles.perform(action,path:path) }
        model.revealSavedCopies={ [weak self] in self?.progressFiles.reveal($0) }
        model.confirmCancellation = { [weak self] in await self?.askCancellation() ?? false }
        window.escape = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }

        DialogGeometry.attach(window, identifier: "RevertProgressDialog", legacyName: "RevertProgressDialog")
    }
    private func askCancellation() async -> Bool {
        guard !model.retired, question == nil, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = "The operation is still running."; alert.informativeText = WorkingFileRevertPresentation.cancellation(model.policy); alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        let id = UUID()
        return await withCheckedContinuation { continuation in
            question = (id, alert, { continuation.resume(returning: $0) })
            if !presentQuestion(window,alert,{ [weak self] response in self?.finishQuestion(id,accepted:response == .alertFirstButtonReturn) }) {finishQuestion(id,accepted:false)}
        }
    }
    private func finishQuestion(_ id: UUID, accepted: Bool) {
        guard let pending = question, pending.0 == id else { return }; question = nil
        Task {await FileOperationWindowDrain.detach(pending.1.window);pending.2(accepted)}
    }
    private func finish(_ reply:((Bool)->Void)?=nil) {
        guard !closed,!finishing,model.progressActionsAvailable,window?.attachedSheet==nil else {reply?(false);return}
        finishing=true;handoff=reply;window?.orderOut(nil);close()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if model.busy {model.cancel();return false}
        guard model.progressActionsAvailable,sender.attachedSheet==nil else{return false};finish();return false
    }
    override func close(){super.close();retireClosedWindow()}
    func windowWillClose(_ notification:Notification){retireClosedWindow()}
    private func retireClosedWindow() {
        guard !closed else{return};closed=true
        let accepted=finishing,reply=handoff,sheet=window?.attachedSheet;handoff=nil
        model.retire();progressFiles.retire();if let pending=question{finishQuestion(pending.0,accepted:false)}
        Self.activeReleases += 1
        Task { [self] in
            defer {Self.activeReleases -= 1}
            if let sheet {await FileOperationWindowDrain.detach(sheet)}
            if let window {await FileOperationWindowDrain.detach(window)}
            while model.busy || model.confirmingCancellation || progressFiles.busy {try? await Task.sleep(nanoseconds:5_000_000)}
            onClosed();reply?(accepted && !model.confirmingQuit && model.externalAvailability())
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct RevertProgressRow: Identifiable {
    let id = UUID()
    let action: String
    let path: String
    var status: String
}

@MainActor final class RevertProgressWindowModel: ObservableObject, ActionLogProgress {
    let progress:FileOperationProgressState
    let progressPresentation: GitCommandPresentation
    static private(set) var activeOperations = 0
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let entries: [StatusEntry]
    private let amend: Bool
    private let againstHead: Bool
    private let autoCloseSuccess: Bool
    let preferences: UserDefaults
    let policy: WorkingFileRevertPolicy
    private let autoClosePolicy: GitProgressAutoClose
    private var cancellation: OperationCancellation?
    private var started = false
    private(set) var retired = false
    private var completedSuccessfully = false
    private var rowIndices: GitPathMap<Int> = [:]
    @Published fileprivate var rows: [RevertProgressRow] = []
    var externalAvailability:()->Bool = {true}
    @Published var confirmingQuit=false
    @Published var fileActionBusy=false
    @Published private(set) var handoffPending=false
    var progressOwnerAvailable:Bool {!busy && !retired && !confirmingQuit && !confirmingCancellation && !handoffPending && externalAvailability()}
    var progressActionsAvailable:Bool {progressOwnerAvailable && !busy && !fileActionBusy}
    var onProgressFileAction:(FileOperationProgressAction,String)->Void = {_,_ in}
    var finishAndPerform:((@escaping(Bool)->Void)->Void) = {$0(false)}
    var revealSavedCopies:([URL])->Void = {NSWorkspace.shared.activateFileViewerSelecting($0)}
    @Published var busy = true
    @Published private(set) var confirmingCancellation = false
    @Published var cancelRequested = false
    @Published var completed = 0
    @Published var total = 0
    @Published var current = "Preparing Revert…"
    @Published var information = ""
    @Published var commandOutput = ""
    @Published var failed = false
    @Published var cancelled = false
    @Published var trashedFiles: [URL] = []
    @Published var submodulePaths: [String] = []
    private var comparisonRevision: String?
    var confirmCancellation: () async -> Bool = { false }
    var onHandleSubmodules: (String, [String]) -> Void = { _, _ in }
    var close: () -> Void = {}
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var execute: (([StatusEntry], OperationCancellation, @escaping @Sendable (WorkingFileRevertProgress) -> Void, @escaping @Sendable (GitOutputChunk) -> Void) async throws -> WorkingFileRevertResult)?
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool, againstHead: Bool, autoCloseSuccess: Bool, preferences: UserDefaults = .standard, policy: WorkingFileRevertPolicy? = nil) {
        self.policy=policy ?? WorkingFileRevertPolicy.load(from:preferences)
        progress=FileOperationProgressState(preferences:preferences)
        self.repository = repository; self.access = access; self.entries = entries; self.amend = amend; self.againstHead = againstHead; self.autoCloseSuccess = autoCloseSuccess; self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences); autoClosePolicy = GitProgressAutoClose(preferences: preferences)
    }
    func retire() { guard !retired else { return }; if busy { cancelled = true }; saveActionLog(); retired = true; progress.retire();cancellation?.cancel();if !started {busy=false} }
    func cancel() {
        guard !retired, busy, !cancelRequested, !confirmingCancellation, let request = cancellation else { return }
        if !preferences.bool(forKey: "ConfirmKillProcess") { stop(request); return }
        confirmingCancellation = true; Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1 }
            let accepted = await confirmCancellation()
            confirmingCancellation = false;guard !retired else { return }
            if busy, cancellation === request, accepted { stop(request) }
            finishAutomaticClose()
        }
    }
    private func stop(_ request: OperationCancellation) { cancelRequested = true; request.cancel(); current = "Cancelling after the current operation…" }
    private func receive(_ event: WorkingFileRevertProgress, request: OperationCancellation) {
        guard !retired, cancellation === request else { return }
        let key = event.step.rawValue + "\0" + event.path
        if let index = rowIndices[key] { rows[index].status = event.finished ? "Completed" : "In progress" }
        else { rowIndices[key] = rows.count; rows.append(RevertProgressRow(action: event.step.rawValue, path: event.path, status: event.finished ? "Completed" : "In progress")) }
        if let index=rowIndices[key] {let row=rows[index];progress.record(id:row.id,action:row.action,path:row.path,status:row.status)}
        completed = event.completed; total = event.total
        if !cancelRequested { current = event.step.rawValue + ": " + event.path }
    }
    func start() { guard !started, !retired else { return }; started = true; run(refreshSelection: false) }
    func retry() { guard progressActionsAvailable, failed || cancelled else { return }; run(refreshSelection: true) }
    private func run(refreshSelection: Bool) {
        let attemptStarted=Date()
        progress.begin("Revert")
        ProgressActionLog.nextAttempt(self); let request = OperationCancellation(); cancellation = request; busy = true; cancelRequested = false; failed = false; cancelled = false; completedSuccessfully = false; information = ""; commandOutput = ""; rows = []; rowIndices = [:]; completed = 0; total = 0; current = refreshSelection ? "Refreshing selected paths…" : "Preparing Revert…"; submodulePaths = []
        Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1; withExtendedLifetime(access) {}; if cancellation === request { cancellation = nil;busy=false; if !retired {progress.finish(success:completedSuccessfully,cancelled:cancelled,started:attemptStarted);saveActionLog(); finishAutomaticClose() } } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let selected = refreshSelection ? try await repository.workingFileRevertSelection(entries, amend: amend, againstHead: againstHead, cancellation: request) : entries
                try request.check(); guard !retired else { return }
                let (stream, continuation) = AsyncStream<WorkingFileRevertProgress>.makeStream()
                let operation = Task { [self] in
                    defer { continuation.finish() }
                    return try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] progress in guard let self, !self.retired, self.cancellation === request else { return }; self.commandOutput = progress.output }, resultText: { _ in "" }) { [self] emit in
                        if let execute { return try await execute(selected, request, { continuation.yield($0) }, emit) }
                        return try await repository.revertWorkingFiles(selected, amend: amend, amendDiffToLastCommit: againstHead, policy: policy, cancellation: request, progress: { continuation.yield($0) }, onOutput: emit)
                    }
                }
                for await event in stream { receive(event, request: request) }
                let result = try await operation.value
                guard !retired, cancellation === request else { return }
                submodulePaths = result.submodulePaths; comparisonRevision = result.comparisonRevision; retainCopies(result.trashedFiles)
                information = "\(result.revertedPaths.count) file(s) reverted."; current = "Finished"; completedSuccessfully = true
                onFinished((trashedFiles.map { "Moved to Trash: " + $0.path } + [information]).joined(separator: "\n"), true)
            } catch {
                guard !retired, cancellation === request else { return }
                let failure = error as? WorkingFileRevertFailure
                cancelled = failure?.wasCancelled == true || request.isCancelled || error is OperationCancellationFailure
                failed = !cancelled; retainCopies(failure?.trashedFiles ?? [])
                current = cancelled ? "Cancelled" : "Revert failed"; information = error.localizedDescription
                if cancelled { information += "\n\nEarlier working-file changes remain; review current status before retrying." }
                commandOutput = LocalGitCommandProgress.failure(error, existing: commandOutput, preferences: preferences)
                for index in rows.indices where rows[index].status == "In progress" { rows[index].status = cancelled ? "Cancelled" : "Failed";let row=rows[index];progress.record(id:row.id,action:row.action,path:row.path,status:row.status) }
                onFinished(information, false)
            }
        }
    }
    private func retainCopies(_ urls: [URL]) { var seen = GitPathSet(trashedFiles.map(\.path)); trashedFiles += urls.filter { seen.insert($0.path).inserted } }
    private func finishAutomaticClose() {
        guard progressActionsAvailable, completedSuccessfully else { return }
        if autoCloseSuccess && submodulePaths.isEmpty || autoClosePolicy.shouldClose(success: true, postActionCount: submodulePaths.isEmpty ? 0 : 1) { close() }
    }
    func handleSubmodules() {
        guard progressActionsAvailable,!failed,!cancelled,!submodulePaths.isEmpty,let revision=comparisonRevision else{return}
        let paths=submodulePaths,callback=onHandleSubmodules
        saveActionLog()
        // The controller validates and drains the closing result before handing off.
        finishAndPerform {accepted in if accepted {callback(revision,paths)}}
    }
    func revealCopies() {guard progressActionsAvailable,!trashedFiles.isEmpty else{return};revealSavedCopies(trashedFiles)}
    var clipboardOutput:String {rows.map{[$0.action,$0.path].joined(separator:"\t")}.joined(separator:"\n")+"\n\n"+commandOutput+"\n"+information+"\n"+trashedFiles.map{"Moved to Trash: "+$0.path}.joined(separator:"\n")}
    func copyOutput() {guard progressActionsAvailable else{return};progress.publishClipboard(clipboardOutput)}
    var output: String { clipboardOutput }
    var actionLogRepository: URL { repository.root }
    var actionLogEligible: Bool { started && (!rows.isEmpty || !information.isEmpty || !commandOutput.isEmpty) }
    var actionLogFailed: Bool { failed }
    var actionLogCancelled: Bool { cancelled }
}

private struct RevertProgressDialog: View {
    @ObservedObject var model: RevertProgressWindowModel
    var body: some View {
        VStack(spacing: 10) {
            RevertProgressTable(model:model)
            HStack {
                Text(model.current).lineLimit(1).help(model.current).foregroundStyle(model.failed ? Color.red : model.cancelled ? Color.orange : Color.primary)
                Spacer()
                if model.total > 0 { ProgressView(value: Double(model.completed), total: Double(model.total)).frame(width: 230) }
                else if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
            }
            if !model.commandOutput.isEmpty { SubmoduleProgressOutputView(text: model.commandOutput, completed: !model.busy, success: !model.failed && !model.cancelled, preferences: model.preferences).frame(height: 90) }
            if !model.information.isEmpty {
                ScrollView { Text(model.information).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(model.failed ? Color.red : Color.primary) }.frame(maxHeight: 110)
            }
            HStack {
                if !model.trashedFiles.isEmpty { Button { model.revealCopies() } label: { CommandLabel(title: "Show saved copies in Finder", icon: .explore) }.disabled(!model.progressActionsAvailable) }
                if !model.busy && !model.failed && !model.cancelled && !model.submodulePaths.isEmpty {
                    Button { model.handleSubmodules() } label: { CommandLabel(title: "Handle submodules", icon: .compare) }.disabled(!model.progressActionsAvailable)
                }
                if !model.busy && (model.failed || model.cancelled) { Button { model.retry() } label: { CommandLabel(title: "Retry", icon: .refresh) }.disabled(!model.progressActionsAvailable) }
                Button {model.copyOutput()} label:{CommandLabel(title:"Copy Output",icon:.copy)}.disabled(!model.progressActionsAvailable)
                Spacer()
                if model.total > 0 { Text("\(model.completed) / \(model.total) operations").font(.caption).foregroundStyle(.secondary) }
                Button("OK") { model.close() }.keyboardShortcut(.defaultAction).disabled(!model.progressActionsAvailable)
                Button("Cancel") { model.cancel() }.disabled(!model.busy || model.cancelRequested || model.confirmingCancellation)
            }
        }.padding(12)
    }
}

/// Use the same notification actions and attempt receipts as Add and Resolve.
struct RevertProgressTable:View {
    @ObservedObject var model:RevertProgressWindowModel
    var body:some View {
        FileOperationProgressTable(state:model.progress,icon:.revert,available:model.progressActionsAvailable,repository:model.repository.root,keyboardAvailable:model.progressActionsAvailable,fileRowIcons:true,actionAvailability:{model.progressActionsAvailable},perform:model.onProgressFileAction)
    }
}
