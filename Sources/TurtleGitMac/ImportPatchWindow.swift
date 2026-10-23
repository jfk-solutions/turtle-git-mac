// Adapts TortoiseGit's ImportPatchDlg controls and git-am workflow (see NOTICE).
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class ImportPatchWindowController: NSWindowController, NSWindowDelegate {
    let model: ImportPatchWindowModel
    var onClosed: () -> Void = {}
    private var approvedClose = false
    private var retired = false
    var canReuse:Bool {!retired && !model.closed}
    var hasPendingWork:Bool {activeOperation || window?.sheetParent != nil}
    private var releaseTask:Task<Void,Never>?
    private(set) static var activeReleases=0
    private(set) var presentationClosed=false
    private(set) var identitySession:NoteIdentitySession!
    private var mailCompletion:((String?)->Void)?
    private(set) var filePanel:NSOpenPanel?
    private var filePanelID=UUID()
    private var question:(UUID,NSAlert,(NSApplication.ModalResponse)->Void)?
    var presentFiles:(NSOpenPanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void = {panel,owner,reply in panel.beginSheetModal(for:owner,completionHandler:reply)}
    var selectedFiles:(NSOpenPanel)->[URL] = {$0.urls}
    var presentQuestion:(NSAlert,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Bool = {alert,owner,reply in guard owner.attachedSheet==nil else{return false};alert.beginSheetModal(for:owner,completionHandler:reply);return true}
    private var patch: PatchWindowController?
    private var review: WorkingTreePatchWindowController?
    private var sendPatch: SendMailWorkflow?
    var activeOperation: Bool { model.hasPendingWork || identitySession?.hasPendingWork == true || releaseTask != nil || model.pickingFiles || model.confirmingQuit || model.receivingDrop || model.busy || model.closing || model.openingViewer || model.composingMail || window?.attachedSheet != nil || patch?.model.busy == true || patch?.window?.attachedSheet != nil || review?.activeOperation == true }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, mailPresentation: ((NSWindowController) -> Void)? = nil) {
        model = ImportPatchWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Apply Patch Serial", preferences: preferences)
        window.isReleasedWhenClosed = false
        let host=NSHostingController(rootView: ImportPatchDialog(model:model).defaultAppStorage(preferences));host.sizingOptions=[]
        window.contentViewController=host
        super.init(window: window); window.delegate = self
        identitySession=NoteIdentitySession(repository:repository,access:access,preferences:preferences,parent:window)
        identitySession.available={ [weak model] in model?.closed==false && model?.confirmingQuit==false }
        model.requireIdentity={ [weak self] token in guard let self else{return false};return try await self.identitySession.require(token) }
        model.cancelIdentity={ [weak self] in self?.identitySession.cancel() }
        window.setContentSize(.init(width: 800, height: 620))
        window.contentMinSize = .init(width: 660, height: 460); window.center()
        model.childActive = { [weak self] in self?.review?.activeOperation == true || self?.review?.model.dirty == true || self?.review?.model.editingEnabled == true || self?.patch?.model.busy == true || self?.patch?.window?.attachedSheet != nil }
        model.onStateChanged = { [weak self] in self?.review?.model.updateParentState() }
        model.showReview = { [weak self] bytes, title, lease in
            guard let self else { return }
            self.review?.close()
            let controller = WorkingTreePatchWindowController(repository: repository, access: access, fileAccess: lease, bytes: bytes, title: title, preferences: preferences)
            controller.model.parentActive = { [weak self] in
                guard let self else { return true }
                return self.model.busy || self.model.closing || self.model.confirmingQuit || self.window?.attachedSheet != nil
            }
            controller.model.onChanged = { [weak self] output in self?.model.onChanged(output) }
            controller.model.onMutationStopped = { [weak self] in self?.model.onMutationStopped() }
            controller.model.onBusyChanged = { [weak self] in self?.model.objectWillChange.send() }
            controller.onClosed = { [weak self, weak controller] in if self?.review === controller { self?.review = nil; self?.model.objectWillChange.send() } }
            self.review = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
        model.chooseFiles = { [weak self] in self?.chooseFiles() }
        model.showPatch = { [weak self] bytes, title, alternate in
            guard let self,!self.retired,!self.model.closed else{return}
            if try await UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: preferences, title: title, permissions: access.map { [$0] } ?? []) { return }
            guard !self.retired,!self.model.closed else{return}
            self.patch = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: self.patch, title: title, preferences: preferences, onClosed: { [weak self] in self?.patch = nil })
        }
        model.composeMail = { [weak self] files, completion in
            guard let self else { completion("The patch window was closed."); return }
            do {
                let leases = self.model.items.filter { files.contains($0.file) }.map(\.access) + [access].compactMap { $0 }
                self.mailCompletion=completion
                let workflow = SendMailWorkflow(files: files, repository: repository, access: access,
                    fileAccess: leases, preferences: preferences, presentation: mailPresentation) { [weak self] _ in
                    guard let self else{return};self.sendPatch=nil
                    let done=self.mailCompletion;self.mailCompletion=nil;done?(nil)
                }
                self.sendPatch = workflow; workflow.start(); return
            }

        }
        model.chooseRecovery = { [weak self] in
            guard let self else { return nil }
            let response = await self.prompt("A patch import is active", "Resolve conflicts and stage the result before choosing Resolved.", buttons: ["Abort", "Skip", "Resolved", "Cancel"])
            return (0..<3).contains(response) ? [MailPatchRecovery.abort, .skip, .resolved][response] : nil
        }
        model.chooseClose = { [weak self] in
            guard let self else { return .cancel }
            let response = await self.prompt("A patch import is active", "Abort the import, or keep its state to continue later?", buttons: ["Abort", "Keep session", "Cancel"])
            return response == 0 ? .abort : response == 1 ? .keep : .cancel
        }
        model.chooseUnavailableClose = { [weak self] reason in
            guard let self else { return false }
            return await self.prompt("Could not check patch import state", reason + "\n\nClose this window and keep any existing Git state?", buttons: ["Close and keep state", "Cancel"]) == 0
        }
        model.close = { [weak self] in
            guard let self, let window = self.window else { return }
            self.approvedClose = true
            if let parent = window.sheetParent {
                parent.endSheet(window)
                window.close()
            } else { window.performClose(nil) }
        }
        DialogGeometry.attach(window, identifier: "ImportDlg", legacyName: "ImportDlg")
    }
    private func prompt(_ title: String, _ message: String, buttons: [String]) async -> Int {
        guard let window, window.attachedSheet == nil else { return -1 }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.effectiveAppearance
        for title in buttons { alert.addButton(withTitle: title) }
        // Cancel is the safe keyboard default; recovery remains an explicit choice.
        alert.buttons.first?.keyEquivalent = ""; alert.buttons.last?.keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons.last?.cell as? NSButtonCell
        let response=await ask(alert)
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
    private func ask(_ alert:NSAlert) async -> NSApplication.ModalResponse {
        guard !model.closed,question==nil,let window,window.attachedSheet==nil else{return .abort}
        let id=UUID()
        return await withCheckedContinuation { continuation in
            question=(id,alert,{continuation.resume(returning:$0)})
            if !presentQuestion(alert,window,{ [weak self] response in self?.settleQuestion(id,response) }) {settleQuestion(id,.abort)}
        }
    }
    private func settleQuestion(_ id:UUID,_ response:NSApplication.ModalResponse) {
        guard let pending=question,pending.0==id else{return};question=nil
        if let parent=pending.1.window.sheetParent {parent.endSheet(pending.1.window,returnCode:.abort)}
        pending.1.window.orderOut(nil)
        Task{@MainActor [self] in
            while pending.1.window.sheetParent != nil || window?.attachedSheet === pending.1.window {try? await Task.sleep(nanoseconds:5_000_000)}
            pending.1.window.close();pending.2(retired ? .abort:response)
        }
    }
    private func chooseFiles() {
        guard !activeOperation,model.editable,let window else{return}
        let catalog=model.catalogRevision,flags=model.optionIdentity,id=UUID();filePanelID=id
        let panel=NSOpenPanel();filePanel=panel;model.pickingFiles=true
        panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        panel.title="Add patches";panel.directoryURL=model.repository.root
        presentFiles(panel,window) { [weak self,weak panel] response in
            guard let self,let panel,self.filePanelID==id,self.filePanel === panel else{return}
            self.filePanel=nil;self.model.pickingFiles=false
            guard response == .OK,self.model.editable,self.model.catalogRevision==catalog,self.model.optionIdentity==flags else{return}
            self.model.add(self.selectedFiles(panel))
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        guard review?.activeOperation != true, sender.attachedSheet == nil, !model.confirmingQuit, !model.pickingFiles, !model.receivingDrop, !model.openingViewer, !model.composingMail, patch?.model.busy != true, patch?.window?.attachedSheet == nil else { return false }
        if let review, review.model.dirty {
            Task { [weak self] in if await review.model.resolveDraft() { self?.model.requestClose() } }
        } else { model.requestClose() }
        return false
    }
    override func close(){super.close();if !retired,window?.isVisible != true{retireOwner()}}
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else{return};retireOwner()
    }
    private func retireOwner() {
        guard !retired else{return};retired=true
        model.invalidate();identitySession.retire();filePanelID=UUID()
        if let pending=question {settleQuestion(pending.0,.abort)}
        let panel=filePanel;filePanel=nil
        if let panel {panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.orderOut(nil);panel.cancel(nil);panel.close()}
        let retiredPatch=patch,retiredReview=review,mailOptions=sendPatch?.options,mailProgress=sendPatch?.progress
        let retiringMail=sendPatch != nil
        sendPatch?.invalidate();sendPatch=nil
        patch?.model.confirmingQuit=false;review?.setQuitConfirmation(false)
        patch?.close();review?.close()
        let owner=window,parent=window?.sheetParent
        if let sheet=owner?.attachedSheet {owner?.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)}
        if let owner {parent?.endSheet(owner)}
        Self.activeReleases += 1
        releaseTask=Task{@MainActor [self] in
            // Forced closure retires UI immediately; ownership ends only when
            // actual reads, Git children, Settings and attached sheets drain.
            while identitySession.hasPendingWork || panel?.sheetParent != nil || owner?.attachedSheet != nil || owner?.sheetParent != nil || (owner != nil && parent?.attachedSheet === owner) || retiredPatch?.model.busy==true || retiredPatch?.window?.attachedSheet != nil || retiredReview?.hasPendingWork==true || mailOptions?.hasPendingWork==true || mailProgress?.model.hasPendingWork==true || mailOptions?.window?.attachedSheet != nil || mailProgress?.window?.attachedSheet != nil {
                try? await Task.sleep(nanoseconds:5_000_000)
            }
            if retiringMail {let done=mailCompletion;mailCompletion=nil;done?(nil)}
            while model.hasPendingWork {try? await Task.sleep(nanoseconds:5_000_000)}
            patch=nil;review=nil;presentationClosed=true;Self.activeReleases -= 1;releaseTask=nil
            let done=onClosed;onClosed={};done()
        }
    }
    func setQuitConfirmation(_ value: Bool) {
        model.confirmingQuit = value; review?.setQuitConfirmation(value)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ImportPatchWindowModel: ObservableObject {
    enum State: String { case pending = "", applying = "Applying", success = "Success", failed = "Failed", skipped = "Skipped" }
    enum CloseChoice { case abort, keep, cancel }
    enum ContextAction: String { case viewPatch = "View Patch", reviewPatch = "Review Patch with TurtleGitMerge", sendMail = "Send Mail…" }
    struct Item: Identifiable {
        let id = UUID()
        let file: URL
        let access: RepositoryAccessLease
        var checked = true
        var state = State.pending
    }
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let previewDocument: PatchWindowModel
    private(set) static var activeWorkers=0
    private(set) var pendingOperations=0
    var hasPendingWork:Bool {pendingOperations>0}
    private func beginWork(){pendingOperations += 1;Self.activeWorkers += 1}
    private func endWork(){pendingOperations -= 1;Self.activeWorkers -= 1}
    private(set) var catalogRevision=UUID()
    private var formRevision=UUID()
    struct FormContext:Equatable {let owner:ObjectIdentifier;let revision:UUID;let catalog:UUID}
    var formContext:FormContext {.init(owner:ObjectIdentifier(self),revision:formRevision,catalog:catalogRevision)}
    var optionIdentity:[Bool] {[options.threeWay,options.ignoreSpaceChange,options.signOff,options.keepCR]}
    private func accepts(_ context:FormContext)->Bool {editable && context==formContext}
    func option(_ key:WritableKeyPath<MailPatchOptions,Bool>,context:FormContext)->Binding<Bool> {
        Binding(get:{self.options[keyPath:key]},set:{value in guard self.accepts(context) else{return};self.options[keyPath:key]=value})
    }
    func select(_ ids:Set<UUID>,context:FormContext) {guard accepts(context) else{return};selection=ids.intersection(Set(items.map(\.id)))}
    func check(_ id:UUID,_ value:Bool,context:FormContext) {guard accepts(context) else{return};check(id,value)}
    func toggleChecks(_ ids:Set<UUID>,context:FormContext) {
        guard accepts(context) else{return};let eligible=items.filter {ids.contains($0.id) && $0.state != .success}
        let value = !eligible.allSatisfy(\.checked)
        for item in eligible {check(item.id,value)}
    }
    func move(_ direction:Int,context:FormContext) {guard accepts(context) else{return};move(direction)}
    func remove(context:FormContext) {guard accepts(context) else{return};remove()}
    func addFiles(context:FormContext) {guard accepts(context) else{return};chooseFiles()}
    func apply(context:FormContext) {guard accepts(context) else{return};apply()}
    func perform(_ action:ContextAction,ids:Set<UUID>,context:FormContext,alternate:Bool=false) {
        guard accepts(context) else{return}
        switch action {case .viewPatch:viewPatch(ids,alternate:alternate);case .reviewPatch:reviewPatch(ids);case .sendMail:sendMail(ids)}
    }
    var canMoveUp:Bool {editable && items.indices.first(where:{selection.contains(items[$0].id)}).map {$0>0}==true}
    var canMoveDown:Bool {editable && items.indices.last(where:{selection.contains(items[$0].id)}).map {$0<items.count-1}==true}
    @Published var pickingFiles=false {didSet {if oldValue != pickingFiles {formRevision=UUID()}}}
    @Published private(set) var items: [Item] = [] {didSet {catalogRevision=UUID()}}
    @Published var selection: Set<UUID> = [] { didSet { loadPreview() } }
    @Published var options = MailPatchOptions()
    @Published var tab = 0
    @Published private(set) var preview = ""
    @Published private(set) var previewNotice: String?
    @Published private(set) var output = ""
    @Published private(set) var busy = false { didSet { formRevision=UUID();onStateChanged() } }
    @Published private(set) var stopRequested = false
    @Published var confirmingQuit = false { didSet { formRevision=UUID();onStateChanged() } }
    @Published private(set) var closing = false { didSet { formRevision=UUID();onStateChanged() } }
    @Published private(set) var receivingDrop = false {didSet {if oldValue != receivingDrop {formRevision=UUID()}}}
    @Published private(set) var openingViewer = false {didSet {if oldValue != openingViewer {formRevision=UUID()}}}
    @Published private(set) var composingMail = false {didSet {if oldValue != composingMail {formRevision=UUID()}}}
    @Published var error: String?
    private var failedRow: UUID?
    private var failedRowSession:MailPatchRecoverySession?
    private var preparingIdentity=false
    private var invalidated = false
    private var operation: OperationCancellation?
    private var dropProgress:[Progress]=[]
    var activeCancellation: OperationCancellation? { operation }
    var closed: Bool { invalidated }
    private(set) var accepted = false
    private var previewGeneration = UUID()
    var chooseFiles: () -> Void = {}
    var onStateChanged: () -> Void = {}
    var childActive: () -> Bool = { false }
    var showReview: (Data, String, RepositoryAccessLease) throws -> Void = { _, _, _ in }
    var showPatch: (Data, String, Bool) async throws -> Void = { _, _, _ in }
    var composeMail: ([URL], @escaping (String?) -> Void) -> Void = { _, done in done("No mail composition service is available.") }
    var configureIdentity: () async throws -> Bool = { false }
    var requireIdentity:((OperationCancellation)async throws->Bool)?
    var cancelIdentity:()->Void={}
    var readSession:((OperationCancellation)async throws->MailPatchSession)?
    var readRecoverySession:((OperationCancellation)async throws->MailPatchRecoverySession?)?
    var recoverReviewedSession:((MailPatchRecovery,MailPatchRecoverySession,OperationCancellation)async throws->String)?
    var chooseRecovery: () async -> MailPatchRecovery? = { nil }
    var chooseClose: () async -> CloseChoice = { .cancel }
    var chooseUnavailableClose: (String) async -> Bool = { _ in false }
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onMutationStopped: () -> Void = {}
    var finished: Bool { !items.isEmpty && items.allSatisfy { $0.state == .success || $0.state == .skipped } }
    var editable: Bool { !pickingFiles && !confirmingQuit && !receivingDrop && !busy && !closing && !openingViewer && !composingMail && !invalidated && !childActive() }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access
        previewDocument = PatchWindowModel(repository: repository, access: access, appearancePreferences: preferences)
        previewDocument.setReadOnlyDiff(Data()); previewDocument.refreshAvailable = false
    }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; operation?.cancel();cancelIdentity();dropProgress.forEach {$0.cancel()}
        close = {}; onChanged = { _ in }; onMutationStopped = {}; onStateChanged = {};previewDocument.retire()
        previewGeneration = UUID(); items = []; selection = []
        pickingFiles=false
    }
    private func live(_ request: OperationCancellation) -> Bool { !invalidated && operation === request && !request.isCancelled }
    func contextActions(_ ids: Set<UUID>) -> [ContextAction] {
        guard editable else { return [] }
        let count = items.filter { ids.contains($0.id) }.count
        return count == 1 ? [.viewPatch, .reviewPatch, .sendMail] : count > 1 ? [.sendMail] : []
    }
    func viewPatch(_ ids: Set<UUID>, alternate: Bool) {
        guard editable, contextActions(ids).contains(.viewPatch), let item = items.first(where: { ids.contains($0.id) }) else { return }
        openingViewer = true;beginWork()
        Task {
            defer { endWork();openingViewer = false }
            do {
                // Retain the selected item and its lease through the viewer handoff.
                // The external viewer receives an exact app-owned byte snapshot.
                let bytes = try await Task.detached { try Data(contentsOf: item.file) }.value
                guard !invalidated else { return }
                try await showPatch(bytes, item.file.lastPathComponent, alternate)
            } catch { if !invalidated { self.error = error.localizedDescription } }
        }
    }
    func reviewPatch(_ ids: Set<UUID>) {
        guard editable, contextActions(ids).contains(.reviewPatch), let item = items.first(where: { ids.contains($0.id) }) else { return }
        openingViewer = true;beginWork()
        Task {
            defer { endWork();openingViewer = false }
            do {
                let bytes = try await Task.detached { try Data(contentsOf: item.file) }.value
                guard !invalidated else { return }
                try showReview(bytes, item.file.lastPathComponent, item.access)
            } catch { if !invalidated { self.error = error.localizedDescription } }
        }
    }
    func sendMail(_ ids: Set<UUID>) {
        guard editable, contextActions(ids).contains(.sendMail) else { return }
        let selected = items.filter { ids.contains($0.id) }
        composingMail = true;beginWork()
        var completed=false
        composeMail(selected.map(\.file)) { [self] error in
            guard !completed else{return};completed=true
            defer{self.composingMail=false;self.endWork();withExtendedLifetime(selected){}}
            guard !self.invalidated else { return }
            if let error { self.error = error }
        }
    }
    func add(_ urls: [URL], retaining grants: [RepositoryAccessLease] = []) {
        guard editable else { return }
        for url in urls {
            guard url.isFileURL else { error = MailPatchFailure.file.localizedDescription; continue }
            let lease = grants.first { $0.contains(url) && (!GitRuntime.isAppStoreBuild || $0.hasSecurityScope) } ?? RepositoryAccessLease(url: url)
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope || (access?.hasSecurityScope == true && access?.contains(url) == true) else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; continue }
            items.append(Item(file: url, access: lease))
        }
    }
    /// Matches CPatchListCtrl::OnDropFiles: ordered files, no directories or duplicates.
    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard editable else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        receivingDrop = true;beginWork()
        Task {
            defer {endWork();dropProgress=[];receivingDrop=false}
            var urls: [URL] = []
            var failure: String?
            for provider in files {
                guard !invalidated else{return}
                do {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        let progress=provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                            if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: error ?? MailPatchFailure.file) }
                        }
                        dropProgress.append(progress)
                    }
                    guard !invalidated else{return}
                    guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { throw MailPatchFailure.file }
                    urls.append(url)
                } catch { failure = error.localizedDescription }
            }
            receivingDrop = false
            guard !invalidated else { return }
            var paths = GitPathSet(items.map { FileTransferPaths.lexicalPath($0.file.path) })
            let newFiles = urls.filter { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return false }
                return paths.insert(FileTransferPaths.lexicalPath(url.path)).inserted
            }
            add(newFiles)
            if let failure { error = failure }
        }
        return true
    }
    func check(_ id: UUID, _ checked: Bool) {
        guard editable, let index = items.firstIndex(where: { $0.id == id }), items[index].state != .success else { return }
        items[index].checked = checked
        if items[index].state == .skipped { items[index].state = .pending }
    }
    func remove() {
        guard editable else { return }
        items.removeAll { selection.contains($0.id) }; selection = []
        // Retain failedRow's identity even if its row was removed: Git's active
        // session must still be recovered, without marking a different row done.
    }
    func move(_ direction: Int) {
        guard editable, direction == -1 || direction == 1 else { return }
        let indexes = items.indices.filter { selection.contains(items[$0].id) }
        guard let first = indexes.first, let last = indexes.last,
              direction < 0 ? first > 0 : last < items.count - 1 else { return }
        for index in direction < 0 ? indexes : indexes.reversed() { items.swapAt(index, index + direction) }
    }
    private func state(_ id: UUID, _ value: State) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = value }
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func loadPreview() {
        let legacy=ComparisonTextEncoding.legacyEncoding(from:previewDocument.appearancePreferences)
        let generation = UUID(); previewGeneration = generation; preview = ""; previewNotice = nil; previewDocument.setReadOnlyDiff(Data(),displayLegacyEncoding:legacy)
        guard !invalidated, selection.count == 1, let item = items.first(where: { selection.contains($0.id) }) else { return }
        beginWork()
        Task {
            defer {endWork()}
            let result = await Task.detached { () -> (Data?, String?) in
                let size = (try? item.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 250 * 1024 * 1024 else { return (nil, "This patch is too large to preview. It can still be imported.") }
                guard let data = try? Data(contentsOf: item.file) else { return (nil, "The patch could not be read.") }
                return (data, nil)
            }.value
            guard !invalidated, previewGeneration == generation else { return }
            if let bytes = result.0 { previewDocument.setReadOnlyDiff(bytes,displayLegacyEncoding:legacy); preview = previewDocument.document.text }
            else { previewNotice = result.1; preview = result.1 ?? "" }
        }
    }
    func apply() {
        guard editable,!items.isEmpty else{return}
        let batch=items,flags=options,finishing=finished
        let request=OperationCancellation();operation=request
        busy=true;stopRequested=false;error=nil
        beginWork()
        Task {
            defer {
                preparingIdentity=false
                if operation === request {operation=nil;busy=false;if !invalidated {onChanged(output)}}
                endWork();withExtendedLifetime(batch){}
            }
            do {
                try checkAccess()
                preparingIdentity=true
                let allowed=try await ensureIdentity(request)
                preparingIdentity=false
                guard live(request),allowed,!stopRequested else{return}
                // CheckUserData precedes IsFinish/OnOK and the Output tab in
                // upstream. A completed list must not bypass the same gate.
                if finishing {
                    if await confirmCloseState(request),live(request){accepted=finished;close()}
                    return
                }
                tab=1
                try await recoverSession(request)
                for item in batch {
                    guard live(request) else{return}
                    guard !stopRequested else{output += "\nBatch stopped after the current Git command.\n";break}
                    guard let current=items.first(where:{$0.id==item.id}),current.state != .success,current.state != .skipped else{continue}
                    guard current.checked else{state(item.id,.skipped);output += "\nSkipped: \(item.file.path)\n";continue}
                    state(item.id,.applying);output += "\nApplying: \(item.file.path)\n"
                    do {
                        let result=try await repository.importMailPatch(item.file,options:flags,cancellation:request)
                        guard live(request) else{return}
                        output += result+"\nSuccess\n";state(item.id,.success)
                    } catch {
                        guard live(request) else{return}
                        state(item.id,.failed);failedRow=item.id
                        failedRowSession=try? await recoverySnapshot(request)
                        throw error
                    }
                    onChanged(output)
                }
            } catch {
                guard live(request) else{return}
                output += "\n"+error.localizedDescription+"\n";self.error=error.localizedDescription
            }
        }
    }
    private func ensureIdentity(_ request:OperationCancellation)async throws->Bool {
        if let requireIdentity {return try await requireIdentity(request)}
        // Model-only callers retain a configurable repair seam. Production
        // controllers install the owned native Settings session above.
        while live(request),!stopRequested {
            if try await repository.replayUserIdentity(cancellation:request).complete{return live(request) && !stopRequested}
            guard live(request),!stopRequested,try await configureIdentity() else{return false}
        }
        return false
    }
    private func sessionState(_ request:OperationCancellation)async throws->MailPatchSession {
        if let readSession{return try await readSession(request)}
        return try await repository.mailPatchSession(cancellation:request)
    }
    private func recoverySnapshot(_ request:OperationCancellation)async throws->MailPatchRecoverySession? {
        if let readRecoverySession{return try await readRecoverySession(request)}
        return try await repository.mailPatchRecoverySession(cancellation:request)
    }
    private func recover(_ action:MailPatchRecovery,_ reviewed:MailPatchRecoverySession,_ request:OperationCancellation)async throws->String {
        if let recoverReviewedSession{return try await recoverReviewedSession(action,reviewed,request)}
        return try await repository.recoverMailPatch(action,reviewed:reviewed,cancellation:request)
    }
    private func recoverSession(_ request:OperationCancellation)async throws {
        var reviewed=try await recoverySnapshot(request)
        while let captured=reviewed {
            guard live(request),!stopRequested else{return}
            // A row is ours only while its failed am incarnation is still the
            // one being reviewed. Never mark another session's row successful.
            if failedRowSession != captured {failedRow=nil;failedRowSession=nil}
            guard let action=await chooseRecovery() else{if !invalidated {stopRequested=true};return}
            guard live(request),!stopRequested else{return}
            output += "\ngit am --\(action.rawValue)\n"
            do {
                let result=try await recover(action,captured,request)
                guard live(request) else{return}
                output += result+"\nDone\n"
            } catch {
                guard live(request) else{return}
                if error is OperationCancellationFailure || error is CancellationError {throw error}
                output += "\n"+error.localizedDescription+"\nFailed\n";onChanged(output)
                if case MailPatchFailure.changedSession=error {failedRow=nil;failedRowSession=nil;throw error}
                let next=try await recoverySnapshot(request)
                // An ordinary failure leaves recovery available. If its target
                // changed, a fresh Apply is required before any further action.
                guard next==captured else{failedRow=nil;failedRowSession=nil;throw MailPatchFailure.changedSession}
                reviewed=next;continue
            }
            reviewed=try await recoverySnapshot(request)
            if reviewed==nil {
                if let failedRow {
                    switch action {case .abort:state(failedRow,.pending);case .skip:state(failedRow,.skipped);case .resolved:state(failedRow,.success)}
                }
                failedRow=nil;failedRowSession=nil
            } else if failedRow != nil {failedRowSession=reviewed}
            onChanged(output)
        }
        // An externally ended session permits an explicit retry of its file.
        failedRow=nil;failedRowSession=nil
    }
    func requestStop() {
        guard busy else{return};stopRequested=true
        // Abort preparation promptly; once git am starts, preserve the source
        // behavior of stopping the batch after that current command completes.
        if preparingIdentity {operation?.cancel();cancelIdentity()}
    }
    func requestClose(accepted: Bool = false) {
        if busy { requestStop(); return }
        guard editable else { return }
        let request = OperationCancellation(); operation = request; closing = true
        beginWork()
        Task {
            defer { endWork();if operation === request { operation = nil; closing = false } }
            if await confirmCloseState(request), live(request) { self.accepted = accepted && finished; close() }
        }
    }
    /// Quit uses the same session choices without closing windows before every
    /// other document has approved termination.
    func confirmQuit() async -> Bool {
        guard !pickingFiles, !busy, !closing, !receivingDrop, !openingViewer, !composingMail, !invalidated else { return false }
        let request = OperationCancellation(); operation = request; closing = true
        beginWork()
        defer { endWork();if operation === request { operation = nil; closing = false } }
        return await confirmCloseState(request) && live(request)
    }
    private func confirmCloseState(_ request: OperationCancellation) async -> Bool {
        let session: MailPatchSession
        do {
            try checkAccess()
            session = try await sessionState(request)
            guard live(request) else { return false }
        } catch {
            guard live(request) else { return false }
            // Unknown state may only be kept, never automatically aborted.
            let answer = await chooseUnavailableClose(error.localizedDescription)
            return live(request) && answer
        }
        do {
            if session == .applying {
                let reviewed:MailPatchRecoverySession
                do {
                    guard let captured=try await recoverySnapshot(request) else{throw MailPatchFailure.changedSession}
                    reviewed=captured
                } catch {
                    guard live(request) else{return false}
                    // Broken bookkeeping must not trap the window. Explicit
                    // keep-state closure is available without authorizing Abort.
                    let keep=await chooseUnavailableClose(error.localizedDescription)
                    return live(request) && keep
                }
                let answer = await chooseClose(); guard live(request) else { return false }
                switch answer {
                case .cancel: return false
                case .keep: break
                case .abort:
                    let result = try await recover(.abort,reviewed,request)
                    guard live(request) else { return false }
                    output += result; onChanged(output)
                }
            }
            return live(request)
        } catch { if live(request) { self.error = error.localizedDescription }; return false }
    }

}

struct ImportPatchDialog: View {
    @ObservedObject var model: ImportPatchWindowModel
    private func tool(_ title: String, _ icon: MenuIcon, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Image(nsImage: icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16); Text(title);Spacer(minLength:0) } }
    }
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 10) {
            ImportPatchSplit(upper: AnyView(VStack(alignment: .leading, spacing: 10) {
            HStack(alignment:.top,spacing:12) {
                ImportPatchNativeList(model:model).frame(minHeight:120)
                    .onDrop(of:[UTType.fileURL],isTargeted:nil) {model.receiveDrop($0)}
                VStack(spacing:8) {
                    tool("Add…",.add) {model.addFiles(context:context)}
                    tool("Up",.jumpUp) {model.move(-1,context:context)}.disabled(!model.canMoveUp)
                    tool("Down",.jumpDown) {model.move(1,context:context)}.disabled(!model.canMoveDown)
                    tool("Remove",.remove) {model.remove(context:context)}.disabled(model.selection.isEmpty)
                }.frame(width:100).disabled(!model.editable)
            }
            HStack {
                Toggle("3 way merge", isOn: model.option(\.threeWay,context:context))
                Toggle("Ignore space change", isOn: model.option(\.ignoreSpaceChange,context:context))
                Toggle("Add \"Signed-off-by\"", isOn: model.option(\.signOff,context:context))
                Toggle("Keep CR", isOn: model.option(\.keepCR,context:context))
            }.disabled(!model.editable)
            }), lower: AnyView(ImportPatchTabs(model:model)), preferences: model.previewDocument.appearancePreferences)
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text(model.stopRequested ? "Stopping after current command…" : "Applying patches…") }
                Spacer()
                Button(model.finished ? "OK" : "Apply") { model.apply(context:context) }.keyboardShortcut(.defaultAction).disabled(!model.editable || model.items.isEmpty)
                Button(model.busy ? "Abort" : "Cancel") { model.requestClose() }.keyboardShortcut(.cancelAction).disabled(model.pickingFiles || model.confirmingQuit || model.receivingDrop || model.closing || model.stopRequested && model.busy)
                Button { TurtleGitHelp.show(.patches) } label: {CommandLabel(title:"Help",icon:.help)}
            }
        }.padding(16)
        .alert("Apply Patch Serial", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

/// Keep the source Patch/Log tabs inside the preview pane on every supported macOS.
struct ImportPatchTabs:NSViewRepresentable {
    @ObservedObject var model:ImportPatchWindowModel
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->NSTabView {
        let tabs=NSTabView();tabs.tabViewType = .topTabsBezelBorder;tabs.font = .systemFont(ofSize:NSFont.systemFontSize);tabs.delegate=context.coordinator
        tabs.setAccessibilityLabel("Patch and Log")
        for (index,title) in ["Patch","Log"].enumerated() {
            let host=NSHostingController(rootView:AnyView(EmptyView()));host.sizingOptions=[]
            context.coordinator.hosts.append(host)
            let item=NSTabViewItem(identifier:index);item.label=title;item.view=host.view;tabs.addTabViewItem(item)
        };return tabs
    }
    func updateNSView(_ tabs:NSTabView,context:Context) {
        let coordinator=context.coordinator;guard !coordinator.retired else{return}
        coordinator.model=model;coordinator.updating=true;defer {coordinator.updating=false}
        coordinator.hosts[0].rootView=AnyView(ImportPatchPreview(model:model).environment(\.colorScheme,context.environment.colorScheme).environment(\.isEnabled,context.environment.isEnabled).defaultAppStorage(model.previewDocument.appearancePreferences))
        coordinator.hosts[1].rootView=AnyView(OutputView(text:model.output,usesLogFont:true).environment(\.colorScheme,context.environment.colorScheme).environment(\.isEnabled,context.environment.isEnabled).defaultAppStorage(model.previewDocument.appearancePreferences))
        if tabs.selectedTabViewItem?.identifier as? Int != model.tab,tabs.tabViewItems.indices.contains(model.tab) {tabs.selectTabViewItem(at:model.tab)}
    }
    static func dismantleNSView(_ tabs:NSTabView,coordinator:Coordinator) {coordinator.retired=true;coordinator.model=nil;tabs.delegate=nil}
    @MainActor final class Coordinator:NSObject,NSTabViewDelegate {
        weak var model:ImportPatchWindowModel?
        var hosts:[NSHostingController<AnyView>]=[]
        var updating=false,retired=false
        func tabView(_ tabView:NSTabView,didSelect tabViewItem:NSTabViewItem?) {
            guard !retired,!updating,let model,!model.closed,let index=tabViewItem?.identifier as? Int else{return};model.tab=index
        }
    }
}
private struct ImportPatchPreview:View {
    @ObservedObject var model:ImportPatchWindowModel
    var body:some View {
        Group {
            if let notice=model.previewNotice {ScrollView {Text(notice).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(12)}}
            else {PatchTextView(model:model.previewDocument)}
        }
    }
}

@MainActor private final class ImportPatchMenuCommand:NSObject {
    let action:()->Void
    init(_ action:@escaping ()->Void) {self.action=action}
    @objc func invoke(_ sender:Any?) {action()}
}
@MainActor final class ImportPatchCheckButton:NSButton {
    var toggle:(Bool)->Void={_ in}
    convenience init() {self.init(frame:.zero);setButtonType(.switch);title="";target=self;action=#selector(changed(_:))}
    @objc private func changed(_ sender:NSButton) {guard isEnabled,window != nil else{return};toggle(state == .on)}
}
@MainActor final class ImportPatchNativeTable:NSTableView {
    let lifetime=TransportControlLifetime()
    var buildMenu:()->NSMenu?={nil}
    var activate:()->Void={}
    var toggleChecks:()->Void={}
    var contentWidth:CGFloat=300
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();lifetime.observe(self)}
    override func menu(for event:NSEvent)->NSMenu? {
        guard isEnabled,!lifetime.retired else{return nil}
        let row=self.row(at:convert(event.locationInWindow,from:nil))
        if row>=0,!selectedRowIndexes.contains(row) {selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
        return buildMenu()
    }
    override func keyDown(with event:NSEvent) {
        guard isEnabled,!lifetime.retired else{return}
        if event.keyCode==36 {activate();return}
        if event.keyCode==49 {toggleChecks();return}
        super.keyDown(with:event)
    }
    func fitViewport(_ viewport:NSSize) {
        let width=max(contentWidth,viewport.width)
        if tableColumns.first?.width != width {tableColumns.first?.width=width}
        let size=NSSize(width:width,height:max(CGFloat(numberOfRows)*(rowHeight+intercellSpacing.height),viewport.height))
        if frame.size != size {setFrameSize(size)}
    }
}
@MainActor final class ImportPatchNativeScroll:NSScrollView {
    private var fitting=false
    override func tile() {super.tile();guard !fitting,let table=documentView as? ImportPatchNativeTable else{return};fitting=true;defer {fitting=false};table.fitViewport(contentSize)}
}
struct ImportPatchNativeList:NSViewRepresentable {
    @ObservedObject var model:ImportPatchWindowModel
    func makeCoordinator()->Coordinator {Coordinator(model)}
    func makeNSView(context:Context)->NSScrollView {
        let table=ImportPatchNativeTable();table.headerView=nil;table.allowsMultipleSelection=true;table.rowHeight=24;table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Patch files");table.identifier = .init("ImportPatch.Files")
        let column=NSTableColumn(identifier:.init("path"));column.maxWidth = .greatestFiniteMagnitude;table.addTableColumn(column)
        table.delegate=context.coordinator;table.dataSource=context.coordinator;table.target=context.coordinator;table.doubleAction=#selector(Coordinator.viewPatch(_:))
        table.buildMenu={ [weak coordinator=context.coordinator] in coordinator?.menu() }
        table.activate={ [weak coordinator=context.coordinator] in coordinator?.viewPatch(nil) }
        table.toggleChecks={ [weak coordinator=context.coordinator] in guard let coordinator,coordinator.available,let context=coordinator.context else{return};coordinator.model.toggleChecks(coordinator.selectedIDs,context:context) }
        context.coordinator.table=table
        let scroll=ImportPatchNativeScroll();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.borderType = .bezelBorder;scroll.documentView=table;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {context.coordinator.model=model;context.coordinator.update()}
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {
        if let table=coordinator.table {NativeListSelection.remove(from:table)}
        coordinator.retired=true;coordinator.table?.lifetime.retire();coordinator.table?.delegate=nil;coordinator.table?.dataSource=nil;coordinator.table?.buildMenu={nil};coordinator.table?.activate={};coordinator.table?.toggleChecks={}
    }
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var model:ImportPatchWindowModel
        weak var table:ImportPatchNativeTable?
        var retired=false,updating=false
        fileprivate var context:ImportPatchWindowModel.FormContext?
        private var rows:[ImportPatchWindowModel.Item]=[]
        private var renderedRevision:UUID?
        private var applying:UUID?
        init(_ model:ImportPatchWindowModel) {self.model=model}
        var available:Bool {!retired && table?.lifetime.retired==false && table?.window != nil && model.editable}
        var selectedIDs:Set<UUID> {Set(table?.selectedRowIndexes.compactMap {rows.indices.contains($0) ? rows[$0].id:nil} ?? [])}
        func update() {
            guard !retired,let table,!table.lifetime.retired else{return}
            updating=true;defer {updating=false}
            let changedContext=context != model.formContext
            context=model.formContext
            if renderedRevision != model.catalogRevision || changedContext {
                let origin=table.enclosingScrollView?.contentView.bounds.origin ?? .zero
                rows=model.items;renderedRevision=model.catalogRevision;table.reloadData()
                table.enclosingScrollView?.contentView.scroll(to:origin)
            }
            NativeListSelection.install(on:table,preferences:model.previewDocument.appearancePreferences,primaryColumn:table.tableColumns.first,labelText:{[weak self] row in guard let self,self.rows.indices.contains(row) else{return nil};return self.rows[row].file.path},leadingInset:29)
            let selected=IndexSet(rows.indices.filter {model.selection.contains(rows[$0].id)})
            if selected != table.selectedRowIndexes {table.selectRowIndexes(selected,byExtendingSelection:false)}
            table.isEnabled=model.editable
            let font=NSFont.systemFont(ofSize:NSFont.systemFontSize)
            table.contentWidth=max(300,rows.map {($0.file.path as NSString).size(withAttributes:[.font:font]).width+45}.max() ?? 0)
            table.fitViewport(table.enclosingScrollView?.contentSize ?? .zero)
            let nextApplying=rows.first(where:{$0.state == .applying})?.id
            if nextApplying != applying,let id=nextApplying,let index=rows.firstIndex(where:{$0.id==id}) {table.scrollRowToVisible(index)}
            applying=nextApplying
        }
        func numberOfRows(in tableView:NSTableView)->Int {rows.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard rows.indices.contains(row),let context else{return nil}
            let item=rows[row],cell=NSTableCellView(),button=ImportPatchCheckButton()
            button.frame=NSRect(x:3,y:2,width:22,height:20);button.state=item.checked ? .on:.off;button.isEnabled=model.editable && item.state != .success
            button.setAccessibilityLabel("Import "+item.file.lastPathComponent)
            button.toggle={ [weak model,weak table] value in guard table?.lifetime.retired==false else{return};model?.check(item.id,value,context:context) }
            let text=NSTextField(labelWithString:item.file.path);text.frame=NSRect(x:29,y:2,width:max(270,(table?.contentWidth ?? 300)-34),height:20);text.autoresizingMask=[.width]
            text.font = item.state == .applying ? .boldSystemFont(ofSize:NSFont.systemFontSize):.systemFont(ofSize:NSFont.systemFontSize)
            switch item.state {case .failed:text.textColor = .systemRed;case .success:text.textColor = .systemGreen;case .skipped:text.textColor = .systemBrown;default:text.textColor = .labelColor}
            text.lineBreakMode = .byClipping;cell.addSubview(button);cell.addSubview(text);cell.textField=text;cell.toolTip=item.file.path+(item.state.rawValue.isEmpty ? "":" — "+item.state.rawValue)
            return cell
        }
        func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {
            guard rows.indices.contains(row) else{return nil}
            let view=NativeListSelectionRowView()
            if [.success,.failed,.skipped].contains(rows[row].state) {
                view.backgroundColor=NSColor(name:nil) {appearance in NSColor(white:appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? 0.25:0.78,alpha:1)}
            };return view
        }
        func selectionShouldChange(in tableView:NSTableView)->Bool {updating || available}
        func tableViewSelectionDidChange(_ notification:Notification) {guard !updating,available,let context else{return};model.select(selectedIDs,context:context)}
        @objc func viewPatch(_ sender:Any?) {guard available,let context else{return};model.perform(.viewPatch,ids:selectedIDs,context:context,alternate:NSEvent.modifierFlags.contains(.shift))}
        func menu()->NSMenu? {
            guard available,let context else{return nil}
            let ids=selectedIDs,menu=NSMenu();menu.autoenablesItems=false
            for action in model.contextActions(ids) {
                let entry=NSMenuItem(title:action.rawValue,action:nil,keyEquivalent:"")
                entry.image=(action == .sendMail ? MenuIcon.sendMail:.patch).contextImage(defaults:model.previewDocument.appearancePreferences)
                let command=ImportPatchMenuCommand { [weak self,weak model] in
                    guard let self,self.available,let model,self.model === model else{return}
                    model.perform(action,ids:ids,context:context,alternate:NSEvent.modifierFlags.contains(.shift))
                }
                entry.target=command;entry.action=#selector(ImportPatchMenuCommand.invoke(_:));entry.representedObject=command;menu.addItem(entry)
            };return menu
        }
    }
}

/// Native divider; the source persists AMDlgSizer in ResizableState.
struct ImportPatchSplit: NSViewControllerRepresentable {
    let upper: AnyView
    let lower: AnyView
    let preferences: UserDefaults
    private func hosted(_ view: AnyView, environment: EnvironmentValues) -> AnyView {
        AnyView(view.environment(\.colorScheme,environment.colorScheme).environment(\.isEnabled,environment.isEnabled).defaultAppStorage(preferences))
    }
    func makeNSViewController(context: Context) -> ImportPatchSplitController {
        ImportPatchSplitController(upper: hosted(upper, environment: context.environment), lower: hosted(lower, environment: context.environment), preferences: preferences)
    }
    func updateNSViewController(_ controller: ImportPatchSplitController, context: Context) {
        controller.upper.rootView = hosted(upper, environment: context.environment); controller.lower.rootView = hosted(lower, environment: context.environment)
    }
}

@MainActor final class ImportPatchSplitController: NSViewController, NSSplitViewDelegate {
    static let positionKey = WindowGeometryStore.prefix + "AMDlgSizer"
    let splitView = NSSplitView()
    let upper: NSHostingController<AnyView>
    let lower: NSHostingController<AnyView>
    private let preferences: UserDefaults
    private var initialized = false
    init(upper: AnyView, lower: AnyView, preferences: UserDefaults) {
        self.upper = NSHostingController(rootView: upper); self.lower = NSHostingController(rootView: lower)
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() { view = splitView }
    override func viewDidLoad() {
        super.viewDidLoad(); splitView.isVertical = false; splitView.dividerStyle = .thin
        splitView.setAccessibilityLabel("Patch list and preview divider")
        upper.sizingOptions = []; lower.sizingOptions = []
        addChild(upper); addChild(lower)
        splitView.addArrangedSubview(upper.view); splitView.addArrangedSubview(lower.view)
        splitView.delegate = self; splitView.adjustSubviews()
    }
    private func fitted(_ value: CGFloat) -> CGFloat {
        let available = max(0, splitView.bounds.height - splitView.dividerThickness)
        let topMinimum = min(220, available / 2), bottomMinimum = min(160, available / 2)
        return min(max(value, topMinimum), available - bottomMinimum)
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.bounds.height > 0 else { return }
        let stored = preferences.double(forKey: Self.positionKey)
        let wanted = initialized ? upper.view.frame.height : stored.isFinite && stored > 0 ? CGFloat(stored) : splitView.bounds.height / 2
        let height = fitted(wanted), divider = splitView.dividerThickness
        upper.view.frame = NSRect(x: 0, y: 0, width: splitView.bounds.width, height: height)
        lower.view.frame = NSRect(x: 0, y: height + divider, width: splitView.bounds.width, height: max(0, splitView.bounds.height - height - divider))
        initialized = true
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { fitted(0) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { fitted(.greatestFiniteMagnitude) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard initialized else { return }
        let position = Double(upper.view.frame.height)
        guard position.isFinite, position > 0 else { return }
        if preferences.double(forKey: Self.positionKey) != position { preferences.set(position, forKey: Self.positionKey) }
    }
}

@MainActor final class WorkingTreePatchWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let editorFileMenu = MergeEditorFileMenu()
    var editorCommandMenu: MergeEditorCommandMenu?
    var editorToolbar:MergeEditorToolbar?
    var commandsAvailable:Bool { !retired && !preparingReplacement && editorOpenWorkflow == nil }
    var editorOpenWorkflow: MergeEditorOpenWorkflow?
    var replacementOwner: MergeEditorReplacementOwner?
    weak var sharedReplacementOwner: MergeEditorReplacementOwner?
    var preparingReplacement: Bool { (sharedReplacementOwner ?? replacementOwner)?.preparingPatch == true }
    func windowDidBecomeKey(_ notification: Notification) { editorFileMenu.remove();editorCommandMenu?.install() }
    func windowDidResignKey(_ notification: Notification) { editorCommandMenu?.remove();editorFileMenu.remove() }
    func detachForReplacement() { editorToolbar?.retire();editorCommandMenu?.retire();editorFileMenu.remove(); model.retire(); model.window = nil }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { !retired && !activeOperation && !preparingReplacement && (item.action == #selector(openMergeDocument(_:)) || item.action == #selector(reloadEditor(_:))) }
    @objc func reloadEditor(_ sender: Any?) {
        guard !activeOperation, !preparingReplacement else { return }
        Task { if await model.resolveDraft() { model.refresh() } }
    }
    @objc func openMergeDocument(_ sender: Any?) {
        guard !retired, !activeOperation, !preparingReplacement, let window else { return }
        let workflow = MergeEditorOpenWorkflow(window: window, permissions: model.openPermissions, preferences: model.openPreferences)
        editorOpenWorkflow = workflow
        workflow.onClosed = { [weak self] in self?.editorOpenWorkflow = nil }
        workflow.accept = { [weak self] request, permissions in
            guard let self, let window = self.window, !self.model.busy, !self.model.confirmingQuit else { throw OperationCancellationFailure.cancelled }
            let owner = self.sharedReplacementOwner ?? self.replacementOwner ?? MergeEditorReplacementOwner(onClosed: self.onClosed)
            if self.sharedReplacementOwner == nil { self.replacementOwner = owner }
            try owner.replace(request, permissions: permissions, preferences: self.model.openPreferences, window: window, previous: self)
        }
        workflow.start(dirty: model.dirty, description: window.title, save: { [weak self] completion in
            guard let self else { completion(false); return }; self.model.saveDraft(completion: completion)
        })
    }
    let model: WorkingTreePatchWindowModel
    var onClosed: () -> Void = {}
    private var approvedClose = false
    private var retired = false
    private var releaseTask:Task<Void,Never>?
    static private(set) var activeReleases=0
    var canReuse:Bool {!retired && !model.retired}
    var hasPendingWork:Bool {releaseTask != nil || activeOperation || window?.sheetParent != nil}
    var activeOperation: Bool { editorOpenWorkflow != nil || model.busy || model.confirmingQuit || model.draftDecisionPending || model.previewDocument.busy || model.editor?.hasPendingEditorChoice == true || model.editor?.busy == true || model.conflictOperationActive || window?.attachedSheet != nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, fileAccess: RepositoryAccessLease?, bytes: Data, title: String, preferences: UserDefaults = .standard, directoryMode: Bool = false, isGitWorkingTree: Bool = true, initialStripCount: Int = 1, initialTextEncodingPolicy:MergeTextEncodingPolicy? = nil, automaticallyRefresh: Bool = true) {
        model = WorkingTreePatchWindowModel(repository: repository, access: access, fileAccess: fileAccess, bytes: bytes, preferences: preferences, directoryMode: directoryMode, isGitWorkingTree: isGitWorkingTree, initialStripCount: initialStripCount,initialTextEncodingPolicy:initialTextEncodingPolicy)
        let window = TextConflictNSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) – Review Patch – TurtleGitMerge"; window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: WorkingTreePatchDialog(model: model).defaultAppStorage(preferences)); host.sizingOptions = []
        window.contentViewController = host
        super.init(window: window); window.delegate = self; window.patchModel = model; window.openMergeDocument = { [weak self] in self?.openMergeDocument(nil) }; model.window = window
        window.setContentSize(.init(width: 1100, height: 720)); window.contentMinSize = .init(width: 800, height: 460); window.center()
        DialogGeometry.attach(window, identifier: "TurtleGit.PatchReview")
        model.close = { [weak self] in self?.approvedClose = true; self?.window?.performClose(nil) }
        model.chooseDraft = { [weak self] in
            guard let window = self?.window, window.attachedSheet == nil else { return .cancel }
            let alert = NSAlert(); alert.messageText = "Save the edited patched result?"
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
            alert.buttons[0].keyEquivalent = ""; alert.buttons[2].keyEquivalent = "\r"; alert.window.defaultButtonCell = alert.buttons[2].cell as? NSButtonCell
            let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            return response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .cancel
        }
        model.onConflictEditorChanged = { [weak self] conflict in
            guard let self else {return}
            self.editorToolbar?.retire();self.editorToolbar = nil
            if let conflict,let window = self.window {
                self.editorToolbar = MergeEditorToolbar.conflict(model:conflict,window:window,ownerReady:{ [weak self] in self?.commandsAvailable == true },open:{ [weak self] in self?.openMergeDocument(nil) },reload:{ [weak self] in self?.reloadEditor(nil) },help:{TurtleGitHelp.show(.patches)})
            }
            self.editorCommandMenu?.remove()
            if self.window?.isKeyWindow == true {self.editorCommandMenu?.install()}
        }
        editorCommandMenu = MergeEditorCommandMenu.patchReview(self)
        if automaticallyRefresh { model.refresh(encodingPolicy:initialTextEncodingPolicy) }
    }
    func setQuitConfirmation(_ value: Bool) { model.confirmingQuit = value; model.previewDocument.confirmingQuit = value }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !preparingReplacement else { return false }
        if approvedClose { return true }
        guard !activeOperation else { return false }
        if model.dirty { model.requestClose(); return false }
        return true
    }
    override func close(){super.close();if !retired,window?.isVisible != true{retireOwner()}}
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else{return};retireOwner()
    }
    private func retireOwner() {
        guard !retired else{return};retired=true
        editorToolbar?.retire();editorCommandMenu?.retire();editorFileMenu.remove()
        let opening=editorOpenWorkflow;opening?.retire();editorOpenWorkflow=nil
        let editor=model.editor,conflict=model.conflictEditor
        model.retire()
        let owner=window,parent=window?.sheetParent
        if let sheet=owner?.attachedSheet {owner?.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)}
        if let owner {parent?.endSheet(owner)}
        Self.activeReleases += 1
        releaseTask=Task{@MainActor [self,opening,editor,conflict] in
            while model.busy || model.draftDecisionPending || model.previewDocument.busy || editor?.busy == true || editor?.hasPendingEditorChoice == true || conflict?.busy == true || conflict?.preparing == true || conflict?.formatPending == true || conflict?.exportingSource == true || owner?.attachedSheet != nil || owner?.sheetParent != nil || (owner != nil && parent?.attachedSheet === owner) {
                try? await Task.sleep(nanoseconds:5_000_000)
            }
            withExtendedLifetime(opening){}
            Self.activeReleases -= 1;releaseTask=nil
            let done=onClosed;onClosed={};done()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class WorkingTreePatchWindowModel: ObservableObject {
    var mergeToolReadOnly = false
    var mergeToolOriginalLabel: String?
    var mergeToolPatchedLabel: String?
    static private(set) var activeOperations = 0
    private(set) var retired = false
    private var operation: OperationCancellation?
    private var specialQuestion:NSAlert?
    private(set) var saveQuestion:NSAlert?
    var presentSaveQuestion:((NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var chooseSpecialResolution:((WorkingTreePatchResolutionChoice,WorkingTreePatchFileComparison) async -> Bool)?
    @Published private(set) var keptCurrentPaths:Set<Data> = []
    @Published private(set) var specialSavedResult:WorkingTreePatchSaveResult?
    @Published private(set) var specialResolutionChoice:WorkingTreePatchResolutionChoice?
    var specialComparison:WorkingTreePatchFileComparison? {
        guard let comparison,comparison.requiresMerge,comparison.recoveryKind != .text else {return nil}
        return comparison
    }
    var canResolveSpecial:Bool {!mergeToolReadOnly && editable && !requiresRefresh && specialComparison.map {!appliedPaths.contains(Data($0.document.destination.path.utf8))} == true}
    enum DraftChoice { case save, discard, cancel }
    let repository: GitRepository
    let directoryMode: Bool
    let isGitWorkingTree: Bool
    var openPreferences: UserDefaults { preferences }
    var openPermissions: [RepositoryAccessLease] { [access, fileAccess].compactMap { $0 } + (editor?.openPermissions ?? []) + (conflictEditor?.openPermissions ?? []) }
    private let preferences: UserDefaults
    private(set) var reviewEncodingPolicy=MergeTextEncodingPolicy(preferUTF8:false)
    private let access: RepositoryAccessLease?
    private let fileAccess: RepositoryAccessLease?
    private let bytes: Data
    let previewDocument: PatchWindowModel
    @Published private(set) var review: WorkingTreePatchReview?
    @Published private(set) var selected: Set<Int> = []
    @Published private(set) var appliedPaths: Set<Data> = []
    @Published private(set) var fileResults: [Data: WorkingTreePatchFileResult] = [:]
    @Published private(set) var fileInspections:[Data:WorkingTreePatchFileInspection] = [:]
    var onConflictEditorChanged:(TextConflictWindowModel?)->Void = {_ in}
    @Published private(set) var conflictEditor:TextConflictWindowModel? {didSet {onConflictEditorChanged(conflictEditor)}}
    private var conflictChanges:AnyCancellable?
    var conflictOperationActive:Bool {conflictEditor.map {$0.busy || $0.preparing || $0.formatPending || $0.exportingSource} == true}
    @Published private(set) var highlightedFiles = Set<Int>()
    private(set) var fileListGeneration = UUID()
    private var comparisonRead = false
    var canPatchFiles: Bool { !mergeToolReadOnly && canReplaceComparison && !requiresRefresh && review?.files.contains(where: { !appliedPaths.contains($0.pathBytes) }) == true }
    @Published private(set) var batchProgress:WorkingTreePatchProgress?
    @Published private(set) var batchCompleted=0
    @Published private(set) var batchTotal=0
    @Published private(set) var batchCancelled=false
    private var batchApplying=false
    @Published private(set) var fileListVisible = true
    var canToggleFileList:Bool { !retired && review?.files.isEmpty == false && !confirmingQuit && !draftDecisionPending && window?.attachedSheet == nil }
    func toggleFileList() {
        guard canToggleFileList else {return}
        fileListVisible.toggle()
        if !fileListVisible,let table = window?.firstResponder as? NSTableView,table.identifier?.rawValue == "TurtleGit.Patch.Files",let destination = afterScroll?.documentView {
            window?.makeFirstResponder(destination)
        }
    }
    var canHighlightFiles:Bool { !retired && !conflictOperationActive && editor?.hasPendingEditorChoice != true && (!busy || comparisonRead) && !dirty && !editingEnabled && !confirmingQuit && !draftDecisionPending && !requiresRefresh }
    func highlightFiles(_ ids: Set<Int>) {
        guard canHighlightFiles,let review else {return}
        // Source LVN_ITEMCHANGED changes selection only; preview is explicit.
        highlightedFiles = ids.intersection(Set(review.files.map(\.id)))
    }
    func canPreviewFiles(_ ids:Set<Int>,generation:UUID) -> Bool {
        generation == fileListGeneration && canReplaceComparison && !requiresRefresh && ids.count == 1 && review?.files.contains(where:{ ids.contains($0.id) && !appliedPaths.contains($0.pathBytes) }) == true
    }
    func previewFiles(_ ids:Set<Int>,generation:UUID) {
        guard canPreviewFiles(ids,generation:generation) else {return}
        focusFile(ids.first)
    }
    func fileState(_ file:WorkingTreePatchReview.File) -> String {
        if keptCurrentPaths.contains(file.pathBytes) {return "kept current"}
        if appliedPaths.contains(file.pathBytes) {return "patched"}
        if let result = fileResults[file.pathBytes],!result.success {return result.requiresMerge ? "conflict" : "error"}
        switch fileInspections[file.pathBytes]?.state {case .error:return "error";case .conflict:return "conflict";default:return ""}
    }
    func patchFiles(_ ids: Set<Int>, generation: UUID) {
        guard generation == fileListGeneration, canPatchFiles, let review else { return }
        let targets = Set(review.files.filter { ids.contains($0.id) && !appliedPaths.contains($0.pathBytes) }.map(\.id))
        guard !targets.isEmpty, let token = begin() else { return }
        selectedReview = nil
        let reverse = reversed, strip = stripCount
        let autoAdd=MergeEditorPreferences.load(from:preferences).autoAdd
        var engine = try? SubversionMergeConfiguration.bundled();engine?.options = .load(from:preferences)
        let capturedEngine=engine,policy=reviewEncodingPolicy
        batchApplying=true;batchProgress=nil;batchCompleted=0;batchTotal=Set(review.files.filter{targets.contains($0.id)}.map(\.pathBytes)).count;batchCancelled=false
        Task { [self] in
            defer { finish(token) }
            var reported = false
            do {
                try checkAccess()
                let batch = try await repository.applyWorkingTreePatchBatch(review, fileIDs: targets, mergeConfiguration:capturedEngine,autoAddNewFiles:autoAdd,textEncodingPolicy:policy, cancellation: token,onProgress:{ [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,!self.retired,self.operation === token,self.batchApplying else{return}
                        self.batchProgress=progress;self.batchCompleted=progress.completedIndex;self.batchTotal=progress.total
                    }
                }) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, !self.retired, self.operation === token,self.batchApplying else { return }
                        self.fileResults[result.pathBytes] = result
                        if result.success { self.appliedPaths.insert(result.pathBytes) }
                        self.batchCompleted += 1
                    }
                }
                batchApplying=false
                let report = batch.files.map { ( $0.success ? "Patched: " : "Error: " ) + String(decoding: $0.pathBytes, as: UTF8.self) + "\n" + $0.output + ($0.addError.map{"\nSaved patched file, but Add failed: " + $0} ?? "") }.joined(separator: "\n")
                // Notify the repository owner even if the window was closed after
                // a file changed; UI publications still require the live token.
                if batch.files.contains(where: \.success) { onChanged(report) } else { onMutationStopped() }
                reported = true
                guard !retired, operation === token else { return }
                for result in batch.files { fileResults[result.pathBytes] = result; if result.success { appliedPaths.insert(result.pathBytes) } }
                batchCompleted=batch.files.count;batchCancelled=batch.cancelled;batchProgress=nil
                output += "\n" + report + "\n"
                if batch.cancelled {notice="Patching canceled. Completed files remain patched; refresh to inspect the remaining files."}
                try ensure(token)
                try await load(reverse: reverse, strip: strip, token: token)
                let failures=batch.files.filter{!$0.success}.count,warnings=batch.files.filter{$0.addError != nil || $0.postApplyError != nil}.count
                if failures>0 || warnings>0 {notice="Patched \(batch.files.filter(\.success).count) of \(batch.files.count) files. \(failures) failed; \(warnings) saved with warnings. Select a file to inspect its result."}
            } catch {
                if !reported { onMutationStopped() }
                if !retired && !token.isCancelled { notice = error.localizedDescription }
            }
        }
    }
    @Published private(set) var busy = false { didSet { updateParentState(); onBusyChanged() } }
    @Published var confirmingQuit = false { didSet {if confirmingQuit && !oldValue {fileListGeneration=UUID();cancelOperation()};updateParentState() } }
    @Published private(set) var reversed = false
    @Published private(set) var stripCount = 1
    @Published private(set) var comparison: WorkingTreePatchFileComparison?
    @Published private(set) var editor: FileComparisonWindowModel?
    private var editorChanges: AnyCancellable?
    @Published private(set) var draftDecisionPending = false { didSet { updateParentState(); onBusyChanged() } }
    var chooseDraft: () async -> DraftChoice = { .cancel }
    weak var window: NSWindow? { didSet { editor?.window = window;conflictEditor?.window = window } }
    var alignment: FileComparisonAlignment? { editor?.alignment }
    var dirty: Bool { conflictEditor?.dirty == true || editor?.dirty == true }
    var editingEnabled: Bool { editor?.patchEditingEnabled == true }
    var canReplaceComparison: Bool { editable && !dirty && !editingEnabled }
    var canEditResult: Bool { !mergeToolReadOnly && editable && !requiresRefresh && (editor?.savedPaneURL(base: false) != nil || comparison.map({ !appliedPaths.contains(Data($0.document.destination.path.utf8)) }) == true) && alignment != nil && editor?.canEdit(base: false) == true }
    var canSaveDraft: Bool { !mergeToolReadOnly && (conflictEditor.map {editable && !$0.patchResultCompleted && $0.document != nil} ?? (canEditResult && editingEnabled)) }
    @Published private(set) var focusedFile: Int?
    @Published private(set) var comparisonNotice = ""
    @Published var previewTab = 0
    @Published var difference = -1
    weak var beforeScroll: NSScrollView?
    weak var afterScroll: NSScrollView?
    private var synchronizingScroll = false
    @Published private(set) var requiresRefresh = false
    @Published private(set) var notice = ""
    @Published private(set) var output = ""
    private var selectedReview: WorkingTreePatchReview?
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onMutationStopped: () -> Void = {}
    var onBusyChanged: () -> Void = {}
    var parentActive: () -> Bool = { false }
    var editable: Bool { !retired && !busy && !conflictOperationActive && editor?.busy != true && editor?.hasPendingEditorChoice != true && !confirmingQuit && !draftDecisionPending && !previewDocument.busy && !parentActive() }
    private func begin() -> OperationCancellation? {
        guard !retired, !busy else { return nil }
        let token = OperationCancellation(); operation = token; busy = true; Self.activeOperations += 1
        return token
    }
    private func finish(_ token: OperationCancellation) {
        Self.activeOperations -= 1
        if operation === token {
            batchApplying=false;batchProgress=nil
            operation = nil; busy = false
            if !retired && token.isCancelled {
                if editor?.dirty == true { notice = "Operation canceled. Draft retained; retry Save, or discard edits and refresh." }
                else { requiresRefresh = true; notice = "Operation canceled. Refresh to check current files." }
            }
            if !retired, !token.isCancelled, !requiresRefresh, highlightedFiles.count == 1,
               let wanted = review?.files.first(where: { highlightedFiles.contains($0.id) && !appliedPaths.contains($0.pathBytes) }), wanted.id != focusedFile {
                focusFile(wanted.id)
            }
        }
    }
    private func ensure(_ token: OperationCancellation) throws {
        guard !retired, operation === token, !token.isCancelled else { throw OperationCancellationFailure.cancelled }
    }
    func cancelOperation() {operation?.cancel();dismissSpecialQuestion();dismissSaveQuestion();editor?.cancelOutput();editor?.cancelPaneSave();conflictEditor?.cancelPatchOperation()}
    private func dismissSaveQuestion(){
        guard let question=saveQuestion else{return}
        if let window,question.window.sheetParent === window {window.endSheet(question.window,returnCode:.abort)}
        question.window.orderOut(nil)
    }
    /// Explicit FileSave asks about an empty result and honors Backup. Automatic
    /// PatchSave deliberately uses the Core nil-options policy instead.
    private func explicitSaveOptions(text:String,path:String,backup:Bool,cancellation:OperationCancellation) async throws -> MergeFileSaveOptions? {
        try cancellation.check()
        guard !retired,!confirmingQuit else{throw OperationCancellationFailure.cancelled}
        guard text.isEmpty else{return .init(backupOriginal:backup,emptyResult:.keep)}
        guard let window,window.attachedSheet==nil,saveQuestion==nil else{return nil}
        let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="File is empty."
        alert.informativeText="Delete “\((path as NSString).lastPathComponent)” or keep the empty file?"
        alert.addButton(withTitle:"Delete");alert.addButton(withTitle:"Cancel — Keep Empty File").keyEquivalent="\u{1b}"
        saveQuestion=alert
        let response=await withCheckedContinuation {continuation in
            var answered=false
            let answer:(NSApplication.ModalResponse)->Void={response in guard !answered else{return};answered=true;continuation.resume(returning:response)}
            if let presentSaveQuestion {presentSaveQuestion(alert,answer)}
            else {alert.beginSheetModal(for:window,completionHandler:answer)}
        }
        while alert.window.sheetParent != nil || window.attachedSheet === alert.window {try? await Task.sleep(nanoseconds:5_000_000)}
        if saveQuestion === alert {saveQuestion=nil}
        try cancellation.check()
        guard !retired,!confirmingQuit,response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else{return nil}
        return .init(backupOriginal:backup,emptyResult:response == .alertFirstButtonReturn ? .delete:.keep)
    }
    private func dismissSpecialQuestion() {
        guard let question = specialQuestion else {return};specialQuestion = nil
        if let window,question.window.sheetParent === window {window.endSheet(question.window,returnCode:.alertFirstButtonReturn)}
        question.window.orderOut(nil)
    }
    func retire() {
        guard !retired else { return }; retired = true; operation?.cancel();dismissSpecialQuestion();dismissSaveQuestion()
        fileListGeneration = UUID()
        previewDocument.retire(); editor?.retireImageLoader(); editorChanges = nil;conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil
        beforeScroll = nil; afterScroll = nil; close = {}; chooseDraft = { .cancel }; onBusyChanged = {}
    }
    var canApply: Bool { !mergeToolReadOnly && canReplaceComparison && !requiresRefresh && selectedReview?.canApply == true && !selected.isEmpty }
    init(repository: GitRepository, access: RepositoryAccessLease?, fileAccess: RepositoryAccessLease?, bytes: Data, preferences: UserDefaults = .standard, directoryMode: Bool = false, isGitWorkingTree: Bool = true, initialStripCount: Int = 1,initialTextEncodingPolicy:MergeTextEncodingPolicy? = nil) {
        self._stripCount = Published(initialValue: initialStripCount)
        self.directoryMode = directoryMode; self.isGitWorkingTree = isGitWorkingTree
        self.repository = repository; self.access = access; self.fileAccess = fileAccess; self.bytes = bytes; self.preferences = preferences;reviewEncodingPolicy=initialTextEncodingPolicy ?? MergeTextEncodingPolicy(defaults:preferences)
        previewDocument = PatchWindowModel(repository: repository, access: access, appearancePreferences: preferences)
        previewDocument.setReadOnlyDiff(bytes,displayLegacyEncoding:reviewEncodingPolicy.legacyEncoding); previewDocument.refreshAvailable = false
    }
    func setReversed(_ value: Bool) {
        guard canReplaceComparison, value != reversed else { return }
        reversed = value; requiresRefresh = true; selectedReview = nil; comparison = nil; editor?.retireImageLoader(); editor = nil; editorChanges = nil; conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil; beforeScroll = nil; afterScroll = nil; notice = "Refresh to check the changed options."
    }
    func setStripCount(_ value: Int) {
        guard canReplaceComparison, value != stripCount else { return }
        stripCount = value; requiresRefresh = true; selectedReview = nil; comparison = nil; editor?.retireImageLoader(); editor = nil; editorChanges = nil; conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil; beforeScroll = nil; afterScroll = nil; notice = "Refresh to check the changed options."
    }
    private func checkAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func refresh(encodingPolicy:MergeTextEncodingPolicy? = nil,completion: (() -> Void)? = nil) {
        guard canReplaceComparison, let token = begin() else { completion?(); return }; selectedReview = nil; appliedPaths = []; keptCurrentPaths = []; comparison = nil; editor?.retireImageLoader(); editor = nil; editorChanges = nil; conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil; beforeScroll = nil; afterScroll = nil
        fileResults = [:];fileInspections = [:]
        let reverse = reversed, strip = stripCount,policy=encodingPolicy ?? MergeTextEncodingPolicy(defaults:preferences)
        Task {
            defer { finish(token); completion?() }
            do { try checkAccess(); try await load(reverse: reverse, strip: strip, token: token,encodingPolicy:policy) }
            catch { if !retired && !token.isCancelled { review = nil; selected = []; notice = error.localizedDescription } }
        }
    }
    private func load(reverse: Bool, strip: Int, token: OperationCancellation, retainingSavedComparison: Bool = false,encodingPolicy:MergeTextEncodingPolicy? = nil) async throws {
        try ensure(token)
        // One accepted read owns the container and target decoding policy across
        // discovery, review, simulation and selected application. Original patch
        // bytes remain the Copy/Save payload even for BOM-less Unicode text.
        let policy=encodingPolicy ?? reviewEncodingPolicy
        let next = try await repository.reviewWorkingTreePatch(bytes, reversed: reverse, stripCount: strip, directoryMode: directoryMode, isGitWorkingTree: isGitWorkingTree,textEncodingPolicy:policy, cancellation: token)
        try ensure(token)
        previewDocument.setReadOnlyDiff(bytes,displayLegacyEncoding:policy.legacyEncoding,sourceEncoding:next.document.sourceEncoding)
        reviewEncodingPolicy=policy
        review = next; requiresRefresh = false; fileListGeneration = UUID()
        highlightedFiles.formIntersection(Set(next.files.map(\.id)))
        selected = Set(next.files.filter { !appliedPaths.contains($0.pathBytes) }.map(\.id))
        try await validateSelection(token)
        let inspections = try await repository.inspectWorkingTreePatchFiles(next,excluding:appliedPaths,textEncodingPolicy:reviewEncodingPolicy,cancellation:token)
        try ensure(token);fileInspections = inspections
        if !retainingSavedComparison { await loadComparison(token) }
    }
    private func validateSelection(_ token: OperationCancellation) async throws {
        try ensure(token)
        selectedReview = nil
        guard let review, !selected.isEmpty else { notice = appliedPaths.isEmpty ? "Select files to apply." : "Selected files have been applied."; return }
        let next = try await repository.reviewWorkingTreePatchFiles(review, fileIDs: selected, cancellation: token)
        try ensure(token)
        selectedReview = next; notice = next.validationError ?? "Choose files to patch, or patch all remaining files."
    }
    func focusFile(_ id: Int?) {
        guard canReplaceComparison, !requiresRefresh else { return }
        if let id, let file = review?.files.first(where: { $0.id == id }) {
            // FilePatchesDlg does not reopen or redirect an already-patched row.
            if appliedPaths.contains(file.pathBytes) { return }
            if let result = fileResults[file.pathBytes], !result.success && !result.requiresMerge {
                comparisonNotice = result.output; return
            }
        } else if id != nil { return }
        guard let token = begin() else { return }
        focusedFile = id
        comparisonRead = true
        Task { defer { comparisonRead = false; finish(token) }; await loadComparison(token) }
    }
    private func loadComparison(_ token: OperationCancellation) async {
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        guard (try? ensure(token)) != nil else { return }
        comparison = nil;specialSavedResult = nil;specialResolutionChoice = nil; editor?.retireImageLoader(); editor = nil; editorChanges = nil; conflictEditor?.retire();conflictEditor = nil;conflictChanges = nil; beforeScroll = nil; afterScroll = nil; comparisonNotice = ""; difference = -1
        guard let review else { focusedFile = nil; return }
        let file: WorkingTreePatchReview.File?
        if let focusedFile { file = review.files.first(where: { $0.id == focusedFile }) }
        else { file = review.files.first(where: { !appliedPaths.contains($0.pathBytes) }) }
        guard let file else { focusedFile = nil; return }
        guard !appliedPaths.contains(file.pathBytes) else { return }
        if let result = fileResults[file.pathBytes], !result.success && !result.requiresMerge { comparisonNotice = result.output; return }
        focusedFile = file.id
        do {
            try checkAccess()
            let value = try await repository.compareWorkingTreePatchFile(review, fileID: file.id,textEncodingPolicy:reviewEncodingPolicy, cancellation: token)
            try ensure(token)
            comparison = value
            if value.requiresMerge {
                if value.recoveryKind == .text {installConflict(value)}
                else {onConflictEditorChanged(nil);comparisonNotice = "Choose the current or patched file state to complete this file."}
                return
            }
            let nextEditor = FileComparisonWindowModel(patchComparison: value, access: access, preferences: preferences)
            nextEditor.configureMergeToolReadOnly(mergeToolReadOnly)
            nextEditor.window = window; nextEditor.retainPermissions(openPermissions)
            nextEditor.onExportStateChanged = { [weak self] in self?.updateParentState(); self?.onBusyChanged() }
            nextEditor.onRegisterScroll = { [weak self] scroll, base in if base { self?.beforeScroll = scroll } else { self?.afterScroll = scroll } }
            editorChanges = nextEditor.objectWillChange.sink { [weak self] in self?.objectWillChange.send(); self?.onBusyChanged() }
            editor = nextEditor; updateParentState()
        } catch { if !retired && !token.isCancelled { comparisonNotice = error.localizedDescription } }
    }
    func resolveSpecial(_ choice:WorkingTreePatchResolutionChoice) {
        guard canResolveSpecial,let comparison = specialComparison,let token = begin() else {return}
        let generation = fileListGeneration
        let autoAdd=MergeEditorPreferences.load(from:preferences).autoAdd
        Task { [self] in
            defer {finish(token)}
            var reported = false
            do {
                let accepted:Bool
                if let chooseSpecialResolution {accepted = await chooseSpecialResolution(choice,comparison)}
                else if choice == .patched,comparison.document.destination.mode == nil {
                    guard let window,window.attachedSheet == nil else {return}
                    let question = NSAlert();question.alertStyle = .warning;question.messageText = "Delete “" + comparison.document.base.path + "”?"
                    question.informativeText = "The patch deletes this file. Delete the reviewed current version?"
                    let cancel = question.addButton(withTitle:"Cancel");cancel.keyEquivalent = "\r";question.addButton(withTitle:"Delete").keyEquivalent = ""
                    question.window.defaultButtonCell = cancel.cell as? NSButtonCell
                    specialQuestion = question
                    let response = await withCheckedContinuation {continuation in question.beginSheetModal(for:window) {continuation.resume(returning:$0)}}
                    if specialQuestion === question {specialQuestion = nil}
                    accepted = response == .alertSecondButtonReturn
                } else {accepted = true}
                try ensure(token)
                guard accepted,generation == fileListGeneration,self.comparison?.fileID == comparison.fileID else {return}
                try checkAccess()
                let saved = try await repository.resolveWorkingTreePatchFile(comparison,choice:choice,autoAddNewFiles:autoAdd,cancellation:token)
                onChanged(saved.output);reported = true
                try ensure(token)
                specialSavedResult = saved;specialResolutionChoice = choice
                if choice == .current {keptCurrentPaths.insert(Data(comparison.document.destination.path.utf8))}
                appliedPaths.insert(Data(comparison.document.destination.path.utf8));output += saved.output
                comparisonNotice = choice == .current ? "Current working file and paths kept." : "Selected patched file state saved."
                if let failure = saved.addError {notice = "Saved selected file state, but Add failed: " + failure}
                if let failure=saved.postApplyError {notice=failure;requiresRefresh=true}
            } catch {
                if !reported {onMutationStopped()}
                if !retired,!token.isCancelled {notice = error.localizedDescription;output += notice + "\n"}
            }
        }
    }
    private func installConflict(_ comparison:WorkingTreePatchFileComparison) {
        let next = TextConflictWindowModel(repository:repository,access:access,path:comparison.document.destination.path)
        next.configureMergeToolReadOnly(mergeToolReadOnly)
        next.patchComparison = comparison;next.window = window;next.comparisonDefaults = preferences
        next.workingMergePermissions = [access,fileAccess].compactMap {$0}
        next.patchResultSaver = { [weak self,weak next] text,encoding,cancellation in
            guard let self,let next,!self.retired,let document = next.document,let cancellation else {throw OperationCancellationFailure.cancelled}
            let autoAdd=MergeEditorPreferences.load(from:self.preferences).autoAdd,backup=MergeFileSaveOptions.backupEnabled(from:self.preferences)
            do {
                try self.checkAccess()
                guard let options=try await self.explicitSaveOptions(text:text,path:comparison.document.destination.path,backup:backup,cancellation:cancellation) else{throw OperationCancellationFailure.cancelled}
                guard self.conflictEditor === next else{throw OperationCancellationFailure.cancelled}
                let saved = try await self.repository.saveWorkingTreePatchFile(next.patchComparison ?? comparison,text:text,encoding:encoding,autoAddNewFiles:autoAdd,options:options,cancellation:cancellation)
                self.onChanged(saved.output)
                if !self.retired {
                    self.appliedPaths.insert(Data(comparison.document.destination.path.utf8));self.output += saved.output
                    next.patchResultCompleted = true;next.resetHistory()
                    if let failure = saved.addError {self.notice = "Saved patched result, but Add failed: " + failure}
                    if let failure=saved.postApplyError {self.notice=failure;self.requiresRefresh=true}
                }
                return try document.recordingPatchSave(saved)
            } catch {self.onMutationStopped();throw error}
        }
        next.onChanged = {_ in}
        conflictChanges = next.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send();self?.onBusyChanged() }
        conflictEditor = next;next.load();updateParentState()
    }
    enum ComparisonPresentation: Equatable { case text, processing, failure(String), binary, empty }
    var comparisonPresentation: ComparisonPresentation {
        guard comparison != nil else { return .empty }
        if editor?.filtering == true { return .processing }
        if alignment != nil { return .text }
        if let error = editor?.error { return .failure(error) }
        if editor?.document?.base.text != nil && editor?.document?.destination.text != nil {
            return .failure("The text comparison is unavailable. Refresh to rebuild its preview.")
        }
        return .binary
    }
    func synchronizeScroll(from scroll: NSScrollView) {
        guard !synchronizingScroll else { return }
        let other = scroll === beforeScroll ? afterScroll : beforeScroll
        guard let other else { return }
        synchronizingScroll = true; defer { synchronizingScroll = false }
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.minX, y: scroll.contentView.bounds.minY))
        other.reflectScrolledClipView(other.contentView)
    }
    func navigate(_ step: Int) {
        guard editable, let alignment, !alignment.differences.isEmpty else { return }
        difference = min(max(difference + step, 0), alignment.differences.count - 1)
        let row = alignment.differences[difference].lowerBound
        for (scroll, base) in [(beforeScroll, true), (afterScroll, false)] {
            guard let text = scroll?.documentView as? NSTextView else { continue }
            let cells = alignment.rows.map { base ? $0.base : $0.destination }
            let offset = cells.prefix(row).reduce(0) { $0 + ($1.displayText as NSString).length + 1 }
            text.setSelectedRange(NSRange(location: min(offset, (text.string as NSString).length), length: 0))
            text.scrollRangeToVisible(text.selectedRange())
        }
    }
    func undoPreview() {if let conflictEditor {conflictEditor.undo()} else {editor?.undo()}}
    func redoPreview() {if let conflictEditor {conflictEditor.redo()} else {editor?.redo()}}
    var canUndoPreview:Bool {conflictEditor?.canUndo ?? editor?.canUndo ?? false}
    var canRedoPreview:Bool {conflictEditor?.canRedo ?? editor?.canRedo ?? false}
    func findComparison() {
        guard editable else { return }
        if conflictEditor != nil {(window as? TextConflictNSWindow)?.find(.showFindInterface);return}
        guard let view = afterScroll?.documentView as? NSTextView else { return }
        view.window?.makeFirstResponder(view)
        let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(sender)
    }
    func updateParentState() {
        editor?.busy = busy || editor?.exporting == true
        editor?.confirmingQuit = confirmingQuit || draftDecisionPending || parentActive()
        let blocked = confirmingQuit || draftDecisionPending || busy || parentActive()
        if conflictEditor?.confirmingQuit != blocked {conflictEditor?.confirmingQuit = blocked}
        objectWillChange.send()
    }
    func setEditing(_ value: Bool) {
        guard canEditResult, !dirty else { return }
        editor?.setPatchEditing(value)
    }
    func discardDraft() {
        guard editable else { return }
        resetComparisonDraft()
    }
    private func resetComparisonDraft() {
        guard let comparison else { return }
        if conflictEditor != nil {conflictEditor?.retire();conflictChanges = nil;installConflict(comparison);return}
        editor?.resetHistory(); editor?.retireImageLoader(); beforeScroll = nil; afterScroll = nil
        let next = FileComparisonWindowModel(patchComparison: comparison, access: access, preferences: preferences)
        next.window = window; next.retainPermissions(openPermissions)
        next.onExportStateChanged = { [weak self] in self?.updateParentState(); self?.onBusyChanged() }
        next.onRegisterScroll = { [weak self] scroll, base in if base { self?.beforeScroll = scroll } else { self?.afterScroll = scroll } }
        editorChanges = next.objectWillChange.sink { [weak self] in self?.objectWillChange.send(); self?.onBusyChanged() }
        editor = next; updateParentState(); onBusyChanged()
    }
    func saveDraft(completion: ((Bool) -> Void)? = nil) {
        if let conflictEditor {guard canSaveDraft else {completion?(false);return};conflictEditor.save(markResolved:false,completion:completion);return}
        guard canSaveDraft, let token = begin() else { completion?(false); return }
        let policy=savePolicy()
        Task { let saved = await performSave(token,policy:policy); finish(token); completion?(saved) }
    }
    private struct SavePolicy {let autoAdd:Bool,backup:Bool}
    private func savePolicy()->SavePolicy {.init(autoAdd:MergeEditorPreferences.load(from:preferences).autoAdd,backup:MergeFileSaveOptions.backupEnabled(from:preferences))}
    private func performSave(_ token: OperationCancellation,policy:SavePolicy) async -> Bool {
        guard !retired, let comparison, let editor, editor.canEdit(base: false) else { return false }
        if editor.savedPaneURL(base: false) != nil {
            let saved = await withCheckedContinuation { continuation in editor.saveReboundResultFromOwner { continuation.resume(returning: $0) } }
            if saved { onChanged("Saved selected pane: " + (editor.savedPaneURL(base: false)?.path ?? "")) }
            else { onMutationStopped() }
            guard !retired, operation === token, !token.isCancelled else { return false }
            if saved { output += "Saved selected pane: " + (editor.savedPaneURL(base: false)?.path ?? "") + "\n" }
            return saved
        }
        let text = editor.draftText(base: false), encoding = editor.encoding(base: false)
        let autoAdd=policy.autoAdd,backup=policy.backup
        var reported = false
        do {
            try checkAccess()
            guard let options=try await explicitSaveOptions(text:text,path:comparison.document.destination.path,backup:backup,cancellation:token) else{return false}
            try ensure(token)
            let saved = try await repository.saveWorkingTreePatchFile(comparison, text: text, encoding: encoding, autoAddNewFiles: autoAdd,options:options, cancellation: token)
            onChanged(saved.output); reported = true
            try ensure(token)
            appliedPaths.insert(Data(comparison.document.destination.path.utf8)); output += saved.output
            // Publication already happened. Keep its warning and require an
            // explicit fresh read instead of accepting an unverified savepoint.
            if let failure=saved.postApplyError {notice=failure;requiresRefresh=true;return false}
            try editor.acceptPatchSave(saved.document)
            try await load(reverse: reversed, strip: stripCount, token: token, retainingSavedComparison: true)
            if let failure = saved.addError { notice = "Saved patched result, but Add failed: " + failure; output += notice + "\n"; return false }
            return true
        } catch {
            if !reported { onMutationStopped() }
            if !retired && !token.isCancelled { notice = error.localizedDescription; output += notice + "\n" }
            return false
        }
    }
    func resolveDraft(discardImmediately: Bool = true) async -> Bool {
        guard !retired, !conflictOperationActive, editor?.hasPendingEditorChoice != true else { return false }
        guard dirty else { return true }
        guard !busy, !draftDecisionPending else { return false }
        draftDecisionPending = true; Self.activeOperations += 1
        defer { draftDecisionPending = false; Self.activeOperations -= 1 }
        let choice = await chooseDraft()
        guard !retired else { return false }
        switch choice {
        case .cancel: return false
        case .save:
            if let conflictEditor {return await withCheckedContinuation {continuation in conflictEditor.saveForQuit {continuation.resume(returning:$0)}}}
            guard let token = begin() else { return false }
            let policy=savePolicy()
            defer { finish(token) }
            return await performSave(token,policy:policy)
        case .discard:
            if discardImmediately { resetComparisonDraft() }
            return true
        }
    }
    func requestClose() { Task { if await resolveDraft() { close() } } }
    func check(_ id: Int, _ value: Bool) {
        guard canReplaceComparison, !requiresRefresh, let file = review?.files.first(where: { $0.id == id }), !appliedPaths.contains(file.pathBytes) else { return }
        if value { selected.insert(id) } else { selected.remove(id) }
        guard let token = begin() else { return }; selectedReview = nil
        Task { defer { finish(token) }; do { try checkAccess(); try await validateSelection(token) } catch { if !retired && !token.isCancelled { notice = error.localizedDescription } } }
    }
    func apply() {
        guard canApply, let selection = selectedReview, let token = begin() else { return }; selectedReview = nil
        let reverse = reversed, strip = stripCount
        Task {
            defer { finish(token) }
            var reported = false
            do {
                try checkAccess()
                let result = try await repository.applyWorkingTreePatch(selection, cancellation: token)
                onChanged(result + "\nApplied \(selection.files.count) file(s).\n"); reported = true
                try ensure(token)
                appliedPaths.formUnion(selection.files.map(\.pathBytes)); output += result + "\nApplied \(selection.files.count) file(s).\n"
                try await load(reverse: reverse, strip: strip, token: token)
            } catch {
                if !reported { onMutationStopped() }
                if !retired && !token.isCancelled { notice = error.localizedDescription; output += "\n" + notice + "\n" }
            }
        }
    }
}

private struct WorkingTreePatchFileList: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    var body: some View {
        VStack(alignment: .leading) {
                    Text("Files to patch:")
                    WorkingTreePatchNativeFileList(model:model)
                    Button { model.patchFiles(model.highlightedFiles, generation: model.fileListGeneration) } label: {
                        Text("Patch selected item").frame(maxWidth: .infinity)
                    }.disabled(!model.canPatchFiles || model.highlightedFiles.isEmpty)
                    Button { model.patchFiles(Set(model.review?.files.map(\.id) ?? []), generation: model.fileListGeneration) } label: {
                        Text("Patch all items").frame(maxWidth: .infinity)
                    }.disabled(!model.canPatchFiles)
                }.frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
    }
}

struct WorkingTreePatchDialog: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.repository.root.path).lineLimit(1).help(model.repository.root.path)
                Spacer()
                Button(model.fileListVisible ? "Hide file list" : "Show file list") {model.toggleFileList()}.disabled(!model.canToggleFileList)
                Toggle("Reverse patch", isOn: Binding(get: { model.reversed }, set: { model.setReversed($0) }))
                Text("Strip paths:"); TextField("Strip paths", value: Binding(get: { model.stripCount }, set: { model.setStripCount($0) }), formatter: NumberFormatter()).frame(width: 45)
                Button("Refresh") { model.refresh() }
            }.disabled(!model.canReplaceComparison)
            HSplitView {
                if model.fileListVisible { WorkingTreePatchFileList(model: model) }
                TabView(selection: $model.previewTab) {
                    WorkingTreePatchComparisonView(model: model).tabItem { Text("Compare") }.tag(0)
                    VStack(alignment: .leading) { Text("Original patch:"); PatchTextView(model: model.previewDocument) }.tabItem { Text("Original patch") }.tag(1)
                }.frame(minWidth: 440)
            }
            Text(model.notice).foregroundStyle(model.canApply ? Color.secondary : Color.orange).textSelection(.enabled)
            if let current=model.batchProgress {
                VStack(alignment:.leading,spacing:4) {
                    Text(model.repository.root.appendingPathComponent(String(decoding:current.pathBytes,as:UTF8.self)).path)
                        .lineLimit(1).truncationMode(.middle)
                        .help(model.repository.root.appendingPathComponent(String(decoding:current.pathBytes,as:UTF8.self)).path)
                    ProgressView(value:Double(model.batchCompleted),total:Double(max(1,model.batchTotal)))
                        .accessibilityLabel("Patching files")
                    Text("\(model.batchCompleted) of \(model.batchTotal) files completed").font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("Patch batch progress")
            } else if model.batchTotal>0 {
                Text("\(model.batchCompleted) of \(model.batchTotal) files completed" + (model.batchCancelled ? " — canceled":""))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("Patch batch result")
            }
            if !model.output.isEmpty { DisclosureGroup("Output") { OutputView(text: model.output, usesLogFont: true).frame(height: 100) } }
            HStack {
                if model.busy || model.editor?.exporting == true || model.conflictEditor?.busy == true { ProgressView().controlSize(.small); Text(model.editor?.exporting == true ? "Saving copy…" : "Processing patch…"); Button("Cancel operation", action: model.cancelOperation) }
                Spacer()
                Button("Close") { model.requestClose() }.disabled(!model.editable)
            }
        }.padding(16)
    }
}

struct WorkingTreePatchComparisonView: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    private func pane(base: Bool) -> some View {
        let content = base ? (model.editor?.document?.base ?? model.comparison?.document.base) : (model.editor?.document?.destination ?? model.comparison?.document.destination)
        return VStack(alignment: .leading, spacing: 5) {
            Text(base ? (model.mergeToolOriginalLabel ?? "Before patch") : (model.mergeToolPatchedLabel ?? "After patch")).font(.headline)
            if let content {
                Text(content.path).font(.caption).lineLimit(1).help(content.path)
                if let alignment = model.alignment {
                    // Keep the coordinator, native editor and Undo manager alive
                    // while the authoritative engine refines the provisional rows.
                    WorkingTreePatchComparisonEditor(model: model, cells: alignment.rows.map { base ? $0.base : $0.destination }, base: base)
                        .overlay(alignment: .topTrailing) {
                            if model.comparisonPresentation == .processing { ProgressView("Comparing…").controlSize(.small).padding(6).allowsHitTesting(false) }
                        }
                } else if case .failure(let error) = model.comparisonPresentation {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if model.comparisonPresentation == .processing {
                    ProgressView("Comparing…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text("Binary or unsupported text encoding · \(content.bytes.count) bytes\n" + content.bytes.prefix(4096).enumerated().map { ($0.offset % 16 == 0 ? "\n" : " ") + String(format: "%02X", $0.element) }.joined())
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("\(content.mode ?? "Absent") · \(content.bytes.count) bytes").font(.caption).foregroundStyle(.secondary)
            } else { Color(nsColor: .textBackgroundColor) }
        }.padding(6).frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
    }
    var body: some View {
        VStack(alignment: .leading) {
            if let special = model.specialComparison {
                PatchSpecialRecoveryView(model:model,comparison:special)
            } else if let conflict = model.conflictEditor {
                PatchMergeEditor(model:conflict)
                if conflict.dirty {Button("Discard edits") {model.discardDraft()}.disabled(!model.editable)}
            } else {
            HStack {
                Button { model.navigate(-1) } label: { Image(nsImage: MenuIcon.mergePreviousConflict.image() ?? NSImage()) }.help("Previous difference").accessibilityLabel("Previous difference").disabled(model.difference <= 0)
                Button { model.navigate(1) } label: { Image(nsImage: MenuIcon.mergeNextConflict.image() ?? NSImage()) }.help("Next difference").accessibilityLabel("Next difference").disabled(model.alignment?.differences.isEmpty != false || model.difference >= (model.alignment?.differences.count ?? 0) - 1)
                Button { model.findComparison() } label: { CommandLabel(title: "Find", icon: .mergeFind) }.disabled(model.alignment == nil)
                Button { model.saveDraft() } label: { CommandLabel(title: "Save patched result", icon: .mergeSave) }.disabled(!model.canSaveDraft)
                Button("Discard edits") { model.discardDraft() }.disabled(!model.editingEnabled)
                Spacer()
                Toggle("Edit patched result", isOn: Binding(get: { model.editingEnabled }, set: { model.setEditing($0) })).disabled(!model.canEditResult || model.dirty)
            }.disabled(!model.editable)
            HSplitView { pane(base: true); pane(base: false) }
            if let error = model.editor?.error, model.alignment != nil {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.editor?.error = nil }
                }.accessibilityElement(children: .contain).accessibilityLabel("Comparison error")
            }
            }
            if model.requiresRefresh { Text("Refresh to compare the changed options.").foregroundStyle(.orange) }
            else if !model.comparisonNotice.isEmpty { Text(model.comparisonNotice).foregroundStyle(.orange).textSelection(.enabled) }
            else if model.comparison == nil { Text("Select a file to compare.").foregroundStyle(.secondary) }
        }.padding(6)
    }
}

struct WorkingTreePatchComparisonEditor: View {
    @ObservedObject var model: WorkingTreePatchWindowModel
    let cells: [MergeSourceCell]
    let base: Bool
    var body: some View {
        if let editor = model.editor { WorkingTreePatchPreparedEditor(editor: editor, base: base).id(ObjectIdentifier(editor)) }
    }
}
private struct WorkingTreePatchPreparedEditor: View {
    @ObservedObject var editor: FileComparisonWindowModel
    let base: Bool
    var body: some View {
        VStack(alignment: .leading) {
            FileComparisonEditor(model: editor, cells: editor.alignment?.rows.map { base ? $0.base : $0.destination } ?? [], base: base)
            MergeFormatControls(label: base ? "Before" : "After", encoding: editor.encoding(base: base), text: editor.document == nil ? nil : editor.draftText(base: base), editable: editor.canTransfer(toBase: base), changeEncoding: { editor.changeEncoding($0, base: base) }, changeEnding: { editor.changeLineEnding($0, base: base) })
            if let error = editor.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }
    }
}

/// Source FilePatchesDlg selection and preview are separate operations. AppKit
/// owns row selection, keyboard navigation and context-menu positioning.
struct WorkingTreePatchNativeFileList: NSViewRepresentable {
    @ObservedObject var model:WorkingTreePatchWindowModel
    func makeCoordinator() -> Coordinator {Coordinator(model)}
    func makeNSView(context:Context) -> NSScrollView {
        let table = PatchReviewFileTable();table.coordinator = context.coordinator
        table.identifier = NSUserInterfaceItemIdentifier("TurtleGit.Patch.Files")
        table.setAccessibilityLabel("Files to patch")
        table.allowsMultipleSelection = true;table.allowsEmptySelection = true
        table.allowsColumnReordering = false;table.rowHeight = 22
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (name,width) in [("Path",235.0),("State",65.0)] {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(name));column.title = NSLocalizedString(name,comment:"");column.width = width;column.minWidth = name == "Path" ? 100 : 45;table.addTableColumn(column)
        }
        table.delegate = context.coordinator;table.dataSource = context.coordinator
        table.target = context.coordinator;table.doubleAction = #selector(Coordinator.preview(_:))
        let scroll = NSScrollView();scroll.borderType = .bezelBorder;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller=true;scroll.documentView = table
        context.coordinator.table = table;context.coordinator.update();return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {context.coordinator.update()}
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {
        (scroll.documentView as? PatchReviewFileTable)?.coordinator = nil
        coordinator.table?.delegate = nil;coordinator.table?.dataSource = nil;coordinator.table?.target = nil;coordinator.table = nil;coordinator.retired = true
    }
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSMenuItemValidation {
        let model:WorkingTreePatchWindowModel
        weak var table:NSTableView?
        var retired = false,updating = false
        private var rows:[WorkingTreePatchReview.File] = []
        private struct RowState:Equatable {let id:Int,path:Data,state:String,shown:Bool,diagnostic:String}
        private var rendered:[RowState] = []
        private final class Invocation {
            enum Action {case preview,selected,all}
            let action:Action,ids:Set<Int>,generation:UUID
            init(_ action:Action,_ ids:Set<Int>,_ generation:UUID) {self.action = action;self.ids = ids;self.generation = generation}
        }
        init(_ model:WorkingTreePatchWindowModel) {self.model = model}
        func update() {
            guard !retired,let table else {return}
            updating = true;defer {updating = false}
            rows = model.review?.files ?? []
            let next = rows.map {RowState(id:$0.id,path:$0.pathBytes,state:model.fileState($0),shown:model.focusedFile == $0.id,diagnostic:model.fileResults[$0.pathBytes]?.output ?? model.fileInspections[$0.pathBytes]?.diagnostic ?? "")}
            if next != rendered {
                let origin = table.enclosingScrollView?.contentView.bounds.origin
                rendered = next;table.reloadData()
                if let origin {table.enclosingScrollView?.contentView.scroll(to:origin)}
                fitColumns()
            }
            let selected = IndexSet(rows.indices.filter {model.highlightedFiles.contains(rows[$0].id)})
            if table.selectedRowIndexes != selected {table.selectRowIndexes(selected,byExtendingSelection:false)}
        }
        func numberOfRows(in tableView:NSTableView) -> Int {rows.count}
        func fitColumns(){
            guard let table else{return}
            for column in table.tableColumns {
                let header=(column.title as NSString).size(withAttributes:[.font:column.headerCell.font ?? NSFont.systemFont(ofSize:NSFont.smallSystemFontSize)]).width+20
                let width=rows.reduce(header){width,file in
                    let path=column.identifier.rawValue=="Path",text=path ? (file.path as NSString).lastPathComponent:model.fileState(file)
                    let font=model.focusedFile==file.id ? NSFont.boldSystemFont(ofSize:NSFont.systemFontSize):NSFont.systemFont(ofSize:NSFont.systemFontSize)
                    return max(width,(text as NSString).size(withAttributes:[.font:font]).width+(path ? 32:14))
                }
                // The sidebar remains bounded; long literal leaf names scroll
                // horizontally and keep the complete path in their tooltip.
                column.width=max(column.minWidth,min(column.identifier.rawValue=="Path" ? 600:180,width))
            }
        }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
            guard rows.indices.contains(row) else {return nil};let file = rows[row],state = model.fileState(file)
            let cell = NSTableCellView(),label = NSTextField(labelWithString:tableColumn?.identifier.rawValue == "State" ? state : (file.path as NSString).lastPathComponent)
            label.lineBreakMode = .byTruncatingTail
            label.font = model.focusedFile == file.id ? .boldSystemFont(ofSize:NSFont.systemFontSize) : .systemFont(ofSize:NSFont.systemFontSize)
            label.textColor = state=="conflict" ? .systemOrange:state=="error" ? .systemRed : ["patched","kept current"].contains(state) ? .secondaryLabelColor : .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false;cell.addSubview(label);cell.textField = label
            let result=model.fileResults[file.pathBytes]
            let absolutePath = FileTransferPaths.lexicalPath(model.repository.root.path + "/" + file.path)
            var tooltip: String = FileTransferPaths.fileURL(absolutePath).path
            if ["error", "conflict"].contains(state) {
                let diagnostic: String = result?.output ?? model.fileInspections[file.pathBytes]?.diagnostic ?? ""
                tooltip += "\n" + diagnostic
            }
            if let addError = result?.addError {
                tooltip += "\nSaved patched file, but Add failed: " + addError
            }
            if let postApplyError = result?.postApplyError {
                tooltip += "\nSaved patched file, but cleanup failed: " + postApplyError
            }
            cell.toolTip = tooltip
            if tableColumn?.identifier.rawValue == "Path" {
                let image = NSImageView();image.image = NSWorkspace.shared.icon(for:UTType(filenameExtension:(file.path as NSString).pathExtension) ?? .data);image.translatesAutoresizingMaskIntoConstraints = false;cell.addSubview(image);cell.imageView = image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4),image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),image.widthAnchor.constraint(equalToConstant:16),image.heightAnchor.constraint(equalToConstant:16),label.leadingAnchor.constraint(equalTo:image.trailingAnchor,constant:4)])
            } else {label.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4).isActive = true}
            NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        func selectionShouldChange(in tableView:NSTableView) -> Bool {updating || !retired && model.canHighlightFiles}
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard !retired,!updating,let table else {return}
            model.highlightFiles(Set(table.selectedRowIndexes.compactMap {rows.indices.contains($0) ? rows[$0].id : nil}))
        }
        var selectedIDs:Set<Int> {Set((table?.selectedRowIndexes ?? []).compactMap {rows.indices.contains($0) ? rows[$0].id : nil})}
        @objc func preview(_ sender:Any?) {guard !retired else {return};model.previewFiles(selectedIDs,generation:model.fileListGeneration)}
        func contextMenu() -> NSMenu {
            let menu = NSMenu();let ids = selectedIDs,generation = model.fileListGeneration
            let commands:[(String,Invocation.Action,MenuIcon)] = [("Preview patched file",.preview,.compare),("Patch all files",.all,.patch),("Patch selected files",.selected,.patch)]
            for (title,action,icon) in commands {
                let item = NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"");item.target = self;item.representedObject = Invocation(action,ids,generation)
                item.image = MenuPresentationSettings.applicationContextIcons(defaults:model.openPreferences) ? icon.image() : nil
                item.isEnabled = validateMenuItem(item);menu.addItem(item)
            }
            return menu
        }
        func validateMenuItem(_ item:NSMenuItem) -> Bool {
            guard !retired,let invocation = item.representedObject as? Invocation,invocation.generation == model.fileListGeneration else {return false}
            switch invocation.action {
            case .preview:return model.canPreviewFiles(invocation.ids,generation:invocation.generation)
            case .all:return model.canPatchFiles
            case .selected:return model.canPatchFiles && model.review?.files.contains(where:{invocation.ids.contains($0.id) && !model.appliedPaths.contains($0.pathBytes)}) == true
            }
        }
        @objc private func invoke(_ item:NSMenuItem) {
            guard validateMenuItem(item),let invocation = item.representedObject as? Invocation else {return}
            switch invocation.action {
            case .preview:model.previewFiles(invocation.ids,generation:invocation.generation)
            case .all:model.patchFiles(Set(model.review?.files.map(\.id) ?? []),generation:invocation.generation)
            case .selected:model.patchFiles(invocation.ids,generation:invocation.generation)
            }
        }
    }
}

private final class PatchReviewFileTable:NSTableView {
    weak var coordinator:WorkingTreePatchNativeFileList.Coordinator?
    override func menu(for event:NSEvent) -> NSMenu? {
        let row = self.row(at:convert(event.locationInWindow,from:nil))
        if row >= 0,!selectedRowIndexes.contains(row),coordinator?.model.canHighlightFiles == true {selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
        return coordinator?.contextMenu()
    }
    override func keyDown(with event:NSEvent) {
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if flags.isEmpty,(event.keyCode == 36 || event.keyCode == 76) {coordinator?.preview(nil);return}
        if flags == .shift,event.keyCode == 109,let menu = coordinator?.contextMenu() {
            let row = selectedRow >= 0 ? selectedRow : 0
            let point = numberOfRows > row ? NSPoint(x:bounds.minX + 12,y:rect(ofRow:row).midY) : NSPoint(x:bounds.midX,y:bounds.midY)
            menu.popUp(positioning:nil,at:point,in:self);return
        }
        super.keyDown(with:event)
    }
}

private struct PatchSpecialRecoveryView:View {
    @ObservedObject var model:WorkingTreePatchWindowModel
    let comparison:WorkingTreePatchFileComparison
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title).font(.headline)
            Text("Preview does not change files. Choose which complete file state to keep.").foregroundStyle(.secondary)
            HSplitView {
                PatchFileStatePreview(title:"Current working file",content:comparison.document.base)
                PatchFileStatePreview(title:"Patched recorded base",content:comparison.document.destination)
            }
            if let choice = model.specialResolutionChoice {
                Label(choice == .current ? "Current working file and paths kept." : "Selected patched file state saved.",systemImage:"checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                Button {model.resolveSpecial(.current)} label: {CommandLabel(title:comparison.document.base.mode == nil ? "Keep current deletion" : "Keep current file",icon:.mergeUseMine)}
                    .help("Keep the reviewed current files and paths without applying this patch record.")
                Spacer()
                Button {model.resolveSpecial(.patched)} label: {CommandLabel(title:comparison.document.destination.mode == nil ? "Use patched deletion…" : "Use patched file",icon:.mergeUseTheirs)}
                    .help("Use the complete patched contents, file type and paths shown above.")
            }.disabled(!model.canResolveSpecial)
        }.padding(12)
    }
    private var title:String {
        switch comparison.recoveryKind {
        case .binary:return "Binary file conflict"
        case .symbolicLink:return "Symbolic link or file-type conflict"
        case .deletion:return "Deleted or modified file conflict"
        default:return "File conflict"
        }
    }
}
private struct PatchFileStatePreview:View {
    let title:String
    let content:ComparisonFileContent
    private var isLink:Bool {content.mode == "120000"}
    private var image:NSImage? {
        guard ["100644","100755"].contains(content.mode ?? ""),content.bytes.count <= 16 * 1024 * 1024,
              UTType(filenameExtension:(content.path as NSString).pathExtension)?.conforms(to:.image) == true else {return nil}
        return NSImage(data:content.bytes)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.headline)
            Text(content.path).font(.caption).lineLimit(1).help(content.path)
            Text(content.mode.map {isLink ? "Symbolic link · \(content.bytes.count) bytes" : "\($0) · \(content.bytes.count) bytes"} ?? "Absent / deleted").font(.caption).foregroundStyle(.secondary)
            if content.mode == nil {
                VStack {Spacer();Image(systemName:"doc.badge.minus").font(.system(size:32)).foregroundStyle(.orange);Text("No file on this side");Spacer()}.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if isLink {
                ScrollView {Text("Link target:\n" + String(decoding:content.bytes,as:UTF8.self)).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
            } else {
                if let image {Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:240)}
                ScrollView {
                    Text(content.bytes.prefix(4096).enumerated().map {($0.offset % 16 == 0 ? String(format:"\n%08X  ",$0.offset) : " ") + String(format:"%02X",$0.element)}.joined()).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                }.accessibilityLabel(title + " byte preview")
                if content.bytes.count > 4096 {Text("First 4096 bytes shown").font(.caption).foregroundStyle(.secondary)}
            }
        }.padding(10).frame(minWidth:200,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Color(nsColor:.textBackgroundColor))
    }
}
