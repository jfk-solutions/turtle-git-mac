// SPDX-License-Identifier: GPL-2.0-or-later
// Native Rebase/Cherry Pick form adapted from RebaseDlg, TortoiseGit.
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore

/// RebaseDlg's unmodified F5 is scoped to its owning dialog, including field editors.
@MainActor final class RebaseNativeWindow:NSWindow {
    var refreshAction:()->Void = {}
    var keyOwnerQuery:(NSWindow)->Bool = {$0.isKeyWindow}
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if event.keyCode==96,event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
           event.window === self,keyOwnerQuery(self),attachedSheet==nil,NSApp.modalWindow==nil {
            refreshAction();return true
        }
        return super.performKeyEquivalent(with:event)
    }
}

@MainActor final class RebaseWindowController: NSWindowController, NSWindowDelegate {
    let model: RebaseWindowModel
    private var retiredBatchChildren:[()->Bool]=[]
    var transportBatchWorkPending:Bool {
        model.pendingBatchWorkers>0 || model.revisionMenuLog.pendingHistoryLoads>0 || model.revisionMenuLog.noteWorkPending ||
        (logPicker?.model.pendingHistoryLoads ?? 0)>0 || (referencePicker?.model.pendingReferenceReads ?? 0)>0 ||
        splitCommitPicker?.model.attemptWorkPending == true || stashRestore?.transportBatchWorkPending == true ||
        logPicker?.window?.sheetParent != nil || referencePicker?.window?.sheetParent != nil ||
        identitySettings?.window?.sheetParent != nil || retiredBatchChildren.contains{$0()} ||
        window?.attachedSheet != nil || window?.sheetParent != nil
    }
    private(set) var revisionFind: RevisionGraphFindController?
    private(set) var containingWindows: [UUID: CommitContainingReferencesWindowController] = [:]
    private var historyAlert: (UUID, NSAlert, CheckedContinuation<NSApplication.ModalResponse, Never>)?
    private func presentHistoryAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard !model.retired, let window, window.attachedSheet == nil, historyAlert == nil else { return .abort }
        return await withCheckedContinuation { continuation in
            let id = UUID(); historyAlert = (id, alert, continuation); alert.window.alphaValue = window.alphaValue
            alert.beginSheetModal(for: window) { [weak self] response in self?.finishHistoryAlert(id, response: response) }
        }
    }
    private func finishHistoryAlert(_ id: UUID, response: NSApplication.ModalResponse) {
        guard let pending = historyAlert, pending.0 == id else { return }; historyAlert = nil
        pending.2.resume(returning: response)
    }
    var configureContainingReferences: (CommitContainingReferencesWindowController) -> Void = { _ in }
    private func refreshContainingReferenceBlocking() {
        let blocking = containingWindows.values.contains { $0.hasBlockingChild }
        if model.containingReferenceBlocked != blocking { model.containingReferenceBlocked = blocking }
    }
    private func navigateRevision(index: Int, select: Bool) {
        guard model.revisionMenuAvailable, model.entries.indices.contains(index) else { return }
        let id = model.entries[index].id
        model.revisionFindHighlightHash = select ? nil : model.entries[index].commit.hash
        if select { model.selection = [id] }
        model.scrollRevisionOccurrence = id; model.scrollRevisionRequest += 1
    }
    func showRevisionFind(regexExecutable: URL? = nil) {
        guard model.revisionMenuAvailable, let parent = window else { return }
        if let revisionFind { revisionFind.window?.makeKey(); return }
        let child = RevisionGraphFindController(repository: model.repository, access: model.repositoryAccess, preferences: model.columnPreferences, regexExecutable: regexExecutable)
        revisionFind = child
        child.logSnapshot = { [weak model] in guard let model else { return [] }; return model.entries.map { model.revisionHistoryCommit($0.commit) } }
        child.logRowIdentities = { [weak model] in model?.entries.map(\.id) ?? [] }
        child.snapshotEpoch = { [weak model] in model?.formContext.controls }
        child.searchIndex = { [weak model] in model?.revisionFindIndex ?? 0 }
        child.didFindIndex = { [weak model] in model?.revisionFindIndex = $0 }
        child.logDateSettings = .load(defaults: model.columnPreferences)
        child.canSearch = { [weak model] in model?.revisionMenuAvailable == true }
        child.navigateIndex = { [weak self] index, select in self?.navigateRevision(index: index, select: select) }
        child.modalChanged = { [weak model, weak child] in model?.revisionFindBlocked = child?.acknowledgingFailure == true || child?.window?.attachedSheet != nil; child?.updateAvailability() }
        child.onClosed = { [weak self, weak parent, weak child] in
            if let window = child?.window { parent?.removeChildWindow(window) }
            if self?.revisionFind === child { self?.revisionFind = nil; self?.model.revisionFindBlocked = false }
        }
        if let window = child.window { window.alphaValue = parent.alphaValue; window.appearance = parent.appearance; parent.addChildWindow(window, ordered: .above); window.center(); window.orderFront(nil); window.makeFirstResponder(child.searchBox) }
        child.updateAvailability(); child.loadReferences()
    }
    func showRevisionContainingReferences(_ hash: String) {
        guard model.revisionMenuAvailable, !hash.isEmpty, let parent = window else { return }
        let id = UUID(), child = CommitContainingReferencesWindowController(repository: model.repository, access: model.repositoryAccess, revision: hash, preferences: model.columnPreferences)
        containingWindows[id] = child
        // A child's own picker blocks replay, but must not disable its own
        // picker completion/refresh when that picker returns to the child.
        child.externalAvailability = { [weak self, weak child] in
            guard let self, let child else { return false }
            return self.model.revisionMenuOwnerAvailable && !self.containingWindows.values.contains { $0 !== child && $0.hasBlockingChild }
        }
        child.blockingStateChanged = { [weak self] in self?.refreshContainingReferenceBlocking() }
        child.onLog = model.revisionMenuLog.onContainingLog; child.onBrowse = model.revisionMenuLog.onBrowseRepository
        child.onCompare = model.revisionMenuLog.onCompare; child.onUnified = model.revisionMenuLog.onUnifiedDiff
        child.onNavigate = { [weak self] hash, select in
            guard let self, let index = self.model.entries.firstIndex(where: { $0.commit.hash == hash }) else { return }
            self.navigateRevision(index: index, select: select)
        }
        configureContainingReferences(child)
        child.onClosed = { [weak self, weak child, weak parent] in if let window = child?.window { parent?.removeChildWindow(window) }; self?.containingWindows.removeValue(forKey: id); self?.refreshContainingReferenceBlocking() }
        if let window = child.window { window.alphaValue = parent.alphaValue; window.appearance = parent.appearance; parent.addChildWindow(window, ordered: .above); window.center(); window.orderFront(nil); window.makeFirstResponder(child.revision) }
        child.refresh()
    }
    private var revisionFilePresenter:RevisionFileActionPresenter?
    var onClosed: () -> Void = {}
    private var replayQuestion: (UUID, NSAlert, (Int) -> Void)?
    private var identitySettings: SettingsSheetController?
    var replayIdentitySettingsWindow: NSWindow? { identitySettings?.window }
    var replayIdentityNavigation: SettingsNavigationController? { identitySettings?.navigation }
    private(set) var conflictBaseViewer: FileComparisonWindowController?
    private(set) var conflictRevertWindow:RevertProgressWindowController?
    private(set) var conflictUnifiedWindows:[UUID:PatchWindowController]=[:]
    var openConflictUnifiedExternal:(Data,Bool,UserDefaults) async throws -> Bool = {try await UnifiedDiffApplication.openExternal($0,alternate:$1,preferences:$2,title:"Rebase conflict changes")}
    private(set) var conflictAddWindow: AddProgressWindowController?
    private(set) var conflictIgnoreWindow: IgnoreWindowController?
    var configureConflictAdd: (AddProgressWindowModel) -> Void = { _ in }
    var configureConflictIgnore: (IgnoreWindowModel) -> Void = { _ in }
    var configureConflictRevert:(RevertProgressWindowModel)->Void = {_ in}
    var configureConflictBaseViewer: (FileComparisonWindowModel) -> Void = { _ in }
    private var conflictPanel: (UUID, NSOpenPanel, (URL?) -> Void)?
    var presentConflictPanel: (NSWindow, NSOpenPanel, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, panel, reply in
        guard owner.attachedSheet == nil else { return false }; panel.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    private(set) var logPicker: LogWindowController?
    private var commitPickerRequest: UUID?
    private(set) static var activeCommitPickers = 0
    var presentCommitPicker: (NSWindow, NSWindow) -> Bool = { owner, child in
        guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true
    }
    var makeCommitPicker: (GitRepository, RepositoryAccessLease?, UserDefaults, @escaping ([LogEntry]?) -> Void) -> LogWindowController = { repository, access, preferences, choose in
        LogWindowController(repository: repository, access: access, onChooseMultiple: choose, labelDefaults: preferences)
    }
    func showAdditionalCommits() {
        guard let owner = window, owner.attachedSheet == nil, logPicker == nil, let request = model.beginAdditionalSelection() else { return }
        commitPickerRequest = request; Self.activeCommitPickers += 1
        let picker = makeCommitPicker(model.repository, model.repositoryAccess, model.columnPreferences) { [weak self] revisions in
            guard let self, self.commitPickerRequest == request else { return }
            self.finishCommitPicker()
            self.model.finishAdditionalSelection(request, revisions: revisions?.map(\.hash))
        }
        logPicker = picker
        picker.onClosed = { [weak self, weak picker] in
            if let child = picker?.window { child.sheetParent?.endSheet(child); child.orderOut(nil) }
            if self?.logPicker === picker { self?.logPicker = nil }
        }
        model.configureLogPicker(picker.model)
        guard let child = picker.window, presentCommitPicker(owner, child) else {
            finishCommitPicker(); model.finishAdditionalSelection(request, revisions: nil); picker.close(); return
        }
    }
    private func finishCommitPicker() {
        guard commitPickerRequest != nil else { return }
        commitPickerRequest = nil; logPicker = nil; Self.activeCommitPickers -= 1
    }
    private func retireCommitPicker() {
        let picker = logPicker; finishCommitPicker()
        if let child = picker?.window { child.sheetParent?.endSheet(child); child.orderOut(nil) }
        picker?.close()
    }
    private var splitCommitPicker: CommitWindowController?
    private var stashRestore: StashRestoreWindowController?
    private var stashAlert: NSAlert?
    private var notePresenter: CommitNotePresenter?
    var noteEditor: InputWindowController? { notePresenter?.editor }
    private(set) static var activeReferencePickers = 0
    private var referenceRequest: RebaseReferenceRequest?
    private(set) var referencePicker: ReferenceBrowserWindowController?
    var configureReferencePicker: (ReferenceBrowserWindowModel) -> Void = { _ in }
    var presentReferencePicker: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    var makeReferencePicker: (GitRepository, RepositoryAccessLease?, String, UserDefaults, @escaping (String?) -> Void) -> ReferenceBrowserWindowController = { repository, access, initial, preferences, choose in
        ReferenceBrowserWindowController(repository: repository, access: access, initial: initial, preferences: preferences, onChoose: choose)
    }
    func showReferencePicker(_ target: RebaseReferenceTarget) {
        guard let owner = window, owner.attachedSheet == nil, referencePicker == nil, let request = model.beginReferenceSelection(target) else { return }
        referenceRequest = request; Self.activeReferencePickers += 1
        let child = makeReferencePicker(model.repository, model.repositoryAccess, target == .upstream ? request.upstream : request.onto, model.columnPreferences) { [weak self] value in
            guard let self, self.referenceRequest?.id == request.id else { return }
            self.finishReferencePicker(); self.model.acceptReferenceSelection(request, value: value)
        }
        referencePicker = child; configureReferencePicker(child.model)
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.referencePicker === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.referencePicker = nil
        }
        guard let window = child.window, presentReferencePicker(owner, window) else {
            finishReferencePicker(); child.abandonPresentation(); model.abandonReferenceSelection(request); return
        }
        child.model.load()
    }
    private func finishReferencePicker() {
        guard referenceRequest != nil else { return }; referenceRequest = nil; referencePicker = nil; Self.activeReferencePickers -= 1
    }
    private func retireReferencePicker() { let child = referencePicker; finishReferencePicker(); child?.abandonPresentation() }


    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = RebaseWindowModel(repository: repository, access: access, messageDefaults: preferences)
        let window = RebaseNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Rebase", preferences: preferences); window.contentMinSize = NSSize(width: 930, height: 600); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: RebaseDialog(model: model).defaultAppStorage(preferences)); host.sizingOptions = []; window.contentViewController = host
        super.init(window: window); model.clientHooks.windowProvider = { [weak window] in window?.attachedSheet ?? window }; window.delegate = self; window.setContentSize(NSSize(width:1040,height:720)); window.center(); model.close = { [weak window] in window?.close() }
        window.refreshAction = { [weak model] in model?.refreshFromSourceCommand() }
        model.onFindRevision = { [weak self] in self?.showRevisionFind() }
        model.onRefreshRevisionFind = { [weak self] in self?.revisionFind?.loadReferences() }
        model.onFindAvailability = { [weak self] in self?.revisionFind?.updateAvailability(); self?.containingWindows.values.forEach { $0.updateAvailability() } }
        model.revisionMenuLog.onShowContainingReferences = { [weak self] in self?.showRevisionContainingReferences($0) }
        model.revisionMenuLog.window = window
        model.revisionMenuLog.confirmReferenceDeletion = { [weak self] request in
            guard let self else { return .abort }
            let response = await self.presentHistoryAlert(HistoryReferenceDeletionPresentation.alert(request))
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            return request.choices.indices.contains(index) ? request.choices[index].choice : .abort
        }
        model.revisionMenuLog.acknowledgeReferenceDeletionFailure = { [weak self] message in
            let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "Could not delete reference."
            alert.informativeText = message; alert.addButton(withTitle: "OK")
            _ = await self?.presentHistoryAlert(alert)
        }
        model.revisionMenuLog.sshSettings.present = { [weak self, weak window] prompt in
            guard let self, !self.model.retired, let window, window.attachedSheet == nil, let child = prompt.window else { return false }
            child.alphaValue = window.alphaValue; window.makeFirstResponder(nil); window.beginSheet(child); return true
        }
        model.revisionFiles.window = window
        revisionFilePresenter=RevisionFileActionPresenter(model:model.revisionFiles,window:window)
        model.revisionFiles.onFilesChanged={ [weak model] in model?.onChanged() }

        model.chooseConflictApplication = { [weak self] in await self?.chooseConflictLocation(application: true) }
        model.chooseConflictExport = { [weak self] in await self?.chooseConflictLocation(application: false) }
        model.onConflictBaseComparison = { [weak self] prepared in
            guard let self, !self.model.retired, self.conflictBaseViewer == nil else { return }
            let child = FileComparisonWindowController(repository: repository, access: access, conflict: prepared, preferences: preferences)
            self.configureConflictBaseViewer(child.model); self.conflictBaseViewer = child; self.model.viewingConflictBase = true
            child.onClosed = { [weak self] in
                guard let self else { return }; self.conflictBaseViewer = nil; self.model.viewingConflictBase = false
                if !self.model.retired { self.model.busy = false; self.model.refreshState() }
            }
            child.showWindow(nil); child.window?.makeKeyAndOrderFront(nil)
        }
        model.onConflictUnified={ [weak self] bytes,alternate,title,token in
            guard let self,!self.model.retired,!token.isCancelled else {return}
            if try await self.openConflictUnifiedExternal(bytes,alternate,preferences) {return}
            guard !self.model.retired,!token.isCancelled else {return}
            let id=UUID()
            self.conflictUnifiedWindows[id]=UnifiedDiffApplication.presentBuiltin(bytes,repository:repository,access:access,existing:nil,title:title,onClosed:{ [weak self] in self?.conflictUnifiedWindows.removeValue(forKey:id) })
        }
        model.confirmConflictMutation={ [weak self] message,flags in
            await self?.askReplay(message,buttons:["Yes","No"],defaultIndex:flags ? 1:0) == 0
        }
        model.cancelConflictRevert={ [weak self] in self?.conflictRevertWindow?.model.cancel() }
        model.presentConflictRevert={ [weak self] entries,validate in
            guard let self,!self.model.retired,self.conflictRevertWindow == nil,let window=self.window,window.attachedSheet == nil else {return}
            await withCheckedContinuation { continuation in
                let child=RevertProgressWindowController(repository:repository,access:access,entries:entries,amend:false,againstHead:true,autoCloseSuccess:true,preferences:preferences)
                child.model.externalAvailability={ [weak model=self.model] in model?.retired == false && model?.revisionMenuLog.confirmingQuit == false }
                child.onProgressLog={ [weak model=self.model] path in guard let model,!model.retired,!model.revisionMenuLog.confirmingQuit else{return};model.onConflictFileLog(path) }
                var firstAttempt=true
                child.model.execute={ selected,token,progress,output in
                    try await validate(token,firstAttempt);firstAttempt=false
                    return try await repository.revertWorkingFiles(selected,cancellation:token,progress:progress,onOutput:output)
                }
                child.model.onFinished={ [weak model=self.model] text,_ in if let model,!model.retired {model.output += text+"\n"} }
                child.model.onHandleSubmodules={ [weak model=self.model] revision,paths in if let model,!model.retired {model.onConflictRevertSubmodules(revision,paths)} }
                child.onClosed={ [weak self,weak child] in
                    if let sheet=child?.window {sheet.sheetParent?.endSheet(sheet);sheet.orderOut(nil)}
                    if self?.conflictRevertWindow === child {self?.conflictRevertWindow=nil};continuation.resume()
                }
                self.conflictRevertWindow=child;self.configureConflictRevert(child.model)
                if let sheet=child.window {window.beginSheet(sheet);child.model.start()} else {child.close()}
            }
        }
        model.confirmConflictDeletion={ [weak self] paths,permanently in
            await self?.askReplay(permanently ? "Permanently delete the selected paths?":"Move the selected paths to Trash?",detail:"\(paths.count) selected item(s). Their index entries will also be removed."+(permanently ? " This cannot be undone.":" Files moved to Trash can be recovered in Finder."),buttons:["No","Yes"],defaultIndex:0) == 1
        }
        model.cancelConflictFileDialog={ [weak self] in
            self?.conflictAddWindow?.model.cancel();self?.conflictIgnoreWindow?.model.cancel()
        }
        model.presentConflictAdd={ [weak self] paths,mode,backend,validate in
            guard let self,!self.model.retired,self.conflictAddWindow == nil,let owner=self.window,owner.attachedSheet == nil else {return}
            await withCheckedContinuation { continuation in
                let child=AddProgressWindowController(repository:repository,access:access,paths:paths,mode:mode,preferences:preferences,backend:backend,preservePathOrder:true)
                child.model.externalAvailability={ [weak model=self.model] in model?.retired == false && model?.revisionMenuLog.confirmingQuit == false }
                child.onProgressLog={ [weak model=self.model] path in guard let model,!model.retired,!model.revisionMenuLog.confirmingQuit else {return};model.onConflictFileLog(path) }
                child.model.allowsCommit=false;child.model.validateMutation=validate
                child.model.onFinished={ [weak model=self.model] text,_ in if let model,!model.retired {model.output += text+"\n"} }
                child.onClosed={ [weak self,weak child] in
                    if let sheet=child?.window {sheet.sheetParent?.endSheet(sheet);sheet.orderOut(nil)}
                    if self?.conflictAddWindow === child {self?.conflictAddWindow=nil};continuation.resume()
                }
                self.conflictAddWindow=child;self.configureConflictAdd(child.model)
                if let sheet=child.window {sheet.alphaValue=owner.alphaValue;sheet.appearance=owner.effectiveAppearance;owner.beginSheet(sheet);child.model.start()} else {child.close()}
            }
        }
        model.presentConflictIgnore={ [weak self] action,paths,validate in
            guard let self,!self.model.retired,self.conflictIgnoreWindow == nil,let owner=self.window,owner.attachedSheet == nil else {return}
            let child=try IgnoreWindowController(repository:repository,access:access,paths:paths,mask:action.ignoresByExtension,delete:action.removesWhenIgnoring)
            await withCheckedContinuation { continuation in
                child.model.validateMutation=validate
                child.model.close={ [weak child] in
                    guard let child,let sheet=child.window else {return}
                    sheet.sheetParent?.endSheet(sheet);sheet.orderOut(nil);child.close()
                }
                child.onChanged={ [weak model=self.model] text in if let model,!model.retired {model.output += text+"\n"} }
                child.onClosed={ [weak self,weak child] in
                    if let sheet=child?.window {sheet.sheetParent?.endSheet(sheet);sheet.orderOut(nil)}
                    if self?.conflictIgnoreWindow === child {self?.conflictIgnoreWindow=nil};continuation.resume()
                }
                self.conflictIgnoreWindow=child;self.configureConflictIgnore(child.model)
                if let sheet=child.window {owner.beginSheet(sheet)} else {child.close()}
            }
        }
        model.pickReference = { [weak self] target in self?.showReferencePicker(target) }
        notePresenter = CommitNotePresenter(parent: window, model: model.revisionMenuLog, preferences: preferences)
        model.onModeChanged = { [weak window, weak model] in
            RepositoryWindowTitles.set(window, repository: repository.root, dialog: "\(model?.operationTitle ?? "Rebase")", preferences: preferences)
        }
        model.pickAdditionalCommits = { [weak self] in self?.showAdditionalCommits() }
        model.cancelMainlineQuestion = { [weak self] in
            if let pending = self?.replayQuestion { self?.finishReplayQuestion(pending.0, answer: Int.max) }
            self?.identitySettings?.retire()
        }
        model.repairReplayIdentity = { [weak self] in
            guard let self, await self.askReplay("You have not entered your user information yet.", detail: "Enter your name and email address in Git settings before continuing.", buttons: ["Yes", "No"], defaultIndex: 1) == 0 else { return false }
            return await self.showReplayIdentitySettings()
        }
        model.showSplitSelection = { [weak self] split, message in self?.showSplitSelection(split, message: message) }
        model.chooseStashBeforeReplay = { [weak self] in
            await self?.askStash(message: "Your working tree is not clean", detail: "Stash tracked changes before starting? Untracked and ignored files will remain in the working tree.", save: true) ?? false
        }
        model.chooseRestoreReplayStash = { [weak self] in
            await self?.askStash(message: "Restore stashed changes?", detail: "Do you want to pop the changes saved before this replay?", save: false) ?? false
        }
        model.restoreReplayStash = { [weak self] mode in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            await withCheckedContinuation { continuation in
                let child = StashRestoreWindowController(repository: repository, access: access, pop: true, showChanges: mode, preferences: preferences)
                self.stashRestore = child
                child.onChanged = { [weak model = self.model] text in model?.output += text + "\n"; model?.onChanged() }
                child.onViewChanges = { [weak model = self.model] in model?.onShowStatus() }
                child.onClosed = { [weak self, weak child] in
                    if let sheet = child?.window { sheet.sheetParent?.endSheet(sheet); sheet.orderOut(nil) }
                    if self?.stashRestore === child { self?.stashRestore = nil }
                    continuation.resume()
                }
                if let sheet = child.window { window.beginSheet(sheet); child.start() }
                else { child.close() }
            }
        }
        model.confirmReplayCancellation = { [weak self] in
            await self?.askReplay("The process is still running.", detail: "Stop the running replay? Applied changes remain available for Continue, Skip or Abort.", buttons: ["Yes", "No"], defaultIndex: 1) == 0
        }
        model.chooseAnotherSplit = { [weak self] in await self?.askReplay("Add another commit?", buttons: ["No", "Yes"], defaultIndex: 0) == 1 }
        model.chooseEmptyResult = { [weak self] in
            let answer = await self?.askReplay("The current commit will be empty", detail: "Skip the commit or keep the message-only commit?", buttons: ["Commit", "Skip", "Cancel"], defaultIndex: 2) ?? 2
            return answer == 0 ? .commit : answer == 1 ? .skip : .cancel
        }
        model.confirmEmptyMessageReview = { [weak self] in
            await self?.askReplay(NSLocalizedString("Found an empty commit message. You have to enter one or rebase cannot proceed.", comment: ""), buttons: [NSLocalizedString("OK", comment: "")], defaultIndex: 0, style: .warning) == 0
        }
        model.chooseCleanCommitFailure = { [weak self] failure in
            let answer = await self?.askReplay("Git command failed", detail: failure.command.joined(separator: " "),
                buttons: ["Retry", "Ignore"], defaultIndex: 0,
                accessory: Self.recoveryDiagnosticAccessory(failure.diagnostic), icons: [.refresh, .rebaseSkip], style: .critical, waitForDetach: true)
            return answer == 1 ? .ignore : .retry
        }
        model.chooseFailedPickRecovery = { [weak self] failed in
            let remember=NSButton(checkboxWithTitle:"Do the same for the rest",target:nil,action:nil)
            let accessory=Self.recoveryDiagnosticAccessory(failed.diagnostic,checkbox:remember)
            let answer=await self?.askReplay("Cherry-pick failed", detail:"Cherry-pick failed (please see log in the cherry pick/rebase dialog for details)! Skip this commit?\n\n"+failed.entry.commit.hash+" — "+String(failed.entry.commit.subject.prefix(256)),buttons:["Skip","Retry","Cancel"],defaultIndex:0,accessory:accessory,icons:[.rebaseSkip,.refresh,nil]) ?? 2
            return answer == 0 ? .skip(remember:remember.state == .on) : answer == 1 ? .retry : .cancel
        }
        model.chooseFailedPickCleanup = { [weak self] failed in
            await self?.askReplay("Git command failed",detail:failed.cleanupCommand ?? "",buttons:["Retry","Abort"],defaultIndex:0,accessory:Self.recoveryDiagnosticAccessory(failed.diagnostic),icons:[.refresh,.mergeAbort]) == 0
        }
        model.confirmConflictHints = { [weak self] in
            let remember = NSButton(checkboxWithTitle: "Do not show again", target: nil, action: nil)
            let answer = await self?.askReplay("Conflict hints remain in the commit message", detail: "The message contains Git's commented conflict list. Ignore the warning to continue, or abort to edit the message.", buttons: ["Ignore", "Abort"], defaultIndex: 1, accessory: remember)
            if answer == 0 && remember.state == .on { preferences.set(true, forKey: "CommitMessageContainsConflictHint") }
            return answer == 0
        }
        model.chooseMainline = { [weak self] commit, choices in
            let answer = await self?.askReplay("TurtleGit", detail: "\"\(commit.hash)\" - \"\(commit.subject)\"\nis a merge commit.\n\nWhich parent do you want to pick?", buttons: choices.map(\.title) + ["Cancel"], defaultIndex: choices.count) ?? choices.count
            return choices.indices.contains(answer) ? choices[answer].number : nil
        }

        DialogGeometry.attach(window, identifier: "RebaseWindowController")
    }
    /// The replay keeps its operation/access ownership while this local Settings
    /// transaction is open. Returning does not mean identity is valid: Start reads
    /// the four values again, and may offer this repair again as upstream does.
    func showReplayIdentitySettings() async -> Bool {
        guard !model.retired, identitySettings == nil, let window, window.attachedSheet == nil else { return false }
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        workspace.root = model.repository.root; workspace.settingsContextOverride = (model.repository, model.repositoryAccess, true)
        let child = SettingsSheetController(workspace: workspace, preferences: model.columnPreferences, initialPage: .git, title: "Settings – TurtleGit for Mac")
        identitySettings = child; model.hasReplayQuestion = true
        return await withCheckedContinuation { continuation in
            child.onClosed = { [weak self, weak child] accepted in
                if let self, self.identitySettings === child { self.identitySettings = nil; self.model.hasReplayQuestion = false }
                continuation.resume(returning: accepted)
            }
            guard child.window != nil else { child.retire(); return }
            child.presentSheet(for: window)
        }
    }
    private static func recoveryDiagnosticAccessory(_ diagnostic:String,checkbox:NSButton?=nil)->NSView {
        let width:CGFloat=500,diagnosticHeight:CGFloat=140,footer:CGFloat=checkbox == nil ? 0:32
        // NSAlert measures accessory.frame before laying out its own content.
        // A zero-frame constraint-only stack can overrun the sheet's right edge.
        let accessory=NSView(frame:NSRect(x:0,y:0,width:width,height:diagnosticHeight+footer))
        let text=NSTextView(frame:NSRect(x:0,y:0,width:width,height:diagnosticHeight))
        text.string=String(diagnostic.suffix(4000));text.isEditable=false;text.isSelectable=true
        text.font=NSFont.monospacedSystemFont(ofSize:11,weight:.regular);text.textContainerInset=NSSize(width:8,height:8)
        text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView=true
        let scroll=NSScrollView(frame:NSRect(x:0,y:footer,width:width,height:diagnosticHeight))
        scroll.documentView=text;scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
        accessory.addSubview(scroll)
        if let checkbox {checkbox.frame=NSRect(x:0,y:0,width:width,height:24);accessory.addSubview(checkbox)}
        return accessory
    }
    private func askReplay(_ title: String, detail: String = "", buttons: [String], defaultIndex: Int, accessory: NSView? = nil, icons: [MenuIcon?] = [], style: NSAlert.Style? = nil, waitForDetach: Bool = false) async -> Int {
        guard !model.retired, replayQuestion == nil, let window, window.attachedSheet == nil else { return Int.max }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.accessoryView = accessory;alert.window.alphaValue=window.alphaValue
        if let style { alert.alertStyle = style }
        for (index, title) in buttons.enumerated() {
            let button = alert.addButton(withTitle:title);button.keyEquivalent=index == defaultIndex ? "\r":""
            if icons.indices.contains(index),let icon=icons[index] {button.image=icon.image();button.imagePosition = .imageLeading}
            if title=="Cancel" || title=="Abort" {button.keyEquivalent="\u{1b}"}
        }
        if alert.buttons.indices.contains(defaultIndex) {alert.window.defaultButtonCell=alert.buttons[defaultIndex].cell as? NSButtonCell}
        alert.layout();alert.window.contentView?.layoutSubtreeIfNeeded()
        let id = UUID(); model.hasReplayQuestion = true
        let answer: Int = await withCheckedContinuation { continuation in
            replayQuestion = (id, alert, { continuation.resume(returning: $0) })
            alert.beginSheetModal(for: window) { [weak self] response in self?.finishReplayQuestion(id, answer: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        }
        if waitForDetach {
            let deadline = Date().addingTimeInterval(3)
            while alert.window.sheetParent === window, !model.retired, Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return answer
    }
    private func finishReplayQuestion(_ id: UUID, answer: Int) {
        guard let pending = replayQuestion, pending.0 == id else { return }; replayQuestion = nil; model.hasReplayQuestion = false
        if pending.1.window.sheetParent === window { window?.endSheet(pending.1.window) }; pending.1.window.orderOut(nil); pending.2(answer)
    }
    private func chooseConflictLocation(application: Bool) async -> URL? {
        guard !model.retired, conflictPanel == nil, let window, window.attachedSheet == nil else { return nil }
        let panel = NSOpenPanel(); panel.title = application ? "Open With" : "Export selected files"; panel.prompt = application ? "Open" : "Export"
        panel.canChooseFiles = application; panel.canChooseDirectories = !application; panel.allowsMultipleSelection = false; panel.canCreateDirectories = !application
        if application { panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true) }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            conflictPanel = (id, panel, { continuation.resume(returning: $0) })
            if !presentConflictPanel(window, panel, { [weak self] response in self?.finishConflictPanel(id, accepted: response == .OK) }) { finishConflictPanel(id, accepted: false) }
        }
    }
    private func finishConflictPanel(_ id: UUID, accepted: Bool) {
        guard let pending = conflictPanel, pending.0 == id else { return }; conflictPanel = nil
        let value = accepted && !model.retired ? pending.1.url : nil
        if pending.1.sheetParent === window { window?.endSheet(pending.1, returnCode: accepted ? .OK : .cancel) }
        pending.1.orderOut(nil); pending.2(value)
    }
    private func askStash(message: String, detail: String, save: Bool) async -> Bool {
        guard !model.retired, let window, window.attachedSheet == nil, stashAlert == nil else { return false }
        let alert = NSAlert(); alert.messageText = message; alert.informativeText = detail; alert.alertStyle = .warning
        let yes = alert.addButton(withTitle: save ? "Stash" : "Yes"); alert.addButton(withTitle: save ? "Abort" : "No")
        yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
        stashAlert = alert
        let response = await alert.beginSheetModal(for: window)
        if stashAlert === alert { stashAlert = nil }
        return !model.retired && response == .alertFirstButtonReturn
    }
    private func showSplitSelection(_ split: RebaseSplitState, message: String) {
        guard let window, window.attachedSheet == nil, splitCommitPicker == nil else { model.splitSelectionClosed(committed: false); return }
        let child = CommitWindowController(repository: model.repository, access: model.repositoryAccess, defaults: model.columnPreferences)
        splitCommitPicker = child
        let commit = child.model
        model.configureCommitSelection(commit)
        var committed = false
        commit.onCommitted = { [weak model] text in committed = true; guard let model, !model.retired else { return }; model.output += text + "\n"; model.onChanged() }
        let originalClose = commit.close
        commit.close = { [weak window, weak child] in
            if let sheet = child?.window { window?.endSheet(sheet); sheet.orderOut(nil) }; originalClose()
        }
        child.onClosed = { [weak self] in self?.splitCommitPicker = nil; self?.model.splitSelectionClosed(committed: committed) }
        commit.loadReplaySplit(split, message: message)
        if let sheet = child.window { sheet.alphaValue = window.alphaValue; sheet.appearance = window.appearance; window.beginSheet(sheet) } else { splitCommitPicker = nil; model.splitSelectionClosed(committed: false) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.replaying { model.cancelReplay(); return false }
        if model.containingReferenceBlocked || model.revisionFindBlocked || model.revisionHistoryBlocked || model.hasReplayQuestion || model.confirmingReplayCancellation || model.pendingConfirmation != nil { return false }
        if model.cancelPreparation() { return false }
        guard !conflictUnifiedWindows.values.contains(where:{$0.model.busy || $0.window?.attachedSheet != nil}),model.pickingReference == nil, !model.busy, !model.selectingSplit, !(model.active && model.hasReplayStash), sender.attachedSheet == nil else { return false }
        if !model.active && model.hasReplayStash { model.finishReplay(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        (window as? RebaseNativeWindow)?.refreshAction = {}
        if let child=logPicker {retiredBatchChildren.append{child.model.pendingHistoryLoads>0 || child.window?.sheetParent != nil}}
        if let child=referencePicker {retiredBatchChildren.append{child.model.pendingReferenceReads>0 || child.window?.sheetParent != nil}}
        if let child=splitCommitPicker {retiredBatchChildren.append{child.model.attemptWorkPending || child.window?.sheetParent != nil}}
        if let child=stashRestore {retiredBatchChildren.append{child.transportBatchWorkPending || child.window?.sheetParent != nil}}
        if let pending = historyAlert { finishHistoryAlert(pending.0, response: .abort); window?.endSheet(pending.1.window, returnCode: .abort); pending.1.window.close() }; revisionFind?.close(); revisionFind = nil; Array(containingWindows.values).forEach { $0.close() }; containingWindows = [:]; retireReferencePicker(); model.retire(); identitySettings?.retire(); retireCommitPicker();conflictAddWindow?.close();conflictAddWindow=nil;conflictIgnoreWindow?.close();conflictIgnoreWindow=nil;Array(conflictUnifiedWindows.values).forEach {$0.close()};conflictUnifiedWindows=[:]; if let pending = replayQuestion { finishReplayQuestion(pending.0, answer: Int.max) }; if let pending = conflictPanel { finishConflictPanel(pending.0, accepted: false) }; conflictRevertWindow?.close();conflictRevertWindow=nil; conflictBaseViewer?.close(); conflictBaseViewer = nil; notePresenter?.close(); if let alert = stashAlert { window?.endSheet(alert.window, returnCode: .abort); alert.window.orderOut(nil) }; stashAlert = nil; stashRestore?.close(); stashRestore = nil; logPicker?.close(); logPicker = nil; splitCommitPicker?.close(); splitCommitPicker = nil
        if model.revisionMenuLog.noteWorkPending {
            Task{@MainActor [self] in while model.revisionMenuLog.noteWorkPending{try? await Task.sleep(nanoseconds:5_000_000)};onClosed()}
        }else{onClosed()}
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
enum RebaseReferenceTarget: Equatable { case upstream, onto }
struct RebaseReferenceRequest {
    let id = UUID()
    let target: RebaseReferenceTarget
    let branch: String
    let upstream: String
    let onto: String
    let intent: [GitReferenceName]
}

@MainActor final class RebaseWindowModel: ObservableObject {
    let repository: GitRepository
    /// A parent-owned Fetch/Sync continuation retains its accepted repository;
    /// ordinary independent loads capture the current dialog preferences.
    private(set) var inheritedOperationRepository:GitRepository?
    private func operationRepository()->GitRepository {
        inheritedOperationRepository ?? repository.capturingDiffBackend(preferences:messageDefaults)
    }
    let fullCommitMessageOnLogLine: Bool
    private let access: RepositoryAccessLease?
    var columnPreferences: UserDefaults { messageDefaults }
    var messageEditorPreferences: UserDefaults { messageDefaults }
    private let messageDefaults: UserDefaults
    lazy var clientHooks = ClientHookSession(preferences: messageDefaults)
    var repositoryAccess: RepositoryAccessLease? { access }
    private var controlMenuGeneration=UUID()
    @Published private(set) var editingPendingActions = false
    private var actionEditCancellation: OperationCancellation?
    var readActionEditSnapshot: ((OperationCancellation) async throws -> RebaseActionEditSnapshot)?
    var writePendingActions: ((RebaseAction, Set<String>, [String: RebaseAction], [String: Int], RebaseActionEditSnapshot, URL, RebaseConflictIdentity?, OperationCancellation) async throws -> RebaseSessionSnapshot)?

    @Published var options = RebaseOptions() {didSet{controlMenuGeneration=UUID()}}
    @Published private(set) var bulkAction:RebaseBulkAction = .pickAll
    @Published private(set) var completionAction:RebaseCompletionAction = .log
    @Published private(set) var referenceTooltips:[String:String]=[:]
    @Published var ontoEnabled = false {didSet{if ontoEnabled != oldValue {controlMenuGeneration=UUID()}}}
    @Published private(set) var showsIssueColumn = false
    @Published private(set) var hasGitSVN = false
    @Published private(set) var issueColumnValues: [String:String] = [:]
    @Published private(set) var svnColumnValues: [String:String] = [:]
    @Published private(set) var loadingColumnMetadata = false
    @Published private(set) var revisionReferenceNames: [String: [String]] = [:]
    private var revisionCurrentReference = ""
    private var revisionHeadHash = ""
    private(set) var revisionBisectTerms = HistoryBisectTerms()
    private var pendingRevisionHistoryRefresh = false
    private var revisionReferenceMutation = false
    private var columnToken: OperationCancellation?
    private var columnGeneration = UUID()
    private var columnSignature: [String] = []
    private(set) var pendingBatchWorkers=0
    static private(set) var activeColumnReads = 0
    static private(set) var activeStashRestorations = 0
    var readColumnMetadata: ([LogEntry],OperationCancellation) async throws -> ReplayColumnMetadata
    @Published var references: [CheckoutReference] = []
    @Published var plan: RebasePlan? {didSet{controlMenuGeneration=UUID(); if oldValue?.entries.map(\.id) != plan?.entries.map(\.id), revisionFindHighlightHash != nil { revisionFindHighlightHash = nil }}}
    @Published var recovered: [RebaseEntry] = []
    @Published var replayRows: [RebaseEntry] = [] {didSet{controlMenuGeneration=UUID(); if oldValue.map(\.id) != replayRows.map(\.id), revisionFindHighlightHash != nil { revisionFindHighlightHash = nil }}}
    @Published var draftEntries: [RebaseEntry] = [] {didSet{controlMenuGeneration=UUID(); if oldValue.map(\.id) != draftEntries.map(\.id), revisionFindHighlightHash != nil { revisionFindHighlightHash = nil }}}
    @Published var state: RebaseState? {didSet{controlMenuGeneration=UUID()}}
    @Published var selection = Set<String>() {didSet{if selection != oldValue {controlMenuGeneration=UUID()}}}
    @Published var files: [CommitFile] = []
    let revisionFiles:RevisionComparisonWindowModel
    private var revisionFilesObservation:AnyCancellable?
    private var revisionMenuObservation: AnyCancellable?
    private var revisionBusyObservation: AnyCancellable?
    var revisionFilesAvailable:Bool { !revisionHistoryBlocked && !retired && !busy && !selectingSplit && !pickingCommits && pickingReference == nil && !revisionFiles.busy && revisionFiles.window?.attachedSheet == nil }

    @Published var conflictRows: [StatusEntry] = []
    @Published var conflictStatistics: GitPathMap<CommitFile> = [:]
    @Published private(set) var conflictIndexFlags:GitPathMap<FinderIndexFlags>=[:]
    @Published private(set) var revertingConflictFiles=false
    @Published private(set) var conflictComparisonMark:PreparedFileComparisonMark?
    private var lastImportedConflictMark:UUID?
    lazy var conflictSubmoduleLog=SubmoduleWorkingLogSession(repository:repository,access:access,preferences:messageDefaults)
    var onConflictSubmoduleLog:(GitRepository)->Void = {_ in}
    var onConflictPreparedComparison:((PreparedFileComparisonMark,PreparedFileComparisonMark)->Void)?
    var onConflictUnified:((Data,Bool,String,OperationCancellation) async throws -> Void)?
    var confirmConflictMutation:(String,Bool) async -> Bool = {_,_ in false}
    var presentConflictRevert:([StatusEntry],@escaping (OperationCancellation,Bool) async throws -> Void) async -> Void = {_,_ in}
    var cancelConflictRevert:()->Void = {}
    private var presentingConflictFileDialog=false
    var cancelConflictFileDialog:()->Void = {}
    private(set) var conflictDeletionResult:WorkingFileDeleteResult?
    var confirmConflictDeletion:([String],Bool) async -> Bool = {_,_ in false}
    var presentConflictAdd:([String],WorkingFileAddMode,GitLibGit2Configuration,@escaping (OperationCancellation,Bool) async throws -> Void) async -> Void = {_,_,_,_ in}
    var presentConflictIgnore:(RepositoryAction,[String],@escaping (OperationCancellation,Bool) async throws -> Void) async throws -> Void = {_,_,_ in}
    var onConflictRevertSubmodules:(String,[String])->Void = {_,_ in}
    @Published var conflictFileColumns:StatusListColumnSettings
    @Published private(set) var conflictSortOrder:[RebaseConflictSort]
    @Published var focusedConflictPath:String?
    static let conflictColumnKey="Rebase.ConflictFileColumns"
    static let conflictColumns=StatusListColumn.defaultColumns
    var visibleConflictColumns:[StatusListColumn] { conflictFileColumns.order.filter { conflictFileColumns.visible.contains($0) && Self.conflictColumns.contains($0) } }
    var conflictTableRows:[RebaseConflictSortableRow] {
        conflictRows.map { RebaseConflictSortableRow(entry:$0,statistics:conflictStatistics[$0.path],status:conflictStatus($0,flags:conflictIndexFlags)) }.sorted(using:conflictSortOrder)
    }
    var conflictColumnsAvailable:Bool { !retired && !busy && !selectingSplit && fileRecovery }
    func setConflictColumn(_ column:StatusListColumn,visible:Bool) {
        guard conflictColumnsAvailable,column != .path,Self.conflictColumns.contains(column) else { return }
        if visible { conflictFileColumns.visible.insert(column) } else { conflictFileColumns.visible.remove(column) }
        conflictFileColumns.save(to:messageDefaults,key:Self.conflictColumnKey)
    }
    @discardableResult func saveConflictColumnLayout(order:[StatusListColumn],widths:[StatusListColumn:Double])->Bool {
        guard conflictColumnsAvailable else { return false }
        let value=StatusListColumnSettings(visible:conflictFileColumns.visible,order:order,widths:widths)
        if conflictFileColumns != value { conflictFileColumns=value;value.save(to:messageDefaults,key:Self.conflictColumnKey) };return true
    }
    func setConflictSort(_ sort:[RebaseConflictSort]) {
        guard conflictColumnsAvailable,let first=sort.first,Self.conflictColumns.contains(first.column) else { return }
        conflictSortOrder=sort.filter { Self.conflictColumns.contains($0.column) }
        messageDefaults.set(first.column.rawValue,forKey:Self.conflictColumnKey+".SortColumn")
        messageDefaults.set(first.order == .reverse,forKey:Self.conflictColumnKey+".SortDescending")
    }
    func resetConflictColumns(choose:@escaping () async -> Bool,onAccepted:@escaping ()->Void) {
        guard conflictColumnsAvailable else { return }
        let generation=conflictMenuGeneration;busy=true;Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task { [self,access] in
            defer { Self.activePreparationReads -= 1;pendingBatchWorkers -= 1;withExtendedLifetime(access) {};if !retired {busy=false;loadPendingHandoff()} }
            guard await choose(),!retired,generation==conflictMenuGeneration,fileRecovery else { return }
            conflictFileColumns=StatusListColumnSettings();conflictFileColumns.save(to:messageDefaults,key:Self.conflictColumnKey);onAccepted()
        }
    }
    func conflictColumnText(_ entry:StatusEntry,_ column:StatusListColumn)->String {
        switch column {
        case .path:return StatusListClipboard.displayedPath(entry,abbreviate:messageDefaults.bool(forKey:"AbbreviateRenamings"))
        case .fileName:return (entry.path as NSString).lastPathComponent
        case .fileExtension:return StatusListClipboard.fileExtension(entry.path,isDirectory:conflictStatistics[entry.path]?.isSubmodule == true)
        case .status:return FileListLabels.caption(conflictStatus(entry,flags:conflictIndexFlags))
        case .added:return conflictStatistics[entry.path]?.added.map(String.init) ?? "–"
        case .removed:return conflictStatistics[entry.path]?.removed.map(String.init) ?? "–"
        case .lastModified,.fileSize:return "–"
        case .lfsOwner:return ""
        }
    }
    private func conflictStatus(_ entry:StatusEntry,flags:GitPathMap<FinderIndexFlags>)->String {
        if flags[entry.path]?.skipWorktree == true {return "Skip-worktree"}
        if flags[entry.path]?.assumeUnchanged == true {return "Assume unchanged"}
        return entry.state.rawValue.capitalized
    }
    @Published var conflicts: [ConflictEntry] = []
    private var highlightedConflictPaths = GitPathSet()
    @Published var nativeConflictSelection = Set<String>() {
        didSet { highlightedConflictPaths = GitPathRowIdentity.paths(nativeConflictSelection) }
    }
    var selectedConflicts: GitPathSet {
        get { highlightedConflictPaths }
        set { let ids = Set(newValue.map(GitPathRowIdentity.encode)); if nativeConflictSelection != ids { nativeConflictSelection = ids } }
    }
    @Published var checkedConflicts = GitPathSet()
    private var conflictHead = ""
    var canCheckConflictFiles: Bool { fileRecovery && (state?.stoppedAction == .pick || state?.stoppedAction == .edit || state?.stoppedAction == .squash) }
    var prepareReplayMessage:(String,Bool,Bool,OperationCancellation) async throws -> String
    var supportsConflictSelection: Bool { state?.stoppedAction == .pick || state?.stoppedAction == .edit }
    @Published var fileRecovery = false
    var onConflictBaseComparison: (ConflictBaseComparison) -> Void = { _ in }
    var onConflictFileLog: (String) -> Void = { _ in }
    var onConflictFileBlame: (String, String) -> Void = { _, _ in }
    var onConflictWorkingComparison: ([String],Bool) -> Void = { _,_ in }
    var onConflictWorkingPair: ([String]) -> Void = { _ in }
    var chooseConflictApplication: () async -> URL? = { nil }
    var chooseConflictExport: () async -> URL? = { nil }
    var conflictPasteboard: NSPasteboard = .general
    var openConflictWorkingFile: (URL, URL?) async throws -> Void = { url, application in
        if let application {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
                    if let failure { reply.resume(throwing: failure) } else { reply.resume() }
                }
            }
        } else if !NSWorkspace.shared.open(url) { throw StatusFileActionFailure(message: "Could not open " + url.lastPathComponent + ".") }
    }
    lazy var openConflictAlternativeEditor: (URL) async throws -> Void = { [weak self] url in
        guard let self else { throw OperationCancellationFailure.cancelled }
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            AlternativeEditor.open(url, preferences: self.messageDefaults, permissions: self.access.map { [$0] } ?? []) { failure in if let failure { reply.resume(throwing: StatusFileActionFailure(message: failure)) } else { reply.resume() } }
        }
    }
    var revealConflictFiles: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    @Published var viewingConflictBase = false
    @Published private(set) var preparingConflictFiles = false
    private var conflictFileCancellation: OperationCancellation?
    private var conflictMenuGeneration = UUID()
    var onConflictAction: (RepositoryAction, [String]) -> Void = { _, _ in }
    @Published var conflictPatch: String?
    @Published var selectedFiles = Set<String>()
    @Published var message = ""
    @Published var amendMessage = "" { didSet { persistReplayMessageDraft() } }
    @Published private(set) var replayMessageCommit: LogEntry?
    @Published private(set) var replayMessageEditorID = UUID()
    private var replayMessageIdentity: RebaseMessageIdentity?
    private var replayMessageBaseline = ""
    private var installingReplayMessage = false
    private var replayMessageDraftKey: String { "Rebase.MessageDraft." + repository.root.standardizedFileURL.path }
    private func persistReplayMessageDraft() {
        guard !installingReplayMessage, let identity = replayMessageIdentity,
              let data = try? JSONEncoder().encode(RebaseMessageDraft(identity: identity, message: amendMessage)) else { return }
        messageDefaults.set(data, forKey: replayMessageDraftKey)
    }
    private func installReplayMessage(_ snapshot: RebaseSessionSnapshot) {
        let identity = RebaseMessageIdentity(state: snapshot.state, head: snapshot.head)
        let baseline = snapshot.state.cleanCommitFailure?.message ?? snapshot.state.squashMessage?.message ?? (snapshot.state.isEditPause ? snapshot.messageCommit?.message : nil) ?? snapshot.state.message
        let retained = identity != nil && identity == replayMessageIdentity && amendMessage != replayMessageBaseline ? amendMessage : nil
        let saved = messageDefaults.data(forKey: replayMessageDraftKey).flatMap { try? JSONDecoder().decode(RebaseMessageDraft.self, from: $0) }
        installingReplayMessage = true
        if identity != replayMessageIdentity { replayMessageEditorID = UUID() }
        replayMessageIdentity = identity; replayMessageBaseline = baseline; replayMessageCommit = snapshot.messageCommit
        amendMessage = retained ?? (saved?.identity == identity && identity != nil ? saved?.message : nil) ?? baseline
        installingReplayMessage = false
        if identity == nil { messageDefaults.removeObject(forKey: replayMessageDraftKey) }
        else { persistReplayMessageDraft() }
    }
    @Published var projectSettings = ProjectDialogSettings()
    @Published private(set) var issueProperties = IssueTrackerProperties()
    @Published var output = ""
    @Published var tab = 0
    @Published var busy = false {didSet{if busy != oldValue {controlMenuGeneration=UUID()}}}
    @Published var finished = false {didSet{if finished != oldValue {controlMenuGeneration=UUID()}}}
    @Published var completedSuccessfully = false
    var completionAfterFetch = false
    var completionFromLog = false
    var completionAutoStart = false
    var onCompletedLog: (() -> Void)?
    var onCompletedPush: ((String) -> Void)?
    var onCompletedMail: ((FormatPatchPreset) -> Void)?
    @Published var error: String?
    @Published var confirmation: String?
    @Published private(set) var pendingConfirmation: ActionConfirmation?
    @Published private(set) var pickingReference: RebaseReferenceTarget?
    var pickReference: (RebaseReferenceTarget) -> Void = { _ in }
    private var referenceRequest: RebaseReferenceRequest?
    private var referenceCancellation: OperationCancellation?
    private var planCancellation: OperationCancellation?
    private var detailCancellation: OperationCancellation?
    private var initialCancellation: OperationCancellation?
    private var messageSelectionCancellation: OperationCancellation?
    @Published private(set) var preparingMessageSelection = false
    private var insertionCancellation: OperationCancellation?
    private var mainlineCancellation: OperationCancellation?
    @Published private(set) var addingCommits = false
    @Published private(set) var preparingMainline = false
    var readAddedEntries: (([RebaseEntry], [String], OperationCancellation) async throws -> [RebaseEntry])?
    var readAddedPlan: ((RebasePlan, [String], OperationCancellation) async throws -> RebasePlan)?
    var readMainlineChoices: ((LogEntry, OperationCancellation) async throws -> [LogParentChoice])?
    var cancelMainlineQuestion: () -> Void = {}
    private var referenceRefreshCancellation:OperationCancellation?
    private var referenceRefreshGeneration=UUID()
    @Published private(set) var refreshingReferences=false
    var readRefreshReferences:((OperationCancellation)async throws->[CheckoutReference])?
    private var planSignature: Data?
    @Published private(set) var loadingPlan = false
    @Published private(set) var cancellingPreparation = false
    static private(set) var activePreparationReads = 0
    var readPlan: ((RebaseOptions, OperationCancellation) async throws -> RebasePlan)?
    var validateOnto: (String, String, String, OperationCancellation) async throws -> String?
    var hasCancellablePreparation: Bool { referenceRefreshCancellation != nil || messageSelectionCancellation != nil || actionEditCancellation != nil || insertionCancellation != nil || mainlineCancellation != nil || revisionFiles.hasOwnedPreparation || conflictFileCancellation != nil || sessionCancellation != nil || conflictDiffCancellation != nil || planCancellation != nil || referenceCancellation != nil || initialCancellation != nil || detailCancellation != nil }
    @discardableResult func cancelPreparation() -> Bool {
        if revertingConflictFiles {cancelConflictRevert();return true}
        if presentingConflictFileDialog {cancelConflictFileDialog();return true}
        guard hasCancellablePreparation else { return false }
        revisionFiles.cancelEmbeddedPreparation()
        messageSelectionCancellation?.cancel()
        cancellingPreparation = true; referenceRefreshCancellation?.cancel(); actionEditCancellation?.cancel(); insertionCancellation?.cancel(); mainlineCancellation?.cancel(); if preparingMainline || editingPendingActions { cancelMainlineQuestion() };pendingSessionRefresh=false;sessionCancellation?.cancel();conflictDiffCancellation?.cancel();conflictFileCancellation?.cancel(); planCancellation?.cancel(); referenceCancellation?.cancel(); initialCancellation?.cancel(); detailCancellation?.cancel(); return true
    }
    struct FormContext: Equatable {
        let owner: ObjectIdentifier; let controls: UUID; let generation: Int
        let active: Bool; let finished: Bool; let step: Int; let head: String
    }
    var formContext: FormContext { .init(owner:ObjectIdentifier(self),controls:controlMenuGeneration,generation:planGeneration,active:active,finished:finished,step:state?.currentStep ?? 0,head:conflictHead) }
    private func matches(_ context: FormContext) -> Bool { !retired && context == formContext }
    private var referenceIntent: [GitReferenceName] { [options.branch,options.upstream,options.onto,String(ontoEnabled),String(options.force),String(options.preserveMerges),String(options.isCherryPick),String(options.addCherryPickedFrom),String(options.squashDate.rawValue)].map { GitReferenceName($0) } }
    func referenceBinding(branch: Bool, context: FormContext) -> Binding<String> {
        Binding(get:{branch ? self.options.branch:self.options.upstream},set:{value in
            guard self.matches(context),self.editable,!self.isCherryPick else{return}
            if branch {self.chooseBranch(value)} else {self.chooseUpstream(value)}
        })
    }
    func option(_ key: WritableKeyPath<RebaseOptions,Bool>, context: FormContext) -> Binding<Bool> {
        Binding(get:{self.options[keyPath:key]},set:{value in
            guard self.matches(context),self.editable else{return}
            if key == \RebaseOptions.addCherryPickedFrom {guard self.isCherryPick else{return}}
            else {guard !self.isCherryPick else{return}}
            self.options[keyPath:key]=value
            if key == \RebaseOptions.addCherryPickedFrom {self.updateAttribution()} else {self.reloadPlan()}
        })
    }
    var canEditMessage: Bool { !revisionHistoryBlocked && !retired && !busy && state?.emptyMessageWarning == nil && state?.cleanCommitFailure == nil && state?.hasIgnoredCleanCommitFailure != true && !revisionFiles.busy && pickingReference == nil && !pickingCommits && !selectingSplit && pendingConfirmation == nil && confirmation == nil && (fileRecovery || state?.squashMessage != nil || state?.isEditPause == true || state?.split != nil) }
    func messageBinding(_ context: FormContext) -> Binding<String> { Binding(get:{self.amendMessage},set:{if self.matches(context),self.canEditMessage {self.amendMessage=$0}}) }
    func splitBinding(_ context: FormContext) -> Binding<Bool> { Binding(get:{self.splitCommit},set:{if self.matches(context),self.canSplit,self.state?.split == nil {self.splitCommit=$0}}) }
    func tabBinding(_ context: FormContext) -> Binding<Int> { Binding(get:{self.tab},set:{if self.matches(context),!self.busy,!self.selectingSplit,self.pickingReference == nil,self.pendingConfirmation == nil {self.tab=$0}}) }
    func reverseReferences(_ context: FormContext) {guard matches(context) else{return};reverseReferences()}
    func browseReference(_ target:RebaseReferenceTarget,context:FormContext) {guard matches(context),editable,!isCherryPick else{return};pickReference(target)}
    func move(up:Bool,toEnd:Bool,context:FormContext) {guard matches(context) else{return};move(up:up,toEnd:toEnd)}
    func add(_ context:FormContext) {guard matches(context),canAdd else{return};pickAdditionalCommits()}
    func primary(_ context:FormContext) {guard matches(context),pendingConfirmation == nil else{return};if finished {finishReplay()} else {request(active ? "continue":"start")}}
    func abort(_ context:FormContext) {guard matches(context),pendingConfirmation == nil else{return};if active {request("abort")} else {finishReplay()}}
    func request(_ action:String,context:FormContext) {guard matches(context) else{return};request(action)}
    struct ActionConfirmation: Identifiable {
        let id=UUID();let action:String;let message:String;let context:FormContext;let intent:[GitReferenceName]
    }
    private var replayIntent:[GitReferenceName] {
        let targets=[plan?.branchHash ?? "",plan?.upstreamHash ?? "",plan?.ontoHash ?? "",amendMessage,String(splitCommit)].map {GitReferenceName($0)}
        let rows=(plan?.entries ?? replayRows).flatMap {[$0.id,$0.action.rawValue,String($0.mainline ?? 0)]}.map {GitReferenceName($0)}
        let paths=checkedConflicts.sorted {$0.utf8.lexicographicallyPrecedes($1.utf8)}.map {GitReferenceName($0)}
        return referenceIntent + targets + rows + paths
    }
    private var insertionIntent: [GitReferenceName] {
        replayIntent + draftEntries.flatMap { [$0.id, $0.action.rawValue, String($0.mainline ?? 0)] }.map { GitReferenceName($0) }
    }
    func answerConfirmation(_ question:ActionConfirmation,proceed:Bool) {
        guard !retired,pendingConfirmation?.id == question.id else{return}
        let accepted=matches(question.context) && replayIntent == question.intent
        pendingConfirmation=nil;confirmation=nil
        defer {loadPendingHandoff()}
        guard proceed,accepted,canRequest(question.action) else{return};execute(question.action)
    }
    var canSkipReplay: Bool { canRequest("skip") }
    private func canRequest(_ action:String)->Bool {
        guard !containingReferenceBlocked,!revisionFindBlocked,!revisionHistoryBlocked,!retired,!busy,!revisionFiles.busy,pickingReference == nil,!pickingCommits,!selectingSplit,pendingConfirmation == nil,confirmation == nil,!hasReplayQuestion,!confirmingReplayCancellation else{return false}
        switch action {case "start":return canStart;case "skip":return active && state?.cleanCommitFailure == nil && state?.hasIgnoredCleanCommitFailure != true;case "continue","abort":return active;default:return false}
    }
    func referenceChoices(_ target: RebaseReferenceTarget?) -> [CheckoutReference] {
        let selected = target == nil ? options.branch : options.upstream
        var result = target == nil ? references.filter { $0.target == .branch && !$0.isFetchHead } : references
        if !result.contains(where: { GitReferenceName.equal($0.name, selected) }) { result.insert(CheckoutReference(name: selected), at: 0) }
        return result
    }
    func chooseBranch(_ name: String) { guard editable else { return }; options.branch = name; reloadPlan() }
    func chooseUpstream(_ name: String) { guard editable else { return }; options.upstream = name; reloadPlan() }
    func reverseReferences() {
        guard editable else { return }; let old = options.branch; options.branch = options.upstream; options.upstream = old; reloadPlan()
    }
    func beginReferenceSelection(_ target: RebaseReferenceTarget) -> RebaseReferenceRequest? {
        guard editable, !isCherryPick else { return nil }
        planCancellation?.cancel()
        let request = RebaseReferenceRequest(target: target, branch: options.branch, upstream: options.upstream, onto: options.onto, intent: referenceIntent)
        referenceRequest = request; pickingReference = target; return request
    }
    private func acceptsReference(_ request: RebaseReferenceRequest) -> Bool {
        !retired && referenceRequest?.id == request.id && referenceIntent == request.intent && GitReferenceName.equal(options.branch, request.branch) && GitReferenceName.equal(options.upstream, request.upstream) && GitReferenceName.equal(options.onto, request.onto)
    }
    func abandonReferenceSelection(_ request: RebaseReferenceRequest) {
        guard referenceRequest?.id == request.id else { return }; referenceRequest = nil; pickingReference = nil
        if !retired { reloadPlan(); loadPendingHandoff() }
    }
    func acceptReferenceSelection(_ request: RebaseReferenceRequest, value: String?) {
        guard acceptsReference(request) else { if referenceRequest?.id == request.id { referenceRequest = nil; pickingReference = nil; if !retired { reloadPlan(force: true); loadPendingHandoff() } }; return }
        if request.target == .upstream {
            referenceRequest = nil; pickingReference = nil
            if let value { options.upstream = value }
            reloadPlan(force: value != nil); loadPendingHandoff(); return
        }
        let token = OperationCancellation(); referenceCancellation = token; Self.activePreparationReads += 1;pendingBatchWorkers += 1; cancellingPreparation = false
        Task {
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}
                if referenceCancellation === token { referenceCancellation = nil; referenceRequest = nil; pickingReference = nil; cancellingPreparation = false; loadPendingHandoff() }
            }
            do {
                try requireAccess()
                let choice = try await validateOnto(value ?? "", request.branch, request.upstream, token)
                guard acceptsReference(request), !token.isCancelled else { return }
                referenceCancellation = nil; referenceRequest = nil; pickingReference = nil
                options.onto = choice ?? ""; ontoEnabled = choice != nil; cancellingPreparation = false; reloadPlan(force: true); loadPendingHandoff()
            } catch {
                guard acceptsReference(request), !token.isCancelled else { return }
                referenceCancellation = nil; referenceRequest = nil; pickingReference = nil; options.onto = ""; ontoEnabled = false; cancellingPreparation = false
                reloadPlan(); self.error = error.localizedDescription
            }
        }
    }

    @Published var pickingCommits = false
    @Published var splitCommit = false
    @Published var selectingSplit = false
    var showSplitSelection: (RebaseSplitState, String) -> Void = { _, _ in }
    var configureCommitSelection: (CommitWindowModel) -> Void = { _ in }
    var chooseAnotherSplit: () async -> Bool = { false }
    private(set) var retired = false
    @Published private(set) var hasReplayStash = false
    private var replayResultInspection:OperationCancellation?
    private var replayPreparationCancellation: OperationCancellation?
    static private(set) var activeReplayOperations = 0
    static func beginReplayWork() { activeReplayOperations += 1 }
    static func endReplayWork() { activeReplayOperations -= 1 }
    @Published private(set) var replaying = false
    @Published private(set) var replayStopped = false
    @Published private(set) var cancellingReplay = false
    @Published private(set) var confirmingReplayCancellation = false
    @Published var hasReplayQuestion = false
    var confirmReplayCancellation: () async -> Bool = { false }
    var confirmEmptyMessageReview: () async -> Bool = { false }
    func cancelReplay() {
        guard !retired, replaying, !hasReplayQuestion, !confirmingReplayCancellation, !cancellingReplay, let token = replayPreparationCancellation else { return }
        if !messageDefaults.bool(forKey: "ConfirmKillProcess") { pendingSessionRefresh = false; cancellingReplay = true; token.cancel(); return }
        confirmingReplayCancellation = true
        Task { let accepted = await confirmReplayCancellation(); confirmingReplayCancellation = false; if accepted && !retired && replayPreparationCancellation === token { pendingSessionRefresh = false; cancellingReplay = true; token.cancel() } }
    }

    var readReplayIdentity: ((OperationCancellation) async throws -> ReplayUserIdentity)?
    var repairReplayIdentity: () async -> Bool = { false }
    private func requireReplayIdentity(_ token: OperationCancellation) async throws {
        while true {
            try token.check(); guard !retired else { throw OperationCancellationFailure.cancelled }
            let identity: ReplayUserIdentity
            if let readReplayIdentity { identity = try await readReplayIdentity(token) }
            else { identity = try await repository.replayUserIdentity(cancellation: token) }
            try token.check(); guard !retired else { throw OperationCancellationFailure.cancelled }
            if identity.complete { return }
            guard await repairReplayIdentity(), !retired else { throw OperationCancellationFailure.cancelled }
            try token.check()
        }
    }
    var chooseStashBeforeReplay: () async -> Bool = { false }
    var chooseRestoreReplayStash: () async -> Bool = { false }
    var restoreReplayStash: (Int) async -> Void = { _ in }
    func retire() { retired = true;pendingLoad=nil;referenceRefreshGeneration=UUID();referenceRefreshCancellation?.cancel(); replayResultInspection?.cancel(); replayResultInspection=nil; messageSelectionCancellation?.cancel(); actionEditCancellation?.cancel(); pendingConfirmation=nil;confirmation=nil; insertionCancellation?.cancel(); mainlineCancellation?.cancel(); cancelMainlineQuestion(); additionalSelection = nil; pickingCommits = false;revisionFiles.invalidate();revisionFiles.closeOwnedViewers();conflictSubmoduleLog.retire();conflictComparisonMark=nil;pendingSessionRefresh=false;sessionGeneration=UUID();conflictDiffGeneration=UUID();sessionCancellation?.cancel();conflictDiffCancellation?.cancel();conflictFileCancellation?.cancel(); planCancellation?.cancel(); referenceCancellation?.cancel(); initialCancellation?.cancel(); detailCancellation?.cancel(); planGeneration += 1; detailGeneration += 1; referenceRequest = nil; pickingReference = nil; loadingPlan = false; columnGeneration = UUID(); columnToken?.cancel(); columnToken = nil; loadingColumnMetadata = false; revisionMenuLog.invalidate(); replayPreparationCancellation?.cancel(); clientHooks.retire() }
    func finishReplay(after: (() -> Void)? = nil) {
        guard !retired, pendingConfirmation == nil, !busy, !revisionFiles.busy, !active, !selectingSplit, !pickingCommits else { return }
        // Preserve immediate completion routing when there is no stash question
        // or restore operation to await.
        if !hasReplayStash { if let after { after() } else { close() }; return }
        busy=true;let request=OperationCancellation();replayPreparationCancellation=request
        Self.activeStashRestorations += 1;pendingBatchWorkers += 1
        Task {
            defer { busy=false;Self.activeStashRestorations -= 1;pendingBatchWorkers -= 1;if replayPreparationCancellation === request { replayPreparationCancellation=nil };withExtendedLifetime(access) {} }
            do {
                if hasReplayStash {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let automatic=try await repository.replayAutomaticStash(cherryPick:isCherryPick,cancellation:request)
                    guard !retired,!request.isCancelled else { return }
                    let restore=automatic ? true : await chooseRestoreReplayStash()
                    guard !retired,!request.isCancelled else { return }
                    // Once-only, including No: source clears m_bStashed after this choice.
                    hasReplayStash=false
                    if restore { await restoreReplayStash(automatic ? 0 : 1) }
                }
                guard !retired,!request.isCancelled else { return }
                busy=false
                if let after { after() } else { close() }
            } catch { if !retired,!request.isCancelled { self.error=error.localizedDescription } }
        }
    }
    var close: () -> Void = {}
    var onChanged: () -> Void = {}
    var onShowStatus: () -> Void = {}
    var onModeChanged: () -> Void = {}
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    lazy var revisionMenuLog = LogWindowModel(repository: repository, access: access, labelDefaults: messageDefaults)
    var onRefreshRevisionFind: () -> Void = {}
    var onFindAvailability: () -> Void = {}
    var onFindRevision: (() -> Void)?
    var revisionFindIndex = 0
    @Published var revisionFindHighlightHash: String?
    @Published var revisionFindBlocked = false
    @Published var containingReferenceBlocked = false
    @Published var scrollRevisionOccurrence: String?
    @Published var scrollRevisionRequest = 0
    var onShowRevisionLog: ((String) -> Void)?
    var pickAdditionalCommits: () -> Void = {}
    enum CleanCommitFailureDecision { case retry, ignore }
    var chooseCleanCommitFailure: (RebaseCleanCommitFailure) async -> CleanCommitFailureDecision = { _ in .retry }
    var cleanCommitFailure: RebaseCleanCommitFailure? { state?.cleanCommitFailure }
    private var cleanCommitReturnedToEditor = false
    enum FailedPickDecision { case retry, skip(remember:Bool), cancel }
    var chooseFailedPickRecovery: (RebaseFailedPickRecovery) async -> FailedPickDecision = { _ in .cancel }
    var chooseFailedPickCleanup: (RebaseFailedPickRecovery) async -> Bool = { _ in false }
    private(set) var automaticallySkipFailedPicks=false
    private var failedPickSkipSession:String?
    private(set) var failedPickRecoveryCancelled=false
    var chooseEmptyResult: () async -> RebaseEmptyChoice = { .cancel }
    var confirmConflictHints: () async -> Bool = { false }
    var chooseMainline: (LogEntry, [LogParentChoice]) async -> Int? = { _, _ in nil }
    var editorExecutable: URL? = Bundle.main.executableURL
    var isCherryPick: Bool { options.isCherryPick || state?.isCherryPick == true }
    var operationTitle: String { isCherryPick ? "Cherry Pick" : "Rebase" }
    var startTitle: String { isCherryPick ? "Continue" : plan?.disposition == .fastForward ? "Start (FastFwd)" : "Start Rebase" }
    private var planGeneration = 0
    private var detailGeneration = 0
    private var conflictIdentity:RebaseConflictIdentity?
    private var sessionCancellation:OperationCancellation?
    private var conflictDiffCancellation:OperationCancellation?
    private var sessionGeneration=UUID()
    private var conflictDiffGeneration=UUID()
    private var pendingSessionRefresh=false
    @Published private(set) var refreshingSession=false
    @Published private(set) var preparingConflictDiff=false
    var readSession:((RebaseConflictIdentity?,OperationCancellation) async throws -> RebaseSessionSnapshot)?
    private func applyConflictSnapshot(_ snapshot:RebaseSessionSnapshot) {
        conflictMenuGeneration = UUID()
        let previousPaths=conflictIdentity == snapshot.identity ? GitPathSet(conflictRows.map(\.path)):[]
        if conflictIdentity != snapshot.identity || !snapshot.fileRecovery {checkedConflicts=[]}
        state=snapshot.state;fileRecovery=snapshot.fileRecovery;conflictIdentity=snapshot.identity
        conflicts=snapshot.conflicts;conflictRows=snapshot.rows;conflictStatistics=snapshot.statistics;conflictIndexFlags=snapshot.indexFlags;conflictHead=snapshot.head
        let paths=GitPathSet(snapshot.rows.map(\.path))
        checkedConflicts.formIntersection(paths);checkedConflicts.formUnion(paths.subtracting(previousPaths))
        selectedConflicts.formIntersection(GitPathSet(snapshot.rows.map(\.id)))
        if !snapshot.fileRecovery {checkedConflicts=[]}
        installReplayMessage(snapshot)
    }
    private func readAddedEntriesValue(_ entries:[RebaseEntry],_ revisions:[String],_ token:OperationCancellation,repository:GitRepository) async throws -> [RebaseEntry] {
        if let readAddedEntries {return try await readAddedEntries(entries,revisions,token)}
        return try await repository.addingRebaseEntries(entries,revisions:revisions,cancellation:token)
    }
    private func readAddedPlanValue(_ plan:RebasePlan,_ revisions:[String],_ token:OperationCancellation,repository:GitRepository) async throws -> RebasePlan {
        if let readAddedPlan {return try await readAddedPlan(plan,revisions,token)}
        return try await repository.addingRebaseCommits(plan,revisions:revisions,cancellation:token)
    }
    private func readMainlineChoicesValue(_ commit:LogEntry,_ token:OperationCancellation,repository:GitRepository) async throws -> [LogParentChoice] {
        if let readMainlineChoices {return try await readMainlineChoices(commit,token)}
        return try await repository.logParentChoices(commit,cancellation:token)
    }
    private func readPlanValue(_ options:RebaseOptions,_ cancellation:OperationCancellation,repository captured:GitRepository?=nil) async throws -> RebasePlan {
        if let readPlan {return try await readPlan(options,cancellation)}
        let repository=captured ?? self.operationRepository()
        return try await repository.rebasePlan(options,cancellation:cancellation)
    }
    private func readSessionValue(_ identity:RebaseConflictIdentity?,_ cancellation:OperationCancellation,repository captured:GitRepository?=nil) async throws -> RebaseSessionSnapshot {
        if let readSession {return try await readSession(identity,cancellation)}
        let repository=captured ?? self.operationRepository()
        return try await repository.rebaseSessionSnapshot(retaining:identity,cancellation:cancellation)
    }
    private func loadConflictFiles(cancellation:OperationCancellation?=nil,repository captured:GitRepository?=nil) async throws {
        try cancellation?.check();guard !retired else {return}
        let repository=captured ?? self.operationRepository()
        let token=cancellation ?? OperationCancellation()
        if cancellation == nil {replayResultInspection=token}
        defer {if replayResultInspection === token {replayResultInspection=nil}}
        let snapshot=try await repository.rebaseSessionSnapshot(retaining:conflictIdentity,includeReplay:false,cancellation:token)
        try token.check();guard !retired else {return};applyConflictSnapshot(snapshot)
    }
    struct ConflictFileMenu {
        let generation: UUID
        let identity: RebaseConflictIdentity?
        let head: String
        let rows: [StatusEntry]
        let conflicts: [ConflictEntry]
        let statistics: GitPathMap<CommitFile>
        let columns:[StatusListColumn]
        let indexFlags:GitPathMap<FinderIndexFlags>
        let mark:String
        let comparisonMark:PreparedFileComparisonMark?
        let amendToParent:Bool
        var paths: [String] { rows.map(\.path) }
    }
    let workingDragOrigin = UUID().uuidString
    /// Paused replay files are working-tree paths, independent of commit checks.
    func captureWorkingDrag(_ orderedPaths:[String])->WorkingFileListDrag? {
        guard revisionMenuOwnerAvailable, !containingReferenceBlocked, !viewingConflictBase,
              !preparingConflictDiff, !refreshingSession, fileRecovery,
              NSApp.modalWindow == nil, !orderedPaths.isEmpty,
              GitPathSet(orderedPaths).count == orderedPaths.count else { return nil }
        let menu=conflictFileMenu(orderedPaths)
        guard acceptsConflictFileMenu(menu), orderedPaths.allSatisfy({selectedConflicts.contains($0)}) else { return nil }
        let lookup=GitPathMap(uniqueKeysWithValues:menu.rows.map{($0.path,$0)})
        let rows=orderedPaths.compactMap{lookup[$0]}
        guard rows.count == orderedPaths.count else { return nil }
        let directories=GitPathSet(rows.filter { row in
            let attributes=try? FileManager.default.attributesOfItem(atPath:repository.root.appendingPathComponent(row.path).path)
            return conflictStatistics[row.path]?.isSubmodule == true || conflicts.contains{GitReferenceName.equal($0.path,row.path) && $0.isSubmodule} ||
                attributes?[.type] as? FileAttributeType == .typeDirectory
        }.map(\.path))
        return FileListDrag.workingSelection(repository:repository,access:access,entries:rows,
            directories:directories,backend:operationRepository().libgit2Configuration ?? GitLibGit2Configuration.load(from:messageDefaults),origin:workingDragOrigin)
    }
    func conflictFileMenu(_ values: some Sequence<String>,markedPath:String?=nil) -> ConflictFileMenu {
        let ids = GitPathSet(values)
        let rows = conflictTableRows.map(\.entry).filter { ids.contains($0.id) }
        return ConflictFileMenu(generation: conflictMenuGeneration, identity: conflictIdentity, head: conflictHead, rows: rows, conflicts: conflicts.filter { ids.contains($0.id) }, statistics: conflictStatistics,columns:visibleConflictColumns,indexFlags:conflictIndexFlags,mark:(markedPath ?? focusedConflictPath).flatMap {id in rows.contains(where:{GitReferenceName.equal($0.id,id)}) ? id:nil} ?? rows.first?.id ?? "",comparisonMark:conflictComparisonMark,amendToParent:state?.stoppedAction == .squash)
    }
    private func acceptsConflictFileMenu(_ menu: ConflictFileMenu, duringRequest: Bool = false) -> Bool {
        !retired && pendingConfirmation == nil && (duringRequest || !busy) && !viewingConflictBase && !selectingSplit && fileRecovery &&
        menu.generation == conflictMenuGeneration && menu.identity == conflictIdentity && menu.head == conflictHead &&
        !menu.rows.isEmpty && menu.rows.allSatisfy { conflictRows.contains($0) }
    }
    func canConflictFileCommand(_ command: StatusFileCommand, menu: ConflictFileMenu) -> Bool {
        guard acceptsConflictFileMenu(menu) else { return false }
        let ordinary = menu.rows.allSatisfy { row in menu.statistics[row.path]?.isSubmodule != true && !menu.conflicts.contains(where: { GitReferenceName.equal($0.path, row.path) && $0.isSubmodule }) }
        switch command {
        case .log: return menu.rows.count == 1
        case .oldNameLog: return menu.rows.count == 1 && menu.rows[0].originalPath != nil
        case .blame: return menu.rows.count == 1 && ordinary && menu.rows[0].state != .deleted && menu.rows[0].state != .added
        case .editor, .open, .openWith: return menu.rows.count == 1 && ordinary && menu.rows[0].state != .deleted
        case .export: return ordinary && menu.rows.allSatisfy { $0.state != .deleted }
        case .reveal: return menu.rows.count == 1 && menu.rows[0].state != .deleted
        case .compareTwo: return menu.rows.count == 2 && ordinary && menu.rows.allSatisfy { $0.state != .deleted }
        case .submoduleLog:return menu.rows.count == 1 && !ordinary
        case .delete: return menu.rows.first(where:{GitReferenceName.equal($0.id,menu.mark)})?.canDeleteFromStatusList == true
        }
    }
    private func validateConflictFileMenu(_ menu: ConflictFileMenu, token: OperationCancellation,validateRows:Bool=true) async throws {
        try requireAccess(); try token.check()
        guard acceptsConflictFileMenu(menu, duringRequest: true) else { throw RebaseFailure.changed }
        let fresh = try await readSessionValue(menu.identity, token)
        guard fresh.identity == menu.identity, fresh.head == menu.head, fresh.fileRecovery,
              !validateRows || menu.rows.allSatisfy({ fresh.rows.contains($0) && fresh.indexFlags[$0.path] == menu.indexFlags[$0.path] }),
              !validateRows || menu.conflicts.allSatisfy({ fresh.conflicts.contains($0) }) else { throw RebaseFailure.changed }
        try token.check(); guard acceptsConflictFileMenu(menu, duringRequest: true) else { throw RebaseFailure.changed }
    }
    private func conflictLocation(_ path: String) throws -> URL {
        _ = try RemovalRequest(paths: [path], keepLocal: true)
        let location = repository.root.appendingPathComponent(path).standardizedFileURL
        guard RepositoryAccessLease.pathIsContained(location.deletingLastPathComponent(), by: repository.root) else { throw ResolveFailure.outsideWorkingTree }
        return location
    }
    private func runConflictFileMenu(_ menu: ConflictFileMenu, operation: @escaping (OperationCancellation) async throws -> Void) {
        guard acceptsConflictFileMenu(menu) else { return }
        let alternate=ComparisonToolInvocation.capture
        let token = OperationCancellation(); conflictFileCancellation = token; preparingConflictFiles = true; cancellingPreparation = false; busy = true; error = nil
        Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task {
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}
                if conflictFileCancellation === token { conflictFileCancellation = nil; preparingConflictFiles = false; cancellingPreparation = false; if !retired { busy = false; loadPendingHandoff() } }
            }
            do { try await validateConflictFileMenu(menu, token: token); try await ComparisonToolInvocation.$alternate.withValue(alternate) {try await operation(token)} }
            catch { if !retired, !token.isCancelled, conflictFileCancellation === token { self.error = error.localizedDescription } }
        }
    }
    func conflictFileCommand(_ command: StatusFileCommand, menu: ConflictFileMenu) {
        if command == .delete {deleteConflictFiles(menu,permanently:NSEvent.modifierFlags.contains(.shift));return}
        guard canConflictFileCommand(command, menu: menu) else { return }
        runConflictFileMenu(menu) { [self] token in
            switch command {
            case .log: onConflictFileLog(menu.paths[0])
            case .oldNameLog: if let old = menu.rows[0].originalPath { onConflictFileLog(old) }
            case .blame: onConflictFileBlame(menu.paths[0], menu.head)
            case .compareTwo: onConflictWorkingPair(menu.paths)
            case .reveal: revealConflictFiles(try menu.paths.map(conflictLocation))
            case .open, .openWith, .editor:
                let application = command == .openWith ? await chooseConflictApplication() : nil
                guard command != .openWith || application != nil else { return }
                try await validateConflictFileMenu(menu, token: token)
                let location = try conflictLocation(menu.paths[0])
                let type = try FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else { throw WorkingFileRestoreFailure.unsupported }
                let grant = application.map { RepositoryAccessLease(url: $0) }
                if GitRuntime.isAppStoreBuild, application != nil, grant?.hasSecurityScope != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                defer { withExtendedLifetime(grant) {} }
                if command == .editor { try await openConflictAlternativeEditor(location) } else { try await openConflictWorkingFile(location, application) }
            case .export:
                guard let folder = await chooseConflictExport() else { return }
                let permission = RepositoryAccessLease(url: folder); defer { withExtendedLifetime(permission) {} }
                if GitRuntime.isAppStoreBuild && (!permission.hasSecurityScope || !permission.contains(folder)) { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await validateConflictFileMenu(menu, token: token)
                let count = try await repository.exportWorkingFiles(paths: menu.paths, to: folder, cancellation: token)
                guard !retired, !token.isCancelled else { return }; output += "Exported \(count) files.\n"
            case .submoduleLog:
                let child=try await conflictSubmoduleLog.load(menu.paths[0],cancellation:token)
                try await validateConflictFileMenu(menu,token:token);onConflictSubmoduleLog(child)
            case .delete: break
            }
        }
    }
    func importConflictComparisonMark(_ access:WorkingComparisonAccess?) {
        guard !retired,let access,access.mark.id != lastImportedConflictMark else {return}
        lastImportedConflictMark=access.mark.id
        conflictComparisonMark=PreparedFileComparisonMark(path:access.file.path,revision:"",workingAccess:access)
    }
    func canMarkConflictComparison(_ menu:ConflictFileMenu)->Bool {
        guard acceptsConflictFileMenu(menu),let mark=menu.rows.first(where:{GitReferenceName.equal($0.id,menu.mark)}) else {return false}
        return mark.state != .deleted && menu.statistics[mark.path]?.isSubmodule != true && !menu.conflicts.contains {GitReferenceName.equal($0.path,mark.path) && $0.isSubmodule}
    }
    func markConflictForComparison(_ menu:ConflictFileMenu) {
        guard canMarkConflictComparison(menu) else {return}
        runConflictFileMenu(menu) { [self] token in
            try token.check();conflictComparisonMark=PreparedFileComparisonMark(path:menu.mark,revision:"")
        }
    }
    func compareConflictWithMarked(_ menu:ConflictFileMenu,alternate:Bool?=nil) {
        guard canMarkConflictComparison(menu),let mark=menu.comparisonMark,let onConflictPreparedComparison else {return}
        let alternate=alternate ?? ComparisonToolInvocation.capture
        runConflictFileMenu(menu) { token in
            try token.check()
            ComparisonToolInvocation.$alternate.withValue(alternate) {onConflictPreparedComparison(mark,PreparedFileComparisonMark(path:menu.mark,revision:""))}
        }
    }
    func canShowConflictUnified(_ menu:ConflictFileMenu)->Bool {
        acceptsConflictFileMenu(menu) && menu.rows.first(where:{GitReferenceName.equal($0.id,menu.mark)})?.canCompareWithBaseFromStatusList == true && onConflictUnified != nil
    }
    func showConflictUnified(_ menu:ConflictFileMenu,alternate:Bool?=nil) {
        guard canShowConflictUnified(menu) else {return}
        let alternate=alternate ?? ComparisonToolInvocation.capture
        runConflictFileMenu(menu) { [self] token in
            let base=menu.amendToParent ? try await repository.commitComparisonBase(amendToParent:true,cancellation:token):menu.head
            var bytes=Data()
            for row in menu.rows {
                try token.check()
                let paths=[row.path]+(row.originalPath.map {[$0]} ?? [])
                let patch=try await repository.run(["diff","--no-ext-diff","--no-textconv","--no-color"]+repository.diffDetection.comparisonArguments+[base,"--"]+paths,cancellation:token).stdout
                bytes.append(patch)
            }
            try await validateConflictFileMenu(menu,token:token)
            try await onConflictUnified?(bytes,alternate,"Changes in \(menu.rows.count) replay file(s)",token)
        }
    }
    func canAddConflictFiles(_ menu:ConflictFileMenu,mode:WorkingFileAddMode = .normal)->Bool {
        guard acceptsConflictFileMenu(menu),let mark=menu.rows.first(where:{GitReferenceName.equal($0.id,menu.mark)}) else {return false}
        guard mark.state == .untracked || mark.state == .ignored || mark.hasUnversionedCopy else {return false}
        if mode != .normal {
            guard let location=try? conflictLocation(mark.path),let attributes=try? FileManager.default.attributesOfItem(atPath:location.path),attributes[.type] as? FileAttributeType != .typeDirectory else {return false}
        }
        return true
    }
    func addConflictFiles(_ menu:ConflictFileMenu,mode:WorkingFileAddMode) {
        guard canAddConflictFiles(menu,mode:mode) else {return}
        let backend=operationRepository().libgit2Configuration ?? GitLibGit2Configuration.load(from:messageDefaults)
        runConflictFileMenu(menu) { [self] token in
            try token.check();presentingConflictFileDialog=true
            defer {presentingConflictFileDialog=false;if !retired {pendingSessionRefresh=true;onChanged()}}
            await presentConflictAdd(menu.paths,mode,backend) { [self] request,initial in
                try await validateConflictFileMenu(menu,token:request,validateRows:initial)
            }
        }
    }
    func canIgnoreConflictFiles(_ menu:ConflictFileMenu)->Bool {
        guard acceptsConflictFileMenu(menu),let mark=menu.rows.first(where:{GitReferenceName.equal($0.id,menu.mark)}) else {return false}
        return mark.state == .untracked || mark.state == .deleted || mark.hasUnversionedCopy
    }
    func ignoreConflictFiles(_ menu:ConflictFileMenu,action:RepositoryAction,paths:[String]) {
        guard canIgnoreConflictFiles(menu),action.isIgnore else {return}
        let folders=menu.paths.map {($0 as NSString).deletingLastPathComponent}.filter {!$0.isEmpty}
        guard paths.map({GitReferenceName($0)}) == menu.paths.map({GitReferenceName($0)}) || paths.count==1 && GitPathSet(folders).contains(paths[0]) else {return}
        runConflictFileMenu(menu) { [self] token in
            try token.check();presentingConflictFileDialog=true
            defer {presentingConflictFileDialog=false;if !retired {pendingSessionRefresh=true;onChanged()}}
            try await presentConflictIgnore(action,paths) { [self] request,initial in
                try await validateConflictFileMenu(menu,token:request,validateRows:initial)
            }
        }
    }
    func deleteConflictFiles(_ menu:ConflictFileMenu,permanently:Bool) {
        guard canConflictFileCommand(.delete,menu:menu) else {return}
        runConflictFileMenu(menu) { [self] token in
            guard await confirmConflictDeletion(menu.paths,permanently) else {return}
            try await validateConflictFileMenu(menu,token:token)
            defer {if !retired {pendingSessionRefresh=true;onChanged()}}
            let result=try await repository.deleteWorkingFiles(menu.rows,selectionMark:menu.rows.first {GitReferenceName.equal($0.id,menu.mark)},permanently:permanently,cancellation:token)
            guard !retired,!token.isCancelled else {return}
            conflictDeletionResult=result
            output += "Deleted \(result.removedPaths.count) working file(s); removed \(result.removedIndexPaths.count) index entries.\n"
            if !result.trashedFiles.isEmpty {output += "Recoverable in Trash:\n"+result.trashedFiles.map(\.path).joined(separator:"\n")+"\n"}
            checkedConflicts.subtract(menu.paths);selectedConflicts.subtract(menu.paths)
        }
    }
    func canRevertConflictFiles(_ menu:ConflictFileMenu)->Bool {
        acceptsConflictFileMenu(menu) && menu.rows.allSatisfy { ![FileState.untracked,.ignored].contains($0.state) }
    }
    func canSetConflictFlags(_ action:IndexFlagAction,menu:ConflictFileMenu)->Bool {
        guard acceptsConflictFileMenu(menu),let mark=menu.rows.first(where:{GitReferenceName.equal($0.id,menu.mark)}) else {return false}
        return action.isAvailable(for:mark,flags:menu.indexFlags[mark.path] ?? FinderIndexFlags())
    }
    func setConflictFlags(_ action:IndexFlagAction,menu:ConflictFileMenu) {
        guard canSetConflictFlags(action,menu:menu) else {return}
        runConflictFileMenu(menu) { [self] token in
            guard await confirmConflictMutation(action.confirmation,true) else {return}
            try await validateConflictFileMenu(menu,token:token)
            defer {if !retired {pendingSessionRefresh=true;onChanged()}}
            try await repository.setIndexFlags(action,paths:menu.paths,markedPath:menu.mark,cancellation:token)
        }
    }
    func revertConflictFiles(_ menu:ConflictFileMenu) {
        guard canRevertConflictFiles(menu) else {return}
        runConflictFileMenu(menu) { [self] token in
            let confirm=menu.rows.contains {$0.state == .modified && menu.statistics[$0.path]?.isSubmodule != true}
            if confirm {guard await confirmConflictMutation("Revert changes in \(menu.rows.count) selected file(s)?",false) else {return}}
            try await validateConflictFileMenu(menu,token:token)
            revertingConflictFiles=true
            defer {revertingConflictFiles=false;if !retired {pendingSessionRefresh=true;onChanged()}}
            await presentConflictRevert(menu.rows) { [self] request,initial in
                try await validateConflictFileMenu(menu,token:request,validateRows:initial)
            }
        }
    }
    func compareConflictWorkingFiles(_ menu: ConflictFileMenu) {
        guard acceptsConflictFileMenu(menu), menu.rows.allSatisfy({ $0.state != .conflicted }) else { return }
        runConflictFileMenu(menu) { [self] token in try token.check(); onConflictWorkingComparison(menu.paths,menu.amendToParent) }
    }
    func conflictClipboardText(_ menu: ConflictFileMenu, copy: StatusListCopy) -> String {
        let files=menu.rows.map { entry in
            let stats=menu.statistics[entry.path]
            return CommitFile(path:entry.path,oldPath:entry.originalPath,action:stats?.action ?? "M",added:stats?.added,removed:stats?.removed,hasStatistics:stats?.hasStatistics ?? false,isSubmodule:stats?.isSubmodule ?? false)
        }
        let statuses=GitPathMap(uniqueKeysWithValues:zip(files,menu.rows).map {($0.0.id,conflictStatus($0.1,flags:menu.indexFlags))})
        return StatusListClipboard.text(files,root:repository.root,statuses:statuses,copy:copy,visibleColumns:menu.columns, label:FileListLabels.caption)
    }
    func copyConflictFiles(_ menu: ConflictFileMenu, copy: StatusListCopy) {
        guard acceptsConflictFileMenu(menu) else { return }; let text = conflictClipboardText(menu, copy: copy)
        guard !text.isEmpty else { return }; conflictPasteboard.clearContents(); conflictPasteboard.setString(text, forType: .string)
    }
    func setConflictChecked(_ path:String,checked:Bool) {
        guard !retired,pendingConfirmation == nil,!busy,!selectingSplit,canCheckConflictFiles,conflictRows.contains(where:{GitReferenceName.equal($0.path,path)}) else {return}
        let targets = selectedConflicts.contains(path) ? selectedConflicts.intersection(conflictRows.map(\.path)) : GitPathSet([path])
        if checked {checkedConflicts.formUnion(targets)} else {checkedConflicts.subtract(targets)}
    }
    func toggleConflictChecks(_ values: some Sequence<String>, mark: String?) {
        let ids = GitPathSet(values)
        guard !retired, pendingConfirmation == nil, !busy, !selectingSplit, fileRecovery, canCheckConflictFiles else { return }
        let available = GitPathSet(conflictRows.map(\.id)), selected = ids.intersection(available)
        guard !selected.isEmpty else { return }
        let shouldCheck = !(mark.map { checkedConflicts.contains($0) } ?? selected.allSatisfy { checkedConflicts.contains($0) })
        if shouldCheck { checkedConflicts.formUnion(selected) } else { checkedConflicts.subtract(selected) }
    }
    func conflictAction(_ action: RepositoryAction, ids: some Sequence<String>) { conflictAction(action, menu: conflictFileMenu(ids)) }
    func conflictAction(_ action: RepositoryAction, menu: ConflictFileMenu) {
        let paths = menu.conflicts.map(\.path)
        guard acceptsConflictFileMenu(menu), !paths.isEmpty, action != .editConflict || paths.count == 1 && menu.rows.count == 1 else { return }
        runConflictFileMenu(menu) { [self] token in
            try token.check(); guard !retired else { return }; onConflictAction(action, paths)
        }
    }
    func compareConflictMenu(_ menu: ConflictFileMenu) {
        guard acceptsConflictFileMenu(menu),menu.rows.first(where:{GitReferenceName.equal($0.id,menu.mark)})?.canCompareWithBaseFromStatusList == true else { return }
        if menu.rows.count==1,menu.conflicts.count==1 {compareConflicts(GitPathSet(menu.conflicts.map(\.id)))}
        else {runConflictFileMenu(menu) { [self] token in try token.check();onConflictWorkingComparison(menu.paths,menu.amendToParent)}}
    }
    func compareConflicts(_ values:some Sequence<String>) {
        let ids = GitPathSet(values)
        let paths=conflicts.filter {ids.contains($0.id)}.map(\.path)
        guard !retired,!busy,!selectingSplit,!paths.isEmpty else {return}
        let captured=conflictIdentity,request=UUID(),token=OperationCancellation(),alternate=ComparisonToolInvocation.capture
        conflictDiffGeneration=request;conflictDiffCancellation=token;preparingConflictDiff=true;cancellingPreparation=false;busy=true
        Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task {
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1;withExtendedLifetime(access) {}
                if conflictDiffCancellation === token {conflictDiffCancellation=nil;preparingConflictDiff=false;cancellingPreparation=false;if !retired {busy=viewingConflictBase;if !viewingConflictBase {loadPendingHandoff()}}}
            }
            do {
                try requireAccess()
                let fresh=try await repository.rebaseState(cancellation:token)
                guard RebaseConflictIdentity(fresh) == captured else {throw RebaseFailure.changed}
                if paths.count == 1, let entry = conflicts.first(where: { GitReferenceName.equal($0.path,paths[0]) }), !entry.isSubmodule, entry.stages.contains(where: { $0.number == 1 }) {
                    let prepared = try await repository.conflictBaseComparison(entry, cancellation: token)
                    let current = try await repository.rebaseState(cancellation: token)
                    guard RebaseConflictIdentity(current) == captured else { throw RebaseFailure.changed }
                    guard !retired, !token.isCancelled, conflictDiffGeneration == request, conflictIdentity == captured else { return }
                    ComparisonToolInvocation.$alternate.withValue(alternate) {onConflictBaseComparison(prepared)}; return
                }
                let patch=try await repository.run(["diff","--no-ext-diff","--no-textconv","--no-color","--base","--"]+paths,cancellation:token).text
                let current=try await repository.rebaseState(cancellation:token)
                guard RebaseConflictIdentity(current) == captured else {throw RebaseFailure.changed}
                guard !retired,!token.isCancelled,conflictDiffGeneration == request,conflictIdentity == captured else {return}
                conflictPatch=patch
            } catch {if !retired,!token.isCancelled,conflictDiffGeneration == request {self.error=error.localizedDescription}}
        }
    }
    private var completion = "Rebase finished"
    private var pendingLoad: (upstream: String?, autoStart: Bool, preserveMerges: Bool, cherryPick: [String]?, force: Bool?,acceptedRepository:GitRepository?)?
    private func loadPendingHandoff() {
        guard !retired,!busy,pendingConfirmation == nil,pickingReference == nil,!pickingCommits,!selectingSplit else {return}
        if pendingSessionRefresh {pendingSessionRefresh=false;refreshState();return}
        guard let pending=pendingLoad else {return}
        pendingLoad = nil
        load(upstream: pending.upstream, autoStart: pending.autoStart, preserveMerges: pending.preserveMerges, cherryPick: pending.cherryPick, force: pending.force,acceptedRepository:pending.acceptedRepository)
    }
    var active: Bool { state?.active == true }
    var editable: Bool { !containingReferenceBlocked && !revisionFindBlocked && !revisionHistoryBlocked && confirmation == nil && pendingConfirmation == nil && !retired && !busy && !revisionFiles.busy && pickingReference == nil && !active && !finished && !pickingCommits && !selectingSplit }
    var canAdd: Bool { editable && !options.preserveMerges }
    // Upstream displays newest first, while replay proceeds from the oldest commit.
    var entries: [RebaseEntry] {
        if active || finished && !replayRows.isEmpty { return replayRows.reversed() }
        if plan?.disposition == .upToDate || plan?.disposition == .equal { return [] }
        return Array((plan?.entries ?? draftEntries).reversed())
    }
    func entryNumber(_ entry: RebaseEntry) -> Int {
        if active || finished && !replayRows.isEmpty { return (replayRows.firstIndex(where: { $0.id == entry.id }) ?? 0) + 1 }
        return ((plan?.entries ?? draftEntries).firstIndex(where: { $0.id == entry.id }) ?? 0) + 1
    }
    private func restoreSessionContext() {
        guard let context = state?.session else { return }
        completionFromLog = context.fromLog ?? false; completionAfterFetch = context.afterFetch; completionAutoStart = context.autoStart
        options.branch = context.branch; options.upstream = context.upstream; options.onto = context.onto
        options.force = context.force; options.preserveMerges = context.preserveMerges; ontoEnabled = !context.onto.isEmpty
        options.addCherryPickedFrom = context.addCherryPickedFrom ?? false
    }
    var completionActions: [RebaseCompletionAction] {
        guard finished, completedSuccessfully, !active, !isCherryPick, !completionFromLog else { return [] }
        return completionAfterFetch ? [.log, .push, .mail, .rebase] : [.log, .restart]
    }
    func canPerformCompletionAction(_ action: RebaseCompletionAction) -> Bool {
        guard !busy, !pickingCommits, !selectingSplit, revisionMenuAvailable,revisionMenuLog.window?.attachedSheet==nil, completionActions.contains(action) else { return false }
        switch action {
        case .log: return onCompletedLog != nil
        case .push: return onCompletedPush != nil
        case .mail: return onCompletedMail != nil && !options.upstream.isEmpty
        case .restart, .rebase: return true
        }
    }
    func performCompletionAction(_ action: RebaseCompletionAction) {
        guard canPerformCompletionAction(action) else { return }
        finishReplay { [weak self] in
            guard let self else { return }
            switch action {
            case .log: let callback = self.onCompletedLog; self.close(); callback?()
            case .push: let callback = self.onCompletedPush; self.close(); callback?("HEAD")
            case .mail:
                guard let preset = FormatPatchPreset(startRevision: self.options.upstream, endRevision: self.options.branch) else { return }
                let callback = self.onCompletedMail; self.close(); callback?(preset)
            case .restart: self.load(acceptedRepository:self.inheritedOperationRepository)
            case .rebase: self.load(upstream: self.options.upstream, autoStart: self.completionAutoStart, preserveMerges: self.options.preserveMerges,acceptedRepository:self.inheritedOperationRepository)
            }
        }
    }

    var canStart: Bool { editable && !loadingPlan && plan != nil && plan?.disposition != .upToDate && plan?.disposition != .equal && plan?.entries.first(where: { $0.action != .skip })?.action != .squash }
    var primaryActionTitle: String {
        if finished { return "Done" }
        if !active { return startTitle }
        if state?.emptyMessageWarning != nil { return "Continue" }
        if state?.squashMessage?.skipBaseHead != nil { return "Continue" }
        if state?.squashMessage != nil { return "Commit" }
        if state?.isEditPause == true { return "Amend" }
        if fileRecovery && supportsConflictSelection && state?.split == nil { return "Commit" }
        return "Continue"
    }
    var dockProgress: DockProgressState? {
        guard !retired, replaying || active || replayStopped else { return nil }
        let total = state?.total ?? 0
        let percentage = total > 0 ? min(100, max(0, (state?.currentStep ?? 0) * 100 / total)) : nil
        if !busy && (error != nil || !(state?.conflicts.isEmpty ?? true) || replayStopped) { return DockProgressState(.failed, percentage: percentage) }
        return DockProgressState(busy && !hasReplayQuestion && !confirmingReplayCancellation ? .running : .paused, percentage: percentage)
    }
    var status: String {
        if editingPendingActions { return "Saving replay actions…" }
        if replayStopped { return completion }
        if finished { return completion }
        if state?.emptyMessageWarning != nil { return "Review the empty commit message before continuing." }
        if state?.squashMessage?.skipBaseHead != nil { return "Continue retries the approved empty-group Skip." }
        if state?.squashMessage != nil { return "Edit the combined commit message, then Commit." }
        if active { return "Step \(state?.currentStep ?? 0) of \(state?.total ?? 0) • \(state?.conflicts.count ?? 0) unresolved paths" }
        if plan == nil { return "Choose valid branch and upstream revisions before starting." }
        switch plan?.disposition {
        case .equal: return "Branch and upstream are the same revision."
        case .upToDate: return "Branch is up to date. Enable Force Rebase to replay its commits."
        case .fastForward: return "The branch can fast-forward to upstream."
        default: return "\(plan?.entries.count ?? 0) commits in the \(operationTitle.lowercased()) plan"
        }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, messageDefaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.messageDefaults = messageDefaults
        revisionFiles=RevisionComparisonWindowModel(repository:repository,access:access,from:.emptyTree,to:.revision("HEAD"),preferences:messageDefaults,columnsKey:"RebaseDlg.RevisionFiles.Columns")
        conflictFileColumns=StatusListColumnSettings.load(from:messageDefaults,key:Self.conflictColumnKey)
        let saved=messageDefaults.string(forKey:Self.conflictColumnKey+".SortColumn").flatMap(StatusListColumn.init(rawValue:))
        let column=saved.flatMap { Self.conflictColumns.contains($0) ? $0:nil } ?? .path
        conflictSortOrder=[RebaseConflictSort(column:column,order:messageDefaults.bool(forKey:Self.conflictColumnKey+".SortDescending") ? .reverse:.forward)]
        readColumnMetadata = { try await repository.replayColumnMetadata($0,cancellation:$1) }
        prepareReplayMessage={try await repository.prepareCommitMessageFile($0,stripComments:$1,sanitize:$2,cancellation:$3).contents}
        validateOnto = { try await repository.rebaseOntoSelection($0, branch: $1, upstream: $2, cancellation: $3) }
        self.fullCommitMessageOnLogLine = messageDefaults.bool(forKey: "FullCommitMessageOnLogLine")
        revisionFiles.canStartFileDrag = { [weak self] in
            guard let self else{return false}
            return !self.fileRecovery && self.revisionFilesAvailable && !self.containingReferenceBlocked && !self.revisionFindBlocked &&
                self.pendingConfirmation == nil && self.confirmation == nil && !self.hasReplayQuestion && !self.confirmingReplayCancellation
        }
        revisionFilesObservation=revisionFiles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        revisionMenuObservation = revisionMenuLog.objectWillChange.sink { [weak self] _ in
            guard let self else { return }; self.controlMenuGeneration = UUID(); self.objectWillChange.send()
        }
        revisionBusyObservation = revisionMenuLog.$busy.dropFirst().removeDuplicates().sink { [weak self] busy in
            guard !busy else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.retired else { return }
                if self.revisionReferenceMutation { self.revisionReferenceMutation = false; self.refreshRevisionHistoryContext() }
                self.flushRevisionHistoryRefresh()
            }
        }
    }
    /// Choosing edits stay in the local draft. Paused action edits use a captured
    /// sequencer receipt, including recognized older or external sessions.
    var revisionContextPolicy: HistoryContextMenuPolicy {
        var policy = HistoryContextMenuPolicy.rebase
        if editable || canEditPendingActions { policy.commands.formUnion([.rebasePick, .rebaseSquash, .rebaseEdit, .rebaseSkip]) }
        return policy
    }
    func revisionActionChoices(_ ids: Set<String>) -> [RebaseAction] {
        let rows = revisionMenuRows(ids)
        guard editable || canEditPendingActions, !rows.isEmpty, rows.count == ids.count,
              rows.first?.progress == .pending else { return [] }
        return [RebaseAction.pick, .squash, .edit, .skip].filter { action in
            action != .squash || (!ids.contains(entries.last!.id) && (isCherryPick || rows[0].commit.parents.count == 1))
        }
    }
    /// Each popup owns one exact occurrence selection, phase and form generation.
    /// Option/selection away-and-back cannot revive it before AppKit redraws.
    func captureRevisionMenu(_ ids: Set<String>) -> (() -> Bool)? {
        guard revisionMenuAvailable, selection == ids, !ids.isEmpty,
              revisionMenuRows(ids).count == ids.count else { return nil }
        let context = formContext, policy = revisionContextPolicy, referenceNames = revisionReferenceNames.mapValues { $0.map { GitReferenceName($0) } }
        let rows = entries.map { [$0.id, $0.commit.hash, $0.action.rawValue, String(describing: $0.progress)] }
        var used = false
        return { [weak self] in
            guard let self, !used, self.revisionMenuAvailable, self.formContext == context,
                  self.selection == ids, self.revisionContextPolicy == policy, self.revisionReferenceNames.mapValues({ $0.map { GitReferenceName($0) } }) == referenceNames,
                  self.entries.map({ [$0.id, $0.commit.hash, $0.action.rawValue, String(describing: $0.progress)] }) == rows else { return false }
            used = true; return true
        }
    }
    var revisionMenuOwnerAvailable: Bool { !revisionHistoryBlocked && !loadingPlan && !revisionFindBlocked && confirmation == nil && pendingConfirmation == nil && !hasReplayQuestion && !confirmingReplayCancellation && pickingReference == nil && revisionMenuLog.window?.attachedSheet == nil && !revisionMenuLog.confirmingQuit && !retired && !busy && !revisionFiles.busy && !selectingSplit && !pickingCommits && revisionMenuLog.noteRequest == nil && !revisionMenuLog.busy && !revisionMenuLog.loadingNote && !revisionMenuLog.savingNote && !revisionMenuLog.copyingDetails }
    var revisionMenuAvailable: Bool { !containingReferenceBlocked && revisionMenuOwnerAvailable }
    func revisionMenuRows(_ ids: Set<String>) -> [RebaseEntry] { entries.filter { ids.contains($0.id) } }
    func revisionHistoryCommit(_ commit: LogEntry) -> LogEntry {
        var commit = commit
        commit.isHead = commit.hash == revisionHeadHash
        var seen = Set<GitReferenceName>()
        commit.references = (revisionReferenceNames[commit.hash] ?? []).compactMap { raw in
            let peeled = GitReferenceName.removingSuffix("^{}", from: raw)
            let name = peeled ?? raw
            guard seen.insert(GitReferenceName(name)).inserted else { return nil }
            return RevisionReference(name: name, isCurrent: GitReferenceName.equal(name, revisionCurrentReference), kind: peeled == nil ? HistoryReferenceLabel.shortName(name, terms: revisionBisectTerms).kind : .annotatedTag)
        }
        return commit
    }
    var revisionHistoryBlocked: Bool {
        revisionMenuLog.confirmingQuit || revisionMenuLog.busy || revisionMenuLog.unifiedViewerBusy || revisionMenuLog.jumping ||
            revisionMenuLog.copyingDetails || revisionMenuLog.loadingNote || revisionMenuLog.savingNote || revisionMenuLog.noteRequest != nil
    }
    func refreshRevisionHistoryContext() { pendingRevisionHistoryRefresh = true; flushRevisionHistoryRefresh() }
    func flushRevisionHistoryRefresh() {
        guard pendingRevisionHistoryRefresh, !retired, !busy, !loadingColumnMetadata,
              revisionMenuAvailable, revisionMenuLog.window?.attachedSheet == nil else { return }
        pendingRevisionHistoryRefresh = false; refreshColumnMetadata(force: true)
    }
    func revisionReference(_ target: LogReferenceMenuTarget?, ids: Set<String>) -> RevisionReference? {
        guard ids.count == 1, let target, let entry = revisionMenuRows(ids).first,
              entry.commit.hash == target.revisionHash else { return nil }
        return revisionHistoryCommit(entry.commit).references.first { GitReferenceName.equal($0.name, target.name) }
    }
    func revisionSwitchBranches(_ ids: Set<String>, target: LogReferenceMenuTarget?) -> [RevisionReference] {
        guard !revisionMenuLog.bare, ids.count == 1, let entry = revisionMenuRows(ids).first else { return [] }
        let references = target.map { _ in revisionReference(target, ids: ids).map { [$0] } ?? [] } ?? revisionHistoryCommit(entry.commit).references
        guard !revisionHistoryCommit(entry.commit).references.contains(where: { $0.name == "refs/stash" }) else { return [] }
        return references.filter { $0.name.hasPrefix("refs/heads/") && !$0.isCurrent }
    }
    func revisionDeletionCandidates(_ ids: Set<String>, target: LogReferenceMenuTarget?) -> [RevisionReference] {
        guard ids.count == 1, let entry = revisionMenuRows(ids).first else { return [] }
        let references = target.map { _ in revisionReference(target, ids: ids).map { [$0] } ?? [] } ?? revisionHistoryCommit(entry.commit).references
        return references.filter { !$0.isCurrent }
    }
    func performRevisionSwitch(_ target: LogReferenceMenuTarget, ids: Set<String>) {
        guard revisionSwitchBranches(ids, target: target).count == 1, let log = prepareRevisionMenu(ids) else { return }
        log.switchBranch(target: target)
    }
    func performRevisionDeletion(_ targets: [LogReferenceMenuTarget], ids: Set<String>) {
        guard !targets.isEmpty, targets.allSatisfy({ target in revisionDeletionCandidates(ids, target: target).count == 1 }),
              let log = prepareRevisionMenu(ids) else { return }
        revisionReferenceMutation = true; log.deleteReferences(targets)
    }
    func revisionBisectAvailable(_ command: LogBisectCommand, ids: Set<String>) -> Bool {
        let rows = revisionMenuRows(ids), source: HistoryContextCommand
        switch command { case .start: source = .bisectStart; case .good: source = .bisectGood; case .bad: source = .bisectBad; case .skip: source = .bisectSkip; case .reset: source = .bisectReset }
        guard revisionContextPolicy.contains(source), !revisionMenuLog.bare, !rows.isEmpty, rows.count == ids.count else { return false }
        let first = revisionHistoryCommit(rows[0].commit)
        if command == .start { return rows.count == 2 && !revisionMenuLog.bisectActive && !revisionMenuLog.mergeActive && !first.references.contains { $0.name == "refs/stash" } }
        return command != .reset && revisionMenuLog.bisectActive && !first.references.contains { $0.name.hasPrefix("refs/bisect/") } && (command == .skip || rows.count == 1)
    }
    func performRevisionBisect(_ command: LogBisectCommand, ids: Set<String>) {
        guard revisionBisectAvailable(command, ids: ids), let log = prepareRevisionMenu(ids) else { return }
        log.requestBisect(command)
    }
    @discardableResult func prepareRevisionMenu(_ ids: Set<String>) -> LogWindowModel? {
        let rows = revisionMenuRows(ids)
        guard revisionMenuAvailable, !rows.isEmpty, rows.count == ids.count else { return nil }
        revisionMenuLog.contextMenuPolicy = revisionContextPolicy
        revisionMenuLog.embeddedSelectionCount = ids.count
        revisionMenuLog.entries = rows.map { revisionHistoryCommit($0.commit) }
        revisionMenuLog.selected = Set(rows.map { $0.commit.hash })
        return revisionMenuLog
    }
    func revisionMenuRanges(_ ids: Set<String>) -> [HistoryRevisionRange] {
        let rows = revisionMenuRows(ids)
        guard ids.count == 2, rows.count == 2 else { return [] }
        return [HistoryRevisionRange(from: rows[1].commit.hash, to: rows[0].commit.hash),
                HistoryRevisionRange(from: rows[0].commit.hash, to: rows[1].commit.hash),
                HistoryRevisionRange(from: rows[1].commit.hash, to: rows[0].commit.hash, kind: .symmetricDifference)]
    }
    func performRevisionRange(_ range: HistoryRevisionRange, ids: Set<String>) {
        guard revisionMenuAvailable, revisionMenuRanges(ids).contains(range) else { return }
        revisionMenuLog.onShowHistoryRange?(range)
    }
    func revisionMenuPatchPreset(_ ids: Set<String>) -> FormatPatchPreset? {
        let indexes = entries.indices.filter { ids.contains(entries[$0].id) }
        guard !indexes.isEmpty, indexes.count == ids.count else { return nil }
        if indexes.count == 1 { return FormatPatchPreset(startRevision: entries[indexes[0]].commit.hash) }
        guard indexes.count <= 2 || indexes.last! - indexes.first! + 1 == indexes.count else { return nil }
        return FormatPatchPreset(startRevision: entries[indexes.last!].commit.hash + "~1", endRevision: entries[indexes.first!].commit.hash)
    }
    func revisionCommandVisible(_ command: RebaseRevisionCommand, ids: Set<String>, extended: Bool = false) -> Bool {
        let rows = revisionMenuRows(ids), one = rows.count == 1
        guard !rows.isEmpty, rows.count == ids.count else { return false }
        let commit = rows.first.map { revisionHistoryCommit($0.commit) }
        let stash = commit?.references.contains { $0.name == "refs/stash" } == true
        if command == .log { return one && revisionContextPolicy.showsLog(hasReferences: commit?.references.isEmpty == false, isStash: stash, extended: extended) }
        guard revisionContextPolicy.contains(command.sourceCommand(single: one)) else { return false }
        switch command {
        case .workingTree: return one && !revisionMenuLog.bare
        case .unified: return rows.count <= 2 && !revisionMenuLog.bare
        case .compare:
            let indexes = entries.indices.filter { ids.contains(entries[$0].id) }
            return rows.count <= 2 || indexes.last! - indexes.first! + 1 == indexes.count
        case .branch, .tag, .notes: return one && !stash
        case .browse, .export, .containing: return one
        case .patch: return !stash && revisionMenuPatchPreset(ids) != nil
        case .push, .svnDCommit:
            return one && ((!stash && commit?.references.contains { $0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/tags/") } == true) || extended) &&
                (command != .svnDCommit || hasGitSVN && !revisionMenuLog.bare)
        case .pull: return one && commit?.isHead == true && !revisionMenuLog.bare && !revisionMenuLog.mergeActive
        case .referenceNames: return one && commit?.references.isEmpty == false
        case .changeSets: return rows.count == 2
        default: return true
        }
    }
    func canPerformRevisionMenu(_ command: RebaseRevisionCommand, ids: Set<String>, extended: Bool = false) -> Bool {
        let rows = revisionMenuRows(ids), one = rows.count == 1
        guard revisionMenuAvailable, revisionCommandVisible(command, ids: ids, extended: extended) else { return false }
        switch command {
        case .workingTree: return one && !revisionMenuLog.bare && revisionMenuLog.onCompare != nil
        case .compare: return revisionMenuLog.onCompare != nil
        case .unified: return rows.count <= 2 && !revisionMenuLog.unifiedViewerBusy
        case .log: return one && onShowRevisionLog != nil
        case .browse: return one && revisionMenuLog.onBrowseRepository != nil
        case .branch, .tag, .push: return one
        case .notes: return one && revisionMenuLog.noteRequest == nil
        case .find: return onFindRevision != nil
        case .export: return one && revisionMenuLog.onExportRevision != nil
        case .containing: return one && revisionMenuLog.onShowContainingReferences != nil
        case .patch: return revisionMenuPatchPreset(ids) != nil && revisionMenuLog.onFormatPatch != nil
        case .changeSets: return rows.count == 2 && revisionMenuLog.onCommitChangeSets != nil
        case .pull: return revisionMenuLog.onHistoryPull != nil
        case .svnDCommit: return revisionMenuLog.onHistorySVNDCommit != nil
        default: return true
        }
    }
    func performRevisionMenu(_ command: RebaseRevisionCommand, ids: Set<String>, alternate: Bool = false, parent: Int? = nil, diffMode: LogRevisionDiffMode = .firstParent, target: LogReferenceMenuTarget? = nil) {
        guard canPerformRevisionMenu(command, ids: ids, extended: alternate), target == nil || revisionReference(target, ids: ids) != nil,
              let log = prepareRevisionMenu(ids) else { return }
        switch command {
        case .workingTree: ComparisonToolInvocation.$alternate.withValue(alternate) { log.compare(workingTree: true) }
        case .compare:
            let rows = revisionMenuRows(ids)
            ComparisonToolInvocation.$alternate.withValue(alternate) {
                if rows.count > 1 { log.onCompare?(.revision(rows.last!.commit.hash), .revision(rows[0].commit.hash)) }
                else { log.compare(parent: parent) }
            }
        case .unified: log.diff(alternate: alternate, mode: diffMode)
        case .log: if let revision = log.revision { onShowRevisionLog?(revision.hash) }
        case .browse: if let revision = log.revision { log.onBrowseRepository?(revision.hash) }
        case .branch:
            if let target { log.onCreateReference(false, target.name) }
            else { log.requestReference(.branch, target: nil) }
        case .tag: log.requestReference(.tag, target: nil)
        case .push: if let revision = log.revision { log.pushCaptured(revision, pointedName: target?.name) }
        case .find: onFindRevision?()
        case .export: log.requestExport()
        case .containing: if let hash = log.revision?.hash { log.onShowContainingReferences?(hash) }
        case .notes: log.editNotes()
        case .patch: if let preset = revisionMenuPatchPreset(ids) { log.onFormatPatch?(preset) }
        case .changeSets: log.compareChangeSets(alternate: alternate)
        case .pull: log.pullFromHistory()
        case .svnDCommit: log.svnDCommitFromHistory(extended: alternate)
        case .referenceNames: log.copyReferenceNames(target: target)
        case .details: log.copyDetails()
        case .detailsWithoutPaths: log.copyDetails(includePaths: false)
        case .hashes: log.copy(log.revisions.map(\.hash).joined(separator: "\n"))
        case .authors: log.copy(log.revisions.map { "\($0.author) <\($0.email)>" }.joined(separator: "\n"))
        case .authorNames: log.copy(log.revisions.map(\.author).joined(separator: "\n"))
        case .authorEmails: log.copy(log.revisions.map(\.email).joined(separator: "\n"))
        case .subjects: log.copy(log.revisions.map(\.subject).joined(separator: "\n"))
        case .messages: log.copy(log.revisions.map(\.message).joined(separator: "\n\n"))
        }
    }
    func refreshColumnMetadata(force: Bool = false) {
        guard !retired else { return }
        let commits = entries.map(\.commit), signature = Array(Set(entries.map { $0.commit.hash + "\0" + $0.commit.message })).sorted()
        guard force || signature != columnSignature else { return }
        columnSignature = signature; columnToken?.cancel()
        let request = UUID(), token = OperationCancellation(), read = readColumnMetadata
        columnGeneration = request; columnToken = token; loadingColumnMetadata = true; Self.activeColumnReads += 1;pendingBatchWorkers += 1
        Task { [self, access] in
            defer {
                Self.activeColumnReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}
                if self.columnToken === token { self.columnToken = nil; self.loadingColumnMetadata = false }
            }
            do {
                try self.requireAccess()
                let result = try await read(commits,token)
                // Reuse the source-style peeled hash/name map within this
                // existing owned read; menu actions never start a Git lookup.
                let names = try await self.repository.referenceLogReferenceNamesByHash(cancellation: token)
                let current = try await self.repository.run(["symbolic-ref", "--quiet", "HEAD"], successfulExitCodes: 0...1, cancellation: token).text.trimmingCharacters(in: .newlines)
                let head = try await self.repository.run(["rev-parse", "--verify", "HEAD"], successfulExitCodes: 0...1, cancellation: token).text.trimmingCharacters(in: .newlines)
                let metadata = try await self.repository.finderMetadata(cancellation: token)
                let referenceContext = try await self.repository.historyReferenceContext(cancellation: token)
                let bisectTerms = try await self.repository.historyBisectTerms(cancellation: token)
                guard !self.retired, self.columnGeneration == request, !token.isCancelled else { return }
                self.showsIssueColumn = result.showsIssueIDs; self.hasGitSVN = result.hasGitSVN
                self.controlMenuGeneration = UUID()
                self.issueColumnValues = result.issueIDs; self.svnColumnValues = result.svnRevisions
                self.revisionReferenceNames = names
                self.revisionCurrentReference = current; self.revisionHeadHash = head
                self.revisionMenuLog.installEmbeddedHistoryContext(metadata, currentBranch: GitReferenceName.removingPrefix("refs/heads/", from: current) ?? current, referenceContext: referenceContext, bisectTerms: bisectTerms)
                self.revisionBisectTerms = bisectTerms
                self.onRefreshRevisionFind()
            } catch {
                guard !self.retired, self.columnGeneration == request, !token.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func preparedRead<T>(_ token: OperationCancellation, _ read: () async throws -> T) async throws -> T {
        try token.check(); let value = try await read()
        if retired { token.cancel() }; try token.check(); return value
    }
    func load(upstream: String? = nil, autoStart: Bool = false, preserveMerges: Bool = false, cherryPick: [String]? = nil, force: Bool? = nil,acceptedRepository:GitRepository?=nil) {
        guard !retired else { return }
        if pendingConfirmation != nil {
            if upstream != nil || cherryPick != nil || force != nil || acceptedRepository != nil {pendingLoad=(upstream,autoStart,preserveMerges,cherryPick,force,acceptedRepository)}
            return
        }
        if hasReplayStash && !active && !busy {
            finishReplay { [weak self] in self?.load(upstream: upstream, autoStart: autoStart, preserveMerges: preserveMerges, cherryPick: cherryPick, force: force,acceptedRepository:acceptedRepository) }
            return
        }
        guard !busy, !revisionFiles.busy, pickingReference == nil, !pickingCommits, !selectingSplit else {
            if upstream != nil || cherryPick != nil || force != nil || acceptedRepository != nil { pendingLoad = (upstream, autoStart, preserveMerges, cherryPick, force,acceptedRepository) }
            return
        }; planCancellation?.cancel(); detailCancellation?.cancel(); planSignature = nil
        inheritedOperationRepository=acceptedRepository
        let repository=self.operationRepository()
        let token = OperationCancellation(); initialCancellation = token; cancellingPreparation = false; Self.activePreparationReads += 1;pendingBatchWorkers += 1
        busy = true; planGeneration += 1; detailGeneration += 1
        Task {
            var started = false
            defer { Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}; if initialCancellation === token { initialCancellation = nil; cancellingPreparation = false }; if !started && !retired { busy = false; refreshColumnMetadata(force:true); onRefreshRevisionFind(); loadPendingHandoff() } }
            do {
                try requireAccess()
                projectSettings = try await preparedRead(token) { try await repository.projectDialogSettings(source: .effective, cancellation: token) }
                issueProperties = try await preparedRead(token) { try await repository.issueTrackerProperties(cancellation: token) }
                revisionMenuLog.bare = try await preparedRead(token) { try await repository.isBare(cancellation: token) }
                references = try await preparedRead(token) { try await repository.checkoutReferences(includeFetchHead:true,cancellation:token) }
                let session=try await preparedRead(token) {try await readSessionValue(conflictIdentity,token,repository:repository)}
                applyConflictSnapshot(session);finished=false;completedSuccessfully=false;output="";error=nil;confirmation=nil;draftEntries=[]
                if fileRecovery {tab=0}
                if active { splitCommit = state?.split != nil && state?.split?.conflictRecovery != true; options.isCherryPick = state?.isCherryPick == true; onModeChanged(); options.branch = state?.branch ?? "HEAD"; options.upstream = state?.onto ?? ""; restoreSessionContext(); plan = nil; recovered=session.remaining;replayRows=session.replay; selection = Set(recovered.first.map { [$0.id] } ?? []); if state?.squashMessage != nil || state?.isEditPause == true { tab = 1 }; selectCommit(); return }
                finished = false; plan = nil; recovered = []; replayRows = []; selection = []; files = []; message = ""; options = RebaseOptions(); options.preserveMerges = preserveMerges; options.force = force ?? false; ontoEnabled = false
                if let cherryPick {
                    plan = try await preparedRead(token) { try await repository.cherryPickPlan(revisions: cherryPick, cancellation: token) }
                    options = plan!.options
                    options.addCherryPickedFrom = messageDefaults.bool(forKey: "CherrypickAddCherryPickedFrom")
                    updateAttribution()
                    options.squashDate = RebaseSquashDate(rawValue: messageDefaults.integer(forKey: "SquashDate")) ?? .first
                    plan?.options.squashDate = options.squashDate
                    onModeChanged(); selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit(); return
                }
                onModeChanged()
                options.squashDate = RebaseSquashDate(rawValue: messageDefaults.integer(forKey: "SquashDate")) ?? .first
                let branch = try await preparedRead(token) { try await repository.branch(cancellation: token) }; options.branch = branch.isEmpty ? "HEAD" : "refs/heads/" + branch
                let defaults = try await preparedRead(token) { try await repository.pullDefaults(cancellation: token) }
                options.upstream = upstream ?? (defaults.trackedRemote.isEmpty || defaults.trackedBranch.isEmpty ? "" : "refs/remotes/" + defaults.trackedRemote + "/" + defaults.trackedBranch)
                if !options.upstream.isEmpty {
                    let value=try await preparedRead(token) {try await readPlanValue(options,token,repository:repository)}
                    let summaries=try await readReferenceTooltips(value,repository:repository,cancellation:token)
                    guard !retired,!token.isCancelled else{return}
                    plan=value;referenceTooltips=summaries;selection=Set(entries.first.map {[$0.id]} ?? []);selectCommit()
                }
                busy = false
                if autoStart && canStart { started = true; execute("start") }
            } catch { if !retired, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func reloadPlan(force: Bool = false) {
        guard editable, !isCherryPick else { return }
        var snapshot = options; if !ontoEnabled { snapshot.onto = "" }
        let repository=self.operationRepository()
        let backend=repository.libgit2Configuration
        let signature = Data([snapshot.branch, snapshot.upstream, snapshot.onto, String(snapshot.force), String(snapshot.preserveMerges), String(snapshot.squashDate.rawValue),String(backend?.enabled ?? true),String(backend?.mask ?? GitLibGit2Configuration.defaultMask),backend?.helperURL?.path ?? "",(try? repository.singleCommitBackendIdentity()) ?? "single-commit-unavailable"].joined(separator: "\0").utf8)
        if !force, planCancellation?.isCancelled != true, planSignature == signature, loadingPlan || plan != nil { return }
        planCancellation?.cancel(); detailCancellation?.cancel(); planGeneration += 1; detailGeneration += 1
        let request = planGeneration, token = OperationCancellation(); planCancellation = token; planSignature = signature
        plan = nil; draftEntries = []; selection = []; files = []; message = ""
        guard !snapshot.branch.isEmpty, !snapshot.upstream.isEmpty else { planCancellation = nil; loadingPlan = false; return }
        loadingPlan = true; cancellingPreparation = false; Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task {
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}
                if planCancellation === token { planCancellation = nil; loadingPlan = false; cancellingPreparation = false }
            }
            do {
                try requireAccess(); let value = try await readPlanValue(snapshot, token,repository:repository)
                let summaries=try await readReferenceTooltips(value,repository:repository,cancellation:token)
                guard !retired, request == planGeneration, planCancellation === token, !token.isCancelled, editable else { return }
                plan = value;referenceTooltips=summaries; selection = Set(entries.first.map { [$0.id] } ?? []); selectCommit(); onRefreshRevisionFind()
            } catch RebaseFailure.revision { /* Incomplete or unavailable reference: keep Start unavailable. */ }
            catch { if !retired, request == planGeneration, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func referenceTooltip(branch:Bool)->String {
        let name=branch ? options.branch:options.upstream
        guard let plan,GitReferenceName.equal(plan.options.branch,options.branch),GitReferenceName.equal(plan.options.upstream,options.upstream) else{return name}
        return referenceTooltips[branch ? plan.branchHash:plan.upstreamHash] ?? name
    }
    private func readReferenceTooltips(_ plan:RebasePlan,repository:GitRepository,cancellation:OperationCancellation) async throws -> [String:String] {
        var result:[String:String]=[:]
        let dates=HistoryDateSettings(shortDate:false,relative:false,useSystemLocale:HistoryDateSettings.load(defaults:messageDefaults).useSystemLocale)
        for hash in [plan.branchHash,plan.upstreamHash] where result[hash]==nil {
            try cancellation.check()
            do {
                let commit=try await repository.singleCommitDetails(revision:hash,cancellation:cancellation).asLogEntry()
                try cancellation.check()
                let text="Revision: "+commit.hash+"\nAuthor: "+commit.author+" <"+commit.email+">\nDate: "+dates.format(commit.date,absolute:true)+"\nMessage:\n"+commit.message
                var units=Array(text.utf16.prefix(8000))
                if let last=units.last,(0xD800...0xDBFF).contains(last) {units.removeLast()}
                result[hash]=String(decoding:units,as:UTF16.self)
            } catch {try cancellation.check();result[hash]="Revision: "+hash+"\nMetadata unavailable: "+error.localizedDescription}
        }
        return result
    }
    var canUseBulkActions:Bool {editable && !loadingPlan && revisionMenuAvailable && revisionMenuLog.window?.attachedSheet==nil}
    func chooseBulkAction(_ action:RebaseBulkAction) {
        guard canUseBulkActions else{return}
        bulkAction=action
        var values=plan?.entries ?? draftEntries
        for index in values.indices {
            if action.unselected && selection.contains(values[index].id) {continue}
            if action.action == .squash {
                if index==0 || (!isCherryPick && values[index].commit.parents.count != 1) {continue}
            }
            values[index].action=action.action
        }
        if plan != nil {plan?.entries=values} else {draftEntries=values}
    }
    func captureBulkAction()->((String)->Void)? {
        guard canUseBulkActions else{return nil}
        let generation=planGeneration,epoch=controlMenuGeneration,selected=selection,rows=entries.map {[$0.id,$0.action.rawValue]}
        let branch=options.branch,upstream=options.upstream,onto=options.onto,force=options.force,preserve=options.preserveMerges
        var consumed=false
        return { [weak self] raw in
            guard let self,!consumed,self.canUseBulkActions,self.controlMenuGeneration==epoch,self.planGeneration==generation,self.selection==selected,
                  self.entries.map({[$0.id,$0.action.rawValue]})==rows,
                  GitReferenceName.equal(self.options.branch,branch),GitReferenceName.equal(self.options.upstream,upstream),GitReferenceName.equal(self.options.onto,onto),self.options.force==force,self.options.preserveMerges==preserve,
                  let action=RebaseBulkAction(rawValue:raw) else{return}
            consumed=true;self.chooseBulkAction(action)
        }
    }
    func captureCompletionAction()->((String)->Void)? {
        guard !completionActions.isEmpty else{return nil}
        let generation=planGeneration,epoch=controlMenuGeneration,actions=completionActions,branch=options.branch,upstream=options.upstream
        var consumed=false
        return { [weak self] raw in
            guard let self,!consumed,self.controlMenuGeneration==epoch,self.planGeneration==generation,self.completionActions==actions,
                  GitReferenceName.equal(self.options.branch,branch),GitReferenceName.equal(self.options.upstream,upstream),
                  let action=RebaseCompletionAction(rawValue:raw),self.canPerformCompletionAction(action) else{return}
            consumed=true;self.completionAction=action;self.performCompletionAction(action)
        }
    }
    private func requireAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func updateAttribution() {
        guard isCherryPick, var value = plan, !active else { return }
        value.options.addCherryPickedFrom = options.addCherryPickedFrom
        plan = value
        messageDefaults.set(options.addCherryPickedFrom, forKey: "CherrypickAddCherryPickedFrom")
    }
    private func prepareCherryPick() {
        guard canStart, var snapshot = plan else { return }
        let repository=self.operationRepository()
        let token = OperationCancellation(), generation = planGeneration
        mainlineCancellation = token; preparingMainline = true; cancellingPreparation = false; busy = true; error = nil
        Self.activePreparationReads += 1;pendingBatchWorkers += 1
        let controls = controlMenuGeneration
        Task {
            var start = false
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}
                if mainlineCancellation === token {
                    mainlineCancellation = nil; preparingMainline = false; cancellingPreparation = false
                    if !retired { busy = false; if start { execute("start") } else { loadPendingHandoff() } }
                }
            }
            do {
                try requireAccess(); try token.check()
                for index in snapshot.entries.indices where snapshot.entries[index].action != .skip && snapshot.entries[index].commit.parents.count > 1 {
                    let commit = snapshot.entries[index].commit
                    let choices = try await preparedRead(token) { try await readMainlineChoicesValue(commit, token,repository:repository) }
                    guard generation == planGeneration, controls == controlMenuGeneration else { return }
                    guard let parent = await chooseMainline(commit, choices) else { return }
                    try token.check()
                    guard !retired, generation == planGeneration, controls == controlMenuGeneration, mainlineCancellation === token else { return }
                    guard choices.contains(where: { $0.number == parent }) else { throw RebaseFailure.plan }
                    snapshot.entries[index].mainline = parent
                }
                try token.check()
                guard !retired, generation == planGeneration, controls == controlMenuGeneration, mainlineCancellation === token else { return }
                plan = snapshot; start = true
            } catch { if !retired, !token.isCancelled, generation == planGeneration, controls == controlMenuGeneration, mainlineCancellation === token { self.error = error.localizedDescription } }
        }
    }
    private var additionalSelection: (id: UUID, generation: Int, controls: UUID)?
    func beginAdditionalSelection() -> UUID? {
        guard canAdd else { return nil }
        let id = UUID(); additionalSelection = (id, planGeneration, controlMenuGeneration); pickingCommits = true
        return id
    }
    func finishAdditionalSelection(_ request: UUID, revisions: [String]?) {
        guard let pending = additionalSelection, pending.id == request else { return }
        additionalSelection = nil; pickingCommits = false
        guard !retired, pending.generation == planGeneration, pending.controls == controlMenuGeneration else { if !retired { loadPendingHandoff() }; return }
        finishPickingCommits(revisions)
    }
    func finishPickingCommits(_ revisions: [String]?) {
        guard !retired else { return }
        pickingCommits = false
        if let revisions, !revisions.isEmpty { addCommits(revisions) }
        else { loadPendingHandoff() }
    }
    func addCommits(_ revisions: [String]) {
        guard canAdd, !revisions.isEmpty else { return }
        let repository=self.operationRepository()
        let snapshot = plan, draft = draftEntries
        var settings = options; if !ontoEnabled { settings.onto = "" }
        planCancellation?.cancel(); detailCancellation?.cancel(); busy = true; planGeneration += 1; detailGeneration += 1
        let generation = planGeneration, token = OperationCancellation()
        insertionCancellation = token; addingCommits = true; cancellingPreparation = false; error = nil
        // Column metadata refreshes only change presentation. Fence the accepted
        // insertion against actual replay inputs and row identities instead.
        let intent = insertionIntent
        Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task {
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}
                if insertionCancellation === token {
                    insertionCancellation = nil; addingCommits = false; cancellingPreparation = false
                    if !retired { busy = false; loadPendingHandoff() }
                }
            }
            do {
                try requireAccess(); try token.check()
                let added: [RebaseEntry], updated: RebasePlan?
                if let snapshot {
                    let value = try await preparedRead(token) { try await readAddedPlanValue(snapshot, revisions, token,repository:repository) }
                    updated = value; added = value.entries
                } else {
                    let draftResult = try await preparedRead(token) { try await readAddedEntriesValue(draft, revisions, token,repository:repository) }
                    var captured: RebasePlan?
                    do { captured = try await preparedRead(token) { try await readPlanValue(settings, token,repository:repository) } }
                    catch RebaseFailure.revision { try token.check() /* Incomplete references keep the editable draft. */ }
                    if let captured {
                        let value = try await preparedRead(token) { try await readAddedPlanValue(captured, draftResult.reversed().map { $0.commit.hash }, token,repository:repository) }
                        updated = value; added = value.entries
                    } else { updated = nil; added = draftResult }
                }
                try token.check()
                guard !retired, generation == planGeneration, intent == insertionIntent, insertionCancellation === token else { return }
                plan = updated; draftEntries = updated == nil ? added : []
                selection = Set(added.suffix(revisions.count).map(\.id)); selectCommit()
            } catch { if !retired, !token.isCancelled, generation == planGeneration, intent == insertionIntent, insertionCancellation === token { self.error = error.localizedDescription } }
        }
    }
    func setAction(_ action: RebaseAction, ids: Set<String>? = nil) {
        if active { changePendingActions(action, ids: ids ?? selection); return }
        guard !retired, editable else { return }
        var values = plan?.entries ?? draftEntries
        let targets = ids ?? selection
        for index in values.indices where targets.contains(values[index].id) && values[index].progress == .pending {
            if action == .squash && (index==0 || !isCherryPick && values[index].commit.parents.count > 1) {continue}
            values[index].action = action
        }
        if plan != nil { plan?.entries = values } else { draftEntries = values }
    }
    var canEditPendingActions: Bool {
        active && state?.cleanCommitFailure == nil && state?.hasIgnoredCleanCommitFailure != true && !finished && !retired && !busy && revisionMenuAvailable && editorExecutable != nil &&
        (state?.isEditPause == true || fileRecovery || state?.squashMessage != nil)
    }
    private func changePendingActions(_ action: RebaseAction, ids: Set<String>, changes: [String: RebaseAction] = [:]) {
        guard canEditPendingActions, let captured = state, let editorExecutable,
              !revisionActionChoices(ids).isEmpty, let head = conflictHead.isEmpty ? nil : conflictHead else { return }
        let recovery = conflictIdentity
        let repository=self.operationRepository()
        let original = replayRows.map { [$0.id, $0.action.rawValue, String(describing: $0.progress)] }
        let token = OperationCancellation()
        actionEditCancellation = token; editingPendingActions = true; busy = true; cancellingPreparation = false
        let generation = formContext
        Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task {
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}
                if actionEditCancellation === token {
                    actionEditCancellation = nil; editingPendingActions = false; cancellingPreparation = false
                    if !retired { busy = false; loadPendingHandoff() }
                }
            }
            do {
                try requireAccess()
                let expected:RebaseActionEditSnapshot
                if let readActionEditSnapshot {expected=try await readActionEditSnapshot(token)}
                else {expected=try await repository.rebaseActionEditSnapshot(cancellation:token)}
                try token.check()
                guard !retired, formContext == generation, RebaseConflictIdentity(expected.state) == RebaseConflictIdentity(captured),
                      expected.head == head, expected.state.remainingCommands == captured.remainingCommands,
                      expected.replay.map({ [$0.id, $0.action.rawValue, String(describing: $0.progress)] }) == original else { throw RebaseFailure.changed }
                var mainlines: [String: Int] = [:]
                if captured.isCherryPick {
                    for row in expected.replay where ids.contains(row.id) && row.progress == .pending && row.commit.parents.count > 1 && row.mainline == nil && (changes[row.id] ?? action) != .skip {
                        let choices = try await readMainlineChoicesValue(row.commit, token,repository:repository)
                        guard !retired, !token.isCancelled, formContext == generation else { return }
                        guard let parent = await chooseMainline(row.commit, choices) else { return }
                        try token.check(); mainlines[row.id] = parent
                    }
                }
                guard !retired, formContext == generation else { return }
                let snapshot:RebaseSessionSnapshot
                if let writePendingActions {snapshot=try await writePendingActions(action,ids,changes,mainlines,expected,editorExecutable,recovery,token)}
                else {snapshot=try await repository.changePendingRebaseActions(action,ids:ids,expected:expected,changes:changes,mainlines:mainlines,editorExecutable:editorExecutable,retaining:recovery,cancellation:token)}
                // Publication is a critical section. If Cancel arrives after its
                // commit point, display the actual saved result rather than a
                // false unchanged draft. Retirement still fences publication.
                guard !retired else { return }
                applyConflictSnapshot(snapshot); recovered = snapshot.remaining; replayRows = snapshot.replay
                onChanged()
            } catch {
                if !retired, !token.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    struct RowDrag { let owner: UUID; let generation: Int; let rows: ReplayRowDrag }
    private let rowDragOwner = UUID()
    var canDragRows: Bool { !retired && editable && revisionMenuAvailable && revisionMenuLog.window?.attachedSheet == nil }
    func beginRowDrag(_ ids: Set<String>) -> RowDrag? {
        guard canDragRows, let rows = ReplayRowDrag(visible:entries,selected:ids) else { return nil }
        selection = ids
        return RowDrag(owner:rowDragOwner,generation:planGeneration,rows:rows)
    }
    func canDropRows(_ drag: RowDrag, before destination: Int) -> Bool {
        canDragRows && drag.owner == rowDragOwner && drag.generation == planGeneration && drag.rows.canDrop(visible:entries,before:destination)
    }
    @discardableResult func dropRows(_ drag: RowDrag, before destination: Int) -> Bool {
        guard canDropRows(drag,before:destination), let values = drag.rows.reordered(visible:entries,before:destination) else { return false }
        if plan != nil { plan?.entries = Array(values.reversed()) } else { draftEntries = Array(values.reversed()) }
        selection = drag.rows.selected; selectCommit(); return true
    }
    func canMove(up: Bool, toEnd: Bool = false) -> Bool {
        guard !retired, editable else { return false }
        let visible = entries
        let indexes = visible.indices.filter { selection.contains(visible[$0].id) }
        guard let first = indexes.first, let last = indexes.last else { return false }
        if toEnd { return up ? indexes != Array(0..<indexes.count) : indexes != Array((visible.count - indexes.count)..<visible.count) }
        return up ? first > 0 : last < visible.count - 1
    }
    func move(up: Bool, toEnd: Bool = false) {
        guard canMove(up: up, toEnd: toEnd) else { return }
        var visible = entries
        if toEnd {
            let selected = visible.filter { selection.contains($0.id) }, others = visible.filter { !selection.contains($0.id) }
            visible = up ? selected + others : others + selected
        } else {
            let indexes = visible.indices.filter { selection.contains(visible[$0].id) }
            for index in up ? indexes : Array(indexes.reversed()) { visible.swapAt(index, index + (up ? -1 : 1)) }
        }
        if plan != nil { plan?.entries = Array(visible.reversed()) } else { draftEntries = Array(visible.reversed()) }
    }
    func cycleActions() {
        if active {
            let pending = entries.filter { selection.contains($0.id) && $0.progress == .pending }
            guard !pending.isEmpty else { return }
            let changes = Dictionary(uniqueKeysWithValues: pending.map { row -> (String, RebaseAction) in
                let next: RebaseAction = row.action == .pick ? .skip : row.action == .skip ? .edit : row.action == .edit ? (isCherryPick || row.commit.parents.count == 1 ? .squash : .pick) : .pick
                return (row.id, next)
            })
            changePendingActions(.pick, ids: selection, changes: changes); return
        }
        guard !retired, editable else { return }
        var values = plan?.entries ?? draftEntries
        for index in values.indices where selection.contains(values[index].id) {
            if options.preserveMerges {
                switch values[index].action {
                case .pick: values[index].action = .skip
                case .skip: values[index].action = .edit
                case .edit: values[index].action = values[index].commit.parents.count == 1 ? .squash : .pick
                case .squash: values[index].action = .pick
                }
                continue
            }
            switch values[index].action {
            case .pick: values[index].action = .skip
            case .skip: values[index].action = .edit
            case .edit: values[index].action = index == 0 && (isCherryPick || values[index].commit.parents.count == 1) ? .pick : .squash
            case .squash: values[index].action = .pick
            }
        }
        if plan != nil { plan?.entries = values } else { draftEntries = values }
    }
    func selectCommit() {
        let repository=self.operationRepository()
        guard !retired else { return }; detailCancellation?.cancel()
        if !busy { refreshColumnMetadata() }
        detailGeneration += 1; let request = detailGeneration
        files = []; selectedFiles=[]; message = "";revisionFiles.clearEmbeddedSnapshot()
        guard let entry = entries.first(where: { selection.contains($0.id) }), !fileRecovery else { return }
        message = entry.commit.message
        let token = OperationCancellation(); detailCancellation = token; Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task {
            defer { Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}; if detailCancellation === token { detailCancellation = nil } }
            do {
                try requireAccess()
                let base:ComparisonRevision=entry.commit.parents.first.map(ComparisonRevision.revision) ?? .emptyTree
                let changed=try await repository.revisionComparison(from:base,to:.revision(entry.commit.hash),cancellation:token)
                guard !retired,!token.isCancelled,request == detailGeneration else {return}
                files=changed.files;revisionFiles.installEmbeddedSnapshot(changed,bare:revisionMenuLog.bare)
            }
            catch { if !retired, !token.isCancelled, request == detailGeneration { self.error = error.localizedDescription } }
        }
    }
    /// Source Refresh changes conflicts only during conflict recovery, and both
    /// branch choices and the pending plan during ordinary branch selection.
    // fileRecovery can remain true for an accepted occurrence even after an
    // Edit/Split/message phase change. Source F5 is limited to actual conflict
    // recovery, not every phase that owns a recovery-shaped file list.
    var sourceRefreshesConflicts:Bool {active && fileRecovery && state?.needsFileRecovery==true}
    var canRefreshDialog:Bool {
        !retired && !revisionMenuLog.confirmingQuit && !containingReferenceBlocked && !revisionFindBlocked && !revisionHistoryBlocked &&
        confirmation==nil && pendingConfirmation==nil && !hasReplayQuestion && !confirmingReplayCancellation &&
        pickingReference==nil && !pickingCommits && !selectingSplit && !revisionFiles.busy &&
        revisionMenuLog.window?.attachedSheet==nil && NSApp.modalWindow==nil &&
        (!busy || refreshingReferences) && (sourceRefreshesConflicts || !active && !finished && !isCherryPick)
    }
    func refreshFromSourceCommand() {
        guard canRefreshDialog else{return}
        if sourceRefreshesConflicts {refreshState();return}
        referenceRefreshCancellation?.cancel();planCancellation?.cancel();detailCancellation?.cancel()
        planGeneration += 1;detailGeneration += 1;loadingPlan=false;planSignature=nil
        let token=OperationCancellation(),request=UUID(),originalIntent=referenceIntent
        var snapshot=options;if !ontoEnabled {snapshot.onto=""}
        let repository=self.operationRepository()
        referenceRefreshCancellation=token;referenceRefreshGeneration=request;refreshingReferences=true;busy=true;cancellingPreparation=false;error=nil
        Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task { [self,access] in
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1;withExtendedLifetime(access) {}
                if referenceRefreshCancellation === token {
                    referenceRefreshCancellation=nil;refreshingReferences=false;cancellingPreparation=false
                    if !retired {busy=false;refreshColumnMetadata(force:true);onRefreshRevisionFind();loadPendingHandoff()}
                }
            }
            do {
                try requireAccess()
                let catalog:[CheckoutReference]
                if let readRefreshReferences {catalog=try await readRefreshReferences(token)}
                else {catalog=try await repository.checkoutReferences(includeFetchHead:true,cancellation:token)}
                try token.check()
                let current=try await repository.run(["-c","core.precomposeunicode=false","symbolic-ref","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:token)
                if current.exitCode==0 {snapshot.branch=current.text.trimmingCharacters(in:.newlines)}
                else {snapshot.branch=try await repository.run(["rev-parse","--verify","HEAD"],cancellation:token).text.trimmingCharacters(in:.newlines)}
                if snapshot.upstream.isEmpty {
                    let defaults=try await repository.pullDefaults(cancellation:token)
                    let tracked="refs/remotes/"+defaults.trackedRemote+"/"+defaults.trackedBranch
                    if !defaults.trackedRemote.isEmpty,!defaults.trackedBranch.isEmpty,catalog.contains(where:{GitReferenceName.equal($0.name,tracked)}) {snapshot.upstream=tracked}
                }
                var refreshed:RebasePlan?
                if !snapshot.branch.isEmpty && !snapshot.upstream.isEmpty {
                    do {refreshed=try await readPlanValue(snapshot,token,repository:repository)}
                    catch RebaseFailure.revision { /* Keep editable unknown references and disable Start. */ }
                }
                // LoadBranchInfo selects current HEAD; FetchLogList rebuilds
                // source order and default Pick/patch-equivalent Skip actions.
                // User Add/order/action edits belong to the old plan, not refs.
                let tooltips:[String:String]
                if let refreshed {tooltips=try await readReferenceTooltips(refreshed,repository:repository,cancellation:token)} else {tooltips=[:]}
                try token.check()
                guard !retired,referenceRefreshCancellation === token,referenceRefreshGeneration==request,
                      !revisionMenuLog.confirmingQuit,revisionMenuLog.window?.attachedSheet==nil,NSApp.modalWindow==nil,
                      referenceIntent==originalIntent else{return}
                references=catalog;options=snapshot;plan=refreshed;referenceTooltips=tooltips;draftEntries=[]
                selection=Set(entries.first.map{[$0.id]} ?? []);selectCommit()
            } catch {if !retired,referenceRefreshCancellation === token,!token.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func refreshState() {
        guard !retired,pickingReference == nil,!selectingSplit,!pickingCommits else {return}
        if busy || revisionFiles.busy || pendingConfirmation != nil {pendingSessionRefresh=true;return}
        let request=UUID(),token=OperationCancellation(),previous=conflictIdentity,wasActive=active
        sessionGeneration=request;sessionCancellation=token;refreshingSession=true;cancellingPreparation=false;busy=true
        Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task {
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1;withExtendedLifetime(access) {}
                if sessionCancellation === token {sessionCancellation=nil;refreshingSession=false;cancellingPreparation=false;if !retired {busy=false;loadPendingHandoff()}}
            }
            do {
                try requireAccess();let snapshot=try await readSessionValue(previous,token)
                guard !retired,!token.isCancelled,sessionGeneration == request else {return}
                applyConflictSnapshot(snapshot);conflictPatch=nil;onModeChanged()
                if active {
                    restoreSessionContext();recovered=snapshot.remaining;replayRows=snapshot.replay
                    if state?.squashMessage != nil || state?.isEditPause == true {tab=1}
                    selectCommit()
                } else if wasActive {finished=true;completedSuccessfully=false;completion="\(operationTitle) session ended";recovered=[];replayRows=[];selection=[];files=[];message=""}
                onChanged()
            } catch {if !retired,!token.isCancelled,sessionGeneration == request {self.error=error.localizedDescription}}
        }
    }
    func request(_ action: String) {
        guard canRequest(action) else{return}
        if action == "continue", state?.cleanCommitFailure != nil || state?.hasIgnoredCleanCommitFailure == true { execute(action);return }
        if action == "continue",state?.emptyMessageWarning != nil {execute(action);return}
        if action == "continue", splitCommit || state?.split != nil && state?.split?.conflictRecovery != true { beginSplitSelection(); return }
        if action == "continue", state?.split?.conflictRecovery == true { resumeConflictSelection(); return }
        if action == "continue", state?.isEditPause == true, state?.squashMessage == nil, state?.split == nil {
            prepareEditMessageContinuation(); return
        }
        if action == "start", isCherryPick { prepareCherryPick(); return }
        let message:String
        if action == "start" {message="Start rewriting the selected branch using this commit plan?"}
        else if action == "abort" {message="Abort this \(operationTitle.lowercased()) and restore its original branch? Current conflict-resolution edits will be discarded."}
        else if action == "skip" {message="Skip the current commit? Its changes and current conflict-resolution edits will be discarded."}
        else {execute(action);return}
        let question=ActionConfirmation(action:action,message:message,context:formContext,intent:replayIntent)
        pendingConfirmation=question;confirmation=message
    }
    func execute(_ action: String,repository captured:GitRepository?=nil) {
        guard !containingReferenceBlocked, !revisionFindBlocked, !revisionHistoryBlocked, !retired, pendingConfirmation == nil, confirmation == nil, !busy, !revisionFiles.busy, pickingReference == nil, !pickingCommits, !selectingSplit, action != "start" || canStart else { return }
        let snapshot = plan, draftMessage = amendMessage, previouslyFinished = finished, replayEditor = editorExecutable
        let continuationState=state,continuationPaths=checkedConflicts,continuationHead=conflictHead
        let continuationRecovery=fileRecovery,usesCheckedSelection=supportsConflictSelection
        let stripComments=messageDefaults.bool(forKey:"StripCommentedLines")
        let sanitizeMessage=messageDefaults.object(forKey:"SanitizeCommitMsg") as? Bool ?? true
        let suppressConflictHints=messageDefaults.bool(forKey:"CommitMessageContainsConflictHint")
        if action=="start" {automaticallySkipFailedPicks=false;failedPickSkipSession=nil}
        failedPickRecoveryCancelled=false; cleanCommitReturnedToEditor=false
        busy = true; tab = 2
        let repository=captured ?? self.operationRepository()
        let preparation = OperationCancellation(); replayPreparationCancellation = preparation; replaying = true; cancellingReplay = false; replayStopped = false
        Self.beginReplayWork();pendingBatchWorkers += 1; LocalGitCommandProgress.begin()
        Task {
            var followRecovery = false, followEmpty = false, finishingReplay = false
            var skippedID = action == "skip" ? state?.stoppedEntryID : nil
            defer { Self.endReplayWork();pendingBatchWorkers -= 1; LocalGitCommandProgress.end(); withExtendedLifetime(access) {}; if replayPreparationCancellation === preparation { replayPreparationCancellation = nil; replaying = false; cancellingReplay = false }; if !finishingReplay { busy = false }; if !retired && !preparation.isCancelled { if followEmpty { execute("continue") } else if followRecovery { resumeConflictSelection(afterCommit: true) } else { loadPendingHandoff() } } }
            do {
                try requireAccess()
                let prefix = output
                let result = try await LocalGitCommandProgress.stream(preferences: messageDefaults, update: { [weak self] progress in
                    guard let self, !self.retired, self.replayPreparationCancellation === preparation else { return }; self.output = LocalGitCommandProgress.bounded(prefix + progress.output, preferences: self.messageDefaults)
                }, resultText: { $0.output }) { [self] emit in
                    let result: RebaseExecution
                do {
                try preparation.check()
                switch action {
                case "start": guard let snapshot, let executable = replayEditor else { throw RebaseFailure.plan }
                    let condition = try await repository.replayStashCondition(cherryPick: snapshot.options.isCherryPick, cancellation: preparation)
                    if condition.dirty {
                        let accepted = condition.automatic ? true : await chooseStashBeforeReplay()
                        guard !retired, accepted else { throw OperationCancellationFailure.cancelled }
                        try preparation.check()
                        let saved = try await repository.saveStash(StashSaveOptions(), onOutput: emit)
                        if saved.created { hasReplayStash = true }
                        try preparation.check(); guard !retired else { throw OperationCancellationFailure.cancelled }
                        onChanged()
                    }
                    try preparation.check(); guard !retired else { throw OperationCancellationFailure.cancelled }
                    // Source CheckRebaseCondition stashes first, then repairs
                    // author/committer configuration, then runs PreRebase. Cherry
                    // Pick shares the identity check but has no client hook.
                    try await requireReplayIdentity(preparation)
                    if !snapshot.options.isCherryPick {
                        _ = try await clientHooks.run(.preRebase, repository: repository, access: access, upstream: snapshot.options.upstream, rebasedBranch: snapshot.options.branch, cancellation: preparation, allowContinue: true)
                    }
                    try preparation.check(); guard !retired else { throw OperationCancellationFailure.cancelled }
                    replayRows = snapshot.entries; result = try await repository.startRebase(snapshot, editorExecutable: executable, afterFetch: completionAfterFetch, autoStart: completionAutoStart, fromLog: completionFromLog, cancellation: preparation, onOutput: emit)
                case "abort": result = try await repository.abortRebase(cancellation: preparation, onOutput: emit)
                case "skip": result = try await repository.skipRebase(cancellation: preparation, onOutput: emit)
                default:
                    let rawText=draftMessage,paths=continuationPaths,head=continuationHead
                    guard let captured=continuationState else {throw RebaseFailure.inactive}
                    if captured.hasIgnoredCleanCommitFailure {
                        // Ignore was already accepted durably. Resume transport
                        // without preprocessing or submitting the failed text.
                        result=try await repository.continueRebase(expectedReplayState:captured,expectedReplayHead:head,
                            cancellation:preparation,onOutput:emit,editorExecutable:replayEditor)
                    } else if let failure = captured.cleanCommitFailure {
                        result = try await recoverCleanCommitFailure(failure, expected: captured, repository: repository,
                            cancellation: preparation, onOutput: emit, editorExecutable: replayEditor)
                    } else if captured.emptyMessageWarning != nil {
                        // A reopened pre-entry warning has not applied its row.
                        // Keep its captured checkpoint through the same owned
                        // warning/recovery loop instead of amending a prior HEAD.
                        result=RebaseExecution(output:"",exitCode:0,state:captured)
                    } else {
                    try await repository.validateRebaseContinuation(expected:captured,expectedHead:head,cancellation:preparation)
                    let usesMessage=captured.squashMessage?.skipBaseHead == nil && (captured.squashMessage != nil || captured.isEditPause || continuationRecovery && usesCheckedSelection)
                    let text=usesMessage ? try await prepareReplayMessage(rawText,stripComments,sanitizeMessage,preparation):rawText
                    try preparation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
                    if usesMessage && text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {tab=1;throw RebaseFailure.message}
                    if continuationRecovery,captured.split == nil,!suppressConflictHints,try await repository.rebaseMessageContainsConflictHints(rawText,stripComments:stripComments,cancellation:preparation) {
                        guard await confirmConflictHints() else {tab=1;throw OperationCancellationFailure.cancelled}
                    }
                    try preparation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
                    try await repository.validateRebaseContinuation(expected:captured,expectedHead:head,cancellation:preparation)
                    if captured.squashMessage?.skipBaseHead != nil {
                        result=try await repository.continueRebase(expectedReplayState:captured,expectedReplayHead:head,cancellation:preparation,onOutput:emit,editorExecutable:replayEditor)
                    } else if captured.squashMessage != nil,captured.split == nil,try await repository.rebaseSquashIsEmpty(cancellation:preparation) {
                        let choice=await chooseEmptyResult()
                        try preparation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
                        if choice == .cancel {tab=1;throw OperationCancellationFailure.cancelled}
                        result=try await repository.continueRebase(squashMessage:text,emptySquashChoice:choice,expectedSquashHead:head,expectedSquashState:captured,expectedReplayState:captured,expectedReplayHead:head,cancellation:preparation,onOutput:emit,editorExecutable:replayEditor)
                    } else if continuationRecovery,usesCheckedSelection,captured.split == nil {
                        let empty=try await repository.rebaseConflictSelectionIsEmpty(paths:paths,expected:captured,expectedHead:head,cancellation:preparation)
                        let choice=empty ? await chooseEmptyResult():RebaseEmptyChoice.commit
                        try preparation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
                        if choice == .cancel {tab=0;throw OperationCancellationFailure.cancelled}
                        try await repository.validateRebaseContinuation(expected:captured,expectedHead:head,cancellation:preparation)
                        if empty,!(try await repository.rebaseConflictSelectionIsEmpty(paths:paths,expected:captured,expectedHead:head,cancellation:preparation)) {throw RebaseFailure.changed}
                        if choice == .skip {skippedID=captured.stoppedEntryID;result=try await repository.skipRebase(cancellation:preparation,onOutput:emit)}
                        else {result=try await repository.commitRebaseConflictSelection(message:text,paths:paths,expected:captured,expectedHead:head,allowEmpty:empty,cancellation:preparation,onOutput:emit)}
                    } else {
                        result=try await repository.continueRebase(squashMessage:captured.squashMessage == nil ? nil:text,editMessage:captured.isEditPause ? text:nil,expectedReplayState:captured,expectedReplayHead:head,cancellation:preparation,onOutput:emit,editorExecutable:replayEditor)
                    }
                    }
                }
                } catch let failure as RebaseCleanCommitFailure {
                    let saved = try await repository.rebaseState(cancellation: preparation)
                    result = try await recoverCleanCommitFailure(failure, expected: saved, repository: repository,
                        cancellation: preparation, onOutput: emit, editorExecutable: replayEditor)
                }
                    return try await recoverExecutionFailures(result,repository:repository,cancellation:preparation,onOutput:emit)
                }
                guard !retired else { return }
                try preparation.check(); state = result.state; finished = result.exitCode == 0 && !result.state.active; completedSuccessfully = finished && action != "abort";if completedSuccessfully {completionAction = .log}; completion = action == "abort" ? "\(operationTitle) aborted" : "\(operationTitle) finished"
                if result.exitCode == 0, let skippedID { replayRows = replayRows.map { var row = $0; if row.id == skippedID { row.action = .skip }; return row } }
                if finished, action != "abort" { replayRows = replayRows.map { var row = $0; row.progress = .completed; return row } }
                try await loadConflictFiles(repository:repository)
                if active { restoreSessionContext(); recovered = try await repository.remainingRebaseEntries(); replayRows = try await repository.rebaseReplayEntries(); if state?.squashMessage != nil || state?.isEditPause == true { tab = 1 }; selection = Set(state?.stoppedEntryID.isEmpty == false ? [state!.stoppedEntryID] : []) }
                if failedPickRecoveryCancelled { replayStopped=true;completion="Replay stopped; review the current state." }
                if finished || action=="abort" {automaticallySkipFailedPicks=false;failedPickSkipSession=nil}
                if !failedPickRecoveryCancelled, result.exitCode != 0, state?.needsFileRecovery == true, supportsConflictSelection, state?.split == nil, state?.conflicts.isEmpty == true, conflictRows.isEmpty { followEmpty = true; error = nil }
                if result.state.squashMessage != nil { tab = 1 }
                else if fileRecovery { tab = 0; if result.exitCode != 0 && !followEmpty && !failedPickRecoveryCancelled { error = result.output } }
                else if result.exitCode != 0 && !failedPickRecoveryCancelled { error = result.output }
                if failedPickRecoveryCancelled {tab=2;error=nil}
                if cleanCommitReturnedToEditor { tab=1; error=nil; replayStopped=true; completion="Replay stopped; review the current state." }
                onChanged()
                if action == "abort", finished { busy = false; finishingReplay = true; finishReplay(); return }
                if action == "continue", !cleanCommitReturnedToEditor, state?.split?.conflictRecovery == true { followRecovery = true }
            } catch {
                guard !retired else { return }; output = LocalGitCommandProgress.failure(error, existing: output, preferences: messageDefaults)
                let declined = !preparation.isCancelled && error is OperationCancellationFailure
                replayStopped = true; self.error = preparation.isCancelled || error is OperationCancellationFailure ? nil : error.localizedDescription
                let inspection=OperationCancellation();replayResultInspection=inspection
                defer {if replayResultInspection === inspection {replayResultInspection=nil}}
                do { let actual = try await readSessionValue(conflictIdentity, inspection,repository:repository); guard !retired else { return }; applyConflictSnapshot(actual); recovered = actual.remaining; replayRows = actual.replay; finished = declined ? previouslyFinished : !actual.state.active && (action != "start" || actual.head != snapshot?.branchHash); completedSuccessfully = false; completion = preparation.isCancelled || error is OperationCancellationFailure ? "Replay stopped; review the current state." : "Replay failed; review the current state."; onChanged() }
                catch { if !retired { self.error = error.localizedDescription } }
            }
        }
    }
    /// Retry means return to the stopped editor, as in RebaseDlg; it does not
    /// immediately rerun the failed commit. Ignore consumes the owned receipt.
    private func recoverCleanCommitFailure(_ failure: RebaseCleanCommitFailure, expected: RebaseState,
        repository: GitRepository, cancellation: OperationCancellation,
        onOutput: @escaping @Sendable (GitOutputChunk) -> Void, editorExecutable: URL?) async throws -> RebaseExecution {
        try cancellation.check()
        guard !retired, replayPreparationCancellation === cancellation, expected.cleanCommitFailure == failure else { throw RebaseFailure.changed }
        let owner = revisionMenuLog.window
        state=expected; error=nil
        recovered=try await repository.remainingRebaseEntries(cancellation:cancellation)
        replayRows=try await repository.rebaseReplayEntries(cancellation:cancellation)
        try await repository.validateRebaseContinuation(expected:expected,expectedHead:failure.head,cancellation:cancellation)
        try cancellation.check()
        guard !retired, replayPreparationCancellation === cancellation, revisionMenuLog.window === owner,
              !revisionMenuLog.confirmingQuit, owner?.attachedSheet == nil, NSApp.modalWindow == nil else { throw OperationCancellationFailure.cancelled }
        let draft = Data(amendMessage.utf8), editorID = replayMessageEditorID
        selection=[failure.identity.entry]; tab=1; hasReplayQuestion=true
        let answer=await chooseCleanCommitFailure(failure)
        hasReplayQuestion=false
        try cancellation.check()
        guard !retired, replayPreparationCancellation === cancellation, revisionMenuLog.window === owner,
              !revisionMenuLog.confirmingQuit, owner?.attachedSheet == nil, NSApp.modalWindow == nil else { throw OperationCancellationFailure.cancelled }
        guard replayMessageEditorID == editorID, Data(amendMessage.utf8) == draft else { throw RebaseFailure.changed }
        try requireAccess()
        try await repository.validateRebaseContinuation(expected:expected,expectedHead:failure.head,cancellation:cancellation)
        switch answer {
        case .retry:
            let stopped = try await repository.retryRebaseCleanCommitFailure(failure,expected:expected,expectedHead:failure.head,cancellation:cancellation)
            cleanCommitReturnedToEditor=true
            return RebaseExecution(output:failure.diagnostic,exitCode:0,state:stopped)
        case .ignore:
            do {
                return try await repository.ignoreRebaseCleanCommitFailure(failure,expected:expected,expectedHead:failure.head,
                    cancellation:cancellation,onOutput:onOutput,editorExecutable:editorExecutable)
            } catch let next as RebaseCleanCommitFailure {
                let saved=try await repository.rebaseState(cancellation:cancellation)
                return try await recoverCleanCommitFailure(next,expected:saved,repository:repository,cancellation:cancellation,onOutput:onOutput,editorExecutable:editorExecutable)
            }
        }
    }
    /// Keep the replay/access/Quit owner through each reached-row warning and
    /// source failure decision, including the checked return from Git recovery.
    private func recoverExecutionFailures(_ initial:RebaseExecution,repository:GitRepository,cancellation:OperationCancellation,
        onOutput:@escaping @Sendable (GitOutputChunk)->Void) async throws -> RebaseExecution {
        var result=initial
        while true {
            try cancellation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
            if let warning=result.state.emptyMessageWarning {
                state=result.state;recovered=try await repository.remainingRebaseEntries(cancellation:cancellation)
                replayRows=try await repository.rebaseReplayEntries(cancellation:cancellation)
                try cancellation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
                selection=[warning.entryID];tab=2;error=nil
                hasReplayQuestion=true
                let accepted=await confirmEmptyMessageReview()
                hasReplayQuestion=false
                try cancellation.check();guard !retired,accepted else {throw OperationCancellationFailure.cancelled}
                result=try await repository.acknowledgeRebaseEmptyMessage(warning,expected:result.state,expectedHead:warning.head,cancellation:cancellation,onOutput:onOutput)
                continue
            }
            guard result.exitCode != 0 else {return result}
            guard let failed=try await repository.failedPickRecovery(after:result,cancellation:cancellation) else {return result}
            if failedPickSkipSession != failed.sessionIdentity {automaticallySkipFailedPicks=false;failedPickSkipSession=failed.sessionIdentity}
            state=result.state;recovered=try await repository.remainingRebaseEntries(cancellation:cancellation)
            replayRows=try await repository.rebaseReplayEntries(cancellation:cancellation)
            try cancellation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
            selection=[failed.entry.id];tab=2;error=nil
            let answer:FailedPickDecision
            if failed.pendingAction == .skip {
                hasReplayQuestion=true
                answer=await chooseFailedPickCleanup(failed) ? .retry:.cancel
                hasReplayQuestion=false
            } else if automaticallySkipFailedPicks {answer = .skip(remember:true)}
            else {
                hasReplayQuestion=true
                answer=await chooseFailedPickRecovery(failed)
                hasReplayQuestion=false
            }
            try cancellation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
            let action:RebaseFailedPickAction
            switch answer {
            case .cancel:failedPickRecoveryCancelled=true;return result
            case .retry:if failed.pendingAction != .skip {automaticallySkipFailedPicks=false};action = .retry
            case .skip(let remember):automaticallySkipFailedPicks=remember;action = .skip
            }
            result=try await repository.recoverFailedPick(failed,action:action,cancellation:cancellation,onOutput:onOutput)
            if action == .skip || failed.pendingAction == .skip,result.exitCode==0 || result.state.stoppedEntryID != failed.state.stoppedEntryID {
                replayRows=replayRows.map {row in var row=row;if row.id==failed.entry.id {row.action = .skip;row.progress = .completed};return row}
            }
        }
    }
    var canSplit: Bool { !revisionHistoryBlocked && !retired && pendingConfirmation == nil && confirmation == nil && !busy && !revisionFiles.busy && !selectingSplit && state?.canSplit == true }
    private func prepareEditMessageContinuation() {
        guard canRequest("continue"), let expected = state else { return }
        let repository=self.operationRepository()
        let head = conflictHead, draft = amendMessage, token = OperationCancellation()
        messageSelectionCancellation = token; preparingMessageSelection = true; busy = true; Self.activePreparationReads += 1;pendingBatchWorkers += 1
        Task { [self, access] in
            defer {
                Self.activePreparationReads -= 1;pendingBatchWorkers -= 1; withExtendedLifetime(access) {}
                if messageSelectionCancellation === token { messageSelectionCancellation = nil; preparingMessageSelection = false; cancellingPreparation = false }
            }
            do {
                try requireAccess()
                let selection = try await repository.beginRebaseEditSelection(expected: expected, expectedHead: head, cancellation: token)
                try token.check(); guard !retired else { return }
                if let selection {
                    try await loadConflictFiles(cancellation: token,repository:repository)
                    try token.check(); guard !retired else { return }
                    amendMessage = draft; busy = false; selectingSplit = true; showSplitSelection(selection, draft)
                } else { busy = false; execute("continue",repository:repository) }
            } catch {
                guard !retired else { return }
                let inspection=OperationCancellation();replayResultInspection=inspection
                defer {if replayResultInspection === inspection {replayResultInspection=nil}}
                if let snapshot = try? await readSessionValue(conflictIdentity, inspection,repository:repository),!retired,!inspection.isCancelled { applyConflictSnapshot(snapshot) }
                guard !retired else{return}
                busy = false; if !token.isCancelled { self.error = error.localizedDescription }; loadPendingHandoff()
            }
        }
    }
    func beginSplitSelection() {
        guard canSplit else { return }; busy = true; Self.beginReplayWork();pendingBatchWorkers += 1
        Task {
            defer { Self.endReplayWork();pendingBatchWorkers -= 1; withExtendedLifetime(access) {} }
            do { try requireAccess(); let split = try await repository.beginRebaseSplit(); guard !retired else { return }; state = try await repository.rebaseState(); guard !retired else { return }; busy = false; selectingSplit = true; showSplitSelection(split, amendMessage) }
            catch { if !retired { busy = false; self.error = error.localizedDescription } }
        }
    }
    private func resumeConflictSelection(afterCommit: Bool = false) {
        guard !busy, !selectingSplit, let continuation = state?.split, continuation.conflictRecovery == true else { return }; busy = true; Self.beginReplayWork();pendingBatchWorkers += 1
        Task {
            defer { Self.endReplayWork();pendingBatchWorkers -= 1; withExtendedLifetime(access) {} }
            do {
                try requireAccess()
                let remaining = try await repository.rebaseSplitHasRemainingChanges(); guard !retired else { return }
                busy = false
                if remaining { selectingSplit = true; showSplitSelection(continuation, amendMessage) }
                else if continuation.parts == 0 {
                    busy = true
                    let draft = amendMessage
                    try await repository.cancelUnstartedRebaseSplit(); try await loadConflictFiles(); amendMessage = draft
                    busy = false
                    execute("continue")
                }
                else if afterCommit && state?.isEditPause == true { tab = 1 }
                else { execute("continue") }
            } catch { if !retired { busy = false; self.error = error.localizedDescription } }
        }
    }
    func splitSelectionClosed(committed: Bool) {
        guard !retired, selectingSplit else { return }; selectingSplit = false; busy = true; Self.beginReplayWork();pendingBatchWorkers += 1
        Task {
            defer { Self.endReplayWork();pendingBatchWorkers -= 1; withExtendedLifetime(access) {} }
            do {
                state = try await repository.rebaseState(); guard !retired else { return }; splitCommit = state?.split != nil && state?.split?.conflictRecovery != true
                guard committed else { if state?.split?.parts == 0 { let draft = amendMessage; try await repository.cancelUnstartedRebaseSplit(); try await loadConflictFiles(); amendMessage = draft; splitCommit = false }; busy = false; loadPendingHandoff(); return }
                if state?.split?.conflictRecovery == true {
                    try await loadConflictFiles()
                    busy = false; resumeConflictSelection(afterCommit: true); return
                }
                let remaining = try await repository.rebaseSplitHasRemainingChanges()
                let another = remaining ? true : await chooseAnotherSplit(); guard !retired else { return }
                busy = false
                if another { beginSplitSelection() }
                else { splitCommit = false; execute("continue") }
            } catch { if !retired { busy = false; self.error = error.localizedDescription; loadPendingHandoff() } }
        }
    }


}
/// Source order and labels of IDC_SPLITALLOPTIONS. The remembered action belongs
/// to this window, exactly like CMenuButton's current entry.
enum RebaseBulkAction:String,CaseIterable {
    case pickAll="Pick ALL",squashAll="Squash ALL",editAll="Edit ALL"
    case skipUnselected="Skip unselected",squashUnselected="Squash unselected",editUnselected="Edit unselected"
    var unselected:Bool {self == .skipUnselected || self == .squashUnselected || self == .editUnselected}
    var action:RebaseAction {
        switch self {case .pickAll:return .pick;case .squashAll,.squashUnselected:return .squash;case .editAll,.editUnselected:return .edit;case .skipUnselected:return .skip}
    }
}

/// Native split control: the main segment repeats the chosen command, while
/// the arrow exposes source-ordered commands with their original artwork.
final class RebaseNativeSplitControl:NSSegmentedControl {
    let lifetime=TransportControlLifetime()
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();lifetime.observe(self)}
}
struct RebaseSplitControl:NSViewRepresentable {
    let title:String
    let items:[(String,MenuIcon)]
    let label:String
    let enabled:Bool
    let primary:()->Void
    let captureMenu:()->((String)->Void)?
    var preferences:UserDefaults = .standard
    @Environment(\.isEnabled) private var environmentEnabled
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->NSSegmentedControl {
        let control=RebaseNativeSplitControl(labels:[title,""],trackingMode:.momentary,target:context.coordinator,action:#selector(Coordinator.clicked(_:)))
        control.segmentStyle = .rounded;control.setWidth(130,forSegment:0);control.setWidth(24,forSegment:1)
        control.setShowsMenuIndicator(true,forSegment:1);control.setAccessibilityLabel(label)
        context.coordinator.control=control;return control
    }
    func updateNSView(_ control:NSSegmentedControl,context:Context) {
        let coordinator=context.coordinator
        if let owned=control as? RebaseNativeSplitControl,owned.lifetime.retired {control.isEnabled=false;control.target=nil;control.action=nil;return}
        coordinator.live=true;coordinator.primary=primary;coordinator.captureMenu=captureMenu
        control.isEnabled=enabled && environmentEnabled;control.setLabel(title,forSegment:0)
        control.toolTip=title
        let names=items.map{$0.0}
        if coordinator.names != names || control.menu(forSegment:1)==nil {
            coordinator.invoke=nil;coordinator.names=names
            let menu=NSMenu();menu.delegate=coordinator;menu.autoenablesItems=false
            for (name,icon) in items {
                let item=NSMenuItem(title:name,action:#selector(Coordinator.chosen(_:)),keyEquivalent:"")
                item.target=coordinator;item.representedObject=name;item.image=icon.contextImage(defaults:preferences);menu.addItem(item)
            }
            control.setMenu(menu,forSegment:1)
        }
        for (index,item) in (control.menu(forSegment:1)?.items ?? []).enumerated() {item.state=item.title==title ? .on:.off;item.isEnabled=control.isEnabled;if items.indices.contains(index) {item.image=items[index].1.contextImage(defaults:preferences)}}
    }
    static func dismantleNSView(_ control:NSSegmentedControl,coordinator:Coordinator) {
        (control as? RebaseNativeSplitControl)?.lifetime.retire()
        coordinator.live=false;coordinator.invoke=nil;coordinator.primary={};coordinator.captureMenu={nil}
        control.menu(forSegment:1)?.delegate=nil;control.setMenu(nil,forSegment:1);control.target=nil;control.action=nil;control.isEnabled=false
    }
    @MainActor final class Coordinator:NSObject,NSMenuDelegate {
        weak var control:NSSegmentedControl?
        var live=true,names:[String]=[]
        var primary:()->Void = {}
        var captureMenu:()->((String)->Void)? = {nil}
        var invoke:((String)->Void)?
        @objc func clicked(_ sender:NSSegmentedControl) {
            guard live,sender===control,sender.isEnabled,sender.window != nil,sender.selectedSegment==0 else{return}
            primary()
        }
        func menuWillOpen(_ menu:NSMenu) {
            guard live,let control,control.isEnabled,control.window != nil,control.menu(forSegment:1)===menu else {invoke=nil;return}
            invoke=captureMenu()
            for item in menu.items {item.isEnabled=invoke != nil}
        }
        @objc func chosen(_ sender:NSMenuItem) {
            guard live,let control,control.isEnabled,control.window != nil,sender.isEnabled,
                  sender.menu===control.menu(forSegment:1),let value=sender.representedObject as? String,let invoke else{return}
            self.invoke=nil;invoke(value)
        }
    }
}

enum RebaseCompletionAction: String, CaseIterable {
    case log = "Show log", restart = "Restart rebase", push = "Push…", mail = "Send Mail…", rebase = "Rebase…"
    var icon: MenuIcon {
        switch self { case .log: return .log; case .push: return .push; case .mail: return .sendMail; case .restart, .rebase: return .rebase }
    }
}

enum RebaseRevisionCommand: String, CaseIterable {
    case workingTree = "Compare with working tree", compare = "Compare with previous revision", unified = "Show changes as unified diff"
    case log = "Show log", browse = "Browse repository", branch = "Create branch at this version…", tag = "Create tag at this version…", push = "Push…", notes = "Edit Notes", patch = "Format Patch…"
    case find = "Find…", export = "Export this version…", containing = "Show branches this commit is on"
    case changeSets = "Compare change sets", pull = "Pull…", svnDCommit = "SVN DCommit…", referenceNames = "Tag/branch names"
    case details = "Full log details", detailsWithoutPaths = "Full log details without changed paths", hashes = "Hashes", authors = "Authors", authorNames = "Author names", authorEmails = "Author emails", subjects = "Subjects", messages = "Messages"
    func sourceCommand(single: Bool) -> HistoryContextCommand {
        switch self {
        case .workingTree: return .compareWorkingTree
        case .compare: return single ? .comparePrevious : .compareTwo
        case .unified: return single ? .unifiedDiff : .unifiedDiffTwo
        case .log: return .showLog
        case .browse: return .repositoryBrowser
        case .branch: return .createBranch
        case .tag: return .createTag
        case .push: return .push
        case .notes: return .editNote
        case .find: return .find
        case .export: return .export
        case .containing: return .showBranches
        case .patch: return .createPatch
        case .changeSets: return .compareChangeSets
        case .pull: return .pull
        case .svnDCommit: return .svnDCommit
        default: return .copyClipboard
        }
    }
    var icon: MenuIcon {
        switch self {
        case .workingTree, .compare: return .compare
        case .unified: return .unifiedDiff
        case .log: return .log
        case .browse: return .repositoryBrowser
        case .branch: return .branch
        case .tag: return .tag
        case .push: return .push
        case .notes: return .rebaseEdit
        case .find: return .historyFind
        case .export: return .export
        case .containing: return .showBranches
        case .patch: return .patch
        case .changeSets: return .compare
        case .pull: return .pull
        case .svnDCommit: return .commit
        default: return .copy
        }
    }
}
struct RebaseRevisionMenuPresentation: ViewModifier {
    @ObservedObject var log: LogWindowModel
    func body(content: Content) -> some View {
        content.alert("Git operation failed", isPresented: Binding(get: { log.error != nil }, set: { if !$0 { log.error = nil } })) {
            Button("OK") { log.error = nil }
        } message: { Text(log.error ?? "") }
    }
}

struct RebaseDialog: View {
    @ObservedObject var model: RebaseWindowModel
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    @AppStorage("LogDateFormat") private var shortDate = true
    @AppStorage("RelativeTimes") private var relativeTimes = false
    @AppStorage("UseSystemLocaleForDates") private var systemDates = true
    private var dates: HistoryDateSettings { .init(shortDate: shortDate, relative: relativeTimes, useSystemLocale: systemDates) }
    private var messageFont: Font { Font(MessageEditorFont.resolve(name: fontName, size: fontSize)) }
    var body: some View {
        let context=model.formContext
        VStack(spacing: 10) {
            HStack {
                if model.isCherryPick {
                    Text("Branch:"); TextField("", text: .constant("")).disabled(true)
                    Image(nsImage: MenuIcon.reverse.image() ?? NSImage()).resizable().frame(width: 16, height: 16).opacity(0.4)
                    Text("Upstream:"); TextField("", text: .constant("HEAD")).disabled(true)
                    Button("…") {}.disabled(true); Toggle("Onto", isOn: .constant(false)).toggleStyle(.button).disabled(true)
                } else {
                Text("Branch:"); ReferencePopup(references: model.referenceChoices(nil), selection: model.referenceBinding(branch:true,context:context), accessibilityLabel: "Branch", displaysIcons: true, tooltip:model.referenceTooltip(branch:true))
                Button { model.reverseReferences(context) } label: { Image(nsImage: MenuIcon.reverse.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }.accessibilityLabel("Reverse branch and upstream")
                Text("Upstream:"); ReferencePopup(references: model.referenceChoices(.upstream), selection: model.referenceBinding(branch:false,context:context), accessibilityLabel: "Upstream", displaysIcons: true, tooltip:model.referenceTooltip(branch:false))
                Button("…") { model.browseReference(.upstream,context:context) }.accessibilityLabel("Browse upstream references")
                Toggle("Onto", isOn: Binding(get: { model.ontoEnabled }, set: { _ in model.browseReference(.onto,context:context) })).toggleStyle(.button).help(model.options.onto)
                }
            }.disabled(!model.editable)
            VSplitView {
                VStack(spacing: 8) {
                    RebaseReplayTable(model: model, dates: dates)
                        .background(RebaseColumnLayout(model: model)).background(RebaseListInteraction(model: model))
                    HStack {
                        RebaseSplitControl(title:model.bulkAction.rawValue,items:RebaseBulkAction.allCases.map {($0.rawValue,$0.action.icon)},label:"Rebase bulk actions",enabled:model.canUseBulkActions,primary:{model.chooseBulkAction(model.bulkAction)},captureMenu:model.captureBulkAction,preferences:model.columnPreferences).frame(width:158,height:24)
                        Button("Up") { model.move(up:true,toEnd:NSEvent.modifierFlags.contains(.shift),context:context) }.disabled(!model.canMove(up: true, toEnd: true))
                        Button("Down") { model.move(up:false,toEnd:NSEvent.modifierFlags.contains(.shift),context:context) }.disabled(!model.canMove(up: false, toEnd: true))
                        Button { model.add(context) } label: { CommandLabel(title: "Add", icon: .add) }.disabled(!model.canAdd)
                        Spacer()
                        if model.isCherryPick { Toggle("add \"cherry picked from\"", isOn: model.option(\.addCherryPickedFrom,context:context)) }
                        else { Toggle("Preserve merges", isOn: model.option(\.preserveMerges,context:context)).help("Preserve merge commits while replaying the branch; see Help for structural rebase behavior."); Toggle("Force Rebase", isOn: model.option(\.force,context:context)).help("Force replay even if the branch is already a descendant of the upstream commit.") }
                    }.disabled(!model.editable)
                }.frame(minHeight: 180)
                TabView(selection: model.tabBinding(context)) {
                    Group {
                    if model.fileRecovery { RebaseConflictFiles(model: model) }
                    else {
                    RevisionComparisonFileList(model:model.revisionFiles,pathTitle:"Path",statusTitle:"Status")
                        .disabled(!model.revisionFilesAvailable)
                        .alert("File operation failed",isPresented:Binding(get:{model.revisionFiles.error != nil},set:{if !$0 {model.revisionFiles.error=nil}})) {
                            Button("OK"){model.revisionFiles.error=nil}
                        } message:{Text(model.revisionFiles.error ?? "")}
                    }
                    }.tabItem { Text(model.fileRecovery ? "Conflict Files" : "Revision Files") }.tag(0)
                    Group {
                        if model.fileRecovery || model.state?.squashMessage != nil || model.state?.isEditPause == true || model.state?.split != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.state?.squashMessage != nil ? "Combined commit message:" : "Edit commit message:")
                                ProjectMessageEditor(text: model.messageBinding(context), settings: model.projectSettings, label: model.state?.squashMessage != nil ? "Combined commit message" : "Edit commit message", preferences: model.messageEditorPreferences, issueProperties: model.issueProperties, sourceAvailable: { [weak model] in model?.canEditMessage == true && model?.formContext == context })
                                    .id(model.replayMessageEditorID).disabled(!model.canEditMessage)
                                if let author = model.replayMessageCommit {
                                    Text("Author: " + author.author + " <" + author.email + "> • Author date: " + dates.format(author.date, absolute: true)).font(.caption).textSelection(.enabled)
                                }
                                if let squash = model.state?.squashMessage { Text("Author: first commit • Author date: " + (squash.datePolicy == .first ? "first commit" : squash.datePolicy == .latest ? "latest commit" : "current time")).font(.caption) }
                            }.padding(8)
                        } else { ScrollView { Text(model.message).font(messageFont).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8) } }
                    }.tabItem { Text("Commit Message") }.tag(1)
                    SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: model.completedSuccessfully, preferences: model.columnPreferences).tabItem { Text("Progress") }.tag(2)
                }.frame(minHeight: 150)
            }
            if model.active {
                HStack { Button("Open Working Tree") { model.onShowStatus() }; Button("Refresh State") { model.refreshState() }; Spacer(); Button("Skip") { model.request("skip",context:context) }.disabled(!model.canSkipReplay) }
            }
            if model.busy { ProgressView().progressViewStyle(.linear) }
            else { ProgressView(value: model.finished ? 1 : Double(model.state?.currentStep ?? 0), total: model.finished ? 1 : Double(max(model.state?.total ?? 1, 1))) }
            HStack {
                if model.completionActions.isEmpty { Text(model.status).font(.caption) }
                else {
                    RebaseSplitControl(title:model.completionAction.rawValue,items:model.completionActions.map {($0.rawValue,$0.icon)},label:"Rebase completion actions",enabled:model.canPerformCompletionAction(model.completionAction),primary:{model.performCompletionAction(model.completionAction)},captureMenu:model.captureCompletionAction,preferences:model.columnPreferences).frame(width:158,height:24)
                }
                Spacer()
                if model.state?.canSplit == true {Toggle("Edit/Split commit",isOn:model.splitBinding(context)).disabled(!model.canSplit || model.state?.split != nil)}
                Button(model.primaryActionTitle) { model.primary(context) }.keyboardShortcut(.defaultAction).disabled(!model.finished && !model.active && !model.canStart)
                Button("Abort") { model.abort(context) }.keyboardShortcut(.cancelAction).help(model.active ? "Recover to the status before rebase":"Close this dialog")
                Button{model.refreshFromSourceCommand()}label:{CommandLabel(title:"Refresh",icon:.refresh)}.disabled(!model.canRefreshDialog).accessibilityIdentifier("rebase-refresh")
                Button("Help") { TurtleGitHelp.show(model.isCherryPick ? .cherryPick : .rebase) }
            }
        }.padding(12).disabled(model.busy || model.selectingSplit || model.pickingReference != nil)
        .overlay(alignment: .bottomLeading) {
            if model.replaying {
                HStack { Text(model.cancellingReplay ? "Stopping replay…" : "Running replay…").font(.caption); Button(model.cancellingReplay ? "Cancelling…" : "Cancel") { model.cancelReplay() }.disabled(model.cancellingReplay || model.hasReplayQuestion || model.confirmingReplayCancellation) }.padding(12)
            } else if model.revisionFiles.busy {
                HStack {ProgressView().controlSize(.small);Text(model.revisionFiles.fileActionTitle.isEmpty ? "Preparing revision files…":model.revisionFiles.fileActionTitle).font(.caption);Spacer();Button("Cancel"){model.revisionFiles.cancelEmbeddedPreparation()}}.padding(12).background(.regularMaterial)
            } else if model.hasCancellablePreparation {
                HStack { ProgressView().controlSize(.small); Text(model.preparingMessageSelection ? "Preparing commit selection…":model.addingCommits ? "Adding selected commits…":model.preparingMainline ? "Preparing merge parents…":model.revertingConflictFiles ? "Reverting selected files…":model.editingPendingActions ? "Updating pending replay actions…":model.refreshingSession ? "Refreshing replay state…":model.refreshingReferences ? "Refreshing references…":model.preparingConflictFiles ? "Preparing file action…":model.preparingConflictDiff ? "Preparing conflict comparison…":model.loadingPlan ? "Preparing commit plan…" : "Reading references…").font(.caption); Button(model.cancellingPreparation ? "Cancelling…" : "Cancel") { model.cancelPreparation() }.disabled(model.cancellingPreparation) }.padding(12)
            }
        }
        .modifier(RebaseRevisionMenuPresentation(log: model.revisionMenuLog))
        .disabled(model.revisionFindBlocked || model.containingReferenceBlocked)
        .onChange(of: model.busy) { if !$0 { model.refreshColumnMetadata() } }
        .onChange(of: model.selection) { _ in model.selectCommit() }
        .alert(model.operationTitle, isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil }; Button("Open Working Tree") { model.error = nil; model.onShowStatus() } } message: { Text(model.error ?? "") }
        .alert("Confirm " + model.operationTitle,isPresented:Binding(get:{model.confirmation != nil},set:{if !$0 {model.confirmation=nil}}),presenting:model.pendingConfirmation) {question in
            Button("Continue") {model.answerConfirmation(question,proceed:true)}
            Button("Cancel",role:.cancel) {model.answerConfirmation(question,proceed:false)}
        } message: {question in Text(question.message)}
        .sheet(isPresented: Binding(get: { model.conflictPatch != nil }, set: { if !$0 { model.conflictPatch = nil } })) {
            VStack { Text("Compare with base").font(.headline); OutputView(text: model.conflictPatch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.conflictPatch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
        .gitDockProgress(model.dockProgress)
    }
}
struct RebaseConflictSortableRow:Identifiable {
    let entry:StatusEntry
    let statistics:CommitFile?
    let status:String
    var id:String { GitPathRowIdentity.encode(entry.id) }
}
struct RebaseConflictSort:SortComparator {
    var column:StatusListColumn
    var order:SortOrder = .forward
    func compare(_ lhs:RebaseConflictSortableRow,_ rhs:RebaseConflictSortableRow)->ComparisonResult {
        let result:ComparisonResult
        if column == .status {
            let status=lhs.status.compare(rhs.status,options:.caseInsensitive)
            result=status == .orderedSame ? StatusListSorting.compare(lhs.entry,rhs.entry,column:.path):status
        } else {
            result=StatusListSorting.compare(lhs.entry,rhs.entry,column:column,lhsStatistics:lhs.statistics,rhsStatistics:rhs.statistics)
        }
        return order == .forward ? result : (result == .orderedAscending ? .orderedDescending:result == .orderedDescending ? .orderedAscending:.orderedSame)
    }
}
struct RebaseConflictFiles: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: RebaseWindowModel
    var body: some View {
        Table(model.conflictTableRows, selection: $model.nativeConflictSelection, sortOrder:Binding(get:{model.conflictSortOrder},set:{model.setConflictSort($0)})) {
            TableColumn("✓") { row in FileSelectionCheckbox(path: row.entry.path, verb: model.supportsConflictSelection ? "Commit" : "Check", checked: model.checkedConflicts.contains(row.entry.path), enabled: model.canCheckConflictFiles && !model.busy) { model.setConflictChecked(row.entry.path, checked: $0) }.frame(width: 20, height: 20) }.width(28)
            TableColumn("Path",sortUsing:RebaseConflictSort(column:.path)) { row in HStack(spacing:5) { Image(nsImage:row.entry.state.icon.image() ?? NSImage());cell(row,.path) }.repositoryFileHelp(repository: model.repository.root, path: row.entry.path, preferences: model.columnPreferences) }
            TableColumn("Extension",sortUsing:RebaseConflictSort(column:.fileExtension)) { cell($0,.fileExtension) }.width(min:45,ideal:70)
            TableColumn("Status",sortUsing:RebaseConflictSort(column:.status)) { cell($0,.status) }.width(min:80,ideal:110)
            TableColumn("Lines added",sortUsing:RebaseConflictSort(column:.added)) { cell($0,.added) }.width(min:55,ideal:85)
            TableColumn("Lines removed",sortUsing:RebaseConflictSort(column:.removed)) { cell($0,.removed) }.width(min:55,ideal:95)
        }.fileListFont().contextMenu(forSelectionType: String.self) { ids in
            let paths = GitPathRowIdentity.paths(ids)
            let menu = model.conflictFileMenu(paths)
            TurtleGitContextMenu {
                if model.canAddConflictFiles(menu) {
                    Button {model.addConflictFiles(menu,mode:.normal)} label:{CommandLabel(title:WorkingFileAddMode.normal.rawValue,icon:.add)}
                    if NSEvent.modifierFlags.contains(.shift),menu.statistics[menu.mark]?.isSubmodule != true {
                        ForEach([WorkingFileAddMode.executable,.symlink],id:\.self) {mode in
                            if model.canAddConflictFiles(menu,mode:mode) {Button {model.addConflictFiles(menu,mode:mode)} label:{CommandLabel(title:mode.rawValue,icon:.add)}}
                        }
                    }
                    Divider()
                }
                Button {model.compareConflictMenu(menu)} label:{CommandLabel(title:"Compare with base",icon:.compare)}
                    .disabled(model.busy || menu.rows.first(where:{GitReferenceName.equal($0.id,menu.mark)})?.canCompareWithBaseFromStatusList != true)
                if model.canShowConflictUnified(menu) {Button {model.showConflictUnified(menu)} label:{CommandLabel(title:"Show changes as unified diff",icon:.unifiedDiff)}}
                Divider()
                ResolveSelectionMenu(paths: menu.conflicts.map(\.path), rebase: true, canEdit: menu.rows.count == 1 && menu.conflicts.count == 1) { action, _ in model.conflictAction(action, menu: menu) }
                Divider()
                ForEach([StatusFileCommand.compareTwo, .log, .submoduleLog, .oldNameLog, .blame], id: \.self) { command in
                    if model.canConflictFileCommand(command, menu: menu) { Button { model.conflictFileCommand(command, menu: menu) } label: { CommandLabel(title: command.rawValue, icon: command.icon) } }
                }
                Divider()
                if model.canRevertConflictFiles(menu) {
                    Button {model.revertConflictFiles(menu)} label:{CommandLabel(title:"Revert",icon:.revert)}
                }
                ForEach(IndexFlagAction.allCases,id:\.self) { action in
                    if model.canSetConflictFlags(action,menu:menu) {Button {model.setConflictFlags(action,menu:menu)} label:{CommandLabel(title:action.rawValue,icon:.settings)}}
                }
                Divider()
                ForEach([StatusFileCommand.open, .openWith, .editor, .reveal, .export], id: \.self) { command in
                    if model.canConflictFileCommand(command, menu: menu) { Button { model.conflictFileCommand(command, menu: menu) } label: { CommandLabel(title: command.rawValue, icon: command.icon) } }
                }
                if model.canMarkConflictComparison(menu) {
                    Button {model.markConflictForComparison(menu)} label:{CommandLabel(title:"Mark for comparison",icon:.compare)}
                    if let mark=menu.comparisonMark,model.onConflictPreparedComparison != nil {
                        Button {model.compareConflictWithMarked(menu)} label:{CommandLabel(title:"Compare with “"+mark.label(for:menu.mark)+"”",icon:.compare)}
                    }
                }
                if model.canConflictFileCommand(.delete,menu:menu) {
                    Button {model.deleteConflictFiles(menu,permanently:NSEvent.modifierFlags.contains(.shift))} label:{CommandLabel(title:"Delete",icon:.remove)}
                }
                if model.canIgnoreConflictFiles(menu) {
                    IgnoreSelectionMenu(paths:menu.paths) {action,paths in model.ignoreConflictFiles(menu,action:action,paths:paths)}
                }
                Menu {
                    Button { model.copyConflictFiles(menu, copy: .all) } label: { CommandLabel(title: "Copy all information to clipboard", icon: .copy) }
                    Button { model.copyConflictFiles(menu, copy: .fullPaths) } label: { CommandLabel(title: "Full paths", icon: .copy) }
                    Button { model.copyConflictFiles(menu, copy: .relativePaths) } label: { CommandLabel(title: "Relative paths", icon: .copy) }
                    Button { model.copyConflictFiles(menu, copy: .names) } label: { CommandLabel(title: "File/folder names", icon: .copy) }
                    ForEach(model.visibleConflictColumns, id: \.self) { column in Button { model.copyConflictFiles(menu, copy: .column(column)) } label: { CommandLabel(title: "column '\(column.rawValue)'", icon: .copy) } }
                } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }.disabled(menu.rows.isEmpty || model.busy)
            }
        } primaryAction: { ids in
            let paths = GitPathRowIdentity.paths(ids)
            if paths.count == 1 && model.conflicts.contains(where: { paths.contains($0.id) }) { model.conflictAction(.editConflict, ids: paths) }
            else { model.compareConflictWorkingFiles(model.conflictFileMenu(paths)) }
        }
        .background(CommitFileInteraction(rows:model.conflictTableRows.map { .file($0.entry) },keyboardDeleteEnabled:false,captureWorkingDrag:{model.captureWorkingDrag($0)},workingDragOrigin:model.workingDragOrigin,nativeColumns:RebaseWindowModel.conflictColumns,preferences:model.columnPreferences,
            visibleColumns:Set(model.visibleConflictColumns),availableColumns:Set(RebaseWindowModel.conflictColumns),columnText:{model.conflictColumnText($0,$1)},
            savedOrder:model.conflictFileColumns.order,savedWidths:model.conflictFileColumns.widths,
            saveLayout:{model.saveConflictColumnLayout(order:$0,widths:$1)},setColumnVisible:{model.setConflictColumn($0,visible:$1)},
            resetColumns:{model.resetConflictColumns(choose:$0,onAccepted:$1)},focusedPath:$model.focusedConflictPath,enabled:model.conflictColumnsAvailable,
            delete:{entries,mark,permanently in model.deleteConflictFiles(model.conflictFileMenu(GitPathSet(entries.map(\.id)),markedPath:mark.id),permanently:permanently)},copy:{entries,status in model.copyConflictFiles(model.conflictFileMenu(GitPathSet(entries.map(\.id))),copy:status ? .pathsAndStatus:.relativePaths)},
            copyColumn:{entries,column in model.copyConflictFiles(model.conflictFileMenu(GitPathSet(entries.map(\.id))),copy:.column(column))},
            toggleCheck:{entries,mark in model.toggleConflictChecks(GitPathSet(entries.map(\.id)),mark:mark.id)}))
        .background(RebaseConflictFileKeys(model: model))
    }
    private func cell(_ row:RebaseConflictSortableRow,_ column:StatusListColumn)->some View {
        Text(model.conflictColumnText(row.entry,column)).foregroundStyle(row.entry.statusTextColor(selected:model.selectedConflicts.contains(row.entry.path),preferences:model.columnPreferences))
    }
}
/// Scope upstream's unmodified action keys to the AppKit table hosted by this
/// SwiftUI list. Other fields, tables and windows retain their normal key handling.
struct RebaseListInteraction: NSViewRepresentable {
    let model: RebaseWindowModel
    func makeNSView(context: Context) -> Probe { Probe() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
    func updateNSView(_ view: Probe, context: Context) { view.model = model }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }
    final class Probe: NSView {
        weak var model: RebaseWindowModel?
        private var monitor: Any?
        private weak var dragTable: NSTableView?
        private var dragStart: NSPoint?
        private var rowDrag: RebaseWindowModel.RowDrag?
        private(set) var dropIndex: Int?
        private let marker = NSView()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }; return self.observe(event)
            }
        }
        func stopObserving() { cancelRowDrag(); if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { stopObserving() }
        func cancelRowDrag() { marker.removeFromSuperview(); rowDrag = nil; dragStart = nil; dragTable = nil; dropIndex = nil }
        func beginDrag(in table: NSTableView, ids: Set<String>) -> Bool {
            guard let model, window?.attachedSheet == nil, let drag = model.beginRowDrag(ids) else { return false }
            rowDrag = drag; dragTable = table; return true
        }
        func updateDrag(at point: NSPoint) -> Bool {
            guard let table = dragTable, let model, let drag = rowDrag, table.visibleRect.contains(point) else { marker.removeFromSuperview(); dropIndex = nil; return false }
            var adjusted = point; adjusted.y += min(10,table.rowHeight/2)
            var destination = table.row(at:adjusted)
            if destination < 0, table.row(at:point) >= 0 { destination = table.numberOfRows }
            guard destination >= 0, model.canDropRows(drag,before:destination) else { marker.removeFromSuperview(); dropIndex = nil; return false }
            dropIndex = destination
            let y = destination == table.numberOfRows ? table.rect(ofRow:destination-1).maxY : table.rect(ofRow:destination).minY
            marker.wantsLayer = true; marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            marker.frame = NSRect(x:table.visibleRect.minX,y:y-1,width:table.visibleRect.width,height:2)
            if marker.superview !== table { table.addSubview(marker) }
            marker.setAccessibilityLabel("Insert selected commits here")
            return true
        }
        @discardableResult func finishDrag() -> Bool {
            defer { cancelRowDrag() }
            guard let model, let drag = rowDrag, let destination = dropIndex else { return false }
            let accepted = model.dropRows(drag,before:destination), table = dragTable
            if accepted { DispatchQueue.main.async { [weak model, weak table] in
                guard let model, let table, let row = model.entries.firstIndex(where:{ model.selection.contains($0.id) }) else { return }
                table.scrollRowToVisible(row)
            } }
            return accepted
        }
        private func rowTable() -> NSTableView? {
            guard let content = window?.contentView else { return nil }
            func find(_ view:NSView)->NSTableView? {
                if let table = view as? NSTableView, table.tableColumns.count == RebaseColumnLayout.Probe.names.count,
                   convert(bounds,to:nil).intersects(table.convert(table.visibleRect,to:nil)) { return table }
                return view.subviews.compactMap(find).first
            }
            return find(content)
        }
        private func observeMouse(_ event:NSEvent)->NSEvent? {
            guard let window, event.window === window else { if event.type == .leftMouseUp { cancelRowDrag() }; return event }
            if event.type == .leftMouseDown {
                cancelRowDrag()
                guard event.clickCount == 1, model?.canDragRows == true, let table = rowTable() else { return event }
                let point = table.convert(event.locationInWindow,from:nil)
                guard table.visibleRect.contains(point), table.row(at:point) >= 0 else { return event }
                dragTable = table; dragStart = point
            } else if event.type == .leftMouseDragged, let table = dragTable, let start = dragStart, let model {
                let point = table.convert(event.locationInWindow,from:nil)
                guard rowDrag != nil || hypot(point.x-start.x,point.y-start.y) >= 4 else { return event }
                if rowDrag == nil {
                    let visible = model.entries, ids = Set(table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
                    guard beginDrag(in:table,ids:ids) else { cancelRowDrag(); return event }
                }
                _ = updateDrag(at:point); _ = table.autoscroll(with:event); return nil
            } else if event.type == .leftMouseUp, rowDrag != nil { _ = finishDrag(); return nil }
            else if event.type == .leftMouseUp { cancelRowDrag() }
            return event
        }
        func observe(_ event: NSEvent) -> NSEvent? {
            if event.type != .keyDown { return observeMouse(event) }
            if rowDrag != nil, event.keyCode == 53 { cancelRowDrag(); return nil }
            guard event.type == .keyDown, let window, event.window === window,
                  let table = window.firstResponder as? NSTableView,
                  convert(bounds, to: nil).intersects(table.convert(table.visibleRect, to: nil)),
                  let model, model.editable || model.canEditPendingActions else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard flags.subtracting(.shift).isEmpty else { return event }
            let visible = model.entries
            let ids = Set(table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
            guard !ids.isEmpty else { return event }
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            guard [" ", "p", "s", "q", "e", "u", "d"].contains(key) else { return event }
            model.selection = ids
            switch key {
            case " ": model.cycleActions()
            case "p": model.setAction(.pick)
            case "s": model.setAction(.skip)
            case "q": model.setAction(.squash)
            case "e": model.setAction(.edit)
            default: model.move(up: key == "u", toEnd: flags.contains(.shift))
            }
            // The native representable reconciles occurrence-bound selection after
            // replacing rows. Immediate AppKit indexes would use the old rows.
            DispatchQueue.main.async { [weak table, weak model] in
                guard let table, let model, model.selection == ids else { return }
                let visible = model.entries
                let selected = visible.indices.filter { ids.contains(visible[$0].id) }
                if let row = key == "d" ? selected.last : selected.first { table.scrollRowToVisible(row) }
            }
            return nil
        }
    }
}

extension RebaseAction {
    var icon: MenuIcon {
        switch self { case .pick: return .rebasePick; case .skip: return .rebaseSkip; case .edit: return .rebaseEdit; case .squash: return .rebaseSquash }
    }
}

/// Clipboard and checked-row keys belong only to the lower conflict table.
/// Commit-message fields and the upper replay table retain their key behavior.
struct RebaseConflictFileKeys: NSViewRepresentable {
    let model: RebaseWindowModel
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.model = model }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: NSView {
        weak var model: RebaseWindowModel?
        private var monitor: Any?
        private var closing: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop(); guard let window else { return }
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handle(event) ?? event }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let closing { NotificationCenter.default.removeObserver(closing) }; closing = nil
        }
        func table() -> NSTableView? {
            func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
            var parent = superview
            while let ancestor = parent {
                let found = tables(ancestor); if found.count == 1 { return found.first }
                if found.count > 1 { let area = convert(bounds, to: nil); let intersecting = found.filter { area.intersects($0.convert($0.visibleRect, to: nil)) }; return intersecting.count == 1 ? intersecting.first : nil }; parent = ancestor.superview
            }
            return nil
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let model, !model.retired, !model.busy, model.fileRecovery, event.window === window,
                  let table = table(), let responder = window?.firstResponder as? NSView,
                  responder === table || responder.isDescendant(of: table) else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .shift, .option]), key = event.charactersIgnoringModifiers?.lowercased()
            let indexes = table.selectedRowIndexes.filter { model.conflictTableRows.indices.contains($0) }
            let ids = GitPathSet(indexes.map { model.conflictTableRows[$0].entry.path })
            if key == "c", flags == .command || flags == .control || flags == [.command, .shift] || flags == [.control, .shift] {
                model.copyConflictFiles(model.conflictFileMenu(ids), copy: flags.contains(.shift) ? .pathsAndStatus : .relativePaths); return nil
            }
            if event.keyCode == 49, flags.isEmpty || flags == .control {
                model.toggleConflictChecks(ids, mark: model.conflictTableRows.indices.contains(table.selectedRow) ? model.conflictTableRows[table.selectedRow].entry.path : nil); return nil
            }
            return event
        }
    }
}
