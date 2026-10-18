// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

/// One command's grants, editors and completion stay owned until its real work drains.
@MainActor final class MergeToolLaunchSession {
    static private(set) var activePreparations = 0
    let invocation: MergeToolInvocation
    let preferences: UserDefaults
    private weak var owner: NSWindow?
    private var ownerObserver: NSObjectProtocol?
    private var grants: [RepositoryAccessLease]
    private let cancellation = OperationCancellation()
    private var started = false, retired = false, finishing = false
    private(set) var preparing = false
    private(set) var editor: NSWindowController?
    private(set) var opener: MergeOpenWindowController?
    private(set) var patch: ReviewPatchWorkflow?
    private var panel: NSOpenPanel?
    private var panelAnswer: ((URL?) -> Void)?
    private(set) var outputPanel: NSSavePanel?
    private var outputAnswer: ((URL?) -> Void)?
    private var cleanupInputs: [MergeToolCleanupInput] = []
    private var replacementOwner: MergeEditorReplacementOwner?
    private var retiredOpeners: [MergeOpenWindowController] = []
    private var hasPendingOpenWork: Bool { (opener?.pendingChoices ?? 0) > 0 || retiredOpeners.contains { $0.pendingChoices > 0 } }
    private var hasReplacement = false, abandonedRequestedResult = false
    var requiresScopes = GitRuntime.isAppStoreBuild
    var executable: () throws -> URL = { try GitRuntime.executable() }
    var authorize: ((URL, Bool) async throws -> RepositoryAccessLease?)?
    var chooseOutput: (() async -> URL?)?
    var presentOutputPanel: (NSSavePanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, owner, completion in
        if let owner, owner.isVisible, owner.attachedSheet == nil { panel.beginSheetModal(for: owner, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    var selectedOutputURL: (NSSavePanel) -> URL? = { $0.url }
    var presentation: ((NSWindowController) -> Void)?
    var configurePatchWorkflow: (ReviewPatchWorkflow) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    var onFinished: (Int32) -> Void = { _ in }
    var hasPendingWork: Bool {
        preparing || finishing || hasPendingOpenWork || replacementOwner?.preparingPatch == true || replacementOwner?.hasPendingRetiredWork == true || (editor as? FileComparisonWindowController)?.model.mergeToolHasPendingWork == true ||
        (editor as? TextConflictWindowController)?.model.mergeToolHasPendingWork == true ||
        (editor as? WorkingTreePatchWindowController)?.activeOperation == true || patch?.loading == true
    }
    var completionStatus: Int32 {
        if abandonedRequestedResult { return 1 }
        if let merge = editor as? TextConflictWindowController {
            if hasReplacement { return merge.model.document != nil && !merge.model.dirty && !merge.model.mergeToolHasConflicts ? 0 : 1 }
            return merge.model.mergeToolSaved && !merge.model.mergeToolHasConflicts ? 0 : 1
        }
        if let comparison = editor as? FileComparisonWindowController {
            guard comparison.model.document != nil else { return 1 }
            if hasReplacement { return comparison.model.dirty ? 1 : 0 }
            return (invocation.merged != nil || invocation.saveRequired) && !comparison.model.mergeToolSaved ? 1 : 0
        }
        return editor is WorkingTreePatchWindowController ? 0 : 1
    }
    func closeAfterApprovedQuit() {
        let status = completionStatus
        cancellation.cancel(); cancelOutputChoice(); opener?.close(); patch?.cancel(); editor?.close(); finish(status)
    }
    init(invocation: MergeToolInvocation, preferences: UserDefaults, owner: NSWindow?, permissions: [RepositoryAccessLease] = []) {
        self.invocation = invocation; self.preferences = preferences; self.owner = owner; self.grants = permissions
        if let owner {
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { if self?.preparing == true { self?.cancel() } } }
        }
    }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    func start() {
        guard !started, !retired else { return }; started = true; preparing = true; Self.activePreparations += 1
        Task {
            defer { preparing = false; Self.activePreparations -= 1 }
            do {
                if invocation.help { TurtleGitHelp.show(.compare); finish(0); return }
                let inputs = [invocation.base, invocation.theirs, invocation.mine, invocation.diff, invocation.originalFile, invocation.modifiedFile].compactMap { $0 }
                for url in inputs {
                    let absent = !FileManager.default.fileExists(atPath: url.path)
                    try await permission(for: absent ? url.deletingLastPathComponent() : url, folder: absent)
                }
                if let folder = invocation.patchPath { try await permission(for: folder, folder: true) }
                if let output = invocation.merged { try await permission(for: output.deletingLastPathComponent(), folder: true) }
                try cancellation.check(); guard !retired else { return }
                if invocation.deleteInputsOnClose {
                    let paths = [invocation.base, invocation.theirs, invocation.mine].compactMap { $0 }
                    let output = invocation.merged ?? invocation.mine
                    cleanupInputs = try await Task.detached { try paths.filter { url in
                        guard let output else { return true }
                        var inputInfo = stat(), outputInfo = stat()
                        if lstat(url.path, &inputInfo) == 0, lstat(output.path, &outputInfo) == 0, inputInfo.st_dev == outputInfo.st_dev, inputInfo.st_ino == outputInfo.st_ino { return false }
                        return !GitReferenceName.equal(url.path, output.path)
                    }.compactMap(MergeToolCleanupInput.capture) }.value
                }
                try cancellation.check()
                if invocation.createUnifiedDiff, let original = invocation.originalFile, let modified = invocation.modifiedFile {
                    try await createUnifiedDiff(original: original, modified: modified); return
                }
                if invocation.diff != nil || invocation.patchPath != nil { try showPatch(file: invocation.diff, target: invocation.patchPath); return }
                if let base = invocation.base, let mine = invocation.mine {
                    if let theirs = invocation.theirs { try showMerge(base: base, theirs: theirs, mine: mine) }
                    else { try showComparison(base: base, mine: mine, single: false) }
                } else { showOpen() }
            } catch {
                if !cancellation.isCancelled { onError(error.localizedDescription) }
                finish(1)
            }
        }
    }
    private func permission(for url: URL, folder: Bool) async throws {
        try cancellation.check()
        if grants.contains(where: { $0.contains(url) && (!requiresScopes || $0.hasSecurityScope) }) { return }
        let lease: RepositoryAccessLease?
        if let authorize { lease = try await authorize(url, folder) }
        else if !requiresScopes { lease = RepositoryAccessLease(url: url) }
        else {
            let selected = await pick(url, folder: folder)
            lease = selected.map { RepositoryAccessLease(url: $0) }
        }
        try cancellation.check()
        guard let lease, lease.contains(url), !requiresScopes || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        grants.append(lease)
    }
    private func pick(_ url: URL, folder: Bool) async -> URL? {
        guard !retired else { return nil }
        let picker = NSOpenPanel(); picker.canChooseDirectories = folder; picker.canChooseFiles = !folder; picker.allowsMultipleSelection = false
        picker.title = "Authorize TurtleGitMerge file access"; picker.prompt = "Authorize"
        picker.directoryURL = folder ? url : url.deletingLastPathComponent(); picker.message = url.path
        if !folder { picker.nameFieldStringValue = url.lastPathComponent }
        panel = picker
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (URL?) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            panelAnswer = reply
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { reply(nil); return }
                if self.panel === picker { self.panel = nil; self.panelAnswer = nil }
                reply(!self.retired && response == .OK ? picker.url : nil)
            }
            if let owner, owner.isVisible, owner.attachedSheet == nil { picker.beginSheetModal(for: owner, completionHandler: completion) }
            else { picker.begin(completionHandler: completion) }
        }
    }
    private func present(_ controller: NSWindowController) {
        editor = controller
        installReplacementOwner(controller)
        if let presentation { presentation(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    private func installReplacementOwner(_ controller: NSWindowController) {
        guard replacementOwner == nil else { return }
        let replacement = MergeEditorReplacementOwner(onClosed: { [weak self] in guard let self else { return }; self.finish(self.completionStatus) })
        replacement.configurePatchWorkflow = { [weak self] workflow in
            guard let self else { return }
            workflow.configureReview = { [invocation = self.invocation] model in
                model.mergeToolReadOnly = invocation.readOnly; model.mergeToolOriginalLabel = invocation.patchOriginal; model.mergeToolPatchedLabel = invocation.patchPatched
                model.setReversed(invocation.reversedPatch)
            }
            self.configurePatchWorkflow(workflow)
        }
        replacement.configureBeforeAdopt = { [weak self] next in
            guard let self, !self.retired else { throw OperationCancellationFailure.cancelled }
            if let pair = next as? FileComparisonWindowController {
                let oneWay = (self.editor as? FileComparisonWindowController)?.model.onePaneMode ?? self.invocation.oneWay
                pair.model.configureMergeToolReplacement(readOnly: self.invocation.readOnly, oneWay: oneWay, reflectedBase: self.invocation.baseReflectedName, reflectedMine: self.invocation.mineReflectedName)
            } else if let merge = next as? TextConflictWindowController { merge.model.configureMergeToolReadOnly(self.invocation.readOnly) }
            else if let patch = next as? WorkingTreePatchWindowController { patch.model.mergeToolReadOnly = self.invocation.readOnly }
        }
        replacement.onAdopt = { [weak self] next, previous in
            guard let self else { return }
            if !self.hasReplacement {
                let needsResult = self.invocation.merged != nil || self.invocation.saveRequired || previous is TextConflictWindowController
                let saved = (previous as? FileComparisonWindowController)?.model.mergeToolSaved == true || (previous as? TextConflictWindowController)?.model.mergeToolSaved == true
                self.abandonedRequestedResult = needsResult && !saved
            }
            self.hasReplacement = true; self.editor = next
        }
        replacementOwner = replacement
        if let pair = controller as? FileComparisonWindowController { pair.sharedReplacementOwner = replacement }
        else if let merge = controller as? TextConflictWindowController { merge.sharedReplacementOwner = replacement }
        else if let patch = controller as? WorkingTreePatchWindowController { patch.sharedReplacementOwner = replacement }
    }
    private func showComparison(base: URL, mine: URL, single: Bool) throws {
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: grants, preferences: preferences, deferInitialLoad: true)
        try controller.model.configureMergeTool(invocation); controller.model.singleFileMode = single
        controller.onClosed = { [weak self] in guard let self else { return }; self.finish(self.completionStatus) }
        present(controller); controller.model.beginTransferredDocument()
    }
    private func showMerge(base: URL, theirs: URL, mine: URL) throws {
        let working = try WorkingTextMerge(base: base, theirs: theirs, mine: mine, merged: invocation.merged, allowMissingInputs: true)
        let repository = GitRepository(root: mine.deletingLastPathComponent(), executable: try executable())
        let controller = TextConflictWindowController(repository: repository, access: nil, path: (invocation.merged ?? mine).path, workingMerge: working, permissions: grants, preferences: preferences, deferInitialLoad: true)
        try controller.model.configureMergeTool(invocation)
        controller.onClosed = { [weak self] in guard let self else { return }; self.finish(self.completionStatus) }
        present(controller); controller.model.beginTransferredDocument()
    }
    private func showOpen() {
        let controller = MergeOpenWindowController(preferences: preferences, permissions: grants); opener = controller
        controller.base.stringValue = invocation.base?.path ?? ""; controller.theirs.stringValue = invocation.theirs?.path ?? ""; controller.mine.stringValue = invocation.mine?.path ?? ""
        controller.onAccepted = { [weak self] request, permissions in
            guard let self, !self.retired else { throw OperationCancellationFailure.cancelled }; self.grants += permissions
            switch request {
            case .compare(let base, let mine, let single): try self.showComparison(base: base, mine: mine, single: single)
            case .merge(let base, let theirs, let mine): try self.showMerge(base: base, theirs: theirs, mine: mine)
            case .patch(let file, let directory, let bytes): try self.showPatch(file: file, target: directory, bytes: bytes)
            }
        }
        controller.onClosed = { [weak self, weak controller] in
            guard let self else { return }
            if let controller, controller.pendingChoices > 0 { self.retiredOpeners.append(controller) }
            self.opener = nil; if self.editor == nil && self.patch == nil { self.finish(1) }
        }
        if let presentation { presentation(controller) } else { controller.present(parent: owner) }
    }
    private func showPatch(file: URL?, target: URL?, bytes: Data? = nil) throws {
        let workflow = ReviewPatchWorkflow(file: file, target: target, grants: grants, executable: try executable(), preferences: preferences, clipboardBytes: bytes)
        patch = workflow
        workflow.configureReview = { [invocation] model in
            model.mergeToolReadOnly = invocation.readOnly; model.mergeToolOriginalLabel = invocation.patchOriginal; model.mergeToolPatchedLabel = invocation.patchPatched
            model.setReversed(invocation.reversedPatch)
        }
        workflow.preparedPresentation = { [weak self] controller in
            guard let self, !self.retired else { throw OperationCancellationFailure.cancelled }
            controller.onClosed = { [weak self] in self?.finish(0) }; self.present(controller)
        }
        workflow.onFinished = { [weak self] in guard let self else { return }; self.patch = nil; if self.editor == nil { self.finish(1) } }
        configurePatchWorkflow(workflow)
        if let presentation { presentation(workflow) } else { workflow.showWindow(nil) }
        workflow.start()
    }
    private func createUnifiedDiff(original: URL, modified: URL) async throws {
        let output: URL?
        if let supplied = invocation.outputFile { output = supplied }
        else if let chooseOutput { output = await chooseOutput() }
        else { output = await chooseUnifiedOutput(directory: original.deletingLastPathComponent()) }
        try cancellation.check(); guard let output else { finish(1); return }
        if invocation.outputFile == nil { grants.append(RepositoryAccessLease(url: output)) }
        try await permission(for: output.deletingLastPathComponent(), folder: true)
        let baseline = try MergeToolOutputTarget(capturing: output)
        let token = cancellation, executable = try executable(), context = MergeUnifiedPatch.contextLines(from: preferences)
        let inputs = try await Task.detached { (try MergeToolOutputTarget(capturing: original), try MergeToolOutputTarget(capturing: modified)) }.value
        let bytes = try await MergeUnifiedPatch.create(base: inputs.0.content, destination: inputs.1.content, baseLabel: original.lastPathComponent, destinationLabel: modified.lastPathComponent, contextLines: context, executable: executable, cancellation: token)
        try token.check()
        _ = try await Task.detached { try token.check(); try inputs.0.validate(); try inputs.1.validate(); return try baseline.save(bytes: bytes) }.value
        finish(0)
    }
    private func chooseUnifiedOutput(directory: URL) async -> URL? {
        guard !retired, outputPanel == nil else { return nil }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "changes.patch"; panel.directoryURL = directory; panel.canCreateDirectories = true
        outputPanel = panel
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: (URL?) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            outputAnswer = answer
            presentOutputPanel(panel, owner) { [weak self] response in
                guard let self, self.outputPanel === panel else { answer(nil); return }
                self.outputPanel = nil; self.outputAnswer = nil
                answer(!self.retired && response == .OK ? self.selectedOutputURL(panel) : nil)
            }
        }
    }
    private func cancelOutputChoice() {
        let answer = outputAnswer; outputAnswer = nil
        if let panel = outputPanel {
            outputPanel = nil
            if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }
            panel.cancel(nil); panel.orderOut(nil)
        }
        answer?(nil)
    }
    func cancel() {
        cancellation.cancel(); retired = true; cancelOutputChoice()
        if let panel { panel.cancel(nil); if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }; panel.orderOut(nil) }
        panel = nil; let answer = panelAnswer; panelAnswer = nil; answer?(nil)
        opener?.close(); patch?.cancel(); editor?.close()
        finish(1)
    }
    private func finish(_ status: Int32) {
        guard !finishing else { return }; finishing = true; retired = true
        Task {
            while preparing || hasPendingOpenWork || replacementOwner?.preparingPatch == true || replacementOwner?.hasPendingRetiredWork == true || (editor as? FileComparisonWindowController)?.model.mergeToolHasPendingWork == true || (editor as? TextConflictWindowController)?.model.mergeToolHasPendingWork == true || (editor as? WorkingTreePatchWindowController)?.activeOperation == true || patch?.loading == true {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if invocation.deleteInputsOnClose {
                let inputs = cleanupInputs
                do { try await Task.detached { for input in inputs { try input.removeIfUnchanged() } }.value }
                catch { onError(error.localizedDescription) }
            }
            if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver); self.ownerObserver = nil }
            grants = []; editor = nil; replacementOwner = nil; opener = nil; retiredOpeners = []; patch = nil; finishing = false
            let callback = onFinished; onFinished = { _ in }; callback(status)
        }
    }
}

/// Explicit cleanup removes only the same unchanged input object; never the merged output.
private struct MergeToolCleanupInput: @unchecked Sendable {
    let url: URL
    let identity: stat
    let bytes: Data
    static func capture(_ url: URL) throws -> Self? {
        var info = stat(); if lstat(url.path, &info) != 0, errno == ENOENT { return nil }
        return try Self(url)
    }
    init(_ url: URL) throws {
        var info = stat(); guard lstat(url.path, &info) == 0 else { throw TextConflictFailure.changedWorkingFile }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            self.url = url; identity = info; bytes = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8); return
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw TextConflictFailure.unsupported }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW); guard fd >= 0 else { throw TextConflictFailure.changedWorkingFile }
        defer { close(fd) }; var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw TextConflictFailure.changedWorkingFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        self.url = url; identity = info; bytes = try handle.readToEnd() ?? Data()
    }
    func removeIfUnchanged() throws {
        var current = stat(); guard lstat(url.path, &current) == 0 else { return }
        guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino, current.st_mode == identity.st_mode, current.st_size == identity.st_size,
              current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec else { return }
        let latest = try Self(url); guard latest.bytes == bytes else { return }
        guard unlink(url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
