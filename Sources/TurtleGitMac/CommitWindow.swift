import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import TurtleGitCore
@MainActor private final class CommitNativeWindow: NSWindow {
    // SwiftUI hosting updates must not discard the form's usability floor.
    var minimumCommitContentSize=NSSize(width:900,height:680)
    override var contentMinSize:NSSize {
        get{NSSize(width:max(super.contentMinSize.width,minimumCommitContentSize.width),height:max(super.contentMinSize.height,minimumCommitContentSize.height))}
        set{super.contentMinSize=NSSize(width:max(newValue.width,minimumCommitContentSize.width),height:max(newValue.height,minimumCommitContentSize.height))}
    }
    override var minSize:NSSize {
        get{let floor=frameRect(forContentRect:NSRect(origin:.zero,size:minimumCommitContentSize)).size;return NSSize(width:max(super.minSize.width,floor.width),height:max(super.minSize.height,floor.height))}
        set{let floor=frameRect(forContentRect:NSRect(origin:.zero,size:minimumCommitContentSize)).size;super.minSize=NSSize(width:max(newValue.width,floor.width),height:max(newValue.height,floor.height))}
    }
    weak var model: CommitWindowModel?
    weak var commandMenu:CommitCommandMenu?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if commandMenu?.performKeyEquivalent(event)==true {return true}
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor private final class CommitIdentityQuestionState {
    let alert:NSAlert,token:OperationCancellation
    var completion:((Bool)->Void)?,watcher:Task<Void,Never>?
    var settling=false
    init(alert:NSAlert,token:OperationCancellation,completion:@escaping(Bool)->Void){self.alert=alert;self.token=token;self.completion=completion}
}

@MainActor private final class CommitDetachedQuestionState {
    let alert:NSAlert,token:OperationCancellation
    var completion:((CommitWindowModel.DetachedHeadChoice)->Void)?,watcher:Task<Void,Never>?
    var settling=false
    init(alert:NSAlert,token:OperationCancellation,completion:@escaping(CommitWindowModel.DetachedHeadChoice)->Void){self.alert=alert;self.token=token;self.completion=completion}
}

@MainActor private final class CommitConflictQuestionState {
    let alert:NSAlert,token:OperationCancellation
    var completion:(((accepted:Bool,remember:Bool)?)->Void)?,watcher:Task<Void,Never>?
    var settling=false
    init(alert:NSAlert,token:OperationCancellation,completion:@escaping((accepted:Bool,remember:Bool)?)->Void){self.alert=alert;self.token=token;self.completion=completion}
}

@MainActor final class CommitWindowController: NSWindowController, NSWindowDelegate {
    let model: CommitWindowModel
    private(set) var commandMenu:CommitCommandMenu?
    // Closing owners remain cached until their actual children/work release.
    // They must retain that ownership without becoming a usable dialog again.
    var canReuse:Bool {!closingCommit && model.messageFocusAvailable}
    override func showWindow(_ sender:Any?) {
        guard canReuse else{return}
        super.showWindow(sender)
    }
    func windowDidResignKey(_ notification:Notification) {cancelFormFocus();commandMenu?.remove()}
    var commandsAvailable:Bool {!closingCommit && !hasMessagePicker && !model.inputsBlocked && window?.attachedSheet==nil && model.messageFocusAvailable}
    var refreshCommandAvailable:Bool {!closingCommit && !hasMessagePicker && model.canRefresh && window?.attachedSheet==nil}
    func messageEditor(in view:NSView? = nil)->CommitMessageTextView? {
        guard let view=view ?? window?.contentView else {return nil}
        if let editor=view as? CommitMessageTextView {return editor}
        return view.subviews.compactMap {messageEditor(in:$0)}.first
    }
    func fileTable(in view:NSView? = nil)->NSTableView? {
        guard let view=view ?? window?.contentView else{return nil}
        if let table=view as? NSTableView,table.tableColumns.count>1 {return table}
        return view.subviews.compactMap{fileTable(in:$0)}.first
    }
    @discardableResult func focusFileList()->Bool {
        guard commandsAvailable,model.fileListAvailable,let window,let table=fileTable() else{return false}
        return window.makeFirstResponder(table)
    }
    private var formFocusTask:Task<Void,Never>?
    private var formFocusID=UUID()
    var formFocusPending:Bool {formFocusTask != nil}
    private func cancelFormFocus() {formFocusID=UUID();formFocusTask?.cancel();formFocusTask=nil}
    /// Accept the command against its form, then wait for SwiftUI's native
    /// attachment/editability update without carrying authority to a later form.
    @discardableResult func focusFormField(_ identifier:String)->Bool {
        cancelFormFocus()
        guard commandsAvailable,NSApp.modalWindow==nil,let window,window.isVisible,!window.isMiniaturized else{return false}
        let receipt=model.formReceipt,id=formFocusID,initialResponder=window.firstResponder
        guard formFocusAllowed(identifier),model.acceptsFormReceipt(receipt) else{return false}
        guard let completed=attemptFormFocus(identifier,receipt:receipt,window:window,initialResponder:initialResponder) else{return false}
        if completed {return true}
        formFocusTask=Task { @MainActor [weak self,weak window,weak initialResponder] in
            defer {if let self,self.formFocusID==id {self.formFocusTask=nil}}
            for _ in 0..<300 {
                do {
                    guard let self,let window,!Task.isCancelled,self.formFocusID==id else{return}
                    guard let completed=self.attemptFormFocus(identifier,receipt:receipt,window:window,initialResponder:initialResponder) else{return}
                    if completed {return}
                }
                try? await Task.sleep(nanoseconds:10_000_000)
            }
        }
        return true
    }
    private func formFocusAllowed(_ identifier:String)->Bool {
        switch identifier {
        case "Commit new branch":return model.nativeNewBranchInputAvailable
        case "Commit author":return !model.loadingAuthorIdentity
        case "Commit author date","Commit author time":return model.nativeAuthorDateInputAvailable
        default:return false
        }
    }
    /// nil revokes the request; false means the accepted native view is pending.
    private func attemptFormFocus(_ identifier:String,receipt:CommitWindowModel.FormReceipt,window:NSWindow,initialResponder:NSResponder?)->Bool? {
        guard self.window===window,window.isVisible,!window.isMiniaturized,NSApp.modalWindow==nil,commandsAvailable,model.acceptsFormReceipt(receipt),formFocusAllowed(identifier) else{return nil}
        func find(_ view:NSView)->NSView? {
            if view.identifier?.rawValue==identifier{return view}
            return view.subviews.compactMap{find($0)}.first
        }
        guard let content=window.contentView else{return nil}
        let field=find(content),responder=window.firstResponder
        let ownsResponder:Bool
        if let text=field as? NSTextField {ownsResponder=responder===text || responder===text.currentEditor()}
        else if let field,let responder=responder as? NSView {ownsResponder=responder===field || responder.isDescendant(of:field)}
        else {ownsResponder=false}
        guard responder===initialResponder || responder===window || ownsResponder else{return nil}
        guard let field,field.window===window,!field.isHiddenOrHasHiddenAncestor,
              (field as? NSControl)?.isEnabled != false else{return false}
        if let text=field as? CommitOwnedTextField {
            guard text.hasOriginalOwner else{return nil}
            let expectsEditing=identifier=="Commit new branch" || model.setAuthor
            guard text.isEditable==expectsEditing,text.isSelectable else{return false}
            guard window.makeFirstResponder(text) else{return false}
            text.selectText(nil)
            guard let editor=text.currentEditor() else{return false}
            editor.selectedRange=NSRange(location:0,length:text.stringValue.utf16.count)
            return true
        }
        if let picker=field as? CommitOwnedDatePicker,!picker.hasOriginalOwner {return nil}
        guard window.makeFirstResponder(field) else{return false}
        guard let responder=window.firstResponder as? NSView else{return false}
        return responder===field || responder.isDescendant(of:field)
    }
    var onClosed: () -> Void = {}
    private(set) var partial: PatchWindowController?
    private(set) var stagingHintAlert:NSAlert?
    private var stagingHintAnswer:((Bool?)->Void)?
    private(set) var unversionedFilesAlert:NSAlert?
    private var unversionedFilesAnswer:(((show:Bool,remember:Bool)?)->Void)?
    private var visibilitySheetObservation:AnyCancellable?
    private var previousPartialParentFrame: NSRect?
    private var positioningPartial = false
    var partialPlacementScreens: () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private(set) var templatePanel: NSOpenPanel?
    private var closingCommit = false
    private var conflictQuestionState:CommitConflictQuestionState?
    private(set) var mergeHintAlert:NSAlert?
    var presentConflictQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool={owner,alert,reply in alert.beginSheetModal(for:owner,completionHandler:reply);return true}
    private var commitIdentityQuestion:CommitIdentityQuestionState?
    var identityQuestion:NSAlert? {commitIdentityQuestion?.alert}
    private var identitySettings:SettingsSheetController?
    var identitySettingsWindow:NSWindow? {identitySettings?.window}
    var identityNavigation:SettingsNavigationController? {identitySettings?.navigation}
    var presentCommitIdentityQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool={owner,alert,reply in alert.beginSheetModal(for:owner,completionHandler:reply);return true}
    var configureCommitIdentitySettings:(SettingsSheetController)->Void={_ in}
    private var detachedQuestionState:CommitDetachedQuestionState?
    var detachedQuestion:NSAlert? {detachedQuestionState?.alert}
    private(set) var detachedBranch:BranchTagWindowController?
    var configureDetachedBranch:(BranchTagWindowController)->Void={_ in}
    var presentDetachedQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool={owner,alert,reply in alert.beginSheetModal(for:owner,completionHandler:reply);return true}
    private var historyWindow: NSWindow?
    var makeHistoryWindow: () -> NSWindow = {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    }
    private var logPicker: LogWindowController?
    private(set) var preflightAlert:NSAlert?
    var hasMessagePicker: Bool { historyWindow != nil || logPicker != nil }
    private(set) var issueProviderOwner: CommitIssueProviderOwner?
    private var progressController: CommitProgressWindowController?
    private(set) var addProgressController:AddProgressWindowController?
    var configureAddProgress:(AddProgressWindowModel)->Void={_ in}
    var onPullAfterLFSLock: () -> Void = {}
    private var lfsOperation: LFSFileOperationController?
    var makeLFSOperation: (GitRepository, RepositoryAccessLease?) -> LFSFileOperationController = { LFSFileOperationController(repository: $0, access: $1) }
    init(repository: GitRepository, access: RepositoryAccessLease?, defaults: UserDefaults = .standard) {
        makeLFSOperation = { LFSFileOperationController(repository: $0, access: $1, defaults: defaults) }
        preferences = defaults
        model = CommitWindowModel(repository: repository, access: access, unversionedDefaults: defaults, dialogDefaults: defaults)
        let window = CommitNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Commit", preferences: defaults)
        window.contentMinSize=NSSize(width:900,height:680); window.isReleasedWhenClosed = false
        let host=NSHostingController(rootView: CommitDialog(model: model).defaultAppStorage(defaults));host.sizingOptions=[]
        window.contentViewController=host
        super.init(window: window); model.comparisonWindow = window; model.missingStagedRecovery.ownerWindow = window; model.clientHooks.windowProvider = { [weak window] in window?.attachedSheet ?? window }; window.model = model; window.delegate = self; window.setContentSize(NSSize(width: 1000, height: 760)); window.center()
        model.confirmDetachedHead={ [weak self] token in await self?.askDetachedHead(token) ?? .cancel }
        model.createDetachedBranch={ [weak self] token in await self?.showDetachedBranch(token) ?? false }
        model.retireDetachedChildren={ [weak self] in self?.retireDetachedChildren() }
        model.repairCommitIdentity={ [weak self] token in await self?.repairCommitIdentity(token) ?? false }
        model.retireCommitIdentitySettings={ [weak self] in self?.retireCommitIdentityChildren() }
        model.presentAddProgress={ [weak self] paths,mode,backend,token in
            guard let self,!self.closingCommit,!self.model.confirmingQuit,self.addProgressController==nil,let owner=self.window,owner.attachedSheet==nil,!token.isCancelled else{return false}
            return await withCheckedContinuation { continuation in
                let child=AddProgressWindowController(repository:repository,access:access,paths:paths,mode:mode,preferences:defaults,backend:backend,preservePathOrder:true)
                child.model.allowsCommit=false
                child.model.externalAvailability={ [weak self] in self?.closingCommit==false && self?.model.confirmingQuit==false }
                child.onProgressLog={ [weak self] path in guard let self,!self.closingCommit,!self.model.confirmingQuit else{return};self.model.onFileLog(path)}
                var settled=false
                child.onClosed={ [weak self,weak child] in
                    guard !settled else{return};settled=true
                    if self?.addProgressController === child{self?.addProgressController=nil}
                    continuation.resume(returning:child?.model.success==true && child?.model.cancelled==false && !token.isCancelled)
                }
                self.addProgressController=child;self.configureAddProgress(child.model)
                if let sheet=child.window{sheet.alphaValue=owner.alphaValue;sheet.appearance=owner.effectiveAppearance;owner.beginSheet(sheet);child.model.start()}else{child.close()}
                Task{@MainActor [weak child] in
                    while !settled{if token.isCancelled{child?.close();return};try? await Task.sleep(nanoseconds:10_000_000)}
                }
            }
        }
        model.presentStagingHint={ [weak self,weak window] in
            guard let self,!self.closingCommit,let window,window.isVisible,window.attachedSheet==nil else {return nil}
            let alert=NSAlert();alert.alertStyle = .informational;alert.messageText="Staging support";alert.informativeText=CommitWindowModel.stagingHint
            alert.addButton(withTitle:"OK");alert.showsSuppressionButton=true;alert.suppressionButton?.title="Do not show this message again"
            self.stagingHintAlert=alert
            return await withCheckedContinuation { continuation in
                var answered=false
                let answer:(Bool?)->Void = {value in guard !answered else {return};answered=true;continuation.resume(returning:value)}
                self.stagingHintAnswer=answer
                alert.beginSheetModal(for:window) { [weak self] response in
                    if self?.stagingHintAlert === alert {self?.stagingHintAlert=nil;self?.stagingHintAnswer=nil}
                    answer(response == .alertFirstButtonReturn ? alert.suppressionButton?.state == .on:nil)
                }
            }
        }
        model.presentUnversionedFiles = { [weak self,weak window] in
            guard let self,!self.closingCommit,let window,window.isVisible,window.attachedSheet==nil else {return nil}
            let alert=NSAlert();alert.alertStyle = .informational
            alert.messageText=CommitWindowModel.noChangesMessage
            alert.informativeText="Do you want to see the unversioned files?"
            alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No");alert.buttons.last?.keyEquivalent="\u{1b}"
            alert.showsSuppressionButton=true;alert.suppressionButton?.title="Do not show this message again"
            self.unversionedFilesAlert=alert
            return await withCheckedContinuation { continuation in
                var answered=false
                let answer:((show:Bool,remember:Bool)?)->Void = {value in guard !answered else {return};answered=true;continuation.resume(returning:value)}
                self.unversionedFilesAnswer=answer
                alert.beginSheetModal(for:window) { [weak self] response in
                    if self?.unversionedFilesAlert === alert {self?.unversionedFilesAlert=nil;self?.unversionedFilesAnswer=nil}
                    answer(response == .alertFirstButtonReturn || response == .alertSecondButtonReturn ? (response == .alertFirstButtonReturn,alert.suppressionButton?.state == .on):nil)
                }
            }
        }
        model.cancelUnversionedFilesPrompt = { [weak self] in self?.finishUnversionedFilesPrompt() }
        visibilitySheetObservation=NotificationCenter.default.publisher(for:NSWindow.didEndSheetNotification,object:window).sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in guard let self,!self.closingCommit else {return};self.model.offerMergeHint();self.model.offerStagingHint();self.model.offerUnversionedFiles() }
        }
        model.authorizeTemplateFile = { [weak self, weak window] file in
            guard let self, let window, !self.closingCommit, window.attachedSheet == nil else { throw OperationCancellationFailure.cancelled }
            let panel = NSOpenPanel(); self.templatePanel = panel
            panel.title = "Allow access to commit template"; panel.prompt = "Allow Access"
            panel.message = "Select the configured commit template: " + file.path
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.directoryURL = file.deletingLastPathComponent(); panel.nameFieldStringValue = file.lastPathComponent
            defer { if self.templatePanel === panel { self.templatePanel = nil } }
            let response = await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0) } }
            guard !self.closingCommit else { throw OperationCancellationFailure.cancelled }
            return response == .OK ? panel.url : nil
        }
        issueProviderOwner = CommitIssueProviderOwner(model: model, parent: window)
        model.close = { [weak self, weak window] in
            guard let self, self.canReuse, self.partial?.model.busy != true, self.partial?.window?.attachedSheet == nil, !self.model.unifiedViewerBusy else { return }
            window?.close()
        }
        model.onCommitProgress = { [weak self, weak window] progress in
            guard let self, self.canReuse, !self.model.confirmingQuit, let window, window.attachedSheet == nil else { progress.dismissWithoutWindow = true; if progress.cancellable { progress.cancellation.cancel() }; return }
            let controller = CommitProgressWindowController(model: progress)
            controller.onClosed = { [weak self] in self?.progressController = nil }
            self.progressController = controller
            if let child = controller.window { child.alphaValue=window.alphaValue;child.appearance=window.appearance;window.beginSheet(child) }
        }
        model.onLFSOperation = { [weak self, weak window] paths, locked in
            guard let self, !self.closingCommit, let window, window.attachedSheet == nil, self.lfsOperation == nil else { return false }
            let progress = self.makeLFSOperation(repository, access)
            progress.model.onProgressLog = { [weak self] path in self?.model.onFileLog(path) }
            progress.model.onPullAfterLock = { [weak self] in guard let self, !self.closingCommit else { return }; self.onPullAfterLFSLock() }
            progress.onClosed = { [weak self, weak progress] in
                guard let self, !self.closingCommit, self.lfsOperation === progress else { return }
                self.lfsOperation = nil; self.model.busy = false; self.model.reload(); self.model.refreshPartial()
            }
            self.lfsOperation = progress
            guard progress.present(owner: window, paths: paths, locked: locked) else { self.lfsOperation = nil; return false }
            return true
        }
        model.showPartial = { [weak self] staged in self?.showPartial(staged: staged) }
        model.showViewPatch = { [weak self] in self?.showPartial(staged: false, readOnly: true) }
        model.refreshPartial = { [weak self] in
            guard let self else { return }; if self.model.gitGuiInterface { self.model.refreshGuiPatch() } else { self.reloadPartial() }
        }
        model.interfaceChanged = { [weak self] in
            guard let self else { return }; self.commandMenu?.remove(); if !self.model.gitGuiInterface { self.commandMenu?.install() }
        }
        model.closePartial = { [weak self] in
            guard let self, self.partial?.model.busy != true, self.partial?.window?.attachedSheet == nil else { return }
            self.partial?.close()
        }
        model.showMessageHistory = { [weak self] insert in self?.showHistory(insert: insert) }
        model.pickRevision = { [weak self] message, insert in self?.showRevisionPicker(message: message, insert: insert) }
        model.chooseApplication = { [weak window] _ in
            await Task.yield()
            guard let window, window.attachedSheet == nil else { return nil }
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let response = await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0) } }
            return response == .OK ? panel.url : nil
        }
        model.chooseExportFolder = { [weak window] _ in
            await Task.yield()
            guard let window, window.attachedSheet == nil else { return nil }
            let panel = NSOpenPanel(); panel.title = "Export selected files"; panel.prompt = "Export"
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
            let response = await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0) } }
            return response == .OK ? panel.url : nil
        }
        model.confirmFileDeletion = { [weak window] paths, permanently in
            await Task.yield()
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = permanently ? "Permanently delete the selected paths?" : "Move the selected paths to Trash?"
            alert.informativeText = "\(paths.count) selected item(s). Their index entries will also be removed." + (permanently ? " This cannot be undone." : " Files moved to Trash can be recovered in Finder.")
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            return await withCheckedContinuation { reply in alert.beginSheetModal(for: window) { reply.resume(returning: $0 == .alertSecondButtonReturn) } }
        }
        model.confirmFileRestore = { [weak window] in
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Do you really want to restore the copy?"
            alert.informativeText = "You will lose all changes that you have done after creating the copy."
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Restore")
            return await withCheckedContinuation { reply in alert.beginSheetModal(for: window) { reply.resume(returning: $0 == .alertSecondButtonReturn) } }
        }
        model.chooseRestoreCopies = { [weak window] allowCancel, choose in
            guard let window else { choose(.cancel); return }
            let alert = NSAlert()
            alert.messageText = "You marked some files as “Restore after commit”."
            alert.informativeText = "Do you want to restore them now? You might lose all changes to this file after marking it."
            alert.addButton(withTitle: "Keep current state"); alert.addButton(withTitle: "Restore old state")
            if allowCancel { alert.addButton(withTitle: "Cancel") }
            alert.beginSheetModal(for: window) { response in
                choose(response == .alertSecondButtonReturn ? .restore : response == .alertFirstButtonReturn ? .keep : .cancel)
            }
        }
        model.confirmCancel = { [weak window] choose in
            guard let window else { choose(false); return }
            let alert = NSAlert(); alert.messageText = "Do you really want to cancel?"
            alert.informativeText = "Your commit message is saved in Recent messages."
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window) { response in
                if alert.suppressionButton?.state == .on { defaults.set(true, forKey: "Commit.SkipCancelConfirmation") }
                choose(response == .alertSecondButtonReturn)
            }
        }
        model.confirmUneditedTemplate = { [weak window] choose in
            guard let window else { choose(false); return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The commit message template has not been edited."
            alert.informativeText = "Do you want to proceed with this commit anyway?"
            alert.addButton(withTitle: "Proceed anyway"); alert.addButton(withTitle: "No")
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window) { [weak model = self.model] response in
                guard let model, model.messageFocusAvailable else { choose(false); return }
                if response == .alertFirstButtonReturn {
                    if alert.suppressionButton?.state == .on { model.rememberTemplateProceed() }
                }
                choose(response == .alertFirstButtonReturn)
            }
        }
        model.onFocusConflictedFile={ [weak self] key,path in
            guard let self else{return}
            let receipt=self.model.fileCheckReceipt
            Task{@MainActor [weak self] in
                for _ in 0..<200 {
                    guard let self,!self.closingCommit,!self.model.confirmingQuit,self.model.messageFocusAvailable,
                          self.model.fileCheckReceipt==receipt,self.model.selection==GitPathSet([path]) else{return}
                    if self.commandsAvailable,self.model.focusConflictFile(key:key,path:path) {return}
                    try? await Task.sleep(nanoseconds:5_000_000)
                }
            }
        }
        model.confirmConflictedSelection={ [weak self] paths,token in
            guard let self else{return nil}
            let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="One or more files are in a conflicted state."
            alert.informativeText="OK selects the first conflicted file. Ignore continues with the current commit selection.\n\n"+paths.prefix(8).joined(separator:"\n")
            alert.addButton(withTitle:"OK");alert.addButton(withTitle:"Ignore")
            guard let result=await self.askConflictQuestion(alert,token:token,mergeHint:false) else{return nil}
            return (ignore:result.accepted,remember:result.remember)
        }
        model.presentMergeHint={ [weak self] token in
            guard let self else{return nil}
            let alert=NSAlert();alert.alertStyle = .informational
            alert.messageText="The commit you are composing is a special commit. It is a merge commit and, thus contains your changes as well as the changes of a merged branch."
            alert.informativeText="You should NOT uncheck files unless you know what you are doing.\n\nWhen you merge changes, conflicts can arise that must be solved manually (i.e., you need to integrate your changes into a file which was also modified on another branch).\n\nSee help for more information."
            alert.addButton(withTitle:"OK")
            return await self.askConflictQuestion(alert,token:token,mergeHint:true)?.remember
        }
        model.confirmBranchTagCollision={ [weak self,weak window] name,choose in
            guard let self,!self.closingCommit,let window,window.attachedSheet==nil else { choose(false);return }
            let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="A tag with this name already exists."
            alert.informativeText="Creating branch “"+name+"” makes the short name ambiguous. Continue anyway?"
            alert.addButton(withTitle:"Continue");let abort=alert.addButton(withTitle:"Abort");alert.buttons[0].keyEquivalent="";abort.keyEquivalent="\r";alert.window.defaultButtonCell=abort.cell as? NSButtonCell;self.preflightAlert=alert
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self else { choose(false);return };if self.preflightAlert===alert { self.preflightAlert=nil }
                choose(!self.closingCommit && response == .alertFirstButtonReturn)
            }
        }
        model.confirmMissingIssue = { [weak window] choose in
            guard let window else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "You have not entered an issue ID."
            alert.informativeText = "Do you want to commit without an issue ID?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        model.confirmMissingSignOff = { [weak window] choose in
            guard let window else { choose(.abort); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "The commit message has no Signed-off-by line for your Git identity."
            alert.addButton(withTitle: "Add Signed-off-by"); alert.addButton(withTitle: "Commit without Signed-off-by"); alert.addButton(withTitle: "Abort")
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn ? .add : $0 == .alertSecondButtonReturn ? .proceed : .abort) }
        }
        model.confirmConflictHints = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false, false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "Conflict hints remain in the commit message"
            alert.informativeText = "Git's commented conflict list remains in the message. Ignore this warning to keep those lines, or abort to edit the message. You can remove them automatically by enabling comment stripping in Commit message settings."
            alert.addButton(withTitle: "Ignore"); let abort = alert.addButton(withTitle: "Abort")
            alert.buttons.first?.keyEquivalent = ""; abort.keyEquivalent = "\r"; alert.window.defaultButtonCell = abort.cell as? NSButtonCell
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn, alert.suppressionButton?.state == .on) }
        }
        model.confirmDirtySubmodule = { [weak window] path, choose in
            guard let window, window.attachedSheet == nil else { choose(.cancel); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The submodule \"" + path + "\" is dirty."
            alert.informativeText = "Merely committing the superproject cannot track or save such changes to the submodule.\nCommit the submodule now or ignore dirty changes?"
            alert.addButton(withTitle: "Commit"); alert.addButton(withTitle: "Ignore"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn ? .commit : $0 == .alertSecondButtonReturn ? .ignore : .cancel) }
        }

        commandMenu=CommitCommandMenu(owner:self);window.commandMenu=commandMenu
        DialogGeometry.attach(window, identifier: "CommitWindowController")
    }
    /// AppUtils::CheckUserData precedes CCommitDlg and its Start hook. The
    /// captured, still-uninitialized native Commit host owns the macOS sheet;
    /// no repository status/template/hook preparation runs before this loop.
    private func repairCommitIdentity(_ token:OperationCancellation)async->Bool {
        guard !closingCommit,!model.confirmingQuit,!token.isCancelled,commitIdentityQuestion==nil,identitySettings==nil,let owner=window,owner.attachedSheet==nil else{return false}
        let alert=NSAlert();alert.alertStyle = .critical
        alert.messageText="User name and email must be set before commit."
        alert.informativeText="Do you want to set these now?"
        alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No")
        alert.window.alphaValue=owner.alphaValue;alert.window.appearance=owner.effectiveAppearance
        let accepted=await withCheckedContinuation { continuation in
            let pending=CommitIdentityQuestionState(alert:alert,token:token){continuation.resume(returning:$0)}
            commitIdentityQuestion=pending
            pending.watcher=Task{@MainActor [weak self,weak pending] in
                while !Task.isCancelled {
                    guard let self,let pending,self.commitIdentityQuestion === pending,!pending.settling else{return}
                    if token.isCancelled || self.closingCommit {self.settleCommitIdentityQuestion(pending,accepted:false);return}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
            }
            if !presentCommitIdentityQuestion(owner,alert,{[weak self,weak pending] response in
                guard let self,let pending else{return};self.settleCommitIdentityQuestion(pending,accepted:response == .alertFirstButtonReturn)
            }) {settleCommitIdentityQuestion(pending,accepted:false)}
        }
        guard accepted,!closingCommit,!model.confirmingQuit,!token.isCancelled,owner.attachedSheet==nil else{return false}
        return await showCommitIdentitySettings(token)
    }
    private func settleCommitIdentityQuestion(_ pending:CommitIdentityQuestionState,accepted:Bool) {
        guard commitIdentityQuestion === pending,!pending.settling else{return}
        pending.settling=true;pending.watcher?.cancel();pending.watcher=nil
        let child=pending.alert.window,parent=child.sheetParent ?? window
        if child.sheetParent != nil || parent?.attachedSheet === child {parent?.endSheet(child,returnCode:accepted ? .alertFirstButtonReturn:.abort)}
        child.orderOut(nil)
        Task{@MainActor [self,pending] in
            // End-sheet callbacks can precede actual AppKit detachment. Retain
            // the question and reload ownership until the native child retires.
            while child.sheetParent != nil || parent?.attachedSheet === child || child.attachedSheet != nil {
                await withCheckedContinuation{reply in DispatchQueue.main.asyncAfter(deadline:.now()+0.005){reply.resume()}}
            }
            child.close()
            if commitIdentityQuestion === pending {commitIdentityQuestion=nil}
            let reply=pending.completion;pending.completion=nil
            reply?(accepted && !closingCommit && !model.confirmingQuit && !pending.token.isCancelled)
        }
    }
    private func askConflictQuestion(_ alert:NSAlert,token:OperationCancellation,mergeHint:Bool)async->(accepted:Bool,remember:Bool)? {
        guard !closingCommit,!model.confirmingQuit,!token.isCancelled,conflictQuestionState==nil,let owner=window,owner.attachedSheet==nil else{return nil}
        alert.showsSuppressionButton=true;alert.suppressionButton?.title="Do not show this message again"
        alert.window.alphaValue=owner.alphaValue;alert.window.appearance=owner.effectiveAppearance
        return await withCheckedContinuation {reply in
            let pending=CommitConflictQuestionState(alert:alert,token:token){reply.resume(returning:$0)}
            conflictQuestionState=pending
            if mergeHint {mergeHintAlert=alert} else {preflightAlert=alert}
            pending.watcher=Task{@MainActor [weak self,weak pending] in
                while !Task.isCancelled {
                    guard let self,let pending,self.conflictQuestionState===pending,!pending.settling else{return}
                    if token.isCancelled || self.closingCommit || self.model.confirmingQuit {self.settleConflictQuestion(pending,result:nil);return}
                    try? await Task.sleep(nanoseconds:5_000_000)
                }
            }
            let presented=presentConflictQuestion(owner,alert){ [weak self,weak pending] response in
                guard let self,let pending else{return}
                let valid = !self.closingCommit && !self.model.confirmingQuit && !token.isCancelled
                let result:(accepted:Bool,remember:Bool)? = valid && (response == .alertFirstButtonReturn || !mergeHint && response == .alertSecondButtonReturn) ? (mergeHint || response == .alertSecondButtonReturn,alert.suppressionButton?.state == .on):nil
                self.settleConflictQuestion(pending,result:result)
            }
            if !presented {settleConflictQuestion(pending,result:nil)}
        }
    }
    private func settleConflictQuestion(_ pending:CommitConflictQuestionState,result:(accepted:Bool,remember:Bool)?) {
        guard conflictQuestionState===pending,!pending.settling else{return}
        pending.settling=true;pending.watcher?.cancel();pending.watcher=nil
        let child=pending.alert.window,owner=window
        if child.sheetParent != nil {child.sheetParent?.endSheet(child,returnCode:.cancel)}
        child.orderOut(nil)
        Task{@MainActor [self,pending] in
            while child.sheetParent != nil || owner?.attachedSheet===child {
                await withCheckedContinuation{reply in DispatchQueue.main.asyncAfter(deadline:.now()+0.005){reply.resume()}}
            }
            child.close()
            guard conflictQuestionState===pending else{return}
            conflictQuestionState=nil
            if preflightAlert===pending.alert {preflightAlert=nil}
            if mergeHintAlert===pending.alert {mergeHintAlert=nil}
            let answer=pending.completion;pending.completion=nil
            answer?(!closingCommit && !model.confirmingQuit && !pending.token.isCancelled ? result:nil)
        }
    }
    private func showCommitIdentitySettings(_ token:OperationCancellation)async->Bool {
        guard !closingCommit,!model.confirmingQuit,!token.isCancelled,identitySettings==nil,let owner=window,owner.attachedSheet==nil else{return false}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        workspace.root=model.repository.root;workspace.settingsContextOverride=(model.repository,model.access,true)
        let child=SettingsSheetController(workspace:workspace,preferences:preferences,initialPage:.git,title:"Settings – TurtleGit for Mac")
        identitySettings=child;model.hasCommitIdentitySettings=true
        child.window?.alphaValue=owner.alphaValue;child.window?.appearance=owner.effectiveAppearance
        return await withCheckedContinuation {continuation in
            var settled=false
            let watcher=Task{@MainActor [weak self,weak child] in
                while !Task.isCancelled && !settled {
                    guard let self,let child,self.identitySettings === child else{return}
                    if token.isCancelled || self.closingCommit {child.retire();return}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
            }
            child.onClosed={ [weak self,weak child] _ in
                guard !settled else{return};settled=true;watcher.cancel()
                if let self,self.identitySettings === child {self.identitySettings=nil;self.model.hasCommitIdentitySettings=false}
                // Cancel/OK only finish Settings. Neither certifies identity:
                // the model always reads all four values again.
                continuation.resume(returning:self?.closingCommit==false && self?.model.confirmingQuit==false && !token.isCancelled)
            }
            configureCommitIdentitySettings(child)
            guard !settled,canReuse,!model.confirmingQuit,!token.isCancelled,identitySettings === child,owner.attachedSheet==nil else{child.retire();return}
            child.presentSheet(for:owner)
        }
    }
    private func retireCommitIdentityChildren() {
        if let pending=commitIdentityQuestion {settleCommitIdentityQuestion(pending,accepted:false)}
        identitySettings?.retire()
    }
    private func askDetachedHead(_ token:OperationCancellation)async->CommitWindowModel.DetachedHeadChoice {
        guard !closingCommit,!model.confirmingQuit,!token.isCancelled,detachedQuestionState==nil,let owner=window,owner.attachedSheet==nil else{return .cancel}
        let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="Current HEAD is detached, you are working on (no branch).";alert.informativeText="Do you want to create a branch now?"
        alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No");alert.addButton(withTitle:"Cancel").keyEquivalent="\u{1b}"
        alert.window.alphaValue=owner.alphaValue;alert.window.appearance=owner.effectiveAppearance
        return await withCheckedContinuation {reply in
            let pending=CommitDetachedQuestionState(alert:alert,token:token){reply.resume(returning:$0)}
            detachedQuestionState=pending
            pending.watcher=Task{@MainActor [weak self,weak pending] in
                while !Task.isCancelled {
                    guard let self,let pending,self.detachedQuestionState === pending,!pending.settling else{return}
                    if token.isCancelled || self.closingCommit {self.settleDetachedQuestion(pending,choice:.cancel);return}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
            }
            if !presentDetachedQuestion(owner,alert,{ [weak self,weak pending] response in
                guard let self,let pending else{return}
                self.settleDetachedQuestion(pending,choice:response == .alertFirstButtonReturn ? .createBranch:response == .alertSecondButtonReturn ? .continueDetached:.cancel)
            }){settleDetachedQuestion(pending,choice:.cancel)}
        }
    }
    private func settleDetachedQuestion(_ pending:CommitDetachedQuestionState,choice:CommitWindowModel.DetachedHeadChoice) {
        guard detachedQuestionState === pending,!pending.settling else{return};pending.settling=true;pending.watcher?.cancel();pending.watcher=nil
        let child=pending.alert.window,parent=child.sheetParent ?? window
        if child.sheetParent != nil || parent?.attachedSheet === child {parent?.endSheet(child,returnCode:.abort)}
        child.orderOut(nil)
        Task{@MainActor [self,pending] in
            while child.sheetParent != nil || parent?.attachedSheet === child || child.attachedSheet != nil {
                await withCheckedContinuation{reply in DispatchQueue.main.asyncAfter(deadline:.now()+0.005){reply.resume()}}
            }
            child.close();if detachedQuestionState === pending{detachedQuestionState=nil}
            let reply=pending.completion;pending.completion=nil
            reply?(closingCommit || model.confirmingQuit || pending.token.isCancelled ? .cancel:choice)
        }
    }
    private func showDetachedBranch(_ token:OperationCancellation)async->Bool {
        guard !closingCommit,!model.confirmingQuit,!token.isCancelled,detachedBranch==nil,let owner=window,owner.attachedSheet==nil else{return false}
        let child=BranchTagWindowController(repository:model.repository,access:model.access,isTag:false,preferences:preferences)
        detachedBranch=child;model.hasDetachedBranch=true
        child.window?.alphaValue=owner.alphaValue;child.window?.appearance=owner.effectiveAppearance
        child.model.load(revision:"HEAD");child.model.switchAfterCreation=true
        return await withCheckedContinuation{continuation in
            var settled=false
            let watcher=Task{@MainActor [weak self,weak child] in
                while !Task.isCancelled && !settled {
                    guard let self,let child,self.detachedBranch === child else{return}
                    if token.isCancelled || self.closingCommit {child.close();return}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
            }
            child.onClosed={ [weak self,weak child] in
                guard !settled else{return};settled=true;watcher.cancel()
                let success=child?.model.completedSuccessfully==true
                if self?.detachedBranch === child {self?.detachedBranch=nil;self?.model.hasDetachedBranch=false}
                continuation.resume(returning:success && self?.closingCommit==false && self?.model.confirmingQuit==false && !token.isCancelled)
            }
            configureDetachedBranch(child)
            guard !settled,child.model.active,!token.isCancelled,!closingCommit else{child.close();return}
            if let sheet=child.window {owner.beginSheet(sheet)}else{child.close()}
        }
    }
    private func retireDetachedChildren() {
        if let pending=detachedQuestionState {settleDetachedQuestion(pending,choice:.cancel)}
        detachedBranch?.close()
    }
    private func finishUnversionedFilesPrompt() {
        let answer=unversionedFilesAnswer;unversionedFilesAnswer=nil
        if let alert=unversionedFilesAlert {
            unversionedFilesAlert=nil
            if let parent=alert.window.sheetParent {parent.endSheet(alert.window,returnCode:.abort)}
            alert.window.orderOut(nil)
        }
        answer?(nil)
    }
    func setQuitConfirmation(_ pending: Bool) { model.confirmingQuit = pending; partial?.model.confirmingQuit = pending;addProgressController?.model.confirmingQuit=pending;detachedBranch?.model.confirmingQuit=pending }
    func windowWillClose(_ notification: Notification) {
        // End-sheet callbacks may run synchronously while native children retire.
        // Fence owner actions before dismissing any of those children, once.
        guard !closingCommit else{return}
        closingCommit = true
        cancelFormFocus()
        if let pending=conflictQuestionState {settleConflictQuestion(pending,result:nil)}
        retireCommitIdentityChildren();retireDetachedChildren()
        commandMenu?.retire();visibilitySheetObservation=nil;finishUnversionedFilesPrompt()
        let hintAnswer=stagingHintAnswer;stagingHintAnswer=nil;stagingHintAlert=nil;hintAnswer?(nil)
        templatePanel?.cancel(nil); templatePanel = nil
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        preflightAlert=nil; model.invalidateForClose(); issueProviderOwner?.retire(); issueProviderOwner = nil; lfsOperation?.close(); lfsOperation = nil
        if let child = historyWindow {
            historyWindow = nil; window?.endSheet(child); child.orderOut(nil); child.close()
        }
        logPicker?.close(); logPicker = nil; partial?.close(); partial = nil; model.unifiedWindow?.close()
        addProgressController?.close()
        if model.fileWorkPending || conflictQuestionState != nil || model.mergeHintVisible || addProgressController != nil || commitIdentityQuestion != nil || identitySettings != nil || model.preparingCommitIdentity || detachedQuestionState != nil || detachedBranch != nil || model.preparingDetachedHead || model.detachedHeadWorkPending || model.attemptWorkPending || model.issueProviderWorkPending {
            Task{@MainActor [self] in
                while model.fileWorkPending || conflictQuestionState != nil || model.mergeHintVisible || addProgressController != nil || commitIdentityQuestion != nil || identitySettings != nil || model.preparingCommitIdentity || detachedQuestionState != nil || detachedBranch != nil || model.preparingDetachedHead || model.detachedHeadWorkPending || model.attemptWorkPending || model.issueProviderWorkPending {
                    await withCheckedContinuation{reply in DispatchQueue.main.asyncAfter(deadline:.now()+0.005){reply.resume()}}
                };onClosed()
            }
        } else {onClosed()}
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.preparingCommitIdentity || model.preparingDetachedHead || model.detachedHeadWorkPending || model.attemptWorkPending {model.cancel();return false}
        if model.missingStagedRecovery.busy { model.missingStagedRecovery.cancel(); return false }
        if model.submoduleLog.isReading { model.submoduleLog.cancel(); return false }
        guard sender.attachedSheet == nil, !hasMessagePicker, partial?.model.busy != true, partial?.window?.attachedSheet == nil, !model.unifiedViewerBusy else { return false }
        model.cancel(); return false
    }
    private func showHistory(insert: @escaping (String) -> Void) {
        guard !closingCommit, !model.inputsBlocked, let window, window.attachedSheet == nil,
              logPicker == nil, let history = model.messageHistory, historyWindow == nil else { return }
        let child = makeHistoryWindow(); child.isReleasedWhenClosed = false
        child.title = "Log History – TurtleGit"; child.minSize = NSSize(width: 400, height: 260)
        child.contentView = MessageHistoryPickerView(history: history) { [weak self, weak window, weak child] text in
            guard let self, !self.closingCommit, let child, self.historyWindow === child else { return }
            self.historyWindow = nil; window?.endSheet(child); child.orderOut(nil); child.close()
            if let text { insert(text) }
        }
        DialogGeometry.attach(child, identifier: "HistoryDlg")
        child.alphaValue=window.alphaValue;child.appearance=window.appearance
        historyWindow = child; window.beginSheet(child)
    }
    private func showRevisionPicker(message: Bool, insert: @escaping (String) -> Void) {
        guard !closingCommit, !model.inputsBlocked, let window, window.attachedSheet == nil,
              historyWindow == nil, logPicker == nil else { return }
        let picker = LogWindowController(repository: model.repository, access: model.access, onChoose: { [weak self] revision in
            guard let self,self.canReuse,!self.model.confirmingQuit else{return}
            if let revision {if message {self.model.importLogMessage(revision.hash,insert:insert)} else {insert(revision.hash)}}
            self.model.reload()
        },labelDefaults:model.colorPreferences)
        logPicker = picker
        picker.onClosed = { [weak self] in self?.logPicker = nil }
        model.configureLogPicker(picker.model)
        guard canReuse,!model.confirmingQuit,logPicker === picker,window.attachedSheet==nil else{picker.close();return}
        guard let child = picker.window else { logPicker = nil; return }
        child.alphaValue=window.alphaValue;child.appearance=window.appearance;window.beginSheet(child)
    }
    private func showPartial(staged: Bool, readOnly: Bool = false) {
        guard canReuse,!model.gitGuiInterface,!model.confirmingQuit,let window,window.attachedSheet==nil,partial?.model.busy != true, partial?.window?.attachedSheet == nil else { return }
        if let partial, partial.model.readOnly == readOnly, partial.model.staged == staged { partial.close(); return }
        let controller = partial ?? PatchWindowController(repository: model.repository, access: model.access, preferences: preferences)
        partial = controller
        controller.onClosed = { [weak self, weak controller] in
            guard let self, self.partial === controller else { return }
            if let child = controller?.window { child.parent?.removeChildWindow(child) }
            self.previousPartialParentFrame = nil
            self.partial = nil; self.model.partialMode = nil; self.model.viewingPatch = false
            if !self.closingCommit { self.model.savePatchPreference(false) }
        }
        controller.onMoved = { [weak self] in self?.snapPartial() }
        controller.model.onApplying = { [weak self] busy in
            guard let self, !self.closingCommit else { return }
            self.model.busy = busy
        }
        controller.model.onSettled = { [weak self] _ in
            guard let self, !self.closingCommit else { return }
            self.model.refreshStagingState(refreshPatch: false)
        }
        controller.model.onApplied = {}
        controller.model.readOnly = readOnly
        controller.model.staged = staged
        controller.model.base = model.comparisonBase
        model.partialMode = readOnly ? nil : staged
        model.viewingPatch = readOnly
        model.savePatchPreference(true)
        controller.model.comparisonTitle = model.comparisonBase != nil ? "Parent → Working tree" : model.hasHead ? "HEAD → Working tree" : "Initial commit"
        controller.window?.title = readOnly ? "View Patch – " + controller.model.comparisonTitle : staged ? "Partial Unstaging – HEAD → Index" : "Partial Staging – Index → Working tree"
        if let child = controller.window {
            // A modeless native companion can be moved independently, as upstream's
            // sticky PatchView. AppKit child windows otherwise translate on every
            // parent move, including deliberately detached placements.
            child.parent?.removeChildWindow(child)
            if previousPartialParentFrame == nil {
                positioningPartial = true
                child.setFrame(LogPatchPlacement.initial(parent: window.frame, width: child.frame.width, screens: partialPlacementScreens()), display: false)
                positioningPartial = false
            }
            child.alphaValue = window.alphaValue; child.appearance = window.appearance
        }
        previousPartialParentFrame = window.frame
        if let preview = controller.window, window.isVisible { preview.order(.above, relativeTo: window.windowNumber) }
        reloadPartial()
    }
    private func reloadPartial() {
        guard let partial else { return }
        partial.model.base = model.comparisonBase
        partial.model.comparisonTitle = model.comparisonBase != nil ? "Parent → Working tree" : model.hasHead ? "HEAD → Working tree" : "Initial commit"
        partial.window?.title = partial.model.readOnly ? "View Patch – " + partial.model.comparisonTitle : partial.model.staged ? (model.comparisonBase == nil ? "Partial Unstaging – HEAD → Index" : "Partial Unstaging – Parent → Index") : "Partial Staging – Index → Working tree"
        let selected = model.entries.filter { model.selection.contains($0.id) && $0.state != .untracked && $0.state != .ignored }
        let statistics = partial.model.readOnly ? model.statistics : partial.model.staged ? model.stagedStatistics : model.unstagedStatistics
        // A copied row may have no originalPath in porcelain status. Include
        // its diff source so the preview retains the copy header and whole-file gate.
        let paths = selected.flatMap { entry in
            let source = entry.originalPath ?? statistics[entry.path]?.oldPath
            return [entry.path] + (source.map { [$0] } ?? [])
        }
        partial.model.reload(paths: Array(GitPathSet(paths)).sorted(), staged: partial.model.staged)
    }
    private func snapPartial() {
        guard !closingCommit, !positioningPartial, let parent = window, let preview = partial?.window,
              let frame = LogPatchPlacement.snap(preview: preview.frame, parent: parent.frame), frame != preview.frame else { return }
        positioningPartial = true; preview.setFrame(frame, display: false); positioningPartial = false
    }
    private func followPartial() {
        guard !closingCommit, let parent = window, let preview = partial?.window, let previous = previousPartialParentFrame else { return }
        previousPartialParentFrame = parent.frame
        guard previous != parent.frame,
              let frame = LogPatchPlacement.follow(preview: preview.frame, oldParent: previous, newParent: parent.frame, minimumHeight: preview.minSize.height) else { return }
        positioningPartial = true; preview.setFrame(frame, display: false); positioningPartial = false
    }
    private func showPartialWithoutActivation() {
        guard !closingCommit, let parent = window, parent.isVisible, !parent.isMiniaturized, let preview = partial?.window else { return }
        preview.appearance = parent.appearance; preview.alphaValue = parent.alphaValue
        preview.order(.above, relativeTo: parent.windowNumber)
    }
    func windowDidMove(_ notification: Notification) { followPartial() }
    func windowDidResize(_ notification: Notification) { followPartial() }
    func windowWillMiniaturize(_ notification: Notification) { partial?.window?.orderOut(nil) }
    func windowDidDeminiaturize(_ notification: Notification) { showPartialWithoutActivation() }
    func windowDidBecomeKey(_ notification: Notification) {guard canReuse else{return};if !model.gitGuiInterface {commandMenu?.install()};showPartialWithoutActivation();model.offerMergeHint();model.offerStagingHint();model.offerUnversionedFiles()}
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CommitWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    lazy var clientHooks = ClientHookSession(preferences: dialogDefaults)
    @Published var conflictRebase = false
    @Published var entries: [StatusEntry] = [] { didSet { if entries != oldValue { fileMenuGeneration = UUID() } } }
    @Published var indexFlagFiles: [WorkingTreeFile] = []
    @Published var restoreCopies: GitPathMap<WorkingFileRestoreCopy> = [:] { didSet { fileMenuGeneration = UUID() } }
    var restoreWorkingCopy:((WorkingFileRestoreCopy,OperationCancellation?)async throws->Void)?
    enum RestoreChoice { case restore, keep, cancel }
    var chooseRestoreCopies: (Bool, @escaping (RestoreChoice) -> Void) -> Void = { _, choose in choose(.keep) }
    @Published var comparisonBase: String?
    @Published var stagedStatistics: GitPathMap<CommitFile> = [:]
    @Published var unstagedStatistics: GitPathMap<CommitFile> = [:]
    @Published private(set) var gitGuiInterface = false
    @Published private(set) var guiStaged = false
    @Published private(set) var guiPatch: PatchWindowModel?
    var interfaceChanged: () -> Void = {}
    func setCommitInterface(_ gui: Bool) {
        guard !inputsBlocked, messageFocusAvailable, loadedPreferences, gui != gitGuiInterface, guiPatch?.busy != true else { return }
        closePartial(); guiPatch?.retire(); guiPatch = nil
        gitGuiInterface = gui; dialogDefaults.set(gui, forKey: "TurtleGit.Commit.GitGuiInterface")
        stagingEnabled = gui || (persistedStaging ?? false); appliedStagingMode = stagingEnabled
        selection = []; interfaceChanged(); reload()
    }
    func selectGuiFiles(_ paths: Set<String>, staged: Bool) {
        guard gitGuiInterface, !inputsBlocked, guiPatch?.busy != true else { return }
        guiStaged = staged; stagedDiff = staged; selection = GitPathSet(paths)
        refreshGuiPatch()
    }
    func refreshGuiPatch() {
        guard gitGuiInterface, messageFocusAvailable, guiPatch?.applyingChanges != true else { return }
        if guiPatch == nil {
            let patch = PatchWindowModel(repository: repository, access: access, appearancePreferences: dialogDefaults)
            patch.externalAvailability = { [weak self] in self?.gitGuiInterface == true && self?.messageFocusAvailable == true && self?.inputsBlocked == false }
            patch.onApplying = { [weak self] value in self?.busy = value }
            patch.onSettled = { [weak self] _ in self?.refreshStagingState() }
            guiPatch = patch
        }
        guiPatch?.base = comparisonBase
        let available = guiStaged ? stagedEntries : unstagedEntries
        guiPatch?.reload(paths: available.filter { selection.contains($0.id) }.map(\.path), staged: guiStaged)
    }
    @Published var stagingEnabled = false { didSet { if stagingEnabled != oldValue { fileMenuGeneration = UUID();retireFormReceipts() } } }
    @Published var viewingPatch = false
    var readCommitIdentity:((OperationCancellation)async throws->ReplayUserIdentity)?
    var repairCommitIdentity:(OperationCancellation)async->Bool={_ in false}
    var retireCommitIdentitySettings:()->Void={}
    @Published private(set) var preparingCommitIdentity=false
    @Published private(set) var commitIdentityPrepared=false
    @Published var hasCommitIdentitySettings=false
    private var acceptedCommitIdentity:ReplayUserIdentity?
    @Published private(set) var messageEditorSession=UUID()
    @Published private(set) var attemptWorkPending=false
    private var pendingRecommitSession=false
    private var resetMetadataTransitions:[String:Bool]=[:]
    private func consumesResetTransition(_ key:String,value:Bool)->Bool {
        guard let expected=resetMetadataTransitions.removeValue(forKey:key) else{return false}
        return value==expected
    }

    private func requireCommitIdentity(_ token:OperationCancellation)async throws->Bool {
        if commitIdentityPrepared{return true}
        // SwiftUI may deliver checkbox observers after caller presets were
        // installed, including after an identity Settings round trip. Capture
        // enabled installation values once; false is the view's initial state
        // and creates no checkbox transition to consume. A later real toggle
        // still refreshes defaults. Existing replay snapshots stay authoritative.
        if replayAuthorPreset==nil,setAuthor {replayAuthorPreset=(setAuthor,author)}
        if replayDatePreset==nil,setAuthorDate {replayDatePreset=(setAuthorDate,authorDate,resetAuthorDate)}
        preparingCommitIdentity=true
        defer {preparingCommitIdentity=false}
        while true {
            let identity=try await readReload(token) {
                if let readCommitIdentity {return try await readCommitIdentity(token)}
                return try await repository.replayUserIdentity(cancellation:token)
            }
            guard !confirmingQuit else{throw OperationCancellationFailure.cancelled}
            if identity.complete {acceptedCommitIdentity=identity;commitIdentityPrepared=true;return true}
            let repair=try await readReload(token) {await repairCommitIdentity(token)}
            guard !confirmingQuit else{throw OperationCancellationFailure.cancelled}
            if !repair{return false}
        }
    }
    private var loadedPreferences = false
    struct FormReceipt:Equatable {fileprivate let revision:UUID}
    enum FormOption {case newBranch,amend,amendComparison,author,authorDate,resetDate,wholeProject,messageOnly,noAutoSubmodules,staging,unversioned}
    private var formRevision=UUID(),metadataEpoch=UUID()
    var formReceipt:FormReceipt {FormReceipt(revision:formRevision)}
    private func retireFormReceipts(){formRevision=UUID()}
    func acceptsFormReceipt(_ receipt:FormReceipt)->Bool {receipt==formReceipt && messageFocusAvailable && !inputsBlocked && comparisonWindow?.attachedSheet==nil && NSApp.modalWindow==nil}
    func canChangeFormOption(_ option:FormOption)->Bool {
        guard messageFocusAvailable,!inputsBlocked,comparisonWindow?.attachedSheet==nil,NSApp.modalWindow==nil else{return false}
        switch option {
        case .newBranch:return operation==nil && replaySplit==nil && historyCombine==nil
        case .amend:return hasHead && operation==nil && replaySplit==nil && historyCombine==nil
        case .amendComparison:return amend && hasParent && replaySplit==nil && historyCombine==nil
        case .resetDate:return amend && setAuthorDate && !loadingAuthorDate
        case .wholeProject:return !scopePaths.isEmpty
        default:return true
        }
    }
    func setFormOption(_ option:FormOption,value:Bool,receipt:FormReceipt) {
        guard acceptsFormReceipt(receipt),canChangeFormOption(option) else{return}
        switch option {
        case .newBranch:createBranch=value
        case .amend:amend=value
        case .amendComparison:amendDiffToLastCommit=value
        case .author:setAuthor=value
        case .authorDate:setAuthorDate=value
        case .resetDate:resetAuthorDate=value
        case .wholeProject:setShowWholeProject(value)
        case .messageOnly:messageOnly=value
        case .noAutoSubmodules:setDoNotAutoselectSubmodules(value)
        case .staging:setStagingEnabled(value)
        case .unversioned:setShowUnversioned(value)
        }
    }
    private var persistedStaging: Bool?
    @Published var partialMode: Bool?
    @Published var stagedDiff = true { didSet { if stagedDiff != oldValue { fileMenuGeneration = UUID() } } }
    private var hasLoaded = false
    static private(set) var activeFileDrops = 0
    var readDroppedURL: (NSItemProvider) async throws -> URL = CommitFileURLReader.read
    var applyDroppedURLs: (([URL], OperationCancellation) async throws -> [CommitDroppedItem])?
    private var droppedChecks: [CommitDroppedItem] = []
    private var reloadTask: Task<Void, Never>?
    private var reloadCancellation: OperationCancellation?
    private var reloadError:String?
    @Published private(set) var fileListReadError:String?
    @Published private(set) var fileListReadCancelled=false
    @Published private(set) var unversionedPromptVisible=false
    private var unversionedPromptPending=false
    private var unversionedPromptRequest=UUID()
    var presentUnversionedFiles:(() async -> (show:Bool,remember:Bool)?)?
    var cancelUnversionedFilesPrompt:()->Void = {}
    @Published private var pendingReloadCancel = false
    var queryCommitStatus: (Bool, OperationCancellation) async throws -> [StatusEntry]
    var queryStagingStates: ([StatusEntry], String?, OperationCancellation) async throws -> GitPathMap<CommitStagingState>
    @Published var statistics: GitPathMap<CommitFile> = [:]
    @Published var checked = GitPathSet()
    private var selectedPaths = GitPathSet()
    @Published var nativeFileSelection = Set<String>() {
        didSet {
            guard nativeFileSelection != oldValue else {return}
            selectedPaths = GitPathRowIdentity.paths(nativeFileSelection)
            fileMenuGeneration = UUID()
        }
    }
    var selection: GitPathSet {
        get {selectedPaths}
        set {
            let ids = Set(newValue.map(GitPathRowIdentity.encode))
            if nativeFileSelection != ids {nativeFileSelection = ids}
        }
    }

    @Published var fileMetadata: GitPathMap<StatusListMetadata> = [:] { didSet { if fileMetadata.mapValues({ $0.isDirectory }) != oldValue.mapValues({ $0.isDirectory }) { fileMenuGeneration = UUID() } } }
    @Published var hasLFS = false
    @Published var lfsOwners: GitPathMap<String> = [:]
    @Published var lfsLockedPaths = GitPathSet()
    @Published var lfsOwnershipKnown = false
    private var lfsOwnerCancellation: OperationCancellation?
    var queryLFSOwners: (OperationCancellation) async throws -> [LFSLock]
    var onLFSOperation: ([String], Bool) -> Bool = { _, _ in false }
    @Published var fileColumns = StatusListColumnSettings()
    var availableFileColumns: Set<StatusListColumn> { Set(StatusListColumn.allCases).subtracting(hasLFS ? [] : [.lfsOwner]) }
    var visibleFileColumns: [StatusListColumn] { fileColumns.order.filter { fileColumns.visible.contains($0) && availableFileColumns.contains($0) } }
    @Published var fileSortOrder = [CommitFileSort(column: .path)] { didSet { if !fileSortOrder.elementsEqual(oldValue, by: { $0.column == $1.column && $0.order == $1.order }) { fileMenuGeneration = UUID() } } }
    @Published var focusedFiles: [String: String] = [:] { didSet { if focusedFiles.mapValues({ GitReferenceName($0) }) != oldValue.mapValues({ GitReferenceName($0) }) { fileMenuGeneration = UUID() } } }
    @Published var changelists = GitChangelists() { didSet { if changelists != oldValue { fileMenuGeneration = UUID() } } }
    @Published var changelistsLoaded = false
    @Published var keepChangelists = false
    @Published var creatingChangelist = false
    @Published var changelistName = ""
    private var changelistPaths: [String] = []
    private var changelistMenu: StatusFileMenuSnapshot?
    @Published var branch = ""
    @Published var createBranch = false {didSet{if createBranch != oldValue{retireFormReceipts()}}}
    @Published var newBranch = ""
    @Published var message = "" { didSet { if !GitReferenceName.equal(message,oldValue) { cancelHistoryIssueUpdate(); scheduleIssueStyling() } } }
    @Published var projectSettings = ProjectDialogSettings()
    var projectIconAccess: RepositoryAccessLease? { access }
    static private(set) var activeIssueProviderOperations = 0
    @Published private(set) var issueProviderBusy = false
    @Published private(set) var issueProviderWorkPending = false
    @Published private(set) var issueProviderPreflightPending = false
    @Published private(set) var nativeIssueProvider: NativeIssueProviderSession?
    @Published private(set) var issueProviderError: String?
    private var issueProviderGeneration = UUID()
    var issueProviderCredentials: any IssueProviderCredentialStore = IssueProviderKeychainStore.shared
    var chooseProviderIssues: (NativeIssueProviderSession, NativeIssueProviderContext) async -> NativeIssueProviderResult? = { _, _ in nil }
    var cancelProviderIssues: () -> Void = {}
    var providerContext: NativeIssueProviderContext { NativeIssueProviderContext(repositoryRoot: repository.root, paths: scopePaths, message: message, issueID: issueID) }
    func selectProviderIssues() {
        guard messageFocusAvailable, !inputsBlocked, let provider = nativeIssueProvider else { return }
        let context = providerContext, generation = UUID(); issueProviderGeneration = generation; issueProviderBusy = true; issueProviderWorkPending = true; Self.activeIssueProviderOperations += 1
        Task {
            defer { Self.activeIssueProviderOperations -= 1; issueProviderWorkPending = false; withExtendedLifetime(access) {}; if issueProviderGeneration == generation { issueProviderBusy = false } }
            let result = await chooseProviderIssues(provider, context)
            guard messageFocusAvailable, issueProviderGeneration == generation, !confirmingQuit, message.utf8.elementsEqual(context.message.utf8), issueID.utf8.elementsEqual(context.issueID.utf8), scopePaths == context.paths, let result else { return }
            message = result.message; issueID = result.issueID; requestMessageFocus()
        }
    }
    private func readNativeIssueProvider(_ token: OperationCancellation) async throws -> (provider:NativeIssueProviderSession?,error:String?) {
        let rows: [NativeIssueAssociation]
        do { rows = try NativeIssueAssociations.load(from: dialogDefaults) }
        catch { return (nil,error.localizedDescription) }
        let association = try await readReload(token) { try await repository.nativeIssueAssociation(rows: rows, cancellation: token) }
        do {
            guard let association else {return (nil,nil)}
            var provider = try NativeIssueProviderSession(identifier:association.provider,parameters:association.parameters)
            if provider.isRemote,let endpoint=provider.endpoint {
                // Repository configuration cannot authorize sending repository
                // paths or drafts to a server. An enabled local association is
                // the user's explicit choice of this provider for this root.
                guard NativeIssueAssociations.matching(rows,root:repository.root) != nil else {
                    throw NativeIssueProviderFailure.configuration("Enable an association for this working tree in Issue Tracker Integration before using a remote provider.")
                }
                let store=issueProviderCredentials
                let bearer=try await readReload(token) {try await store.token(for:endpoint)}
                provider=try NativeIssueProviderSession(identifier:association.provider,parameters:association.parameters,bearerToken:bearer)
            }
            try token.check()
            return (provider,nil)
        } catch {
            try token.check()
            return (nil,error.localizedDescription)
        }
    }
    @Published var issueProperties = IssueTrackerProperties() { didSet { if issueProperties != oldValue { cancelHistoryIssueUpdate(); scheduleIssueStyling() } } }
    @Published private(set) var issueMessageStyles: [IssueMessageStyle] = []
    private let issueStyler = IssueMessageStyler()
    private var issueStyleTask: Task<Void, Never>?
    private var issueStyleCancellation: OperationCancellation?
    private var historyIssueTask: Task<Void, Never>?
    private var historyIssueCancellation: OperationCancellation?
    private var historyIssueGeneration = UUID()
    var queryHistoryIssue: (IssueTrackerProperties, String, OperationCancellation) async throws -> String
    @Published var formattingEnabled = true {
        didSet { if formattingEnabled != oldValue { scheduleIssueStyling() } }
    }
    private(set) var messageSnippets = MessageSnippets()
    @Published private(set) var messageCompletionCatalog = MessageCompletionCatalog()
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = UUID()
    private var completionSources: [MessageCodeScanner.Source] = []
    private var completionOptions: MessageCodeScanner.Options?
    private var completionEnabled: Bool?
    deinit { reloadCancellation?.cancel(); reloadTask?.cancel(); completionTask?.cancel(); issueStyleTask?.cancel(); issueStyleCancellation?.cancel(); historyIssueTask?.cancel(); historyIssueCancellation?.cancel(); authorCancellation?.cancel(); dateCancellation?.cancel(); amendCancellation?.cancel() }
    func prepareMessageCompletions(force: Bool = false) {
        var options = MessageCodeScanner.Options()
        let defaults = dialogDefaults
        let enabled = defaults.object(forKey: "Autocompletion") as? Bool ?? true
        options.removeExtensions = defaults.bool(forKey: "AutocompleteRemovesExtensions")
        options.parseUnversioned = defaults.bool(forKey: "AutocompleteParseUnversioned")
        options.maximumBytes = defaults.object(forKey: "AutocompleteParseMaxSize") as? Int ?? 300000
        options.timeoutSeconds = UInt32(clamping: defaults.object(forKey: "AutocompleteParseTimeout") as? Int ?? 5)
        options.useUTF8 = ComparisonTextEncoding.preferUTF8(from: defaults)
        let locallyIgnored = GitPathSet(indexFlagFiles.filter { $0.assumeUnchanged || $0.skipWorktree }.map { $0.entry.path })
        let rows = StatusListGroups.rows(entries: visibleEntries, changelists: changelists, locallyIgnored: locallyIgnored)
        let sources = rows.compactMap(\.entry).map { MessageCodeScanner.Source(path: $0.path, state: $0.state) }
        guard force || sources != completionSources || options != completionOptions || enabled != completionEnabled else { return }
        completionTask?.cancel()
        completionSources = sources; completionOptions = options; completionEnabled = enabled
        let generation = UUID(); completionGeneration = generation
        let snippets = messageSnippets, root = repository.root, lease = access
        let userDefinitions = RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("autolist.txt")
        completionTask = Task { [weak self] in
            guard !Task.isCancelled, self?.completionGeneration == generation else { return }
            self?.messageCompletionCatalog = MessageCompletionCatalog(snippets: snippets, paths: sources.map(\.path), removeExtensions: options.removeExtensions)
            guard enabled else { return }
            do {
                if GitRuntime.isAppStoreBuild && (lease?.hasSecurityScope != true || lease?.contains(root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await MessageCodeScanner.shared.scan(root: root, sources: sources, snippets: snippets, userDefinitions: userDefinitions, options: options)
                guard !Task.isCancelled, let self, self.completionGeneration == generation else { return }
                self.messageCompletionCatalog = result.catalog
            } catch { /* Filename/snippet fallback remains available after cancellation or inaccessible contents. */ }
            withExtendedLifetime(lease) {}
        }
    }
    private let snippetLoader = MessageSnippetLoader()
    @Published var issueID = "" { didSet { if !GitReferenceName.equal(issueID,oldValue) { cancelHistoryIssueUpdate() } } }
    private func cancelHistoryIssueUpdate() {
        historyIssueGeneration = UUID()
        historyIssueCancellation?.cancel(); historyIssueTask?.cancel()
        historyIssueCancellation = nil; historyIssueTask = nil
    }
    private func scheduleIssueStyling() {
        issueStyleTask?.cancel(); issueStyleCancellation?.cancel(); issueMessageStyles = []
        let cancellation = OperationCancellation(); issueStyleCancellation = cancellation
        let text = message, properties = issueProperties, worker = issueStyler, formatting = formattingEnabled
        guard !text.isEmpty else { return }
        issueStyleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                try Task.checkCancellation(); try cancellation.check()
                MessageEditorStylingSession.beginOperation()
                defer { MessageEditorStylingSession.endOperation() }
                let styles = try await worker.styles(properties: properties, message: text, formattingEnabled: formatting, cancellation: cancellation)
                guard !Task.isCancelled, let self, GitReferenceName.equal(self.message,text), self.issueProperties == properties, self.formattingEnabled == formatting else { return }
                self.issueMessageStyles = styles
            } catch { /* Invalid/stale styling does not interrupt text entry. Commit validation reports configuration failures. */ }
        }
    }
    func updateIssueFromHistory(_ selectedMessage: String, insertedInto text: String) {
        cancelHistoryIssueUpdate()
        let properties = issueProperties, previousID = issueID
        guard messageFocusAvailable, properties.showsIssueField else { return }
        let generation = historyIssueGeneration, token = OperationCancellation(), query = queryHistoryIssue
        historyIssueCancellation = token
        historyIssueTask = Task { [weak self] in
            defer {
                if self?.historyIssueGeneration == generation { self?.historyIssueTask = nil; self?.historyIssueCancellation = nil }
            }
            guard !Task.isCancelled, !token.isCancelled else { return }
            guard let id = try? await query(properties, selectedMessage, token), !id.isEmpty,
                  !Task.isCancelled, !token.isCancelled, let self, self.messageFocusAvailable,
                  self.historyIssueGeneration == generation,
                  GitReferenceName.equal(self.message,text), GitReferenceName.equal(self.issueID,previousID), self.issueProperties == properties else { return }
            self.issueID = id
        }
    }
    private var loadedMessage = false
    let templateFileAccess: CommitTemplateFileAccess
    var authorizeTemplateFile: (URL) async throws -> URL? = { _ in nil }
    private(set) var messageTemplate = ""
    private(set) var messageHistory: CommitMessageHistory?
    var showMessageHistory: (@escaping (String) -> Void) -> Void = { _ in }
    var pickRevision: (Bool, @escaping (String) -> Void) -> Void = { _, _ in }
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var onCompare: ([String], Bool) -> Void = { _, _ in }
    var onCompareTwoFiles: ([String]) -> Void = { _ in }
    lazy var submoduleLog = SubmoduleWorkingLogSession(repository: repository, access: access, preferences: dialogDefaults)
    var onSubmoduleLog: (GitRepository) -> Void = { _ in }
    var onFileLog: (String) -> Void = { _ in }
    var onFileBlame: (String) -> Void = { _ in }
    var onResolve: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onIgnore: (RepositoryAction, [String]) -> Void = { _, _ in }
    var onCopyAdd: ([String]) -> Void = { _ in }
    var onPasteFiles: (Bool, [URL]) -> Void = { _, _ in }
    var onMove: ([String]) -> Void = { _ in }
    var onRename: (String) -> Void = { _ in }
    var chooseApplication: (String) async -> URL? = { _ in nil }
    var chooseExportFolder: ([String]) async -> URL? = { _ in nil }
    var confirmFileDeletion: ([String], Bool) async -> Bool = { _, _ in false }
    var confirmFileRestore: () async -> Bool = { false }
    var openWorkingFile: (URL, URL?) async throws -> Void = { url, application in
        if let application {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
                    if let failure { reply.resume(throwing: failure) } else { reply.resume() }
                }
            }
        } else if !NSWorkspace.shared.open(url) { throw StatusFileActionFailure(message: "Could not open " + url.lastPathComponent + ".") }
    }
    lazy var openAlternativeEditor: (URL) async throws -> Void = { [weak self] url in
        guard let self else { throw OperationCancellationFailure.cancelled }
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            AlternativeEditor.open(url, preferences: self.dialogDefaults, permissions: self.access.map { [$0] } ?? []) { failure in
                if let failure { reply.resume(throwing: StatusFileActionFailure(message: failure)) } else { reply.resume() }
            }
        }
    }

    var confirmCancel: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    private var originalAmendMessage = ""
    var confirmUneditedTemplate: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    private let conflictFocusProbes=NSMapTable<NSString,CommitFileInteraction.Probe>(keyOptions:.strongMemory,valueOptions:.weakMemory)
    func registerFileList(_ probe:CommitFileInteraction.Probe,key:String) {conflictFocusProbes.setObject(probe,forKey:key as NSString)}
    func focusConflictFile(key:String,path:String)->Bool {conflictFocusProbes.object(forKey:key as NSString)?.focusFile(path) ?? false}
    var onFocusConflictedFile:(String,String)->Void={_,_ in}
    var confirmConflictedSelection:(([String],OperationCancellation)async->(ignore:Bool,remember:Bool)?)?
    var presentMergeHint:((OperationCancellation)async->Bool?)?
    var confirmUnresolvedConflicts:([String],@escaping (Bool)->Void)->Void = { _,choose in choose(false) }
    var confirmBranchTagCollision:(String,@escaping (Bool)->Void)->Void = { _,choose in choose(false) }
    enum DetachedHeadChoice {case createBranch,continueDetached,cancel}
    var readCommitBranch:((OperationCancellation)async throws->String)?
    var confirmDetachedHead:(OperationCancellation)async->DetachedHeadChoice={_ in .cancel}
    var createDetachedBranch:(OperationCancellation)async->Bool={_ in false}
    var retireDetachedChildren:()->Void={}
    @Published private(set) var preparingDetachedHead=false
    @Published private(set) var detachedHeadWorkPending=false
    @Published var hasDetachedBranch=false
    /// CommitDlg::CheckHeadDetach follows optional branch creation. An explicit
    /// new-branch option is created/switched by the existing commit engine before
    /// commit; failure there aborts, so it cannot produce a detached commit.
    private func prepareDetachedHead(options:CommitOptions,request:UUID,token:OperationCancellation)async throws->Bool {
        guard replaySplit==nil,historyCombine==nil,options.newBranch==nil else{return true}
        detachedHeadWorkPending=true;preparingDetachedHead=true;defer{preparingDetachedHead=false}
        while true {
            let current:String
            if let readCommitBranch {current=try await readCommitBranch(token)}else{current=try await repository.branch(cancellation:token)}
            try validatePreflight(request,token)
            if !current.isEmpty {branch=current;return true}
            let choice=await confirmDetachedHead(token);try validatePreflight(request,token)
            switch choice {
            case .cancel:return false
            case .continueDetached:return true
            case .createBranch:
                guard await createDetachedBranch(token) else {try validatePreflight(request,token);return false}
                try validatePreflight(request,token)
                // The branch dialog can change its switch choice; do not infer
                // an attached HEAD from creation alone. Re-read after release.
            }
        }
    }
    private func cancelDetachedHeadPreparation(closeWindow:Bool,completion:((Bool)->Void)?)->Bool {
        guard preparingDetachedHead,let token=preflightCancellation else{return false}
        guard !pendingReloadCancel,!confirmingQuit || !closeWindow else{completion?(false);return true}
        pendingReloadCancel=true;token.cancel();retireDetachedChildren()
        Task{@MainActor [self] in
            while preparingDetachedHead || detachedHeadWorkPending {try? await Task.sleep(nanoseconds:5_000_000)}
            pendingReloadCancel=false
            guard messageFocusAvailable else{completion?(false);return}
            busy=false;cancel(closeWindow:closeWindow,completion:completion,confirmationAccepted:false)
        };return true
    }
    private var preflightCancellation:OperationCancellation?
    private var providerCommitAttemptTask: Task<Void,Never>?
    private var preflightRequest=UUID()
    private(set) static var activeCommitPreflights=0
    private func validatePreflight(_ request:UUID,_ token:OperationCancellation) throws {
        guard messageFocusAvailable,preflightRequest==request,!token.isCancelled else { throw OperationCancellationFailure.cancelled }
    }
    var fileListFocusKey:String {stagingEnabled ? (stagedDiff ? "staged":"unstaged"):"checkbox"}
    private func focusConflictedFile(_ conflicts:[StatusEntry]) {
        guard let first=visibleEntries.first(where:{ $0.state == .conflicted }) ?? conflicts.first else { return }
        if !visibleEntries.contains(where:{ GitReferenceName.equal($0.path,first.path) }) { showWholeProject=true }
        selection=[first.id];focusedFiles[fileListFocusKey]=first.id
    }
    var confirmMissingIssue: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    var confirmConflictHints: (@escaping (Bool, Bool) -> Void) -> Void = { choose in choose(false, false) }
    enum DirtySubmoduleChoice { case commit, ignore, cancel }
    var confirmDirtySubmodule: (String, @escaping (DirtySubmoduleChoice) -> Void) -> Void = { _, choose in choose(.cancel) }
    var onCommitSubmodule: (URL) -> Void = { _ in }
    enum SignOffChoice { case add, proceed, abort }
    var confirmMissingSignOff: (@escaping (SignOffChoice) -> Void) -> Void = { choose in choose(.abort) }
    @Published var operation: CommitOperation?
    @Published var hasHead = false
    @Published var hasParent = false
    var replaySplit: RebaseSplitState?
    private(set) var historyCombine: HistoryCombinePlan?
    @Published var amend = false {didSet{if amend != oldValue{retireFormReceipts()}}}
    @Published var amendDiffToLastCommit = false {didSet{if amendDiffToLastCommit != oldValue{retireFormReceipts()}}}
    private var nonAmendMessage = ""
    private var amendMessage = ""
    var amendToParent: Bool { amend && !amendDiffToLastCommit }
    @Published var setAuthorDate = false {didSet{if setAuthorDate != oldValue{retireFormReceipts()}}}
    @Published var messageCaretPosition = MessageCaretPosition.at("", utf16Offset: 0)
    @Published var authorDate = Date()
    @Published var resetAuthorDate = false {didSet{if resetAuthorDate != oldValue{retireFormReceipts()}}}
    @Published var messageOnly = false {
        didSet { if messageOnly != oldValue { fileMenuGeneration = UUID();retireFormReceipts() } }
    }
    @Published var doNotAutoselectSubmodules = false {didSet{if doNotAutoselectSubmodules != oldValue{retireFormReceipts()}}}
    @Published var submodules = GitPathSet() { didSet { if submodules != oldValue { fileMenuGeneration = UUID() } } }
    @Published var setAuthor = false {didSet{if setAuthor != oldValue{retireFormReceipts()}}}
    @Published var author = ""
    @Published private(set) var loadingAuthorIdentity = false
    @Published private(set) var loadingAuthorDate = false
    @Published private(set) var loadingAmendMessage = false
    @Published private(set) var amendMessageReadFailed = false
    @Published private(set) var messageFocusRequest = 0
    @Published private(set) var issueFocusRequest=0
    private(set) var appliedMessageFocusRequest = 0
    private(set) var messageFocusAvailable = true
    private var authorGeneration = 0
    private var dateGeneration = 0
    private var amendGeneration = 0
    private var replayAuthorPreset: (enabled: Bool, value: String)?
    private var replayDatePreset: (enabled: Bool, value: Date, reset: Bool)?
    private var authorCancellation: OperationCancellation?
    private var dateCancellation: OperationCancellation?
    private var amendCancellation: OperationCancellation?
    /// Includes cancelled author/date/amend readers after their native owner closes.
    static private(set) var activeMetadataOperations = 0
    var nativeAuthorInputAvailable: Bool { messageFocusAvailable && !inputsBlocked && setAuthor && !loadingAuthorIdentity }
    var nativeNewBranchInputAvailable:Bool {createBranch && canChangeFormOption(.newBranch)}
    var nativeAuthorDateInputAvailable: Bool { messageFocusAvailable && !inputsBlocked && setAuthorDate && !loadingAuthorDate && !(amend && resetAuthorDate) }
    var queryCommitAuthor: ((Bool, OperationCancellation) async throws -> String?)?
    var queryCommitAuthorDate: ((OperationCancellation) async throws -> Date?)?
    var queryAmendMessage: ((OperationCancellation) async throws -> String?)?
    @Published var showUnversioned = true { didSet { if showUnversioned != oldValue { fileMenuGeneration = UUID();retireFormReceipts() } } }
    private let unversionedDefaults: UserDefaults
    var messageEditorPreferences: UserDefaults { dialogDefaults }
    private let dialogDefaults: UserDefaults
    private var selectFilesAutomatically: Bool
    private let doNotAutoselectMissing: Bool
    private var scopeCheckStates=GitPathMap<Bool>()
    @Published private(set) var fileListReportInEnglish=true
    @Published var showWholeProject = true {
        willSet {if newValue != showWholeProject,messageFocusAvailable,!busy {filterPosition = fileListRefresh.begin(preferences:dialogDefaults,selectedIDs:selection)}}
        didSet {if showWholeProject != oldValue{retireFormReceipts()};updateScopeTitle();if let position = filterPosition {filterPosition = nil;restoreVisibleFilePosition(position)}}
    }
    @Published var scopePaths: [String] = [] { didSet { updateScopeTitle() } }
    @Published var busy = false {didSet{if busy != oldValue{retireFormReceipts()}}}
    @Published var confirmingQuit = false {didSet{
        guard confirmingQuit != oldValue else{return}
        retireFormReceipts();metadataEpoch=UUID(); guiPatch?.confirmingQuit = confirmingQuit
        if confirmingQuit {
            if loadingAmendMessage {amendMessageReadFailed=true}
            authorCancellation?.cancel();dateCancellation?.cancel();amendCancellation?.cancel();importedMessageCancellation?.cancel()
        }
    }}
    @Published var error: String?
    private var diffSession: FileListComparisonSession?
    var onUnifiedDiff: ((Data, Bool) async throws -> Void)?
    weak var comparisonWindow: NSWindow? { didSet { updateScopeTitle() } }
    var unifiedWindow: PatchWindowController?
    var unifiedViewerBusy: Bool { unifiedWindow?.model.busy == true || unifiedWindow?.window?.attachedSheet != nil }
    var showViewPatch: () -> Void = {}
    var showPartial: (Bool) -> Void = { _ in }
    var refreshPartial: () -> Void = {}
    var closePartial: () -> Void = {}
    var close: () -> Void = {}
    var onCommitted: (String) -> Void = { _ in }
    var onPush: (CommitPushContinuation) -> Void = { _ in }
    var onPull: () -> Void = {}
    var onCreateTag: () -> Void = {}
    var onSVNDCommit: () -> Void = {}
    var onCommitProgress: ((CommitProgressWindowModel) -> Void)?
    @Published private(set) var commitProgress: CommitProgressWindowModel?
    enum CompletionAction: String, CaseIterable {
        case commit = "Commit", recommit = "ReCommit", push = "Commit & Push"
        var sourceIndex: Int { switch self { case .commit: return 0; case .recommit: return 1; case .push: return 2 } }
        init(sourceIndex: Int) { self = Self.allCases.first { $0.sourceIndex == sourceIndex } ?? .commit }
    }
    @Published private(set) var completionAction: CompletionAction = .commit
    var currentCompletionAction: CompletionAction { replaySplit == nil && historyCombine == nil ? completionAction : .commit }
    func commitCurrentAction() { commit(currentCompletionAction) }
    private func rememberCompletionAction(_ action: CompletionAction) {
        guard replaySplit == nil, historyCombine == nil else { return }
        dialogDefaults.set(action.sourceIndex, forKey: "CommitLastAction")
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, unversionedDefaults: UserDefaults = .standard, dialogDefaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.unversionedDefaults = unversionedDefaults
        self.dialogDefaults = dialogDefaults
        gitGuiInterface = dialogDefaults.bool(forKey: "TurtleGit.Commit.GitGuiInterface")
        templateFileAccess = CommitTemplateFileAccess(preferences: dialogDefaults)
        queryLFSOwners = { try await repository.lfsLocks(cancellation: $0) }
        queryHistoryIssue = { try await repository.issueFieldValue(properties: $0, message: $1, cancellation: $2) }
        // Display reloads must not create optional index locks: those are watched
        // filesystem events and can otherwise restart other status dialogs.
        queryCommitStatus = { try await repository.commitDialogStatus(amendToParent: $0, cancellation: $1, refreshIndex: false) }
        queryStagingStates = { try await repository.commitStagingStates(for: $0, base: $1, cancellation: $2) }
        fileColumns = .load(from: dialogDefaults)
        completionAction = CompletionAction(sourceIndex: dialogDefaults.integer(forKey: "CommitLastAction"))
        selectFilesAutomatically = dialogDefaults.object(forKey: "SelectFilesForCommit") as? Bool ?? true
        doNotAutoselectMissing = dialogDefaults.bool(forKey: "AutoselectMissingFiles")
        showUnversioned = unversionedDefaults.object(forKey: "AddBeforeCommit") == nil || unversionedDefaults.bool(forKey: "AddBeforeCommit")
        keepChangelists = dialogDefaults.bool(forKey: "Commit.KeepChangelists")
        doNotAutoselectSubmodules = dialogDefaults.bool(forKey: "Commit.DoNotAutoselectSubmodules")
        formattingEnabled = dialogDefaults.object(forKey: "StyleCommitMessages") as? Bool ?? true
    }
    func setShowUnversioned(_ enabled: Bool) {
        guard messageFocusAvailable, !inputsBlocked else { return }
        let position = fileListRefresh.begin(preferences:dialogDefaults,selectedIDs:selection)
        showUnversioned = enabled
        unversionedDefaults.set(enabled, forKey: "AddBeforeCommit");restoreVisibleFilePosition(position)
    }
    func setShowWholeProject(_ value:Bool) {
        guard canChangeFormOption(.wholeProject),value != showWholeProject else{return}
        reload(wholeProject:value)
    }
    private func restoreVisibleFilePosition(_ position:FileListRefreshCoordinator.Ticket) {
        if !position.remember {selection = []}
        Task { [self] in await fileListRefresh.restore(position,ids:visibleFileRowIDs);fileListRefresh.finish(position) }
    }
    static let noChangesMessage="No files were changed or added since\nthe last commit."
    var fileListEmptyMessage:String? {
        guard visibleEntries.isEmpty else {return nil}
        if pendingReloadCancel {return "Cancelling…"}
        if preparingCommitIdentity {return "Checking Git user data…"}
        if reloadCancellation != nil {return hasLoaded ? "Refreshing changes…":"Loading changes…"}
        if let fileListReadError {return "Could not load changes.\n"+fileListReadError}
        if fileListReadCancelled {return "Refresh cancelled. Press F5 to retry."}
        return Self.noChangesMessage
    }
    private var hasHiddenUnversionedFiles:Bool {
        !showUnversioned && entries.contains {entry in
            entry.state == .untracked && (showWholeProject || scopePaths.contains {GitReferenceName.equal($0,entry.path) || entry.path.utf8.starts(with:($0+"/").utf8)})
        }
    }
    func offerUnversionedFiles() {
        guard unversionedPromptPending else {return}
        guard messageFocusAvailable,!inputsBlocked,error==nil else {return}
        guard visibleEntries.isEmpty,hasHiddenUnversionedFiles,operation != .merge,fileListReadError==nil else {unversionedPromptPending=false;return}
        if let remembered=dialogDefaults.object(forKey:"NothingToCommitShowUnversioned") as? NSNumber,[6,7].contains(remembered.intValue) {
            unversionedPromptPending=false
            if remembered.intValue==6 {showUnversioned=true}
            return
        }
        guard let presentUnversionedFiles else {return}
        let request=UUID();unversionedPromptRequest=request;unversionedPromptVisible=true;Self.activePreferenceOperations += 1
        Task { [self,access] in
            defer {Self.activePreferenceOperations -= 1;withExtendedLifetime(access){};if unversionedPromptRequest==request {unversionedPromptVisible=false}}
            let response=await presentUnversionedFiles()
            guard messageFocusAvailable,unversionedPromptRequest==request,!confirmingQuit,visibleEntries.isEmpty,hasHiddenUnversionedFiles,operation != .merge else {return}
            guard let response else {return}
            unversionedPromptPending=false
            if response.remember {dialogDefaults.set(response.show ? 6:7,forKey:"NothingToCommitShowUnversioned")}
            // Source StatusThread changes the live checkbox here; its shared
            // AddBeforeCommit preference is saved only after a commit attempt.
            if response.show {showUnversioned=true}
        }
    }
    var visibleFileRowIDs:[String] {
        let ignored = GitPathSet(indexFlagFiles.filter {$0.assumeUnchanged || $0.skipWorktree}.map {$0.entry.path})
        return StatusListGroups.rows(entries:sortedFiles(visibleEntries,statistics:statistics),changelists:changelists,locallyIgnored:ignored).map(\.id)
    }
    var visibleEntries: [StatusEntry] {
        entries.filter { entry in
            entry.state != .ignored && (showUnversioned || entry.state != .untracked) &&
                (entry.staged || showWholeProject || scopePaths.contains { GitReferenceName.equal($0,entry.path) || entry.path.utf8.starts(with:($0 + "/").utf8) })
        }
    }
    func sortedFiles(_ files: [StatusEntry], statistics: GitPathMap<CommitFile>) -> [StatusEntry] {
        guard let comparator = fileSortOrder.first else { return files }
        return files.map { CommitSortableRow(row: .file($0), statistics: statistics[$0.path], isDirectory: submodules.contains($0.path) || fileMetadata[$0.path]?.isDirectory == true, metadata: fileMetadata[$0.path], lfsOwner: lfsOwners[$0.path] ?? "") }
            .sorted(using: comparator).compactMap(\.entry)
    }
    @discardableResult func saveFileColumnLayout(order: [StatusListColumn], widths: [StatusListColumn: Double]) -> Bool {
        guard messageFocusAvailable, !inputsBlocked else { return false }
        let next = StatusListColumnSettings(visible: fileColumns.visible, order: order, widths: widths)
        if fileColumns != next { fileColumns = next; fileColumns.save(to: dialogDefaults) }
        return true
    }
    func setFileColumn(_ column: StatusListColumn, visible: Bool) {
        guard messageFocusAvailable, column != .path, availableFileColumns.contains(column), !inputsBlocked else { return }
        if visible { fileColumns.visible.insert(column) } else { fileColumns.visible.remove(column) }
        fileColumns.save(to: dialogDefaults)
        if column == .lfsOwner { if visible { reload() } else { lfsOwners = [:]; lfsLockedPaths = []; lfsOwnershipKnown = false } }
    }
    @discardableResult func resetFileColumns() -> Bool {
        guard messageFocusAvailable, !inputsBlocked else { return false }
        fileColumns = StatusListColumnSettings(); fileColumns.save(to: dialogDefaults); return true
    }
    func requestResetFileColumns(choose: @escaping () async -> Bool, onAccepted: @escaping () -> Void) {
        guard messageFocusAvailable, !inputsBlocked else { return }
        busy = true
        Task {
            defer { busy = false }
            guard await choose(), messageFocusAvailable, !confirmingQuit else { return }
            fileColumns = StatusListColumnSettings(); fileColumns.save(to: dialogDefaults)
            onAccepted()
        }
    }
    func setFileSortOrder(_ order: [CommitFileSort]) {
        guard messageFocusAvailable, !inputsBlocked else { return }
        // The source retains one column, with its path tie-break, rather than
        // accumulating old columns as additional sorting priorities.
        fileSortOrder = Array(order.prefix(1))
    }
    // Upstream keeps m_Action, list groups and line statistics until F5, while
    // m_stagingStatus changes independently. Do not replace the displayed rows
    // with porcelain records after each checkbox or partial patch operation.
    @Published private(set) var stagingStateNeedsRefresh = false
    @Published private var stagingStates: GitPathMap<NSControl.StateValue>?
    func stagingState(_ entry: StatusEntry) -> NSControl.StateValue {
        if let stagingStates { return stagingStates[entry.path] ?? .off }
        if entry.state == .conflicted {return .off}
        return entry.staged ? (entry.worktree == " " ? .on : .mixed) : .off
    }
    func isStaged(_ entry: StatusEntry) -> Bool { stagingState(entry) != .off }
    var stagedEntries: [StatusEntry] { visibleEntries.filter { isStaged($0) } }
    var unstagedEntries: [StatusEntry] { visibleEntries.filter { stagingState($0) != .on } }

    /// Reuse the owned reload lifetime without reloading groups, metadata, hooks,
    /// message completions, preferences or LFS locks. Publish one coherent index
    /// snapshot only after every cancellable read has completed.
    func refreshStagingState(refreshPatch: Bool = true) {
        let repository=self.repository.capturingDiffBackend(preferences:dialogDefaults)
        guard stagingEnabled else { reload(); return }
        guard messageFocusAvailable, !busy, !pendingReloadCancel else { return }
        let position = fileListRefresh.begin(preferences:dialogDefaults,selectedIDs:selection)
        fileMenuGeneration = UUID(); busy = true; stagingStateNeedsRefresh = true
        Self.activeFileOperations += 1;pendingFileOperations += 1
        let token = OperationCancellation(); reloadCancellation = token
        let base = comparisonBase, retainedEntries = entries
        reloadTask = Task {
            defer {
                Self.activeFileOperations -= 1;pendingFileOperations -= 1;fileListRefresh.finish(position)
                if reloadCancellation === token { reloadCancellation = nil; reloadTask = nil; busy = false }
                withExtendedLifetime(access) {}
            }
            do {
                try validateRestoreAccess()
                let current = try await readReload(token) { try await queryStagingStates(retainedEntries, base, token) }
                let staged = try await readReload(token) { try await repository.stagingFiles(staged: true, base: base, cancellation: token) }
                let unstaged = try await readReload(token) { try await repository.stagingFiles(staged: false, cancellation: token) }
                try await recoverMissingStagedFiles(retainedEntries, repository: repository, token: token,
                    scope: scopePaths, wholeProject: showWholeProject)
                stagingStates = current.mapValues { state in
                    switch state { case .unstaged: return .off; case .partial: return .mixed; case .staged: return .on }
                }
                stagedStatistics = GitPathMap(staged.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                unstagedStatistics = GitPathMap(unstaged.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
                stagingStateNeedsRefresh = false
                if refreshPatch { refreshPartial() }
                if !position.remember {selection = []}
                await fileListRefresh.restore(position,ids:visibleFileRowIDs);try token.check()
            } catch {
                if messageFocusAvailable, reloadCancellation === token, !token.isCancelled { self.error = "Could not refresh staging. Press F5 to reload before committing.\n\n" + error.localizedDescription }
            }
        }
    }
    private(set) static var activeReloads = 0
    let fileListRefresh = FileListRefreshCoordinator()
    let missingStagedRecovery = MissingStagedFileRecoverySession()
    private var filterPosition:FileListRefreshCoordinator.Ticket?
    private(set) static var activeFileOperations = 0
    private(set) var pendingFileOperations=0
    var fileWorkPending:Bool {pendingFileOperations>0}
    private var fileMenuGeneration = UUID()
    private var activeFileMenu: StatusFileMenuSnapshot?
    private var fileOperationToken: OperationCancellation?
    @Published private(set) var fileOperationTitle = ""
    @Published private(set) var fileOperationCancelling = false
    func fileMenu(_ ids: some Sequence<String>, mark: String? = nil, orderedEntries: [StatusEntry]? = nil) -> StatusFileMenuSnapshot { let ids = GitPathSet(ids);
        let selected = (orderedEntries ?? visibleEntries).filter { ids.contains($0.id) }
        let focused = entries.first { GitReferenceName.equal($0.id,mark) } ?? selected.first
        func directory(_ entry: StatusEntry) -> Bool { submodules.contains(entry.path) || fileMetadata[entry.path]?.isDirectory == true }
        var commands: [StatusFileCommand] = []
        if selected.count == 2, selected.allSatisfy({ !directory($0) }) { commands.append(.compareTwo) }
        if let entry = selected.first, selected.count == 1, ![FileState.untracked, .ignored].contains(entry.state) {
            commands.append(.log)
            if directory(entry) { commands.append(.submoduleLog) }
            if entry.originalPath != nil { commands.append(.oldNameLog) }
            if !directory(entry), entry.index != "A", entry.worktree != "A", entry.index != "D" { commands.append(.blame) }
        }
        if !selected.isEmpty, let focused, focused.state != .deleted, focused.worktree != "D" { commands.append(.export) }
        if let entry = selected.first, selected.count == 1, entry.state != .deleted, entry.worktree != "D", !directory(entry) { commands += [.editor, .open, .openWith] }
        if let entry = selected.first, selected.count == 1, entry.index != "D" { commands.append(.reveal) }
        if focused?.canDeleteFromStatusList == true { commands.append(.delete) }
        return StatusFileMenuSnapshot(generation: fileMenuGeneration, entries: selected, mark: focused, commands: commands, markIsDirectory: focused.map(directory) ?? false)
    }
    private func acceptsFileMenu(_ snapshot: StatusFileMenuSnapshot, duringOperation: Bool = false) -> Bool {
        guard !messageOnly,messageFocusAvailable,!savingPreferences,!mergeHintVisible,!stagingHintVisible,!unversionedPromptVisible,!confirmingQuit,!pendingReloadCancel,duringOperation || !busy,
              snapshot.generation == fileMenuGeneration, !snapshot.entries.isEmpty else { return false }
        let current = GitPathMap(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        return snapshot.entries.allSatisfy { current[$0.path] == $0 } && (snapshot.mark.map { current[$0.path] == $0 } ?? true)
    }
    func withFileMenu(_ snapshot: StatusFileMenuSnapshot, perform: () -> Void) {
        guard acceptsFileMenu(snapshot) else { return }
        let previous = activeFileMenu; activeFileMenu = snapshot
        defer { activeFileMenu = previous }; perform()
    }
    private func isFileOperationLive(_ token: OperationCancellation) -> Bool {
        messageFocusAvailable && fileOperationToken === token && !token.isCancelled && !Task.isCancelled
    }
    @discardableResult func cancelFileOperation() -> Bool {
        guard let fileOperationToken else { return false }
        fileOperationCancelling = true; fileOperationToken.cancel(); return true
    }
    private func runFileOperation(_ title: String, operation: @escaping (OperationCancellation, StatusFileMenuSnapshot?) async throws -> Void, completed: @escaping () -> Void = {}, failed: @escaping () -> Void = {}) {
        guard messageFocusAvailable, !inputsBlocked else { return }
        let snapshot = activeFileMenu
        guard snapshot.map({ acceptsFileMenu($0) }) ?? true else { return }
        let token = OperationCancellation(); fileOperationToken = token
        busy = true; fileOperationCancelling = false; fileOperationTitle = title; Self.activeFileOperations += 1;pendingFileOperations += 1
        Task {
            defer {
                Self.activeFileOperations -= 1;pendingFileOperations -= 1
                if fileOperationToken === token { fileOperationToken = nil; busy = false; fileOperationCancelling = false; fileOperationTitle = "" }
                withExtendedLifetime(access) {}
            }
            do {
                try validateRestoreAccess(); try await operation(token, snapshot)
                guard messageFocusAvailable, fileOperationToken === token else { return }
                finishFileOperation(token)
                if token.isCancelled { failed(); self.error = "Operation cancelled. Any completed changes are retained." }
                else { completed() }
            } catch {
                guard messageFocusAvailable, fileOperationToken === token else { return }
                let diagnostic = token.isCancelled ? "Operation cancelled. Any completed changes are retained." : error.localizedDescription
                finishFileOperation(token); failed(); self.error = diagnostic
            }
        }
    }
    private func finishFileOperation(_ token: OperationCancellation) {
        guard fileOperationToken === token else { return }
        fileOperationToken = nil; busy = false; fileOperationCancelling = false; fileOperationTitle = ""
    }
    private func acceptsPendingFileMenu(_ snapshot: StatusFileMenuSnapshot?, token: OperationCancellation) -> Bool {
        isFileOperationLive(token) && (snapshot.map { acceptsFileMenu($0, duringOperation: true) } ?? true)
    }
    func fileAction(_ command: StatusFileCommand, snapshot: StatusFileMenuSnapshot, permanently: Bool = false) {
        guard snapshot.commands.contains(command) else { return }
        withFileMenu(snapshot) {
            let paths = snapshot.entries.map(\.path)
            switch command {
            case .compareTwo: onCompareTwoFiles(paths)
            case .log: onFileLog(paths[0])
            case .oldNameLog: if let old = snapshot.entries.first?.originalPath { onFileLog(old) }
            case .submoduleLog: showSubmoduleLog(paths[0])
            case .blame: onFileBlame(paths[0])
            case .reveal:
                var location = repository.root.appendingPathComponent(paths[0])
                while !FileManager.default.fileExists(atPath: location.path), location.path != repository.root.path { location.deleteLastPathComponent() }
                NSWorkspace.shared.activateFileViewerSelecting([location])
            case .export:
                runFileOperation("Exporting working files…", operation: { [self] token, captured in
                    guard let folder = await chooseExportFolder(paths), acceptsPendingFileMenu(captured, token: token) else { return }
                    let scoped = folder.startAccessingSecurityScopedResource(); defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                    _ = try await repository.exportWorkingFiles(paths: paths, to: folder, cancellation: token)
                })
            case .delete: deleteFiles(snapshot.entries, selectionMark: snapshot.mark, permanently: permanently)
            case .editor, .open, .openWith:
                runFileOperation(command.rawValue, operation: { [self] token, captured in
                    let application = command == .openWith ? await chooseApplication(paths[0]) : nil
                    guard command != .openWith || application != nil, acceptsPendingFileMenu(captured, token: token) else { return }
                    let url = repository.root.appendingPathComponent(paths[0])
                    if command == .editor { try await openAlternativeEditor(url) } else { try await openWorkingFile(url, application) }
                })
            }
        }
    }
    func showSubmoduleLog(_ path: String) {
        guard submodules.contains(path) else { return }
        runFileOperation("Reading submodule checkout…", operation: { [self] token, captured in
            let child = try await submoduleLog.load(path, cancellation: token)
            guard acceptsPendingFileMenu(captured, token: token) else { return }; onSubmoduleLog(child)
        })
    }

    func openFile(_ path: String, application: URL? = nil) {
        runFileOperation("Open", operation: { [self] token, captured in
            guard acceptsPendingFileMenu(captured, token: token) else { return }
            try await openWorkingFile(repository.root.appendingPathComponent(path), application)
        })
    }

    func exportFiles(_ paths: [String], to folder: URL) {
        runFileOperation("Exporting working files…", operation: { [self] token, captured in
            guard acceptsPendingFileMenu(captured, token: token) else { return }
            let scoped = folder.startAccessingSecurityScopedResource(); defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            _ = try await repository.exportWorkingFiles(paths: paths, to: folder, cancellation: token)
        })
    }

    func openInEditor(_ path: String) {
        runFileOperation("View revision in alternative editor", operation: { [self] token, captured in
            guard acceptsPendingFileMenu(captured, token: token) else { return }
            try await openAlternativeEditor(repository.root.appendingPathComponent(path))
        })
    }

    enum CopyFileInformation: String, CaseIterable {
        case fullPaths = "Full paths", relativePaths = "Relative paths", names = "File/folder names", all = "Copy all information to clipboard"
    }
    func copyFiles(_ selected: [StatusEntry], information: CopyFileInformation, staged: Bool?) {
        let stats = staged.map { $0 ? stagedStatistics : unstagedStatistics } ?? statistics
        let copy: StatusListCopy
        switch information {
        case .fullPaths: copy = .fullPaths
        case .relativePaths: copy = .relativePaths
        case .names: copy = .names
        case .all: copy = .all
        }
        copyFileText(selected, statistics: stats, copy: copy)
    }
    func copyFileText(_ selected: [StatusEntry], statistics: GitPathMap<CommitFile>, copy: StatusListCopy) {
        guard fileListAvailable,!selected.isEmpty else { return }
        let text = StatusListClipboard.text(selected, root: repository.root, statistics: statistics, copy: copy, metadata: fileMetadata, lfsOwners: lfsOwners, visibleColumns: visibleFileColumns, label:FileListLabels.caption)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private func validateRestoreAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    var onRevert: ([StatusEntry], Bool, Bool, @escaping (Bool) -> Void) -> Void = { _, _, _, done in done(false) }
    func revertFiles(_ selected: [StatusEntry]) {
        guard !busy, !confirmingQuit, !selected.isEmpty else { return }
        if selected.contains(where: { [.modified, .conflicted].contains($0.state) }) {
            let alert = NSAlert()
            alert.messageText = "Are you sure you want to revert \(selected.count) item(s)?"
            alert.informativeText = "You will lose ALL changes since the last update! Existing replaced file contents are moved to Trash. Added files remain on disk as unversioned files."
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        guard messageFocusAvailable, activeFileMenu.map({ acceptsFileMenu($0) }) ?? true else { return }
        busy = true
        onRevert(selected, amend, amendDiffToLastCommit) { [weak self] succeeded in
            guard let self, self.messageFocusAvailable else { return }
            if succeeded { self.checked.subtract(selected.map(\.path)); self.selection.subtract(selected.map(\.path)) }
            self.busy = false; self.reload(); self.refreshPartial()
        }
    }
    func markForRestore(_ paths: some Sequence<String>) { let paths = GitPathSet(paths);
        guard !paths.isEmpty else { return }
        runFileOperation("Saving working file copies…", operation: { [self] token, _ in
            for path in paths.sorted() where restoreCopies[path] == nil {
                let copy = try await repository.captureWorkingFileRestoreCopy(path: path, cancellation: token)
                guard isFileOperationLive(token) else { return }; restoreCopies[path] = copy
            }
        })
    }

    private func restoreSavedCopies(_ paths: some Sequence<String>, cancellation: OperationCancellation? = nil) async throws { let paths = GitPathSet(paths);
        guard paths.contains(where: { restoreCopies[$0] != nil }) else { return }
        try validateRestoreAccess()
        for path in paths.sorted() {
            try cancellation?.check()
            guard messageFocusAvailable else{throw OperationCancellationFailure.cancelled}
            guard let copy = restoreCopies[path] else { continue }
            if let restoreWorkingCopy {try await restoreWorkingCopy(copy,cancellation)}else{try await repository.restoreWorkingFile(copy, cancellation: cancellation)}
            try cancellation?.check()
            guard messageFocusAvailable else{throw OperationCancellationFailure.cancelled}
            restoreCopies.removeValue(forKey: path)
        }
    }
    func restoreNow(_ paths: some Sequence<String>) { let paths = GitPathSet(paths);
        guard paths.contains(where: { restoreCopies[$0] != nil }) else { return }
        var restored = false
        runFileOperation("Restoring working copies…", operation: { [self] token, captured in
            guard await confirmFileRestore(), acceptsPendingFileMenu(captured, token: token) else { return }
            try await restoreSavedCopies(paths, cancellation: token); restored = true
        }, completed: { [self] in if restored { reload() } }, failed: { [self] in reload() })
    }

    private func chooseSavedCopies(allowCancel: Bool) async -> RestoreChoice {
        await withCheckedContinuation { continuation in
            chooseRestoreCopies(allowCancel) { continuation.resume(returning: $0) }
        }
    }
    func setFlags(_ action: IndexFlagAction, files: [WorkingTreeFile], selectionMark: WorkingTreeFile) {
        guard fileListAvailable, !files.isEmpty, action.isAvailable(for: [selectionMark]), confirmIndexFlags(action) else { return }
        runFileOperation(action.rawValue, operation: { [self] token, _ in
            try await repository.setIndexFlags(action, paths: files.map(\.id), markedPath: selectionMark.id, cancellation: token)
        }, completed: { [self] in reload() }, failed: { [self] in reload() })
    }

    func moveToStage(_ paths: some Sequence<String>, staged: Bool,receipt:FileCheckReceipt? = nil) { let paths = GitPathSet(paths);
        guard acceptsFileCheck(receipt) else { return }
        let valid = entries.filter { paths.contains($0.id) }
        guard !valid.isEmpty else { return }
        let amendToParent = self.amendToParent
        runFileOperation(staged ? "Staging selected files…" : "Unstaging selected files…", operation: { [self] token, _ in
            try await repository.setCommitFilesStaged(valid, staged: staged, amendToParent: amendToParent, cancellation: token)
        }, completed: { [self] in refreshStagingState() }, failed: { [self] in refreshStagingState() })
    }

    func canLockLFS(_ selected: [StatusEntry]) -> Bool {
        LFSLockingSelection.isAvailable(selected, hasLFS: hasLFS, root: repository.root, directories: submodules)
    }
    func lfsActions(_ selected: [StatusEntry]) -> [LFSLockMenuAction] {
        guard canLockLFS(selected) else { return [] }
        return LFSLockMenu.actions(paths: selected.map(\.path), ownersVisible: visibleFileColumns.contains(.lfsOwner), lockedPaths: lfsLockedPaths, ownershipKnown: lfsOwnershipKnown)
    }
    func setLFSLocked(_ ids: some Sequence<String>, locked: Bool) { let ids = GitPathSet(ids);
        guard fileListAvailable else { return }
        let selected = entries.filter { ids.contains($0.id) }
        guard selected.count == ids.count, lfsActions(selected).contains(locked ? .lock : .unlock) else { return }
        busy = true
        if !onLFSOperation(selected.map(\.path), locked) { busy = false }
    }
    var presentAddProgress:(([String],WorkingFileAddMode,GitLibGit2Configuration,OperationCancellation)async->Bool)?
    func addFiles(_ selected: [StatusEntry], mode: WorkingFileAddMode) {
        let paths = selected.map(\.path); guard fileListAvailable,!paths.isEmpty else { return }
        let backend = GitLibGit2Configuration.load(from: dialogDefaults)
        runFileOperation(mode.rawValue, operation: { [self] token, _ in
            if let presentAddProgress{guard await presentAddProgress(paths,mode,backend,token) else{return}}
            else{try await repository.addWorkingFiles(paths: paths, mode: mode, cancellation: token, backend: backend,preservePathOrder:true)}
            guard isFileOperationLive(token) else { return }; checked.formUnion(paths)
        }, completed: { [self] in reload() }, failed: { [self] in reload() })
    }

    func deleteFiles(_ selected: [StatusEntry], selectionMark: StatusEntry? = nil, permanently: Bool) {
        guard fileListAvailable,!selected.isEmpty else { return }
        var changed = false
        runFileOperation(permanently ? "Deleting working files…" : "Moving working files to Trash…", operation: { [self] token, captured in
            guard await confirmFileDeletion(selected.map(\.path), permanently), acceptsPendingFileMenu(captured, token: token) else { return }
            _ = try await repository.deleteWorkingFiles(selected, selectionMark: selectionMark, permanently: permanently, cancellation: token)
            changed = true
            guard isFileOperationLive(token) else { return }
            checked.subtract(selected.map(\.path)); selection.subtract(selected.map(\.path))
        }, completed: { [self] in if changed { reload() } }, failed: { [self] in reload() })
    }

    func newChangelist(_ selected: [StatusEntry]) {
        guard fileListAvailable, !selected.isEmpty else { return }
        changelistMenu = activeFileMenu ?? fileMenu(GitPathSet(selected.map(\.id)))
        changelistPaths = selected.map(\.path); changelistName = ""; creatingChangelist = true
    }
    func createChangelist() {
        guard messageFocusAvailable, !changelistName.isEmpty, let captured = changelistMenu, acceptsFileMenu(captured) else { cancelChangelist(); return }
        let paths = changelistPaths, name = changelistName
        creatingChangelist = false; changelistPaths = []; changelistName = ""
        changelistMenu = nil
        withFileMenu(captured) { moveToChangelist(paths, name: name) }
    }
    func cancelChangelist() { changelistMenu = nil; creatingChangelist = false; changelistPaths = []; changelistName = "" }
    func saveKeepChangelists(_ value: Bool) {
        guard messageFocusAvailable, !inputsBlocked else { return }
        keepChangelists = value; dialogDefaults.set(value, forKey: "Commit.KeepChangelists")
    }
    var colorPreferences: UserDefaults { dialogDefaults }
    func setDoNotAutoselectSubmodules(_ disabled: Bool) {
        guard messageFocusAvailable, !inputsBlocked else { return }
        doNotAutoselectSubmodules = disabled
        dialogDefaults.set(disabled, forKey: "Commit.DoNotAutoselectSubmodules")
        // The source keeps this policy enabled in staging mode. Changing an
        // automatic-selection preference must never stage/unstage a gitlink.
        guard !stagingEnabled else {return}
        if disabled { checked.subtract(submodules) }
        else { check { submodules.contains($0.path) } }
    }
    func rememberTemplateProceed() {
        guard messageFocusAvailable else { return }
        dialogDefaults.set(true, forKey: "Commit.TemplateNotEdited.Proceed")
    }
    func moveToChangelist(_ paths: [String], name: String?) {
        guard fileListAvailable,!paths.isEmpty else { return }
        let staging = stagingEnabled
        runFileOperation("Moving to changelist…", operation: { [self] token, _ in
            let saved = try await repository.assignChangelist(paths: paths, name: name, cancellation: token)
            guard isFileOperationLive(token) else { return }; changelists = saved
            if name == GitChangelists.ignored {
                checked.subtract(paths)
                if staging {
                    do { try await repository.unstage(paths, cancellation: token) }
                    catch { throw StatusFileActionFailure(message: "The changelist was saved, but unstaging its paths failed.\n\n" + error.localizedDescription) }
                }
            }
        }, completed: { [self] in reload() }, failed: { [self] in reload() })
    }

    private func updateScopeTitle() {
        let location = RepositoryPresentationSettings.scopedLocation(repository: repository.root, paths: scopePaths, wholeProject: showWholeProject)
        RepositoryWindowTitles.set(comparisonWindow, repository: repository.root, location: location, dialog: "Commit", preferences: dialogDefaults)
    }
    func fileHelp(_ entry: StatusEntry) -> String {
        let origin = entry.originalPath.map { "Renamed from " + $0 } ?? ""
        return changelists.name(for: entry.path).map { origin + (origin.isEmpty ? "" : "\n") + "Changelist: " + $0 } ?? origin
    }
    var checkedPathsForCommit: GitPathSet { GitPathSet(visibleEntries.filter { checked.contains($0.id) }.map(\.path)) }
    var canCommit: Bool { messageFocusAvailable && !stagingStateNeedsRefresh && !savingPreferences && !mergeHintVisible && !stagingHintVisible && !unversionedPromptVisible && !issueProviderBusy && !pendingReloadCancel && !busy && !confirmingQuit && !loadingAuthorIdentity && !loadingAuthorDate && !loadingAmendMessage && !loadingImportedMessage && (!amend || !amendMessageReadFailed) && loadedMessage && changelistsLoaded && (messageOnly || (stagingEnabled ? entries.contains(where: { isStaged($0) }) || operation == .merge || amend : !checkedPathsForCommit.isEmpty || operation == .merge || (amend && amendDiffToLastCommit))) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= projectSettings.minimumLength && (!createBranch || !newBranch.isEmpty) && (!setAuthor || !author.isEmpty) }
    func didRename(_ source: String, to destination: String) {
        func moved(_ path: String) -> String { GitReferenceName.equal(path,source) ? destination : path.utf8.starts(with:(source + "/").utf8) ? destination + path.dropFirst(source.count) : path }
        checked = GitPathSet(checked.map(moved)); selection = GitPathSet(selection.map(moved)); scopePaths = scopePaths.map(moved); reload()
    }
    func loadHistoryCombine(_ plan: HistoryCombinePlan, date: RebaseSquashDate) {
        invalidateMetadataLoads(); historyCombine = plan
        createBranch = false; newBranch = ""
        amend = true; amendDiffToLastCommit = plan.lastParentCount != 1
        message = plan.message; amendMessage = plan.message; originalAmendMessage = plan.message
        showWholeProject = true; selectFilesAutomatically = true
        setAuthorDate = true; authorDate = CommitAuthorDateControl.loaded(date == .first ? plan.lastAuthorDate : date == .latest ? plan.firstAuthorDate : Date(),retainingDay:authorDate)
        resetAuthorDate = date == .current
        replayDatePreset = (setAuthorDate, authorDate, resetAuthorDate)
        reload(paths: ["."])
    }
    func loadReplaySplit(_ split: RebaseSplitState, message: String) {
        invalidateMetadataLoads()
        appliedMessageFocusRequest = messageFocusRequest
        replaySplit = split; amend = split.conflictRecovery == true || split.parts == 0; amendDiffToLastCommit = split.conflictRecovery == true
        self.message = split.conflictRecovery == true || split.parts == 0 ? message : ""
        if split.parts == 0, let date = split.squashDate {
            setAuthor = true; author = split.firstAuthor
            if date != .current, let value = ISO8601DateFormatter().date(from: split.firstDate) { setAuthorDate = true; authorDate = CommitAuthorDateControl.loaded(value,retainingDay:authorDate) }
            else if date == .current { setAuthorDate = true; resetAuthorDate = true }
            // Suppress only the onChange generated by installing caller
            // presets. Later user checkbox changes still run normal handlers.
            replayAuthorPreset = (setAuthor, author)
            if setAuthorDate { replayDatePreset = (setAuthorDate, authorDate, resetAuthorDate) }
        }
        reload(paths: ["."])
    }
    let workingDragOrigin = UUID().uuidString
    func captureWorkingDrag(_ orderedPaths:[String])->WorkingFileListDrag? {
        guard fileListAvailable,hasLoaded,!orderedPaths.isEmpty,
              comparisonWindow?.attachedSheet==nil,NSApp.modalWindow==nil,
              GitPathSet(orderedPaths).count==orderedPaths.count else{return nil}
        let lookup=GitPathMap(uniqueKeysWithValues:visibleEntries.map{($0.path,$0)})
        let selected=orderedPaths.compactMap{lookup[$0]}
        guard selected.count==orderedPaths.count,orderedPaths.allSatisfy({selection.contains($0)}) else{return nil}
        let directories=GitPathSet(selected.filter{submodules.contains($0.path) || statistics[$0.path]?.isSubmodule==true || fileMetadata[$0.path]?.isDirectory==true}.map(\.path))
        return FileListDrag.workingSelection(repository:repository,access:access,entries:selected,
            directories:directories,backend:GitLibGit2Configuration.load(from:dialogDefaults),origin:workingDragOrigin)
    }
    var canReceiveFileDrop: Bool { messageFocusAvailable && !inputsBlocked && !messageOnly && hasLoaded }
    @discardableResult func receiveFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canReceiveFileDrop, !FileListDrag.isOwnWorkingDrop(providers:providers,origin:workingDragOrigin), !providers.isEmpty, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        busy = true; let token = OperationCancellation(); reloadCancellation = token
        Self.activeFileDrops += 1
        reloadTask = Task {
            var refresh = false
            defer {
                Self.activeFileDrops -= 1
                if reloadCancellation === token {
                    reloadCancellation = nil; reloadTask = nil; busy = false
                    if refresh && messageFocusAvailable && !pendingReloadCancel { reload() }
                }
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                var urls: [URL] = []
                for provider in providers { urls.append(try await readReload(token) { try await readDroppedURL(provider) }) }
                let items = try await readReload(token) {
                    if let applyDroppedURLs { return try await applyDroppedURLs(urls, token) }
                    return try await repository.addDroppedCommitFiles(urls, cancellation: token)
                }
                guard !items.isEmpty else { return }
                refresh = true; droppedChecks.append(contentsOf: items)
                if items.contains(where: { $0.path == "." }) { scopePaths = []; showWholeProject = true }
                else if !scopePaths.isEmpty {
                    for item in items where !visibleEntries.contains(where: { $0.path.utf8.elementsEqual(item.path.utf8) }) && !scopePaths.contains(where: { $0.utf8.elementsEqual(item.path.utf8) || item.path.hasPrefix($0 + "/") }) { scopePaths.append(item.path) }
                }
                let errors = items.compactMap(\.error)
                if !errors.isEmpty { error = errors.joined(separator: "\n") }
            } catch { if messageFocusAvailable, !token.isCancelled, !Task.isCancelled { self.error = error.localizedDescription } }
        }
        return true
    }
    private var commandLineMessageProvided = false
    private var commandLineIssueID: String?
    func applyCommandLine(_ invocation: PrimaryCommandInvocation, message: String?) {
        guard !hasLoaded, !busy else { return }
        if let message { self.message = message; commandLineMessageProvided = true }
        commandLineIssueID = invocation.issueID
        if let issueID = invocation.issueID { self.issueID = issueID }
    }
    func reload(paths: [String]? = nil,wholeProject:Bool? = nil) {
        let repository=self.repository.capturingDiffBackend(preferences:dialogDefaults)
        guard messageFocusAvailable, !issueProviderBusy, !busy, !pendingReloadCancel, !unversionedPromptVisible else { return }
        unversionedPromptPending=false;fileListReadError=nil;fileListReadCancelled=false
        fileMenuGeneration = UUID(); busy = true
        let requestedScope = paths.map { $0.contains(".") ? [] : $0 } ?? scopePaths
        let scopedPreference=dialogDefaults.bool(forKey:CommitScopePreference.key(root:repository.root))
        let requestedWholeProject=wholeProject ?? (paths == nil ? showWholeProject:requestedScope.isEmpty || scopedPreference)
        let changingWholeProject=wholeProject != nil && !requestedScope.isEmpty
        let resetChecks=changingWholeProject || paths != nil && (!hasLoaded || requestedScope != scopePaths)
        var retainedScopeChecks=scopeCheckStates
        if hasLoaded {for entry in visibleEntries {retainedScopeChecks[entry.path]=checked.contains(entry.id)}}
        let position = fileListRefresh.begin(preferences:dialogDefaults,reset:!hasLoaded || requestedScope != scopePaths,selectedIDs:selection)
        let token = OperationCancellation(); reloadCancellation = token; Self.activeReloads += 1
        reloadTask = Task {
            defer {
                Self.activeReloads -= 1; fileListRefresh.finish(position); withExtendedLifetime(access) {}
                if reloadCancellation === token {
                    reloadCancellation=nil;reloadTask=nil;busy=false;offerMergeHint();offerStagingHint();offerUnversionedFiles()
                    if amend,amendMessageReadFailed,!loadingAmendMessage,!confirmingQuit,fileListReadError==nil,!fileListReadCancelled {amendChanged()}
                }
            }
            do {
                try validateRestoreAccess()
                guard try await requireCommitIdentity(token) else {busy=false;close();return}
                // Collect the entire next display before changing the accepted
                // one. Every suspension checks both token and owning window.
                let preferences:CommitPreferences?
                if loadedPreferences { preferences=nil }
                else { preferences=try await readReload(token) { try await repository.commitPreferences(cancellation:token) } }
                let nextOperation = try await readReload(token) { try await repository.commitOperation(cancellation:token) }
                let nextHasHead = try await readReload(token) { (try? await repository.run(["rev-parse","--verify","HEAD"],cancellation:token)) != nil }
                let nextHasParent = try await readReload(token) { (try? await repository.run(["rev-parse","--verify","HEAD^1"],cancellation:token)) != nil }
                let nextAmend = nextOperation == nil && amend
                let nextAmendDiff = nextAmend && !nextHasParent ? true : amendDiffToLastCommit
                let compareParent = nextAmend && !nextAmendDiff
                let nextBase = compareParent ? try await readReload(token) { try await repository.commitComparisonBase(amendToParent:true,cancellation:token) } : nil
                let nextEntries = try await readReload(token) { try await queryCommitStatus(compareParent,token) }
                let nextSubmodules = try await readReload(token) { try await repository.submodulePathNames(cancellation:token).map(\.rawValue) }
                let nextBranch = try await readReload(token) { try await repository.branch(cancellation:token) }
                let nextReportInEnglish=try await readReload(token) {try await repository.commitFileListReportInEnglish(cancellation:token)}
                let nextMetadata = try await readReload(token) { await repository.statusListMetadata(paths:nextEntries.map(\.path)) }
                let nextHasLFS = try await readReload(token) { try await repository.hasLFS(cancellation:token) }
                let snippetURL = RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("snippet.txt")
                let nextSnippets = try await readReload(token) { await snippetLoader.load(userURL:snippetURL) }
                let nextChangelists = try await readReload(token) { try await repository.changelists(cancellation:token) }
                let nextIndexFlags = try await readReload(token) { try await repository.workingTreeStatus(readPolicy:.automatic,cancellation:token) }
                let nextConflictRebase = try await readReload(token) { try await repository.conflictIsRebase(cancellation:token) }
                let nextStatistics = GitPathMap(try await readReload(token) { try await repository.workingTreeFiles(amendToParent:compareParent,cancellation:token) }.map {($0.path,$0)},uniquingKeysWith:{_,new in new})
                let nextStaged = GitPathMap(try await readReload(token) { try await repository.stagingFiles(staged:true,base:nextBase,cancellation:token) }.map {($0.path,$0)},uniquingKeysWith:{_,new in new})
                let nextUnstaged = GitPathMap(try await readReload(token) { try await repository.stagingFiles(staged:false,cancellation:token) }.map {($0.path,$0)},uniquingKeysWith:{_,new in new})
                let nextAuthor:String?
                if !hasLoaded && (author.isEmpty || pendingRecommitSession) {
                    if !pendingRecommitSession,let identity=acceptedCommitIdentity {nextAuthor="\(identity.authorName) <\(identity.authorEmail)>"}
                    else {nextAuthor=try await readReload(token) {try await readAuthor(amend:false,repository:repository,cancellation:token)}}
                } else { nextAuthor=nil }
                let provider = try await readNativeIssueProvider(token)
                let nextIssueProperties:IssueTrackerProperties?,nextProjectSettings:ProjectDialogSettings?,nextHistory:CommitMessageHistory?,seed:CommitMessageSeed?
                let draftMessage=message,draftIssueID=issueID
                if !loadedMessage {
                    nextIssueProperties = try await readReload(token) { try await repository.issueTrackerProperties(cancellation:token) }
                    nextProjectSettings = try await readReload(token) { try await repository.projectDialogSettings(source:.effective,cancellation:token) }
                    let identity = try await readReload(token) { try await repository.commitMessageHistoryIdentity(cancellation:token) }
                    let limit = dialogDefaults.object(forKey:"MaxHistoryItems") as? Int ?? dialogDefaults.object(forKey:"Commit.MaxHistoryItems") as? Int ?? 25
                    nextHistory = CommitMessageHistory(repositoryIdentity:identity,defaults:dialogDefaults,limit:limit)
                    seed = try await readReload(token) { try await loadMessageSeed(includeOperationMessages:!pendingRecommitSession,cancellation:token) }
                } else { nextIssueProperties=nil;nextProjectSettings=nil;nextHistory=nil;seed=nil }
                var nextOwners:GitPathMap<String>=[:],nextLocked=GitPathSet(),nextOwnershipKnown=false
                var warnings=seed?.warnings ?? []
                if nextHasLFS && fileColumns.visible.contains(.lfsOwner) {
                    lfsOwnerCancellation=token
                    defer {if lfsOwnerCancellation === token {lfsOwnerCancellation=nil}}
                    do {
                        let locks = try await readReload(token) { try await queryLFSOwners(token) }
                        nextOwners=GitPathMap(locks.map {($0.path,$0.owner)},uniquingKeysWith:{first,_ in first})
                        nextLocked=GitPathSet(locks.map(\.path));nextOwnershipKnown=true
                    } catch {
                        try token.check()
                        warnings.append("Could not get LFS locks: " + error.localizedDescription)
                    }
                }
                var nextMessage=draftMessage,nextIssueID=draftIssueID
                if let seed {
                    if pendingRecommitSession {
                        // ReCommit installs only the new template, preserving
                        // its issue field as CommitDlg does. Initial operation
                        // messages and command-line presets belong to the old
                        // preparation and must not replace this next draft.
                        nextMessage=seed.template
                    } else if draftMessage.isEmpty && !nextAmend && !commandLineMessageProvided {
                        let separated=(nextIssueProperties ?? issueProperties).separateIssueLine(from:seed.message)
                        nextMessage=separated.message;nextIssueID=separated.issueID
                    }
                    do {
                        if let hook = try await clientHooks.run(.startCommit,repository:repository,access:access,paths:requestedScope.isEmpty ? [repository.root.path] : requestedScope.map {repository.root.appendingPathComponent($0).path},message:nextMessage,cancellation:token,allowContinue:true) { nextMessage=hook.message }
                    } catch {
                        guard messageFocusAvailable,reloadCancellation === token,!token.isCancelled else {return}
                        self.error=error.localizedDescription;busy=false;close();return
                    }
                }
                if !loadedMessage,!pendingRecommitSession,let commandLineIssueID {nextIssueID=commandLineIssueID}
                try await recoverMissingStagedFiles(nextEntries, repository: repository, token: token,
                    scope: requestedScope, wholeProject: requestedWholeProject)
                _ = try await readReload(token) { () }
                // No suspension until every field and dependent command target
                // belongs to the same accepted read. Native row settlement follows.
                if let preferences {
                    persistedStaging=preferences.staging;stagingEnabled=gitGuiInterface || preferences.staging;appliedStagingMode=stagingEnabled;stagingHintPending=preferences.staging && !gitGuiInterface;loadedPreferences=true
                }
                operation=nextOperation;if nextOperation != nil {createBranch=false}
                amend=nextAmend;amendDiffToLastCommit=nextAmendDiff
                hasHead=nextHasHead;hasParent=nextHasParent;comparisonBase=nextBase
                scopePaths=requestedScope;showWholeProject=requestedWholeProject
                entries=nextEntries;submodules=GitPathSet(nextSubmodules);branch=nextBranch;fileMetadata=nextMetadata
                fileListReportInEnglish=nextReportInEnglish
                hasLFS=nextHasLFS;messageSnippets=nextSnippets;changelists=nextChangelists;changelistsLoaded=true
                indexFlagFiles=nextIndexFlags;conflictRebase=nextConflictRebase
                statistics=nextStatistics;stagedStatistics=nextStaged;unstagedStatistics=nextUnstaged
                stagingStates=nil;stagingStateNeedsRefresh=false
                lfsOwners=nextOwners;lfsLockedPaths=nextLocked;lfsOwnershipKnown=nextOwnershipKnown
                nativeIssueProvider=provider.provider;issueProviderError=provider.error
                if resetChecks {
                    checked=GitPathSet(visibleEntries.filter {entry in
                        if let retained=retainedScopeChecks[entry.path] {return retained}
                        let inScope=entry.staged || requestedWholeProject || requestedScope.isEmpty || requestedScope.contains {GitReferenceName.equal($0,entry.path) || entry.path.utf8.starts(with:($0+"/").utf8)}
                        let directFile=requestedScope.contains {GitReferenceName.equal($0,entry.path)}
                        let missing=entry.worktree == "D"
                        let automatic=(changingWholeProject || selectFilesAutomatically || replaySplit != nil) && entry.state != .untracked && (!doNotAutoselectMissing || !missing)
                        return inScope && (directFile || automatic) && !changelists.ignores(entry.path) && (!doNotAutoselectSubmodules || !submodules.contains(entry.path))
                    }.map(\.id))
                } else {checked.formIntersection(GitPathSet(entries.map(\.id)))}
                for item in droppedChecks {
                    for entry in visibleEntries where item.path == "." || entry.path.utf8.elementsEqual(item.path.utf8) || item.directory && entry.path.hasPrefix(item.path + "/") {
                        let missing=entry.worktree == "D"
                        let automatic=(selectFilesAutomatically || replaySplit != nil) && entry.state != .untracked && (!doNotAutoselectMissing || !missing)
                        let direct=requestedScope.contains(entry.path)
                        if (direct || automatic) && !changelists.ignores(entry.path) && (!doNotAutoselectSubmodules || !submodules.contains(entry.path)) {checked.insert(entry.id)}
                        else {checked.remove(entry.id)}
                    }
                }
                droppedChecks=[];selection.formIntersection(GitPathSet(entries.map(\.id)))
                if changingWholeProject {
                    scopeCheckStates=retainedScopeChecks
                    for entry in visibleEntries {scopeCheckStates[entry.path]=checked.contains(entry.id)}
                    dialogDefaults.set(requestedWholeProject,forKey:CommitScopePreference.key(root:repository.root))
                }
                if author.isEmpty || pendingRecommitSession,let nextAuthor {author=nextAuthor}
                hasLoaded=true
                if let seed {
                    issueProperties=nextIssueProperties!;projectSettings=nextProjectSettings!;messageHistory=nextHistory;messageTemplate=seed.template
                    if message.utf8.elementsEqual(draftMessage.utf8),issueID.utf8.elementsEqual(draftIssueID.utf8) {message=nextMessage;issueID=nextIssueID}
                    loadedMessage=true
                    // CommitDlg clears Undo when installing the next template.
                    // Accept the complete native template/Start-hook snapshot
                    // first; failed/obsolete reloads cannot retire the draft.
                    if pendingRecommitSession {pendingRecommitSession=false;messageEditorSession=UUID()}
                }
                if !warnings.isEmpty {reloadError=warnings.joined(separator:"\n\n");self.error=reloadError}
                else if self.error == reloadError {self.error=nil;reloadError=nil}
                refreshPartial();prepareMessageCompletions(force:true)
                if !gitGuiInterface, preferences?.showPatch == true {if stagingEnabled {showPartial(false)} else {showViewPatch()}}
                if !position.remember {selection=[]}
                await fileListRefresh.restore(position,ids:visibleFileRowIDs);try token.check()
                unversionedPromptPending=visibleEntries.isEmpty && hasHiddenUnversionedFiles && operation != .merge
            } catch {
                if messageFocusAvailable,reloadCancellation === token {
                    if token.isCancelled || error is OperationCancellationFailure || error is CancellationError {fileListReadCancelled=true}
                    else {fileListReadError=error.localizedDescription;reloadError=error.localizedDescription;self.error=reloadError}
                }
            }
        }
    }
    /// Capture config before presenting a permission sheet. A config edit while
    /// that sheet is open must not redirect the subsequent read to another file.
    func loadMessageSeed(includeOperationMessages: Bool = true, cancellation: OperationCancellation) async throws -> CommitMessageSeed {
        func check() throws {
            try cancellation.check()
            guard messageFocusAvailable, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        }
        try check()
        var selection = try await repository.commitMessageTemplate(cancellation: cancellation)
        try check()
        var permission: RepositoryAccessLease?, warning: String?
        if let file = selection.url, templateFileAccess.needsPermission(file, repositoryAccess: access) {
            do { permission = try templateFileAccess.acquire(file) } catch { /* Re-authorize missing, stale or invalid saved access. */ }
            if permission == nil {
                let selected = try await authorizeTemplateFile(file)
                try check()
                if let selected {
                    do { permission = try templateFileAccess.remember(selected, for: file) }
                    catch { warning = "Could not authorize commit.template file: " + file.path + "\n" + error.localizedDescription }
                } else { warning = "The commit template was not loaded because file access was cancelled: " + file.path }
                if permission == nil { selection = CommitMessageTemplate(url: nil) }
            }
        }
        defer { withExtendedLifetime(permission) {} }
        try check()
        let seed = try await repository.commitMessageSeed(includeOperationMessages: includeOperationMessages, template: selection, cancellation: cancellation)
        try check()
        return CommitMessageSeed(template: seed.template, message: seed.message, warnings: seed.warnings + (warning.map { [$0] } ?? []))
    }
    private func recoverMissingStagedFiles(_ entries: [StatusEntry], repository: GitRepository,
                                          token: OperationCancellation, scope: [String], wholeProject: Bool) async throws {
        // Commit includes staged paths beyond the selected Finder scope, matching
        // the same policy as its visibleEntries and included-staged source list.
        let included = entries.filter { entry in
            entry.staged || wholeProject || scope.contains {
                GitReferenceName.equal($0, entry.path) || entry.path.utf8.starts(with: ($0 + "/").utf8)
            }
        }
        try await missingStagedRecovery.process(repository: repository, entries: included, token: token) { [weak self] in
            guard let self else { return false }
            return self.messageFocusAvailable && self.reloadCancellation === token && !self.confirmingQuit && !self.pendingReloadCancel
        }
    }
    /// Check on both sides of every suspension: even an injected read that
    /// ignores cancellation cannot publish into a closed Commit window.
    private func readReload<Value>(_ token: OperationCancellation, _ read: () async throws -> Value) async throws -> Value {
        guard messageFocusAvailable, reloadCancellation === token, !token.isCancelled, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        let value = try await read()
        guard messageFocusAvailable, reloadCancellation === token, !token.isCancelled, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        return value
    }
    private(set) static var activePreferenceOperations=0
    @Published private(set) var savingPreferences=false
    @Published private(set) var mergeHintVisible=false
    private var mergeHintOffered=false
    private var mergeHintCancellation:OperationCancellation?
    func offerMergeHint() {
        guard hasLoaded,operation == .merge,!mergeHintOffered,messageFocusAvailable,!inputsBlocked,let presentMergeHint else{return}
        if dialogDefaults.integer(forKey:"CommitMergeHint") != 0 {mergeHintOffered=true;return}
        let token=OperationCancellation();mergeHintCancellation=token;mergeHintVisible=true;Self.activePreferenceOperations += 1
        Task { [self,access] in
            defer {Self.activePreferenceOperations -= 1;withExtendedLifetime(access){};if mergeHintCancellation===token {mergeHintCancellation=nil;mergeHintVisible=false;offerStagingHint();offerUnversionedFiles()}}
            let remember=await presentMergeHint(token)
            guard messageFocusAvailable,!confirmingQuit,!token.isCancelled,mergeHintCancellation===token,operation == .merge else{return}
            if let remember {mergeHintOffered=true;if remember {dialogDefaults.set(1,forKey:"CommitMergeHint")}}
        }
    }
    @Published private(set) var stagingHintVisible=false
    private var preferenceTask:Task<Void,Never>?
    private var preferenceCancellation:OperationCancellation?
    private var pendingStagingPreference:Bool?,pendingPatchPreference:Bool?
    private var appliedStagingMode=false
    private var stagingHintPending=false
    private var stagingHintRequest=UUID()
    var presentStagingHint:(() async -> Bool?)?
    static let stagingHint="""
    The file checkboxes now show what is staged for commit:
    • Checked: all changes in the file are staged.
    • Unchecked: the changes are unstaged.
    • Mixed (a square): only some changes are staged.

    Clicking a checkbox immediately stages or unstages the whole file. Clicking a mixed checkbox stages its remaining working changes.

    For performance, status labels, line counts and groups stay as they were when the list was loaded. Press F5 to refresh them. The checkboxes always reflect the latest staging action.

    Use Partial Staging or Partial Unstaging to open the selected file's patch and choose individual hunks or lines. Commit includes the whole index, including staged files outside the displayed scope.
    """
    func offerStagingHint() {
        guard stagingHintPending else {return}
        guard stagingEnabled,!dialogDefaults.bool(forKey:"HintStagingMode") else {stagingHintPending=false;return}
        guard messageFocusAvailable,!inputsBlocked,let presentStagingHint else {return}
        let request=UUID();stagingHintRequest=request;stagingHintVisible=true;Self.activePreferenceOperations += 1
        Task { [self,access] in
            defer {Self.activePreferenceOperations -= 1;withExtendedLifetime(access){};if stagingHintRequest==request {stagingHintVisible=false;offerUnversionedFiles()}}
            let suppress=await presentStagingHint()
            guard messageFocusAvailable,stagingHintRequest==request,stagingEnabled else {return}
            if let suppress {stagingHintPending=false;if suppress {dialogDefaults.set(true,forKey:"HintStagingMode")}}
        }
    }
    func setStagingEnabled(_ enabled:Bool) {
        guard messageFocusAvailable,!inputsBlocked,loadedPreferences,stagingEnabled != enabled else {return}
        stagingEnabled=enabled;stagingChanged()
    }
    func savePatchPreference(_ visible:Bool) {
        guard messageFocusAvailable,!unversionedPromptVisible else {return};queuePreferences(showPatch:visible)
    }
    func stagingChanged() {
        guard messageFocusAvailable,loadedPreferences,!inputsBlocked,appliedStagingMode != stagingEnabled else {return}
        appliedStagingMode=stagingEnabled;closePartial();stagingHintPending=stagingEnabled
        queuePreferences(staging:stagingEnabled)
    }
    private func queuePreferences(staging:Bool? = nil,showPatch:Bool? = nil) {
        if let staging {pendingStagingPreference=staging}
        if let showPatch {pendingPatchPreference=showPatch}
        guard preferenceTask==nil else {return}
        let token=OperationCancellation();preferenceCancellation=token;savingPreferences=true;Self.activePreferenceOperations += 1
        preferenceTask=Task { [self,repository,access] in
            var refresh=false
            defer {
                Self.activePreferenceOperations -= 1;withExtendedLifetime(access){}
                preferenceTask=nil;preferenceCancellation=nil;savingPreferences=false
                if messageFocusAvailable,!token.isCancelled {if refresh {reload()} else {offerStagingHint()}}
            }
            while messageFocusAvailable,!token.isCancelled,pendingStagingPreference != nil || pendingPatchPreference != nil {
                let mode=pendingStagingPreference,patch=pendingPatchPreference;pendingStagingPreference=nil;pendingPatchPreference=nil
                if mode != nil {refresh=true}
                do {
                    try validateRestoreAccess()
                    try await repository.saveCommitPreferences(staging:mode,showPatch:patch,cancellation:token)
                    guard messageFocusAvailable,!token.isCancelled else {return}
                    if let mode {persistedStaging=mode}
                } catch {if messageFocusAvailable,!token.isCancelled {self.error=error.localizedDescription}}
            }
        }
    }
    struct FileCheckReceipt:Equatable {
        let generation:UUID,staging:Bool,files:[StatusEntry],noAutoSubmodules:Bool
    }
    var fileCheckReceipt:FileCheckReceipt {FileCheckReceipt(generation:fileMenuGeneration,staging:stagingEnabled,files:visibleEntries,noAutoSubmodules:doNotAutoselectSubmodules)}
    private func acceptsFileCheck(_ receipt:FileCheckReceipt?) -> Bool {
        fileListAvailable && (receipt == nil || receipt == fileCheckReceipt)
    }
    func canCheckCategory(_ category:CommitCheckCategory)->Bool {
        fileListAvailable && !messageOnly && CommitCheckPolicy.isAvailable(category,entries:visibleEntries,submodules:submodules)
    }
    func checkCategory(_ category:CommitCheckCategory,checking:Bool,receipt:FileCheckReceipt? = nil) {
        guard acceptsFileCheck(receipt),canCheckCategory(category) else{return}
        let paths=CommitCheckPolicy.paths(category,entries:visibleEntries,submodules:submodules,checking:checking,doNotAutoselectSubmodules:doNotAutoselectSubmodules)
        if stagingEnabled {moveToStage(paths,staged:checking,receipt:receipt)}
        else if checking {checked.formUnion(paths)} else {checked.subtract(paths)}
    }
    func check(_ predicate: (StatusEntry) -> Bool,checking:Bool = true,receipt:FileCheckReceipt? = nil) {
        guard acceptsFileCheck(receipt) else {return}
        let paths = GitPathSet(visibleEntries.filter {predicate($0)}.map(\.id))
        if stagingEnabled {moveToStage(paths,staged:checking)} else if checking {checked.formUnion(paths)} else {checked.subtract(paths)}
    }
    func setGroupChecked(_ files: [StatusEntry], checked value: Bool,receipt:FileCheckReceipt? = nil) {
        guard acceptsFileCheck(receipt),files.allSatisfy({visibleEntries.contains($0)}) else {return}
        let paths = GitPathSet(files.map(\.id))
        if stagingEnabled { moveToStage(paths, staged: value) }
        else if value { checked.formUnion(paths) }
        else { checked.subtract(paths) }
    }
    func setFileChecked(_ entry: StatusEntry, files: [StatusEntry], highlighted: some Sequence<String>, checked value: Bool,receipt:FileCheckReceipt? = nil) { let highlighted = GitPathSet(highlighted);
        guard acceptsFileCheck(receipt),files.contains(entry),files.allSatisfy({visibleEntries.contains($0)}) else {return}
        let targets = StatusListSelection.checkboxEntries(entry: entry, entries: files, highlighted: highlighted)
        let paths = GitPathSet(targets.map(\.id))
        if stagingEnabled { moveToStage(paths, staged: value) }
        else if value { checked.formUnion(paths) }
        else { checked.subtract(paths) }
    }
    func checkAll(_ checking:Bool,receipt:FileCheckReceipt? = nil) {check({_ in true},checking:checking,receipt:receipt)}
    func uncheckAll() {
        guard fileListAvailable else {return}
        if stagingEnabled { moveToStage(GitPathSet(visibleEntries.filter { isStaged($0) }.map(\.id)), staged: false) }
        else { checked.subtract(visibleEntries.map(\.id)) }
    }
    @Published private(set) var loadingImportedMessage=false
    private var importedMessageCancellation:OperationCancellation?
    private(set) var amendDetailsBackendIdentity:String?
    func importLogMessage(_ revision:String,insert:@escaping(String)->Void) {
        guard messageFocusAvailable,!confirmingQuit else{return}
        importedMessageCancellation?.cancel()
        let repository=self.repository.capturingDiffBackend(preferences:dialogDefaults)
        let token=OperationCancellation(),draft=message
        importedMessageCancellation=token;loadingImportedMessage=true;Self.activeMetadataOperations += 1
        Task {
            defer {Self.activeMetadataOperations -= 1;if importedMessageCancellation === token {importedMessageCancellation=nil;loadingImportedMessage=false};withExtendedLifetime(access){}}
            do {
                try validateRestoreAccess()
                guard case .commit(let details)=try await repository.singleCommitDetails(revision:revision,cancellation:token) else {throw GitSingleCommitFailure.notCommit}
                try token.check()
                guard messageFocusAvailable,!confirmingQuit,importedMessageCancellation === token,message.utf8.elementsEqual(draft.utf8) else{return}
                loadingImportedMessage=false;insert(details.subject+"\n"+details.body)
            } catch {if messageFocusAvailable,importedMessageCancellation === token,!token.isCancelled {self.error=error.localizedDescription}}
        }
    }
    private func readAuthor(amend:Bool,repository:GitRepository,cancellation:OperationCancellation) async throws -> String? {
        if let queryCommitAuthor {return try await queryCommitAuthor(amend,cancellation)}
        try validateRestoreAccess()
        if amend {
            let previous=try await repository.singleCommitDetails(revision:"HEAD",cancellation:cancellation).asLogEntry()
            return "\(previous.author) <\(previous.email)>"
        }
        let identity:ReplayUserIdentity
        if let readCommitIdentity {identity=try await readCommitIdentity(cancellation)}else{identity=try await repository.replayUserIdentity(cancellation:cancellation)}
        return "\(identity.authorName) <\(identity.authorEmail)>"
    }
    private func readAuthorDate(repository:GitRepository,cancellation:OperationCancellation) async throws -> Date? {
        if let queryCommitAuthorDate {return try await queryCommitAuthorDate(cancellation)}
        try validateRestoreAccess()
        guard case .commit(let commit)=try await repository.singleCommitDetails(revision:"HEAD",cancellation:cancellation) else{return nil}
        return Date(timeIntervalSince1970:TimeInterval(commit.author.time))
    }
    func amendChanged() {
        if consumesResetTransition("amend",value:amend){return}
        guard messageFocusAvailable,!confirmingQuit,commitIdentityPrepared,!preparingCommitIdentity else { return }
        retireFormReceipts()
        if replaySplit != nil || historyCombine != nil { comparisonChanged(); return }
        let repository=self.repository.capturingDiffBackend(preferences:dialogDefaults)
        let wasLoading = loadingAmendMessage, failedRead = amendMessageReadFailed
        amendMessageReadFailed = false
        invalidateMetadataLoads()
        if amend {
            if !failedRead {nonAmendMessage = message}
            if !amendMessage.isEmpty { finishAmendMessage(amendMessage,repository:repository); return }
            loadingAmendMessage = true
            let generation = amendGeneration, draft = message, token = OperationCancellation(),epoch=metadataEpoch
            amendCancellation = token
            Self.activeMetadataOperations += 1
            Task {
                defer { Self.activeMetadataOperations -= 1; if generation == amendGeneration { loadingAmendMessage = false; amendCancellation = nil } }
                do {
                    if token.isCancelled { throw OperationCancellationFailure.cancelled }
                    let identity=try await repository.singleCommitBackendIdentity(cancellation:token)
                    let previous:String?
                    if let queryAmendMessage {previous=try await queryAmendMessage(token)} else {try validateRestoreAccess();guard case .commit(let commit)=try await repository.singleCommitDetails(revision:"HEAD",cancellation:token) else {throw GitSingleCommitFailure.notCommit};previous=commit.subject+"\n"+commit.body}
                    if token.isCancelled { throw OperationCancellationFailure.cancelled }
                    guard generation == amendGeneration,epoch==metadataEpoch,messageFocusAvailable,!confirmingQuit,amend else { return }
                    guard let previous else { throw StatusFileActionFailure(message: "Could not read the last commit message.") }
                    amendDetailsBackendIdentity=identity
                    finishAmendMessage(message.utf8.elementsEqual(draft.utf8) ? previous : message,repository:repository)
                } catch { if generation == amendGeneration,epoch==metadataEpoch,!confirmingQuit,amend,messageFocusAvailable,!token.isCancelled { amendMessageReadFailed = true; self.error = error.localizedDescription; requestMessageFocus() } }
            }
        } else {
            if !wasLoading && !failedRead { amendMessage = message }
            message = nonAmendMessage
            dateChanged(); authorChanged(); requestMessageFocus(); comparisonChanged()
        }
    }
    private func invalidateMetadataLoads() {
        importedMessageCancellation?.cancel();importedMessageCancellation=nil;loadingImportedMessage=false
        authorCancellation?.cancel(); dateCancellation?.cancel(); amendCancellation?.cancel()
        authorCancellation = nil; dateCancellation = nil; amendCancellation = nil
        authorGeneration += 1; dateGeneration += 1; amendGeneration += 1
        loadingAuthorIdentity = false; loadingAuthorDate = false; loadingAmendMessage = false
        amendMessageReadFailed = false
        replayAuthorPreset = nil; replayDatePreset = nil
    }
    private func finishAmendMessage(_ value: String,repository:GitRepository) {
        message = value; originalAmendMessage = value; loadingAmendMessage = false; amendMessageReadFailed = false
        dateChanged(repository:repository); authorChanged(repository:repository); requestMessageFocus(); comparisonChanged()
    }
    func focusMessage() {guard !inputsBlocked else {return};requestMessageFocus()}
    func focusIssueField(){guard messageFocusAvailable,!inputsBlocked,issueProperties.showsIssueField else{return};issueFocusRequest += 1}
    private func requestMessageFocus() {
        guard messageFocusAvailable else { return }
        messageFocusRequest += 1
    }
    func invalidateMessageFocus() {
        cancelHistoryIssueUpdate()
        retireFormReceipts();metadataEpoch=UUID()
        messageFocusAvailable = false; messageFocusRequest = 0; appliedMessageFocusRequest = 0
    }
    func invalidateForClose() {
        guiPatch?.retire(); guiPatch = nil
        pendingRecommitSession=false;resetMetadataTransitions=[:]
        missingStagedRecovery.retire()
        preferenceCancellation?.cancel();pendingStagingPreference=nil;pendingPatchPreference=nil
        unversionedPromptRequest=UUID();unversionedPromptPending=false;unversionedPromptVisible=false;cancelUnversionedFilesPrompt()
        mergeHintCancellation?.cancel()
        stagingHintRequest=UUID();stagingHintVisible=false;stagingHintPending=false
        preflightRequest=UUID();preflightCancellation?.cancel();preflightCancellation=nil
        if issueProviderPreflightPending {providerCommitAttemptTask?.cancel()}
        if let progress=commitProgress { progress.invalidate();if !progress.busy { progress.choose(nil) } }
        issueProviderGeneration = UUID(); issueProviderBusy = false; cancelProviderIssues()
        fileMenuGeneration = UUID(); fileOperationToken?.cancel(); cancelChangelist()
        diffSession?.cancel(); diffSession = nil
        retireCommitIdentitySettings();retireDetachedChildren();clientHooks.retire(); submoduleLog.retire();fileListRefresh.retire()
        reloadCancellation?.cancel(); reloadTask?.cancel(); lfsOwnerCancellation?.cancel()
        reloadCancellation = nil; reloadTask = nil; lfsOwnerCancellation = nil
        pendingReloadCancel = false; busy = false
        invalidateMessageFocus()
        invalidateMetadataLoads()
        completionTask?.cancel(); issueStyleTask?.cancel(); issueStyleCancellation?.cancel()
    }
    func acknowledgeMessageFocus(_ request: Int) {
        guard messageFocusAvailable, request == messageFocusRequest else { return }
        appliedMessageFocusRequest = request
    }
    func comparisonChanged() {
        if consumesResetTransition("comparison",value:amendDiffToLastCommit){return}
        guard messageFocusAvailable,commitIdentityPrepared,!preparingCommitIdentity else{return}
        hasLoaded = false
        reload(paths: scopePaths.isEmpty ? ["."] : scopePaths)
    }
    func authorChanged(repository captured:GitRepository?=nil) {
        if consumesResetTransition("author",value:setAuthor){return}
        guard messageFocusAvailable,!confirmingQuit,commitIdentityPrepared,!preparingCommitIdentity else { return }
        retireFormReceipts()
        authorCancellation?.cancel(); authorCancellation = nil
        authorGeneration += 1
        loadingAuthorIdentity = false
        if let preset = replayAuthorPreset {
            replayAuthorPreset = nil
            if setAuthor == preset.enabled, author.utf8.elementsEqual(preset.value.utf8) { return }
        }
        let repository=captured ?? self.repository.capturingDiffBackend(preferences:dialogDefaults)
        let generation = authorGeneration, wasAmend = amend, wasSetAuthor = setAuthor, draft = author,epoch=metadataEpoch
        let token = OperationCancellation(); authorCancellation = token
        loadingAuthorIdentity = true
        Self.activeMetadataOperations += 1
        Task {
            defer { Self.activeMetadataOperations -= 1; if generation == authorGeneration { loadingAuthorIdentity = false; authorCancellation = nil } }
            do {
                if token.isCancelled { throw OperationCancellationFailure.cancelled }
                let value = try await readAuthor(amend:wasAmend,repository:repository,cancellation:token)
                if token.isCancelled { throw OperationCancellationFailure.cancelled }
                guard generation == authorGeneration,epoch==metadataEpoch,messageFocusAvailable,!confirmingQuit,amend == wasAmend,setAuthor == wasSetAuthor,
                      author.utf8.elementsEqual(draft.utf8), let value else { return }
                author = value
            } catch { if generation == authorGeneration,epoch==metadataEpoch,messageFocusAvailable,!confirmingQuit,!token.isCancelled,amend == wasAmend,setAuthor == wasSetAuthor { self.error = error.localizedDescription } }
        }
    }
    func dateChanged(repository captured:GitRepository?=nil) {
        if consumesResetTransition("date",value:setAuthorDate){return}
        guard messageFocusAvailable,!confirmingQuit,commitIdentityPrepared,!preparingCommitIdentity else { return }
        retireFormReceipts()
        dateCancellation?.cancel(); dateCancellation = nil
        dateGeneration += 1
        loadingAuthorDate = false
        if let preset = replayDatePreset {
            replayDatePreset = nil
            if setAuthorDate == preset.enabled, authorDate == preset.value, resetAuthorDate == preset.reset { return }
        }
        resetAuthorDate = false
        guard setAuthorDate else { return }
        if !amend { authorDate = Date(); return }
        let repository=captured ?? self.repository.capturingDiffBackend(preferences:dialogDefaults)
        let generation = dateGeneration, draft = authorDate,epoch=metadataEpoch
        let token = OperationCancellation(); dateCancellation = token
        loadingAuthorDate = true
        Self.activeMetadataOperations += 1
        Task {
            defer { Self.activeMetadataOperations -= 1; if generation == dateGeneration { loadingAuthorDate = false; dateCancellation = nil } }
            do {
                if token.isCancelled { throw OperationCancellationFailure.cancelled }
                let value = try await readAuthorDate(repository:repository,cancellation:token)
                if token.isCancelled { throw OperationCancellationFailure.cancelled }
                guard generation == dateGeneration,epoch==metadataEpoch,messageFocusAvailable,!confirmingQuit,amend,setAuthorDate,authorDate == draft,let value else { return }
                authorDate = CommitAuthorDateControl.loaded(value,retainingDay:draft)
            } catch { if generation == dateGeneration,epoch==metadataEpoch,messageFocusAvailable,!confirmingQuit,!token.isCancelled,amend,setAuthorDate { self.error = error.localizedDescription } }
        }
    }
    var querySignOff:((OperationCancellation) async throws -> String)?
    func addSignOff() {
        runFileOperation("Reading signing identity…",operation:{ [self] token,_ in
            let trailer:String
            do {
                if let querySignOff {trailer=try await querySignOff(token)}
                else {trailer=try await repository.commitSignOffLine(cancellation:token)}
            } catch {
                guard !token.isCancelled else {throw error}
                throw NSError(domain:"TurtleGit.CommitSignOff",code:1,userInfo:[NSLocalizedDescriptionKey:"Configure your Git user name and email before adding a sign-off.\n" + error.localizedDescription])
            }
            guard isFileOperationLive(token) else {return}
            message=IssueTrackerProperties.addingSignOff(trailer,to:message)
        },completed:{ [weak self] in self?.requestMessageFocus() })
    }
    func compare(paths selected: some Sequence<String>) { let selected = GitPathSet(selected);
        guard fileListAvailable else { return }
        let paths = entries.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }; onCompare(paths, amendToParent)
    }
    func diff(paths selected: some Sequence<String>, staged: Bool? = nil, alternate: Bool = false) { let selected = GitPathSet(selected);
        let repository=self.repository.capturingDiffBackend(preferences:dialogDefaults)
        guard fileListAvailable, !unifiedViewerBusy else { return }
        let paths = entries.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        let amendToParent = self.amendToParent
        let session = FileListComparisonSession(window: comparisonWindow, preferences: dialogDefaults)
        diffSession = session; busy = true
        Task {
            defer { if diffSession === session { diffSession = nil; busy = false }; withExtendedLifetime(access) {} }
            do {
                try await session.run(selectedCount: 0) { [self] token in
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let bytes: Data
                    if let staged { bytes = try await repository.patchData(paths: paths, staged: staged, base: amendToParent && staged ? try await repository.commitComparisonBase(amendToParent: true, cancellation: token) : nil, cancellation: token) }
                    else {
                        let head = try? await repository.run(["rev-parse", "--verify", "HEAD"], cancellation: token)
                        let base = amendToParent ? try await repository.commitComparisonBase(amendToParent: true, cancellation: token) : "HEAD"
                        let args = ["diff", "--no-ext-diff", "--no-color"] + (head == nil ? ["--cached"] : [base]) + ["--"] + paths
                        bytes = try await repository.unifiedDiffData(arguments:args,cancellation:token)
                }
                guard messageFocusAvailable, !confirmingQuit, !token.isCancelled else { return }
                if let onUnifiedDiff { try await onUnifiedDiff(bytes, alternate) }
                else if try await !UnifiedDiffApplication.openExternal(bytes, alternate: alternate, preferences: dialogDefaults, title: staged == true ? "Index changes" : staged == false ? "Working tree changes" : "Commit changes", permissions: access.map { [$0] } ?? [], cancellation: token) {
                    guard messageFocusAvailable, !confirmingQuit, !token.isCancelled else { return }
                    unifiedWindow = UnifiedDiffApplication.presentBuiltin(bytes, repository: repository, access: access, existing: unifiedWindow, title: staged == true ? "Index changes" : staged == false ? "Working tree changes" : "Commit changes", preferences: dialogDefaults, onClosed: { [weak self] in self?.unifiedWindow = nil })
                }
                }
            } catch { if messageFocusAvailable, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    var captureCommitBackend:(()->GitLibGit2Configuration)?
    private(set) var acceptedCommitBackend:GitLibGit2Configuration?
    func commit(_ action: CompletionAction = .commit) {
        guard canCommit, replaySplit == nil && historyCombine == nil || action == .commit,
              historyCombine == nil || (amend && !createBranch) else { return }
        let backend=captureCommitBackend?() ?? GitLibGit2Configuration.load(from:dialogDefaults)
        acceptedCommitBackend=backend
        if replaySplit == nil && historyCombine == nil { completionAction = action }
        let rawMessage = message, rawIssueID = issueID, properties = issueProperties, provider = nativeIssueProvider, paths = checkedPathsForCommit, staging = stagingEnabled, showUnversionedForAttempt=showUnversioned
        let committedPaths = staging ? GitPathSet(entries.filter { isStaged($0) }.map(\.path)) : messageOnly ? GitPathSet() : paths
        let committedPathNames = Set(committedPaths.map { GitReferenceName($0) })
        let retainedChangelists = Set(visibleEntries.filter { !committedPathNames.contains(GitReferenceName($0.path)) }.map { GitReferenceName($0.path) }).union(restoreCopies.keys.map { GitReferenceName($0) })
        let pruningScope = showWholeProject ? [] : scopePaths
        let preserveChangelists = keepChangelists
        var options = CommitOptions(); options.amend = amend; options.amendDiffToLastCommit = amendDiffToLastCommit; options.author = setAuthor ? author : nil
        options.authorDate = setAuthorDate ? authorDate : nil; options.resetAuthorDate = amend && setAuthorDate && resetAuthorDate; options.messageOnly = messageOnly; options.newBranch = createBranch ? newBranch : nil
        if let date=options.authorDate,!options.resetAuthorDate,date < Date(timeIntervalSince1970:0) {error="Invalid time";return}
        if !staging { options.checkboxIndexPolicy = CommitCheckboxIndexPolicy(paths:GitPathSet(visibleEntries.map(\.path)),defaults:dialogDefaults) }
        let historyForAttempt=messageHistory
        let nonAmendHistoryForAttempt=options.amend && !nonAmendMessage.isEmpty && !GitReferenceName.equal(nonAmendMessage,messageTemplate) ? nonAmendMessage:nil
        let preflight=UUID(),preflightToken=OperationCancellation();preflightRequest=preflight;preflightCancellation=preflightToken
        busy = true;attemptWorkPending=true;Self.activeCommitPreflights += 1
        providerCommitAttemptTask = Task { [self,access] in
            var commitAttempted = false,commitSucceeded=false
            var attemptedHistoryMessage:String?
            var headBeforeAttempt:Data?
            defer {
                if commitAttempted,messageFocusAvailable {unversionedDefaults.set(showUnversionedForAttempt,forKey:"AddBeforeCommit")}
                detachedHeadWorkPending=false;attemptWorkPending=false;issueProviderPreflightPending=false
                providerCommitAttemptTask=nil;Self.activeCommitPreflights -= 1
                withExtendedLifetime(access) {}
                if preflightRequest==preflight {preflightCancellation=nil}
            }
            var progress: CommitProgressWindowModel?
            var selectedPostAction: CommitPostAction?
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let current=try await repository.commitDialogStatus(amendToParent:options.amend && !options.amendDiffToLastCommit,cancellation:preflightToken)
                try validatePreflight(preflight,preflightToken)
                let conflicts=current.filter { $0.state == .conflicted }
                if !conflicts.isEmpty {
                    let saved=dialogDefaults.integer(forKey:"CommitWarnOnUnresolved")
                    let ignore:Bool
                    if saved == 1 || saved == 2 {ignore=saved == 2}
                    else if let confirmConflictedSelection {
                        let result=await confirmConflictedSelection(conflicts.map(\.path),preflightToken)
                        try validatePreflight(preflight,preflightToken)
                        guard let result else {busy=false;return}
                        ignore=result.ignore
                        if result.remember {dialogDefaults.set(ignore ? 2:1,forKey:"CommitWarnOnUnresolved")}
                    } else {
                        ignore=await withCheckedContinuation { continuation in confirmUnresolvedConflicts(conflicts.map(\.path)) { continuation.resume(returning:$0) } }
                    }
                    try validatePreflight(preflight,preflightToken)
                    guard ignore else { entries=current;focusConflictedFile(conflicts);busy=false;if let path=selection.first {onFocusConflictedFile(fileListFocusKey,path)};return }
                    options.ignoreUnresolvedConflicts=true
                }
                if let name=options.newBranch {
                    let collision=try await repository.validateCommitBranch(name,cancellation:preflightToken)
                    try validatePreflight(preflight,preflightToken)
                    if collision {
                        let proceed=await withCheckedContinuation { continuation in confirmBranchTagCollision(name) { continuation.resume(returning:$0) } }
                        try validatePreflight(preflight,preflightToken);guard proceed else { busy=false;return }
                    }
                }
                if let historyCombine { try await repository.verifyHistoryCombineAmend(historyCombine) }
                let validation = try await repository.prepareIssueCommit(properties: properties, message: rawMessage, issueID:rawIssueID,cancellation:preflightToken)
                try validatePreflight(preflight,preflightToken)
                if validation.requiresIssueWarning {
                    let proceed = await withCheckedContinuation { continuation in confirmMissingIssue { continuation.resume(returning: $0) } }
                    try validatePreflight(preflight,preflightToken)
                    guard proceed else { busy = false; return }
                }
                if !messageTemplate.isEmpty && GitReferenceName.equal(rawMessage,messageTemplate) && !dialogDefaults.bool(forKey: "Commit.TemplateNotEdited.Proceed") {
                    let proceed = await withCheckedContinuation { continuation in confirmUneditedTemplate { continuation.resume(returning: $0) } }
                    try validatePreflight(preflight,preflightToken)
                    guard proceed else { busy = false; return }
                }
                var text = rawMessage
                if properties.warnNoSignedOffBy {
                    let line = try await repository.commitSignOffLine(cancellation:preflightToken)
                    try validatePreflight(preflight,preflightToken)
                    if !text.contains(line) {
                        let choice = await withCheckedContinuation { continuation in confirmMissingSignOff { continuation.resume(returning: $0) } }
                        try validatePreflight(preflight,preflightToken)
                        if choice == .abort { busy = false; return }
                        if choice == .add { text = IssueTrackerProperties.addingSignOff(line, to: text); message = text }
                    }
                }
                // AppUtils' detector is shared by Commit and Rebase. Test the
                // draft after sign-off handling, before issue insertion or staging.
                let conflictHints = !dialogDefaults.bool(forKey:"CommitMessageContainsConflictHint") ? try await repository.rebaseMessageContainsConflictHints(text,stripComments:dialogDefaults.bool(forKey:"StripCommentedLines"),cancellation:preflightToken) : false
                try validatePreflight(preflight,preflightToken)
                if conflictHints {
                    let choice = await withCheckedContinuation { continuation in confirmConflictHints { continuation.resume(returning: ($0, $1)) } }
                    try validatePreflight(preflight,preflightToken)
                    guard choice.0 else { busy = false; return }
                    if choice.1 { dialogDefaults.set(true, forKey: "CommitMessageContainsConflictHint") }
                }
                if let hook = try await clientHooks.run(.preCommit, repository: repository, access: access, paths: committedPaths.sorted().map { repository.root.appendingPathComponent($0).path }, message: text, allowContinue: true) { text = hook.message }
                try validatePreflight(preflight,preflightToken)
                let prepared = text == rawMessage ? validation : try await repository.prepareIssueCommit(properties: properties, message: text, issueID:rawIssueID,cancellation:preflightToken)
                try validatePreflight(preflight,preflightToken)
                if !options.messageOnly {
                    let candidates = staging ? visibleEntries.filter { isStaged($0) }.map(\.path) : visibleEntries.filter { paths.contains($0.path) }.map(\.path)
                    let dirty = try await repository.commitDirtySubmodules(paths:candidates,cancellation:preflightToken)
                    try validatePreflight(preflight,preflightToken)
                    for child in dirty {
                        let choice = await withCheckedContinuation { continuation in confirmDirtySubmodule(child.path) { continuation.resume(returning: $0) } }
                        try validatePreflight(preflight,preflightToken)
                        guard choice == .ignore else {
                            busy = false
                            if choice == .commit { onCommitSubmodule(child.checkout) }
                            return
                        }
                    }
                }
                try validatePreflight(preflight,preflightToken)
                guard try await prepareDetachedHead(options:options,request:preflight,token:preflightToken) else{busy=false;return}
                try validatePreflight(preflight,preflightToken)
                // OnOK mutates its attempt buffer, not the source editor.
                // Publishing issue insertion or serialization into the editor
                // would invalidate its existing native Undo ranges on failure.
                text = prepared.message
                if let provider {
                    issueProviderPreflightPending=true
                    defer {issueProviderPreflightPending=false}
                    try await provider.checkCommit(context: NativeIssueProviderContext(repositoryRoot:repository.root,paths:committedPaths.sorted(),message:text,issueID:rawIssueID),cancellation:preflightToken)
                }
                try validatePreflight(preflight,preflightToken)
                let isGitSVN = try await repository.finderMetadata(knownBare:false,cancellation:preflightToken).hasGitSVN
                let written = try await repository.prepareCommitMessageFile(text, stripComments: dialogDefaults.bool(forKey: "StripCommentedLines"), sanitize:dialogDefaults.object(forKey:"SanitizeCommitMsg") as? Bool ?? true,cancellation:preflightToken)
                text = written.contents
                try validatePreflight(preflight,preflightToken)
                let result = CommitProgressWindowModel(repository: repository, action: action, staging: staging, paths: paths, options: options, preferences: dialogDefaults, cancellable: replaySplit == nil && historyCombine == nil)
                progress = result; commitProgress = result
                onCommitProgress?(result)
                let presented = onCommitProgress != nil && !result.dismissWithoutWindow
                let output: String
                var providerReceipt: IssueProviderCommitReceipt?
                if let historyCombine { try await repository.verifyHistoryCombineAmend(historyCombine) }
                // Git can create a commit and still return failure during later
                // hook/index work. Retain an exact witness, including unborn
                // HEAD, without treating a changed ref as proof of our success.
                let initialHead=try await repository.run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:preflightToken)
                try validatePreflight(preflight,preflightToken)
                headBeforeAttempt=initialHead.stdout
                commitAttempted = true;attemptedHistoryMessage=written.draft
                let countedReplay = replaySplit != nil
                if countedReplay { RebaseWindowModel.beginReplayWork() }
                defer { if countedReplay { RebaseWindowModel.endReplayWork() } }
                do {
                    let parser = GitCliOutputParser(limit: result.outputLimit)
                    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let operation = Task {
                        defer { continuation.finish() }
                        let onOutput: @Sendable (GitOutputChunk) -> Void = { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }
                        if provider != nil {
                            let receipt=try await repository.commitForIssueProvider(message:text,paths:paths,staging:staging,options:options,replaySplit:replaySplit,backend:backend,cancellation:result.cancellation,onOutput:onOutput)
                            return (receipt.output,Optional(receipt))
                        }
                        if let replaySplit { return (try await repository.commitRebaseSplit(message: text, paths: paths, staging: staging, options: options, expected: replaySplit, onOutput: onOutput),Optional<IssueProviderCommitReceipt>.none) }
                        if staging { return (try await repository.commitIndex(message: text, options: options, cancellation: result.cancellation, onOutput: onOutput),Optional<IssueProviderCommitReceipt>.none) }
                        return (try await repository.commitSelected(message: text, paths: paths, options: options, cancellation: result.cancellation, onOutput: onOutput,backend:backend),Optional<IssueProviderCommitReceipt>.none)
                    }
                    for await _ in updates { result.consume(parser.processPending(), parser: parser) }
                    result.consume(parser.processPending(), parser: parser); result.consume(parser.finish(), parser: parser)
                    let completed=try await operation.value
                    output=completed.0;providerReceipt=completed.1;commitSucceeded=true
                }
                guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else {
                    result.complete(output:output,success:true,cancelled:false,postActions:[]);commitProgress=nil;return
                }
                var completionFailure: String? = providerReceipt?.warning
                if let provider {
                    do {
                        if let revision=providerReceipt?.revision {
                            let warning=try await provider.commitFinished(context: NativeIssueProviderContext(repositoryRoot:repository.root,paths:committedPaths.sorted(),message:text,issueID:rawIssueID), revision:revision,cancellation:result.cancellation)
                            if let warning,!warning.isEmpty {completionFailure="The commit succeeded, but its issue provider reported a completion warning.\n\n"+warning}
                        }
                    } catch { completionFailure = "The commit succeeded, but its issue-provider completion failed.\n\n" + error.localizedDescription }
                }
                try validatePreflight(preflight,preflightToken)
                var restored=true
                do {try await restoreSavedCopies(GitPathSet(restoreCopies.keys),cancellation:result.cancellation)}
                catch {
                    restored=false
                    completionFailure=(completionFailure.map{$0+"\n\n"} ?? "")+"The commit succeeded, but restoring saved working copies failed. The remaining copies are retained in this dialog.\n\n"+error.localizedDescription
                }
                try validatePreflight(preflight,preflightToken)
                // Source RestoreFiles precedes the client PostCommit hook. A
                // failed native restoration retains recovery and must not run
                // a hook against the wrong working-copy contents.
                if restored {
                    do { _ = try await clientHooks.run(.postCommit, repository: repository, access: access, amend: options.amend,cancellation:result.cancellation) }
                    catch { completionFailure = (completionFailure.map { $0 + "\n\n" } ?? "") + "The commit succeeded, but its post-commit hook failed.\n\n" + error.localizedDescription }
                }
                try validatePreflight(preflight,preflightToken)
                if !preserveChangelists {
                    do {
                        let remaining=try await repository.pruneChangelists(retainingPathNames:retainedChangelists,scope:pruningScope,cancellation:preflightToken)
                        try validatePreflight(preflight,preflightToken);changelists=remaining
                    } catch {completionFailure=(completionFailure.map{$0+"\n\n"} ?? "")+"The commit succeeded, but updating changelists failed.\n\n"+error.localizedDescription}
                }
                try validatePreflight(preflight,preflightToken)
                historyForAttempt?.add(written.draft)
                if let nonAmendHistoryForAttempt {historyForAttempt?.add(nonAmendHistoryForAttempt)}
                if !result.isAbandoned { onCommitted(output) }
                let postActions:[CommitPostAction]=completionFailure==nil && replaySplit==nil && historyCombine==nil ? (isGitSVN ? [.svnDCommit,.push,.pull,.recommit,.createTag]:[.push,.pull,.recommit,.createTag]):[]
                if let completionFailure {result.appendDiagnostic(completionFailure)}
                result.complete(output:output,success:true,cancelled:false,postActions:postActions)
                if action != .commit || replaySplit != nil || historyCombine != nil || !presented || result.isAbandoned { result.choose(nil) }
                selectedPostAction = await result.waitForChoice()
                try validatePreflight(preflight,preflightToken)
                rememberCompletionAction(action)
                commitProgress = nil
                if let completionFailure {self.error=completionFailure;busy=false;reload();return}
                if action == .recommit || selectedPostAction == .recommit {
                    invalidateMetadataLoads()
                    // These are controlled reset transitions, not user toggles.
                    // Keep their delayed SwiftUI callbacks from restoring the
                    // previous amend buffer over the accepted next template.
                    if amend {resetMetadataTransitions["amend"]=false}
                    if amendDiffToLastCommit {resetMetadataTransitions["comparison"]=false}
                    if setAuthor {resetMetadataTransitions["author"]=false}
                    if setAuthorDate {resetMetadataTransitions["date"]=false}
                    pendingRecommitSession=true
                    createBranch = false; newBranch = ""; amend = false; amendDiffToLastCommit = false; amendMessage = ""; nonAmendMessage = ""; setAuthorDate = false; resetAuthorDate = false; setAuthor = false; messageOnly = false
                    selectFilesAutomatically = true
                    checked = []; selection = []; hasLoaded = false; loadedMessage = false
                    busy = false
                    reload(paths: scopePaths.isEmpty ? ["."] : scopePaths)
                } else {
                    // Save before the accepted success closes/invalidates this owner.
                    unversionedDefaults.set(showUnversionedForAttempt,forKey:"AddBeforeCommit")
                    busy = false; close()
                    if action == .push || selectedPostAction == .push { onPush(.init(origin:action == .push ? .footer:.progress,amend:options.amend)) }
                    else if selectedPostAction == .pull { onPull() }
                    else if selectedPostAction == .createTag { onCreateTag() }
                    else if selectedPostAction == .svnDCommit { onSVNDCommit() }
                }
            } catch {
                guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else {
                    if let progress { progress.complete(output:error.localizedDescription,success:commitSucceeded,cancelled:!commitSucceeded,postActions:[]);progress.choose(nil) };commitProgress=nil;return
                }
                var commitError = error.localizedDescription
                if commitAttempted,!commitSucceeded,let headBeforeAttempt {
                    let currentHead=try? await repository.run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:preflightToken)
                    guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else{commitProgress=nil;return}
                    if let currentHead,currentHead.stdout != headBeforeAttempt {
                        let warning="Git reported an error, but HEAD changed during the attempt. A commit may already exist. Inspect Log before retrying."
                        if let progress {
                            if progress.output.isEmpty {progress.appendDiagnostic((error as? GitFailure)?.message ?? commitError)}
                            progress.appendDiagnostic(warning)
                        }
                        commitError += "\n\n"+warning
                    }
                }
                let shownInProgress = progress != nil && onCommitProgress != nil && progress?.dismissWithoutWindow != true
                if let progress {
                    progress.complete(output: (error as? GitFailure)?.message ?? commitError, success: false, cancelled: progress.cancellation.isCancelled, postActions: [], exitCode: (error as? GitFailure)?.code)
                    if !shownInProgress || progress.cancelled { progress.choose(nil) }
                    _ = await progress.waitForChoice()
                    guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else{commitProgress=nil;return}
                    rememberCompletionAction(action); commitProgress = nil
                }
                guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else{return}
                var failureMessage = shownInProgress ? "" : commitError
                if commitAttempted && !restoreCopies.isEmpty {
                    let choice=await chooseSavedCopies(allowCancel:false)
                    guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else{return}
                    if choice == .restore {
                        do {try await restoreSavedCopies(GitPathSet(restoreCopies.keys),cancellation:preflightToken)}
                        catch {failureMessage=commitError+"\n\nRestoring saved working copies failed: "+error.localizedDescription}
                    }
                }
                guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else{return}
                if commitAttempted, let created = options.newBranch {
                    let current=try? await repository.branch(cancellation:preflightToken)
                    guard messageFocusAvailable,preflightRequest==preflight,!preflightToken.isCancelled else{return}
                    if current==created {createBranch=false;newBranch=""}
                }
                if commitAttempted,let attemptedHistoryMessage {
                    historyForAttempt?.add(attemptedHistoryMessage)
                    if let nonAmendHistoryForAttempt {historyForAttempt?.add(nonAmendHistoryForAttempt)}
                }
                self.error = failureMessage.isEmpty ? nil : failureMessage
                busy = false; reload()
            }
        }
    }
    var displayedFileEntries:[StatusEntry] {
        let ignored=GitPathSet(indexFlagFiles.filter{$0.assumeUnchanged || $0.skipWorktree}.map{$0.entry.path})
        return StatusListGroups.rows(entries:sortedFiles(visibleEntries,statistics:statistics),changelists:changelists,locallyIgnored:ignored).compactMap(\.entry)
    }
    func fileListDisplayedPath(_ entry:StatusEntry)->String {
        CommitFileListReport.displayedPath(entry,statistics:statistics[entry.path],abbreviateRenames:dialogDefaults.bool(forKey:"AbbreviateRenamings"))
    }
    var checkedFileList:String {
        let displayed=displayedFileEntries
        let included=stagingEnabled ? GitPathSet(displayed.filter{isStaged($0)}.map(\.id)):checked
        return CommitFileListReport.text(entries:displayed,checked:included,statistics:statistics,abbreviateRenames:dialogDefaults.bool(forKey:"AbbreviateRenamings"),label:{[fileListReportInEnglish] raw in
            fileListReportInEnglish ? raw:NSLocalizedString(raw,comment:"")
        })
    }
    private var operationInputsBlocked:Bool {loadingImportedMessage || busy || issueProviderBusy || confirmingQuit || pendingReloadCancel || savingPreferences || mergeHintVisible || stagingHintVisible || unversionedPromptVisible}
    var inputsBlocked:Bool {!commitIdentityPrepared || preparingCommitIdentity || operationInputsBlocked}
    var canRefresh:Bool {messageFocusAvailable && !operationInputsBlocked}
    var fileListAvailable:Bool {messageFocusAvailable && !messageOnly && !inputsBlocked}
    var canCancel: Bool { messageFocusAvailable && !mergeHintVisible && !stagingHintVisible && !unversionedPromptVisible && !confirmingQuit && !pendingReloadCancel && (!busy || reloadCancellation != nil || fileOperationToken != nil || preparingDetachedHead || issueProviderPreflightPending) }
    func cancel(closeWindow: Bool = true, completion: ((Bool) -> Void)? = nil) {
        cancel(closeWindow: closeWindow, completion: completion, confirmationAccepted: false)
    }
    private func cancel(closeWindow: Bool, completion: ((Bool) -> Void)?, confirmationAccepted: Bool) {
        guard messageFocusAvailable else { completion?(false); return }
        if issueProviderPreflightPending,let token=preflightCancellation,let task=providerCommitAttemptTask {
            guard !pendingReloadCancel,!confirmingQuit || !closeWindow else {completion?(false);return}
            pendingReloadCancel=true;token.cancel();task.cancel()
            Task { [self] in
                await task.value
                guard messageFocusAvailable else {completion?(false);return}
                pendingReloadCancel=false;busy=false
                cancel(closeWindow:closeWindow,completion:completion,confirmationAccepted:confirmationAccepted)
            }
            return
        }
        if cancelDetachedHeadPreparation(closeWindow:closeWindow,completion:completion){return}
        if preparingCommitIdentity,let token=reloadCancellation,let task=reloadTask {
            guard !pendingReloadCancel,!confirmingQuit || !closeWindow else{completion?(false);return}
            pendingReloadCancel=true;token.cancel();task.cancel();retireCommitIdentitySettings()
            Task{@MainActor [weak self] in
                await task.value
                guard let self,self.messageFocusAvailable else{completion?(false);return}
                self.pendingReloadCancel=false
                if closeWindow {self.close()};completion?(true)
            };return
        }
        if missingStagedRecovery.busy { missingStagedRecovery.cancel(); completion?(false); return }
        guard !mergeHintVisible,!stagingHintVisible,!unversionedPromptVisible else {completion?(false);return}
        if let task=preferenceTask {
            preferenceCancellation?.cancel();pendingStagingPreference=nil;pendingPatchPreference=nil
            Task { [weak self] in
                await task.value
                guard let self,self.messageFocusAvailable else {completion?(false);return}
                self.cancel(closeWindow:closeWindow,completion:completion,confirmationAccepted:confirmationAccepted)
            }
            return
        }
        if cancelFileOperation() { completion?(false); return }
        if let token = reloadCancellation, let task = reloadTask {
            guard !pendingReloadCancel, !confirmingQuit || !closeWindow else { completion?(false); return }
            pendingReloadCancel = true
            var answered = false
            let stop: (Bool) -> Void = { [weak self] approved in
                guard !answered else { return }; answered = true
                guard let self, self.messageFocusAvailable, self.pendingReloadCancel else { completion?(false); return }
                if !approved { self.pendingReloadCancel = false; completion?(false); return }
                self.invalidateMetadataLoads()
                token.cancel();missingStagedRecovery.cancel();fileListRefresh.cancel(); task.cancel()
                Task { [weak self] in
                    await task.value
                    guard let self, self.messageFocusAvailable else { completion?(false); return }
                    self.pendingReloadCancel = false
                    self.cancel(closeWindow: closeWindow, completion: completion, confirmationAccepted: true)
                }
            }
            let recoveredMessage = issueProperties.messageForCancelledDraft(message: message, issueID: issueID)
            let changed = !recoveredMessage.isEmpty && !GitReferenceName.equal(recoveredMessage,amend ? originalAmendMessage : messageTemplate)
            if !confirmationAccepted, (changed || !entries.isEmpty), !dialogDefaults.bool(forKey: "Commit.SkipCancelConfirmation") {
                confirmCancel(stop)
            } else { stop(true) }
            return
        }
        if let token = lfsOwnerCancellation { token.cancel(); completion?(false); return }
        if let commitProgress { commitProgress.cancel(); completion?(false); return }
        guard !busy, !confirmingQuit || !closeWindow else { completion?(false); return }
        if !commitIdentityPrepared {if closeWindow {close()};completion?(true);return}
        let recoveredMessage = issueProperties.messageForCancelledDraft(message: message, issueID: issueID)
        let changed = !recoveredMessage.isEmpty && !GitReferenceName.equal(recoveredMessage,amend ? originalAmendMessage : messageTemplate)
        let finish = { [weak self] in
            guard let self, self.messageFocusAvailable else { completion?(false); return }
            if changed { self.messageHistory?.add(recoveredMessage) }
            if self.amend && !self.nonAmendMessage.isEmpty && !GitReferenceName.equal(self.nonAmendMessage,self.messageTemplate) { self.messageHistory?.add(self.nonAmendMessage) }
            if closeWindow { self.restoreCopies.removeAll(); self.close() }
            completion?(true)
        }
        let restoreAndFinish = { [weak self] in
            guard let self, self.messageFocusAvailable else { completion?(false); return }
            guard !self.restoreCopies.isEmpty else { finish(); return }
            self.busy = true
            Task {
                let choice = await self.chooseSavedCopies(allowCancel: true)
                if choice == .cancel { self.busy = false; completion?(false); return }
                if choice == .restore {
                    do { try await self.restoreSavedCopies(GitPathSet(self.restoreCopies.keys)) }
                    catch { self.error = error.localizedDescription; self.busy = false; self.reload(); completion?(false); return }
                }
                self.busy = false; finish()
            }
        }
        if !confirmationAccepted, (changed || !entries.isEmpty), !dialogDefaults.bool(forKey: "Commit.SkipCancelConfirmation") {
            confirmCancel { approved in if approved { restoreAndFinish() } else { completion?(false) } }
        } else { restoreAndFinish() }
    }
}

struct CommitSortableRow: Identifiable {
    let row: StatusListRow
    let statistics: CommitFile?
    let isDirectory: Bool
    var metadata: StatusListMetadata? = nil
    var lfsOwner = ""
    var id: String { GitPathRowIdentity.encode(row.id) }
    var entry: StatusEntry? { row.entry }
    var group: StatusListGroup? { row.group }
}
struct CommitFileSort: SortComparator {
    var column: StatusListColumn
    var order: SortOrder = .forward
    func compare(_ lhs: CommitSortableRow, _ rhs: CommitSortableRow) -> ComparisonResult {
        guard let a = lhs.entry, let b = rhs.entry else { return .orderedSame }
        let comparison = StatusListSorting.compare(a, b, column: column, lhsStatistics: lhs.statistics, rhsStatistics: rhs.statistics, lhsDirectory: lhs.isDirectory, rhsDirectory: rhs.isDirectory, lhsMetadata: lhs.metadata, rhsMetadata: rhs.metadata, lhsLFSOwner: lhs.lfsOwner, rhsLFSOwner: rhs.lfsOwner)
        if order == .forward { return comparison }
        return comparison == .orderedAscending ? .orderedDescending : comparison == .orderedDescending ? .orderedAscending : .orderedSame
    }
}

/// The upstream new-branch toggle focuses the newly shown edit control and
/// selects its entire draft. Request this once per insertion, after attachment.
@MainActor class CommitOwnedTextField:NSTextField {
    private weak var originalOwner:NSWindow?
    private var ownerBound=false
    private(set) var retired=false
    var acceptsChanges:()->Bool={true}
    var hasOriginalOwner:Bool {!retired && window != nil && window === originalOwner && window?.attachedSheet==nil && NSApp.modalWindow==nil}
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow()
        if let window {if !ownerBound {ownerBound=true;originalOwner=window}else if originalOwner !== window {retire()}}
    }
    func retire(){retired=true;acceptsChanges={false};isEditable=false}
}
struct CommitNewBranchField: NSViewRepresentable {
    @Binding var name: String
    var acceptsChanges:()->Bool={true}
    @AppStorage("UseCustomWordBreak") private var wordBreakMode=2
    func makeCoordinator() -> Coordinator { Coordinator(name: $name) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "New branch name"
        field.setAccessibilityLabel("New branch name")
        field.identifier = .init("Commit new branch")
        field.usesSingleLineMode=true;field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable=true;field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        field.delegate = context.coordinator
        field.stringValue = name
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        guard !field.retired else{field.isEnabled=false;return}
        context.coordinator.wordCommands.policy=GitInputWordBreak(mode:UInt32(truncatingIfNeeded:wordBreakMode))
        context.coordinator.name = $name
        field.acceptsChanges=acceptsChanges
        if !field.stringValue.utf8.elementsEqual(name.utf8) { field.stringValue = name }
        field.isEnabled = context.environment.isEnabled
        field.isEditable=field.isEnabled && acceptsChanges();field.toolTip=name
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:Field,context:Context)->CGSize? {CGSize(width:proposal.width ?? 250,height:max(22,nsView.intrinsicContentSize.height))}
    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        field.focusPending = false
        field.delegate = nil
        field.retire();coordinator.retired=true
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let wordCommands=GitInputWordCommands()
        var retired=false
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
            guard !retired,let field=control as? Field,field.hasOriginalOwner,field.acceptsChanges() else{return false}
            return wordCommands.handle(control,text:textView,selector:commandSelector,combo:false,owner:self)
        }
        var name: Binding<String>
        init(name: Binding<String>) { self.name = name }
        func controlTextDidChange(_ notification: Notification) {
            guard !retired,let field=notification.object as? Field,field.hasOriginalOwner,field.acceptsChanges(),field.isEnabled,field.isEditable else{return}
            name.wrappedValue = field.stringValue
        }
    }
    final class Field: CommitOwnedTextField {
        var focusPending = true
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let owner = window, focusPending else { return }
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self, let owner, self.window === owner,
                      self.focusPending,self.hasOriginalOwner,self.acceptsChanges(),self.isEditable,self.isEnabled,owner.attachedSheet == nil else { return }
                self.focusPending = false
                if owner.makeFirstResponder(self), let editor = self.currentEditor() {
                    editor.selectedRange = NSRange(location: 0, length: self.stringValue.utf16.count)
                }
            }
        }
    }
}

struct CommitAuthorField: NSViewRepresentable {
    @Binding var author: String
    @AppStorage("UseCustomWordBreak") private var wordBreakMode=2
    var editable: Bool
    var acceptsChanges: () -> Bool = { true }
    func makeCoordinator() -> Coordinator { Coordinator(author: $author, acceptsChanges: acceptsChanges) }
    func makeNSView(context: Context) -> NSTextField {
        let field = CommitOwnedTextField()
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.drawsBackground = true; field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "Name <email>"
        field.setAccessibilityLabel("Author identity")
        field.identifier = .init("Commit author")
        field.usesSingleLineMode=true;field.lineBreakMode = .byTruncatingMiddle;field.cell?.isScrollable=true
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        guard (field as? CommitOwnedTextField)?.retired != true else{field.isEnabled=false;return}
        context.coordinator.wordCommands.policy=GitInputWordBreak(mode:UInt32(truncatingIfNeeded:wordBreakMode))
        context.coordinator.author = $author
        context.coordinator.acceptsChanges = acceptsChanges
        (field as? CommitOwnedTextField)?.acceptsChanges=acceptsChanges
        if !field.stringValue.utf8.elementsEqual(author.utf8) { field.stringValue = author }
        field.isEnabled = context.environment.isEnabled
        field.isEditable = editable && field.isEnabled
        // EM_SETREADONLY in CommitDlg preserves selection and copy access.
        field.isSelectable = true
        field.toolTip=author
        if let editor = field.currentEditor() as? NSTextView {
            editor.isEditable = field.isEditable
        }
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSTextField,context:Context)->CGSize? {CGSize(width:proposal.width ?? 280,height:max(22,nsView.intrinsicContentSize.height))}
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil; field.isEditable = false
        coordinator.retired = true; coordinator.acceptsChanges = { false }
        (field as? CommitOwnedTextField)?.retire()
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let wordCommands=GitInputWordCommands()
        var retired = false
        var acceptsChanges: () -> Bool
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
            guard !retired,let field=control as? CommitOwnedTextField,field.hasOriginalOwner,acceptsChanges() else { return false }
            return wordCommands.handle(control,text:textView,selector:commandSelector,combo:false,owner:self)
        }
        var author: Binding<String>
        init(author: Binding<String>, acceptsChanges: @escaping () -> Bool) { self.author = author; self.acceptsChanges = acceptsChanges }
        func controlTextDidChange(_ notification: Notification) {
            guard !retired,acceptsChanges(),let field=notification.object as? CommitOwnedTextField,field.hasOriginalOwner,field.isEnabled,field.isEditable else { return }
            author.wrappedValue = field.stringValue
        }
    }
}

struct CommitDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: CommitWindowModel
    @AppStorage("Commit.MessagePaneHeight") private var messagePaneHeight = 300.0
    @AppStorage("StyleCommitMessages") private var styleCommitMessages = true
    @AppStorage("LogFontForFileListCtrl") private var reportUsesLogFont=false
    @AppStorage("LogFontName") private var reportFontName=MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var reportFontSize=MessageEditorFont.defaultSize
    private var reportGeometry:FileListUniformRowGeometry {
        let font=reportUsesLogFont ? MessageEditorFont.resolve(name:reportFontName,size:reportFontSize):NSFont.systemFont(ofSize:NSFont.systemFontSize)
        return FileListUniformRowGeometry(font:font,groupFont:NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask))
    }
    @StateObject private var dropTargets = CommitFileDropTargets()
    @State private var dividerStart: Double?
    @FocusState private var issueFieldFocused: Bool
    @State private var initialIssueFocusApplied = false
    var body: some View {
        let receipt=model.formReceipt
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 0)
                Picker("Commit window", selection: Binding(get: { model.gitGuiInterface }, set: { model.setCommitInterface($0) })) {
                    Text("Classic").tag(false); Text("Git Gui-style staging").tag(true)
                }.pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                    .accessibilityLabel("Commit window")
                    .disabled(model.inputsBlocked || model.guiPatch?.busy == true)
            }
            if model.gitGuiInterface { guiWorkspace } else {
            Group {
                CommitDestinationLayout {
                    HStack(spacing:8) {
                        Text("Commit to:").fixedSize()
                        if model.createBranch { CommitNewBranchField(name:$model.newBranch,acceptsChanges:{model.acceptsFormReceipt(receipt) && model.nativeNewBranchInputAvailable}).frame(width:250) }
                        else { CommitDestinationLabel(branch:model.branch.isEmpty ? "Detached / unborn HEAD" : model.branch).frame(minWidth:30,idealWidth:100,maxWidth:250) }
                        Toggle("new branch",isOn:formBinding(.newBranch,\.createBranch)).toggleStyle(.checkbox).fixedSize().disabled(!model.canChangeFormOption(.newBranch))
                    }
                    HStack(spacing:8) {
                        if let provider = model.nativeIssueProvider {
                            Button { model.selectProviderIssues() } label: { CommandLabel(title:provider.linkText,icon:.settingsIssueTracker,localized:false).lineLimit(1).truncationMode(.tail) }
                                .frame(maxWidth:200).help(provider.linkText).disabled(model.inputsBlocked)
                        }
                        if model.issueProperties.showsIssueField {
                            Text(model.issueProperties.label).lineLimit(1).truncationMode(.tail).frame(maxWidth:180).help(model.issueProperties.label)
                            TextField("",text:Binding(get:{model.issueID},set:{if model.acceptsFormReceipt(receipt){model.issueID=$0}})).textFieldStyle(.roundedBorder).frame(width:140).accessibilityLabel(model.issueProperties.label).focused($issueFieldFocused).onSubmit {issueFieldFocused=false;model.focusMessage()}
                        }
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                }
                if let error = model.issueProviderError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if !model.fileOperationTitle.isEmpty { HStack { Text(model.fileOperationCancelling ? "Cancelling…" : model.fileOperationTitle).font(.caption); Spacer(); Button("Cancel operation") { model.cancelFileOperation() }.disabled(model.fileOperationCancelling) } }
                GeometryReader { geometry in
                    let maximum = max(245.0, geometry.size.height - 288)
                    let height = min(max(messagePaneHeight, 245), maximum)
                    VStack(spacing: 0) {
                        messageSection.frame(height: height)
                        Divider().frame(height: 8).contentShape(Rectangle())
                            .background(CommitDividerCursor().accessibilityHidden(true))
                            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                                guard !model.busy else { return }
                                if dividerStart == nil { dividerStart = height }
                                messagePaneHeight = min(max((dividerStart ?? height) + drag.translation.height, 245), maximum)
                            }.onEnded { _ in dividerStart = nil })
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Message and changes divider")
                            .accessibilityValue("\(Int(height)) points")
                            .accessibilityAdjustableAction { direction in
                                guard !model.busy else { return }
                                switch direction {
                                case .increment: messagePaneHeight = min(height + 20, maximum)
                                case .decrement: messagePaneHeight = max(height - 20, 245)
                                @unknown default: break
                                }
                            }
                        changesSection.frame(maxHeight: .infinity)
                    }
                }
            }.disabled(model.inputsBlocked)
            }
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show Whole Project", isOn:formBinding(.wholeProject,\.showWholeProject)).disabled(!model.canChangeFormOption(.wholeProject))
                    Toggle("Message only", isOn:formBinding(.messageOnly,\.messageOnly))
                }.toggleStyle(.checkbox).disabled(model.inputsBlocked)
                if let operation=model.operation {
                    CommandLabel(title:operation.title,icon:operation == .merge ? .merge:operation == .cherryPick ? .cherryPick:.revert)
                        .font(.caption).foregroundStyle(.orange).lineLimit(2).help(operation.title)
                        .accessibilityIdentifier("Commit operation state")
                }
                Spacer()
                CommitActionControl(model:model).fixedSize().disabled(!model.canCommit || model.inputsBlocked)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
                Button("Help") { TurtleGitHelp.show(.commit) }.disabled(model.inputsBlocked)
            }
        }.padding(12)
        .onAppear { model.formattingEnabled = styleCommitMessages }
        .onChange(of: styleCommitMessages) { model.formattingEnabled = $0 }
        .onChange(of: model.busy) { loading in
            if !loading, model.issueProperties.showsIssueField, !initialIssueFocusApplied {
                initialIssueFocusApplied = true; issueFieldFocused = true
            }
        }
        .onChange(of:model.issueFocusRequest){_ in if model.messageFocusAvailable,!model.inputsBlocked,model.issueProperties.showsIssueField{issueFieldFocused=true}}
        .onChange(of: model.amendDiffToLastCommit) { _ in model.comparisonChanged() }
        .onChange(of: model.setAuthor) { _ in model.authorChanged() }
        .onChange(of: model.setAuthorDate) { _ in model.dateChanged() }
        .onChange(of: model.selection) { _ in model.refreshPartial() }
        .alert("TurtleGit", isPresented: Binding(get: { model.error != nil }, set: { if !$0,model.messageFocusAvailable,!model.confirmingQuit { model.error = nil } })) {
            Button("OK") {if model.messageFocusAvailable,!model.confirmingQuit{model.error = nil}}
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.creatingChangelist) { CreateChangelistSheet(model: model) }

    }
    private var guiWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commit to: " + (model.branch.isEmpty ? "Detached / unborn HEAD" : model.branch)).font(.headline)
                Spacer()
                Button("Refresh") { model.reload() }.disabled(model.inputsBlocked)
            }
            HSplitView {
                VSplitView {
                    guiFiles(staged: false)
                    guiFiles(staged: true)
                }.frame(minWidth: 230, idealWidth: 300)
                VStack(alignment: .leading, spacing: 8) {
                    if let patch = model.guiPatch { GuiCommitPatch(model: patch) }
                    else { Text("Select a file to review its changes.").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    GroupBox("Commit message") {
                        CommitMessageEditor(model: model).frame(minHeight: 110, idealHeight: 150)
                    }
                    HStack {
                        Toggle("Amend Last Commit", isOn: formBinding(.amend, \.amend)).toggleStyle(.checkbox)
                            .disabled(!model.canChangeFormOption(.amend)).onChange(of: model.amend) { _ in model.amendChanged() }
                        Spacer(); CommitMessagePositionIndicator(model: model)
                    }
                }.frame(minWidth: 450)
            }
        }
    }
    private func guiFiles(staged: Bool) -> some View {
        let entries = staged ? model.stagedEntries : model.unstagedEntries
        let selection = Binding<Set<String>>(get: {
            model.guiStaged == staged ? Set(model.selection.map { $0 }) : []
        }, set: { model.selectGuiFiles($0, staged: staged) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(staged ? "Staged changes" : "Unstaged changes").font(.headline)
                Text("\(entries.count)").foregroundStyle(.secondary)
                Spacer()
            }
            List(entries, id: \.id, selection: selection) { entry in
                HStack {
                    Image(nsImage: entry.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16)
                    Text(verbatim: entry.path).lineLimit(1).truncationMode(.middle).help(entry.path)
                }.tag(entry.id)
            }.listStyle(.inset).frame(minHeight: 100)
            HStack {
                Button { model.moveToStage(model.selection, staged: !staged) } label: {
                    CommandLabel(title: staged ? "Unstage files" : "Stage files", icon: staged ? .revert : .add)
                }.disabled(model.inputsBlocked || model.guiStaged != staged || model.selection.isEmpty)
                if !staged {
                    Toggle("Unversioned", isOn: formBinding(.unversioned, \.showUnversioned)).toggleStyle(.checkbox).disabled(model.inputsBlocked)
                }
            }
        }.padding(6)
    }
    private func formBinding(_ option:CommitWindowModel.FormOption,_ keyPath:ReferenceWritableKeyPath<CommitWindowModel,Bool>)->Binding<Bool> {
        let receipt=model.formReceipt
        return Binding(get:{model[keyPath:keyPath]},set:{model.setFormOption(option,value:$0,receipt:receipt)})
    }
    private var messageSection: some View {
        let receipt=model.formReceipt
        return GroupBox("Message:") {
                VStack(alignment: .leading, spacing: 8) {
                    CommitMessageEditor(model: model).frame(minHeight: 100, maxHeight: .infinity).border(Color.secondary.opacity(0.3))
                    HStack { Spacer(); CommitMessagePositionIndicator(model: model) }
                    // IDD_COMMITDLG keeps the conditional comparison control
                    // anchored to the right edge of the Amend option band.
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Toggle("Amend Last Commit", isOn:formBinding(.amend,\.amend)).toggleStyle(.checkbox).fixedSize().disabled(!model.canChangeFormOption(.amend)).onChange(of: model.amend) { _ in model.amendChanged() }
                        Spacer(minLength: 12)
                        if model.amend { Toggle("Show diff to last commit", isOn:formBinding(.amendComparison,\.amendDiffToLastCommit)).toggleStyle(.checkbox).fixedSize().disabled(!model.canChangeFormOption(.amendComparison)) }
                    }
                    DialogCommandRows {
                        Toggle("Set author date", isOn:formBinding(.authorDate,\.setAuthorDate)).toggleStyle(.checkbox).frame(minWidth:170,alignment:.leading).fixedSize()
                        if model.setAuthorDate {
                            CommitDatePicker(selection: $model.authorDate, time: false, enabled: !model.loadingAuthorDate && !(model.amend && model.resetAuthorDate), acceptsChanges: {model.acceptsFormReceipt(receipt) && model.nativeAuthorDateInputAvailable}).frame(width: 130, height: 24)
                            CommitDatePicker(selection: $model.authorDate, time: true, enabled: !model.loadingAuthorDate && !(model.amend && model.resetAuthorDate), acceptsChanges: {model.acceptsFormReceipt(receipt) && model.nativeAuthorDateInputAvailable}).frame(width: 115, height: 24)
                            if model.amend { Toggle("Reset", isOn:formBinding(.resetDate,\.resetAuthorDate)).toggleStyle(.checkbox).disabled(!model.canChangeFormOption(.resetDate)) }
                        }
                    }
                    DialogCommandRows {
                        Toggle("Set author", isOn:formBinding(.author,\.setAuthor)).toggleStyle(.checkbox).frame(minWidth:170,alignment:.leading).fixedSize()
                        CommitAuthorField(author: $model.author, editable: model.setAuthor && !model.loadingAuthorIdentity, acceptsChanges: {model.acceptsFormReceipt(receipt) && model.nativeAuthorInputAvailable})
                            .frame(minWidth:220,idealWidth:280).layoutValue(key:DialogCommandRows.Flexible.self,value:true)
                        Button("Add Signed-off-by") { model.addSignOff() }
                    }
                }.padding(4)
            }
    }
    private var changesSection: some View {
GroupBox("Changes made (F5: refresh, double-click on file for diff):") {
                    VStack(alignment: .leading, spacing: 6) {
                        DialogCommandRows(spacing:10) {
                            Text("Check:")
                            categoryButton("All",.all)
                            categoryButton("None",.none)
                            categoryButton("Unversioned",.unversioned)
                            categoryButton("Versioned",.versioned)
                            categoryButton("Added",.added)
                            categoryButton("Deleted",.deleted)
                            categoryButton("Modified",.modified)
                            categoryButton("Files",.files)
                            categoryButton("Submodules",.submodules)
                        }.font(.system(size: 12)).disabled(model.messageOnly)
                        fileTable(model.visibleEntries, staged: model.stagingEnabled ? model.stagedDiff : nil)
                            .overlay {if let text=model.fileListEmptyMessage {Text(text).multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary).padding(20).frame(maxWidth:.infinity,maxHeight:.infinity).allowsHitTesting(false).accessibilityLabel(text)}}
                            .frame(minHeight: 120).disabled(model.messageOnly)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Staging support (EXPERIMENTAL)",isOn:formBinding(.staging,\.stagingEnabled))
                                Toggle("Show Unversioned Files", isOn:formBinding(.unversioned,\.showUnversioned))
                                Toggle("Do not autoselect submodules", isOn:formBinding(.noAutoSubmodules,\.doNotAutoselectSubmodules))
                            }.toggleStyle(.checkbox)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                // Source statistics precede the patch links,
                                // directly below the accepted file snapshot.
                                Text(model.stagingEnabled ? FileListLabels.stagingSummary(staged:model.stagedEntries.count,unstaged:model.unstagedEntries.count):FileListLabels.selectionSummary(checked:model.checkedPathsForCommit.count,shown:model.visibleEntries.count)).font(.caption)
                                if model.stagingEnabled {
                                    Button(LocalizedStringKey(model.partialMode == false ? "Hide Staging «" : "Partial Staging »")) { model.showPartial(false) }.buttonStyle(.link)
                                    Button(LocalizedStringKey(model.partialMode == true ? "Hide Unstaging «" : "Partial Unstaging »")) { model.showPartial(true) }.buttonStyle(.link)
                                } else {
                                    Button(LocalizedStringKey(model.viewingPatch ? "Hide Patch «" : "View Patch »")) { model.showViewPatch() }.buttonStyle(.link)
                                }
                            }
                        }
                    }.padding(4)
                }
    }
    func fileTable(_ entries: [StatusEntry], staged: Bool?) -> some View {
        let geometry=reportGeometry
        let statistics = model.statistics
        let entries = model.sortedFiles(entries, statistics: statistics)
        let focusKey = staged.map { $0 ? "staged" : "unstaged" } ?? "checkbox"
        let checkReceipt=model.fileCheckReceipt
        let focus = Binding<String?>(get: { model.focusedFiles[focusKey] }, set: { model.focusedFiles[focusKey] = $0 })
        let ignored = GitPathSet(model.indexFlagFiles.filter { $0.assumeUnchanged || $0.skipWorktree }.map { $0.entry.path })
        let rows = StatusListGroups.rows(entries: entries, changelists: model.changelists, locallyIgnored: ignored)
        let tableRows = rows.map { CommitSortableRow(row: $0, statistics: $0.entry.flatMap { statistics[$0.path] }, isDirectory: $0.entry.map { model.submodules.contains($0.path) } ?? false, metadata: $0.entry.flatMap { model.fileMetadata[$0.path] }, lfsOwner: $0.entry.flatMap { model.lfsOwners[$0.path] } ?? "") }
        let sort = Binding(get: { model.fileSortOrder }, set: { model.setFileSortOrder($0) })
        return Table(tableRows, selection: $model.nativeFileSelection, sortOrder: sort) {
            TableColumn("") { (row: CommitSortableRow) in
                if let entry = row.entry {
                    if staged != nil {
                        StagingCheckbox(entry:entry,state:model.stagingState(entry),enabled:model.fileListAvailable) { model.setFileChecked(entry, files: entries, highlighted: model.selection, checked: $0,receipt:checkReceipt) }.frame(width: 20, height: 20)
                    } else {
                        StagingCheckbox(entry:entry,state:model.checked.contains(entry.id) ? .on : .off,enabled:model.fileListAvailable,inclusion:true) {
                            model.setFileChecked(entry,files:entries,highlighted:model.selection,checked:$0,receipt:checkReceipt)
                        }.frame(width:20,height:20)
                    }
                }
            }.width(24)
            TableColumn("Path", sortUsing: CommitFileSort(column: .path)) { (row: CommitSortableRow) in
                if let entry = row.entry {
                    HStack {
                        Image(nsImage: entry.state.icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16).overlay {
                            if model.restoreCopies[entry.path] != nil { Image(nsImage: MenuIcon.restoreOverlay.image() ?? NSImage()).resizable().frame(width: 16, height: 16) }
                        }
                        Text(model.fileListDisplayedPath(entry)).truncationMode(.middle).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)).background(NativeListSelectionLabelMarker())
                    }.frame(height:geometry.contentHeight).repositoryFileHelp(repository: model.repository.root, path: entry.path, detail: model.fileHelp(entry), preferences: model.colorPreferences)
                } else if let group = row.group {
                    HStack {
                        Text(verbatim:FileListLabels.groupTitle(group)).font(Font(geometry.groupFont)).foregroundStyle(Color.accentColor)
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
                    }.frame(height:geometry.contentHeight).help(changelistGroupHelp(group, lists: model.changelists)).accessibilityLabel(changelistGroupHelp(group, lists: model.changelists))
                }
            }.width(min: 260, ideal: 420)
            TableColumn("Filename", sortUsing: CommitFileSort(column: .fileName)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text((entry.path as NSString).lastPathComponent).help((entry.path as NSString).lastPathComponent).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)).frame(height:geometry.contentHeight) } else { groupRule }
            }.width(min: 100, ideal: 180)
            TableColumn("Extension", sortUsing: CommitFileSort(column: .fileExtension)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(StatusListClipboard.fileExtension(entry.path, isDirectory: model.submodules.contains(entry.path) || model.fileMetadata[entry.path]?.isDirectory == true)).help(StatusListClipboard.fileExtension(entry.path, isDirectory:model.submodules.contains(entry.path) || model.fileMetadata[entry.path]?.isDirectory == true)).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)).frame(height:geometry.contentHeight) }
                else { groupRule }
            }.width(min: 40, ideal: 75)
            TableColumn("Status", sortUsing: CommitFileSort(column: .status)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(FileListLabels.caption(entry.index == "R" || entry.worktree == "R" ? "Renamed" : statistics[entry.path]?.status ?? entry.state.rawValue.capitalized)).help(FileListLabels.caption(entry.index == "R" || entry.worktree == "R" ? "Renamed" : statistics[entry.path]?.status ?? entry.state.rawValue.capitalized)).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)).frame(height:geometry.contentHeight) }
                else { groupRule }
            }.width(min: 60, ideal: 90)
            TableColumn("Lines added", sortUsing: CommitFileSort(column: .added)) { (row: CommitSortableRow) in
                lineCount(row.row, statistics: statistics, selected: model.selection, added: true).frame(height:geometry.contentHeight)
            }.width(min: 40, ideal: 80)
            TableColumn("Lines removed", sortUsing: CommitFileSort(column: .removed)) { (row: CommitSortableRow) in
                lineCount(row.row, statistics: statistics, selected: model.selection, added: false).frame(height:geometry.contentHeight)
            }.width(min: 40, ideal: 95)
            TableColumn("Last modified", sortUsing: CommitFileSort(column: .lastModified)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.metadata?.dateText ?? "–").help(row.metadata?.dateText ?? "–").foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)).frame(height:geometry.contentHeight) } else { groupRule }
            }.width(min: 140, ideal: 180)
            TableColumn("File size", sortUsing: CommitFileSort(column: .fileSize)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.metadata?.sizeText ?? "–").help(row.metadata?.sizeText ?? "–").foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)).frame(height:geometry.contentHeight) } else { groupRule }
            }.width(min: 60, ideal: 90)
            TableColumn("LFS Lock", sortUsing: CommitFileSort(column: .lfsOwner)) { (row: CommitSortableRow) in
                if let entry = row.entry { Text(row.lfsOwner).help(row.lfsOwner).foregroundStyle(entry.statusTextColor(selected: model.selection.contains(entry.id), preferences: model.colorPreferences)).frame(height:geometry.contentHeight) } else { groupRule }
            }.width(min: 100, ideal: 160)
        }.tableStyle(.bordered(alternatesRowBackgrounds:false)).fileListFont().environment(\.defaultMinListRowHeight,geometry.rowHeight).lineLimit(1).truncationMode(.tail).contextMenu(forSelectionType: String.self) { nativeIDs in
            let requested = GitPathRowIdentity.paths(nativeIDs)
            TurtleGitContextMenu {
                let ids = requested.intersection(GitPathSet(entries.map(\.id)))
                let mark = StatusListSelection.mark(entries: entries, requested: ids, highlighted: model.selection, focusedPath: focus.wrappedValue)
                let menuSnapshot = model.fileMenu(ids, mark: mark?.id, orderedEntries: rows.compactMap(\.entry))
                if requested.count == 1, let group = rows.first(where: { requested.contains($0.id) })?.group {
                    let files = StatusListGroups.files(in: group, rows: rows)
                    let groupSnapshot = model.fileMenu(GitPathSet(files.map(\.id)), orderedEntries: files)
                    Button("Check group") { model.withFileMenu(groupSnapshot) { model.setGroupChecked(files, checked: true) } }.disabled(model.busy || model.confirmingQuit)
                    Button("Uncheck group") { model.withFileMenu(groupSnapshot) { model.setGroupChecked(files, checked: false) } }.disabled(model.busy || model.confirmingQuit)
                } else {
                    let selected = entries.filter { ids.contains($0.id) }
                    let flagFiles = model.indexFlagFiles.filter { ids.contains($0.id) }
                    let selectionMark = menuSnapshot.mark
                    if menuSnapshot.offersResolve {
                        ResolveSelectionMenu(paths:selected.map(\.path), rebase:model.conflictRebase, canEdit:selected.count == 1, action: { action, paths in model.withFileMenu(menuSnapshot) { model.onResolve(action, paths) } })
                        Divider()
                    }
                    if menuSnapshot.offersAdd {
                        ForEach(menuSnapshot.addModes(extended:NSEvent.modifierFlags.contains(.shift)), id: \.self) { mode in
                            Button { model.withFileMenu(menuSnapshot) { model.addFiles(selected, mode:mode) } } label: { CommandLabel(title:mode.rawValue, icon:.add) }.disabled(model.busy || model.confirmingQuit)
                        }
                        Divider()
                    }
                    if menuSnapshot.offersCompare {
                        Button { model.withFileMenu(menuSnapshot) { model.compare(paths: ids) } } label: { CommandLabel(title: "Compare with base", icon: .compare) }
                        if model.hasHead {
                            Button { model.withFileMenu(menuSnapshot) { model.diff(paths: ids, staged: staged, alternate: NSEvent.modifierFlags.contains(.shift)) } } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(model.busy || model.confirmingQuit)
                        }
                        Divider()
                    }
                    if selected.count == 2, selected.allSatisfy({ !model.submodules.contains($0.path) }) {
                        Button { model.fileAction(.compareTwo, snapshot: menuSnapshot) } label: { CommandLabel(title: "Compare two files", icon: .compare) }
                            .disabled(model.busy || model.confirmingQuit)
                        Divider()
                    }
                    if menuSnapshot.offersRevert {
                        Button { model.withFileMenu(menuSnapshot) { model.revertFiles(selected) } } label: { CommandLabel(title: "Revert", icon: .revert) }
                    }
                    if !selected.isEmpty && selected.allSatisfy({ ![FileState.untracked, .ignored].contains($0.state) && !model.submodules.contains($0.path) }) {
                        if let first = selected.first, model.restoreCopies[first.path] != nil {
                            Button { model.withFileMenu(menuSnapshot) { model.restoreNow(ids) } } label: { CommandLabel(title: "Restore", icon: .restore) }
                        } else {
                            Button { model.withFileMenu(menuSnapshot) { model.markForRestore(ids) } } label: { CommandLabel(title: "Restore after commit", icon: .restore) }
                        }
                    }
                    ForEach(model.lfsActions(selected), id: \.self) { action in
                        Button { model.withFileMenu(menuSnapshot) { model.setLFSLocked(ids, locked: action == .lock) } } label: { CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if !selected.isEmpty, let mark = model.indexFlagFiles.first(where: { GitReferenceName.equal($0.id,selectionMark?.id) }) {
                        IndexFlagsMenu(files: flagFiles, selectionMark: mark) { action in model.withFileMenu(menuSnapshot) { model.setFlags(action, files: flagFiles, selectionMark: mark) } }
                    }
                    if !selected.isEmpty, selected.allSatisfy({ $0.state != .deleted }) {
                        Button { model.withFileMenu(menuSnapshot) { FileTransferClipboard.copy(selected.map { model.repository.root.appendingPathComponent($0.path) }) } } label: { CommandLabel(title: "Copy files", icon: .copy) }
                        Button { model.withFileMenu(menuSnapshot) { model.onCopyAdd(selected.map(\.path)) } } label: { CommandLabel(title: "Copy and Add…", icon: .add) }
                    }
                    Button { let urls = FileTransferClipboard.urls(); model.withFileMenu(menuSnapshot) { model.onPasteFiles(true, urls) } } label: { CommandLabel(title: "Paste Copy and Add…", icon: .copy) }
                    Button { let urls = FileTransferClipboard.urls(); model.withFileMenu(menuSnapshot) { model.onPasteFiles(false, urls) } } label: { CommandLabel(title: "Paste Move…", icon: .rename) }
                    if !selected.isEmpty, selected.allSatisfy({ ![FileState.untracked, .ignored, .deleted].contains($0.state) }) {
                        Button { model.withFileMenu(menuSnapshot) { model.onMove(selected.map(\.path)) } } label: { CommandLabel(title: "Move…", icon: .rename) }
                    }
                    if selected.count == 1, let entry = selected.first {
                        Divider()
                        if entry.state != .untracked && entry.state != .ignored {
                            Button { model.fileAction(.log, snapshot: menuSnapshot) } label: { CommandLabel(title: "Show log", icon: .log) }
                            if model.submodules.contains(entry.path) { Button { model.fileAction(.submoduleLog, snapshot: menuSnapshot) } label: { CommandLabel(title: "Show submodule log", icon: .log) } }
                            if entry.state != .deleted {
                                Button { model.withFileMenu(menuSnapshot) { model.onRename(entry.path) } } label: { CommandLabel(title: "Rename…", icon: .rename) }
                            }
                            if entry.originalPath != nil {
                                Button { model.fileAction(.oldNameLog, snapshot: menuSnapshot) } label: { CommandLabel(title: "Show log of old name", icon: .log) }
                            }
                            if menuSnapshot.commands.contains(.blame) {
                                Button { model.fileAction(.blame, snapshot: menuSnapshot) } label: { CommandLabel(title: "Blame", icon: .blame) }
                            }
                        }
                    }
                    if menuSnapshot.commands.contains(.export) {
                        Button { model.fileAction(.export, snapshot: menuSnapshot) } label: { CommandLabel(title: "Export…", icon: .export) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if selected.count == 1 {
                        if menuSnapshot.commands.contains(.reveal) {
                            if menuSnapshot.commands.contains(.open) {
                                Button { model.fileAction(.editor, snapshot: menuSnapshot) } label: { CommandLabel(title: "View revision in alternative editor", icon: .editor) }.disabled(model.busy || model.confirmingQuit)
                                Button { model.fileAction(.open, snapshot: menuSnapshot) } label: { CommandLabel(title: "Open", icon: .open) }
                                Button { model.fileAction(.openWith, snapshot: menuSnapshot) } label: { CommandLabel(title: "Open With…", icon: .open) }
                            }
                            Button { model.fileAction(.reveal, snapshot: menuSnapshot) } label: { CommandLabel(title: "Reveal in Finder", icon: .explore) }
                        }
                    }
                    if !selected.isEmpty && selectionMark?.canDeleteFromStatusList == true {
                        Button { model.fileAction(.delete, snapshot: menuSnapshot, permanently: NSEvent.modifierFlags.contains(.shift)) } label: { CommandLabel(title: "Delete", icon: .remove) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if menuSnapshot.offersIgnore {
                        Divider()
                        IgnoreSelectionMenu(paths: selected.map(\.path), action: { action, paths in model.withFileMenu(menuSnapshot) { model.onIgnore(action, paths) } })
                    }
                    if !selected.isEmpty {
                        Divider()
                        Menu {
                            ForEach(CommitWindowModel.CopyFileInformation.allCases, id: \.self) { information in
                                Button { model.withFileMenu(menuSnapshot) { model.copyFiles(selected, information: information, staged: staged) } } label: { CommandLabel(title: information.rawValue, icon: .copy) }
                            }
                        } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }
                    }
                    // The pinned upstream gate compares legacy status values to action
                    // bits: only a pure Added action (1) is excluded, not UNVER (0x80000000).
                    if !selected.isEmpty, let mark = selectionMark, !(mark.index == "A" && mark.worktree == " ") {
                        Divider()
                        if selected.contains(where: { model.changelists.name(for: $0.path) != nil }) {
                            Button("Remove from changelist") { model.withFileMenu(menuSnapshot) { model.moveToChangelist(selected.map(\.path), name: nil) } }
                        }
                        Menu("Move to changelist") {
                            Button("<new changelist>") { model.withFileMenu(menuSnapshot) { model.newChangelist(selected) } }
                            Divider()
                            Button(GitChangelists.ignored) { model.withFileMenu(menuSnapshot) { model.moveToChangelist(selected.map(\.path), name: GitChangelists.ignored) } }
                            let names = model.changelists.nameIdentities.filter { $0.rawValue != GitChangelists.ignored }
                            if !names.isEmpty {
                                Divider()
                                ForEach(names, id: \.self) { name in Button(name.rawValue) { model.withFileMenu(menuSnapshot) { model.moveToChangelist(selected.map(\.path), name: name.rawValue) } }.help(changelistNameHelp(name, names: names)).accessibilityLabel(changelistNameHelp(name, names: names)) }
                            }
                        }
                        Toggle("Keep changelists", isOn: Binding(get: { model.keepChangelists }, set: { model.saveKeepChangelists($0) }))
                    }
                }
            }
        } primaryAction: { nativeIDs in
            let requested = GitPathRowIdentity.paths(nativeIDs)
            let ids = requested.intersection(GitPathSet(entries.map(\.id)))
            model.selection = ids
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }), entry.state == .conflicted { model.onResolve(.editConflict, [entry.path]) }
            else { model.compare(paths: ids) }
        }
        .background(CommitFileInteraction(rows: rows,uniformRowGeometry:geometry,captureWorkingDrag:{model.captureWorkingDrag($0)},workingDragOrigin:model.workingDragOrigin, configureRefresh: {dropTargets.set($0,for:focusKey);model.registerFileList($0,key:focusKey);model.fileListRefresh.attach($0)},preferences:model.colorPreferences, visibleColumns: Set(model.visibleFileColumns), availableColumns: model.availableFileColumns, columnText: { entry, column in
            String(StatusListClipboard.text([entry], root: model.repository.root, statistics: statistics, copy: .column(column), metadata: model.fileMetadata, lfsOwners: model.lfsOwners, label:FileListLabels.caption).dropLast())
        }, savedOrder: model.fileColumns.order, savedWidths: model.fileColumns.widths, saveLayout: { model.saveFileColumnLayout(order: $0, widths: $1) }, setColumnVisible: { model.setFileColumn($0, visible: $1) }, resetColumns: { choose, accepted in model.requestResetFileColumns(choose: choose, onAccepted: accepted) }, focusedPath: focus, enabled: model.fileListAvailable, delete: { model.deleteFiles($0, selectionMark: $1, permanently: $2) }, copy: { model.copyFileText($0, statistics: statistics, copy: $1 ? .pathsAndStatus : .relativePaths) }, copyColumn: { model.copyFileText($0, statistics: statistics, copy: .column($1)) }, toggleCheck: { files, mark in
            let next = model.stagingEnabled ? model.stagingState(mark) != .on : !model.checked.contains(mark.id)
            model.setFileChecked(mark, files: files, highlighted: GitPathSet(files.map(\.id)), checked: next,receipt:checkReceipt)
        }))
        .onDrop(of: [UTType.fileURL], delegate: CommitFileDropDelegate(model: model, targets: dropTargets, key: focusKey))
        .onChange(of: model.selection) { ids in
            let files = ids.intersection(GitPathSet(entries.map(\.id)))
            if files.count == 1 && NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { focus.wrappedValue = files.first }
        }
    }
    @ViewBuilder private func lineCount(_ row: StatusListRow, statistics: GitPathMap<CommitFile>, selected: some Sequence<String>, added: Bool) -> some View { let selected = GitPathSet(selected);
        if let entry = row.entry {
            let count: Int? = added ? statistics[entry.path]?.added : statistics[entry.path]?.removed
            let label = count.map { String($0) } ?? "–"
            Text(label).help(label).foregroundStyle(entry.statusTextColor(selected: selected.contains(entry.id), preferences: model.colorPreferences))
        } else { groupRule }
    }
    private var groupRule: some View { Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1) }
    func categoryButton(_ title:String,_ category:CommitCheckCategory)->some View {
        let receipt=model.fileCheckReceipt
        return checkButton(title,enabled:model.canCheckCategory(category)) {checking in
            model.checkCategory(category,checking:category == .none ? !checking:checking,receipt:receipt)
        }.accessibilityIdentifier("Commit.Check."+category.rawValue)
    }
    func checkButton(_ title: String, enabled: Bool = true, action: @escaping (Bool) -> Void) -> some View { let receipt=model.fileCheckReceipt;return Button {guard model.fileListAvailable,receipt==model.fileCheckReceipt else{return};action(!NSEvent.modifierFlags.contains(.shift))} label: {Text(LocalizedStringKey(title)).underline(enabled).fontWeight(title == "All" || title == "None" ? .semibold:.regular)}.buttonStyle(.plain).foregroundStyle(enabled ? Color.accentColor : Color.secondary).disabled(!enabled).help(title == "None" ? "Uncheck all files. Shift-click checks all files." : "Check matching files. Shift-click unchecks matching files.") }
}

/// Keep the source destination/issue bands on one line when they fit. At the
/// minimum window width, place issue controls below without duplicating fields
/// or losing their focus/selection identity during a resize.
struct CommitDestinationLayout:Layout {
    private func sizes(_ subviews:Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        let values = sizes(subviews), width = proposal.width ?? values.reduce(0) { $0 + $1.width } + 12
        guard values.count == 2 else { return CGSize(width:width,height:24) }
        let wrapped = values[1].width > 0 && values[0].width + values[1].width + 12 > width
        return CGSize(width:width,height:wrapped ? values[0].height + values[1].height + 6 : max(values[0].height,values[1].height))
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let values = sizes(subviews); guard values.count == 2 else { return }
        let wrapped = values[1].width > 0 && values[0].width + values[1].width + 12 > bounds.width
        subviews[0].place(at:CGPoint(x:bounds.minX,y:bounds.minY),proposal:.init(width:min(bounds.width,values[0].width),height:values[0].height))
        subviews[1].place(at:CGPoint(x:max(bounds.minX,bounds.maxX - values[1].width),y:wrapped ? bounds.minY + values[0].height + 6 : bounds.minY),proposal:.init(width:min(bounds.width,values[1].width),height:values[1].height))
    }
}
struct CommitDestinationLabel:NSViewRepresentable {
    let branch:String
    func makeNSView(context:Context) -> NSTextField {
        let field = NSTextField(labelWithString:branch)
        field.isSelectable = true; field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        field.setAccessibilityLabel("Commit destination"); field.identifier = .init("Commit destination")
        return field
    }
    func updateNSView(_ field:NSTextField,context:Context) {
        field.stringValue = branch; field.toolTip = branch; field.textColor = .linkColor
    }
}

/// The divider uses the system cursor; SwiftUI handles dragging and accessibility.
private struct CommitDividerCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {}
    final class CursorView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Only the source date control has a range. A rejected programmatic date
/// leaves its previous calendar day intact; the independent time still loads.
/// This is an editor rule, not a restriction on dates stored in Git history.
enum CommitAuthorDateControl {
    static var calendar:Calendar {var value=Calendar(identifier:.gregorian);value.timeZone = .current;return value}
    static func range(calendar:Calendar = CommitAuthorDateControl.calendar)->ClosedRange<Date> {
        let minimum=calendar.date(from:DateComponents(year:1970,month:1,day:1))!
        let maximum=calendar.date(from:DateComponents(year:2099,month:12,day:31))!
        return minimum...maximum
    }
    static func merging(day:Date,time:Date,calendar:Calendar = CommitAuthorDateControl.calendar)->Date {
        var values=calendar.dateComponents([.year,.month,.day],from:day)
        let clock=calendar.dateComponents([.hour,.minute,.second],from:time)
        values.hour=clock.hour;values.minute=clock.minute;values.second=clock.second
        return calendar.date(from:values) ?? day
    }
    static func loaded(_ value:Date,retainingDay previous:Date,calendar:Calendar = CommitAuthorDateControl.calendar)->Date {
        let limits=range(calendar:calendar)
        guard !limits.contains(value) else{return value}
        let day=min(limits.upperBound,max(limits.lowerBound,calendar.startOfDay(for:previous)))
        return merging(day:day,time:value,calendar:calendar)
    }
}

/// Upstream has separate date and time fields, including seconds.
private struct CommitDatePicker: NSViewRepresentable {
    @Binding var selection: Date
    @Environment(\.isEnabled) private var environmentEnabled
    let time: Bool
    let enabled: Bool
    let acceptsChanges: () -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection,time:time, acceptsChanges: acceptsChanges) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = CommitOwnedDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.datePickerElements = time ? .hourMinuteSecond : .yearMonthDay
        picker.calendar=CommitAuthorDateControl.calendar;picker.timeZone = .current
        if !time {let limits=CommitAuthorDateControl.range();picker.minDate=limits.lowerBound;picker.maxDate=limits.upperBound}
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setAccessibilityLabel(time ? "Author time" : "Author date")
        picker.identifier = .init(time ? "Commit author time":"Commit author date")
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        guard (picker as? CommitOwnedDatePicker)?.isRetired != true else{picker.isEnabled=false;return}
        context.coordinator.selection = $selection
        context.coordinator.acceptsChanges = acceptsChanges
        let value=time ? selection:CommitAuthorDateControl.calendar.startOfDay(for:selection)
        if picker.dateValue != value {picker.dateValue=value}
        picker.isEnabled = enabled && environmentEnabled
    }
    static func dismantleNSView(_ picker: NSDatePicker, coordinator: Coordinator) {
        picker.target = nil; picker.action = nil; picker.isEnabled = false
        coordinator.retired = true; coordinator.acceptsChanges = { false }
        (picker as? CommitOwnedDatePicker)?.retire()
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Date>
        let time:Bool
        var retired = false
        var acceptsChanges: () -> Bool
        init(selection: Binding<Date>,time:Bool, acceptsChanges: @escaping () -> Bool) {self.selection=selection;self.time=time;self.acceptsChanges=acceptsChanges}
        @objc func changed(_ sender: NSDatePicker) {
            guard !retired,sender.isEnabled,acceptsChanges(),(sender as? CommitOwnedDatePicker)?.hasOriginalOwner==true else { return }
            let previous=selection.wrappedValue
            selection.wrappedValue=CommitAuthorDateControl.merging(day:time ? previous:sender.dateValue,time:time ? sender.dateValue:previous)
        }
    }
}

@MainActor private final class CommitOwnedDatePicker:NSDatePicker {
    private weak var originalOwner:NSWindow?
    private var ownerBound=false,retired=false
    var isRetired:Bool{retired}
    var hasOriginalOwner:Bool {!retired && window != nil && window === originalOwner && window?.attachedSheet==nil && NSApp.modalWindow==nil}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if let window{if !ownerBound{ownerBound=true;originalOwner=window}else if originalOwner !== window{retire()}}}
    func retire(){retired=true;isEnabled=false;target=nil;action=nil}
}

/// Preserve TortoiseGit's three-state staging checkbox in the same file list.
private struct StagingCheckbox: NSViewRepresentable {
    let entry: StatusEntry
    let state: NSControl.StateValue
    let enabled: Bool
    var inclusion = false
    let change: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSButton {
        let button = StageButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = !inclusion
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.change = change
        context.coordinator.nextChecked = state != .on
        button.allowsMixedState = !inclusion
        button.state = state
        button.isEnabled=enabled && context.environment.isEnabled
        button.setAccessibilityLabel((inclusion ? "Include " : "Stage ") + entry.path)
        button.toolTip = inclusion ? "Include this file in the commit" : state != .off ? "Click to change staging; a mixed state stages the remaining working-tree changes." : "Click to stage the current file contents."
    }
    static func dismantleNSView(_ button:NSButton,coordinator:Coordinator) {
        button.isEnabled = false;button.target = nil;button.action = nil;coordinator.change = { _ in }
    }
    final class Coordinator: NSObject {
        var change: (Bool) -> Void
        // A mixed native checkbox can advance through NSCell's mixed state
        // before dispatch. Derive the requested operation from the Git snapshot.
        var nextChecked = true
        init(change: @escaping (Bool) -> Void) { self.change = change }
        @objc func clicked(_ sender: NSButton) { guard sender.isEnabled else {return};change(nextChecked) }
    }
    private final class StageButton: NSButton {
        override func setNextState() { state = state == .on ? .off : .on }
    }
}

enum CommitPostAction: String, CaseIterable, Hashable {
    case svnDCommit, push, pull, recommit, createTag
    var title: String { switch self { case .svnDCommit: return "SVN DCommit…"; case .push: return "Push…"; case .pull: return "Pull…"; case .recommit: return "ReCommit"; case .createTag: return "Create Tag…" } }
    var icon: MenuIcon { switch self { case .svnDCommit: return .commit; case .push: return .push; case .pull: return .pull; case .recommit: return .commit; case .createTag: return .tag } }
}
@MainActor final class CommitProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let action: CommitWindowModel.CompletionAction
    let staging: Bool
    let paths: GitPathSet
    let options: CommitOptions
    let cancellation = OperationCancellation()
    let cancellable: Bool
    var presentationPreferences: UserDefaults { preferences }
    private let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    @Published private(set) var busy = true
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    private(set) var isAbandoned = false
    var outputLimit: Int { outputState.limit }
    var actionLogEligible: Bool { !busy && !isAbandoned }
    @Published private(set) var completionRange: NSRange?
    private let startedAt = ProcessInfo.processInfo.systemUptime
    @Published private(set) var postActions: [CommitPostAction] = []
    private var resolved = false
    private var selected: CommitPostAction?
    private var waiter: CheckedContinuation<CommitPostAction?, Never>?
    private var autoCloseRequested = false
    var dismissWithoutWindow = false
    var onClose: () -> Void = {}
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var canCancel: Bool { !isAbandoned && busy && cancellable && !cancelling && !confirmingCancellation }
    init(repository: GitRepository, action: CommitWindowModel.CompletionAction, staging: Bool, paths: GitPathSet, options: CommitOptions, preferences: UserDefaults, cancellable: Bool) {
        self.repository = repository; self.action = action; self.staging = staging; self.paths = paths; self.options = options; self.preferences = preferences; self.autoClosePolicy = GitProgressAutoClose(preferences: preferences); self.cancellable = cancellable; outputState = GitProgressOutputState(preferences: preferences)
    }
    func complete(output: String, success: Bool, cancelled: Bool, postActions: [CommitPostAction], exitCode: Int32? = nil) {
        guard busy else { return }
        if !outputState.hasOutput && !isAbandoned {
            let parser = GitCliOutputParser(limit: outputState.limit)
            parser.appendChunk(Data(output.utf8)); outputState.consume(parser.processPending(), parser: parser); outputState.consume(parser.finish(), parser: parser)
        }
        self.output = isAbandoned ? "" : outputState.output; self.success = success; self.cancelled = cancelled
        let completion = SubmoduleProgressCompletion(success: success, cancelled: cancelled, exitCode: exitCode,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt, preferences: preferences)
        if !isAbandoned { currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &self.output) }
        self.postActions = isAbandoned ? [] : postActions; busy = false; cancelling = false
        if isAbandoned { choose(nil); return }
        if autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { choose(nil) }
    }
    func appendDiagnostic(_ text:String) {
        guard busy,!isAbandoned else{return}
        let diagnostic=GitCliOutputParser(limit:outputLimit)
        diagnostic.appendChunk(Data(("\n"+text+"\n").utf8))
        consume(diagnostic.processPending(),parser:diagnostic);consume(diagnostic.finish(),parser:diagnostic)
    }
    func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        guard busy, !isAbandoned else { return }
        outputState.consume(emission, parser: parser); output = outputState.output
        currentWork = outputState.currentWork; percentage = outputState.percentage
    }
    func invalidate() {
        guard !isAbandoned else { return }; isAbandoned = true; confirmingCancellation = false
        cancellation.cancel(); onClose = {}
    }
    func waitForChoice() async -> CommitPostAction? {
        if resolved { return selected }
        return await withCheckedContinuation { waiter = $0 }
    }
    func choose(_ action: CommitPostAction?) {
        guard !busy, !resolved else { return }
        if confirmingCancellation { if action == nil { autoCloseRequested = true }; return }
        guard action == nil || postActions.contains(action!) else { return }
        resolved = true; selected = action; onClose()
        waiter?.resume(returning: action); waiter = nil
    }
    func cancel() {
        guard canCancel else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, self.confirmingCancellation else { return }
                self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.cancellation.cancel() }
                else if !self.busy && self.autoCloseRequested { self.choose(nil) }
            }
        } else { cancelling = true; cancellation.cancel() }
    }
}
@MainActor final class CommitProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: CommitProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: CommitProgressWindowModel) {
        self.model = model
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Commit progress", preferences: model.presentationPreferences); window.minSize = NSSize(width: 620,height: 340); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CommitProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        model.onClose = { [weak window] in guard let window else { return }; window.sheetParent?.endSheet(window); window.close() }
        window.escapeAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.choose(nil) } }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            window.makeFirstResponder(nil)
            let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }

        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        guard sender.attachedSheet == nil, !model.confirmingCancellation else { return false }
        model.choose(nil); return false
    }
    func windowWillClose(_ notification: Notification) { if model.busy { model.invalidate() }; model.saveActionLog(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct CommitProgressDialog: View {
    @ObservedObject var model: CommitProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                .tint(model.busy ? .accentColor : model.success ? .blue : .red).accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text: model.output, completed: !model.busy, completionRange: model.completionRange, success: model.success)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }; Text(model.busy ? model.cancelling ? "Cancelling…" : "Committing…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Commit failed").foregroundStyle(model.busy ? Color.primary : model.success ? .green : .red); Spacer() }
            HStack {
                if let first = model.postActions.first {
                    Button { model.choose(first) } label: { CommandLabel(title: first.title,icon: first.icon) }.disabled(model.confirmingCancellation)
                    Menu { ForEach(model.postActions,id: \.self) { action in Button { model.choose(action) } label: { CommandLabel(title: action.title,icon: action.icon) } } } label: { Image(systemName: "chevron.down").accessibilityLabel("Commit post-actions") }.menuStyle(.borderlessButton).fixedSize().disabled(model.confirmingCancellation)
                }
                Spacer()
                Button("Close") { model.choose(nil) }.keyboardShortcut(.defaultAction).disabled(model.busy || model.confirmingCancellation)
                Button("Abort") { if model.busy { model.cancel() } else { model.choose(nil) } }.keyboardShortcut(.cancelAction)
                    .disabled(model.success || model.confirmingCancellation || model.busy && !model.canCancel)
            }
        }.padding(12)
        .gitDockProgress(.command(busy: model.busy, success: model.success, waiting: model.confirmingCancellation, percentage: model.percentage))
    }
}

/// Native commands belong to the active Commit owner, independently of the
/// repository selected in the main workspace. Static menu shapes survive tracking.
@MainActor final class CommitCommandMenu:NSObject,NSMenuItemValidation,NSMenuDelegate {
    enum Command:String,CaseIterable {
        case current="Current commit action",commit="Commit",recommit="ReCommit",push="Commit & Push"
        case refresh="Refresh",focus="Focus commit message",focusFiles="Focus file list",history="Recent messages…",hash="Pick commit hash…",message="Pick commit message…",pasteFiles="Paste file list",signOff="Add Signed-off-by"
        case all="All",none="None",unversioned="Unversioned",versioned="Versioned",added="Added",deleted="Deleted",modified="Modified",files="Files",submodules="Submodules"
        case staging="Staging support (EXPERIMENTAL)",showUnversioned="Show Unversioned Files",whole="Show Whole Project",messageOnly="Message only",amend="Amend Last Commit"
        case newBranch="new branch",amendComparison="Show diff to last commit",author="Set author",authorDate="Set author date",resetDate="Reset",noAutoSubmodules="Do not autoselect submodules"
        case focusBranch="Focus new branch name",focusAuthor="Focus author identity",focusDate="Focus author date",focusTime="Focus author time",focusIssue="Focus issue number",issues="Choose issues…"
        case patch="View Patch",partialStage="Partial Staging",partialUnstage="Partial Unstaging",help="Commit Help"
    }
    private final class Invocation {let command:Command,epoch:UUID;init(_ command:Command,_ epoch:UUID){self.command=command;self.epoch=epoch}}
    private weak var owner:CommitWindowController?
    private weak var installedMenu:NSMenu?
    private var root:NSMenuItem?,items=[NSMenuItem](),epoch=UUID(),retired=false,queued=false,rebuildNeeded=true
    private var trackedMenus=Set<ObjectIdentifier>()
    private var observations=[AnyCancellable]()
    var applicationMenu:()->NSMenu? = {NSApp.mainMenu}
    var keyWindow:()->NSWindow? = {NSApp.keyWindow}
    var modifierFlags:()->NSEvent.ModifierFlags = {NSEvent.modifierFlags}
    init(owner:CommitWindowController) {
        self.owner=owner;super.init()
        observations.append(owner.model.objectWillChange.sink { [weak self] _ in self?.schedule() })
        observations.append(NotificationCenter.default.publisher(for:NSApplication.didUpdateNotification).sink { [weak self] _ in self?.schedule(retiring:false) })
    }
    private var active:Bool {!retired && owner?.model.gitGuiInterface == false && owner?.model.messageFocusAvailable==true && keyWindow() === owner?.window}
    private var ready:Bool {active && owner?.commandsAvailable==true}
    private func schedule(retiring:Bool=true) {
        guard !retired else{return}
        if retiring{epoch=UUID();rebuildNeeded=true}
        guard !queued else{return};queued=true
        DispatchQueue.main.async { [weak self] in guard let self else {return};self.queued=false;if self.active {self.install();self.refresh()} }
    }
    func install() {
        guard active,trackedMenus.isEmpty,let main=applicationMenu() else {return}
        if !rebuildNeeded,installedMenu === main,root?.menu === main {refresh();return}
        remove();installedMenu=main
        rebuildNeeded=false
        for item in main.items where item.identifier?.rawValue=="TurtleGit.Commit.Commands" {main.removeItem(item)}
        let root=NSMenuItem(title:NSLocalizedString("Commit",comment:""),action:nil,keyEquivalent:"");root.identifier = .init("TurtleGit.Commit.Commands");root.image=MenuIcon.commit.contextImage(defaults:owner?.presentationPreferences ?? .standard)
        let menu=NSMenu(title:NSLocalizedString("Commit",comment:""));menu.delegate=self;root.submenu=menu;self.root=root
        func append(_ commands:[Command],to menu:NSMenu) {
            for command in commands {
                let binding=shortcut(command),item=NSMenuItem(title:NSLocalizedString(command.rawValue,comment:""),action:#selector(invoke(_:)),keyEquivalent:binding?.0 ?? "")
                item.keyEquivalentModifierMask=binding?.1 ?? [];item.target=self;item.representedObject=Invocation(command,epoch)
                item.identifier = .init("TurtleGit.Commit.Form."+String(describing:command))
                item.image=icon(command).contextImage(defaults:owner?.presentationPreferences ?? .standard)
                menu.addItem(item);items.append(item)
            }
        }
        func group(_ title:String,_ commands:[Command],icon:MenuIcon) {let caption=NSLocalizedString(title,comment:"");let item=NSMenuItem(title:caption,action:nil,keyEquivalent:"");let child=NSMenu(title:caption);child.delegate=self;item.representedObject=icon.rawValue;item.image=icon.contextImage(defaults:owner?.presentationPreferences ?? .standard);item.submenu=child;menu.addItem(item);append(commands,to:child)}
        append([.current],to:menu);group("Commit actions",[.commit,.recommit,.push],icon:.commit);menu.addItem(.separator())
        group("Check files",[.all,.none,.unversioned,.versioned,.added,.deleted,.modified,.files,.submodules],icon:.add)
        group("Message",[.focus,.history,.hash,.message,.pasteFiles,.signOff,.focusIssue,.issues],icon:.editor);append([.focusFiles],to:menu)
        group("Options",[.newBranch,.amend,.amendComparison,.authorDate,.resetDate,.author,.staging,.showUnversioned,.noAutoSubmodules,.whole,.messageOnly],icon:.settings)
        group("Focus",[.focusBranch,.focusAuthor,.focusDate,.focusTime],icon:.editor)
        append([.patch,.partialStage,.partialUnstage,.refresh,.help],to:menu)
        let index=main.items.firstIndex(where:{item in
            item.submenu.map {$0 === NSApp.windowsMenu || $0 === NSApp.helpMenu} == true || ["Window","Help",NSLocalizedString("Window",comment:""),NSLocalizedString("Help",comment:"")].contains(item.title)
        }) ?? main.numberOfItems
        main.insertItem(root,at:index);refresh()
    }
    func remove() {epoch=UUID();rebuildNeeded=true;if let root,let menu=root.menu {menu.removeItem(root)};root=nil;installedMenu=nil;items=[]}
    func retire() {remove();retired=true;observations=[];owner=nil}
    func menuWillOpen(_ menu:NSMenu) {trackedMenus.insert(ObjectIdentifier(menu));refresh()}
    func menuDidClose(_ menu:NSMenu) {
        trackedMenus.remove(ObjectIdentifier(menu));let captured=epoch
        DispatchQueue.main.async{[weak self] in guard let self,self.epoch==captured else{return};self.schedule()}
    }
    func menuNeedsUpdate(_ menu:NSMenu) {refresh()}
    private func attached(_ item:NSMenuItem)->Bool {
        guard let main=installedMenu,main === applicationMenu(),root?.menu === main else {return false}
        var menu=item.menu
        while let current=menu {if current === main {return true};menu=current.supermenu}
        return false
    }
    private func category(_ command:Command)->CommitCheckCategory? {
        switch command {
        case .all:return .all;case .none:return CommitCheckCategory.none;case .unversioned:return .unversioned;case .versioned:return .versioned
        case .added:return .added;case .deleted:return .deleted;case .modified:return .modified;case .files:return .files;case .submodules:return .submodules
        default:return nil
        }
    }
    private func enabled(_ command:Command)->Bool {
        guard active,let owner else{return false}
        if command == .refresh {return owner.refreshCommandAvailable}
        guard ready else{return false};let model=owner.model
        switch command {
        case .current,.commit:return model.canCommit
        case .recommit,.push:return model.canCommit && model.replaySplit==nil && model.historyCombine==nil
        case .all,.none,.unversioned,.versioned,.added,.deleted,.modified,.files,.submodules:return category(command).map{model.canCheckCategory($0)} ?? false
        case .focusFiles:return model.fileListAvailable && owner.fileTable() != nil
        case .history:return model.messageHistory?.entries.isEmpty==false && owner.messageEditor() != nil
        case .hash,.message,.pasteFiles:return owner.messageEditor() != nil
        case .whole:return !model.scopePaths.isEmpty
        case .amend:return model.hasHead && model.operation==nil && model.replaySplit==nil && model.historyCombine==nil
        case .newBranch:return model.canChangeFormOption(.newBranch)
        case .amendComparison:return model.canChangeFormOption(.amendComparison)
        case .author:return model.canChangeFormOption(.author)
        case .authorDate:return model.canChangeFormOption(.authorDate)
        case .resetDate:return model.canChangeFormOption(.resetDate)
        case .noAutoSubmodules:return model.canChangeFormOption(.noAutoSubmodules)
        case .focusBranch:return model.nativeNewBranchInputAvailable
        case .focusAuthor:return !model.loadingAuthorIdentity
        case .focusDate,.focusTime:return model.nativeAuthorDateInputAvailable
        case .focusIssue:return model.issueProperties.showsIssueField
        case .issues:return model.nativeIssueProvider != nil
        case .patch:return !model.stagingEnabled
        case .partialStage,.partialUnstage:return model.stagingEnabled && !model.selection.isEmpty
        default:return true
        }
    }
    private func checked(_ command:Command)->Bool {
        guard let model=owner?.model else {return false}
        switch command {
        case .commit:return model.currentCompletionAction == .commit
        case .recommit:return model.currentCompletionAction == .recommit
        case .push:return model.currentCompletionAction == .push
        case .staging:return model.stagingEnabled
        case .showUnversioned:return model.showUnversioned
        case .whole:return model.showWholeProject
        case .messageOnly:return model.messageOnly
        case .amend:return model.amend
        case .newBranch:return model.createBranch
        case .amendComparison:return model.amendDiffToLastCommit
        case .author:return model.setAuthor
        case .authorDate:return model.setAuthorDate
        case .resetDate:return model.resetAuthorDate
        case .noAutoSubmodules:return model.doNotAutoselectSubmodules
        case .patch:return model.viewingPatch
        case .partialStage:return model.partialMode==false
        case .partialUnstage:return model.partialMode==true
        default:return false
        }
    }
    private func refresh() {
        let preferences=owner?.presentationPreferences ?? .standard
        root?.image=MenuIcon.commit.contextImage(defaults:preferences)
        for group in root?.submenu?.items ?? [] {if let name=group.representedObject as? String,let icon=MenuIcon(rawValue:name) {group.image=icon.contextImage(defaults:preferences)}}
        for item in items {guard let invocation=item.representedObject as? Invocation else {continue};let command=invocation.command;item.image=icon(command).contextImage(defaults:preferences);item.isEnabled=invocation.epoch==epoch && attached(item) && enabled(command);item.state=checked(command) ? .on:.off;if command == .current {item.title=NSLocalizedString(owner?.model.currentCompletionAction.rawValue ?? command.rawValue,comment:"")}}
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {guard let invocation=item.representedObject as? Invocation else {return false};return invocation.epoch==epoch && attached(item) && enabled(invocation.command)}
    @objc private func invoke(_ item:NSMenuItem) {
        guard validateMenuItem(item),let invocation=item.representedObject as? Invocation else {return}
        epoch=UUID();rebuildNeeded=true
        perform(invocation.command);refresh();schedule(retiring:false)
    }
    private func perform(_ command:Command) {
        guard enabled(command),let owner else {return};let model=owner.model
        switch command {
        case .current:model.commitCurrentAction()
        case .commit:model.commit(.commit)
        case .recommit:model.commit(.recommit)
        case .push:model.commit(.push)
        case .refresh:model.reload()
        case .focus:model.focusMessage()
        case .focusFiles:owner.focusFileList()
        case .focusBranch:owner.focusFormField("Commit new branch")
        case .focusAuthor:owner.focusFormField("Commit author")
        case .focusDate:owner.focusFormField("Commit author date")
        case .focusTime:owner.focusFormField("Commit author time")
        case .focusIssue:model.focusIssueField()
        case .issues:model.selectProviderIssues()
        case .history,.hash,.message,.pasteFiles:owner.messageEditor()?.performCommitMenuCommand(command)
        case .signOff:model.addSignOff()
        case .all,.none,.unversioned,.versioned,.added,.deleted,.modified,.files,.submodules:
            let shift=modifierFlags().contains(.shift),value=command == .none ? shift:!shift
            if let category=category(command) {model.checkCategory(category,checking:value,receipt:model.fileCheckReceipt)}
        case .staging:model.setStagingEnabled(!model.stagingEnabled)
        case .showUnversioned:model.setShowUnversioned(!model.showUnversioned)
        case .whole:model.setShowWholeProject(!model.showWholeProject)
        case .messageOnly:model.messageOnly.toggle()
        case .amend:model.amend.toggle()
        case .newBranch:model.setFormOption(.newBranch,value:!model.createBranch,receipt:model.formReceipt)
        case .amendComparison:model.setFormOption(.amendComparison,value:!model.amendDiffToLastCommit,receipt:model.formReceipt)
        case .author:model.setFormOption(.author,value:!model.setAuthor,receipt:model.formReceipt)
        case .authorDate:model.setFormOption(.authorDate,value:!model.setAuthorDate,receipt:model.formReceipt)
        case .resetDate:model.setFormOption(.resetDate,value:!model.resetAuthorDate,receipt:model.formReceipt)
        case .noAutoSubmodules:model.setFormOption(.noAutoSubmodules,value:!model.doNotAutoselectSubmodules,receipt:model.formReceipt)
        case .patch:model.showViewPatch()
        case .partialStage:model.showPartial(false)
        case .partialUnstage:model.showPartial(true)
        case .help:TurtleGitHelp.show(.commit)
        }
    }
    func performKeyEquivalent(_ event:NSEvent)->Bool {
        guard active else {return false};install()
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode==96,flags.isEmpty {if enabled(.refresh) {perform(.refresh)};return true}
        if [36,76].contains(event.keyCode),flags == .control {if enabled(.current) {perform(.current)};return true}
        guard let text=event.charactersIgnoringModifiers?.lowercased() else {return false}
        if flags == .option,["m","f","d","t"].contains(text),!((owner?.window?.firstResponder as? NSTextView)?.isEditable ?? false) {
            let command:Command=text == "m" ? .focus:text == "f" ? .focusFiles:text == "d" ? .authorDate:.author
            if enabled(command) {perform(command)};return true
        }
        for item in items {guard let invocation=item.representedObject as? Invocation,let binding=shortcut(invocation.command),binding.0.lowercased()==text,binding.1==flags,attached(item) else {continue};if enabled(invocation.command) {invoke(item)};return true}
        return false
    }
    private func shortcut(_ command:Command)->(String,NSEvent.ModifierFlags)? {
        switch command {
        case .current:return ("\r",.command)
        case .recommit:return ("\r",[.command,.option])
        case .push:return ("\r",[.command,.shift])
        case .refresh:return (String(UnicodeScalar(NSF5FunctionKey)!),[])
        case .focus:return ("m",[.command,.option])
        case .focusFiles:return ("f",[.command,.option])
        case .newBranch:return ("n",[.command,.option])
        case .author:return ("t",[.command,.option])
        case .authorDate:return ("d",[.command,.option])
        case .resetDate:return ("r",[.command,.option])
        case .focusIssue:return ("i",[.command,.option])
        default:return nil
        }
    }
    private func icon(_ command:Command)->MenuIcon {
        switch command {
        case .push:return .push
        case .current,.commit,.recommit,.amend,.signOff:return .commit
        case .refresh:return .refresh
        case .focus,.messageOnly:return .editor
        case .focusFiles:return .status
        case .history,.hash,.message:return .log
        case .pasteFiles:return .copy
        case .help:return .help
        case .patch,.partialStage,.partialUnstage:return .patch
        case .whole:return .repositoryBrowser
        case .newBranch,.focusBranch:return .branch
        case .amendComparison:return .compare
        case .author,.focusAuthor:return .settingsGit
        case .authorDate,.resetDate,.focusDate,.focusTime:return .log
        case .noAutoSubmodules:return .fetch
        case .focusIssue,.issues:return .settingsIssueTracker
        case .none:return .revert
        default:return .add
        }
    }
}

/// Only the essential staging actions are exposed in the alternative workspace.
private struct GuiCommitPatch: View {
    @ObservedObject var model: PatchWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.staged ? "HEAD → Index" : "Index → Working tree").font(.headline)
                Spacer()
                Button(model.staged ? "Unstage lines" : "Stage lines") { model.apply(entireHunks: false) }.disabled(!model.canApplyLines)
                Button(model.staged ? "Unstage chunks" : "Stage chunks") { model.apply(entireHunks: true) }.disabled(!model.canApplyHunks)
            }
            PatchDialog(model: model)
            Text(model.information).font(.caption).foregroundStyle(.secondary)
        }
    }
}
