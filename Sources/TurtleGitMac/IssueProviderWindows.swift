// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class IssueProviderPickerController: NSWindowController, NSWindowDelegate {
    static var activeOperations:Int {IssueProviderPickerModel.activeOperations}
    let model:IssueProviderPickerModel
    private var completion:((NativeIssueProviderResult?)->Void)?
    private var closing=false
    var hasPendingWork:Bool {model.pendingOperations>0 || window?.sheetParent != nil || window?.attachedSheet != nil}
    convenience init(provider:NativeIssueProviderSession,context:NativeIssueProviderContext,completion:@escaping(NativeIssueProviderResult?)->Void){self.init(model:IssueProviderPickerModel(provider:provider,context:context),completion:completion)}
    convenience init(provider:NativeIssueCatalogProvider,context:NativeIssueProviderContext,completion:@escaping(NativeIssueProviderResult?)->Void){self.init(model:IssueProviderPickerModel(provider:provider,context:context),completion:completion)}
    private init(model:IssueProviderPickerModel,completion:@escaping(NativeIssueProviderResult?)->Void){
        self.model=model;self.completion=completion
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:420),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title=model.provider.linkText;window.isReleasedWhenClosed=false;window.contentMinSize=NSSize(width:500,height:300)
        window.contentViewController=NSHostingController(rootView:IssueProviderPickerDialog(model:model))
        super.init(window:window);window.delegate=self;window.center();DialogGeometry.attach(window,identifier:"TurtleGit.IssueProviderPicker")
        model.accepted={ [weak self] in self?.finish($0) };model.cancel={ [weak self] in self?.finish(nil) }
        if !model.loaded {model.refresh()}
    }
    func finish(_ value:NativeIssueProviderResult?){
        guard !closing,completion != nil else{return};closing=true;model.retire()
        if let window {if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};window.sheetParent?.endSheet(window);window.close()}
        // Visual Cancel is immediate; ownership and the continuation remain
        // until the actual request and native sheet have both drained.
        Task { @MainActor [self] in
            while hasPendingWork {try? await Task.sleep(nanoseconds:10_000_000)}
            let done=completion;completion=nil;done?(value)
        }
    }
    override func close(){finish(nil)}
    func windowShouldClose(_ sender:NSWindow)->Bool{finish(nil);return false}
    func windowWillClose(_ notification:Notification){finish(nil)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
}
@MainActor final class IssueProviderPickerModel:ObservableObject {
    private(set) static var activeOperations=0
    let provider:NativeIssueProviderSession
    let context:NativeIssueProviderContext
    @Published var query=""
    @Published var selected:Set<String>
    @Published private(set) var loadedIssues:[NativeIssueCatalogItem]=[]
    @Published private(set) var loaded=false
    @Published private(set) var busy=false
    @Published private(set) var submitting=false
    @Published private(set) var error:String?
    @Published private(set) var pendingOperations=0
    private var token:OperationCancellation?,worker:Task<Void,Never>?,generation=UUID(),retired=false
    private let catalog:NativeIssueCatalogProvider?
    var accepted:(NativeIssueProviderResult)->Void={_ in}
    var cancel:()->Void={}
    var accept:()->Void {get {{[weak self] in self?.submit()}}set{legacyAccept=newValue}}
    private var legacyAccept:(()->Void)?
    convenience init(provider:NativeIssueCatalogProvider,context:NativeIssueProviderContext){self.init(provider:NativeIssueProviderSession(catalog:provider),context:context,catalog:provider)}
    init(provider:NativeIssueProviderSession,context:NativeIssueProviderContext,catalog:NativeIssueCatalogProvider?=nil){self.provider=provider;self.context=context;self.catalog=catalog;selected=provider.selectedIDs(in:context.issueID);if let catalog{loadedIssues=catalog.issues;loaded=true}}
    var rows:[NativeIssueCatalogItem]{loadedIssues.filter{query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)}}
    var result:NativeIssueProviderResult? {guard let catalog else{return nil};return try? catalog.commitMessage(context:context,selected:selected)}
    var canAccept:Bool {!retired && loaded && !busy && !selected.isEmpty && selected.isSubset(of:Set(loadedIssues.map(\.id)))}
    func refresh(){
        guard !retired,!busy else{return};let receipt=UUID(),cancellation=OperationCancellation();generation=receipt;token=cancellation;busy=true;error=nil;pendingOperations += 1;Self.activeOperations += 1
        worker=Task{[self] in
            defer{pendingOperations -= 1;Self.activeOperations -= 1;if generation==receipt{busy=false;worker=nil;token=nil}}
            do{let issues=try await provider.issues(context:context,cancellation:cancellation);try cancellation.check();guard !retired,generation==receipt else{return};loadedIssues=issues;loaded=true;selected.formIntersection(Set(issues.map(\.id)))}catch{guard !retired,generation==receipt else{return};self.error=error.localizedDescription}
        }
    }
    func submit(){
        guard canAccept else{return};if let legacyAccept{legacyAccept();return}
        let chosen=selected,receipt=UUID(),cancellation=OperationCancellation();generation=receipt;token=cancellation;busy=true;submitting=true;error=nil;pendingOperations += 1;Self.activeOperations += 1
        worker=Task{[self] in
            defer{pendingOperations -= 1;Self.activeOperations -= 1;if generation==receipt{busy=false;submitting=false;worker=nil;token=nil}}
            do{let result=try await provider.commitMessage(context:context,selected:chosen,cancellation:cancellation);try cancellation.check();guard !retired,generation==receipt else{return};accepted(result)}catch{guard !retired,generation==receipt else{return};self.error=error.localizedDescription}
        }
    }
    func retire(){guard !retired else{return};retired=true;generation=UUID();token?.cancel();worker?.cancel();accepted={_ in};legacyAccept=nil;cancel={}}
}
private struct IssueProviderPickerDialog:View {
    @ObservedObject var model:IssueProviderPickerModel
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            Text(model.context.repositoryRoot.path).font(.caption).textSelection(.enabled)
            HStack{Text("Filter:");TextField("Issue ID or summary",text:$model.query);Button("Refresh"){model.refresh()}.disabled(model.busy)}
            Table(model.rows,selection:$model.selected){TableColumn("Issue ID",value:\.id).width(min:80,ideal:120);TableColumn("Summary",value:\.summary)}.disabled(model.busy)
            Text("\(model.selected.count) issue(s) selected · \(model.context.paths.count) path(s)").font(.caption).foregroundStyle(.secondary)
            if model.busy {HStack{ProgressView().controlSize(.small);Text(model.submitting ? "Preparing commit message…":"Loading issues…").font(.caption)}}
            if let error=model.error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
            HStack{Spacer();Button("Cancel"){model.cancel()}.keyboardShortcut(.cancelAction);Button("OK"){model.submit()}.keyboardShortcut(.defaultAction).disabled(!model.canAccept)}
        }.padding(16)
    }
}

@MainActor final class IssueProviderAssociationEditor: NSWindowController, NSWindowDelegate {
    let model: IssueProviderAssociationDraft
    private var completion: ((NativeIssueAssociation?) -> Void)?
    private var panel: NSOpenPanel?
    private(set) var credentialEditor:IssueProviderCredentialEditor?
    private var credentialChanges:[URL:IssueProviderCredentialDrafts.Mutation]=[:]
    var readCredential:(URL)async throws->String?={try await IssueProviderKeychainStore.shared.token(for:$0)}
    var commitCredentials:([URL:IssueProviderCredentialDrafts.Mutation])->Void={_ in}
    init(association: NativeIssueAssociation, completion: @escaping (NativeIssueAssociation?) -> Void) {
        model = IssueProviderAssociationDraft(association); self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 390), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Issue tracker integration"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 620, height: 320)
        window.contentViewController = NSHostingController(rootView: IssueProviderAssociationDialog(model: model))
        super.init(window: window); window.delegate = self; window.center(); DialogGeometry.attach(window, identifier: "SetBugTraqAdvDlg")
        model.accept = { [weak self] in guard let self, self.completion != nil else { return }; do { try NativeIssueAssociations.validate(self.model.row); self.finish(self.model.row) } catch { self.model.error = error.localizedDescription } }
        model.cancel = { [weak self] in self?.finish(nil) }; model.browse = { [weak self] in self?.browse() };model.credentials={ [weak self] in self?.editCredentials() }
    }
    func editCredentials(){
        guard credentialEditor==nil,panel==nil,!model.options,let window,window.attachedSheet==nil else{return}
        do {
            let provider=try NativeIssueProviderSession(identifier:model.row.provider,parameters:model.row.parameters)
            guard let endpoint=provider.endpoint else{return}
            let previous=credentialChanges[endpoint],read=readCredential
            let child=IssueProviderCredentialEditor(endpoint:endpoint,read:{if let previous{return previous.value};return try await read(endpoint)}){ [weak self] value in
                guard let self else{return};self.credentialEditor=nil;self.model.choosing=false
                if let value{self.credentialChanges[endpoint]=value}
            }
            credentialEditor=child;model.choosing=true
            child.window?.alphaValue=window.alphaValue;child.window?.appearance=window.appearance
            if let sheet=child.window{window.beginSheet(sheet)}else{child.close()}
        }catch{model.error=error.localizedDescription}
    }
    private func browse() {
        guard panel == nil, let window, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.canChooseFiles = false; chooser.canChooseDirectories = true; chooser.directoryURL = URL(fileURLWithPath: model.row.path); chooser.prompt = "Choose working tree"; panel = chooser; model.choosing = true
        chooser.beginSheetModal(for: window) { [weak self] response in guard let self, self.panel === chooser else { return }; self.panel = nil; self.model.choosing = false; if response == .OK, let url = chooser.url { self.model.row.path = url.path } }
    }
    func finish(_ row:NativeIssueAssociation?){
        guard let completion else{return};self.completion=nil
        credentialEditor?.close();credentialEditor=nil;model.options=false
        if let panel{panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.orderOut(nil)};panel=nil
        if let row{commitCredentials(credentialChanges);credentialChanges.removeAll();if let window{if let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()};window.sheetParent?.endSheet(window);window.close()};completion(row)}
        else{credentialChanges.removeAll();if let window{if let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()};window.sheetParent?.endSheet(window);window.close()};completion(nil)}
    }
    override func close() { finish(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { guard panel == nil else { return false }; finish(nil); return false }
    func windowWillClose(_ notification:Notification){finish(nil)}
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class IssueProviderAssociationDraft: ObservableObject {
    @Published var row: NativeIssueAssociation
    @Published var choosing = false
    @Published var error: String?
    @Published var options = false
    var credentials:()->Void={}
    var accept: () -> Void = {}
    var cancel: () -> Void = {}
    var browse: () -> Void = {}
    init(_ row: NativeIssueAssociation) { self.row = row }
}
private struct IssueProviderAssociationDialog: View {
    @ObservedObject var model: IssueProviderAssociationDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable", isOn: $model.row.enabled)
            Text("Working tree path:")
            HStack { TextField("Working tree path", text: $model.row.path); Button("…") { model.browse() } }
            Text("Issue tracker provider:")
            Picker("Provider",selection:$model.row.provider){ForEach(NativeIssueProviderRegistry.descriptors,id:\.identifier){Text($0.name).tag($0.identifier)};if NativeIssueProviderRegistry.descriptor(identifier:model.row.provider)==nil{Text(model.row.provider+" (unavailable)").tag(model.row.provider)}}.labelsHidden()
                .onChange(of:model.row.provider){_ in model.error=nil}
            HStack { Text("Parameters:"); Spacer();if model.row.provider=="org.turtlegit.issue-http"{Button("Credentials…"){model.credentials()}}; Button("Options…") { model.options = true }.disabled(NativeIssueProviderRegistry.descriptor(identifier:model.row.provider)==nil) }
            TextEditor(text: $model.row.parameters).font(.system(.body, design: .monospaced)).frame(minHeight: 80).border(Color.secondary.opacity(0.4))
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction); Button("OK") { model.accept() }.keyboardShortcut(.defaultAction) }
        }.padding(16).disabled(model.choosing).sheet(isPresented: $model.options) { IssueProviderOptionsDraft(provider:model.row.provider,parameters:$model.row.parameters) }
    }
}
private struct IssueProviderOptionsDraft: View {
    let provider:String
    @Binding var parameters: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    private var error: String? { do { _ = try NativeIssueProviderSession(identifier:provider,parameters:draft); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((NativeIssueProviderRegistry.descriptor(identifier:provider)?.name ?? provider)+" options").font(.headline)
            Text(NativeIssueProviderRegistry.descriptor(identifier:provider)?.optionsDescription ?? "This provider is unavailable.").font(.caption)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.4))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Example") { draft = NativeIssueProviderRegistry.descriptor(identifier:provider)?.exampleParameters ?? "" }; Spacer(); Button("Cancel") { dismiss() }; Button("OK") { parameters = draft; dismiss() }.disabled(error != nil) }
        }.padding(16).frame(width: 720, height: 420).onAppear { draft = parameters }
    }
}
