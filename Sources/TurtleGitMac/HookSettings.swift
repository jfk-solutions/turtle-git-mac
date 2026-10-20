// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of SetHooks.cpp, SetHooksAdv.cpp and their resources.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor enum ClientHookPreferences {
    struct Decision: Codable { let identity: ClientHookApprovalIdentity; let approved: Bool }
    static func globals(_ preferences:UserDefaults) -> [ClientHook] { ClientHookConfiguration.parse(preferences.string(forKey:"hooks") ?? "") }
    static func decision(_ hook:ClientHook,preferences:UserDefaults) -> Bool? {
        guard let data = preferences.data(forKey:"ClientHooks.Approvals"), let decisions = try? JSONDecoder().decode([Decision].self,from:data) else { return nil }
        return decisions.last { $0.identity == hook.approvalIdentity }?.approved
    }
    static func remember(_ hook:ClientHook,approved:Bool?,preferences:UserDefaults) throws {
        let old = preferences.data(forKey:"ClientHooks.Approvals").flatMap { try? JSONDecoder().decode([Decision].self,from:$0) } ?? []
        var values = old.filter { $0.identity != hook.approvalIdentity }
        if let approved { values.append(Decision(identity:hook.approvalIdentity,approved:approved)) }
        preferences.set(try JSONEncoder().encode(values),forKey:"ClientHooks.Approvals")
    }
}

@MainActor final class HookSettingsModel: ObservableObject {
    private(set) static var activeSaves = 0
    private(set) static var activeReads = 0
    @Published var hooks:[ClientHook] = []
    @Published var selection = Set<String>()
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var hasEditor = false
    @Published var error:String?
    let preferences:UserDefaults
    private var saved:[ClientHook] = []
    private var repository:GitRepository?, access:RepositoryAccessLease?
    private(set) var localAvailable = false
    private var invalidated = false, generation = UUID()
    private var live=true,saving=false
    private var attachment:UUID?
    private var editorGeneration=UUID()
    @Published private var active=true
    private var cancellation:OperationCancellation?
    private var editor:HookConfigurationController?
    var configureEditor:(HookConfigurationController)->Void = {_ in}
    weak var window:NSWindow?
    init(preferences:UserDefaults = .standard) { self.preferences = preferences }
    var modified:Bool { loaded && hooks != saved }
    var editable:Bool { loaded && live && !busy && !hasEditor && !invalidated }
    var selected:[ClientHook] { hooks.filter { selection.contains($0.id) } }
    var validationError:String? {
        do { try ClientHookConfiguration.validate(hooks); return nil } catch { return error.localizedDescription }
    }
    func activate(repository:GitRepository?,access:RepositoryAccessLease?) {
        guard !invalidated else{return};live=true
        let epoch=editorGeneration
        DispatchQueue.main.async { [weak self] in guard let self,self.live,self.editorGeneration==epoch else{return};self.active=true }
        guard !busy || cancellation?.isCancelled == true else{return}
        if loaded { return }
        self.repository = repository; self.access = access
        let request = UUID(), token = OperationCancellation(); generation = request; cancellation = token; busy = true;Self.activeReads += 1
        Task { [self,access] in
            defer {Self.activeReads -= 1;withExtendedLifetime(access) {}}
            defer { if generation == request { busy = false; cancellation = nil } }
            do {
                var values = ClientHookPreferences.globals(preferences), local = false
                if let repository {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    local = !(try await repository.isBare(cancellation:token))
                    var project = try await repository.projectClientHooks(cancellation:token)
                    for index in project.indices { project[index].enabled = ClientHookPreferences.decision(project[index],preferences:preferences) ?? true }
                    values += project
                }
                guard !invalidated, generation == request, !token.isCancelled else { return }
                hooks = ClientHookConfiguration.sorted(values); saved = hooks; loaded = true; localAvailable = local; error = nil
            } catch { if !invalidated, generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func apply() async -> Bool {
        guard loaded, !busy, !hasEditor, !invalidated else { return false }
        if let validationError { error = validationError; return false }
        let snapshot = hooks, prior = saved, repository = repository, access = access, request = generation
        let token = OperationCancellation(); cancellation = token; busy = true;saving=true; Self.activeSaves += 1
        defer { Self.activeSaves -= 1;saving=false; busy = false; cancellation = nil; withExtendedLifetime(access) {} }
        do {
            let globals = try ClientHookConfiguration.serialize(snapshot)
            if snapshot.filter(\.local) != prior.filter(\.local) {
                guard let repository, localAvailable else { throw ClientHookFailure.configuration("Local hooks require a working-tree repository.") }
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                // Enabling/disabling is per-user; only command/wait/show live in .tgitconfig.
                func shared(_ values:[ClientHook]) -> [ClientHook] { values.filter(\.local).map { var value = $0; value.enabled = true; return value } }
                if shared(snapshot) != shared(prior) { try await repository.saveProjectClientHooks(shared(snapshot),cancellation:token) }
                guard !invalidated, generation == request, !token.isCancelled else { return false }
                for hook in snapshot where hook.local {
                    if !hook.enabled { try ClientHookPreferences.remember(hook,approved:false,preferences:preferences) }
                    else if ClientHookPreferences.decision(hook,preferences:preferences) == false { try ClientHookPreferences.remember(hook,approved:nil,preferences:preferences) }
                }
            }
            guard !invalidated, generation == request, !token.isCancelled else { return false }
            preferences.set(globals,forKey:"hooks"); saved = snapshot; error = nil; return true
        } catch { if !invalidated, generation == request { self.error = error.localizedDescription }; return false }
    }
    func cancel() { guard !busy else { return }; closeEditor(); hooks = saved; selection = []; error = nil }
    func invalidate() {invalidated=true;suspend()}
    func suspend() {
        live=false;editorGeneration=UUID();let epoch=editorGeneration
        if !saving || invalidated {generation=UUID();cancellation?.cancel()}
        closeEditor()
        DispatchQueue.main.async { [weak self] in
            guard let self,!self.live,self.editorGeneration==epoch else{return}
            self.active=false;if !self.saving {self.busy=false}
        }
    }
    func attach(to owner:NSWindow?,attachment receipt:UUID) {
        guard !invalidated else{return}
        guard let owner else{detach(attachment:receipt);return}
        guard attachment != receipt || window !== owner else{return}
        attachment=receipt;window=owner;editorGeneration=UUID();live=true
        let epoch=editorGeneration
        DispatchQueue.main.async { [weak self] in guard let self,self.live,self.editorGeneration==epoch else{return};self.active=true }
    }
    func detach(attachment receipt:UUID) {guard attachment==receipt else{return};attachment=nil;suspend()}
    func setEnabled(_ id:String,_ enabled:Bool) { guard editable, let index = hooks.firstIndex(where:{ $0.id == id }) else { return }; hooks[index].enabled = enabled }
    func remove() { guard editable else { return }; hooks.removeAll { selection.contains($0.id) }; selection = [] }
    func configure(copy:Bool = false,add:Bool = false) {
        guard editable, let window, window.attachedSheet == nil, add || selected.count == 1 else { return }
        let original = add ? nil : selected.first
        var draft = original ?? ClientHook(path:"",enabled:false)
        if copy {draft.path=""}
        let controller = HookConfigurationController(hook:draft,repositoryRoot:localAvailable ? repository?.root:nil,preferences:preferences,requiresTypeSelection:add)
        let request = editorGeneration
        controller.externalAvailability={ [weak self] in guard let self else{return false};return !self.invalidated && self.live && self.editorGeneration==request }
        editor = controller; hasEditor = true
        controller.completed = { [self,weak controller] value in
            guard let controller else{return}
            if editor === controller {editor=nil}
            if editor == nil {hasEditor=false}
            guard !invalidated,live,editorGeneration==request,let value else{return}
            if !copy,let original {hooks.removeAll {$0.id==original.id}}
            hooks.removeAll {$0.id==value.id};hooks.append(value)
            hooks=ClientHookConfiguration.sorted(hooks);selection=[value.id]
        }
        configureEditor(controller)
        guard !controller.answered else{return}
        if let sheet=controller.window {sheet.alphaValue=window.alphaValue;sheet.appearance=window.appearance;window.beginSheet(sheet,completionHandler:nil)}
    }
    private func closeEditor() {let controller=editor;editor=nil;controller?.finish(nil)}

}

@MainActor final class HookConfigurationDraft: ObservableObject {
    @Published var hook:ClientHook {
        didSet {if hook != oldValue {revision=UUID()};if hook.type != oldValue.type {selectedType=hook.type}}
    }
    @Published var selectedType:ClientHookType? {didSet{if selectedType != oldValue {revision=UUID()}}}
    @Published var error:String?
    @Published var choosing=false
    @Published private(set) var active=true
    private(set) var revision=UUID()
    let root:URL?
    init(hook:ClientHook,root:URL?,requiresTypeSelection:Bool=false){self.hook=hook;self.root=root;selectedType=requiresTypeSelection ? nil:hook.type}
    func setLocal(_ local:Bool){guard active,!choosing,!local || root != nil else{return};hook.local=local}
    func selectType(_ value:ClientHookType?){guard active,!choosing else{return};selectedType=value;if let value {hook.type=value}}
    func retire(){active=false;revision=UUID()}
    func acceptedValue()throws->ClientHook {
        guard let selectedType else{throw ClientHookFailure.configuration("Select a hook type.")}
        var value=hook;value.type=selectedType
        if value.local {
            guard let root else{throw ClientHookFailure.configuration("Local hooks require a working-tree repository.")};value.path=root.path
        }else if value.path != "*" {
            guard value.path.hasPrefix("/"),(try? URL(fileURLWithPath:value.path).resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true else{throw ClientHookFailure.configuration("Choose an existing absolute working tree folder, or * for all repositories.")}
        }
        if let error=value.validationError{throw ClientHookFailure.configuration(error)}
        return value
    }
}

@MainActor final class HookConfigurationController:NSWindowController,NSWindowDelegate {
    static private(set) var activeReleases=0
    static private(set) var activeChoosers=0
    let draft:HookConfigurationDraft
    var completed:(ClientHook?)->Void={_ in}
    var externalAvailability:()->Bool={true}
    var presentBrowse:((NSOpenPanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void)?
    var selectedBrowseURL:(NSOpenPanel)->URL?={$0.url}
    private(set) var answered=false
    private(set) var panel:NSOpenPanel?
    private let preferences:UserDefaults
    private var folderAccess:RepositoryAccessLease?
    private var scriptAccess:RepositoryAccessLease?
    private var selectedScript:URL?
    private var selectedScriptCommand:String?
    private var browseReply:((NSApplication.ModalResponse)->Void)?
    private var pendingBrowses=0
    init(hook:ClientHook,repositoryRoot:URL?,preferences:UserDefaults = .standard,requiresTypeSelection:Bool=false){
        self.preferences=preferences;draft=HookConfigurationDraft(hook:hook,root:repositoryRoot,requiresTypeSelection:requiresTypeSelection)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:750,height:360),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Configure Hook Scripts – TurtleGit for Mac";window.isReleasedWhenClosed=false;window.contentMinSize=NSSize(width:690,height:350)
        super.init(window:window);window.delegate=self
        window.contentViewController=NSHostingController(rootView:HookConfigurationDialog(draft:draft,accept:{[weak self] in self?.accept()},cancel:{[weak self] in self?.finish(nil)},browse:{[weak self] command in self?.browse(command:command)}).defaultAppStorage(preferences))
        window.center();DialogGeometry.attach(window,identifier:"HookConfigurationController",legacyName:"SetHooksAdvDlg")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func accept(){
        guard !answered,!draft.choosing,panel==nil,window?.attachedSheet==nil,externalAvailability() else{return}
        do{
            let value=try draft.acceptedValue()
            if let selectedScript,let selectedScriptCommand,value.command.utf8.elementsEqual(selectedScriptCommand.utf8){try ClientHookScriptAccess.remember(selectedScript,preferences:preferences)}
            finish(value)
        }catch{draft.error=error.localizedDescription}
    }
    func finish(_ value:ClientHook?){
        guard !answered else{return};answered=true;draft.retire();Self.activeReleases += 1
        let child=window,parent=window?.sheetParent,picker=panel,reply=completed
        completed={_ in};browseReply?(.cancel)
        Task { @MainActor [self] in
            if let picker{await Self.detach(picker)}
            if let child{await Self.detach(child);child.close()}
            while pendingBrowses>0 || child?.attachedSheet != nil || child?.sheetParent != nil || (child != nil && parent?.attachedSheet===child){try? await Task.sleep(nanoseconds:5_000_000)}
            Self.activeReleases -= 1;reply(value);withExtendedLifetime(self){}
        }
    }
    override func close(){finish(nil)}
    func windowShouldClose(_ sender:NSWindow)->Bool{guard !draft.choosing,sender.attachedSheet==nil else{return false};finish(nil);return false}
    func windowWillClose(_ notification:Notification){finish(nil)}
    private static func detach(_ window:NSWindow)async{
        window.sheetParent?.endSheet(window,returnCode:.cancel);window.orderOut(nil)
        while window.sheetParent != nil{try? await Task.sleep(nanoseconds:5_000_000)}
    }
    func browse(command:Bool){
        guard !answered,!draft.choosing,panel==nil,externalAvailability(),command || !draft.hook.local,let window,window.attachedSheet==nil else{return}
        let chooser=NSOpenPanel();chooser.alphaValue=window.alphaValue;chooser.appearance=window.appearance;chooser.canChooseDirectories = !command;chooser.canChooseFiles=command;chooser.allowsMultipleSelection=false;chooser.canCreateDirectories=false
        chooser.title=command ? "Select hook executable or script":"Select working tree parent"
        if command,let words=try? ClientHookCommand.arguments(draft.hook.command,root:draft.root?.path ?? "/"),let first=words.first,first.hasPrefix("/"),FileManager.default.fileExists(atPath:first){chooser.directoryURL=URL(fileURLWithPath:first).deletingLastPathComponent()}
        else if !command,draft.hook.path.hasPrefix("/"),(try? URL(fileURLWithPath:draft.hook.path).resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true{chooser.directoryURL=URL(fileURLWithPath:draft.hook.path,isDirectory:true)}
        let revision=draft.revision;panel=chooser;draft.choosing=true;pendingBrowses += 1;Self.activeChoosers += 1
        var answered=false
        let reply:(NSApplication.ModalResponse)->Void={ [self] response in
            guard !answered else{return};answered=true
            Task { @MainActor [self] in
                defer{pendingBrowses -= 1;Self.activeChoosers -= 1;if panel===chooser{panel=nil;browseReply=nil;draft.choosing=false}}
                await Self.detach(chooser)
                guard !self.answered,externalAvailability(),panel===chooser,draft.revision==revision,response == .OK,let url=selectedBrowseURL(chooser) else{return}
                let permission=RepositoryAccessLease(url:url)
                guard !GitRuntime.isAppStoreBuild || permission.hasSecurityScope else{draft.error=RepositoryAccessFailure.securityScopeUnavailable.localizedDescription;return}
                if command {
                    guard (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true else{draft.error="Choose a hook executable or script file.";return}
                    scriptAccess=permission;selectedScript=url;draft.hook.command="'"+url.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
                    selectedScriptCommand=draft.hook.command
                }else{
                    guard !draft.hook.local,(try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true else{return};folderAccess=permission;draft.hook.path=url.path
                }
            }
        }
        browseReply=reply
        if let presentBrowse{presentBrowse(chooser,window,reply)}else{chooser.beginSheetModal(for:window,completionHandler:reply)}
    }
}

private struct HookConfigurationDialog:View {
    @ObservedObject var draft:HookConfigurationDraft
    let accept:()->Void,cancel:()->Void,browse:(Bool)->Void
    var body:some View{
        VStack(alignment:.leading,spacing:8){
            Group{
                Toggle("Enable",isOn:$draft.hook.enabled)
                HStack{Text("Hook Type:");Spacer();Picker("Hook Type",selection:Binding(get:{draft.selectedType},set:draft.selectType)){
                    Text("Select a hook type").tag(ClientHookType?.none)
                    ForEach(ClientHookType.allCases,id:\.self){Text($0.title).tag(Optional($0))}
                }.labelsHidden().frame(width:230)}
                Toggle("Run for this repository",isOn:Binding(get:{draft.hook.local},set:draft.setLocal)).disabled(draft.root==nil)
                Text("Run when working tree path is under:")
                HStack{TextField("",text:$draft.hook.path).accessibilityLabel("Working tree path");Button("…"){browse(false)}}.disabled(draft.hook.local)
                Text("Command Line To Execute:")
                HStack{TextField("",text:$draft.hook.command).accessibilityLabel("Command line to execute");Button("…"){browse(true)}}
                Toggle("Wait for the script to finish",isOn:$draft.hook.wait)
                Toggle("Hide the script while running",isOn:Binding(get:{!draft.hook.show},set:{draft.hook.show = !$0}))
            }.disabled(!draft.active || draft.choosing)
            HStack{if draft.choosing{ProgressView().controlSize(.small)};Spacer();Button("OK",action:accept).keyboardShortcut(.defaultAction).disabled(!draft.active || draft.choosing);Button("Cancel",action:cancel).keyboardShortcut(.cancelAction).disabled(!draft.active);Button("Help"){TurtleGitHelp.show(.settings)}}
            if let error=draft.error{Text(error).font(.caption).foregroundStyle(.red)}
        }.padding(16)
    }
}

@MainActor struct HookSettingsPage: View {
    @ObservedObject var model:HookSettingsModel
    let repository:GitRepository?, access:RepositoryAccessLease?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HookSettingsNativeList(model:model)
            HStack { Spacer(); Button("Remove",action:model.remove).disabled(model.selected.isEmpty); Button("Edit…") { model.configure() }.disabled(model.selected.count != 1); Button("Copy") { model.configure(copy:true) }.disabled(model.selected.count != 1); Button("Add…") { model.configure(add:true) } }.disabled(!model.editable)
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }.padding(16)
        .background(HookSettingsWindowCapture(model:model).frame(width:0,height:0))
        .onAppear { model.activate(repository:repository,access:access) }

        .settingsParticipant("hooks",page:.hooks,value:model.hooks,modified:{model.modified},validate:{model.validationError},apply:model.apply,cancel:model.cancel)
    }
}

private struct HookSettingsWindowCapture:NSViewRepresentable {
    let model:HookSettingsModel
    func makeNSView(context:Context) -> NSView { Capture(model:model) }
    func updateNSView(_ view:NSView,context:Context) {if let view=view as? Capture {model.attach(to:view.window,attachment:view.attachment)}}
    static func dismantleNSView(_ view:NSView,coordinator:()) {guard let view=view as? Capture else{return};view.model?.detach(attachment:view.attachment);view.model=nil}
    final class Capture:NSView {
        let attachment=UUID()
        weak var model:HookSettingsModel?
        init(model:HookSettingsModel) { self.model = model; super.init(frame:.zero) }
        required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.attach(to:window,attachment:attachment) }
    }
}

/// SetHooks.cpp's five-column checked list. Double-click is attached to the
/// native row rather than only the type caption; state-icon clicks stay checks.
struct HookSettingsNativeList:NSViewRepresentable {
    @ObservedObject var model:HookSettingsModel
    func makeCoordinator()->Coordinator{Coordinator(model)}
    func makeNSView(context:Context)->NSScrollView{context.coordinator.make()}
    func updateNSView(_ view:NSScrollView,context:Context){context.coordinator.update()}
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator){NativeListSelection.remove(from:coordinator.table);coordinator.table.target=nil;coordinator.table.delegate=nil;coordinator.table.dataSource=nil;coordinator.table.toggleFocused={false}}
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        let model:HookSettingsModel
        let table=HookSettingsNativeTableView()
        private var updating=false
        private var measured:[ClientHook]?
        init(_ model:HookSettingsModel){self.model=model}
        func make()->NSScrollView{
            let scroll=NSScrollView();scroll.borderType = .bezelBorder;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
            table.dataSource=self;table.delegate=self;table.target=self;table.doubleAction=#selector(editRow(_:));table.style = .plain;table.rowHeight=24
            table.allowsMultipleSelection=true;table.allowsEmptySelection=true;table.allowsColumnReordering=false;table.columnAutoresizingStyle = .noColumnAutoresizing
            table.setAccessibilityLabel("Hook Scripts")
            for (key,title) in [("type","Hook Type"),("path","Path"),("command","Command Line"),("wait","Wait"),("show","Show")]{let column=NSTableColumn(identifier:.init(key));column.title=NSLocalizedString(title,comment:"");column.minWidth=35;column.width=key=="command" ? 280:key=="type" ? 170:key=="path" ? 180:55;table.addTableColumn(column)}
            table.toggleFocused={ [weak self] in
                guard let self,self.model.editable,self.model.hooks.indices.contains(self.table.selectedRow) else{return false}
                let hook=self.model.hooks[self.table.selectedRow];self.model.setEnabled(hook.id,!hook.enabled);return true
            }
            scroll.documentView=table;update();return scroll
        }
        func update(){
            updating=true;defer{updating=false}
            NativeListSelection.install(on:table,preferences:model.preferences,primaryColumn:table.tableColumns.first,labelText:{[weak self] row in guard let self,self.model.hooks.indices.contains(row) else{return nil};return self.model.hooks[row].type.rawValue},leadingInset:26)
            table.reloadData()
            let selected=IndexSet(model.hooks.indices.filter{model.selection.contains(model.hooks[$0].id)})
            if table.selectedRowIndexes != selected{table.selectRowIndexes(selected,byExtendingSelection:false)}
            let contents=model.hooks.map{value in var value=value;value.enabled=false;return value}
            if measured != contents{measured=contents;fitColumns()}
            table.needsDisplay=true
        }
        private func value(_ hook:ClientHook,key:String)->String {
            switch key{case "type":return hook.type.rawValue;case "path":return hook.local ? "local":hook.path;case "command":return hook.command;case "wait":return hook.wait ? "true":"false";default:return hook.show ? "show":"hide"}
        }
        private func fitColumns(){
            let font=NSFont.systemFont(ofSize:NSFont.systemFontSize)
            for column in table.tableColumns{
                var width=(column.title as NSString).size(withAttributes:[.font:font]).width+20
                for hook in model.hooks{width=max(width,(value(hook,key:column.identifier.rawValue) as NSString).size(withAttributes:[.font:font]).width+(column.identifier.rawValue=="type" ? 36:20))}
                column.width=max(column.minWidth,width)
            }
        }
        func numberOfRows(in tableView:NSTableView)->Int{model.hooks.count}
        func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView?{
            guard model.hooks.indices.contains(row),let column else{return nil};let hook=model.hooks[row],text=value(hook,key:column.identifier.rawValue)
            let field=NSTextField(labelWithString:text);field.lineBreakMode = .byTruncatingMiddle;field.toolTip=text
            if column.identifier.rawValue != "type"{return field}
            let cell=NSTableCellView();let check=HookSettingsEnableButton(checkboxWithTitle:"",target:self,action:#selector(setEnabled(_:)));check.hookID=hook.id;check.state=hook.enabled ? .on:.off;check.isEnabled=model.editable;check.setAccessibilityLabel("Enable "+hook.type.title)
            cell.textField=field;cell.addSubview(check);cell.addSubview(field);check.translatesAutoresizingMaskIntoConstraints=false;field.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([check.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:2),check.centerYAnchor.constraint(equalTo:cell.centerYAnchor),field.leadingAnchor.constraint(equalTo:check.trailingAnchor,constant:4),field.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),field.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        func tableViewSelectionDidChange(_ notification:Notification){guard !updating,model.editable else{return};model.selection=Set(table.selectedRowIndexes.compactMap{model.hooks.indices.contains($0) ? model.hooks[$0].id:nil})}
        @objc func setEnabled(_ sender:HookSettingsEnableButton){model.setEnabled(sender.hookID,sender.state == .on)}
        @objc func editRow(_ sender:Any?){
            guard model.editable,model.selected.count==1 else{return}
            if let event=NSApp.currentEvent,event.type == .leftMouseDown || event.type == .leftMouseUp{
                let point=table.superview?.convert(event.locationInWindow,from:nil) ?? table.convert(event.locationInWindow,from:nil)
                var hit=table.hitTest(point)
                while let view=hit{if view is HookSettingsEnableButton{return};if view===table{break};hit=view.superview}
            }
            model.configure()
        }
    }
}
@MainActor final class HookSettingsEnableButton:NSButton {var hookID=""}
@MainActor final class HookSettingsNativeTableView:NativeListSelectionTableView {
    var toggleFocused:()->Bool={false}
    override func keyDown(with event:NSEvent){if event.charactersIgnoringModifiers==" ",event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty,toggleFocused(){return};super.keyDown(with:event)}
}
