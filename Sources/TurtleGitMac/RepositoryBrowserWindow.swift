// Adapts RepositoryBrowser.cpp dialog/menu workflows, GPL-2.0-or-later.
// Copyright (C) 2009-2026 TortoiseGit; 2003-2013 TortoiseSVN.
import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

/// A stored-object inspection never materializes a Git pathname or runs filters.
@MainActor final class RepositoryBrowserStoredBlobWindow: NSWindowController, NSWindowDelegate {
    var onClosed:()->Void = {}
    let bytes:Data
    let textView=NSTextView()
    init(bytes:Data,path:String,objectID:String) {
        self.bytes=bytes
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:540),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Stored blob (unfiltered) – TurtleGit";window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self
        let root=NSView(),label=NSTextField(wrappingLabelWithString:path+"\n"+objectID+"\nStored blob (unfiltered)"),scroll=NSScrollView()
        label.isSelectable=true;label.setAccessibilityIdentifier("RepositoryBrowser.StoredBlobIdentity")
        textView.frame=NSRect(x:0,y:0,width:780,height:450);textView.autoresizingMask=[.width];textView.isVerticallyResizable=true;textView.textContainer?.widthTracksTextView=true
        textView.isEditable=false;textView.isSelectable=true;textView.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        textView.setAccessibilityIdentifier("RepositoryBrowser.StoredBlobContents")
        if !bytes.contains(0),let text=String(data:bytes,encoding:.utf8) {textView.string=text}
        else {
            let digits=Array("0123456789abcdef".utf8);var rendered=[UInt8]();rendered.reserveCapacity(bytes.count*4)
            for (index,byte) in bytes.enumerated() {
                if index % 16 == 0 {rendered.append(contentsOf:String(format:"%08x  ",index).utf8)}
                rendered.append(digits[Int(byte>>4)]);rendered.append(digits[Int(byte&15)]);rendered.append(index % 16 == 15 ? 10:32)
            }
            textView.string=String(decoding:rendered,as:UTF8.self)
        }
        scroll.documentView=textView;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        root.addSubview(label);root.addSubview(scroll);label.translatesAutoresizingMaskIntoConstraints=false;scroll.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo:root.topAnchor,constant:12),label.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),label.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),scroll.topAnchor.constraint(equalTo:label.bottomAnchor,constant:12),scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        window.contentView=root;window.contentMinSize=NSSize(width:500,height:300)
    }
    func windowWillClose(_ notification:Notification){let finish=onClosed;onClosed={};finish()}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}

private final class RepositoryBrowserNativeWindow: NSWindow {
    weak var model: RepositoryBrowserWindowModel?
    var commandKeyWindow: () -> NSWindow? = {NSApp.keyWindow}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard commandKeyWindow() === self,event.window === self else {return super.performKeyEquivalent(with:event)}
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if firstResponder is NSTableView,!(firstResponder is NSOutlineView),flags == .command || flags == .control {
            if event.keyCode == 0 {
                if attachedSheet == nil,let model,model.canUseMenu {model.selection = Set(model.entries.map(\.id))};return true
            }
            if event.keyCode == 8 {if attachedSheet == nil {model?.copy()};return true}
        }
        if let tree = firstResponder as? RepositoryBrowserFolderOutline,event.keyCode == 8,flags == .command || flags == .control {
            if attachedSheet == nil,model?.canUseMenu == true {tree.copySelection()};return true
        }
        if event.keyCode == 96,flags.isEmpty {if attachedSheet == nil {model?.refresh()};return true}
        if [36,76].contains(event.keyCode),!flags.contains(.option),firstResponder is NSTableView,!(firstResponder is NSOutlineView) {
            if attachedSheet == nil,let model,model.canUseMenu,model.selected.count == 1,let entry = model.selected.first {model.open(entry)}
            return true
        }
        return super.performKeyEquivalent(with:event)
    }
}
/// A retired window releases its modal request immediately, but actual I/O and
/// launch callbacks retain their own Quit lifetime until they settle.
@MainActor final class RepositoryBrowserFileOperation {
    static private(set) var activeRequests=0
    let cancellation=OperationCancellation()
    var working=false
    private var finished=false
    var hasPendingWork:Bool {!finished}
    init() {Self.activeRequests += 1}
    func finish() {guard !finished else {return};finished=true;Self.activeRequests -= 1}
    func retire() {cancellation.cancel();if !working {finish()}}
}

@MainActor final class RepositoryBrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: RepositoryBrowserWindowModel
    var commandKeyWindow: () -> NSWindow? = {NSApp.keyWindow}
    var onClosed: () -> Void = {}
    private var retired=false,releasing=false
    private var retiredChecks:[()->Bool]=[]
    var canReuse:Bool {!retired && model.active && !model.confirmingQuit}
    var hasPendingWork:Bool {releasing || model.hasPendingWork || fileOperation?.hasPendingWork == true || retiredChecks.contains{$0()} || picker != nil || pickerRelease || ownedSheet?.sheetParent != nil}

    private(set) var picker: LogWindowController?
    private var pickerIdentity:UUID?
    private var pickerChoice:LogEntry?
    private var pickerRelease=false
    var configureLogPicker:(LogWindowModel)->Void = { _ in }
    private(set) weak var contentsTable:NSTableView?
    private var initialContentsFocusPending=true
    private var ownedSheet:NSWindow?
    private var fileOperation:RepositoryBrowserFileOperation?
    private var submoduleUpdateReply:((NSApplication.ModalResponse)->Void)?
    private(set) var storedBlobWindows:[RepositoryBrowserStoredBlobWindow]=[]
    var presentStoredBlobWindow:(RepositoryBrowserStoredBlobWindow)->Void = {$0.showWindow(nil)}
    var presentSubmoduleUpdate:((NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var presentSavePanel:((NSSavePanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    var presentApplicationPanel:((NSOpenPanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    var saveDestination:(NSSavePanel)->URL? = {$0.url}
    var selectedApplication:(NSOpenPanel)->URL? = {$0.url}
    var defaultApplication:(URL)->URL? = {NSWorkspace.shared.urlForApplication(toOpen:$0)}
    var launchDocument:ExternalDocumentApplication.Launch?
    var writeDocument:(Data,URL,OperationCancellation)async throws->Void = {bytes,url,token in
        try await Task.detached {try token.check();try bytes.write(to:url,options:.atomic)}.value
    }

    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences:UserDefaults = .standard, initialFile: String? = nil) {
        model = RepositoryBrowserWindowModel(repository: repository, access: access, revision: revision, preferences:preferences)
        model.initialFile = initialFile
        let window = RepositoryBrowserNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Repository Browser", preferences: preferences)
        window.contentMinSize = NSSize(width: 760, height: 440); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RepositoryBrowserDialog(model: model))
        super.init(window: window); window.delegate = self; window.model = model;window.commandKeyWindow = { [weak self] in self?.commandKeyWindow() }
        window.setContentSize(NSSize(width: 1000, height: 650))
        window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.contentsTableAttached = { [weak self] table in
            guard let self,self.model.active else{return}
            self.contentsTable=table
            guard self.initialContentsFocusPending else{return}
            self.window?.initialFirstResponder=table
            DispatchQueue.main.async { [weak self] in self?.focusInitialContentsIfNeeded() }
        }
        model.chooseRevision = { [weak self] in self?.chooseRevision() }
        model.presentFile = { [weak self] content, action in self?.presentFile(content,action:action) }
        model.presentStoredBlob = { [weak self] bytes,entry in
            guard let self,self.model.canUseMenu else{return}
            let child=RepositoryBrowserStoredBlobWindow(bytes:bytes,path:entry.displayPath,objectID:entry.objectID)
            child.window?.appearance=self.window?.effectiveAppearance;child.window?.alphaValue=self.window?.alphaValue ?? 1
            child.onClosed={ [weak self,weak child] in self?.storedBlobWindows.removeAll{$0 === child} }
            self.storedBlobWindows.append(child);self.presentStoredBlobWindow(child)
        }
        model.handleRevertFailure = { [weak self] message in
            guard let self, self.model.active, let window=self.window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Could not revert file"
            alert.informativeText = message; alert.alertStyle = .warning
            alert.addButton(withTitle:"Continue"); alert.addButton(withTitle:"Cancel")
            self.ownedSheet = alert.window
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for:window) { [weak self] response in
                    if self?.ownedSheet === alert.window { self?.ownedSheet = nil }
                    continuation.resume(returning:self?.model.active == true && response == .alertFirstButtonReturn)
                }
            }
        }
        model.showRevertResult = { [weak self] message in
            guard let self, self.model.active, let window=self.window, window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.messageText = "Revert to this revision"; alert.informativeText = message
            alert.addButton(withTitle:"OK"); self.ownedSheet = alert.window
            alert.beginSheetModal(for:window) { [weak self] _ in
                if self?.ownedSheet === alert.window { self?.ownedSheet = nil }
            }
        }
        model.offerSubmoduleUpdate = { [weak self] entry in
            guard let self,self.model.active,!self.model.confirmingQuit,self.fileOperation==nil,let window=self.window,window.attachedSheet==nil else{return}
            let identity=self.model.generation,object=self.model.snapshot?.objectID,directory=self.model.snapshot?.directory,callback=self.model.onSubmoduleUpdate
            let operation=RepositoryBrowserFileOperation();operation.working=true
            self.fileOperation=operation;self.model.handlingFile=true
            let alert=NSAlert(); alert.messageText="Update submodule?"
            alert.informativeText="Revision " + entry.objectID + " is unavailable in submodule “" + entry.path + "”. Update the submodule to browse it."
            alert.addButton(withTitle:"Update"); alert.addButton(withTitle:"Cancel"); self.ownedSheet=alert.window
            alert.window.appearance=window.appearance;alert.window.alphaValue=window.alphaValue
            var answered=false
            let reply:(NSApplication.ModalResponse)->Void={ [self] response in
                guard !answered else{return};answered=true
                Task { @MainActor [self,operation] in
                    alert.window.sheetParent?.endSheet(alert.window,returnCode:response);alert.window.orderOut(nil)
                    while alert.window.sheetParent != nil{try? await Task.sleep(nanoseconds:5_000_000)}
                    let accepted=self.fileOperation===operation && self.ownedSheet===alert.window && self.model.active && !self.model.confirmingQuit && !operation.cancellation.isCancelled && self.model.generation==identity && self.model.snapshot?.objectID==object && RepositoryBrowserPathIdentity.equal(self.model.snapshot?.directory ?? "",directory ?? "") && response == .alertFirstButtonReturn
                    if self.ownedSheet===alert.window{self.ownedSheet=nil}
                    self.submoduleUpdateReply=nil;self.finishFile(operation)
                    if accepted{callback(entry.path)}
                }
            }
            self.submoduleUpdateReply=reply
            if let presenter=self.presentSubmoduleUpdate{presenter(alert,window,reply)}else{alert.beginSheetModal(for:window,completionHandler:reply)}
        }
        model.confirmResetColumns = { [weak self] in
            guard let self,self.model.active,let window=self.window,window.attachedSheet==nil else { return false }
            let alert=NSAlert();alert.messageText="Reset columns?";alert.informativeText="Restore the default Repository Browser columns, order and widths?"
            alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No");self.ownedSheet=alert.window
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for:window) { [weak self] response in
                    if self?.ownedSheet === alert.window { self?.ownedSheet=nil }
                    continuation.resume(returning:self?.model.active == true && response == .alertFirstButtonReturn)
                }
            }
        }
        model.refresh()

        DialogGeometry.attach(window, identifier: "TurtleGit.RepositoryBrowser", legacyName: "TurtleGit.RepositoryBrowser")
    }
    private func chooseRevision() {
        guard canReuse,model.canUseMenu,picker==nil,!pickerRelease,let window,window.attachedSheet==nil else{return}
        let identity=UUID(),generation=model.generation
        pickerIdentity=identity;pickerChoice=nil;model.choosingRevision=true
        let controller=LogWindowController(repository:model.repository,access:model.access,onChoose:{ [weak self] entry in
            guard let self,self.pickerIdentity==identity else{return};self.pickerChoice=entry
        },labelDefaults:model.preferences,initialRevision:model.snapshot?.objectID)
        picker=controller
        controller.onClosed={ [weak self,weak controller] in
            guard let self,let controller,self.pickerIdentity==identity,self.picker === controller else{return}
            self.pickerRelease=true
            let child=controller.window
            if let child {child.sheetParent?.endSheet(child);child.orderOut(nil)}
            let release=FinderFilesystemWorkflowRelease(ready:{
                controller.model.pendingHistoryLoads==0 && !controller.model.noteWorkPending && child?.sheetParent==nil
            },completion:{ [self,controller] in
                self.pickerRelease=false
                guard self.pickerIdentity==identity,self.picker === controller else{return}
                let entry=self.pickerChoice;self.pickerChoice=nil;self.pickerIdentity=nil;self.picker=nil;self.model.choosingRevision=false
                guard self.canReuse,self.model.generation==generation else{return}
                if let entry {self.model.revision=entry.hash;self.model.refresh()}
            });release.start()
        }
        configureLogPicker(controller.model)
        guard canReuse,pickerIdentity==identity,picker === controller,let child=controller.window else{controller.close();return}
        child.appearance=window.appearance;child.alphaValue=window.alphaValue;window.beginSheet(child)
    }
    private func presentFile(_ content:ComparisonFileContent,action:RepositoryBrowserWindowModel.FileAction) {
        guard model.active,fileOperation == nil,let window,window.attachedSheet == nil else {return}
        let generation=model.generation,revision=model.revision,object=model.snapshot?.objectID,directory=model.snapshot?.directory
        let operation=RepositoryBrowserFileOperation();fileOperation=operation;model.handlingFile=true
        let current:()->Bool = { [weak self,weak window] in
            guard let self else {return false}
            return self.fileOperation === operation && self.model.active && !operation.cancellation.isCancelled && self.window === window && window != nil && self.model.generation==generation && Data(self.model.revision.utf8)==Data(revision.utf8) && self.model.snapshot?.objectID==object && Data((self.model.snapshot?.directory ?? "").utf8)==Data((directory ?? "").utf8)
        }
        if action == .save {
            let name:String
            do{name=try HistoricalFileDeliveryName.leaf(for:content)}catch{model.error=error.localizedDescription;finishFile(operation);return}
            let panel=NSSavePanel();panel.title="Save revision to…";panel.nameFieldStringValue=name;panel.directoryURL=model.repository.root;ownedSheet=panel
            var answered=false
            let reply:(NSApplication.ModalResponse)->Void = { [weak self] response in
                guard !answered,let self,self.fileOperation === operation,self.ownedSheet === panel else {return};answered=true
                let destination=self.saveDestination(panel)
                operation.working=true
                let writer=self.writeDocument
                Task { [self,operation] in
                    defer {self.finishFile(operation)}
                    panel.sheetParent?.endSheet(panel,returnCode:response);panel.orderOut(nil)
                    while panel.sheetParent != nil {try? await Task.sleep(nanoseconds:5_000_000)}
                    if self.ownedSheet === panel {self.ownedSheet=nil}
                    guard response == .OK,current(),!self.model.confirmingQuit,let url=destination,url.isFileURL else {return}
                    let grant=RepositoryAccessLease(url:url)
                    defer {withExtendedLifetime(grant){}}
                    do {try operation.cancellation.check();try await writer(content.bytes,url,operation.cancellation)}
                    catch {if current() {self.model.error=error.localizedDescription}}
                }
            }
            if let presentSavePanel {presentSavePanel(panel,window,reply)} else {panel.beginSheetModal(for:window,completionHandler:reply)}
        } else if action == .openWith {
            let panel=NSOpenPanel();panel.title="Open With";panel.prompt="Open";panel.allowedContentTypes=[.applicationBundle];panel.directoryURL=URL(fileURLWithPath:"/Applications");panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;ownedSheet=panel
            var answered=false
            let reply:(NSApplication.ModalResponse)->Void = { [weak self] response in
                guard !answered,let self,self.fileOperation === operation,self.ownedSheet === panel else {return};answered=true
                let app=self.selectedApplication(panel);operation.working=true
                Task { [self,operation] in
                    panel.sheetParent?.endSheet(panel,returnCode:response);panel.orderOut(nil)
                    while panel.sheetParent != nil {try? await Task.sleep(nanoseconds:5_000_000)}
                    if self.ownedSheet === panel {self.ownedSheet=nil}
                    guard response == .OK,current(),!self.model.confirmingQuit,let app else {self.finishFile(operation);return}
                    self.open(content,action:action,application:app,operation:operation,current:current)
                }
            }
            if let presentApplicationPanel {presentApplicationPanel(panel,window,reply)} else {panel.beginSheetModal(for:window,completionHandler:reply)}
        } else {open(content,action:action,operation:operation,current:current)}
    }
    private func finishFile(_ operation:RepositoryBrowserFileOperation) {
        operation.finish()
        if fileOperation === operation {fileOperation=nil;model.handlingFile=false}
    }
    private func open(_ content:ComparisonFileContent,action:RepositoryBrowserWindowModel.FileAction,application:URL? = nil,operation:RepositoryBrowserFileOperation,current:@escaping ()->Bool) {
        guard current() else {finishFile(operation);return};operation.working=true
        let launch=launchDocument,editor=model.materializationEditorSettings ?? .load(from:model.preferences),permissions=model.access.map {[$0]} ?? [],defaultApplication=self.defaultApplication,cancellation=operation.cancellation
        let applicationGrant=application.map {RepositoryAccessLease(url:$0)}
        Task { [self,operation,permissions,applicationGrant] in
            defer {withExtendedLifetime(permissions) {};withExtendedLifetime(applicationGrant) {};self.finishFile(operation)}
            var preview:HistoricalFilePreview?,dispatched=false
            do {
                guard !GitRuntime.isAppStoreBuild || application == nil || applicationGrant?.hasSecurityScope == true else {throw ExternalDocumentApplication.Failure.programPermission}
                let prepared=try await Task.detached {try cancellation.check();return try HistoricalFilePreview.create(content)}.value
                preview=prepared;try operation.cancellation.check();guard current() else {throw OperationCancellationFailure.cancelled}
                if action == .alternativeEditor {
                    HistoricalPreviewFiles.retain(prepared);dispatched=true
                    try await AlternativeEditor.openDocument(prepared.file,settings:editor,permissions:permissions,cancellation:cancellation,launch:launch)
                } else {
                    guard let app=application ?? defaultApplication(prepared.file) else {throw CocoaError(.fileReadUnknown,userInfo:[NSLocalizedDescriptionKey:"Could not open the historical file. Choose an application using Open With."])}
                    var program=DiffToolProgram();program.enabled=true;program.applicationPath=app.path
                    HistoricalPreviewFiles.retain(prepared);dispatched=true
                    try await ExternalDocumentApplication.open(file:prepared.file,program:program,arguments:[],nativeDocumentOpen:true,permissions:permissions,cancellation:operation.cancellation,requiresProgramScope:false,launch:launch)
                }
            } catch {
                // Once launch has been attempted, a receiving app may own the
                // input even when its receipt fails or its browser has closed.
                if !dispatched {preview?.discard()}
                if current() {self.model.error=error.localizedDescription}
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.attachedSheet == nil && !model.mutating && !model.confirmingQuit }
    func windowWillClose(_ notification:Notification) {
        guard !retired else{return};retired=true;model.invalidate()
        storedBlobWindows.forEach{$0.close()};storedBlobWindows=[]
        submoduleUpdateReply?(.cancel)
        let operation=fileOperation,child=picker,sheet=ownedSheet
        fileOperation=nil;model.handlingFile=false;operation?.retire()
        pickerIdentity=nil;pickerChoice=nil;model.choosingRevision=false
        if let sheet {sheet.sheetParent?.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)}
        ownedSheet=nil;child?.close();picker=nil
        retiredChecks=[{operation?.hasPendingWork == true || (child?.model.pendingHistoryLoads ?? 0)>0 || child?.model.noteWorkPending == true || child?.window?.sheetParent != nil || sheet?.sheetParent != nil}]
        releasing=true
        let release=FinderFilesystemWorkflowRelease(ready:{ [self,child,operation] in !model.hasPendingWork && !retiredChecks.contains{$0()} },completion:{ [self,child,operation] in
            retiredChecks=[];releasing=false;let finish=onClosed;onClosed={};finish();withExtendedLifetime((child,operation)){}
        });release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowDidBecomeKey(_ notification:Notification){focusInitialContentsIfNeeded()}
    func focusInitialContentsIfNeeded(){
        guard initialContentsFocusPending,model.active,!model.busy,!model.mutating,!model.confirmingColumns,let window,let contentsTable,contentsTable.window===window,commandKeyWindow()===window else{return}
        initialContentsFocusPending=false
        guard window.attachedSheet==nil,!model.confirmingQuit,!model.choosingRevision,!model.handlingFile else{return}
        // A deliberate tree selection or field edit already owns focus. Initial
        // source focus is one-shot; refresh and subsequent activation never steal it.
        if window.firstResponder is NSOutlineView || window.firstResponder is NSTextView{return}
        window.makeFirstResponder(contentsTable)
    }
}
@MainActor final class RepositoryBrowserWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    @Published var revision: String
    @Published private(set) var revisionLabel:String
    @Published var choosingRevision=false {didSet{transferEpoch=UUID()}}
    @Published var handlingFile=false {didSet{transferEpoch=UUID()}}
    var clipboard:NSPasteboard = .general
    @Published private(set) var snapshot: RepositoryBrowserSnapshot?
    @Published private(set) var directories: RepositoryBrowserPathMap<[RepositoryBrowserEntry]> = [:]
    @Published var expanded: RepositoryBrowserPathSet = [""]
    @Published var selection = Set<String>()
    @Published var sortOrder = [KeyPathComparator(\RepositoryBrowserEntry.name)] {didSet{transferEpoch=UUID()}}
    @Published var busy = false {didSet{transferEpoch=UUID()}}
    @Published var mutating = false {didSet{transferEpoch=UUID()}}
    @Published var confirmingQuit = false {didSet{transferEpoch=UUID()}}
    @Published var error: String?
    @Published var comparisonMark: PreparedFileComparisonMark? {didSet{comparisonMarkRevision=UUID()}}
    private var lastImportedWorkingMark: UUID?
    private var comparisonMarkRevision=UUID()
    var currentWorkingComparisonMark:(()->WorkingComparisonAccess?)?
    var contentsTableAttached:(NSTableView)->Void={_ in}
    private(set) var generation = UUID()
    private var menuGeneration = UUID()
    private var transferEpoch=UUID()
    func transferContext(tree:Bool)->String? {
        guard canUseMenu,let snapshot,snapshot.objectID != nil else{return nil}
        return generation.uuidString+transferEpoch.uuidString+String(columnsRevision)+(tree ? "":RepositoryBrowserPathIdentity.id(snapshot.directory))
    }
    private var loads = RepositoryBrowserPathSet()
    private var listings: RepositoryBrowserPathMap<RepositoryBrowserSnapshot> = [:]
    private var requestedDirectory = ""
    private(set) var transferInventory:[RepositoryBrowserEntry]?
    private(set) var transferInventoryError:String?
    private(set) var transferInventoryBusy=false
    private var transferDirectories:RepositoryBrowserPathMap<[RepositoryBrowserEntry]>=[:]
    private var transferDirectoryErrors:RepositoryBrowserPathMap<String>=[:]
    private var transferDirectoryLoads=RepositoryBrowserPathSet()
    private(set) var active = true
    private(set) static var activeOperations = 0
    private var requests: [UUID: OperationCancellation] = [:]
    var hasPendingWork:Bool {!requests.isEmpty}
    private var openRequest: UUID?
    private func startRequest() -> (UUID, OperationCancellation) {
        let id = UUID(), cancellation = OperationCancellation()
        requests[id] = cancellation; Self.activeOperations += 1
        return (id, cancellation)
    }
    private func finishRequest(_ id: UUID) {
        if requests.removeValue(forKey:id) != nil { Self.activeOperations -= 1 }
        if openRequest == id { openRequest = nil }
    }
    private func cancelRequests() { requests.values.forEach { $0.cancel() } }
    var handleRevertFailure: (String) async -> Bool = { _ in false }
    var showRevertResult: (String) -> Void = { _ in }
    var onChanged: () -> Void = {}
    var close: () -> Void = {}
    var chooseRevision: () -> Void = {}
    var offerSubmoduleUpdate: (RepositoryBrowserEntry) -> Void = { _ in }
    var onSubmoduleUpdate: (String) -> Void = { _ in }
    let preferences:UserDefaults
    private(set) var materializationEditorSettings:AlternativeEditorPreferences?
    var captureMaterializationBackend:(()->GitLibGit2Configuration)?
    func materializationBackend()->GitLibGit2Configuration {captureMaterializationBackend?() ?? .load(from:preferences,helperURL:repository.libgit2Configuration?.helperURL)}
    @Published private(set) var columns:RepositoryBrowserColumns
    private(set) var columnsRevision = 0
    static let dividerKey = "TurtleGit.RepositoryBrowser.Divider"
    private(set) var dividerWidth: Double?
    func saveDivider(_ width:Double) {
        guard canUseMenu,width.isFinite,(160...10000).contains(width),dividerWidth != width else {return}
        dividerWidth = width;preferences.set(width,forKey:Self.dividerKey)
    }
    @Published private(set) var confirmingColumns=false
    var confirmResetColumns: () async -> Bool = { false }
    var canEditColumns:Bool { canUseMenu }
    func saveColumns(_ value:RepositoryBrowserColumns) {
        guard canEditColumns else { return }
        let value = RepositoryBrowserColumns(visible:value.visible,order:value.order,widths:value.widths)
        guard columns != value else {return};columns = value;columnsRevision &+= 1;columns.save(preferences)
    }
    func requestResetColumns() {
        guard canEditColumns else { return };confirmingColumns=true
        let identity=generation,layout=columnsRevision,(request,cancellation)=startRequest()
        Task { [self] in
            defer { confirmingColumns=false;finishRequest(request) }
            let accepted=await confirmResetColumns()
            guard active,generation==identity,columnsRevision==layout,!cancellation.isCancelled,accepted else { return }
            columns=RepositoryBrowserColumns();columnsRevision &+= 1;columns.save(preferences)
        }
    }
    var onLog: (String, String) -> Void = { _, _ in }
    var onBlame: (String, String) -> Void = { _, _ in }
    private(set) var acceptedNavigationRepository:GitRepository?
    var onCompare: (String, String) -> Void = { _, _ in }
    var onSubmodule: (SubmoduleComparison, RepositoryBrowserEntry, Bool) -> Void = { _, _, _ in }
    var onPreparedFileCompare: ((PreparedFileComparisonMark, PreparedFileComparisonMark) -> Void)?
    enum FileAction { case open, openWith, alternativeEditor, save }
    var presentFile: (ComparisonFileContent, FileAction) -> Void = { _, _ in }
    var presentStoredBlob:(Data,RepositoryBrowserEntry)->Void = {_,_ in}
    var readStoredBlob:((RepositoryBrowserSnapshot,RepositoryBrowserEntry,OperationCancellation)async throws->Data)?
    var readStoredFile:((RepositoryBrowserSnapshot,RepositoryBrowserEntry,OperationCancellation)async throws->ComparisonFileContent)?
    static let rawPathReason="This Git pathname cannot be represented as a macOS text path. Historical Open, Save and comparison use safe temporary files. Working-tree filesystem and mutation actions are unavailable."
    func requireRepresentable(_ path:String)->Bool {
        guard (try? RepositoryBrowserGitPath(key:path).isRepresentable)==true else {error=Self.rawPathReason;return false};return true
    }
    private func parentPath(_ key:String)->String {(try? RepositoryBrowserGitPath(key:key).parentKey) ?? ""}
    private func pathDepth(_ key:String)->Int {(try? RepositoryBrowserGitPath(key:key).ancestorKeys.count) ?? 0}
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences:UserDefaults = .standard) { self.repository = repository; self.access = access; self.revision = revision;self.revisionLabel=revision; self.preferences=preferences;self.columns = .load(preferences)
        let width = preferences.object(forKey:Self.dividerKey) as? NSNumber
        dividerWidth = width.flatMap {let value = $0.doubleValue;return value.isFinite && (160...10000).contains(value) ? value:nil}
    }
    var entries: [RepositoryBrowserEntry] {
        let first = sortOrder.first
        let column: RepositoryBrowserSort = first?.keyPath == \RepositoryBrowserEntry.fileExtension ? .fileExtension : first?.keyPath == \RepositoryBrowserEntry.sizeSort ? .size : .name
        return RepositoryBrowserListing.sorted(snapshot?.entries ?? [], by: column, descending: first?.order == .reverse)
    }
    var selected: [RepositoryBrowserEntry] { entries.filter { selection.contains($0.id) } }
    var displayPath:String {"/"+(snapshot?.displayDirectory ?? "")+(snapshot?.isDirectoryRepresentable == false ? " [raw]":"")}
    var absoluteDisplayPath:String {snapshot?.isDirectoryRepresentable == false ? "Raw Git path (escaped): /"+snapshot!.displayDirectory : repository.root.path+(snapshot?.directory.isEmpty == false ? "/"+snapshot!.displayDirectory:"")}
    var info: String {
        if selected.count > 1 { return "\(selected.count) items selected" }
        if let entry = selected.first {
            if entry.kind == .directory { return entry.name }
            if entry.kind == .submodule { return "Submodule \(entry.name)\nRevision \(entry.objectID)" }
            return entry.name + "\nSize " + sizeText(entry)
        }
        let values = snapshot?.entries ?? []
        let name=snapshot?.directory.isEmpty == false ? (try? RepositoryBrowserGitPath(key:snapshot!.directory).lastComponentDisplay) ?? "" : repository.root.lastPathComponent
        return "\(name): Showing \(values.filter { ![.directory, .submodule].contains($0.kind) }.count) files, \(values.filter { $0.kind == .submodule }.count) submodules and \(values.filter { $0.kind == .directory }.count) folders, \(values.count) items in total"
    }
    func sizeText(_ entry: RepositoryBrowserEntry) -> String { entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "" }
    func invalidate() { active = false; generation = UUID(); cancelRequests() }
    func canReuseForRevision(_ requestedRevision: String) -> Bool {
        canUseMenu && GitReferenceName.equal(revision, requestedRevision) && snapshot.map { GitReferenceName.equal($0.revision, requestedRevision) && $0.directory.isEmpty } == true
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    /// One-shot file context supplied by Blame or another historical file view.
    var initialFile: String?
    func refresh() {
        guard active,!mutating,!confirmingQuit,!confirmingColumns,!choosingRevision,!handlingFile else { return }
        cancelRequests()
        let identity = UUID(); generation = identity; busy = true; error = nil; loads = []
        transferInventory=nil;transferInventoryError=nil;transferInventoryBusy=false
        transferDirectories=[:];transferDirectoryErrors=[:];transferDirectoryLoads=[]
        let requestedFile = initialFile
        let components = requestedFile?.split(separator: "/", omittingEmptySubsequences: false)
        let seed = requestedFile.flatMap { value -> String? in
            guard !value.isEmpty, !value.contains("\0"), components?.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) == true else { return nil }
            return value
        }
        if requestedFile != nil && seed == nil { initialFile = nil }
        let value = revision, directory = seed.map { parentPath($0) } ?? snapshot?.directory ?? "", retainedSelection = selection
        var wanted = expanded
        var parent = directory
        while !parent.isEmpty { wanted.insert(parent); parent = parentPath(parent) }
        wanted.insert("")
        let ordered = wanted.sorted { lhs, rhs in
            let a=pathDepth(lhs), b=pathDepth(rhs)
            return a == b ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8) : a < b
        }
        let (request, cancellation) = startRequest()
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        Task { [self, repository, access] in
            defer { finishRequest(request); if active && generation == identity { busy = false }; withExtendedLifetime(access) {} }
            do {
                try validateAccess()
                let root = try await repository.browseRepository(revision:value, cancellation:cancellation)
                var label=value,labelError:String?
                do {label=try await repository.repositoryBrowserRevisionLabel(root,cancellation:cancellation)}
                catch {if cancellation.isCancelled {throw OperationCancellationFailure.cancelled};labelError=error.localizedDescription}
                var restored:RepositoryBrowserPathMap<RepositoryBrowserSnapshot> = ["":root]
                if root.treeID != nil {
                    for path in ordered where !path.isEmpty {
                        if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                        let ancestor = parentPath(path)
                        guard let listing = restored[ancestor], listing.entries.contains(where: { RepositoryBrowserPathIdentity.equal($0.path,path) && $0.kind == .directory }) else { continue }
                        do { restored[path] = try await repository.browseRepositoryDirectory(root,directory:path,cancellation:cancellation) }
                        catch { if cancellation.isCancelled { throw OperationCancellationFailure.cancelled } /* A removed directory falls back to its surviving ancestor. */ }
                    }
                }
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                guard active, generation == identity else { return }
                var currentPath = directory
                while restored[currentPath] == nil && !currentPath.isEmpty { currentPath = parentPath(currentPath) }
                let current = restored[currentPath] ?? root
                directories = restored.mapValues(\.entries); listings = restored; requestedDirectory = current.directory
                snapshot = current;revisionLabel=label;error=labelError; expanded = wanted.intersection(restored.keys); expanded.insert("")
                prepareTransferInventory(root,identity:identity)
                if let seed {
                    selection = Set(current.entries.filter { RepositoryBrowserPathIdentity.equal($0.path, seed) }.map(\.id))
                    if let pending = initialFile, RepositoryBrowserPathIdentity.equal(pending, seed) { initialFile = nil }
                }
                else { selection = retainedSelection.intersection(Set(current.entries.map(\.id))) }
            } catch { if active && generation == identity && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func prepareTransferInventory(_ snapshot:RepositoryBrowserSnapshot,identity:UUID) {
        guard snapshot.treeID != nil else{return}
        transferInventoryBusy=true
        let (request,cancellation)=startRequest()
        Task { [self,repository,access] in
            defer{finishRequest(request);if active,generation==identity{transferInventoryBusy=false};withExtendedLifetime(access){}}
            do {
                try validateAccess()
                let entries=try await repository.repositoryBrowserTransferInventory(snapshot,cancellation:cancellation)
                guard active,generation==identity,!cancellation.isCancelled else{return}
                transferInventory=entries
            } catch {
                guard active,generation==identity,!cancellation.isCancelled else{return}
                transferInventoryError=error.localizedDescription
            }
        }
    }
    func captureTransfer(_ orderedIDs:[String])->RepositoryBrowserSelectionDrag? {
        guard canUseMenu,let snapshot,!orderedIDs.isEmpty,Set(orderedIDs).count==orderedIDs.count,
              orderedIDs.allSatisfy({selection.contains($0)}) else{return nil}
        let selected=orderedIDs.compactMap{id in snapshot.entries.first{$0.id==id}}
        guard selected.count==orderedIDs.count else{return nil}
        return makeTransfer(snapshot,selected:selected)
    }
    func captureTreeTransfer(_ path:String)->RepositoryBrowserSelectionDrag? {
        guard canUseMenu,folderObjectID(path) != nil,let root=listings[""] else{return nil}
        if path.isEmpty {return makeTransfer(root,selected:root.entries.sorted{$0.name.utf16.lexicographicallyPrecedes($1.name.utf16)})}
        let parent=parentPath(path)
        guard let entry=directories[parent]?.first(where:{RepositoryBrowserPathIdentity.equal($0.path,path) && $0.kind == .directory}) else{return nil}
        return makeTransfer(root,selected:[entry])
    }
    private func makeTransfer(_ snapshot:RepositoryBrowserSnapshot,selected:[RepositoryBrowserEntry])->RepositoryBrowserSelectionDrag? {
        guard active,canUseMenu,!selected.isEmpty else{return nil}
        guard selected.allSatisfy({requireRepresentable($0.path)}) else{return nil}
        do {try validateAccess()} catch {self.error=error.localizedDescription;return nil}
        var inventory=transferInventory
        if inventory==nil {
            var collected:[RepositoryBrowserEntry]=[],missing=false
            for entry in selected where entry.kind == .directory {
                if let entries=transferDirectories[entry.path] {collected += entries}
                else {
                    missing=true
                    if let failure=transferDirectoryErrors[entry.path]{error=failure}
                    else if !transferInventoryBusy {
                        prepareTransferDirectory(snapshot,directory:entry.path)
                        error="The repository transfer inventory is still loading."
                    } else {error="The repository transfer inventory is still loading."}
                }
            }
            if missing{return nil}
            if !collected.isEmpty{inventory=collected}
        }
        guard (inventory?.count ?? 0)<=100_000 else{error=RepositoryBrowserFailure.transferLimit.localizedDescription;return nil}
        do {try RepositoryBrowserTransferPolicy.validateSelection(snapshot,selected:selected,inventory:inventory)}
        catch {self.error=error.localizedDescription;return nil}
        let transfer=RepositoryBrowserSelectionDrag(repository:repository,access:access,snapshot:snapshot,selected:selected,inventory:inventory,backend:materializationBackend())
        if transfer==nil {error=RepositoryBrowserFailure.transferLimit.localizedDescription}
        return transfer
    }
    private func prepareTransferDirectory(_ snapshot:RepositoryBrowserSnapshot,directory:String) {
        guard !transferDirectoryLoads.contains(directory) else{return}
        transferDirectoryLoads.insert(directory)
        let identity=generation,(request,cancellation)=startRequest()
        Task { [self,repository,access] in
            defer{finishRequest(request);if active,generation==identity{transferDirectoryLoads.remove(directory)};withExtendedLifetime(access){}}
            do {
                try validateAccess()
                let entries=try await repository.repositoryBrowserTransferInventory(snapshot,directory:directory,cancellation:cancellation)
                guard active,generation==identity,!cancellation.isCancelled else{return}
                transferDirectories[directory]=entries
            } catch {
                guard active,generation==identity,!cancellation.isCancelled else{return}
                transferDirectoryErrors[directory]=error.localizedDescription
            }
        }
    }

    func loadDirectory(_ path: String, select: Bool) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns,!choosingRevision,!handlingFile, let snapshot, snapshot.treeID != nil else { return }
        let identity = generation
        if select { menuGeneration = UUID(); requestedDirectory = path }
        if let cached = listings[path] {
            if select { self.snapshot = cached; selection = [] }
            return
        }
        guard !loads.contains(path) else { return }; loads.insert(path)
        let (request, cancellation) = startRequest()
        Task { [self, repository, access] in
            defer { finishRequest(request); if active && generation == identity { loads.remove(path) }; withExtendedLifetime(access) {} }
            do {
                try validateAccess()
                let result = try await repository.browseRepositoryDirectory(snapshot,directory:path,cancellation:cancellation)
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                guard active, generation == identity else { return }
                directories[path] = result.entries; listings[path] = result
                if RepositoryBrowserPathIdentity.equal(requestedDirectory,path) { self.snapshot = result; selection = [] }
            } catch { if active && generation == identity && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func open(_ entry: RepositoryBrowserEntry, action: FileAction = .open) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns,!choosingRevision,!handlingFile, let snapshot, snapshot.entries.contains(entry) else { return }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        if entry.kind == .directory { expanded.insert(entry.path); loadDirectory(entry.path,select:true); return }
        if entry.kind == .submodule, !requireRepresentable(entry.path) {return}
        if entry.kind == .submodule && action == .open && !snapshot.bare { loadSubmodule(snapshot,entry:entry,showLog:false); return }
        if let openRequest { requests[openRequest]?.cancel() }
        let (request,cancellation) = startRequest(), identity = generation,backend=materializationBackend()
        openRequest = request;materializationEditorSettings = .load(from:preferences)
        Task { [self, repository, access] in
            defer { finishRequest(request); withExtendedLifetime(access) {} }
            do {
                try validateAccess()
                let content = try await repository.materializedRepositoryBrowserFile(snapshot,entry:entry,cancellation:cancellation,backend:backend)
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                guard active, generation == identity, openRequest == request else { return }
                presentFile(content,action)
            } catch { if active && generation == identity && openRequest == request && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    static let maximumStoredBlobBytes:Int64=8*1024*1024
    /// Object delivery needs no native representation of the original name.
    /// Keep its captured row/tree identity through the read, then hand off to
    /// the same owned panels, cancellation and preview lifecycle as normal Open.
    func openStoredBlob(_ entry:RepositoryBrowserEntry,action:FileAction = .open) {
        guard canUseMenu,let snapshot,snapshot.objectID != nil,snapshot.entries.contains(entry),![.directory,.submodule].contains(entry.kind) else{return}
        let identity=generation,navigation=menuGeneration,(request,cancellation)=startRequest(),read=readStoredFile
        let repository=self.repository.capturingBackend(snapshot.acceptedBackend ?? materializationBackend())
        materializationEditorSettings = .load(from:preferences)
        busy=true
        Task { [self,repository,access] in
            defer{finishRequest(request);if active,generation==identity{busy=false};withExtendedLifetime(access){}}
            do {
                try validateAccess()
                let content:ComparisonFileContent
                if let read {content=try await read(snapshot,entry,cancellation)}
                else {content=try await repository.storedRepositoryBrowserFile(snapshot,entry:entry,cancellation:cancellation)}
                guard active,generation==identity,menuGeneration==navigation,!confirmingQuit,!cancellation.isCancelled else{return}
                busy=false;presentFile(content,action)
            } catch {if active,generation==identity,!cancellation.isCancelled{self.error=error.localizedDescription}}
        }
    }
    func inspectStoredBlob(_ entry:RepositoryBrowserEntry) {
        guard canUseMenu,let snapshot,snapshot.entries.contains(entry),![.directory,.submodule].contains(entry.kind) else{return}
        guard let size=entry.size,size<=Self.maximumStoredBlobBytes else{error="Stored blob inspection is limited to 8 MiB. This object is too large to display.";return}
        let identity=generation,navigation=menuGeneration,(request,cancellation)=startRequest(),read=readStoredBlob
        let repository=self.repository.capturingBackend(snapshot.acceptedBackend ?? materializationBackend())
        busy=true
        Task { [self,repository,access] in
            defer{finishRequest(request);if active,generation==identity{busy=false};withExtendedLifetime(access){}}
            do {
                try validateAccess()
                let bytes:Data
                if let read{bytes=try await read(snapshot,entry,cancellation)}
                else{bytes=try await repository.storedRepositoryBrowserBlob(snapshot,entry:entry,cancellation:cancellation)}
                guard bytes.count<=Self.maximumStoredBlobBytes else{throw CocoaError(.fileReadTooLarge)}
                guard active,generation==identity,menuGeneration==navigation,!confirmingQuit,!cancellation.isCancelled else{return}
                // Clear this read's busy state before the controller's live-menu gate.
                busy=false;presentStoredBlob(bytes,entry)
            } catch {if active,generation==identity,!cancellation.isCancelled{self.error=error.localizedDescription}}
        }
    }
    func dragProvider(_ entry: RepositoryBrowserEntry? = nil, directory: String? = nil) -> NSItemProvider? {
        guard active, !busy, !confirmingQuit, !confirmingColumns,!choosingRevision,!handlingFile, let snapshot, snapshot.objectID != nil,
              entry.map({ snapshot.entries.contains($0) && $0.kind != .submodule }) ?? true else { return nil }
        guard requireRepresentable(entry?.path ?? directory ?? snapshot.directory) else{return nil}
        do { try validateAccess() } catch { self.error = error.localizedDescription; return nil }
        let folder = directory != nil || entry == nil || entry?.kind == .directory
        let name = entry?.name ?? (directory.map { $0.isEmpty ? repository.root.lastPathComponent : (try? RepositoryBrowserGitPath(key:$0).lastComponentDisplay) ?? "" } ?? repository.root.lastPathComponent)
        return RepositoryBrowserDrag.provider(repository: repository, access: access, snapshot: snapshot, entry: entry, directory: directory, name: name, folder: folder,backend:materializationBackend())
    }
    func showSubmoduleLog(_ entry: RepositoryBrowserEntry) {
        guard active, !busy, !confirmingQuit, !confirmingColumns,!choosingRevision,!handlingFile, let snapshot, snapshot.entries.contains(entry), entry.kind == .submodule else { return }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        guard !snapshot.bare else { error = "This bare repository has no child working checkout. Open an initialized working repository to show submodule history."; return }
        guard requireRepresentable(entry.path) else{return}
        loadSubmodule(snapshot,entry:entry,showLog:true)
    }
    private func loadSubmodule(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry, showLog: Bool) {
        let repository=self.repository.capturingBackend(snapshot.acceptedBackend ?? materializationBackend())
        let (request,cancellation) = startRequest(), identity = generation
        busy = true
        Task { [self,repository,access] in
            defer { finishRequest(request); if active && generation == identity { busy = false }; withExtendedLifetime(access) {} }
            do {
                let module = try await repository.repositoryBrowserSubmodule(snapshot,entry:entry,cancellation:cancellation)
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                guard active, generation == identity else { return }
                acceptedNavigationRepository=repository
                onSubmodule(module,entry,showLog)
            } catch { if active && generation == identity && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func revert(_ entries: [RepositoryBrowserEntry]) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns,!choosingRevision,!handlingFile, let snapshot, !snapshot.bare, !entries.isEmpty,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ snapshot.entries.contains($0) && ![.directory,.submodule].contains($0.kind) }) else { return }
        guard entries.allSatisfy({requireRepresentable($0.path)}) else{return}
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        cancelRequests()
        let (request,cancellation) = startRequest(), identity = generation
        busy = true; mutating = true
        Task { [self, repository, access] in
            defer { finishRequest(request); mutating = false; busy = false; withExtendedLifetime(access) {} }
            var restored = 0, failed = 0, attempted = 0
            for entry in entries {
                guard active, generation == identity, !cancellation.isCancelled else { break }
                attempted += 1
                do {
                    try validateAccess()
                    try await repository.revertRepositoryBrowserFile(snapshot,entry:entry,cancellation:cancellation)
                    restored += 1
                } catch {
                    guard active, generation == identity, !cancellation.isCancelled else { break }
                    failed += 1
                    let proceed = await handleRevertFailure(entry.displayPath + "\n\n" + error.localizedDescription)
                    guard active, generation == identity, !cancellation.isCancelled, proceed else { break }
                }
            }
            guard active, generation == identity, !cancellation.isCancelled else { return }
            onChanged()
            showRevertResult("\(restored) file(s) reverted to \(snapshot.revision)." + (failed == 0 ? "" : "\n\(failed) file(s) failed. \(entries.count - attempted) file(s) were not attempted."))
        }
    }
    func importWorkingComparisonMark(_ access: WorkingComparisonAccess?) {
        guard active else{return}
        guard let access else{
            if comparisonMark?.workingAccess?.mark.id==lastImportedWorkingMark,comparisonMark?.workingAccess != nil{comparisonMark=nil}
            lastImportedWorkingMark=nil
            return
        }
        guard access.mark.id != lastImportedWorkingMark else{return}
        lastImportedWorkingMark = access.mark.id
        comparisonMark = PreparedFileComparisonMark(path: access.file.path, revision: "", workingAccess: access)
    }
    func prepareComparisonMenu(){if let currentWorkingComparisonMark{importWorkingComparisonMark(currentWorkingComparisonMark())}}
    func markForComparison(_ entry: RepositoryBrowserEntry) {
        guard active, !busy, !confirmingQuit, !confirmingColumns,!choosingRevision,!handlingFile, let snapshot, let revision = snapshot.objectID,
              snapshot.entries.contains(entry), ![.directory, .submodule].contains(entry.kind) else { return }
        resolveNavigationRevision(revision) { [weak self] resolved in
            self?.comparisonMark = PreparedFileComparisonMark(path:entry.path,revision:resolved)
        }
    }
    func compareWithMarkedFile(_ entry: RepositoryBrowserEntry, capturedMark: PreparedFileComparisonMark? = nil) {
        guard active, !busy, !confirmingQuit, !confirmingColumns,!choosingRevision,!handlingFile, let snapshot, let revision = snapshot.objectID, let comparisonMark = capturedMark ?? comparisonMark,
              snapshot.entries.contains(entry), ![.directory, .submodule].contains(entry.kind) else { return }
        let markIdentity=comparisonMarkRevision
        if comparisonMark.workingAccess != nil || comparisonMark.revision.isEmpty {
            guard requireRepresentable(entry.path) else{return}
        }
        resolveNavigationRevision(revision) { [weak self] resolved in
            guard let self,self.comparisonMarkRevision==markIdentity else{return}
            self.onPreparedFileCompare?(comparisonMark,PreparedFileComparisonMark(path:entry.path,revision:resolved))
        }
    }
    /// Resolve the immutable displayed object, never a branch that may have moved
    /// since ReadTree. Later commands use the owning dialog's accepted master policy.
    private func resolveNavigationRevision(_ revision:String,completion:@escaping(String)->Void) {
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        let identity=generation,navigation=menuGeneration
        let (request,cancellation)=startRequest();busy=true
        Task { [self,repository,access] in
            defer{finishRequest(request);if active,generation==identity{busy=false};withExtendedLifetime(access){}}
            do {
                try validateAccess()
                let resolved=try await repository.repositoryBrowserRevision(revision,cancellation:cancellation)
                guard let object=resolved.objectID else{throw RepositoryBrowserFailure.revision}
                guard active,generation==identity,menuGeneration==navigation,!confirmingQuit,!cancellation.isCancelled else{return}
                acceptedNavigationRepository=repository;completion(object)
            }catch{if active,generation==identity,!cancellation.isCancelled{self.error=error.localizedDescription}}
        }
    }
    struct MenuTarget {
        let owner: ObjectIdentifier
        let generation: UUID
        let navigation: UUID
        let revision: String
        let directory: String
        let entries: [RepositoryBrowserEntry]
        let comparisonMark: PreparedFileComparisonMark?
        let comparisonMarkRevision:UUID
    }
    func menuTarget(_ entries: [RepositoryBrowserEntry] = []) -> MenuTarget? {
        guard canUseMenu, let snapshot, let revision = snapshot.objectID,
              entries.allSatisfy({ snapshot.entries.contains($0) }) else { return nil }
        return MenuTarget(owner:ObjectIdentifier(self),generation:generation,navigation:menuGeneration,revision:revision,directory:snapshot.directory,entries:entries,comparisonMark:comparisonMark,comparisonMarkRevision:comparisonMarkRevision)
    }
    func acceptsComparisonMark(_ target:MenuTarget)->Bool{acceptsMenu(target) && target.comparisonMarkRevision==comparisonMarkRevision}
    func acceptsMenu(_ target: MenuTarget) -> Bool {
        canUseMenu && target.owner == ObjectIdentifier(self) && target.generation == generation && target.navigation == menuGeneration &&
        target.revision == snapshot?.objectID && snapshot.map { RepositoryBrowserPathIdentity.equal(target.directory,$0.directory) } == true &&
        target.entries.allSatisfy { snapshot?.entries.contains($0) == true }
    }
    var canUseMenu: Bool { active && !busy && !mutating && !confirmingQuit && !confirmingColumns && !choosingRevision && !handlingFile }
    func folderObjectID(_ path: String) -> String? {
        guard canUseMenu, let snapshot, snapshot.objectID != nil else { return nil }
        if path.isEmpty { return snapshot.treeID }
        let parent = parentPath(path)
        return directories[parent == "." ? "" : parent]?.first { RepositoryBrowserPathIdentity.equal($0.path,path) && $0.kind == .directory }?.objectID
    }
    func openFolder(_ path: String) {
        guard folderObjectID(path) != nil else { return }
        expanded.insert(path); loadDirectory(path,select:true)
    }
    func folderPromise(_ path: String) -> NSFilePromiseProvider? {
        guard folderObjectID(path) != nil, let snapshot,requireRepresentable(path) else { return nil }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return nil }
        return RepositoryBrowserFilePromise(repository:repository,access:access,snapshot:snapshot,directory:path,backend:materializationBackend()).provider()
    }
    func showFolderLog(_ path: String) {
        guard folderObjectID(path) != nil, let revision = snapshot?.objectID else { return }
        guard snapshot?.treeID != revision else { error = "Tree objects contain file snapshots, but have no commit history or blame information. Choose a commit or tag to view history."; return }
        onLog(path,revision)
    }
    func copyFolder(_ path: String, hashes: Bool = false, pasteboard:NSPasteboard? = nil) {
        guard let hash = folderObjectID(path) else { return }
        let name = path.isEmpty ? repository.root.lastPathComponent : (try? RepositoryBrowserGitPath(key:path).lastComponentDisplay) ?? ""
        let pasteboard=pasteboard ?? clipboard
        pasteboard.clearContents(); pasteboard.setString(hashes ? hash : name + "\r\n",forType:.string)
    }
    func showEntryLog(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, snapshot.entries.contains(entry), let revision = snapshot.objectID else { return }
        guard snapshot.treeID != revision else { error = "Tree objects contain file snapshots, but have no commit history or blame information. Choose a commit or tag to view history."; return }
        onLog(entry.path,revision)
    }
    func showEntryBlame(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, !snapshot.bare, snapshot.entries.contains(entry),
              ![.directory,.submodule].contains(entry.kind), let revision = snapshot.objectID else { return }
        guard snapshot.treeID != revision else { error = "Tree objects contain file snapshots, but have no commit history or blame information. Choose a commit or tag to view history."; return }
        onBlame(entry.path,revision)
    }
    func compareEntryToWorkingTree(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, !snapshot.bare, snapshot.entries.contains(entry),
              entry.kind != .directory, let revision = snapshot.objectID else { return }
        guard requireRepresentable(entry.path) else{return}
        let identity=generation,navigation=menuGeneration,callback=onCompare
        let repository=self.repository.capturingDiffBackend(preferences:preferences)
        let (request,cancellation)=startRequest();busy=true
        Task { [self,repository,access] in
            defer {finishRequest(request);if active,generation==identity {busy=false};withExtendedLifetime(access){}}
            do {
                try validateAccess()
                try await repository.validateRepositoryBrowserWorkingPath(snapshot,entry:entry,cancellation:cancellation)
                guard active,generation==identity,menuGeneration==navigation,!cancellation.isCancelled else {return}
                _ = try await repository.repositoryBrowserRevision(revision,cancellation:cancellation)
                guard active,generation==identity,menuGeneration==navigation,!confirmingQuit,!cancellation.isCancelled else{return}
                acceptedNavigationRepository=repository
                callback(entry.path,revision)
            } catch {if active,generation==identity,!cancellation.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func copy(hashes: Bool = false, pasteboard:NSPasteboard? = nil, entries: [RepositoryBrowserEntry]? = nil) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns,!choosingRevision,!handlingFile else { return }
        let values = entries ?? selected
        guard let snapshot, !values.isEmpty, values.allSatisfy({ snapshot.entries.contains($0) }) else { return }
        let pasteboard=pasteboard ?? clipboard
        pasteboard.clearContents()
        pasteboard.setString(hashes ? values.map(\.objectID).joined(separator:"\r\n") : values.map { $0.name + "\r\n" }.joined(), forType: .string)
    }
}

/// Source IDC_REPOBROWSER_URL is a selectable, read-only edit, not a label.
struct RepositoryBrowserPathField:NSViewRepresentable {
    @ObservedObject var model:RepositoryBrowserWindowModel
    func makeNSView(context:Context)->NSTextField {
        let field=NSTextField();field.isEditable=false;field.isSelectable=true;field.isBezeled=false;field.drawsBackground=false
        field.font = .systemFont(ofSize:NSFont.systemFontSize);field.lineBreakMode = .byTruncatingMiddle;field.cell?.usesSingleLineMode=true;field.cell?.isScrollable=true
        field.setAccessibilityLabel("Repository path");field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return field
    }
    func updateNSView(_ field:NSTextField,context:Context) {
        if field.stringValue != model.displayPath {
            if field.currentEditor() != nil {field.window?.makeFirstResponder(nil)}
            field.stringValue=model.displayPath
        }
        field.toolTip=model.absoluteDisplayPath+((model.snapshot?.objectID).map {"\n"+$0} ?? "")
        field.isSelectable=model.active && !model.handlingFile
    }
    static func dismantleNSView(_ field:NSTextField,coordinator:()) {field.isSelectable=false}
}

private struct RepositoryBrowserDialog: View {
    @ObservedObject var model: RepositoryBrowserWindowModel
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Path:")
                RepositoryBrowserPathField(model:model).frame(minWidth:100,maxWidth:.infinity).frame(height:22)
                Spacer()
                Text("Revision:")
                Button(model.revisionLabel) { model.chooseRevision() }.lineLimit(1).frame(minWidth:180,maxWidth:300).help(model.revisionLabel + ((model.snapshot?.objectID).map { "\n" + $0 } ?? "")).disabled(!model.canUseMenu)
            }
            RepositoryBrowserSplit(model:model) {
                RepositoryBrowserFolderTree(model:model)
            } right: {
                RepositoryBrowserContentsTable(model:model)
            }.border(Color.secondary.opacity(0.4))
            HStack {
                Text(model.info).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                if model.busy || model.handlingFile { ProgressView().controlSize(.small) }
                Button("OK", action: model.close).keyboardShortcut(.defaultAction).disabled(model.mutating)
                Button("Cancel", action: model.close).keyboardShortcut(.cancelAction).disabled(model.mutating)
                Button("Help") { TurtleGitHelp.show(.browser) }
            }
        }.padding(12).disabled(model.confirmingQuit || model.choosingRevision).alert("Repository Browser", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func browserIcon(_ entry: RepositoryBrowserEntry) -> NSImage {
        if [.directory, .submodule].contains(entry.kind) { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
    }
    private func overlay(_ entry: RepositoryBrowserEntry) -> MenuIcon? {
        switch entry.kind { case .executable: return .executableOverlay; case .symlink: return .symlinkOverlay; case .submodule: return .externalOverlay; default: return nil }
    }
}
private struct RepositoryBrowserSplit<Left: View, Right: View>: NSViewControllerRepresentable {
    let model:RepositoryBrowserWindowModel
    let left:Left
    let right:Right
    init(model:RepositoryBrowserWindowModel,@ViewBuilder left:()->Left,@ViewBuilder right:()->Right) {self.model = model;self.left = left();self.right = right()}
    func makeNSViewController(context:Context) -> RepositoryBrowserSplitController {
        let controller = RepositoryBrowserSplitController(model:model)
        controller.splitView.isVertical = true;controller.splitView.dividerStyle = .thin
        let folders = NSSplitViewItem(viewController:NSHostingController(rootView:left))
        folders.minimumThickness = 160;folders.preferredThicknessFraction = 0.28
        let contents = NSSplitViewItem(viewController:NSHostingController(rootView:right));contents.minimumThickness = 300
        controller.addSplitViewItem(folders);controller.addSplitViewItem(contents);controller.observeDivider()
        return controller
    }
    func updateNSViewController(_ controller:RepositoryBrowserSplitController,context:Context) {
        (controller.splitViewItems[0].viewController as? NSHostingController<Left>)?.rootView = left
        (controller.splitViewItems[1].viewController as? NSHostingController<Right>)?.rootView = right
    }
    static func dismantleNSViewController(_ controller:RepositoryBrowserSplitController,coordinator:()) {controller.retire()}
}
private final class RepositoryBrowserSplitController:NSSplitViewController {
    private weak var model:RepositoryBrowserWindowModel?
    private var observer:NSObjectProtocol?
    private var restored = false,restoring = false,retired = false,restoreScheduled = false
    init(model:RepositoryBrowserWindowModel) {
        self.model = model;super.init(nibName:nil,bundle:nil)
        let split = RepositoryBrowserLayoutSplitView()
        split.afterLayout = { [weak self] in self?.scheduleRestore() }
        split.interactionAllowed = { [weak model] in model?.canUseMenu == true }
        splitView = split
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
    func observeDivider() {
        observer = NotificationCenter.default.addObserver(forName:NSSplitView.didResizeSubviewsNotification,object:splitView,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.saveDivider()}
        }
    }
    override func viewDidLayout() {super.viewDidLayout();scheduleRestore()}
    private func scheduleRestore() {
        guard !retired,!restored,!restoreScheduled,splitView.window != nil,splitView.bounds.width >= 461,splitView.arrangedSubviews.count == 2 else {return}
        restoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {return};defer {self.restoreScheduled = false}
            guard !self.retired,!self.restored,self.splitView.window != nil,self.splitView.bounds.width >= 461 else {return}
            self.restoring = true
            if let width = self.model?.dividerWidth {
                let position:CGFloat = min(max(CGFloat(160),CGFloat(width)),self.splitView.bounds.width - CGFloat(301))
                self.splitView.setPosition(position,ofDividerAt:0)
            }
            self.restoring = false;self.restored = true;self.saveDivider()
        }
    }
    private func saveDivider() {
        guard !retired,restored,!restoring,splitView.window?.attachedSheet == nil,let first = splitView.arrangedSubviews.first else {return}
        model?.saveDivider(first.frame.width)
    }
    func retire() {retired = true;if let observer {NotificationCenter.default.removeObserver(observer)};observer = nil}
    deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
}

private final class RepositoryBrowserLayoutSplitView:NSSplitView {
    var afterLayout:()->Void = {}
    var interactionAllowed:()->Bool = {true}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();afterLayout()}
    override func layout() {super.layout();afterLayout()}
    override func resizeSubviews(withOldSize oldSize:NSSize) {super.resizeSubviews(withOldSize:oldSize);afterLayout()}
    override func mouseDown(with event:NSEvent) {if interactionAllowed(),window?.attachedSheet == nil {super.mouseDown(with:event)}}
}

/// Native historical folder navigation. Items keep identity across lazy loads;
/// every action still validates the pinned browser generation and permission.
@MainActor struct RepositoryBrowserFolderTree: NSViewRepresentable {
    @ObservedObject var model: RepositoryBrowserWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeView() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update() }
    static func dismantleNSView(_ view:NSScrollView, coordinator:Coordinator) { coordinator.retired=true;if coordinator.dragSession == nil{coordinator.activeTransfer=nil;coordinator.outline?.delegate=nil;coordinator.outline?.dataSource=nil} }

    @MainActor final class Node: NSObject {
        let path:String
        init(_ path:String) { self.path=path }
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let model:RepositoryBrowserWindowModel
        weak var outline:RepositoryBrowserFolderOutline?
        private var nodes:RepositoryBrowserPathMap<Node>=["":Node("")]
        private var children:RepositoryBrowserPathMap<[RepositoryBrowserEntry]>=[:]
        private var generation:UUID?
        private var updating=false
        var retired=false
        var activeTransfer:RepositoryBrowserSelectionDrag?
        private(set) var dragSession:NSDraggingSession?
        private static var dragOwners:[ObjectIdentifier:Coordinator]=[:]
        func captureDrag(_ path:String)->RepositoryBrowserSelectionDrag? {
            guard available,NSApp.modalWindow==nil else{return nil};return model.captureTreeTransfer(path)
        }
        var available:Bool { !retired && model.canUseMenu && outline?.window?.attachedSheet==nil }
        init(_ model:RepositoryBrowserWindowModel) { self.model=model }
        func node(_ path:String) -> Node { if let value=nodes[path] { return value };let value=Node(path);nodes[path]=value;return value }
        func folders(_ path:String) -> [RepositoryBrowserEntry] { RepositoryBrowserListing.sorted(children[path] ?? []).filter { $0.kind == .directory } }
        func makeView() -> NSScrollView {
            let scroll=NSScrollView(),tree=RepositoryBrowserFolderOutline()
            tree.dragContext={ [weak model] in model?.transferContext(tree:true) }
            scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true
            let column=NSTableColumn(identifier:.init("folder"));column.title="Folders";column.width=250;column.minWidth=100
            tree.addTableColumn(column);tree.outlineTableColumn=column;tree.headerView=nil
            tree.rowHeight=23;tree.indentationPerLevel=16;tree.intercellSpacing=NSSize(width:2,height:2)
            tree.allowsMultipleSelection=false;tree.allowsEmptySelection=false;tree.allowsTypeSelect=true;tree.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            tree.setAccessibilityLabel("Repository folders");tree.dataSource=self;tree.delegate=self
            tree.target=self;tree.doubleAction=#selector(openSelected)
            tree.openSelection={ [weak self] in self?.openSelected() }
            tree.copySelection={ [weak self] in self?.copySelected() }
            tree.contextSelection={ [weak self] row in self?.selectContext(row) }
            let menu=NSMenu();menu.delegate=self;menu.autoenablesItems=false;tree.menu=menu
            tree.setDraggingSourceOperationMask(.copy,forLocal:false);tree.setDraggingSourceOperationMask(.copy,forLocal:true)
            scroll.documentView=tree;outline=tree;update();return scroll
        }
        func update() {
            guard !retired,let outline else { return };updating=true;defer { updating=false }
            if children != model.directories || generation != model.generation {
                children=model.directories;generation=model.generation
                // Retain identity only for paths belonging to the current tree.
                let paths=RepositoryBrowserPathSet([""]+children.values.flatMap { $0.filter { $0.kind == .directory }.map(\.path) })
                nodes=nodes.filter { paths.contains($0.key) };outline.reloadData()
            }
            for path in model.expanded.sorted(by:{ ((try? RepositoryBrowserGitPath(key:$0).ancestorKeys.count) ?? 0) < ((try? RepositoryBrowserGitPath(key:$1).ancestorKeys.count) ?? 0) }) {
                if path.isEmpty || model.folderObjectID(path) != nil { outline.expandItem(node(path)) }
            }
            if let path=model.snapshot?.directory {
                let row=outline.row(forItem:node(path))
                if row>=0 && outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);outline.scrollRowToVisible(row) }
            }
            // Sheets suppress actions through available, but must not leave the
            // outline disabled after dismissal without a model publication.
            outline.isEnabled = !retired && model.canUseMenu
        }
        func outlineView(_ outlineView:NSOutlineView, numberOfChildrenOfItem item:Any?) -> Int { item == nil ? 1 : (item as? Node).map { folders($0.path).count } ?? 0 }
        func outlineView(_ outlineView:NSOutlineView, child index:Int, ofItem item:Any?) -> Any {
            guard let parent=item as? Node else { return node("") };return node(folders(parent.path)[index].path)
        }
        func outlineView(_ outlineView:NSOutlineView, isItemExpandable item:Any) -> Bool {
            guard let item=item as? Node else { return false };return children[item.path] == nil || !folders(item.path).isEmpty
        }
        func outlineView(_ outlineView:NSOutlineView, viewFor tableColumn:NSTableColumn?, item:Any) -> NSView? {
            guard let node=item as? Node else { return nil }
            let cell=NSTableCellView(),label=NSTextField(labelWithString:node.path.isEmpty ? model.repository.root.lastPathComponent : (try? RepositoryBrowserGitPath(key:node.path).lastComponentDisplay) ?? "")
            let image=NSImageView(image:NSWorkspace.shared.icon(for:.folder));cell.imageView=image;cell.textField=label
            label.font = .systemFont(ofSize:12);label.lineBreakMode = .byTruncatingMiddle;label.maximumNumberOfLines=1
            cell.toolTip=node.path.isEmpty ? model.repository.root.path : RepositoryBrowserGitPath.display(key:node.path)
            if (try? RepositoryBrowserGitPath(key:node.path).isRepresentable)==false {label.stringValue += " [raw]";label.setAccessibilityLabel(label.stringValue+" – Raw Git pathname (escaped bytes)");cell.toolTip=(cell.toolTip ?? "")+"\n"+RepositoryBrowserWindowModel.rawPathReason}
            cell.addSubview(image);cell.addSubview(label);image.translatesAutoresizingMaskIntoConstraints=false;label.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:2),image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),image.widthAnchor.constraint(equalToConstant:16),image.heightAnchor.constraint(equalToConstant:16),label.leadingAnchor.constraint(equalTo:image.trailingAnchor,constant:5),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-3),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        func outlineView(_ outlineView:NSOutlineView, typeSelectStringFor tableColumn:NSTableColumn?, item:Any) -> String? {
            (item as? Node).map { $0.path.isEmpty ? model.repository.root.lastPathComponent : (try? RepositoryBrowserGitPath(key:$0.path).lastComponentDisplay) ?? "" }
        }
        func outlineView(_ outlineView:NSOutlineView, shouldExpandItem item:Any) -> Bool { updating || available }
        func outlineView(_ outlineView:NSOutlineView, shouldCollapseItem item:Any) -> Bool { updating || available }
        func outlineView(_ outlineView:NSOutlineView, shouldSelectItem item:Any) -> Bool { updating || available }
        func outlineViewItemDidExpand(_ notification:Notification) {
            guard !updating,available,let item=notification.userInfo?["NSObject"] as? Node else { return }
            model.expanded.insert(item.path);model.loadDirectory(item.path,select:false)
        }
        func outlineViewItemDidCollapse(_ notification:Notification) {
            guard !updating,available,let item=notification.userInfo?["NSObject"] as? Node else { return }
            model.expanded.remove(item.path)
        }
        func outlineViewSelectionDidChange(_ notification:Notification) {
            guard !updating,available,let outline,let item=outline.item(atRow:outline.selectedRow) as? Node else { return }
            model.loadDirectory(item.path,select:true)
        }
        @objc func openSelected() {
            guard available,let outline,let item=outline.item(atRow:outline.selectedRow) as? Node else { return }
            model.openFolder(item.path)
        }
        func copySelected() {
            guard available,let outline,let item=outline.item(atRow:outline.selectedRow) as? Node else { return };model.copyFolder(item.path)
        }
        func selectContext(_ row:Int) {
            guard available,let outline,row>=0 else { return };updating=true
            outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);updating=false
        }
        private final class Invocation:NSObject {
            let path:String,target:RepositoryBrowserWindowModel.MenuTarget,command:Int
            var used=false
            init(path:String,target:RepositoryBrowserWindowModel.MenuTarget,command:Int) { self.path=path;self.target=target;self.command=command }
        }
        func menuNeedsUpdate(_ menu:NSMenu) {
            menu.removeAllItems()
            guard available,let outline,let item=outline.item(atRow:outline.selectedRow) as? Node,model.folderObjectID(item.path) != nil,let target=model.menuTarget() else { return }
            for (index,title,icon) in [(0,"Open",MenuIcon.open),(1,"Show log",.log),(2,"Copy to clipboard",.copy),(3,"Copy hash",.copy)] {
                if index==1 || index==2 { menu.addItem(.separator()) }
                let caption=index==2 && (try? RepositoryBrowserGitPath(key:item.path).isRepresentable)==false ? "Copy displayed name (escaped)":title
                let entry=NSMenuItem(title:caption,action:#selector(invoke(_:)),keyEquivalent:"");entry.target=self
                entry.image=icon.contextImage(defaults:model.preferences);entry.representedObject=Invocation(path:item.path,target:target,command:index)
                menu.addItem(entry)
            }
        }
        @objc func invoke(_ sender:NSMenuItem) {
            guard available,let action=sender.representedObject as? Invocation,!action.used,model.acceptsMenu(action.target) else { return }
            action.used=true
            switch action.command { case 0:model.openFolder(action.path);case 1:model.showFolderLog(action.path);case 2:model.copyFolder(action.path);case 3:model.copyFolder(action.path,hashes:true);default:break }
        }
        func outlineView(_ outlineView:NSOutlineView,writeItems items:[Any],to pasteboard:NSPasteboard)->Bool {
            guard let outline=outlineView as? RepositoryBrowserFolderOutline,outline.acceptsDragGesture,items.count==1,let node=items.first as? Node,let transfer=captureDrag(node.path),transfer.write(to:pasteboard) else{return false}
            activeTransfer=transfer;return true
        }
        func outlineView(_ outlineView:NSOutlineView,draggingSession session:NSDraggingSession,willBeginAt screenPoint:NSPoint,forItems draggedItems:[Any]) {
            guard activeTransfer != nil else{return};dragSession=session;Self.dragOwners[ObjectIdentifier(session)]=self
        }
        func outlineView(_ outlineView:NSOutlineView,draggingSession session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {
            guard dragSession === session else{return}
            Self.dragOwners.removeValue(forKey:ObjectIdentifier(session));dragSession=nil;activeTransfer=nil
            if retired{outlineView.delegate=nil;outlineView.dataSource=nil}
        }
    }
}
@MainActor final class RepositoryBrowserFolderOutline:NSOutlineView {
    var dragContext:()->String?={nil}
    private var dragStart:String?
    var acceptsDragGesture:Bool{dragStart != nil && dragStart==dragContext()}
    @discardableResult func captureDragGesture(_ event:NSEvent)->Bool {
        dragStart=nil
        guard event.type == .leftMouseDown,event.window === window,isEnabled,row(at:convert(event.locationInWindow,from:nil))>=0 else{return false}
        dragStart=dragContext();return dragStart != nil
    }
    override func mouseDown(with event:NSEvent){_ = captureDragGesture(event);defer{dragStart=nil};super.mouseDown(with:event)}
    var openSelection:()->Void = {},copySelection:()->Void = {}
    var contextSelection:(Int)->Void = { _ in }
    override func keyDown(with event:NSEvent) {
        if isEnabled,[36,76].contains(event.keyCode),!event.modifierFlags.contains(.option),window?.firstResponder === self,
           let owner = window as? RepositoryBrowserNativeWindow,owner.commandKeyWindow() === owner,event.window === owner {openSelection();return}
        super.keyDown(with:event)
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if isEnabled,flags == .command || flags == .control,event.keyCode == 8,
           let owner = window as? RepositoryBrowserNativeWindow,owner.commandKeyWindow() === owner,event.window === owner,owner.firstResponder === self {copySelection();return true}
        return super.performKeyEquivalent(with:event)
    }
    override func menu(for event:NSEvent) -> NSMenu? {
        guard isEnabled else { return nil };let clicked=row(at:convert(event.locationInWindow,from:nil));guard clicked>=0 else { return nil }
        contextSelection(clicked);menu?.update();return menu
    }
}
