import AppKit
import TurtleGitCore

/// A single owner spans the Save question and Open dialog. Closing the editor
/// retires both, and repeated Open commands cannot create parallel sessions.
@MainActor final class MergeEditorOpenWorkflow {
    static private(set) var activeSaves = 0
    static private(set) var activeTransactions = 0
    private weak var window: NSWindow?
    private let permissions: [RepositoryAccessLease]
    private let preferences: UserDefaults
    private var question: NSAlert?
    private(set) var opener: MergeOpenWindowController?
    private var retired = false, saving = false, started = false, finished = false
    private var questionAnswered = false
    private var drain: Task<Void, Never>?
    var hasPendingWork: Bool { started && !finished }
    var makeOpener: (UserDefaults, [RepositoryAccessLease]) -> MergeOpenWindowController = { MergeOpenWindowController(preferences: $0, permissions: $1) }
    var accept: (MergeOpenRequest, [RepositoryAccessLease]) throws -> Void = { _, _ in }
    var onClosed: () -> Void = {}
    var presentQuestion: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert, owner, completion in alert.beginSheetModal(for: owner, completionHandler: completion) }
    init(window: NSWindow, permissions: [RepositoryAccessLease], preferences: UserDefaults) {
        self.window = window; self.permissions = permissions; self.preferences = preferences
    }
    func start(dirty: Bool, description: String, save: @escaping (@escaping (Bool) -> Void) -> Void) {
        guard !started, !retired, let window, window.attachedSheet == nil else { return }
        started = true; Self.activeTransactions += 1
        guard dirty else { presentOpen(); return }
        let alert = NSAlert(); alert.messageText = "Save changes to “" + description + "” before opening another file?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        alert.window.alphaValue = window.alphaValue; alert.window.appearance = window.appearance
        question = alert
        presentQuestion(alert, window) { [weak self, alert, window] answer in
            guard let self, !self.retired, self.question === alert, !self.questionAnswered else { return }
            self.questionAnswered = true
            let advance = { [self] in
                guard !self.retired, self.question === alert, self.window === window else { return }
                self.question = nil
                switch answer {
                case .alertFirstButtonReturn:
                    self.saving = true; Self.activeSaves += 1
                    var answered = false
                    save { [self] saved in
                        guard !answered else { return }; answered = true
                        Self.activeSaves -= 1; self.saving = false
                        guard !self.retired else { self.settleRetirement(); return }
                        if saved { self.presentOpen() } else { self.retire() }
                    }
                case .alertSecondButtonReturn: self.presentOpen()
                default: self.retire()
                }
            }
            if alert.window.sheetParent == nil && window.attachedSheet !== alert.window { advance() }
            else {
                Task { @MainActor [self, alert, window] in
                    while alert.window.sheetParent != nil || window.attachedSheet === alert.window {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    advance(); self.settleRetirement()
                }
            }
        }
    }
    private func presentOpen() {
        guard !retired, opener == nil, let window, window.attachedSheet == nil else { retire(); return }
        let controller = makeOpener(preferences, permissions)
        opener = controller
        controller.onAccepted = { [weak self, weak controller] request, leases in
            guard let self, let controller, !self.retired, self.opener === controller else { throw RevisionComparisonFailure.selection }
            try self.accept(request, leases)
        }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, self.opener === controller else { return }
            self.opener = nil; self.retire()
        }
        controller.present(parent: window)
    }
    func retire() {
        guard !retired else { settleRetirement(); return }; retired = true
        if let question {
            if let parent = question.window.sheetParent {
                parent.endSheet(question.window, returnCode: .alertThirdButtonReturn)
            } else if let window, window.attachedSheet === question.window {
                window.endSheet(question.window, returnCode: .alertThirdButtonReturn)
            }
            question.window.orderOut(nil)
        }
        opener?.close()
        accept = { _, _ in }
        settleRetirement()
    }
    private var awaitingRetirement: Bool {
        saving || opener?.hasPendingWork == true || question.map { $0.window.sheetParent != nil || window?.attachedSheet === $0.window } == true
    }
    private func settleRetirement() {
        guard retired, !finished else { return }
        guard !awaitingRetirement else {
            if drain == nil {
                drain = Task { @MainActor [self] in
                    while awaitingRetirement { try? await Task.sleep(nanoseconds: 10_000_000) }
                    drain = nil; settleRetirement()
                }
            }
            return
        }
        finished = true; question = nil; opener = nil
        if started { Self.activeTransactions -= 1 }
        let finished = onClosed; onClosed = {}; finished()
    }
}

/// The original repository registry retains this owner. Repeated replacement
/// keeps only the current editor, rather than a chain of retired controllers.
@MainActor final class MergeEditorReplacementOwner {
    private static var live: [UUID: MergeEditorReplacementOwner] = [:]
    private let id = UUID()
    private(set) var current: NSWindowController?
    /// Policy is applied before any accepted editor or window is detached.
    /// Throwing rejects the prepared replacement and leaves the old owner live.
    var configureBeforeAdopt: (NSWindowController) throws -> Void = { _ in }
    /// Publish the actual owner before its first load and scoped commands start.
    var onAdopt: (NSWindowController, NSWindowController) -> Void = { _, _ in }
    private var retiredEditors: [NSWindowController] = []
    private var retiredPatches: [ReviewPatchWorkflow] = []
    private var retiredDrain: Task<Void,Never>?
    var hasPendingRetiredWork: Bool {
        pendingPatch != nil || retiredEditors.contains { Self.hasPendingWork($0) } || retiredPatches.contains { $0.hasPendingWork }
    }
    private static func hasPendingWork(_ editor: NSWindowController) -> Bool {
        if let pair = editor as? FileComparisonWindowController { return pair.mergeToolHasPendingWork }
        if let merge = editor as? TextConflictWindowController { return merge.mergeToolHasPendingWork }
        return (editor as? WorkingTreePatchWindowController)?.hasPendingWork == true
    }
    private func retainRetired(_ editor: NSWindowController) {
        guard Self.hasPendingWork(editor) else { return }
        retiredEditors.append(editor); beginRetiredDrain()
    }
    private func beginRetiredDrain() {
        guard retiredDrain == nil else { return }
        retiredDrain = Task { [self] in
            while hasPendingRetiredWork {
                retiredEditors.removeAll { !Self.hasPendingWork($0) }
                retiredPatches.removeAll { !$0.hasPendingWork }
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            retiredEditors.removeAll(); retiredPatches.removeAll(); retiredDrain = nil
        }
    }
    private(set) var pendingPatch: ReviewPatchWorkflow?
    private var parentCloseObserver: NSObjectProtocol?
    var preparingPatch: Bool { pendingPatch != nil }
    var configurePatchWorkflow: (ReviewPatchWorkflow) -> Void = { _ in }
    var makePatchWorkflow: (URL?, URL?, Data?, [RepositoryAccessLease], UserDefaults) throws -> ReviewPatchWorkflow = { file, target, bytes, grants, preferences in
        ReviewPatchWorkflow(file: file, target: target, preferred: target, grants: grants, executable: try GitRuntime.executable(), preferences: preferences, clipboardBytes: bytes)
    }
    private var onClosed: () -> Void
    private var finishing = false
    private var finishDrain: Task<Void, Never>?
    init(onClosed: @escaping () -> Void) { self.onClosed = onClosed }
    func replace(_ request: MergeOpenRequest, permissions: [RepositoryAccessLease], preferences: UserDefaults,
                 window: NSWindow, previous: NSWindowController) throws {
        let next: NSWindowController
        switch request {
        case .compare(let base, let mine, let single):
            let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: permissions, preferences: preferences, deferInitialLoad: true)
            controller.model.singleFileMode = single; controller.model.useInternalMergeViewer(); next = controller
        case .merge(let base, let theirs, let mine):
            let merge = try WorkingTextMerge(base: base, theirs: theirs, mine: mine)
            next = TextConflictWindowController(repository: GitRepository(root: mine.deletingLastPathComponent(), executable: try GitRuntime.executable()), access: nil, path: mine.lastPathComponent, workingMerge: merge, permissions: permissions, preferences: preferences, deferInitialLoad: true)
        case .patch(let file, let target, let bytes):
            let workflow = try makePatchWorkflow(file, target, bytes, permissions, preferences)
            configurePatchWorkflow(workflow)
            preparePatch(workflow, window: window, previous: previous, preferences: preferences)
            return
        }
        try adopt(next, window: window, previous: previous)
    }
    private func adopt(_ next: NSWindowController, window: NSWindow, previous: NSWindowController) throws {
        guard previous.window === window, let prepared = next.window, let host = window as? TextConflictNSWindow else { throw RevisionComparisonFailure.selection }
        do { try configureBeforeAdopt(next) }
        catch { next.close(); throw error }
        // The Open transaction must release its actual sheet before adoption.
        guard window.attachedSheet == nil else { next.close(); throw RevisionComparisonFailure.selection }
        let originalFrame = window.frame
        let title = prepared.title, minimum = prepared.contentMinSize, content = prepared.contentViewController
        prepared.contentViewController = nil; prepared.delegate = nil; prepared.orderOut(nil)
        if let pair = previous as? FileComparisonWindowController { pair.detachForReplacement() }
        if let merge = previous as? TextConflictWindowController { merge.detachForReplacement() }
        if let patch = previous as? WorkingTreePatchWindowController { patch.detachForReplacement() }
        retainRetired(previous)
        previous.window = nil; next.window = window
        DialogGeometry.detach(prepared); prepared.close()
        host.model = nil; host.mergedText = nil; host.patchModel = nil; host.imageKeyModel = nil; host.imageKeysRetired = true
        window.contentViewController = content; window.title = title; window.contentMinSize = minimum
        current = next; Self.live[id] = self
        onAdopt(next,previous)
        if let pair = next as? FileComparisonWindowController {
            pair.sharedReplacementOwner = self; pair.model.window = window; pair.externalReload?.rebind(to: window); host.model = pair.model; pair.installEditorToolbar()
            host.openMergeDocument = { [weak pair] in pair?.openMergeDocument(nil) }
            window.delegate = pair; pair.onClosed = { [weak self] in self?.finish() }
            pair.model.externalDidOpen = { [weak window] in window?.close() }
            pair.model.beginTransferredDocument(); pair.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        } else if let merge = next as? TextConflictWindowController {
            merge.sharedReplacementOwner = self; merge.model.window = window; merge.externalReload?.rebind(to: window); merge.installEditorToolbar()
            merge.model.close = { [weak window] in window?.close() }
            host.openMergeDocument = { [weak merge] in merge?.openMergeDocument(nil) }
            window.delegate = merge; merge.onClosed = { [weak self] in self?.finish() }
            merge.model.beginTransferredDocument(); merge.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        }
        if let patch = next as? WorkingTreePatchWindowController {
            patch.sharedReplacementOwner = self; patch.model.window = window; host.patchModel = patch.model
            host.openMergeDocument = { [weak patch] in patch?.openMergeDocument(nil) }
            window.delegate = patch; patch.onClosed = { [weak self] in self?.finish() }
            patch.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        }
        let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let height = max(originalFrame.height, minimumFrame.height), width = max(originalFrame.width, minimumFrame.width)
        window.setFrame(NSRect(x: originalFrame.minX, y: originalFrame.maxY - height, width: width, height: height), display: false)
        window.makeKeyAndOrderFront(nil)
    }
    private func preparePatch(_ workflow: ReviewPatchWorkflow, window: NSWindow, previous: NSWindowController, preferences: UserDefaults) {
        guard pendingPatch == nil else { return }
        pendingPatch = workflow; Self.live[id] = self
        parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak workflow] _ in MainActor.assumeIsolated { workflow?.cancel() } }
        workflow.preparedPresentation = { [weak self, weak window, weak previous, weak workflow] controller in
            guard let self, let window, let previous, let workflow,
                  self.pendingPatch === workflow, previous.window === window else { throw OperationCancellationFailure.cancelled }
            try self.adopt(controller, window: window, previous: previous)
        }
        workflow.onFinished = { [weak self, weak workflow] in
            guard let self else { return }
            if let workflow, workflow.hasPendingWork { self.retiredPatches.append(workflow) }
            self.pendingPatch = nil; self.beginRetiredDrain()
            if let observer = self.parentCloseObserver { NotificationCenter.default.removeObserver(observer); self.parentCloseObserver = nil }
            if self.current == nil { Self.live.removeValue(forKey: self.id) }
        }
        DispatchQueue.main.async { [weak self, weak window, weak workflow] in
            guard let self, let window, let workflow, self.pendingPatch === workflow else { return }
            guard window.attachedSheet == nil, let sheet = workflow.window else { workflow.cancel(); return }
            sheet.alphaValue = window.alphaValue; sheet.appearance = window.appearance
            window.beginSheet(sheet); workflow.start()
        }
    }
    private func finish() {
        guard !finishing else { return }; finishing = true
        pendingPatch?.cancel(); current = nil
        let complete = { [self] in
            Self.live.removeValue(forKey: id)
            let close = onClosed; onClosed = {}; close()
        }
        guard hasPendingRetiredWork else { complete(); return }
        finishDrain = Task { @MainActor [self] in
            while hasPendingRetiredWork { try? await Task.sleep(nanoseconds: 10_000_000) }
            finishDrain = nil; complete()
        }
    }
}
