// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import Combine
import TurtleGitCore

/// One waiting standalone IDiff command. Captured grants outlive native close
/// until accepted reads, writes, choices and optional input cleanup actually drain.
@MainActor final class ImageToolLaunchSession {
    private(set) static var activePreparations=0
    let invocation:ImageToolInvocation,preferences:UserDefaults
    private weak var owner:NSWindow?
    private var ownerObserver:NSObjectProtocol?
    private var grants:[RepositoryAccessLease]
    private let cancellation=OperationCancellation()
    private var started=false,retired=false,finishing=false,completed=false,replacing=false
    private(set) var preparing=false
    private(set) var editor:NSWindowController?
    private(set) var opener:ImageLoadWindowController?
    private var retiredEditors:[NSWindowController]=[]
    private var panel:NSOpenPanel?,panelAnswer:((URL?)->Void)?,validator:ImageToolAuthorizationValidator?
    private var retiringPanels:[NSOpenPanel]=[]
    private var cleanupInputs:[ImageToolCleanupInput]=[]
    private var editorObservation:AnyCancellable?
    private var authorizationFailure:Error?
    var requiresScopes=GitRuntime.isAppStoreBuild
    var authorize:((URL,Bool) async throws -> RepositoryAccessLease?)?
    var makePermissionLease:(URL)->RepositoryAccessLease={RepositoryAccessLease(url:$0)}
    var selectedPermissionURL:(NSOpenPanel)->URL?={$0.url}
    var presentPermissionPanel:(NSOpenPanel,NSWindow?,@escaping(NSApplication.ModalResponse)->Void)->Void={panel,owner,reply in
        if let owner,owner.isVisible,owner.attachedSheet==nil{panel.beginSheetModal(for:owner,completionHandler:reply)}else{panel.begin(completionHandler:reply)}
    }
    var captureSelection:(ImageToolInvocation,OperationCancellation) async throws -> ImageSelectionDocument={invocation,token in try await Task.detached{try ImageSelectionDocument.capture(invocation:invocation,cancellation:token)}.value}
    var configureSelection:(ImageSelectionWindowController)->Void={_ in}
    var presentation:((NSWindowController)->Void)?
    var onError:(String)->Void={_ in}
    var onFinished:(Int32)->Void={_ in}
    var ownsCurrentFrame:Bool {
        guard let window=NSApp.keyWindow,window.isVisible,window.attachedSheet==nil,NSApp.modalWindow==nil else{return false}
        return window === opener?.window || window === editor?.window
    }
    var canCloseWindow:Bool {
        guard !retired else{return false}
        if opener?.window != nil{return true}
        if let selection=editor as? ImageSelectionWindowController{return !selection.model.busy || selection.model.decoding}
        if let comparison=editor as? FileComparisonWindowController{return comparison.model.copyCommandsAllowed && !comparison.model.confirmingQuit && !comparison.preparingReplacement && comparison.editorOpenWorkflow==nil}
        return false
    }
    func closeWindow(){(opener?.window ?? editor?.window)?.performClose(nil)}
    var canOpenImages:Bool{!retired && !preparing && !finishing && !invocation.isSelection && opener==nil && panel==nil && !editorPending}
    private func pending(_ controller:NSWindowController)->Bool {
        if let selection=controller as? ImageSelectionWindowController{return selection.model.hasPendingWork}
        if let comparison=controller as? FileComparisonWindowController{return comparison.model.mergeToolHasPendingWork || comparison.model.imageViewerModel.hasPendingFileRead}
        return false
    }
    private var editorPending:Bool{(editor.map(pending) ?? false) || retiredEditors.contains(where:pending)}
    var hasPendingWork:Bool{preparing || finishing || panel != nil || !retiringPanels.isEmpty || opener != nil || editorPending}
    init(invocation:ImageToolInvocation,preferences:UserDefaults,owner:NSWindow?,permissions:[RepositoryAccessLease]=[]){
        self.invocation=invocation;self.preferences=preferences;self.owner=owner;grants=permissions
        if let owner{ownerObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:owner,queue:.main){[weak self] _ in MainActor.assumeIsolated{if self?.preparing==true{self?.cancel()}}}}
    }
    deinit{if let ownerObserver{NotificationCenter.default.removeObserver(ownerObserver)}}
    func start(){
        guard !started,!retired else{return};started=true;preparing=true;Self.activePreparations+=1;ImageToolMenuContext.shared.install(self)
        Task{[self] in
            defer{preparing=false;Self.activePreparations-=1;ImageToolMenuContext.shared.refresh()}
            do{
                let inputs=invocation.isSelection ? [invocation.base,invocation.mine,invocation.theirs]:[invocation.left,invocation.right]
                for file in inputs.compactMap({$0}){
                    let exists=FileManager.default.fileExists(atPath:file.path)
                    let requested:URL
                    if exists{requested=file}else{requested=try await Task.detached{try MergeOutputDirectories(capturing:file).ancestor}.value}
                    try await permission(for:requested,folder:!exists)
                }
                if let result=invocation.result{
                    let plan=try await Task.detached{try MergeOutputDirectories(capturing:result)}.value
                    try await permission(for:plan.ancestor,folder:true)
                }
                try cancellation.check();guard !retired else{return}
                if invocation.isSelection{
                    let document=try await captureSelection(invocation,cancellation)
                    try cancellation.check();guard !retired else{return}
                    if invocation.deleteInputsOnClose{
                        let inputs=[invocation.base,invocation.mine,invocation.theirs].compactMap{$0}
                        cleanupInputs=try await Task.detached{try inputs.compactMap(ImageToolCleanupInput.capture)}.value
                    }
                    try cancellation.check();guard !retired else{return}
                    let controller=ImageSelectionWindowController(document:document,permissions:grants,preferences:preferences)
                    controller.model.requiresScopes=requiresScopes
                    configureSelection(controller)
                    controller.onFinished={[weak self] status in self?.finish(status)}
                    controller.onClosed={[weak self,weak controller] in guard let self else{return};if self.editor === controller{self.finish(0)}}
                    present(controller)
                }else if invocation.opensChooser{showOpenImages()}else if invocation.left != nil || invocation.right != nil{
                    try showComparison(ImageFileComparison(base:invocation.left,destination:invocation.right))
                }else{showOpenImages()}
            }catch{
                if !cancellation.isCancelled{onError(error.localizedDescription)}
                finish(cancellation.isCancelled ? 0:64)
            }
        }
    }
    private func permission(for url:URL,folder:Bool)async throws{
        try cancellation.check()
        if grants.contains(where:{$0.contains(url) && (!requiresScopes || $0.hasSecurityScope)}){return}
        let lease:RepositoryAccessLease?
        if let authorize{lease=try await authorize(url,folder);if lease==nil{throw ImageToolAuthorizationFailure.scope(url,folder)}}else if !requiresScopes{lease=makePermissionLease(url)}else{let selected=await pick(url,folder:folder);lease=selected.map(makePermissionLease)}
        try cancellation.check()
        guard let lease else{if let authorizationFailure{throw authorizationFailure};cancellation.cancel();throw OperationCancellationFailure.cancelled}
        guard lease.contains(url)else{throw ImageToolAuthorizationFailure.selection(url,folder)}
        guard !requiresScopes || lease.hasSecurityScope else{throw ImageToolAuthorizationFailure.scope(url,folder)}
        grants.append(lease)
    }
    private func pick(_ requested:URL,folder:Bool)async->URL?{
        guard !retired else{return nil};authorizationFailure=nil
        let picker=NSOpenPanel();picker.canChooseDirectories=folder;picker.canChooseFiles = !folder;picker.allowsMultipleSelection=false
        picker.title="Authorize TurtleGitIDiff file access";picker.prompt="Authorize";picker.directoryURL=folder ? requested:requested.deletingLastPathComponent();picker.message=requested.path
        let validation=ImageToolAuthorizationValidator(requested:requested,folder:folder);validator=validation;picker.delegate=validation;panel=picker
        return await withCheckedContinuation{continuation in
            var answered=false
            let settle:(URL?)->Void={[self] value in
                guard !answered else{return};answered=true
                if panel === picker{panel=nil;panelAnswer=nil;validator=nil}
                retiringPanels.append(picker)
                if let parent=picker.sheetParent{parent.endSheet(picker,returnCode:value==nil ? .cancel:.OK)}
                picker.orderOut(nil);picker.close()
                Task{@MainActor [self,validation] in
                    while picker.sheetParent != nil || picker.isVisible{try? await Task.sleep(nanoseconds:5_000_000)}
                    retiringPanels.removeAll{$0 === picker};picker.delegate=nil;withExtendedLifetime(validation){}
                    continuation.resume(returning:!retired && !cancellation.isCancelled ? value:nil)
                }
            }
            panelAnswer=settle
            presentPermissionPanel(picker,owner){[weak self] response in
                guard let self,response == .OK,!self.retired,let selected=self.selectedPermissionURL(picker)else{settle(nil);return}
                do{try validation.panel(picker,validate:selected);settle(selected)}catch{self.authorizationFailure=error;settle(nil)}
            }
        }
    }
    private func present(_ controller:NSWindowController){editor=controller;
        let refresh:(Void)->Void = {[weak self] _ in DispatchQueue.main.async{if self != nil{ImageToolMenuContext.shared.refresh()}}}
        if let comparison=controller as? FileComparisonWindowController{editorObservation=comparison.model.objectWillChange.merge(with:comparison.model.imageViewerModel.objectWillChange).sink(receiveValue:refresh)}
        else if let selection=controller as? ImageSelectionWindowController{editorObservation=selection.model.objectWillChange.sink(receiveValue:refresh)}
        if let presentation{presentation(controller)}else{controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
        ImageToolMenuContext.shared.refresh()
    }
    private func showComparison(_ comparison:ImageFileComparison,initial:Bool=true)throws{
        guard !retired else{return}
        let controller=FileComparisonWindowController(images:comparison,permissions:grants,preferences:preferences)
        let image=controller.model.imageViewerModel
        controller.model.configureStandaloneImageTool(leftTitle:initial ? invocation.leftTitle:nil,rightTitle:initial ? invocation.rightTitle:nil,openImages:{[weak self] in self?.showOpenImages()})
        image.overlay=invocation.overlay;image.showInfo=invocation.showInfo
        if invocation.fitWidths{image.toggleWidths()};if invocation.fitHeights{image.toggleHeights()}
        controller.onClosed={[weak self,weak controller] in guard let self else{return};if self.editor === controller,!self.replacing{self.finish(0)}}
        if let previous=editor{retiredEditors.append(previous);editor=nil;previous.close()}
        present(controller)
    }
    func showOpenImages(){
        guard !retired,opener==nil,panel==nil,!invocation.isSelection,!editorPending,(!preparing || editor==nil) else{return}
        let chooser=ImageLoadWindowController(leftPath:invocation.left?.path ?? "",permissions:grants);opener=chooser
        chooser.requiresScopes=requiresScopes
        chooser.onAccepted={[weak self,weak chooser] comparison,permissions in
            guard let self,!self.retired,self.opener === chooser else{throw OperationCancellationFailure.cancelled}
            self.grants=permissions;self.replacing=true;defer{self.replacing=false}
            try self.showComparison(comparison,initial:false)
        }
        chooser.onClosed={[weak self,weak chooser] in
            guard let self,self.opener === chooser else{return};self.opener=nil
            if self.editor==nil{self.finish(0)};ImageToolMenuContext.shared.refresh()
        }
        if let presentation{presentation(chooser)}else{chooser.showWindow(nil);chooser.window?.makeKeyAndOrderFront(nil)}
        ImageToolMenuContext.shared.refresh()
    }
    func closeAfterApprovedQuit(){cancel()}
    func cancel(){
        guard !completed else{return};cancellation.cancel();retired=true;panelAnswer?(nil);opener?.retire()
        if let selection=editor as? ImageSelectionWindowController{selection.closeAfterApprovedQuit()}else{editor?.close()}
        finish(0)
    }
    private func finish(_ status:Int32){
        guard !finishing,!completed else{return};finishing=true;retired=true;cancellation.cancel();panelAnswer?(nil);ImageToolMenuContext.shared.retire(self)
        Task{[self] in
            while preparing || panel != nil || !retiringPanels.isEmpty || opener != nil || editorPending{try? await Task.sleep(nanoseconds:10_000_000)}
            if invocation.deleteInputsOnClose{
                let inputs=cleanupInputs
                do{try await Task.detached{for input in inputs{try input.removeIfUnchanged()}}.value}catch{onError(error.localizedDescription)}
            }
            if let ownerObserver{NotificationCenter.default.removeObserver(ownerObserver);self.ownerObserver=nil}
            grants=[];editor=nil;editorObservation=nil;retiredEditors=[];completed=true;finishing=false
            let callback=onFinished;onFinished={_ in};callback(status)
        }
    }
}

/// Captured original bytes and object identity, never a path-only delete grant.
private struct ImageToolCleanupInput:@unchecked Sendable{
    let url:URL,identity:stat,bytes:Data
    static func capture(_ url:URL)throws->Self?{var info=stat();if lstat(url.path,&info) != 0,errno==ENOENT{return nil};return try Self(url)}
    init(_ url:URL)throws{
        var info=stat();guard lstat(url.path,&info)==0 else{throw TextConflictFailure.changedWorkingFile}
        if info.st_mode & S_IFMT == S_IFLNK{self.url=url;identity=info;bytes=Data(try FileManager.default.destinationOfSymbolicLink(atPath:url.path).utf8);return}
        guard info.st_mode & S_IFMT == S_IFREG else{throw TextConflictFailure.unsupported}
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw TextConflictFailure.changedWorkingFile};defer{close(fd)}
        var opened=stat();guard fstat(fd,&opened)==0,opened.st_dev==info.st_dev,opened.st_ino==info.st_ino else{throw TextConflictFailure.changedWorkingFile}
        self.url=url;identity=info;bytes=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).readToEnd() ?? Data()
    }
    func removeIfUnchanged()throws{
        var current=stat();guard lstat(url.path,&current)==0 else{return}
        guard current.st_dev==identity.st_dev,current.st_ino==identity.st_ino,current.st_mode==identity.st_mode,current.st_size==identity.st_size,current.st_mtimespec.tv_sec==identity.st_mtimespec.tv_sec,current.st_mtimespec.tv_nsec==identity.st_mtimespec.tv_nsec else{return}
        guard try Self(url).bytes==bytes else{return};guard unlink(url.path)==0 else{throw CocoaError(.fileWriteUnknown)}
    }
}
