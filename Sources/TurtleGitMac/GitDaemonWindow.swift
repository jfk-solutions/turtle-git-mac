// SPDX-License-Identifier: GPL-2.0-or-later
// Native counterpart of Commands/DaemonCommand.cpp and its ProgressDlg.
import AppKit
import SwiftUI
import TurtleGitCore

/// Producers cannot queue unlimited UI tasks while the window is busy.
private final class DaemonOutputMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data(), readinessTail = Data(), ready = false, dropped = false
    func append(_ chunk: GitOutputChunk) {
        lock.lock(); defer { lock.unlock() }
        readinessTail.append(chunk.data)
        if readinessTail.range(of: Data("Ready to rumble".utf8)) != nil { ready = true }
        readinessTail = Data(readinessTail.suffix(32))
        let available = max(0, 64 * 1024 - pending.count)
        pending.append(chunk.data.prefix(available)); dropped = dropped || chunk.data.count > available
    }
    func take() -> (Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        var bytes = pending; pending.removeAll(keepingCapacity: true)
        if dropped { bytes.append(Data("\n[Daemon output queue truncated]\n".utf8)); dropped = false }
        return (bytes, ready)
    }
}

@MainActor final class GitDaemonWindowModel: ObservableObject, ActionLogProgress {
    enum Phase { case warning, running, stopping, finished }
    static private(set) var activeOperations = 0
    static private(set) var activeQuestions = 0
    private(set) var pendingOperations=0
    var active:Bool {!retired}
    var hasPendingWork:Bool {pendingOperations>0 || confirmingCancellation}
    @Published var confirmingQuit=false

    let repository: GitRepository
    let access: RepositoryAccessLease?
    let configuration: GitDaemonConfiguration
    let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    @Published private(set) var phase = Phase.warning
    @Published var rememberWarning = false
    @Published private(set) var output = ""
    @Published private(set) var status = ""
    @Published private(set) var urls: [String] = []
    @Published private(set) var error: String?
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var completionRange: NSRange?
    @Published private(set) var confirmingCancellation = false
    var close: () -> Void = {}
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var run: @Sendable (GitRepository, GitDaemonConfiguration, OperationCancellation, @escaping @Sendable (GitOutputChunk) -> Void) throws -> Int32 = {
        try GitDaemon.run(repository: $0, configuration: $1, cancellation: $2, onOutput: $3)
    }
    private let token = OperationCancellation()
    private let mailbox = DaemonOutputMailbox()
    private let parser: GitCliOutputParser
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    private var started = false, retired = false, closeAfterStop = false
    private var question: UUID?
    private var pump: Task<Void, Never>?
    private let workerDock = UUID()
    var dockRegistry: DockProgressRegistry = .shared
    var busy: Bool { phase == .running || phase == .stopping }
    var canCancel: Bool { !confirmingQuit && !retired && !confirmingCancellation && phase != .stopping }
    var dockState: DockProgressState? {
        guard started, !retired else { return nil }
        if confirmingCancellation { return .init(.paused) }
        return .command(busy:busy, success:success, percentage:busy ? nil : 100)
    }
    var actionLogRepository: URL { repository.root }
    var actionLogFailed: Bool { !success }
    var actionLogCancelled: Bool { cancelled }
    var actionLogEligible: Bool { started && !busy }
    var command: String { (try? configuration.arguments(root: repository.root))?.map { $0.contains(" ") ? "\"" + $0 + "\"" : $0 }.joined(separator: " ") ?? "daemon" }
    init(repository: GitRepository, access: RepositoryAccessLease?, configuration: GitDaemonConfiguration = .init(), preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.configuration = configuration; self.preferences = preferences
        autoClosePolicy = GitProgressAutoClose(preferences:preferences)
        outputState = GitProgressOutputState(preferences: preferences)
        parser = GitCliOutputParser(limit: outputState.limit)
    }
    func begin() {
        guard !confirmingQuit, !started, !retired, phase == .warning else { return }
        if preferences.bool(forKey: "DaemonNoSecurityWarning") { proceed() }
    }
    func proceed() {
        guard !confirmingQuit, !started, !retired, phase == .warning else { return }
        do {
            guard !GitRuntime.isAppStoreBuild || (access?.hasSecurityScope == true && access?.contains(repository.root) == true) else { throw RepositoryAccessFailure.securityScopeUnavailable }
            _ = try configuration.arguments(root: repository.root)
        } catch {
            self.error = error.localizedDescription; status = "Git daemon failed."; phase = .finished
            output = LocalGitCommandProgress.bounded(error.localizedDescription, preferences:preferences); return
        }
        preferences.set(rememberWarning || preferences.bool(forKey: "DaemonNoSecurityWarning"), forKey: "DaemonNoSecurityWarning")
        started = true; phase = .running; status = "Starting Git daemon…"; urls = configuration.urls()
        // DaemonCommand supplies these addresses as ProgressDlg.m_PreText. Keep
        // them in the scrollable/copyable log even on hosts with many interfaces.
        parser.appendChunk(Data((urls.joined(separator:"\n") + "\n\ngit " + command + "\n\n").utf8))
        outputState.consume(parser.processPending(), parser:parser); output = outputState.output
        Self.activeOperations += 1;pendingOperations += 1
        dockRegistry.update(workerDock, .init(.running))
        let repository = repository, configuration = configuration, token = token, mailbox = mailbox, runner = run
        // Own the repository scope, Dock and Quit lease until the real process drains,
        // independently of a forced window close or a pending cancellation question.
        let access = access, began = Date()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                self?.drain()
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
        Task {
            let result = await Task.detached {
                withExtendedLifetime(access) { Result { try runner(repository, configuration, token, { mailbox.append($0) }) } }
            }.value
            defer { Self.activeOperations -= 1;pendingOperations -= 1;dockRegistry.remove(workerDock) }
            pump?.cancel(); pump = nil
            consumeMailbox(); outputState.consume(parser.finish(), parser:parser)
            let wasCancelled = token.isCancelled
            var exitCode: Int32?, failure: Error?
            switch result {
            case .success(let code):
                exitCode = code
                if code != 0 && !wasCancelled { failure = GitDaemonFailure.failed(code, "") }
            case .failure(let caught):
                failure = caught
                if let daemonFailure = caught as? GitDaemonFailure, case .failed(let code, _) = daemonFailure { exitCode = code }
            }
            let passed = !wasCancelled && failure == nil
            var text = outputState.output
            if let failure, !wasCancelled {
                // Retain the diagnostic even when the producer hit its captured limit.
                if let daemonFailure = failure as? GitDaemonFailure, case .failed(_, let detail) = daemonFailure {
                    // The runner retains a raw diagnostic tail independently of
                    // the display limit. Append it only if it was not delivered.
                    if !detail.isEmpty && Data(text.utf8).range(of:Data(detail.utf8)) == nil {
                        text = GitProgressFailureOutput.renderDetails(detail, existing:text, limit:outputState.limit, preferTail:true)
                    }
                } else { text = GitProgressFailureOutput.render(failure, existing:text, limit:outputState.limit) }
            }
            let footer = SubmoduleProgressCompletion(success:passed, cancelled:wasCancelled, exitCode:exitCode, elapsed:Date().timeIntervalSince(began), preferences:preferences)
            let range = footer.append(to:&text)
            if retired {
                ProgressActionLog.record(owner:self, repository:repository.root, output:text, cancelled:wasCancelled, failed:!passed)
                return
            }
            output = text; completionRange = range; success = passed; cancelled = wasCancelled
            error = wasCancelled ? nil : failure?.localizedDescription
            status = wasCancelled ? "Git daemon stopped." : passed ? "Git daemon exited." : "Git daemon failed."
            phase = .finished
            finishClose()
        }
    }
    private func consumeMailbox() {
        let (bytes, _) = mailbox.take()
        parser.appendChunk(bytes); outputState.consume(parser.processPending(), parser:parser)
    }
    private func drain() {
        guard !retired else { return }
        let (bytes, ready) = mailbox.take()
        parser.appendChunk(bytes); outputState.consume(parser.processPending(), parser:parser); output = outputState.output
        if ready && phase == .running { status = "Git daemon is running." }
    }
    private func finishClose() {
        guard !retired, !busy, !confirmingCancellation else { return }
        if closeAfterStop || autoClosePolicy.shouldClose(success:success, postActionCount:0) { close() }
    }
    func cancel(closeWhenStopped: Bool = false) {
        guard canCancel else { return }
        if phase == .warning { preferences.removeObject(forKey:"DaemonNoSecurityWarning"); close(); return }
        guard busy else { close(); return }
        if preferences.bool(forKey:"ConfirmKillProcess") {
            let request = UUID(); question = request; confirmingCancellation = true; Self.activeQuestions += 1
            dockRegistry.update(workerDock, .init(.paused))
            confirmCancellation { [weak self] accepted in
                guard let self, !self.retired, self.question == request else { return }
                self.question = nil; self.confirmingCancellation = false; Self.activeQuestions -= 1
                if self.busy {
                    self.dockRegistry.update(self.workerDock, .init(.running))
                    if accepted { self.stop(closeWhenStopped:closeWhenStopped) }
                }
                self.finishClose()
            }
        } else { stop(closeWhenStopped:closeWhenStopped) }
    }
    private func stop(closeWhenStopped: Bool) {
        closeAfterStop = closeAfterStop || closeWhenStopped
        phase = .stopping; status = "Stopping Git daemon…"; token.cancel()
    }
    func retire() {
        guard !retired else { return }
        retired = true
        if question != nil { question = nil; confirmingCancellation = false; Self.activeQuestions -= 1 }
        if !busy { saveActionLog() }
        token.cancel(); pump?.cancel(); pump = nil
    }
}

@MainActor final class GitDaemonWindowController: NSWindowController, NSWindowDelegate {
    let model: GitDaemonWindowModel
    var onClosed: () -> Void = {}
    private var retired=false,releasing=false
    private var question:NSAlert?
    private var answer:((Bool)->Void)?
    var canReuse:Bool {!retired && model.active && !model.confirmingQuit}
    var hasPendingWork:Bool {releasing || model.hasPendingWork || question?.window.sheetParent != nil || window?.attachedSheet != nil}

    init(repository: GitRepository, access: RepositoryAccessLease?, configuration: GitDaemonConfiguration = .init(), preferences: UserDefaults = .standard) {
        model = GitDaemonWindowModel(repository: repository, access: access, configuration: configuration, preferences: preferences)
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Daemon", preferences: preferences)
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 620, height: 380)
        window.contentViewController = NSHostingController(rootView: GitDaemonDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, !self.model.confirmingCancellation, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        window.escapeAction = { [weak model] in model?.cancel() }
        model.confirmCancellation = { [weak self,weak window] choose in
            guard let self,self.canReuse,let window,window.attachedSheet==nil else{choose(false);return}
            let alert=NSAlert();alert.alertStyle = .informational
            alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?"
            let yes=alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No")
            yes.keyEquivalent="\r";alert.window.defaultButtonCell=yes.cell as? NSButtonCell
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
            var answered=false
            let reply:(Bool)->Void={ [weak self] accepted in
                guard !answered else{return};answered=true
                if self?.question === alert {self?.question=nil;self?.answer=nil}
                choose(self?.canReuse == true && accepted)
            }
            self.question=alert;self.answer=reply
            alert.beginSheetModal(for:window){reply($0 == .alertFirstButtonReturn)}
        }
        DialogGeometry.attach(window, identifier: "DaemonProgressDialog", legacyName: "DaemonProgressDialog")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canReuse else{return false}
        if model.busy { model.cancel(closeWhenStopped: true); return false }
        guard !model.confirmingCancellation, sender.attachedSheet == nil else { return false }
        if model.phase == .warning { model.preferences.removeObject(forKey: "DaemonNoSecurityWarning") }
        return true
    }
    func windowWillClose(_ notification:Notification) {
        guard !retired else{return};retired=true;model.retire()
        let sheet=question?.window ?? window?.attachedSheet,reply=answer
        question=nil;answer=nil
        if let sheet {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)}
        reply?(false);releasing=true
        let release=FinderFilesystemWorkflowRelease(ready:{ [self,sheet] in !model.hasPendingWork && sheet?.sheetParent==nil },completion:{ [self] in releasing=false;let finish=onClosed;onClosed={};finish() });release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct GitDaemonDialog: View {
    @ObservedObject var model: GitDaemonWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daemon").font(.headline)
            Text(model.repository.root.path).textSelection(.enabled).foregroundStyle(.secondary)
            if model.phase == .warning {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.largeTitle)
                    Text("While running daemon, all data of this repository is exposed without authentication and/or encryption.")
                }
                Toggle("Do not show this warning again", isOn: $model.rememberWarning)
                Spacer()
                HStack { Spacer(); Button("Abort") { model.cancel() }.keyboardShortcut(.cancelAction); Button("Proceed") { model.proceed() }.keyboardShortcut(.defaultAction) }
            } else {
                SubmoduleProgressOutputView(text:model.output, completed:model.phase == .finished,
                    completionRange:model.completionRange, success:model.success, preferences:model.preferences)
                    .frame(maxWidth:.infinity, maxHeight:.infinity)
                HStack {
                    if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                    Text(model.status).foregroundStyle(model.error == nil ? Color.primary : Color.red).textSelection(.enabled)
                    Spacer()
                    Button(model.busy ? "Cancel" : "Close") { model.cancel() }.disabled(!model.canCancel).keyboardShortcut(.cancelAction)
                }
            }
        }.padding(16).frame(minWidth: 600, minHeight: 360).gitDockProgress(model.dockState)
    }
}
