import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class RequestPullWindowController: NSWindowController, NSWindowDelegate {
    let model: RequestPullWindowModel
    var onClosed: () -> Void = {}
    private(set) var picker: LogWindowController?
    private var retired = false
    var canReuse:Bool{!retired && !model.isRetired}
    static var activeReleases:Int{RequestPullRelease.activeCount}
    private(set) var waitingController:RequestPullWaitingWindowController?
    var waitingWindow:NSWindow?{waitingController?.window}
    var presentWaiting:(NSWindow,NSWindow)->Bool={parent,child in guard parent.attachedSheet == nil else{return false};parent.beginSheet(child);return true}
    private var errorAlert:NSAlert?
    var errorWindow:NSWindow?{errorAlert?.window}
    var presentError:((NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    private var errorAnswer:((NSApplication.ModalResponse)->Void)?
    private var release:RequestPullRelease?
    private var retiredPicker:LogWindowController?
    private var drainingPickers:[LogWindowController]=[]
    private var observations:Set<AnyCancellable>=[]
    private var epoch=0
    private var capturedPresentation:MergeWindowPresentation?
    private var capturedEditor:AlternativeEditorPreferences?
    var launchEditor:(URL,AlternativeEditorPreferences,[RepositoryAccessLease],OperationCancellation) async throws->Void={file,settings,permissions,token in try await AlternativeEditor.openDocument(file,settings:settings,permissions:permissions,cancellation:token)}

    private var pickerRequest: UUID?
    private struct Options: Equatable {
        let values: [GitReferenceName]
        let sendMail: Bool
    }
    private var options: Options { Options(values: [model.start, model.repositoryURL, model.end].map { GitReferenceName($0) }, sendMail: model.sendMail) }
    private var pendingStart: (UUID, Options, String?)?
    var configureLogPicker: (LogWindowModel) -> Void = { _ in }
    var makePicker: (GitRepository, RepositoryAccessLease?, String?, UserDefaults, @escaping (LogEntry?) -> Void) -> LogWindowController = { repository, access, revision, preferences, choose in
        LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, initialRevision: revision)
    }
    var presentPicker: (NSWindow, NSWindow) -> Bool = { parent, child in
        guard parent.attachedSheet == nil else { return false }; parent.beginSheet(child); return true
    }
    var openDocument: ((URL) -> Bool)?
    var activeOperation: Bool { model.busy || model.hasPendingWork || model.waitingForHandoff || model.openingEditor || model.confirmingError || model.composingMail || model.choosingStart || !drainingPickers.isEmpty || window?.attachedSheet != nil }

    private var sendPatch: SendMailWorkflow?
    private var transportRetiredMail:SendMailWorkflow?
    var transportBatchWorkPending:Bool {model.hasPendingWork || sendPatch?.transportBatchWorkPending == true || transportRetiredMail?.transportBatchWorkPending == true || window?.attachedSheet != nil || window?.sheetParent != nil}
    private let mailPreferences: UserDefaults
    private let mailPresentation: ((NSWindowController) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, end: String? = nil, repositoryURL: String? = nil, preferences: UserDefaults = .standard, mailPresentation: ((NSWindowController) -> Void)? = nil) {
        self.mailPreferences = preferences; self.mailPresentation = mailPresentation
        model = RequestPullWindowModel(repository: repository, access: access, preferences: preferences, end: end, repositoryURL: repositoryURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 210), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Request pull", preferences: preferences); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RequestPullDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self
        window.contentMinSize = NSSize(width: 600, height: 210); window.contentMaxSize = NSSize(width: 4000, height: 210)
        window.center()
        model.close = { [weak self] in guard let self,!self.model.confirmingQuit, !self.activeOperation else { return }; self.window?.performClose(nil) }
        model.chooseStart = { [weak self] in self?.chooseStart() }
        model.presentDocument = { [weak self] file, sendMail in self?.present(file, sendMail: sendMail) }
        model.captureReview={ [weak self] in guard let self else{return};self.capturedEditor=AlternativeEditorPreferences.load(from:self.mailPreferences);if let window=self.window{self.capturedPresentation=MergeWindowPresentation(window)} }
        model.beginGeneration={ [weak self] in self?.showWaiting() }
        model.endGeneration={ [weak self] done in guard let self else{done();return};self.finishWaiting(done) }
        model.prepareRetry={ [weak self] in guard let self else{return};self.capturedEditor=AlternativeEditorPreferences.load(from:self.mailPreferences);if let window=self.window{self.capturedPresentation=MergeWindowPresentation(window)} }
        model.$confirmingQuit.dropFirst().sink{ [weak self] _ in self?.epoch += 1;self?.scheduleError() }.store(in:&observations)
        model.objectWillChange.sink{ [weak self] _ in self?.scheduleError() }.store(in:&observations)
        NotificationCenter.default.addObserver(self, selector: #selector(pickerSheetEnded), name: NSWindow.didEndSheetNotification, object: window)
        model.load()

        DialogGeometry.attach(window, identifier: "RequestPullDialog", legacyName: "RequestPullDialog")
    }
    func chooseStart() {
        guard !retired, model.optionsAvailable, let window, window.attachedSheet == nil, picker == nil else { return }
        window.makeFirstResponder(nil)
        let captured = options, request = UUID(),generation=epoch, revision = FetchDialogHistory.trim(model.start)
        pickerRequest = request; model.choosingStart = true
        let child = makePicker(model.repository, model.access, revision.isEmpty ? nil : revision, mailPreferences) { [weak self] entry in
            guard let self, !self.retired, self.pickerRequest == request else { return }
            self.pendingStart = (request, captured, self.epoch == generation ? entry?.hash:nil); self.drainStart()
        }
        picker = child; configureLogPicker(child.model)
        child.model.showWorkingTree = false; child.model.historyPaths = []; child.model.showWholeProject = true
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.picker === child else { return }
            self.retainClosedPicker(child){ [weak self,weak child] in
                guard let self,!self.retired,self.picker === child else{return}
                self.picker=nil;self.drainStart()
            }
        }
        guard let sheet = child.window else { abandonPicker(); return }
        sheet.appearance = window.appearance; sheet.alphaValue = window.alphaValue
        guard presentPicker(window, sheet) else { abandonPicker(); return }
    }
    private func abandonPicker() {
        pickerRequest = nil; pendingStart = nil
        guard let child=picker else{model.choosingStart=false;return};picker=nil
        retainClosedPicker(child){ [weak self] in guard let self,!self.retired else{return};self.model.choosingStart=false }
        child.close()
    }
    private func retainClosedPicker(_ child:LogWindowController,done:@escaping()->Void){
        drainingPickers.append(child)
        let release=RequestPullRelease(window:child.window,parent:child.window?.sheetParent,ready:{child.model.pendingHistoryLoads == 0}){ [self] in
            self.drainingPickers.removeAll{$0 === child};done()
        };release.start()
    }
    @objc private func pickerSheetEnded() { drainStart() }
    private func drainStart() {
        guard !retired, let pending = pendingStart, pickerRequest == pending.0,
              picker == nil, window?.attachedSheet == nil else { return }
        pickerRequest = nil; pendingStart = nil; model.choosingStart = false
        guard options == pending.1, model.optionsAvailable else { return }
        model.acceptStart(pending.2); window?.makeKeyAndOrderFront(nil)
    }
    private func showWaiting(){
        guard !retired,!model.confirmingQuit,waitingController == nil,let window,window.attachedSheet == nil else{model.invalidate();close();return}
        if capturedPresentation == nil{capturedPresentation=MergeWindowPresentation(window)}
        let child=RequestPullWaitingWindowController(model:model);waitingController=child
        child.onForcedClose={ [weak self] in self?.close() }
        guard let sheet=child.window else{close();return};capturedPresentation?.apply(to:sheet)
        guard presentWaiting(window,sheet) else{close();return}
    }
    private func finishWaiting(_ done:@escaping()->Void){
        let child=waitingController
        guard let child else{done();return}
        child.finish{ [weak self,weak child] in
            guard let self,self.waitingController === child else{done();return}
            self.waitingController=nil;done()
        }
    }
    private func present(_ file:URL,sendMail:Bool){
        guard !retired,!model.confirmingQuit,!model.choosingStart,waitingController == nil,let window,window.attachedSheet == nil else{return}
        if sendMail{
            guard !model.composingMail else{return};model.composingMail=true
            let generation=epoch,snapshot=capturedPresentation ?? MergeWindowPresentation(window)
            let workflow=SendMailWorkflow(files:[file],repository:model.repository,access:model.access,fileAccess:[],preferences:mailPreferences,presentation:{ [weak self] child in
                guard let self,!self.retired,!self.model.confirmingQuit,self.epoch == generation else{child.close();return}
                if let window=child.window{snapshot.apply(to:window)}
                if let present=self.mailPresentation{present(child)}else{child.showWindow(nil);child.window?.makeKeyAndOrderFront(nil)}
            },customSubject:true,appOwnedFiles:[file]){ [weak self] _ in
                guard let self else{return};self.sendPatch=nil;self.model.composingMail=false
                guard !self.retired,!self.model.confirmingQuit,self.epoch == generation else{return};self.model.close()
            }
            sendPatch=workflow;workflow.start()
        }else{
            if let openDocument{
                if openDocument(file){model.close()}else{model.error="Could not open the generated request. Use Open request to try again."};return
            }
            let settings=capturedEditor ?? AlternativeEditorPreferences.load(from:mailPreferences),launch=launchEditor
            model.openInEditor(file,settings:settings,launch:launch)
        }
    }
    private func scheduleError(){Task{ @MainActor [weak self] in await Task.yield();self?.refreshError()} }
    private func refreshError(){
        if model.error == nil,errorAlert != nil{errorAnswer?(.abort);return}
        guard !retired,!model.confirmingQuit,!model.hasPendingWork,!model.waitingForHandoff,waitingController == nil,errorAlert == nil,
              let message=model.error,let window,window.attachedSheet == nil else{return}
        let alert=NSAlert();alert.alertStyle = message == "User cancelled." ? .informational:.critical;alert.messageText="Request pull";alert.informativeText=message;alert.addButton(withTitle:"OK")
        (capturedPresentation ?? MergeWindowPresentation(window)).apply(to:alert.window);errorAlert=alert;model.confirmingError=true
        let generation=epoch;var answered=false
        let answer:(NSApplication.ModalResponse)->Void={ [weak self] _ in
            guard let self,!answered,self.errorAlert === alert else{return};answered=true
            let release=RequestPullRelease(window:alert.window,parent:window,closeWindow:true){ [self] in
                self.errorAlert=nil;self.errorAnswer=nil;self.model.confirmingError=false
                if !self.retired,!self.model.confirmingQuit,self.epoch == generation,self.model.error.map({Data($0.utf8)}) == Data(message.utf8){self.model.error=nil}
                self.scheduleError()
            };release.start()
        }
        errorAnswer=answer
        if let presentError{presentError(alert,window,answer)}else{alert.beginSheetModal(for:window,completionHandler:answer)}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{
        guard !model.confirmingQuit else{return false}
        if model.busy{model.cancel(closeAfter:true);return false};return !activeOperation
    }
    override func close(){super.close();if !retired,window?.isVisible != true{retire()}}
    func windowWillClose(_ notification:Notification){guard notification.object as? NSWindow === window else{return};retire()}
    private func retire(){
        guard !retired else{return};retired=true;NotificationCenter.default.removeObserver(self)
        model.invalidate();pickerRequest=nil;pendingStart=nil;model.choosingStart=false
        transportRetiredMail=sendPatch;sendPatch?.invalidate();sendPatch=nil;model.composingMail=false;errorAnswer?(.abort)
        retiredPicker=picker;picker?.close();picker=nil
        let waiting=waitingController;waitingController=nil;waiting?.close()
        if let window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)}
        let release=RequestPullRelease(window:window,parent:window?.sheetParent,ready:{ [self] in
            self.transportRetiredMail?.transportBatchWorkPending != true && !self.model.hasPendingWork && self.errorAlert == nil && self.drainingPickers.isEmpty && (self.retiredPicker?.model.pendingHistoryLoads ?? 0) == 0 && self.retiredPicker?.window?.sheetParent == nil && waiting?.window?.sheetParent == nil
        }){ [self] in self.release=nil;self.retiredPicker=nil;self.observations.removeAll();let done=self.onClosed;self.onClosed={};done() }
        self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class RequestPullWindowModel:ObservableObject{
    private(set) static var activeOperations=0
    @Published private(set) var pendingOperations=0
    var hasPendingWork:Bool{pendingOperations>0}
    var workDidDrain:(()->Void)?
    let repository:GitRepository
    let access:RepositoryAccessLease?
    let preferences:UserDefaults
    var presentationPreferences:UserDefaults{preferences}
    private var invalidated=false
    var isRetired:Bool{invalidated}
    private var cancellation:OperationCancellation?
    private var closeAfterOperation=false
    private var generation=0,formRevision=UUID()
    @Published var confirmingQuit=false{didSet{if oldValue != confirmingQuit{generation += 1;formRevision=UUID()}}}
    @Published private(set) var loading=false
    @Published var choosingStart=false{didSet{if oldValue != choosingStart{formRevision=UUID()}}}
    @Published private(set) var waitingForHandoff=false
    @Published private(set) var openingEditor=false
    @Published var confirmingError=false
    var optionsAvailable:Bool{!invalidated && !confirmingQuit && !busy && !hasPendingWork && !waitingForHandoff && !openingEditor && !confirmingError && !composingMail && !choosingStart}
    struct FormContext:Equatable{let owner:ObjectIdentifier;let revision:UUID}
    var formContext:FormContext{.init(owner:ObjectIdentifier(self),revision:formRevision)}
    func field<Value>(_ key:ReferenceWritableKeyPath<RequestPullWindowModel,Value>,context:FormContext)->Binding<Value>{Binding(get:{self[keyPath:key]},set:{if self.optionsAvailable,self.formContext==context{self[keyPath:key]=$0}})}
    var requiresRepositoryScope=GitRuntime.isAppStoreBuild
    private func checkAccess()throws{if requiresRepositoryScope && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){throw RepositoryAccessFailure.securityScopeUnavailable}}
    private func begin(loading:Bool)->OperationCancellation{
        let token=OperationCancellation();cancellation=token;self.loading=loading;formRevision=UUID();busy=true;cancelling=false;pendingOperations += 1;Self.activeOperations += 1;return token
    }
    private func finish(_ token:OperationCancellation){
        pendingOperations -= 1;Self.activeOperations -= 1;withExtendedLifetime(access){}
        if cancellation === token{cancellation=nil;busy=false;loading=false;cancelling=false}
        if !hasPendingWork{workDidDrain?()}
        if closeAfterOperation,!invalidated{closeAfterOperation=false;close()}
    }
    private var key:String{"History.RequestPull."+repository.root.path+"."}
    static let urlHistoryKey="History.RequestPull.url"
    static let sendMailKey="RequestPull.SendMail"
    @Published var start:String
    @Published var repositoryURL:String
    @Published var end:String
    @Published var sendMail:Bool
    @Published private(set) var references:[String]=[]
    @Published private(set) var urls:[String]=[]
    @Published private(set) var busy=false
    @Published private(set) var cancelling=false
    @Published var composingMail=false
    @Published var error:String?
    @Published private(set) var document:URL?
    private var unpublishedDocument:URL?
    var close:()->Void={}
    var chooseStart:()->Void={}
    var presentDocument:(URL,Bool)->Void={_,_ in}
    var captureReview:()->Void={}
    var beginGeneration:()->Void={}
    var endGeneration:(@escaping()->Void)->Void={$0()}
    var prepareRetry:()->Void={}
    var runRequestPull:((RequestPullOptions,OperationCancellation) async throws->Data)?
    var writeRequest:((Data,OperationCancellation) async throws->URL)?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard, end: String? = nil, repositoryURL: String? = nil) {
        self.repository = repository; self.access = access; self.preferences = preferences
        let key = "History.RequestPull." + repository.root.path + "."
        start = preferences.string(forKey: key + "startrevision") ?? ""
        self.repositoryURL = repositoryURL.flatMap { $0.isEmpty ? nil : $0 } ?? preferences.string(forKey: key + "repositoryurl") ?? ""
        self.end = end.flatMap { $0.isEmpty ? nil : $0 } ?? preferences.string(forKey: key + "endrevision") ?? "HEAD"
        sendMail = preferences.bool(forKey: Self.sendMailKey)
        urls = FetchDialogHistory.load(preferences, key: Self.urlHistoryKey, caseSensitive: true)
    }
    func load(){
        guard optionsAvailable else{return};let token=begin(loading:true),epoch=generation
        Task{
            defer{finish(token)}
            do{
                try checkAccess()
                let refs=try await repository.checkoutReferences(localBranchesFirst:AdvancedListBehavior(defaults:preferences).localBranchesFirst,cancellation:token)
                guard !invalidated,!token.isCancelled,generation==epoch,!confirmingQuit else{return}
                references=refs.filter{($0.name.hasPrefix("refs/heads/") || $0.remote) && $0.symbolicTarget == nil}.map{
                    $0.name.hasPrefix("refs/heads/") ? String($0.name.dropFirst(11)):$0.name.hasPrefix("refs/") ? String($0.name.dropFirst(5)):$0.name
                }
            }catch{if !invalidated,!token.isCancelled,!confirmingQuit,generation==epoch{self.error=error.localizedDescription}}
        }
    }
    func configureLog(_ log:LogWindowModel){let revision=FetchDialogHistory.trim(start);log.endRevision=revision.isEmpty ? nil:revision;log.allBranches=false;log.showWorkingTree=false;log.historyPaths=[];log.showWholeProject=true;log.reload()}
    func acceptStart(_ hash:String?){guard optionsAvailable,let hash,!hash.isEmpty else{return};start=hash}
    func deleteURL(at index:Int){guard optionsAvailable,let result=FetchDialogHistory.removing(index,entries:urls,preferences:preferences,key:Self.urlHistoryKey) else{return};urls=result.entries;repositoryURL=result.selection}
    private func discardUnpublished(){
        defer{unpublishedDocument=nil}
        guard let file=unpublishedDocument,let root=try? TurtleGitTemporaryStorage.root,RepositoryAccessLease.pathIsContained(file,by:root) else{return}
        let parent=file.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("TurtleGit-request-pull-"),file.lastPathComponent=="pullrequest.txt"{try? FileManager.default.removeItem(at:parent)}else{try? FileManager.default.removeItem(at:file)}
    }
    func invalidate(){guard !invalidated else{return};invalidated=true;formRevision=UUID();cancellation?.cancel();discardUnpublished()}
    func cancel(closeAfter:Bool=false){
        guard !invalidated,!confirmingQuit,!choosingStart,!composingMail,!confirmingError else{return}
        if let cancellation{closeAfterOperation=closeAfterOperation || closeAfter || loading;cancelling=true;cancellation.cancel()}
        else if optionsAvailable{close()}
    }
    func create(){
        guard optionsAvailable else{return}
        var options=RequestPullOptions();options.start=start;options.repositoryURL=FetchDialogHistory.trim(repositoryURL.replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\n",with:" "));options.end=FetchDialogHistory.trim(end)
        captureReview();let mail=sendMail,token=begin(loading:false),epoch=generation;error=nil
        urls=FetchDialogHistory.save(options.repositoryURL,entries:urls,preferences:preferences,key:Self.urlHistoryKey,caseSensitive:true)
        preferences.set(options.start,forKey:key+"startrevision");preferences.set(options.repositoryURL,forKey:key+"repositoryurl");preferences.set(options.end,forKey:key+"endrevision")
        Task{
            var outcome:Result<URL,Error>?,validated=false
            defer{
                let closeRequested=closeAfterOperation
                waitingForHandoff = !invalidated
                finish(token)
                if !invalidated{
                    var answered=false
                    endGeneration{ [weak self] in
                        guard !answered else{return};answered=true
                        guard let self else{return};self.waitingForHandoff=false
                        if closeRequested{self.discardUnpublished();if !self.invalidated,!self.confirmingQuit{self.close()};return}
                        guard !self.invalidated,!self.confirmingQuit,self.generation==epoch else{self.discardUnpublished();return}
                        switch outcome{
                        case .success(let file):self.document=file;self.unpublishedDocument=nil;self.presentDocument(file,mail)
                        case .failure(let failure):self.error=token.isCancelled ? "User cancelled.":(validated ? "Failed to create pull-request.\n":"")+failure.localizedDescription
                        case nil:break
                        }
                    }
                }
            }
            do{
                try checkAccess();try await repository.validateRequestPullEnd(options.end,cancellation:token)
                try token.check();guard !invalidated,!confirmingQuit,generation==epoch else{return}
                validated=true;preferences.set(mail,forKey:Self.sendMailKey);beginGeneration()
                let bytes:Data
                if let runRequestPull{bytes=try await runRequestPull(options,token)}else{bytes=try await repository.requestPull(options,cancellation:token)}
                try token.check();guard !invalidated else{return}
                let file:URL
                if let writeRequest{file=try await writeRequest(bytes,token)}else{
                    let tempRoot=try TurtleGitTemporaryStorage.root
                    file=try await Task.detached{
                        try token.check();let directory=tempRoot.appendingPathComponent("TurtleGit-request-pull-"+UUID().uuidString)
                        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                        do{let file=directory.appendingPathComponent("pullrequest.txt");try bytes.write(to:file,options:.atomic);try token.check();return file}
                        catch{try? FileManager.default.removeItem(at:directory);throw error}
                    }.value
                }
                unpublishedDocument=file
                try token.check();guard !invalidated else{discardUnpublished();return};outcome = .success(file)
            }catch{outcome = .failure(error);discardUnpublished()}
        }
    }
    func openInEditor(_ file:URL,settings:AlternativeEditorPreferences,launch:@escaping(URL,AlternativeEditorPreferences,[RepositoryAccessLease],OperationCancellation) async throws->Void){
        guard optionsAvailable else{return};let token=begin(loading:false),epoch=generation;openingEditor=true
        Task{
            var failure:String?,accepted=false
            do{try await launch(file,settings,access.map{[$0]} ?? [],token);try token.check();accepted=true}
            catch{failure="Could not open the generated request. Use Open request to try again.\n\n"+error.localizedDescription}
            openingEditor=false;finish(token)
            guard !invalidated,!confirmingQuit,generation==epoch else{return}
            if accepted{close()}else if let failure{error=failure}
        }
    }
    func openDocument(){guard optionsAvailable,let document else{return};prepareRetry();presentDocument(document,false)}
}
struct RequestPullDialog: View {
    @ObservedObject var model: RequestPullWindowModel
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 10) {
            Group {
                HStack { Text("Start").frame(width: 110, alignment: .leading); PushRefCombo(value: model.field(\.start,context:context), choices: model.references, local: true); Button("…") { if model.formContext==context{model.chooseStart()} }.accessibilityLabel("Choose start revision from Log") }
                HStack { Text("Repository URL").frame(width: 110, alignment: .leading); FetchHistoryCombo(value: model.field(\.repositoryURL,context:context), choices: model.urls, label: "Repository URL", onDelete: {if model.formContext==context{model.deleteURL(at:$0)}}) }
                HStack { Text("End").frame(width: 110, alignment: .leading); TextField("End", text: model.field(\.end,context:context)).labelsHidden() }
                Toggle("Send Mail after create", isOn: model.field(\.sendMail,context:context))
            }.disabled(!model.optionsAvailable)
            Spacer(minLength: 0)
            HStack { if model.busy { ProgressView().controlSize(.small); Text(model.cancelling ? "Cancelling…" : model.loading ? "Loading revisions…" : "Creating pull-request...").font(.caption) }; if model.document != nil { Button("Open request") {if model.formContext==context{model.openDocument()} }.disabled(!model.optionsAvailable) }; Spacer()
                Button("OK") { if model.formContext==context{model.create()} }.keyboardShortcut(.defaultAction).disabled(!model.optionsAvailable)
                Button("Cancel") {if model.formContext==context{model.cancel()} }.keyboardShortcut(.cancelAction).disabled(model.isRetired || model.cancelling || model.composingMail || model.choosingStart)
                Button("Help") { TurtleGitHelp.show(.patches) }
            }
        }.padding(16)
        .disabled(model.confirmingQuit)
    }
}

@MainActor final class RequestPullWaitingWindowController:NSWindowController,NSWindowDelegate{
    let model:RequestPullWindowModel
    let cancelButton=NSButton(title:NSLocalizedString("Cancel",comment:""),target:nil,action:nil)
    var onForcedClose:()->Void={}
    private(set) var presentationClosed=false
    private var finishing=false,retiring=false,closingForHandoff=false
    private var release:RequestPullRelease?
    private var observation:AnyCancellable?
    init(model:RequestPullWindowModel){
        self.model=model
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:145),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="TurtleGit";window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self
        let content=NSView(frame:NSRect(x:0,y:0,width:430,height:145))
        let spinner=NSProgressIndicator(frame:NSRect(x:20,y:83,width:20,height:20));spinner.style = .spinning;spinner.controlSize = .small;spinner.isIndeterminate=true;spinner.startAnimation(nil)
        let title=NSTextField(labelWithString:NSLocalizedString("Creating pull-request...",comment:""));title.frame=NSRect(x:54,y:91,width:356,height:20)
        let detail=NSTextField(labelWithString:NSLocalizedString("Please wait...",comment:""));detail.textColor = .secondaryLabelColor;detail.frame=NSRect(x:54,y:63,width:356,height:20)
        cancelButton.frame=NSRect(x:330,y:18,width:80,height:28);cancelButton.bezelStyle = .rounded;cancelButton.keyEquivalent="\u{1b}";cancelButton.target=self;cancelButton.action=#selector(cancelWaiting)
        let controls:[NSView]=[spinner,title,detail,cancelButton];controls.forEach{content.addSubview($0)};window.contentView=content
        observation=model.objectWillChange.sink{ [weak self] _ in Task{ @MainActor [weak self] in await Task.yield();self?.refreshCancel()} };refreshCancel()
    }
    @objc private func cancelWaiting(){guard cancelButton.isEnabled else{return};model.cancel();refreshCancel()}
    private func refreshCancel(){cancelButton.isEnabled = !model.isRetired && !model.cancelling && !model.waitingForHandoff && !model.confirmingQuit}
    func finish(_ done:@escaping()->Void){
        guard !retiring else{done();return};finishing=true
        let release=RequestPullRelease(window:window,parent:window?.sheetParent,ready:{ [self] in !self.model.hasPendingWork && self.window?.attachedSheet == nil }){ [self] in
            self.release=nil
            guard !self.retiring else{done();return}
            self.closingForHandoff=true;self.window?.close();self.presentationClosed=true
            DispatchQueue.main.async{done()}
        };self.release=release;release.start()
    }
    override func close(){super.close();if !retiring,!closingForHandoff,window?.isVisible != true{retire()}}
    func windowShouldClose(_ sender:NSWindow)->Bool{model.cancel();return false}
    func windowWillClose(_ notification:Notification){guard notification.object as? NSWindow === window,!closingForHandoff else{return};retire()}
    private func retire(){guard !retiring else{return};retiring=true;model.invalidate();onForcedClose();if let window,let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()};let release=RequestPullRelease(window:window,parent:window?.sheetParent,ready:{ [self] in !self.model.hasPendingWork }){ [self] in self.release=nil;self.presentationClosed=true };self.release=release;release.start()}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
@MainActor private final class RequestPullRelease{
    static private(set) var activeCount=0
    private let window:NSWindow?,parent:NSWindow?
    private let closeWindow:Bool,ready:()->Bool
    private var completion:()->Void
    private var waiter:Task<Void,Never>?
    private var started=false,finished=false
    init(window:NSWindow?,parent:NSWindow?,closeWindow:Bool=false,ready:@escaping()->Bool={true},completion:@escaping()->Void){self.window=window;self.parent=parent;self.closeWindow=closeWindow;self.ready=ready;self.completion=completion}
    func start(){guard !started else{return};started=true;Self.activeCount += 1
        if let window,window.sheetParent != nil || parent?.attachedSheet === window{(window.sheetParent ?? parent)?.endSheet(window);window.orderOut(nil)}
        drain();if !finished{waiter=Task{ @MainActor [self] in while !finished{try? await Task.sleep(nanoseconds:5_000_000);drain()} }}
    }
    private func drain(){guard !finished,window?.attachedSheet == nil,window?.sheetParent == nil,window == nil || parent?.attachedSheet !== window,ready() else{return};finished=true;waiter?.cancel();waiter=nil;Self.activeCount -= 1;if closeWindow{window?.close()};let done=completion;completion={};done()}
}
