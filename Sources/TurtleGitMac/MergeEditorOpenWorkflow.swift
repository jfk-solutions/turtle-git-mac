import AppKit
import TurtleGitCore

/// A single owner spans the Save question and Open dialog. Closing the editor
/// retires both, and repeated Open commands cannot create parallel sessions.
@MainActor final class MergeEditorOpenWorkflow {
    static private(set) var activeSaves = 0
    private weak var window: NSWindow?
    private let permissions: [RepositoryAccessLease]
    private let preferences: UserDefaults
    private var question: NSAlert?
    private(set) var opener: MergeOpenWindowController?
    private var retired = false, saving = false
    var accept: (MergeOpenRequest, [RepositoryAccessLease]) throws -> Void = { _, _ in }
    var onClosed: () -> Void = {}
    var presentQuestion: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert, owner, completion in alert.beginSheetModal(for: owner, completionHandler: completion) }
    init(window: NSWindow, permissions: [RepositoryAccessLease], preferences: UserDefaults) {
        self.window = window; self.permissions = permissions; self.preferences = preferences
    }
    func start(dirty: Bool, description: String, save: @escaping (@escaping (Bool) -> Void) -> Void) {
        guard !retired, question == nil, opener == nil, !saving, let window, window.attachedSheet == nil else { return }
        guard dirty else { presentOpen(); return }
        let alert = NSAlert(); alert.messageText = "Save changes to “" + description + "” before opening another file?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        question = alert
        presentQuestion(alert, window) { [weak self, alert] answer in
            guard let self, !self.retired, self.question === alert else { return }
            self.question = nil
            switch answer {
            case .alertFirstButtonReturn:
                self.saving = true; Self.activeSaves += 1
                var answered = false
                save { [weak self] saved in
                    guard !answered else { return }; answered = true; Self.activeSaves -= 1
                    guard let self, !self.retired, self.saving else { return }
                    self.saving = false
                    if saved { self.presentOpen() } else { self.retire() }
                }
            case .alertSecondButtonReturn: self.presentOpen()
            default: self.retire()
            }
        }
    }
    private func presentOpen() {
        guard !retired, opener == nil, let window, window.attachedSheet == nil else { retire(); return }
        let controller = MergeOpenWindowController(preferences: preferences, permissions: permissions)
        opener = controller
        controller.onAccepted = { [weak self, weak controller] request, leases in
            guard let self, let controller, !self.retired, self.opener === controller else { throw RevisionComparisonFailure.selection }
            try self.accept(request, leases)
        }
        controller.onClosed = { [weak self] in self?.opener = nil; self?.retire() }
        controller.present(parent: window)
    }
    func retire() {
        guard !retired else { return }; retired = true
        if let question, let window { window.endSheet(question.window, returnCode: .alertThirdButtonReturn); question.window.orderOut(nil) }
        question = nil
        let child = opener; opener = nil; child?.close()
        accept = { _, _ in }
        let finished = onClosed; onClosed = {}; finished()
    }
}

/// The original repository registry retains this owner. Repeated replacement
/// keeps only the current editor, rather than a chain of retired controllers.
@MainActor final class MergeEditorReplacementOwner {
    private static var live: [UUID: MergeEditorReplacementOwner] = [:]
    private let id = UUID()
    private(set) var current: NSWindowController?
    private(set) var pendingPatch: ReviewPatchWorkflow?
    private var parentCloseObserver: NSObjectProtocol?
    var preparingPatch: Bool { pendingPatch != nil }
    var makePatchWorkflow: (URL?, URL?, Data?, [RepositoryAccessLease], UserDefaults) throws -> ReviewPatchWorkflow = { file, target, bytes, grants, preferences in
        ReviewPatchWorkflow(file: file, target: target, preferred: target, grants: grants, executable: try GitRuntime.executable(), preferences: preferences, clipboardBytes: bytes)
    }
    private var onClosed: () -> Void
    init(onClosed: @escaping () -> Void) { self.onClosed = onClosed }
    func replace(_ request: MergeOpenRequest, permissions: [RepositoryAccessLease], preferences: UserDefaults,
                 window: NSWindow, previous: NSWindowController) throws {
        let next: NSWindowController
        switch request {
        case .compare(let base, let mine, let single):
            let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: permissions, preferences: preferences, deferInitialLoad: true)
            controller.model.singleFileMode = single; next = controller
        case .merge(let base, let theirs, let mine):
            let merge = try WorkingTextMerge(base: base, theirs: theirs, mine: mine)
            next = TextConflictWindowController(repository: GitRepository(root: mine.deletingLastPathComponent(), executable: try GitRuntime.executable()), access: nil, path: mine.lastPathComponent, workingMerge: merge, permissions: permissions, preferences: preferences, deferInitialLoad: true)
        case .patch(let file, let target, let bytes):
            let workflow = try makePatchWorkflow(file, target, bytes, permissions, preferences)
            preparePatch(workflow, window: window, previous: previous, preferences: preferences)
            return
        }
        try adopt(next, window: window, previous: previous)
    }
    private func adopt(_ next: NSWindowController, window: NSWindow, previous: NSWindowController) throws {
        guard let prepared = next.window, let host = window as? TextConflictNSWindow else { throw RevisionComparisonFailure.selection }
        // Detach the accepted Open sheet before changing controller/window roles.
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        let originalFrame = window.frame
        let title = prepared.title, minimum = prepared.contentMinSize, content = prepared.contentViewController
        prepared.contentViewController = nil; prepared.delegate = nil; prepared.orderOut(nil)
        if let pair = previous as? FileComparisonWindowController { pair.detachForReplacement() }
        if let merge = previous as? TextConflictWindowController { merge.detachForReplacement() }
        if let patch = previous as? WorkingTreePatchWindowController { patch.detachForReplacement() }
        previous.window = nil; next.window = window
        DialogGeometry.detach(prepared); prepared.close()
        host.model = nil; host.mergedText = nil; host.patchModel = nil; host.imageKeyModel = nil; host.imageKeysRetired = true
        window.contentViewController = content; window.title = title; window.contentMinSize = minimum
        current = next; Self.live[id] = self
        if let pair = next as? FileComparisonWindowController {
            pair.sharedReplacementOwner = self; pair.model.window = window; host.model = pair.model; pair.installEditorToolbar()
            host.openMergeDocument = { [weak pair] in pair?.openMergeDocument(nil) }
            window.delegate = pair; pair.onClosed = { [weak self] in self?.finish() }
            pair.model.externalDidOpen = { [weak window] in window?.close() }
            pair.model.beginTransferredDocument(); pair.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        } else if let merge = next as? TextConflictWindowController {
            merge.sharedReplacementOwner = self; merge.model.window = window; merge.installEditorToolbar()
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
        workflow.onFinished = { [weak self] in
            guard let self else { return }; self.pendingPatch = nil
            if let observer = self.parentCloseObserver { NotificationCenter.default.removeObserver(observer); self.parentCloseObserver = nil }
            if self.current == nil { Self.live.removeValue(forKey: self.id) }
        }
        DispatchQueue.main.async { [weak self, weak window, weak workflow] in
            guard let self, let window, let workflow, self.pendingPatch === workflow else { return }
            guard window.attachedSheet == nil, let sheet = workflow.window else { workflow.cancel(); return }
            window.beginSheet(sheet); workflow.start()
        }
    }
    private func finish() { pendingPatch?.cancel(); current = nil; Self.live.removeValue(forKey: id); let close = onClosed; onClosed = {}; close() }
}

/// Scoped entries are installed only while their editor owns the key window.
@MainActor final class MergeEditorFileMenu {
    private weak var menu: NSMenu?
    private var items: [NSMenuItem] = []
    func install(target: AnyObject, open: Selector, reload: Selector, images: Bool = false) {
        remove()
        guard let menu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else { return }
        self.menu = menu
        for (title, action, key, icon) in [(images ? "Load Images…" : "Open in TurtleGitMerge…", open, "o", MenuIcon.open), ("Reload comparison", reload, "", MenuIcon.refresh)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target; item.image = icon.image(); items.append(item); menu.addItem(item)
        }
    }
    func remove() {
        if let menu { for item in items where menu.items.contains(item) { menu.removeItem(item) } }
        menu = nil; items = []
    }
}
