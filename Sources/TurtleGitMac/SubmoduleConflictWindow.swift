import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleConflictWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleConflictWindowModel
    var onClosed: () -> Void = {}
    private(set) var sheets: ConflictReviewSheets!
    private(set) var closing=false
    private var release:FinderFilesystemWorkflowRelease?
    private var ownedReset:ResetWindowController?
    private var resetDrain:Task<Void,Never>?
    private var retiringSheets:[NSWindow]=[]
    private var pendingReplies=0
    var canReuse:Bool {!closing && model.operation.active}
    private var underlyingWork:Bool {pendingReplies>0 || model.hasPendingWork || ownedReset != nil || resetDrain != nil || window?.attachedSheet != nil || window?.sheetParent != nil || retiringSheets.contains{$0.sheetParent != nil || $0.attachedSheet != nil}}
    var hasPendingWork:Bool {release != nil || underlyingWork}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, preferences: UserDefaults = .standard) {
        model = SubmoduleConflictWindowModel(repository: repository, access: access, path: path, preferences: preferences)
        let size=NSSize(width:780,height:570)
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        RepositoryWindowTitles.set(window,repository:repository.root,dialog:"Resolve Submodule Conflict",preferences:preferences);window.isReleasedWhenClosed=false
        let host=NSHostingController(rootView:SubmoduleConflictDialog(model:model,operation:model.operation).defaultAppStorage(preferences))
        host.sizingOptions=[];window.contentViewController=host
        NSLayoutConstraint.activate([host.view.widthAnchor.constraint(greaterThanOrEqualToConstant:690),host.view.heightAnchor.constraint(greaterThanOrEqualToConstant:570)])
        window.contentMinSize=NSSize(width:690,height:570)
        super.init(window:window);window.delegate=self;window.setContentSize(size);window.center()
        sheets=ConflictReviewSheets(window:window,operation:model.operation)
        model.close={ [weak self] in self?.window?.performClose(nil) }
        model.interactionAvailable={ [weak window] in window != nil && window?.attachedSheet == nil }
        model.hasOwnedReset={ [weak self] in self?.ownedReset != nil }
        model.confirmChoice={ [weak self] in await self?.sheets.ask("Are you sure you want to mark the conflicted file(s) as resolved?",buttons:["Yes","No"]) == .alertFirstButtonReturn }
        model.confirmDeletion={ [weak self] request in await self?.sheets.ask("Delete submodule folder?",message:request.gitError+"\n\nMove “\(request.path)” to Trash to resolve its deletion?",buttons:["Delete","Abort"]) == .alertFirstButtonReturn }
        model.operation.confirmCancellation={ [weak self] reply in
            guard let self,!self.closing else{reply(false);return}
            self.pendingReplies += 1
            Task { [self] in
                defer{self.pendingReplies -= 1}
                reply(await self.sheets.ask("The process is still running.",message:"Are you sure to abort?",buttons:["Yes","No"]) == .alertFirstButtonReturn)
            }
        }
        DialogGeometry.attach(window,identifier:"TurtleGit.SubmoduleConflict",legacyName:"TurtleGit.SubmoduleConflict")
    }
    func retainReset(_ child:ResetWindowController) {
        guard !closing,model.operation.active else{child.close();return}
        ownedReset=child
    }
    func resetChildClosed() {
        guard resetDrain == nil else{return}
        guard let child=ownedReset else{model.dismissReset();return}
        resetDrain=Task { @MainActor [self,child] in
            await Task.yield()
            while child.transportBatchWorkPending {try? await Task.sleep(nanoseconds:10_000_000)}
            if ownedReset === child {ownedReset=nil}
            resetDrain=nil;model.dismissReset()
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if model.busy {model.abort();return false}
        return !model.hasPendingWork && model.operation.canClose && sender.attachedSheet == nil
    }
    func windowWillClose(_ notification:Notification) {
        guard notification.object as? NSWindow === window,!closing else{return}
        closing=true;model.invalidate()
        if let window,let sheet=window.attachedSheet {retiringSheets.append(sheet)}
        sheets.retire()
        if let child=ownedReset {child.window?.close();resetChildClosed()}
        if let window {
            if let sheet=window.attachedSheet {if !retiringSheets.contains(where:{$0 === sheet}){retiringSheets.append(sheet)};window.endSheet(sheet,returnCode:.abort);sheet.close()}
            window.sheetParent?.endSheet(window,returnCode:.abort)
        }
        let release=FinderFilesystemWorkflowRelease(ready:{[self] in !underlyingWork}){[self] in
            self.release=nil;retiringSheets.removeAll();let done=onClosed;onClosed={};done()
        }
        self.release=release;release.start()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
@MainActor final class SubmoduleConflictWindowModel: ObservableObject {
    let repository:GitRepository
    let path:String
    let operation:ConflictReviewOperation
    var busy:Bool {operation.busy}
    var error:String? {get{operation.error}set{operation.error=newValue}}
    @Published var details:SubmoduleConflictDetails? {didSet{displayGeneration=UUID()}}
    @Published var confirmingQuit=false {didSet{
        guard oldValue != confirmingQuit else{return};displayGeneration=UUID()
        if confirmingQuit {resetContinuation=nil;if !operation.showingProgress {reloadQueued=true}}
        else if !confirmingQuit {resumeAfterIdle()}
    }}
    private(set) var displayGeneration=UUID()
    private(set) var pendingActions=0
    var hasPendingWork:Bool {operation.busy || pendingActions>0}
    var canInteract:Bool {operation.canInteract && !confirmingQuit && pendingActions==0 && interactionAvailable()}
    private var reloadQueued=false,closeAfterRead=false,resetDismissed=false
    private var resetContinuation:(ConflictEntry,ResolveChoice,UUID)?
    var interactionAvailable:()->Bool={true}
    var hasOwnedReset:()->Bool={false}
    var close:()->Void={}
    var onChanged:(String)->Void={_ in}
    var onLog:(GitRepository,String)->Void={_,_ in}
    var onReset:(GitRepository,String,@escaping()->Void)->Void={_,_,_ in}
    var confirmChoice:() async->Bool={false}
    var confirmDeletion:@Sendable(SubmoduleDeletionRequest) async->Bool={request in await ConflictPrompts.deleteSubmodule(request)}
    var readDetails:((OperationCancellation) async throws->SubmoduleConflictDetails)?
    var resolveEntry:((ConflictEntry,ResolveChoice,OperationCancellation,@escaping @Sendable(GitOutputChunk)->Void) async throws->String)?
    init(repository:GitRepository,access:RepositoryAccessLease?,path:String,preferences:UserDefaults = .standard) {
        self.repository=repository;self.path=path;operation=ConflictReviewOperation(repository:repository,access:access,preferences:preferences)
        operation.onIdle={ [weak self] in self?.resumeAfterIdle() }
    }
    private func resumeAfterIdle() {
        guard operation.active,!confirmingQuit,!hasPendingWork,!operation.hasQuestion else{return}
        if resetDismissed {resetDismissed=false;operation.hasChild=false;if resetContinuation == nil {back();return}}
        if let pending=resetContinuation,!hasOwnedReset(),operation.generation==pending.2 {
            resetContinuation=nil;operation.hasChild=false;apply(pending.0,choice:pending.1);return
        }
        guard operation.canClose else{return}
        if closeAfterRead || operation.success {closeAfterRead=false;close()}
        else if reloadQueued,!operation.showingProgress {reloadQueued=false;load()}
    }
    func invalidate(){reloadQueued=false;resetDismissed=false;resetContinuation=nil;displayGeneration=UUID();operation.invalidate()}
    func abort(){guard operation.active else{return};if busy {if !operation.showingProgress {closeAfterRead=true};operation.cancel()}else if operation.canClose,!hasPendingWork{close()}}
    func back(){guard operation.canClose,!confirmingQuit,!hasPendingWork else{return};operation.back();details=nil;load()}
    func load(){
        guard operation.active else{return}
        guard canInteract else{reloadQueued=true;return};reloadQueued=false
        displayGeneration=UUID()
        let repository=self.repository.capturingDiffBackend(preferences:operation.preferences),identities=ConflictIdentityOptions(defaults:operation.preferences),display=displayGeneration
        let token=operation.begin()
        Task { [self] in
            defer{operation.finish(token);withExtendedLifetime(operation.access){}}
            do {
                try operation.checkAccess()
                let value:SubmoduleConflictDetails
                if let readDetails {value=try await readDetails(token)}else{value=try await repository.submoduleConflictDetails(path:path,identityOptions:identities,cancellation:token)}
                try token.check();guard operation.live(token),!confirmingQuit,displayGeneration==display else{return};details=value
            }catch{if !confirmingQuit,displayGeneration==display {operation.fail(error,token:token)}}
        }
    }
    private func matches(_ side:SubmoduleConflictSide,_ current:SubmoduleConflictDetails)->Bool {
        [current.base,current.mine,current.theirs].contains{$0.stage==side.stage && $0.revision==side.revision && $0.available==side.available && $0.change==side.change && GitReferenceName.equal($0.subject,side.subject)}
    }
    func log(_ side:SubmoduleConflictSide,display:UUID?=nil){
        guard display == nil || display == displayGeneration else{return}
        guard canInteract,side.canShowLog,let revision=side.revision,let original=details,let checkout=original.checkout,matches(side,original) else{return}
        let repository=self.repository.capturingDiffBackend(preferences:operation.preferences),identities=ConflictIdentityOptions(defaults:operation.preferences),display=displayGeneration
        let token=operation.begin()
        Task { [self] in
            defer{operation.finish(token);withExtendedLifetime(operation.access){}}
            do {
                try operation.checkAccess();let current=try await repository.submoduleConflictDetails(path:path,identityOptions:identities,cancellation:token)
                guard current.entry==original.entry,current.checkout==checkout,matches(side,current) else{throw ResolveFailure.stale}
                let child=try await repository.submoduleWorkingRepository(path:path,cancellation:token)
                guard child.root.standardizedFileURL.path==checkout.standardizedFileURL.path else{throw ResolveFailure.stale}
                try token.check();guard operation.live(token),!confirmingQuit,displayGeneration==display else{return};onLog(child,revision)
            }catch{if !confirmingQuit,displayGeneration==display {operation.fail(error,token:token)}}
        }
    }
    func choose(_ side:SubmoduleConflictSide,display:UUID?=nil){
        guard display == nil || display == displayGeneration else{return}
        guard canInteract,let choice=side.choice,let original=details,matches(side,original),[original.mine.stage,original.theirs.stage].contains(side.stage) else{return}
        let generation=operation.generation,display=displayGeneration
        pendingActions += 1;operation.hasQuestion=true
        Task { [self] in
            let accepted=await confirmChoice()
            while operation.active,!confirmingQuit,displayGeneration==display,!interactionAvailable() {try? await Task.sleep(nanoseconds:10_000_000)}
            operation.hasQuestion=false;pendingActions -= 1
            guard operation.active,!confirmingQuit,operation.generation==generation,displayGeneration==display else{resumeAfterIdle();return}
            if accepted {apply(original.entry,choice:choice)}else{resumeAfterIdle()}
        }
    }
    func apply(_ entry:ConflictEntry,choice:ResolveChoice){
        guard operation.active,!confirmingQuit,!busy,!operation.hasQuestion,!operation.hasChild,!operation.confirmingCancellation,pendingActions==0 else{return}
        let display=displayGeneration,token=operation.begin(progress:true)
        Task { [self] in
            defer{operation.finish(token);withExtendedLifetime(operation.access){}}
            do {
                let text=try await operation.stream(token){[self] emit in
                    if let resolveEntry {return try await resolveEntry(entry,choice,token,emit)}
                    return try await repository.resolveConflicts([entry],using:choice,confirmSubmoduleDeletion:confirmDeletion,cancellation:token,onOutput:emit)
                }
                guard operation.live(token),!confirmingQuit,displayGeneration==display else{return};operation.complete(token);onChanged(text)
            }catch ResolveFailure.submoduleCheckout {
                guard operation.live(token),!token.isCancelled,!confirmingQuit,displayGeneration==display else{return}
                do {
                    let (root,revision)=try await repository.submoduleResetTarget(entry,using:choice,cancellation:token)
                    try token.check();guard operation.live(token),!confirmingQuit,displayGeneration==display else{return}
                    let generation=operation.generation;operation.hasChild=true
                    onReset(GitRepository(root:root,executable:repository.executable),revision){[weak self] in
                        guard let self,self.operation.active,!self.confirmingQuit,self.operation.generation==generation,self.displayGeneration==display,self.operation.hasChild else{return}
                        self.resetContinuation=(entry,choice,generation);self.resumeAfterIdle()
                    }
                }catch{if !confirmingQuit,displayGeneration==display {operation.fail(error,token:token)}}
            }catch{
                guard operation.live(token),!confirmingQuit,displayGeneration==display else{return};operation.fail(error,token:token);onChanged(operation.output)
            }
        }
    }
    func dismissReset(){
        guard operation.active else{return}
        if busy {resetDismissed=true;return}
        operation.hasChild=false
        if resetContinuation != nil {resumeAfterIdle()}else if !confirmingQuit{back()}
    }
}
private struct SubmoduleConflictDialog: View {
    @ObservedObject var model: SubmoduleConflictWindowModel
    @ObservedObject var operation: ConflictReviewOperation
    func tint(_ type: SubmoduleChangeType) -> Color {
        switch type {
        case .fastForward: return Color(red: 211/255, green: 249/255, blue: 154/255)
        case .rewind: return Color(red: 249/255, green: 199/255, blue: 229/255)
        case .newerTime: return Color(red: 176/255, green: 223/255, blue: 244/255)
        case .olderTime: return Color(red: 244/255, green: 207/255, blue: 159/255)
        default: return Color(red: 222/255, green: 222/255, blue: 222/255)
        }
    }
    func section(_ side: SubmoduleConflictSide, base: Bool = false) -> some View {
        let display=model.displayGeneration
        return GroupBox(side.title) {
            VStack(alignment: .leading, spacing: 9) {
                if !base {
                    HStack {
                        Text("Type:").frame(width: 65, alignment: .leading)
                        Text(side.change.rawValue).foregroundStyle(side.change == .identical ? Color.primary : .black)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(side.change == .identical ? Color.clear : tint(side.change)).cornerRadius(3)
                        Spacer()
                        Button { model.log(side,display:display) } label: { CommandLabel(title:"Show log",icon:.log) }.frame(width:115).disabled(!side.canShowLog).accessibilityLabel("Show log for \(side.title)").accessibilityIdentifier("SubmoduleConflict.Log.\(side.stage)")
                    }
                }
                HStack {
                    Text("Revision:").frame(width: 65, alignment: .leading)
                    Text(side.revision ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if base {
                        Button {model.log(side,display:display)} label:{CommandLabel(title:"Show log",icon:.log)}.frame(width:115).disabled(!side.canShowLog).accessibilityLabel("Show log for \(side.title)").accessibilityIdentifier("SubmoduleConflict.Log.\(side.stage)")
                    }else{
                        Button("Use this"){model.choose(side,display:display)}.frame(width:115).accessibilityLabel("Use \(side.title)").accessibilityIdentifier("SubmoduleConflict.Use.\(side.stage)")
                    }
                }
                HStack(alignment: .top) {
                    Text("Subject:").frame(width: 65, alignment: .leading)
                    Text(side.subject).foregroundStyle(side.available ? Color.primary : Color.white).textSelection(.enabled).lineLimit(base ? 1:2).help(side.subject)
                        .frame(maxWidth:.infinity,minHeight:base ? 28:42,alignment:.topLeading)
                        .background(side.available ? Color.clear:Color(red:1,green:0,blue:0)).accessibilityIdentifier("SubmoduleConflict.Subject.\(side.stage)")
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(!model.canInteract)
    }
    var body: some View {
        Group {
        if operation.showingProgress { ConflictReviewProgressView(operation: operation, back: model.back) } else {
        VStack(spacing: 12) {
            HStack {
                Text("Submodule " + String(reflecting:model.path)).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(model.path)
                Spacer()
                Button { TurtleGitHelp.show(.resolve) } label: { CommandLabel(title: "Help", icon: .help) }
            }
            if let details = model.details { section(details.base, base: true); section(details.mine); section(details.theirs) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Spacer(minLength: 0)
            if model.busy { HStack { ProgressView().controlSize(.small); Text("Reading conflict metadata…"); Spacer(); Button("Cancel") { model.abort() } } }
        }.padding(14)
        }
        }.onAppear { model.load() }
        .background(Button("") { model.abort() }.keyboardShortcut(.cancelAction).hidden())
        .alert("Could not resolve submodule conflict", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
