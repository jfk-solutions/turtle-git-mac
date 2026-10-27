// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import TurtleGitCore
import UniformTypeIdentifiers

/// Standalone UDiff documents own their file permission, panels and save point.
/// Commit and embedded import previews never enable this session.
@MainActor final class PatchDocumentSession {
    enum Decision { case save, discard, cancel }
    enum Failure: LocalizedError {
        case tooLarge, encoding, changed
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The patch is too large to open (250 MiB limit)."
            case .encoding: return "The edited text cannot be represented in this patch’s original encoding. No file was written."
            case .changed: return "The patch file changed outside TurtleGit. Use Save As to keep your edits in another file."
            }
        }
    }
    static private(set) var activeOperations = 0
    private static var startupFiles:[ObjectIdentifier:PatchDocumentSession]=[:]
    static var activeStartupInputs:Int {startupFiles.count}
    private(set) var startupFileReading=false
    private var startupClosePending=false
    private var startupWaiters:[CheckedContinuation<Void,Never>]=[]
    private var pendingStartupOutcome:(()->Void)?
    static func cancelAllStartupInputs(){for session in startupFiles.values{session.cancellation?.cancel()}}
    static func waitForStartupInputs()async {
        let sessions=Array(startupFiles.values)
        for session in sessions {if startupFiles[ObjectIdentifier(session)] === session {await withCheckedContinuation{session.startupWaiters.append($0)}}}
    }
    func requestStartupInputClose()->Bool {
        guard startupFileReading else{return false}
        startupClosePending=true;cancellation?.cancel();return true
    }
    private weak var owner: PatchWindowController?
    private(set) var fileURL: URL?
    private var fileAccess: RepositoryAccessLease?
    private var diskBytes: Data?
    private var working = false, retired = false
    private var operationTask:Task<Void,Never>?
    private var retiringReview:ReviewPatchWorkflow?
    private var acceptedSaves=0
    private var saveWaiters:[CheckedContinuation<Void,Never>]=[]
    private var generation = 0
    private(set) var documentIdentity = UUID()
    private var cancellation: OperationCancellation?
    private struct Replacement { let bytes: Data; let file: URL?; let access: RepositoryAccessLease?; let displayLegacyEncoding:ComparisonTextEncoding; let publish: () -> Void }
    private var pendingReplacement: Replacement?
    private var replacing = false
    private var updates: AnyCancellable?
    private(set) var reviewWorkflow: ReviewPatchWorkflow?
    private var settings: SettingsSheetController?
    var settingsWindow: NSWindow? { settings?.window }
    var settingsNavigation: SettingsNavigationController? { settings?.navigation }
    var configureReview: (ReviewPatchWorkflow) -> Void = { _ in }
    var presentReview: (ReviewPatchWorkflow) -> Void = { $0.showWindow(nil); $0.window?.makeKeyAndOrderFront(nil) }

    var askChanges: (NSWindow, @escaping (Decision) -> Void) -> Void = { window, reply in
        let alert = NSAlert(); alert.messageText = "Save changes to this patch before continuing?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { result in reply(result == .alertFirstButtonReturn ? .save : result == .alertSecondButtonReturn ? .discard : .cancel) }
    }
    var chooseOpen: (NSWindow, @escaping (URL?) -> Void) -> Void = { window, reply in
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText, UTType(filenameExtension: "diff") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { reply($0 == .OK ? panel.url : nil) }
    }
    var chooseSave: (NSWindow, String, @escaping (URL?) -> Void) -> Void = { window, name, reply in
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText, UTType(filenameExtension: "diff") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { reply($0 == .OK ? panel.url : nil) }
    }
    var acquireAccess: (URL) -> RepositoryAccessLease = { RepositoryAccessLease(url: $0) }
    var requiresFileScope = GitRuntime.isAppStoreBuild
    var readFile: (URL, OperationCancellation) async throws -> Data = { url, token in
        try await Task.detached {
            try UnifiedDiffInputReader.readFile(url, cancellation: token)
        }.value
    }
    init(owner: PatchWindowController) {
        self.owner = owner
        updates = owner.model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.pumpReplacement() }
        }
        owner.model.documentChanged = { [weak self] in self?.owner?.window?.isDocumentEdited = self?.dirty == true }
        owner.model.requestReplacement = { [weak self] bytes,legacy in self?.replace(bytes,displayLegacyEncoding:legacy) }
        owner.model.requestReload = { [weak self] paths, staged,legacy in
            self?.launch { session in
                guard await session.resolveChanges(), let model = session.owner?.model else { return }
                model.reload(paths: paths, staged: staged, discardingEdits: true,displayLegacyEncoding:legacy)
            }
        }
    }
    var enabled: Bool { !retired && owner?.model.allowsDocumentEditing == true && owner?.model.readOnly == true }
    var dirty: Bool { enabled && owner?.model.documentDirty == true }
    private func launch(onRetired:(()->Void)? = nil,_ operation: @escaping (PatchDocumentSession) async -> Void) {
        guard enabled, !working, let owner, !owner.model.busy, !owner.model.confirmingQuit, owner.model.error == nil, owner.window?.attachedSheet == nil else { return }
        working = true; Self.activeOperations += 1
        operationTask=Task {
            var entered=false
            defer {working=false;Self.activeOperations -= 1;operationTask=nil;if !entered{onRetired?()};finishStartupOperation();pumpReplacement()}
            guard !retired else{return};entered=true
            await operation(self)
        }
    }
    private func finishStartupOperation(){
        if startupFileReading {startupFileReading=false;Self.startupFiles.removeValue(forKey:ObjectIdentifier(self))}
        let completed=pendingStartupOutcome;pendingStartupOutcome=nil;completed?()
        let waiters=startupWaiters;startupWaiters.removeAll();for waiter in waiters{waiter.resume()}
        guard startupClosePending else{return};startupClosePending=false
        guard !retired,let owner,!owner.model.retired,let window=owner.window,window.delegate === owner else{return}
        window.performClose(nil)
    }
    func openDocument() {
        launch { session in
            session.pendingReplacement = nil
            guard await session.resolveChanges(), let window = session.owner?.window else { return }
            session.owner?.model.busy = true
            let url = await withCheckedContinuation { reply in session.chooseOpen(window) { reply.resume(returning: $0) } }
            session.owner?.model.busy = false
            guard !session.retired, let url else { return }
            await session.load(url)
        }
    }
    /// Finder/Launch Services already supplies the chosen file; retain the same
    /// scoped read, save point and cancellation ownership as the Open panel.
    func openFile(_ url: URL, title: String? = nil, authorizeIfNeeded: Bool = false,
                  startupResult:((UnifiedDiffStartupInputOutcome)->Void)? = nil) {
        guard enabled,!working,let owner,!owner.model.busy,!owner.model.confirmingQuit,
              owner.model.error==nil,owner.window?.attachedSheet==nil else{startupResult?(.cancelled);return}
        launch(onRetired:{startupResult?(.cancelled)}) { session in
            session.pendingReplacement = nil
            guard await session.resolveChanges(), !session.retired else {
                if let startupResult{session.pendingStartupOutcome={startupResult(.cancelled)}}
                return
            }
            let report:((UnifiedDiffStartupInputOutcome)->Void)?
            if let startupResult{report={outcome in session.pendingStartupOutcome={startupResult(outcome)}}}
            else {report=nil}
            await session.load(url, title: title, authorizeIfNeeded: authorizeIfNeeded,startupResult:report)
        }
    }
    func saveDocument(as newFile: Bool = false) { launch { _ = await $0.save(as: newFile) } }
    func requestClose() { launch { if await $0.resolveChanges() { $0.owner?.close() } } }
    func replace(_ bytes: Data,displayLegacyEncoding:ComparisonTextEncoding? = nil) {present(bytes,displayLegacyEncoding:displayLegacyEncoding,publish:{})}
    func present(_ bytes: Data, file: URL? = nil, access: RepositoryAccessLease? = nil,displayLegacyEncoding:ComparisonTextEncoding? = nil, publish: @escaping () -> Void) {
        guard enabled, !working || replacing else { return }
        pendingReplacement = Replacement(bytes:bytes,file:file,access:access,displayLegacyEncoding:displayLegacyEncoding ?? .legacyEncoding(from:owner?.model.appearancePreferences ?? .standard),publish:publish)
        pumpReplacement()
    }
    private func publish(_ request: Replacement) {
        guard !retired, let owner else { return }
        if let file = request.file, GitRuntime.isAppStoreBuild, request.access?.permits(file) != true {
            owner.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return
        }
        documentIdentity = UUID(); fileURL = request.file; fileAccess = request.access; diskBytes = request.file == nil ? nil : request.bytes
        owner.window?.representedURL = request.file
        owner.model.setReadOnlyDiff(request.bytes, discardingEdits: true,displayLegacyEncoding:request.displayLegacyEncoding); request.publish()
    }
    private func pumpReplacement() {
        guard enabled, pendingReplacement != nil, !working, let model = owner?.model,
              !model.busy, !model.confirmingQuit, model.error == nil, owner?.window?.attachedSheet == nil else { return }
        if !dirty || model.refreshReplacementApproved {
            let request = pendingReplacement!; pendingReplacement = nil; publish(request); return
        }
        replacing = true
        launch { session in
            let accepted = await session.resolveChanges()
            let latest = session.pendingReplacement; session.pendingReplacement = nil; session.replacing = false
            if accepted, let latest { session.publish(latest) }
        }
    }
    func applyPatch() {
        launch { session in
            guard let owner = session.owner else { return }
            // Upstream passes m_filename, including its saved on-disk contents,
            // to TortoiseGitMerge /diff. Unsaved editor text is not substituted.
            let grants = [owner.model.repositoryAccess, session.fileAccess].compactMap { $0 }
            // TortoiseProc supplies a read-only temporary patch for generated
            // comparisons. Its native equivalent is an immutable loaded snapshot.
            let snapshot = session.fileURL == nil && !owner.model.savedDocumentBytes.isEmpty ? owner.model.savedDocumentBytes : nil
            let executable: URL
            do { executable = try owner.model.repository?.executable ?? GitRuntime.executable(preferences: owner.model.appearancePreferences) }
            catch { owner.model.error = error.localizedDescription; return }
            let workflow = ReviewPatchWorkflow(file: session.fileURL, target: nil, preferred: owner.model.documentDirectory,
                grants: grants, executable: executable, preferences: owner.model.appearancePreferences,
                clipboardBytes: snapshot, title: owner.model.comparisonTitle)
            session.reviewWorkflow = workflow; owner.model.busy = true
            workflow.onFinished = { [weak session, weak workflow] in
                guard let session, session.reviewWorkflow === workflow else { return }
                session.reviewWorkflow = nil; session.owner?.model.busy = false; session.pumpReplacement()
            }
            session.configureReview(workflow); session.presentReview(workflow); workflow.start()
        }
    }
    func showSettings() {
        guard enabled, !working, let owner, !owner.model.busy, !owner.model.confirmingQuit, owner.model.error == nil, let window = owner.window, window.attachedSheet == nil else { return }
        let preferences = owner.model.appearancePreferences
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        let child = SettingsSheetController(workspace: workspace, preferences: preferences, initialPage: .unifiedDiff,
            title: "Unified Diff Settings – TurtleGit", globalOnly: true, minimumSize: NSSize(width: 980, height: 700))
        settings = child; owner.model.busy = true
        child.onClosed = { [weak self, weak child] _ in
            guard let self, self.settings === child else { return }
            self.settings = nil
            guard !self.retired else { return }
            self.owner?.model.busy = false; self.pumpReplacement()
        }
        child.presentSheet(for: window)
    }
    func resolveChanges() async -> Bool {
        guard !retired, let owner, !owner.model.busy, let window = owner.window, window.attachedSheet == nil else { return false }
        guard dirty else { return true }
        let wasConfirming = owner.model.confirmingQuit; owner.model.confirmingQuit = true
        defer { owner.model.confirmingQuit = wasConfirming }
        let decision = await withCheckedContinuation { reply in askChanges(window) { reply.resume(returning: $0) } }
        guard !retired else { return false }
        switch decision { case .cancel: return false; case .discard: return true; case .save: return await save() }
    }
    private func load(_ url: URL, title: String? = nil, authorizeIfNeeded: Bool = false,
                      startupResult:((UnifiedDiffStartupInputOutcome)->Void)? = nil) async {
        var outcome=UnifiedDiffStartupInputOutcome.cancelled
        defer{startupResult?(outcome)}
        guard !retired, let owner else { return }
        var access = acquireAccess(url)
        if requiresFileScope && !access.hasSecurityScope && authorizeIfNeeded {
            guard let window = owner.window else { return }
            owner.model.busy = true
            let chosen = await withCheckedContinuation { reply in chooseOpen(window) { reply.resume(returning: $0) } }
            owner.model.busy = false
            guard !retired, let chosen else { return }
            guard Data(FileTransferPaths.lexicalPath(chosen.path).utf8) == Data(FileTransferPaths.lexicalPath(url.path).utf8) else {
                owner.model.error = "Choose the requested Unified Diff input file.";outcome = .failure; return
            }
            access = acquireAccess(chosen)
        }
        let token = OperationCancellation(), request = generation,legacy=ComparisonTextEncoding.legacyEncoding(from:owner.model.appearancePreferences)
        if requiresFileScope && !access.hasSecurityScope { owner.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription;outcome = .failure; return }
        owner.model.busy = true; cancellation = token
        if startupResult != nil {startupFileReading=true;Self.startupFiles[ObjectIdentifier(self)]=self}
        defer {withExtendedLifetime(access) {};owner.model.busy=false;cancellation=nil}
        do {
            let bytes = try await readFile(url, token)
            guard !retired, generation == request, !token.isCancelled else { return }
            documentIdentity = UUID(); fileURL = url; fileAccess = access; diskBytes = bytes
            owner.window?.representedURL = url
            owner.model.setReadOnlyDiff(bytes, discardingEdits: true,displayLegacyEncoding:legacy)
            owner.model.refreshAvailable = false; owner.model.customRefresh = nil
            owner.model.comparisonTitle = title ?? url.lastPathComponent
            owner.model.readOnlyInformation = "Patch document. Edits are saved to the selected patch file."
            owner.window?.title = (title ?? url.lastPathComponent) + " – Unified Diff – TurtleGit"
            outcome = .success
        } catch { if !retired && !token.isCancelled { owner.model.error = error.localizedDescription;outcome = .failure } }
    }
    func encodedBytes() throws -> Data {
        guard let model = owner?.model else { return Data() }
        if !model.documentDirty { return model.exportDocument.bytes }
        do {return try model.encodedDocumentBytes()}
        catch FileComparisonEditFailure.encoding {throw Failure.encoding}
    }
    func save(as newFile: Bool = false) async -> Bool {
        guard !retired, let owner, !owner.model.busy, let window = owner.window, window.attachedSheet == nil else { return false }
        Self.activeOperations += 1;acceptedSaves += 1
        defer {
            Self.activeOperations -= 1;acceptedSaves -= 1
            if acceptedSaves==0{let waiters=saveWaiters;saveWaiters.removeAll();for waiter in waiters{waiter.resume()}}
        }
        let request = generation, snapshot: UnifiedDiffDocument
        do { snapshot = try owner.model.documentSnapshot() }
        catch FileComparisonEditFailure.encoding {owner.model.error=Failure.encoding.localizedDescription;return false}
        catch { owner.model.error = error.localizedDescription; return false }
        owner.model.busy = true
        defer { owner.model.busy = false }
        let target: URL?, access: RepositoryAccessLease?
        if newFile || fileURL == nil {
            target = await withCheckedContinuation { reply in chooseSave(window, fileURL?.lastPathComponent ?? "changes.patch") { reply.resume(returning: $0) } }
            guard !retired, let target else { return false }; access = acquireAccess(target)
        } else { target = fileURL; access = fileAccess }
        guard !retired, let target else { return false }
        if GitRuntime.isAppStoreBuild && access?.hasSecurityScope != true { owner.model.error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return false }
        let expected = !newFile && target == fileURL ? diskBytes : nil, token = OperationCancellation()
        cancellation = token
        defer { withExtendedLifetime(access) {}; cancellation = nil }
        do {
            try await Task.detached {
                try token.check()
                if let expected, try Data(contentsOf: target) != expected { throw Failure.changed }
                try token.check(); try snapshot.bytes.write(to: target, options: .atomic)
            }.value
            guard !retired, generation == request, !token.isCancelled else { return false }
            fileURL = target; fileAccess = access; diskBytes = snapshot.bytes
            owner.acceptDocumentSave(snapshot); owner.window?.representedURL = target
            return true
        } catch { if !retired && !token.isCancelled { owner.model.error = error.localizedDescription }; return false }
    }
    static func permitOwnerClose(_ documents: [PatchWindowController]) -> Bool {
        guard let child = documents.first(where: { $0.documentSession.dirty }) else { return true }
        child.window?.makeKeyAndOrderFront(nil); child.window?.performClose(nil); return false
    }
    func retire() {
        guard !retired else { return }; retired = true; generation += 1; cancellation?.cancel()
        settings?.retire()
        if let window = owner?.window, let sheet = window.attachedSheet, sheet !== settingsWindow { window.endSheet(sheet, returnCode: .cancel); sheet.close() }
        pendingReplacement = nil; updates = nil
        retiringReview=reviewWorkflow
        reviewWorkflow?.cancel(); reviewWorkflow = nil
        fileAccess = nil
    }
    /// Retain exactly this document's accepted operation and Apply child until
    /// they release their worker/sheet scopes. No unrelated window counters.
    func waitForRetirement()async {
        let pending=operationTask
        await pending?.value
        if acceptedSaves>0{await withCheckedContinuation{saveWaiters.append($0)}}
        var children:[ReviewPatchWorkflow]=[]
        for child in [retiringReview,reviewWorkflow].compactMap({$0}) {
            if !children.contains(where:{$0 === child}){children.append(child)}
        }
        for child in children{await child.cancelAndWaitForRetirement()}
        if retired{retiringReview=nil;reviewWorkflow=nil}
    }
}
