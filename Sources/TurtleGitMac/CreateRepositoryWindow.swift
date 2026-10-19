import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CreateRepositoryWindowController: NSWindowController, NSWindowDelegate {
    let model: CreateRepositoryWindowModel
    var onClosed: () -> Void = {}
    static var activeReleases:Int {CreateRepositoryRelease.activeCount}
    private var question:CreateRepositoryQuestionSession?
    var questionWindow:NSWindow? {question?.alert.window}
    var presentQuestion:((CreateRepositoryQuestion,NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    private var finished=false
    private var release:CreateRepositoryRelease?
    init(folder: URL, access: RepositoryAccessLease, preferences:UserDefaults = .standard) {
        model = CreateRepositoryWindowModel(folder: folder, access: access,preferences:preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window,repository:folder,dialog:"Git Init",preferences:preferences)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CreateRepositoryDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); TurtleGitHelp.attach(window, topic: .createRepository); window.delegate = self
        window.setContentSize(NSSize(width: 600, height: 190)); window.center()
        model.close = { [weak self] in
            guard let self,self.model.canClose,self.question==nil else{return}
            guard let window=self.window else{self.retireClosedWindow();return}
            guard window.attachedSheet==nil else{return}
            window.close();if !self.finished,!window.isVisible{self.retireClosedWindow()}
        }
        model.confirm = { [weak self] warning, completion in
            guard let self else{completion(false);return}
            let alert = NSAlert(); alert.alertStyle = .warning
            if warning == .specialFolder {
                alert.messageText = "Create a repository in this special folder?"
                alert.informativeText = "\(folder.path)\n\nThis is a system, volume or personal root folder. Its contents would become part of the repository’s scope."
            } else {
                alert.messageText = "Create a bare repository in a nonempty folder?"
                alert.informativeText = "\(folder.path)\n\nThis folder already contains files. A bare repository stores its Git data directly here and has no working tree."
            }
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Proceed")
            alert.layout();alert.buttons[0].keyEquivalent="\r";alert.buttons[1].keyEquivalent="";alert.window.defaultButtonCell=alert.buttons[0].cell as? NSButtonCell
            self.ask(.warning(warning),alert:alert){completion($0 == .alertSecondButtonReturn)}
        }
        model.showSuccess = { [weak self] in
            guard let self else{return}
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "Repository created"
            alert.informativeText = "Initialized Git repository in \(folder.path)."
            alert.addButton(withTitle: "OK")
            self.ask(.success,alert:alert){ [weak self] _ in self?.model.acknowledgeSuccess()}
        }
        model.showError={ [weak self] message,completion in
            guard let self else{completion();return}
            let alert=NSAlert();alert.alertStyle = .critical;alert.messageText="Could not initialize a repository";alert.informativeText=message;alert.addButton(withTitle:"OK")
            self.ask(.error(message),alert:alert){_ in completion()}
        }

        DialogGeometry.attach(window, identifier: "CreateRepositoryWindowController")
    }
    private func ask(_ kind:CreateRepositoryQuestion,alert:NSAlert,completion:@escaping(NSApplication.ModalResponse)->Void){
        guard !finished,!model.retired,!model.confirmingQuit,question==nil,let window,window.attachedSheet==nil else{completion(.abort);return}
        let request=CreateRepositoryQuestionSession(alert:alert,parent:window);question=request
        alert.window.appearance=window.effectiveAppearance;alert.window.alphaValue=window.alphaValue
        let answer:(NSApplication.ModalResponse)->Void={ [weak self,weak request] response in
            guard let self,let request,!request.answered else{return};request.answered=true
            let release=CreateRepositoryRelease(window:alert.window,parent:window,closeWindow:true){ [self,request] in
                let accepted = !self.finished && !self.model.retired && !self.model.confirmingQuit && self.question===request
                if self.question===request{self.question=nil};request.answer=nil;request.release=nil
                completion(accepted ? response:.abort)
            }
            request.release=release;release.start()
        }
        request.answer=answer
        if let presentQuestion{presentQuestion(kind,alert,window,answer)}else{alert.beginSheetModal(for:window,completionHandler:answer)}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{model.canClose && question==nil && sender.attachedSheet==nil}
    func windowWillClose(_ notification:Notification){guard notification.object as? NSWindow === window else{return};retireClosedWindow()}
    private func retireClosedWindow(){
        guard !finished else{return};finished=true;model.retire();question?.answer?(.abort)
        if let window,let sheet=window.attachedSheet,sheet !== questionWindow{window.endSheet(sheet,returnCode:.abort);sheet.close()}
        guard let window else{let done=onClosed;onClosed={};done();return}
        let release=CreateRepositoryRelease(window:window,parent:window.sheetParent,ready:{ [self] in !model.hasPendingWork && question==nil }){ [self] in self.release=nil;let done=onClosed;onClosed={};done() }
        self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CreateRepositoryWindowModel: ObservableObject {
    static var activeOperations = 0
    @Published private(set) var pendingOperations=0
    var hasPendingWork:Bool{pendingOperations>0}
    var workDidDrain:(()->Void)?
    private var formRevision=UUID()
    struct FormContext:Equatable{let owner:ObjectIdentifier;let revision:UUID;let bare:Bool}
    var formContext:FormContext{.init(owner:ObjectIdentifier(self),revision:formRevision,bare:bare)}
    var canEditForm:Bool{!retired && ready && !confirmingQuit && !busy && !asking && !confirmingSuccess && !confirmingError && !completed}
    func bareBinding(_ context:FormContext)->Binding<Bool>{Binding(get:{context.bare},set:{ [weak self] value in guard let self,self.canEditForm,self.formContext==context else{return};self.bare=value})}
    private var interactionGeneration=0
    @Published var confirmingQuit=false {didSet{if oldValue != confirmingQuit{formRevision=UUID();interactionGeneration += 1};if !confirmingQuit{if pendingPrepare{pendingPrepare=false;prepare()};deliverSuccess()}}}
    private(set) var retired = false
    @Published private(set) var asking = false
    @Published private(set) var confirmingSuccess = false
    @Published private(set) var confirmingError=false
    var canClose: Bool { !retired && !confirmingQuit && !busy && !hasPendingWork && !asking && !confirmingSuccess && !confirmingError }
    var executable: URL?
    private var cancellation: OperationCancellation?
    private var questionGeneration = UUID()
    private var pendingSuccessClose = false
    private var pendingPrepare=false
    private var successPresented=false
    private var pendingInitialization:(GitRepository,Bool,String)?
    func retire() { retired=true;formRevision=UUID();questionGeneration=UUID();cancellation?.cancel();asking=false;confirmingSuccess=false;confirmingError=false;pendingPrepare=false;pendingInitialization=nil;successPresented=false;close={};onInitialized={_,_,_,_ in};showSuccess=nil;showError=nil;if !hasPendingWork{busy=false} }
    func acknowledgeSuccess() {
        successPresented=false
        guard !retired,!confirmingQuit, confirmingSuccess else { return }; confirmingSuccess = false
        if busy { pendingSuccessClose = true } else { close() }
    }
    private func ask(_ warning: InitializationWarning, answered: @escaping (Bool) -> Void) {
        guard !retired,!confirmingQuit,!asking else{return};asking=true;formRevision=UUID()
        let identity=UUID(),generation=interactionGeneration;questionGeneration=identity;var settled=false
        confirm(warning) { [weak self] proceed in
            guard !settled, let self, !self.retired, self.asking, self.questionGeneration == identity else { return }
            settled=true;self.asking=false
            if self.confirmingQuit || self.interactionGeneration != generation{self.busy=false;self.ready=false;self.pendingPrepare=true;if !self.confirmingQuit{self.pendingPrepare=false;self.prepare()};return}
            answered(proceed)
        }
    }
    let folder: URL
    let access: RepositoryAccessLease
    @Published var bare: Bool {didSet{if bare != oldValue{formRevision=UUID()}}}
    @Published var ready = false
    @Published var busy = false
    @Published var completed = false
    @Published var error: String?
    private var confirmed: Set<InitializationWarning> = []
    var close: () -> Void = {}
    var confirm: (InitializationWarning, @escaping (Bool) -> Void) -> Void = { _,reply in reply(false) }
    var showSuccess:(()->Void)?
    var showError:((String,@escaping()->Void)->Void)?
    var initializeOperation:((GitRepository,URL,Bool,Set<InitializationWarning>,OperationCancellation) async throws->String)?
    var warningsForFolder:(URL,Bool)throws->Set<InitializationWarning>={try RepositoryInitialization.warnings(for:$0,bare:$1)}
    var onInitialized: (GitRepository, RepositoryAccessLease, Bool, String) -> Void = { _, _, _, _ in }
    let presentationPreferences:UserDefaults
    init(folder:URL,access:RepositoryAccessLease,preferences:UserDefaults = .standard){
        self.folder=folder;self.access=access;self.presentationPreferences=preferences;bare=RepositoryInitialization.defaultsToBare(folder)
    }
    private func presentSuccess(){guard !retired,!confirmingQuit,confirmingSuccess,!successPresented else{return};successPresented=true;if let showSuccess{showSuccess()}else{acknowledgeSuccess()}}
    private func deliverSuccess(){guard !retired,!confirmingQuit else{return};if let value=pendingInitialization{pendingInitialization=nil;onInitialized(value.0,access,value.1,value.2)};presentSuccess()}
    private func reportError(_ message:String){
        guard !retired else{return};error=message;ready=true;formRevision=UUID()
        guard !confirmingQuit,let showError else{return};confirmingError=true
        let identity=UUID();questionGeneration=identity;var answered=false
        showError(message){ [weak self] in guard !answered,let self,!self.retired,self.questionGeneration==identity else{return};answered=true;self.confirmingError=false;self.error=nil }
    }
    func prepare() {
        guard !retired,!confirmingQuit,!ready,!busy,!asking,!confirmingError,!completed else{return}
        do {
            if try warningsForFolder(folder,false).contains(.specialFolder) {
                ask(.specialFolder) { [weak self] proceed in
                    guard let self else { return }
                    if proceed { self.confirmed.insert(.specialFolder); self.ready = true } else { self.close() }
                }
            } else { ready = true }
        }catch{reportError(error.localizedDescription)}
    }
    func initialize() {
        guard canEditForm else{return}
        do {
            guard access.contains(folder), !GitRuntime.isAppStoreBuild || access.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
            let warnings=try warningsForFolder(folder,bare).subtracting(confirmed)
            let snapshot = bare
            busy = true
            formRevision=UUID()
            review(Array([InitializationWarning.specialFolder, .nonemptyBare].filter(warnings.contains)), bare: snapshot)
        }catch{reportError(error.localizedDescription)}
    }
    private func review(_ warnings: [InitializationWarning], bare: Bool) {
        guard let warning = warnings.first else { perform(bare: bare); return }
        ask(warning) { [weak self] proceed in
            guard let self, !self.retired else { return }
            if proceed { self.confirmed.insert(warning); self.review(Array(warnings.dropFirst()), bare: bare) }
            else { self.busy = false; self.close() }
        }
    }
    private func perform(bare: Bool) {
        guard !retired else { return }
        guard !confirmingQuit else{busy=false;return}
        let token=OperationCancellation();cancellation=token;Self.activeOperations += 1;pendingOperations += 1
        let acceptedWarnings=confirmed
        confirmed.remove(.nonemptyBare)
        Task { [self, access] in
            var created:(GitRepository,Bool,String)?,failure:String?
            defer {
                Self.activeOperations -= 1;pendingOperations -= 1;withExtendedLifetime(access){}
                if cancellation === token { cancellation = nil; busy = false }
                workDidDrain?()
                if !retired,let created{completed=true;confirmingSuccess=true;pendingInitialization=created;deliverSuccess()}
                else if !retired,let failure{reportError(failure)}
                if pendingSuccessClose, !retired { pendingSuccessClose = false; close() }
            }
            do {
                let executable = try self.executable ?? GitRuntime.executable()
                let cwd = try CloneOptions.workingDirectory(for: folder)
                guard access.contains(cwd) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(cwd.path) }
                let initializer=GitRepository(root:cwd,executable:executable),output:String
                if let initializeOperation{output=try await initializeOperation(initializer,folder,bare,acceptedWarnings,token)}else{output=try await initializer.initialize(at:folder,bare:bare,confirmedWarnings:acceptedWarnings,cancellation:token)}
                let candidate = GitRepository(root: folder, executable: executable)
                let resolved = try await candidate.discoverRoot(cancellation: token)
                guard access.contains(resolved) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path) }
                let repo = GitRepository(root: resolved, executable: executable)
                let actualBare = try await repo.isBare(cancellation: token)
                try token.check(); guard !retired else { return }
                created=(repo,actualBare,output)
            }catch{if !retired,!token.isCancelled{failure=error.localizedDescription}}
        }
    }

}

private struct CreateRepositoryDialog: View {
    @ObservedObject var model: CreateRepositoryWindowModel
    var body: some View {
        let context=model.formContext
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Make it Bare (No working directories)", isOn:model.bareBinding(context)).toggleStyle(.checkbox).disabled(!model.canEditForm)
            Text("If you plan to work inside this folder, leave this unchecked. Typically a bare repository receives changes through Push. By convention, a bare repository folder has a name ending in .git.")
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") {model.initialize()}.keyboardShortcut(.defaultAction).disabled(!model.canEditForm)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction).disabled(!model.canClose)
                Button("Help") { TurtleGitHelp.show(.createRepository) }
            }
        }.padding(16)
        .disabled(model.confirmingQuit)
        if let error=model.error,!model.confirmingError{Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
    }
}

enum CreateRepositoryQuestion:Equatable{case warning(InitializationWarning),success,error(String)}
@MainActor private final class CreateRepositoryQuestionSession{
    let alert:NSAlert,parent:NSWindow
    var answered=false
    var answer:((NSApplication.ModalResponse)->Void)?
    var release:CreateRepositoryRelease?
    init(alert:NSAlert,parent:NSWindow){self.alert=alert;self.parent=parent}
}
@MainActor private final class CreateRepositoryRelease{
    static private(set) var activeCount=0
    private let window:NSWindow,parent:NSWindow?
    private let closeWindow:Bool,ready:()->Bool
    private var completion:()->Void
    private var waiter:Task<Void,Never>?
    private var started=false,finished=false
    init(window:NSWindow,parent:NSWindow?,closeWindow:Bool=false,ready:@escaping()->Bool={true},completion:@escaping()->Void){self.window=window;self.parent=parent;self.closeWindow=closeWindow;self.ready=ready;self.completion=completion}
    func start(){
        guard !started else{return};started=true;Self.activeCount += 1
        if window.sheetParent != nil || parent?.attachedSheet===window{(window.sheetParent ?? parent)?.endSheet(window);window.orderOut(nil)}
        drain();if !finished{waiter=Task{ @MainActor [self] in while !finished{try? await Task.sleep(nanoseconds:5_000_000);drain()} }}
    }
    private func drain(){
        guard !finished,window.attachedSheet==nil,window.sheetParent==nil,parent?.attachedSheet !== window,ready() else{return};finished=true;waiter?.cancel();waiter=nil
        Self.activeCount -= 1;if closeWindow{window.close()};let done=completion;completion={};done()
    }
}
