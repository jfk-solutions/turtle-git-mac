import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class AddProgressWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var activeReleases=0
    let model:AddProgressWindowModel
    let progressFiles:FileOperationProgressFiles
    var onClosed:()->Void = {}
    var onProgressLog:(String)->Void = {_ in}
    private var closed=false,finishing=false
    private var handoff:((Bool)->Void)?
    private var question:(NSAlert,(Bool)->Void)?
    var presentQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool = {window,alert,reply in guard window.attachedSheet==nil else{return false};alert.beginSheetModal(for:window,completionHandler:reply);return true}
    init(repository:GitRepository,access:RepositoryAccessLease?,paths:[String],mode:WorkingFileAddMode = .normal,preferences:UserDefaults = .standard) {
        model=AddProgressWindowModel(repository:repository,access:access,paths:paths,mode:mode,preferences:preferences)
        progressFiles=FileOperationProgressFiles(repository:repository,access:access)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:460),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        RepositoryWindowTitles.set(window,repository:repository.root,dialog:"Add",preferences:preferences);window.isReleasedWhenClosed=false;window.contentMinSize=NSSize(width:580,height:330)
        window.contentViewController=NSHostingController(rootView:AddProgressView(model:model).defaultAppStorage(preferences));super.init(window:window);window.delegate=self;window.center()
        model.close={ [weak self] in self?.window?.performClose(nil)}
        model.finishAndPerform={ [weak self] reply in guard let self else{reply(false);return};self.finish(reply)}
        model.confirmCancellation={ [weak self] reply in self?.askCancellation(reply) ?? reply(false)}
        progressFiles.window=window;progressFiles.available={ [weak model] in model?.commandsAvailable==true && model?.busy==false}
        progressFiles.onBusy={ [weak model] in model?.fileActionBusy=$0};progressFiles.onLog={ [weak self] in self?.onProgressLog($0)}
        progressFiles.onError={ [weak model] in model?.information=$0}
        model.onProgressFileAction={ [weak self] action,path in self?.progressFiles.perform(action,path:path)}
        DialogGeometry.attach(window,identifier:"AddProgress",legacyName:"AddProgress")
    }
    private func askCancellation(_ reply:@escaping(Bool)->Void) {
        guard !closed,question==nil,let window,window.attachedSheet==nil else{reply(false);return}
        let alert=NSAlert();alert.messageText="The process is still running.";alert.informativeText="Are you sure to abort?";alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No");alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        question=(alert,reply)
        if !presentQuestion(window,alert,{ [weak self] answer in self?.settleQuestion(answer == .alertFirstButtonReturn) }) {settleQuestion(false)}
    }
    private func settleQuestion(_ accepted:Bool) {
        guard let (alert,reply)=question else{return};question=nil
        Task {await FileOperationWindowDrain.detach(alert.window);reply(accepted)}
    }
    private func finish(_ reply:((Bool)->Void)?=nil) {
        guard !closed,!finishing,!model.busy,!model.confirmingCancellation,!model.fileActionBusy,window?.attachedSheet==nil else{reply?(false);return}
        finishing=true;handoff=reply;window?.orderOut(nil);close()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if model.busy{model.cancel();return false}
        guard !model.confirmingQuit,!model.confirmingCancellation,!model.fileActionBusy,sender.attachedSheet==nil else{return false};finish();return false
    }
    override func close(){super.close();retireClosedWindow()}
    func windowWillClose(_ notification:Notification){retireClosedWindow()}
    private func retireClosedWindow(){
        guard !closed else{return};closed=true;let accepted=finishing,reply=handoff;handoff=nil
        let sheet=window?.attachedSheet;model.retire();progressFiles.retire();settleQuestion(false);Self.activeReleases += 1
        Task { [self] in
            defer{Self.activeReleases -= 1}
            if let sheet{await FileOperationWindowDrain.detach(sheet)};if let window{await FileOperationWindowDrain.detach(window)}
            while model.busy || model.confirmingCancellation || progressFiles.busy{try? await Task.sleep(nanoseconds:5_000_000)}
            onClosed();reply?(accepted && !model.confirmingQuit && model.externalAvailability())
        }
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
@MainActor final class AddProgressWindowModel:ObservableObject,ActionLogProgress {
    static private(set) var activeOperations=0
    let repository:GitRepository,paths:[String],mode:WorkingFileAddMode
    let preferences:UserDefaults
    let progress:FileOperationProgressState
    let progressPresentation:GitCommandPresentation
    private let access:RepositoryAccessLease?
    private var cancellation=OperationCancellation(),started=false
    private(set) var retired=false
    private var workerStarted:Date?
    private var autoClosePolicy:GitProgressAutoClose?
    var allowsCommit=true
    var externalAvailability:()->Bool={true}
    var validateMutation:(OperationCancellation,Bool)async throws->Void={_,_ in}
    var execute:((OperationCancellation)async throws->String)?
    var executeMode:((WorkingFileAddMode,OperationCancellation)async throws->Void)?
    @Published var busy=true
    @Published var confirmingQuit=false
    @Published var fileActionBusy=false
    @Published private(set) var confirmingCancellation=false
    @Published private(set) var cancelling=false
    @Published private(set) var handoffPending=false
    @Published var success=false
    @Published var cancelled=false
    @Published var information="Adding…"
    @Published private(set) var percentage:Int?
    @Published private(set) var currentWork=""
    @Published private(set) var completionRange:NSRange?
    var commandsAvailable:Bool{!retired && !confirmingQuit && !handoffPending && externalAvailability()}
    var close:()->Void={}
    var onFinished:(String,Bool)->Void={_,_ in}
    var onCommit:()->Void={}
    var finishAndPerform:(@escaping(Bool)->Void)->Void={$0(false)}
    var confirmCancellation:(@escaping(Bool)->Void)->Void={$0(false)}
    var onProgressFileAction:(FileOperationProgressAction,String)->Void={_,_ in}
    init(repository:GitRepository,access:RepositoryAccessLease?,paths:[String],mode:WorkingFileAddMode = .normal,preferences:UserDefaults = .standard){self.repository=repository;self.access=access;self.paths=paths;self.mode=mode;self.preferences=preferences;self.progress=FileOperationProgressState(preferences:preferences);progressPresentation=GitCommandPresentation(defaults:preferences);information=mode.rawValue+"…"}
    func retire(){guard !retired else{return};if busy{cancelled=true};retired=true;cancellation.cancel();progress.retire();if !started{busy=false}}
    func cancel(){
        guard busy,!retired,!confirmingCancellation,!cancelling else{return};let token=cancellation
        if workerStarted==nil || !preferences.bool(forKey:"ConfirmKillProcess"){stop(token);return}
        confirmingCancellation=true;Self.activeOperations += 1;var answered=false
        confirmCancellation{ [self] accepted in
            guard !answered else{return};answered=true;Self.activeOperations -= 1;confirmingCancellation=false
            if accepted,!retired,busy,cancellation===token{stop(token)};finishAutomaticClose()
        }
    }
    private func stop(_ token:OperationCancellation){cancelling=true;token.cancel();information="Cancelling…"}
    private func begin(_ command:String){workerStarted=Date();progress.begin(command);autoClosePolicy=GitProgressAutoClose(preferences:preferences);percentage=nil;currentWork=command;completionRange=nil}
    private func complete(){
        guard let date=workerStarted else{return}
        progress.finish(success:success,cancelled:cancelled,started:date)
        let footer=SubmoduleProgressCompletion(success:success,cancelled:cancelled,exitCode:nil,elapsed:Date().timeIntervalSince(date),preferences:preferences,showTimings:true)
        currentWork=footer.currentWork;percentage=100;completionRange=footer.append(to:&information)
    }
    private func finishAutomaticClose(){guard commandsAvailable,!busy,!fileActionBusy,!confirmingCancellation,success,!cancelled,autoClosePolicy?.shouldClose(success:true,postActionCount:(allowsCommit ? 1:0)+(mode == .normal ? 2:0))==true else{return};close()}
    func run()async {
        guard !started,!retired else{return};started=true;Self.activeOperations += 1;LocalGitCommandProgress.begin()
        defer{Self.activeOperations -= 1;LocalGitCommandProgress.end();busy=false;cancelling=false;withExtendedLifetime(access){};saveActionLog();if !retired{onFinished(information,success);finishAutomaticClose()}}
        do{
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){throw RepositoryAccessFailure.securityScopeUnavailable}
            try await validateMutation(cancellation,true);try cancellation.check();guard commandsAvailable else{return};begin(mode.rawValue)
            let text:String;if let execute{text=try await execute(cancellation)}else{text=try await repository.addReviewedPaths(paths,mode:mode,cancellation:cancellation)}
            guard !retired else{return};success=true;cancelled=false;for path in paths{progress.append("Added",path,kind:.file)};information="\(paths.count) item(s) added."+(text.isEmpty ? "":"\n"+text)
        }catch{cancelled=cancellation.isCancelled || error is OperationCancellationFailure;success=false;information=cancelled ? "Cancelled. The index was not replaced.":error.localizedDescription;if workerStarted != nil{progress.append(cancelled ? "User cancelled":"Error",information,kind:.error)}}
        if !retired{complete()}
    }
    func changeMode(_ mode:WorkingFileAddMode)async {
        guard commandsAvailable,success,!busy,!fileActionBusy,!confirmingCancellation,mode != .normal else{return}
        saveActionLog();ProgressActionLog.nextAttempt(self,savePrevious:false);cancellation=OperationCancellation();busy=true;cancelled=false;success=false;workerStarted=nil;Self.activeOperations += 1;LocalGitCommandProgress.begin()
        defer{Self.activeOperations -= 1;LocalGitCommandProgress.end();busy=false;cancelling=false;withExtendedLifetime(access){};saveActionLog();if !retired{onFinished(information,success);finishAutomaticClose()}}
        do{if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true){throw RepositoryAccessFailure.securityScopeUnavailable};try await validateMutation(cancellation,false);try cancellation.check();guard commandsAvailable else{return};begin(mode.rawValue)
            if let executeMode{try await executeMode(mode,cancellation)}else{try await repository.setAddedFileMode(paths:paths,mode:mode,cancellation:cancellation)}
            guard !retired else{return};success=true;information=mode.rawValue+": staged file modes updated.";for path in paths{progress.append(mode.rawValue,path,kind:.file)}
        }catch{cancelled=cancellation.isCancelled;information=cancelled ? "Mode change cancelled. The index was not replaced.":error.localizedDescription;progress.append(cancelled ? "User cancelled":"Error",information,kind:.error)}
        if !retired{complete()}
    }
    func commit(){
        guard commandsAvailable,allowsCommit,success,!cancelled,!busy,!fileActionBusy,!confirmingCancellation else{return}
        let callback=onCommit;handoffPending=true;Self.activeOperations += 1;var answered=false
        finishAndPerform{ [self] accepted in guard !answered else{return};answered=true;defer{handoffPending=false;Self.activeOperations -= 1;withExtendedLifetime(access){}};if accepted,!confirmingQuit,externalAvailability(){callback()}}
    }
    func start(){Task{await run()}}
    var output:String{progress.output+"\n"+information}
    var actionLogRepository:URL{repository.root}
    var actionLogEligible:Bool{workerStarted != nil}
    var actionLogFailed:Bool{!success}
    var actionLogCancelled:Bool{cancelled}
}
struct AddProgressView:View {
    @ObservedObject var model:AddProgressWindowModel
    var body:some View {
        VStack(spacing:12){
            AddProgressTable(model:model).frame(minHeight:220)
            HStack{if model.busy{LocalGitProgressIndicator(percentage:model.percentage,animate:model.progressPresentation.animateActivity)};Text(model.information).textSelection(.enabled);Spacer()}
            HStack{
                if model.success && (model.allowsCommit || model.mode == .normal){HStack(spacing:2){
                    if model.allowsCommit{Button{model.commit()}label:{CommandLabel(title:"Commit…",icon:.commit)}}
                    Menu{
                        if model.allowsCommit{Button{model.commit()}label:{CommandLabel(title:"Commit…",icon:.commit)}}
                        if model.mode == .normal{Button{Task{await model.changeMode(.executable)}}label:{CommandLabel(title:WorkingFileAddMode.executable.rawValue,icon:.add)};Button{Task{await model.changeMode(.symlink)}}label:{CommandLabel(title:WorkingFileAddMode.symlink.rawValue,icon:.add)}}
                    }label:{Image(systemName:"chevron.down").accessibilityLabel("Add post-actions")}.menuStyle(.borderlessButton).fixedSize()
                }.disabled(model.busy || !model.commandsAvailable || model.confirmingCancellation || model.fileActionBusy)}
                Spacer()
                if model.busy{Button(model.cancelling ? "Cancelling…":"Cancel"){model.cancel()}.keyboardShortcut(.cancelAction).disabled(model.confirmingCancellation || model.cancelling)}
                else{Button("Close"){model.close()}.keyboardShortcut(.defaultAction).disabled(model.confirmingCancellation || model.fileActionBusy || model.handoffPending)}
            }
        }.padding(12).disabled(model.confirmingQuit)
    }
}
