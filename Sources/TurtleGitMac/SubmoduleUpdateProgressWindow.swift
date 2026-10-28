// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleUpdateProgressWindowController: NSWindowController, NSWindowDelegate {
    var commandProgressScope: CommandProgressScope? { model.commandProgressScope }
    let model: SubmoduleUpdateProgressWindowModel
    var onClosed: () -> Void = {}
    static var activeChildReleases: Int { SubmoduleUpdateProgressRelease.activeCount }
    private var pendingHandoff: (() -> Void)?
    private var parent: NSWindow?
    private var release: SubmoduleUpdateProgressRelease?
    private var finished = false
    private var retiringChildren:[NSWindow]=[]
    private let question=SubmoduleServiceQuestion()
    var presentQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool {get{question.presentQuestion}set{question.presentQuestion=newValue}}
    var finderServiceCanPresent:Bool {!finished && !model.isRetired}
    private var underlyingWorkPending:Bool {model.pendingOperations>0 || question.hasPendingWork || window?.sheetParent != nil || window?.attachedSheet != nil || retiringChildren.contains{$0.sheetParent != nil || $0.attachedSheet != nil}}
    var finderServiceWorkPending:Bool {release != nil || underlyingWorkPending}
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, preferences: UserDefaults = .standard) {
        model = SubmoduleUpdateProgressWindowModel(repository: repository, access: access, paths: paths, options: options, preferences: preferences)
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Submodule Update", preferences: preferences); window.contentMinSize = NSSize(width: 600, height: 320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleUpdateProgressDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in
            guard let self,!self.model.activeOperation,self.window?.attachedSheet == nil else{return}
            self.parent=self.window?.sheetParent;self.window?.close()
        }
        model.presentationAvailable = { [weak window] in window != nil && window?.attachedSheet == nil }
        model.closeForHandoff = { [weak self] action in
            guard let self,!self.finished,self.pendingHandoff == nil else{return}
            self.pendingHandoff=action;self.model.close()
        }
        window.escapeAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }
        model.confirmCancellation={ [weak self] choose in guard let self else{choose(false);return};self.question.ask(owner:self.window,choose:choose) }
        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.activeOperation && sender.attachedSheet == nil }
    func windowWillClose(_ notification:Notification){
        guard notification.object as? NSWindow === window,!finished else{return};finished=true
        if let child=window?.attachedSheet{retiringChildren.append(child)}
        model.saveActionLog();question.retire();model.invalidate();model.closeForHandoff=nil
        let action=pendingHandoff;pendingHandoff=nil
        if let window{if let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()}}
        guard let window else{let done=onClosed;onClosed={};done();return}
        let release=SubmoduleUpdateProgressRelease(window:window,parent:parent ?? window.sheetParent,ready:{[self] in !underlyingWorkPending}){[self] in
            self.release=nil;retiringChildren.removeAll();let done=onClosed;onClosed={};done();action?()
        };self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SubmoduleUpdateProgressWindowModel: ObservableObject, ActionLogProgress {
    let commandProgressScope = CommandProgressContext.current
    private(set) static var activeOperations = 0
    private(set) var pendingOperations=0
    var isRetired:Bool {invalidated}
    let repository: GitRepository
    private let access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, preferences: UserDefaults, autoClosePolicy: GitProgressAutoClose
    private let token = OperationCancellation()
    private var started = false, invalidated = false
    private var startedAt: TimeInterval = 0
    @Published private(set) var completionRange: NSRange?
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    @Published var busy = false
    @Published var confirmingCancellation = false
    @Published var confirmingQuit = false
    @Published var cancelling = false
    @Published var cancelled = false
    @Published var success = false
    @Published var currentWork = ""
    @Published var percentage: Int?
    @Published var output = ""
    @Published var exitCode: Int32?
    var close: () -> Void = {}
    var onUpdated: (String) -> Void = { _ in }
    var onAttemptCompleted: (SubmoduleUpdateResult) -> Void = { _ in }
    @Published private(set) var result: SubmoduleUpdateResult?
    var argumentByteLimit: Int?
    var presentationPreferences: UserDefaults { preferences }
    var presentationAvailable: () -> Bool = { true }
    var closeForHandoff: ((@escaping () -> Void) -> Void)?
    var onBisect: (BisectOperation) -> Void = { _ in }
    @Published private(set) var postActions: [BisectOperation] = []
    private var dispatched = false
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var activeOperation: Bool { busy || confirmingCancellation || confirmingQuit }
    var actionLogRepository: URL { repository.root }
    var actionLogCancelled: Bool { cancelled }
    var actionLogEligible: Bool { started && !busy }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.paths = paths; self.options = options; self.preferences = preferences
        autoClosePolicy = GitProgressAutoClose(preferences: preferences); outputState = GitProgressOutputState(preferences: preferences)
    }
    func invalidate() { invalidated = true; token.cancel() }
    func start() {
        CommandProgressContext.perform(commandProgressScope) { startInCommandProgressScope() }
    }
    private func startInCommandProgressScope() {
        guard !started, !invalidated, !confirmingQuit else { return }; started = true; busy = true; Self.activeOperations += 1;pendingOperations += 1; startedAt = ProcessInfo.processInfo.systemUptime
        Task {
            defer { Self.activeOperations -= 1;pendingOperations -= 1; withExtendedLifetime(access) {} }
            var receipt: SubmoduleUpdateResult?
            do {
                if GitRuntime.isAppStoreBuild { guard access?.hasSecurityScope == true, access?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
                let parser = GitCliOutputParser(limit: outputState.limit)
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.updateSubmodulesWorkflow(paths: paths, options: options, cancellation: token, argumentByteLimit: argumentByteLimit, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
                }
                for await _ in updates { if !invalidated { consume(parser.processPending(), parser: parser) } }
                if !invalidated { consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser) }
                let result = try await operation.value; receipt=result
                guard !invalidated else { if !result.entries.isEmpty {onAttemptCompleted(result)};busy=false;return }
                exitCode=result.exitCode;success=result.success
                if output.isEmpty { output = result.output.isEmpty ? result.success ? "Submodule update completed." : "Submodule update failed." : result.output }
                if success {
                    // Post-action discovery is read-only; its failure must not
                    // hide a successfully completed update or its refresh receipt.
                    if var directory = try? await repository.run(["rev-parse", "--absolute-git-dir"], cancellation:token).stdout {
                        if directory.last == 10 {directory.removeLast()}
                        let active=FileManager.default.fileExists(atPath:URL(fileURLWithPath:String(decoding:directory,as:UTF8.self)).appendingPathComponent("BISECT_START").path)
                        if !invalidated {postActions=active ? [.good,.bad,.skip,.reset]:[]}
                    }
                }
            } catch {
                if let failure=error as? SubmoduleUpdateExecutionFailure {receipt=failure.result;if !invalidated {exitCode=failure.result.exitCode}}
                if !invalidated {
                    if let failure = error as? GitFailure { exitCode = failure.code }
                    let message = token.isCancelled ? "Submodule update cancelled." : error.localizedDescription
                    if !message.isEmpty { output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message }
                }
            }
            // Forced closure fences presentation, not the authoritative refresh
            // for an operation that may already have changed child worktrees.
            if let receipt,!receipt.entries.isEmpty {onAttemptCompleted(receipt)}
            guard !invalidated else{busy=false;return}
            result=receipt
            if token.isCancelled {success=false;postActions=[]}
            cancelled = token.isCancelled
            let completion = SubmoduleProgressCompletion(success:success, cancelled:cancelled, exitCode:exitCode, elapsed:ProcessInfo.processInfo.systemUptime - startedAt, preferences:preferences)
            currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to:&output)
            busy = false; saveActionLog()
            if success,let receipt {onUpdated(receipt.output)}
            if !invalidated {finishAutomaticClose()}
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        outputState.consume(emission, parser: parser); output = outputState.output
        currentWork = outputState.currentWork; percentage = outputState.percentage
    }
    func cancel() {
        guard busy, !invalidated, !confirmingCancellation, !confirmingQuit, !cancelling else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    func perform(_ operation: BisectOperation) {
        CommandProgressContext.perform(commandProgressScope) { performInCommandProgressScope(operation) }
    }
    private func performInCommandProgressScope(_ operation: BisectOperation) {
        guard !activeOperation, !invalidated, presentationAvailable(), success, !dispatched, postActions.contains(operation) else { return }
        dispatched = true; let callback=onBisect
        let dispatch=CommandProgressContext.capture(commandProgressScope) {callback(operation)}
        if let closeForHandoff {closeForHandoff(dispatch)} else {close();dispatch()}
    }
    func action(for operation: BisectOperation) -> RepositoryAction {
        switch operation { case .good: return .bisectGood; case .bad: return .bisectBad; case .skip: return .bisectSkip; case .reset: return .bisectReset }
    }
    private func finishAutomaticClose() { if !activeOperation, !invalidated, autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() } }
}

private struct SubmoduleUpdateProgressDialog: View {
    @ObservedObject var model: SubmoduleUpdateProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updating submodules").font(.headline)
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                .tint(model.busy ? .accentColor : model.success ? .blue : .red)
                .accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text:model.output, completed:!model.busy, completionRange:model.completionRange, success:model.success).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Text(model.busy ? model.cancelling ? "Cancelling…" : "Updating…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Update failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red)
                Spacer()
                if let first = model.postActions.first {
                    Button { model.perform(first) } label: { CommandLabel(title: model.action(for: first).title, icon: model.action(for: first).icon) }.disabled(model.activeOperation)
                    Menu {
                        ForEach(model.postActions, id: \.self) { operation in
                            Button { model.perform(operation) } label: { CommandLabel(title: model.action(for: operation).title, icon: model.action(for: operation).icon) }
                        }
                    } label: { Image(systemName: "chevron.down").accessibilityLabel("Submodule update post-actions") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.activeOperation)
                }
                Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.activeOperation)
                Button("Abort") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.success || model.confirmingCancellation || model.confirmingQuit || model.busy && model.cancelling)
            }
        }.padding(12)
    }
}

@MainActor private final class SubmoduleUpdateProgressRelease {
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private let ready:()->Bool
    private var completion:()->Void
    private var finished=false
    init(window:NSWindow,parent:NSWindow?,ready:@escaping()->Bool={true},completion:@escaping()->Void){self.window=window;self.parent=parent;self.ready=ready;self.completion=completion}
    func start(){
        Self.activeCount += 1
        window.sheetParent?.endSheet(window);window.orderOut(nil)
        Task { @MainActor [self] in
            await Task.yield()
            while window.sheetParent != nil || parent?.attachedSheet === window || !ready(){try? await Task.sleep(nanoseconds:10_000_000)}
            guard !finished else{return};finished=true;Self.activeCount -= 1;let done=completion;completion={};done()
        }
    }
}
