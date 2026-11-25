// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Lists only explicit grants. No configuration, Include or key contents are read.
@MainActor final class SSHConfigurationAccessModel:ObservableObject {
    private(set) static var activeOperations=0
    @Published private(set) var grants:[SSHConfigurationGrant]=[]
    @Published var selection=Set<GitReferenceName>() {didSet{if selection != oldValue {operation?.cancel()}}}
    @Published var panelOpen=false
    @Published private(set) var busy=false
    @Published private(set) var retired=false
    @Published var error:String?
    var onDrained:()->Void={}
    let store:SSHConfigurationAccessStore
    let requireSecurityScope:Bool
    var readGrants:()throws->[SSHConfigurationGrant]
    var remember:(URL,Bool)throws->Void
    var forget:([SSHConfigurationGrant])throws->Void
    var acquire:(SSHConfigurationGrant,Bool,OperationCancellation)throws->SSHConfigurationAccess
    private var operation:OperationCancellation?
    private var epoch=UUID()
    var selected:[SSHConfigurationGrant] {grants.filter{selection.contains($0.id)}}
    var available:Bool {!retired && !busy && !panelOpen}
    init(store:SSHConfigurationAccessStore = .shared,requireSecurityScope:Bool = GitRuntime.isAppStoreBuild) {
        self.store=store;self.requireSecurityScope=requireSecurityScope
        readGrants={try store.grants()};remember={try store.remember($0,requireSecurityScope:$1)}
        forget={try store.forget($0)};acquire={try store.acquire($0,requireSecurityScope:$1,cancellation:$2)}
    }
    func refresh() {
        guard available else{return}
        do {grants=try readGrants();selection.formIntersection(Set(grants.map(\.id)))}catch{self.error=error.localizedDescription}
    }
    func authorize(_ urls:[URL],ownerIsCurrent:()->Bool) {
        guard available,ownerIsCurrent(),!urls.isEmpty else{return}
        var failures=[String](),saved=0
        for url in urls {
            guard available,ownerIsCurrent() else {
                failures.append("Authorization stopped because the settings window changed. Remaining locations were not attempted.")
                break
            }
            do {try remember(url,requireSecurityScope);saved += 1}
            catch {failures.append(url.path+": "+error.localizedDescription)}
        }
        // Each explicit grant saves independently. Preserve every failed path
        // even if a subsequent grant succeeds; this is not a rollback operation.
        guard available,ownerIsCurrent() else{return}
        if failures.isEmpty {error=nil}
        else {
            let summary=saved>0 ? "Some permissions were saved; other selected locations failed:":"No selected locations were authorized:"
            error=summary+"\n"+failures.joined(separator:"\n")
        }
        refresh()
    }
    func forgetSelected(ownerIsCurrent:()->Bool) {
        guard available,ownerIsCurrent(),!selected.isEmpty else{return}
        let accepted=selected
        do {try forget(accepted);error=nil;refresh()}catch{self.error=error.localizedDescription;refresh()}
    }
    func renew(ownerIsCurrent:@escaping ()->Bool) {
        guard available,ownerIsCurrent(),!selected.isEmpty else{return}
        let accepted=selected,request=UUID(),token=OperationCancellation(),read=acquire,required=requireSecurityScope
        epoch=request;operation=token;busy=true;Self.activeOperations += 1
        Task { [self] in
            defer {operation=nil;busy=false;Self.activeOperations -= 1;onDrained()}
            do {
                // Returned access owns its scopes only for renewal; transports
                // acquire their own operation-scoped leases independently.
                _ = try await Task.detached {try accepted.map {grant in try token.check();return try read(grant,required,token)}}.value
                try token.check()
                guard !retired,epoch==request,ownerIsCurrent(),selected==accepted else{return}
                error=nil
            }catch {if !retired,epoch==request,!token.isCancelled,ownerIsCurrent(){self.error=error.localizedDescription}}
            if !retired,epoch==request,ownerIsCurrent(){busy=false;refresh()}
        }
    }
    func retire() {guard !retired else{return};retired=true;epoch=UUID();operation?.cancel()}
}

@MainActor final class SSHConfigurationAccessWindowController:NSWindowController,NSWindowDelegate {
    private(set) static var activeReleases=0
    static var activeOperations:Int {activeReleases+SSHConfigurationAccessModel.activeOperations}
    let model:SSHConfigurationAccessModel
    private(set) var panel:NSOpenPanel?
    private(set) var closing=false
    private(set) var released=false
    private var panelRequest:UUID?
    private var drainingPanel=false
    private var panelCloseComplete=false
    private var parentIsCurrent:()->Bool
    var onClosed:()->Void={}
    var presentPanel:(NSOpenPanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void={panel,parent,reply in panel.beginSheetModal(for:parent,completionHandler:reply)}
    var selectedURLs:(NSOpenPanel)->[URL]={$0.urls}
    var homeDirectory:URL=UserAccountPaths.homeDirectory
    var canAct:Bool {!closing && !released && parentIsCurrent() && window?.isVisible==true && window?.attachedSheet==nil && !drainingPanel && model.available}
    init(store:SSHConfigurationAccessStore = .shared,requireSecurityScope:Bool = GitRuntime.isAppStoreBuild,parentIsCurrent:@escaping ()->Bool={true}) {
        model=SSHConfigurationAccessModel(store:store,requireSecurityScope:requireSecurityScope);self.parentIsCurrent=parentIsCurrent
        let window=NSWindow(contentRect:.init(x:0,y:0,width:680,height:355),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="SSH Configuration Access";window.isReleasedWhenClosed=false;window.contentMinSize = .init(width:560,height:310)
        super.init(window:window);window.delegate=self
        window.contentViewController=NSHostingController(rootView:SSHConfigurationAccessDialog(model:model,browse:{[weak self] in self?.browse()},renew:{[weak self] in self?.renew()},forget:{[weak self] in self?.forget()},close:{[weak self] in self?.requestClose()}))
        model.onDrained={[weak self] in self?.finishClose()};model.refresh()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func bindParent(_ current:@escaping ()->Bool){guard !closing,!released else{return};parentIsCurrent=current}
    func browse() {
        guard canAct,let window else{return}
        let chosen=model.selected.first
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=true;panel.allowsMultipleSelection=true;panel.showsHiddenFiles=true
        panel.canCreateDirectories=true;panel.title="Allow SSH Configuration Access";panel.prompt="Allow Access"
        panel.message="Choose your .ssh folder, or individual configuration and known-host files. Select additional Include locations explicitly. Access permissions save immediately."
        panel.directoryURL=chosen.map{let url=URL(fileURLWithPath:$0.configuredPath);return $0.kind == .directory ? url:url.deletingLastPathComponent()} ?? homeDirectory.appendingPathComponent(".ssh",isDirectory:true)
        panel.nameFieldStringValue=chosen.flatMap{$0.kind == .file ? ($0.configuredPath as NSString).lastPathComponent:nil} ?? ""
        panel.alphaValue=window.alphaValue;panel.appearance=window.appearance
        let request=UUID();panelRequest=request;self.panel=panel;model.panelOpen=true;Self.activeReleases += 1
        presentPanel(panel,window) { [weak self] response in
            guard let self,self.panel===panel,self.panelRequest==request,!self.drainingPanel else{return}
            let urls=response == .OK ? self.selectedURLs(panel):[]
            self.panelRequest=nil;self.drainingPanel=true
            SettingsLifecycleSheetDrain.close([panel]) { [self] in
                self.panel=nil;self.drainingPanel=false;self.model.panelOpen=false;Self.activeReleases -= 1
                if !self.closing,self.parentIsCurrent(),window.isVisible {
                    // Each mutation is synchronous on the owner actor, after
                    // actual panel detachment; stale/duplicate replies cannot act.
                    self.model.authorize(urls,ownerIsCurrent:{[self] in !self.closing && self.parentIsCurrent() && self.window === window})
                }
                self.finishClose()
            }
        }
    }
    func renew(){guard canAct else{return};model.renew(ownerIsCurrent:{[weak self] in guard let self else{return false};return !self.closing && self.parentIsCurrent() && self.window?.isVisible==true})}
    func forget(){guard canAct else{return};model.forgetSelected(ownerIsCurrent:{[self] in canAct})}
    func requestClose(){retire()}
    override func close(){retire()}
    func windowShouldClose(_ sender:NSWindow)->Bool{retire();return false}
    func windowWillClose(_ notification:Notification){retire()}
    func retire(){
        guard !closing else{return};closing=true;Self.activeReleases += 1;model.retire()
        if let panel,!drainingPanel {
            panelRequest=nil;drainingPanel=true;panel.cancel(nil)
            SettingsLifecycleSheetDrain.close([panel]){[self] in self.panel=nil;drainingPanel=false;model.panelOpen=false;Self.activeReleases -= 1;finishClose()}
        }
        finishClose()
    }
    private func finishClose(){
        guard closing,!released,!model.busy,panel==nil,!drainingPanel,!panelCloseComplete else{return}
        panelCloseComplete=true
        guard let window else{completeClose();return}
        SettingsLifecycleSheetDrain.close([window]){[self] in window.close();completeClose()}
    }
    private func completeClose(){guard !released else{return};released=true;Self.activeReleases -= 1;onClosed();onClosed={};parentIsCurrent={false}}
}

private struct SSHConfigurationAccessDialog:View {
    @ObservedObject var model:SSHConfigurationAccessModel
    let browse:()->Void,renew:()->Void,forget:()->Void,close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:10){
            Text("Allow access to SSH configuration and known hosts").font(.headline)
            Text("Folder access supports configuration reads and known-host updates. Select additional Include locations explicitly. Your SSH client settings and agent stay unchanged.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Table(model.grants,selection:$model.selection){
                TableColumn("Path"){grant in HStack{Image(nsImage:(grant.kind == .directory ? MenuIcon.explore:MenuIcon.editor).image() ?? NSImage()).frame(width:16,height:16);Text(grant.configuredPath).lineLimit(1).truncationMode(.middle).help(grant.configuredPath)}}
                TableColumn("Type"){grant in Text(grant.kind == .directory ? "Folder":"File")}.width(70)
            }.border(Color.secondary.opacity(0.3)).disabled(!model.available)
            Text("Permissions save immediately; Settings Cancel does not undo them. Forget leaves files, saved passphrases and active connections unchanged.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text(model.error ?? " ").help(model.error ?? "").font(.caption).foregroundStyle(.red).lineLimit(2).frame(height:30,alignment:.topLeading)
            HStack {
                Button(action:browse){CommandLabel(title:"Allow Access…",icon:.explore)}.disabled(!model.available)
                Button(action:renew){CommandLabel(title:"Renew",icon:.refresh)}.disabled(!model.available || model.selection.isEmpty)
                Button(action:forget){CommandLabel(title:"Forget",icon:.remove)}.disabled(!model.available || model.selection.isEmpty)
                if model.busy{ProgressView().controlSize(.small)}
                Spacer();Button("Help"){if !model.retired{TurtleGitHelp.show(.ssh)}};Button("Close",action:close).keyboardShortcut(.cancelAction)
            }
        }.padding(14)
    }
}
