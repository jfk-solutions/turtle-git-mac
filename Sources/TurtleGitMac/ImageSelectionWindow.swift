// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import SwiftUI
import TurtleGitCore

@MainActor private final class ImageSelectionNSWindow:NSWindow {
    weak var imageModel:ImageSelectionWindowModel?
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        guard attachedSheet==nil,(firstResponder as? NSTextView)?.isFieldEditor != true,
              let model=imageModel,!model.retired else{return super.performKeyEquivalent(with:event)}
        if event.keyCode==53,event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty,
           !model.busy || model.decoding {performClose(nil);return true}
        if let command=ImageEditorCommand.key(event),model.commandState(command)?.enabled==true {model.perform(command);return true}
        return super.performKeyEquivalent(with:event)
    }
}
@MainActor final class ImageSelectionWindowController:NSWindowController,NSWindowDelegate {
    let model:ImageSelectionWindowModel
    private(set) var imageToolbar:ImageEditorToolbar?
    var onFinished:(Int32)->Void = {_ in}
    var onClosed:()->Void = {}
    init(document:ImageSelectionDocument,permissions:[RepositoryAccessLease],preferences:UserDefaults = .standard,decodeImages:ImageSelectionWindowModel.Decoder?=nil) {
        model=ImageSelectionWindowModel(document:document,permissions:permissions,preferences:preferences,decodeImages:decodeImages)
        let window=ImageSelectionNSWindow(contentRect:.init(x:0,y:0,width:1200,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Select image — TurtleGitIDiff";window.isReleasedWhenClosed=false;window.minSize = .init(width:800,height:400)
        window.contentView=NSHostingView(rootView:ImageSelectionDialog(model:model))
        super.init(window:window);window.delegate=self;window.imageModel=model;model.windowForCommands=window;model.presentation.attach(window)
        model.onAccepted = { [weak self] status in self?.onFinished(status);self?.window?.close() }
        model.askMarkResolved = { [weak model] path in await model?.confirmResolution(path:path) ?? false }
        imageToolbar=ImageEditorToolbar.selection(self)
        TurtleGitHelp.attach(window,topic:.images)
        DialogGeometry.attach(window,identifier:"TurtleGit.ImageSelection");window.center()
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {(!model.busy || model.decoding) && sender.attachedSheet==nil}
    func windowWillClose(_ notification:Notification) {
        guard (notification.object as? NSWindow) === window else{return}
        imageToolbar?.retire();model.retire();(window as? ImageSelectionNSWindow)?.imageModel=nil;onClosed()
    }
    func closeAfterApprovedQuit() {model.cancelWork();window?.close()}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
@MainActor final class ImageSelectionWindowModel:ObservableObject {
    typealias Decoder=(ImageSelectionDocument,OperationCancellation) async throws -> [ImageConflictSide:ComparisonImage]
    static private(set) var activeOperations=0
    @Published private(set) var document:ImageSelectionDocument
    @Published private(set) var images:[ImageConflictSide:ComparisonImage]=[:]
    @Published private(set) var busy=false
    @Published private(set) var decoding=false
    @Published var showInfo=false
    @Published var vertical=false
    @Published var nativeToolbarInstalled=false
    @Published var error:String?
    private(set) var retired=false
    private(set) var completedStatus:Int32?
    private var ownedOperations=0
    var hasPendingWork:Bool {ownedOperations>0 || panes.values.contains{$0.hasPendingFileRead}}
    private var cancellation:OperationCancellation?
    private var task:Task<Void,Never>?
    private var permissions:[RepositoryAccessLease]
    let presentation=ImageWindowPresentation()
    let panes:[ImageConflictSide:ImageComparisonViewModel]
    let presentationPreferences:UserDefaults
    weak var windowForCommands:NSWindow?
    var onAccepted:(Int32)->Void = {_ in}
    var askMarkResolved:(String) async -> Bool = {_ in false}
    let saveFolderAccess=MergeSaveFolderAccess()
    let newOutputResolution=MergeNewOutputAdd()
    var requiresScopes=GitRuntime.isAppStoreBuild {didSet {saveFolderAccess.requireScope=requiresScopes;newOutputResolution.requiresScope=requiresScopes}}
    var decodeImages:Decoder = {document,token in
        try await Task.detached {
            var result:[ImageConflictSide:ComparisonImage]=[:]
            for side in ImageConflictSide.allCases {try token.check();result[side]=document.image(side,cancellation:token)}
            try token.check();return result
        }.value
    }
    private var observations:[AnyCancellable]=[]
    private var question:ExternalMergeSession?
    private struct Resolution {
        let repository:GitRepository,target:MergeToolOutputTarget,entry:ConflictEntry,side:ImageConflictSide
    }
    private var pendingResolution:Resolution?
    @Published private(set) var canRetryResolution=false
    init(document:ImageSelectionDocument,permissions:[RepositoryAccessLease],preferences:UserDefaults = .standard,decodeImages:Decoder?=nil) {
        self.document=document;self.permissions=permissions;presentationPreferences=preferences
        if let decodeImages {self.decodeImages=decodeImages}
        showInfo=document.invocation.showInfo
        let appearance=self.presentation
        panes=Dictionary(uniqueKeysWithValues:ImageConflictSide.allCases.map{($0,ImageComparisonViewModel(presentation:appearance))})
        saveFolderAccess.requireScope=requiresScopes;newOutputResolution.requiresScope=requiresScopes
        for (side,pane) in panes {pane.commandsAllowed = { [weak self] in
            guard let self else{return false};return self.ready && !self.panes.contains{$0.key != side && $0.value.receivingDrop}
        }}
        observations=panes.values.map{$0.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }}
        load(recapturing:false)
    }
    private var ready:Bool {!retired && !busy && !panes.values.contains{$0.receivingDrop} && windowForCommands?.attachedSheet==nil && NSApp.modalWindow==nil}
    func title(for side:ImageConflictSide)->String {
        document.invocation.titles[side] ?? document.inputs[side]?.path ?? side.rawValue
    }
    func canSelect(_ side:ImageConflictSide)->Bool {ready && document.selectionBytes(side) != nil}
    func commandState(_ command:ImageEditorCommand)->ImageEditorCommandState? {
        switch command {
        case .info:return .init(enabled:ready,checked:showInfo)
        case .vertical:return .init(enabled:ready,checked:vertical)
        case .dark:return .init(enabled:ready,checked:presentation.darkMode)
        case .fit,.original,.zoomIn,.zoomOut,.reload,.transparentColor,.fileMenu,.viewMenu:return .init(enabled:ready)
        default:return nil
        }
    }
    func perform(_ command:ImageEditorCommand) {
        guard commandState(command)?.enabled==true else{return}
        switch command {
        case .info:showInfo.toggle();case .vertical:vertical.toggle();case .dark:presentation.toggleDarkMode()
        case .fit:panes.values.forEach{$0.fit=true};case .original:panes.values.forEach{$0.originalSize()}
        case .zoomIn:panes.values.forEach{$0.changeZoom(zoomIn:true)};case .zoomOut:panes.values.forEach{$0.changeZoom(zoomIn:false)}
        case .reload:reload();case .transparentColor:presentation.chooseTransparentColor()
        default:break
        }
    }
    private func begin(decoding:Bool=false)->OperationCancellation {
        let token=OperationCancellation();cancellation=token;busy=true;self.decoding=decoding;error=nil
        ownedOperations+=1;Self.activeOperations+=1;return token
    }
    private func end(_ token:OperationCancellation) {
        ownedOperations-=1;Self.activeOperations-=1
        if cancellation === token {cancellation=nil;task=nil;busy=false;decoding=false}
    }
    private func current(_ token:OperationCancellation)->Bool {!retired && cancellation === token}
    private func load(recapturing:Bool) {
        let token=begin(decoding:true),snapshot=document,decode=decodeImages,held=permissions
        task=Task {
            defer {end(token);withExtendedLifetime(held) {}}
            do {
                let next=recapturing ? try await Task.detached {try ImageSelectionDocument.capture(invocation:snapshot.invocation,cancellation:token)}.value:snapshot
                let decoded=try await decode(next,token);try token.check();guard current(token) else{return}
                document=next;images=decoded;pendingResolution=nil;canRetryResolution=false;completedStatus=nil
                for side in ImageConflictSide.allCases {panes[side]?.configureImages(base:decoded[side],destination:nil,force:true)}
            } catch {if current(token),!token.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func reload() {guard ready else{return};load(recapturing:true)}
    func cancelWork() {cancellation?.cancel();saveFolderAccess.cancel();newOutputResolution.cancel();question?.retire(cancelWork:true)}
    func retire() {
        guard !retired else{return};retired=true;cancelWork();presentation.retire();panes.values.forEach{$0.retire()};observations=[]
    }
    func confirmResolution(path:String) async -> Bool {
        guard !retired,let window=windowForCommands,window.attachedSheet==nil else{return false}
        let session=ExternalMergeSession(owner:window,cancellation:cancellation);question=session
        defer {session.retire(cancelWork:false);if question === session {question=nil}}
        return await session.confirmImageResolution(path:path)
    }
    private func finish(_ side:ImageConflictSide) {
        guard !retired else{return};completedStatus=ImageToolInvocation.selectionExitCode(side);onAccepted(ImageToolInvocation.selectionExitCode(side))
    }
    func select(_ side:ImageConflictSide) {
        guard canSelect(side) else{return}
        let token=begin(),snapshot=document,held=permissions
        task=Task {
            defer {end(token);withExtendedLifetime(held) {}}
            do {
                if let output=snapshot.output {
                    guard let acquired=try await saveFolderAccess.authorize(file:output.url,permissions:permissions,window:windowForCommands,cancellation:token) else{return}
                    try token.check();guard current(token) else{return};permissions+=acquired
                }
                let next=try await Task.detached {try snapshot.select(side,cancellation:token)}.value
                // A successful raw-byte publication is accepted even when Cancel
                // arrived after rename. Optional Git work has a separate boundary.
                guard current(token) else{return};document=next;pendingResolution=nil;canRetryResolution=false
                if token.isCancelled {finish(side);return}
                guard let output=next.output else {finish(side);return}
                guard let context=try await resolution(for:output,side:side,token:token) else {if current(token) {finish(side)};return}
                guard current(token),!token.isCancelled else{return};pendingResolution=context
                guard await askMarkResolved(context.entry.path),current(token),!token.isCancelled else{return}
                try await resolve(context,token:token)
            } catch {if current(token),!token.isCancelled {self.error=error.localizedDescription;canRetryResolution=pendingResolution != nil}}
        }
    }
    private func resolution(for output:MergeToolOutputTarget,side:ImageConflictSide,token:OperationCancellation) async throws -> Resolution? {
        let held=permissions,scoped=requiresScopes
        let discovered=try await Task.detached {try RepositoryMetadataAccess.discoverMergeOutputRepository(at:output.url.deletingLastPathComponent(),permissions:held,requireSecurityScope:scoped,cancellation:token)}.value
        // Source discovery failure still leaves a valid selected/copied image.
        // A partial sandbox grant is not permission to start Git's upward walk.
        guard case .repository=discovered else{return nil}
        guard let authorized=try await newOutputResolution.prepareSavedResolution(file:output.url,permissions:permissions,window:windowForCommands,cancellation:token) else{return nil}
        try token.check();guard current(token) else{throw OperationCancellationFailure.cancelled};permissions+=authorized.1
        let root=authorized.0.root.standardizedFileURL,path=output.url.standardizedFileURL
        let prefix=root.path+"/"
        guard path.path.utf8.starts(with:prefix.utf8) else{throw ResolveFailure.outsideWorkingTree}
        let relative=String(path.path.dropFirst(prefix.count)),entries=try await authorized.0.conflicts(paths:[relative],cancellation:token)
        guard let entry=entries.first(where:{GitReferenceName.equal($0.path,relative) && $0.stages.contains{$0.number==1 || $0.number==2}}) else{return nil}
        return Resolution(repository:authorized.0,target:output,entry:entry,side:side)
    }
    private func resolve(_ context:Resolution,token:OperationCancellation) async throws {
        try token.check();guard current(token) else{throw OperationCancellationFailure.cancelled}
        try await context.repository.resolveSelectedImageOutput(context.target,expectedConflict:context.entry,cancellation:token)
        guard current(token) else{return};pendingResolution=nil;canRetryResolution=false;finish(context.side)
    }
    func retryResolution() {
        guard ready,canRetryResolution,let context=pendingResolution else{return}
        let token=begin(),held=permissions
        task=Task {
            defer {end(token);withExtendedLifetime(held) {}}
            do {guard await askMarkResolved(context.entry.path),current(token),!token.isCancelled else{return};try await resolve(context,token:token)}
            catch {if current(token),!token.isCancelled {self.error=error.localizedDescription}}
        }
    }
}
private struct ImageSelectionDialog:View {
    @ObservedObject var model:ImageSelectionWindowModel
    var body:some View {
        VStack(spacing:0) {
            if model.vertical {VSplitView {pane(.mine);pane(.base);pane(.theirs)}}
            else {HSplitView {pane(.mine);pane(.base);pane(.theirs)}}
            if let error=model.error {Text(error).foregroundStyle(.red).textSelection(.enabled).padding(8)}
            HStack {
                if model.busy {ProgressView().controlSize(.small)}
                Text(model.busy ? (model.decoding ? "Loading images…":"Selecting image…"):"")
                if model.canRetryResolution {Button {model.retryResolution()} label:{CommandLabel(title:"Retry Mark as resolved",icon:.resolve)}}
                Spacer();Text(model.document.invocation.result?.path ?? "Choose an image").lineLimit(1).truncationMode(.middle)
            }.font(.caption).padding(8).frame(minHeight:32)
        }.background(Color(nsColor:.windowBackgroundColor))
    }
    private func pane(_ side:ImageConflictSide)->some View {
        ImageConflictPane(side:side,image:model.images[side],bytes:model.document.inputs[side]?.bytes.count ?? 0,title:model.title(for:side),selectable:model.canSelect(side),emptyBase:false,model:model.panes[side]!,info:model.showInfo,originalPath:model.document.inputs[side]?.path,previewNotice:"Preview only — Select uses the original input image.",unavailableNotice:model.document.inputFailures[side] ?? (model.document.inputs[side]?.isDeleted==true ? "Image file not found — this side cannot be selected":nil)) {model.select(side)}
    }
}
