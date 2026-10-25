// SPDX-License-Identifier: GPL-2.0-or-later
// AppUtils::RebaseAfterFetch exports into the repository before SendPatchMail.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RebaseCompletionMailWindowModel:ObservableObject {
    private(set) static var activeOperations=0
    let repository:GitRepository
    let access:RepositoryAccessLease?
    let preset:FormatPatchPreset
    let preferences:UserDefaults
    @Published private(set) var busy=false
    @Published private(set) var success=false
    @Published private(set) var cancelled=false
    @Published private(set) var output=""
    @Published private(set) var error:String?
    @Published private(set) var files=[URL]()
    @Published private(set) var retired=false
    @Published var confirmingQuit=false
    private var cancellation:OperationCancellation?
    private(set) var started=false
    var onSettled:()->Void={}
    var hasPendingWork:Bool {busy}
    var empty:Bool {success && files.isEmpty}
    init(repository:GitRepository,access:RepositoryAccessLease?,preset:FormatPatchPreset,preferences:UserDefaults) {
        self.repository=repository;self.access=access;self.preset=preset;self.preferences=preferences
    }
    func start() {
        guard !started,!retired,!confirmingQuit else{return};started=true;busy=true
        let token=OperationCancellation();cancellation=token;Self.activeOperations += 1;LocalGitCommandProgress.begin()
        Task {
            defer {
                Self.activeOperations -= 1;LocalGitCommandProgress.end();busy=false;cancellation=nil
                withExtendedLifetime(access){}
                onSettled()
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) {throw RepositoryAccessFailure.securityScopeUnavailable}
                let receipt=try await LocalGitCommandProgress.stream(preferences:preferences,update:{ [weak self] state in
                    guard let self,!self.retired else{return};self.output=state.output
                },resultText:{$0.result.text}) { [repository,preset] emit in
                    try await repository.formatPatchFiles(selection:preset.selection,to:repository.root,noPrefix:false,cancellation:token,onOutput:emit,onCommand:{command in emit(.init(stream:.stdout,data:command.preamble))})
                }
                guard !retired else{return};try token.check()
                files=receipt.files;success=true
            } catch {
                guard !retired else{return}
                cancelled=token.isCancelled || error is OperationCancellationFailure || error is GitCommandCancellationFailure
                self.error=error.localizedDescription
                output=LocalGitCommandProgress.failure(error,existing:output,preferences:preferences)
                if cancelled {output += "\nAny patches written before cancellation remain in the output directory.\n"}
            }
        }
    }
    func cancel() {guard busy,!retired,!confirmingQuit else{return};cancellation?.cancel()}
    func invalidate() {guard !retired else{return};retired=true;cancellation?.cancel()}
}

@MainActor final class RebaseCompletionMailWindowController:NSWindowController,NSWindowDelegate {
    private(set) static var activeReleases=0
    let model:RebaseCompletionMailWindowModel
    var onClosed:()->Void={}
    private(set) var mail:SendMailWorkflow?
    private(set) var notice:NSAlert?
    private var retired=false,completed=false,closingForMail=false,pendingClose=false,started=false
    private var transition=UUID()
    private var drain:Task<Void,Never>?
    private let presentation:((NSWindowController)->Void)?
    var confirmingQuit:Bool {
        get {model.confirmingQuit}
        set {
            model.confirmingQuit=newValue
            mail?.progress?.model.confirmingQuit=newValue
            if !newValue {
                if closingForMail,mail==nil,drain==nil {presentMail()}else{settled()}
            }
        }
    }
    var activeOperation:Bool {model.hasPendingWork || notice != nil || mail?.hasPendingWork == true}
    var transportBatchWorkPending:Bool {activeOperation || drain != nil || window?.sheetParent != nil || window?.attachedSheet != nil}
    var canPresent:Bool {!retired && !completed}
    init(repository:GitRepository,access:RepositoryAccessLease?,preset:FormatPatchPreset,preferences:UserDefaults,presentation:((NSWindowController)->Void)?=nil) {
        model=RebaseCompletionMailWindowModel(repository:repository,access:access,preset:preset,preferences:preferences);self.presentation=presentation
        let window=SubmoduleProgressNativeWindow(contentRect:NSRect(x:0,y:0,width:760,height:430),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentMinSize=NSSize(width:650,height:320)
        RepositoryWindowTitles.set(window,repository:repository.root,dialog:"Send Mail",preferences:preferences)
        super.init(window:window);window.delegate=self
        window.contentViewController=NSHostingController(rootView:RebaseCompletionMailDialog(model:model,cancel:{ [weak self] in self?.requestClose() }).defaultAppStorage(preferences))
        window.escapeAction={ [weak self] in self?.requestClose() }
        model.onSettled={ [weak self] in self?.settled() }
        NotificationCenter.default.addObserver(self,selector:#selector(sheetEnded),name:NSWindow.didEndSheetNotification,object:window)
    }
    @objc private func sheetEnded(){DispatchQueue.main.async{ [weak self] in self?.settled()}}
    deinit {NotificationCenter.default.removeObserver(self)}
    func start() {guard canPresent,!started else{return};started=true;showWindow(nil);window?.makeKeyAndOrderFront(nil);model.start()}
    func requestClose() {
        guard !retired,!confirmingQuit else{return}
        if model.busy {pendingClose=true;model.cancel();return}
        guard notice==nil,window?.attachedSheet==nil else{return};close()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard !retired,!confirmingQuit else{return false}
        if model.busy {pendingClose=true;model.cancel();return false}
        return notice==nil && sender.attachedSheet==nil
    }
    func windowWillClose(_ notification:Notification) {
        guard notification.object as? NSWindow === window else{return}
        if !retired,closingForMail {waitForProgressRelease()}
        else {invalidate()}
    }
    override func close() {invalidate();super.close()}
    func invalidate() {
        guard !retired else{return};retired=true;transition=UUID();pendingClose=false;model.invalidate()
        if let notice {window?.endSheet(notice.window,returnCode:.abort);notice.window.orderOut(nil);self.notice=nil}
        mail?.invalidate();waitForDrain()
    }
    private func settled() {
        guard model.started,!retired,!completed,!model.busy,!confirmingQuit,notice==nil,mail==nil,!closingForMail else {
            if retired {waitForDrain()};return
        }
        if pendingClose {close();return}
        guard let window,window.attachedSheet==nil else{return}
        if model.success,!model.files.isEmpty {
            closingForMail=true;window.close();return
        }
        // Empty output is a successful informational result, never an empty
        // composer. Failed/cancelled exports retain their actual diagnostic.
        let alert=NSAlert();alert.alertStyle=model.success || model.cancelled ? .informational:.critical
        alert.messageText=model.empty ? "No patches were created to attach.":model.cancelled ? "Operation cancelled":"Git command failed"
        alert.informativeText=model.empty ? "The selected range contains no patches.":(model.error ?? "") + (model.cancelled ? "\nAny patches written before cancellation remain in the output directory.":"")
        alert.addButton(withTitle:"OK")
        MergeWindowPresentation(window).apply(to:alert.window);notice=alert
        let accepted=transition
        alert.beginSheetModal(for:window){ [weak self,weak alert] _ in
            guard let self,let alert,self.notice===alert else{return}
            self.notice=nil
            guard !self.retired,self.transition==accepted else{return}
            self.waitForNoticeRelease(alert.window)
        }
    }
    private func scheduleDrain(ready:@escaping()->Bool,finished:@escaping()->Void) {
        drain?.cancel();drain=nil
        Self.activeReleases += 1
        drain=Task { [self] in
            defer{Self.activeReleases -= 1}
            while !Task.isCancelled,!ready() {try? await Task.sleep(nanoseconds:20_000_000)}
            guard !Task.isCancelled else{return};drain=nil;finished()
        }
    }
    private func waitForNoticeRelease(_ sheet:NSWindow) {
        let accepted=transition;pendingClose=true
        scheduleDrain(ready:{sheet.sheetParent==nil}) { [weak self] in
            guard let self,!self.retired,self.transition==accepted else{return}
            if !self.confirmingQuit {self.close()}
        }
    }
    private func waitForProgressRelease() {
        let accepted=transition
        scheduleDrain(ready:{ [self] in window?.sheetParent==nil && window?.attachedSheet==nil }) { [weak self] in
            guard let self,!self.retired,self.transition==accepted else{return}
            self.presentMail()
        }
    }
    private func presentMail() {
        guard !retired,!confirmingQuit,closingForMail,mail==nil,model.success,!model.files.isEmpty,let window else{return}
        let snapshot=MergeWindowPresentation(window)
        let workflow=SendMailWorkflow(files:model.files,repository:model.repository,access:model.access,fileAccess:model.access.map{[$0]} ?? [],preferences:model.preferences,presentation:{ [weak self] controller in
            guard let self,!self.retired,!self.confirmingQuit else{return}
            if let child=controller.window {snapshot.apply(to:child)}
            if let presentation=self.presentation {presentation(controller)}else{controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
        }) { [weak self] _ in
            guard let self else{return};self.mail=nil;self.retired=true;self.model.invalidate();self.waitForDrain()
        }
        mail=workflow;workflow.start()
    }
    private func waitForDrain() {
        scheduleDrain(ready:{ [self] in
            !model.hasPendingWork && mail?.hasPendingWork != true && window?.sheetParent==nil && window?.attachedSheet==nil
        }) { [weak self] in
            guard let self,!self.completed else{return};self.mail=nil;self.completed=true
            let callback=self.onClosed;self.onClosed={};callback()
        }
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}

private struct RebaseCompletionMailDialog:View {
    @ObservedObject var model:RebaseCompletionMailWindowModel
    let cancel:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.busy ? "Creating patches…":model.success ? "Finished":model.cancelled ? "Cancelled":"Failed")
            if model.busy {ProgressView().progressViewStyle(.linear)}
            SubmoduleProgressOutputView(text:model.output,completed:!model.busy,success:model.success,preferences:model.preferences)
            HStack {Spacer();Button(model.busy ? "Cancel":"Close",action:cancel).keyboardShortcut(.cancelAction).disabled(model.confirmingQuit)}
        }.padding(12)
    }
}
