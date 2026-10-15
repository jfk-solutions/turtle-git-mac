// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Edits the workspace's private archive; Finder watches own a separate archive.
@MainActor final class RepositoryAccessWindowModel: ObservableObject {
    enum FolderChoice { case repository, addPermission, replacePermission(UUID) }
    @Published private(set) var repositories: [SavedRepository] = []
    @Published var selection: UUID? { didSet { if selection != oldValue { permissionSelection=nil; error=nil } } }
    @Published var permissionSelection: UUID?
    @Published private(set) var checks: [UUID:String] = [:]
    @Published private(set) var busy=false
    @Published var error:String?
    private(set) var retired=false
    private let store:RepositoryAccessStore
    var provider:any RepositoryBookmarkProvider
    var requireScope:Bool
    weak var window:NSWindow?
    var mayChange:()->Bool = { true }
    var onChanged:()->Void = {}
    var open:((SavedRepository)->Void)?
    var close:()->Void = {}
    // Owned presentation seams also let native checks deliver late responses.
    var presentFolder:((NSOpenPanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    var selectedFolder:(NSOpenPanel)->URL? = { $0.url }
    var presentQuestion:((NSAlert,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    private var sheet:NSWindow?
    private var request:UUID?
    var selected:SavedRepository? { repositories.first { $0.id==selection } }
    var permissions:[SavedFolderPermission] { selected?.additionalPermissions ?? [] }
    var available:Bool { !retired && !busy && mayChange() }
    init(store:RepositoryAccessStore,provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),requireScope:Bool = GitRuntime.isAppStoreBuild,selected:UUID? = nil) {
        self.store=store;self.provider=provider;self.requireScope=requireScope
        self.repositories=store.repositories;selection=selected ?? store.repositories.first?.id
    }
    func refresh() {
        guard !retired else { return }
        repositories=store.repositories
        if !repositories.contains(where:{ $0.id==selection }) { selection=repositories.first?.id }
        if !permissions.contains(where:{ $0.id==permissionSelection }) { permissionSelection=nil }
        let ids=Set(repositories.map(\.id)+repositories.flatMap{($0.additionalPermissions ?? []).map(\.id)})
        checks=checks.filter{ids.contains($0.key)}
    }
    private func changed() { checks=[:];refresh();onChanged() }
    func openSelected() { guard available,let selected else { return };open?(selected) }
    /// Check each bookmark independently, renew stale records and release scopes
    /// immediately. This is not an Open operation and must not reorder Recents.
    func checkAccess() {
        guard available,let saved=selected else { return }
        busy=true;error=nil
        defer { busy=false;refresh();onChanged() }
        func readable(_ lease:RepositoryAccessLease) throws {
            var directory:ObjCBool=false
            guard FileManager.default.fileExists(atPath:lease.url.path,isDirectory:&directory),directory.boolValue,FileManager.default.isReadableFile(atPath:lease.url.path) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        }
        do { let lease=try store.acquire(saved.id,requireSecurityScope:requireScope,recordingOpen:false);try readable(lease);checks[saved.id]="Available";withExtendedLifetime(lease) {} }
        catch { checks[saved.id]="Choose folder again" }
        for permission in saved.additionalPermissions ?? [] {
            do { let lease=try store.acquirePermission(saved.id,permission:permission.id,requireSecurityScope:requireScope);try readable(lease);checks[permission.id]="Available";withExtendedLifetime(lease) {} }
            catch { checks[permission.id]="Choose folder again" }
        }
    }
    func choose(_ choice:FolderChoice) {
        guard available,let saved=selected,let window,window.attachedSheet==nil else { return }
        if case .replacePermission(let id)=choice, !permissions.contains(where:{$0.id==id}) { return }
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.prompt="Allow Access";panel.appearance=window.appearance
        switch choice {
        case .repository:
            panel.title="Choose repository folder";panel.message="Select this repository's working folder, or its new location if it has moved."
            panel.directoryURL=URL(fileURLWithPath:saved.lastKnownPath)
        case .addPermission:
            panel.title="Allow additional folder access";panel.message="Choose a folder containing external Git metadata or objects used by this repository."
            panel.directoryURL=URL(fileURLWithPath:saved.lastKnownPath)
        case .replacePermission(let id):
            panel.title="Renew additional folder access";panel.message="Choose the folder again, or its new location."
            panel.directoryURL=permissions.first(where:{$0.id==id}).map{URL(fileURLWithPath:$0.path)}
        }
        let identity=UUID();request=identity;sheet=panel;busy=true;error=nil
        let completion:(NSApplication.ModalResponse)->Void={ [weak self,weak panel] response in
            guard let self,!self.retired,self.request==identity else { return }
            self.request=nil;self.sheet=nil;self.busy=false
            guard response == .OK,let panel,let url=self.selectedFolder(panel),self.mayChange(),self.store.repositories.contains(where:{$0.id==saved.id}) else { return }
            do {
                let lease=RepositoryAccessLease(url:url,provider:self.provider)
                guard !self.requireScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                var isDirectory:ObjCBool=false
                guard FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory),isDirectory.boolValue else { throw GitConfigurationFailure.invalidValue }
                switch choice {
                case .repository:
                    // Inspect only the selected folder. Git discovery may itself
                    // need external metadata grants and belongs to Open.
                    let fm=FileManager.default
                    let gitfile=(try? fm.attributesOfItem(atPath:url.appendingPathComponent(".git").path)) != nil
                    let bare=fm.fileExists(atPath:url.appendingPathComponent("HEAD").path) && (try? fm.attributesOfItem(atPath:url.appendingPathComponent("objects").path)) != nil
                    guard gitfile || bare else { self.error="Select a repository's root folder.";return }
                    _=try self.store.replace(saved.id,with:url)
                case .addPermission: try self.store.addPermission(saved.id,url:url)
                case .replacePermission(let id): try self.store.addPermission(saved.id,url:url,replacing:id)
                }
                withExtendedLifetime(lease) {};self.changed()
            } catch { self.error=error.localizedDescription }
        }
        if let presentFolder { presentFolder(panel,window,completion) }
        else { panel.beginSheetModal(for:window,completionHandler:completion) }
    }
    func remove(permission:UUID? = nil) {
        guard available,let saved=selected,let window,window.attachedSheet==nil else { return }
        if let permission,!permissions.contains(where:{$0.id==permission}) { return }
        let alert=NSAlert();alert.alertStyle = .warning
        alert.messageText=permission==nil ? "Forget this repository?" : "Remove this folder's saved access?"
        alert.informativeText=permission==nil ? "This removes the repository and its extra folder grants from Open Recent. Repository files stay on disk. Open windows keep their current access until they finish." : "Reopening the repository will ask again if this folder is required. Open windows keep their current access until they finish."
        alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:permission==nil ? "Forget" : "Remove")
        alert.window.defaultButtonCell=alert.buttons.first?.cell as? NSButtonCell
        let identity=UUID();request=identity;sheet=alert.window;busy=true;error=nil
        let completion:(NSApplication.ModalResponse)->Void={ [weak self] response in
            guard let self,!self.retired,self.request==identity else { return }
            self.request=nil;self.sheet=nil;self.busy=false
            guard response == .alertSecondButtonReturn,self.mayChange() else { return }
            do {
                if let permission { try self.store.removePermission(saved.id,permission:permission) }
                else { try self.store.forget(saved.id) }
                self.changed()
            } catch { self.error=error.localizedDescription }
        }
        if let presentQuestion { presentQuestion(alert,window,completion) }
        else { alert.beginSheetModal(for:window,completionHandler:completion) }
    }
    func retire() {
        guard !retired else { return };retired=true;request=nil
        if let sheet { sheet.sheetParent?.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil);sheet.close() }
        sheet=nil;busy=false;onChanged={};open=nil;close={}
    }
}

@MainActor final class RepositoryAccessWindowController:NSWindowController,NSWindowDelegate {
    let model:RepositoryAccessWindowModel
    var onClosed:()->Void = {}
    init(model:RepositoryAccessWindowModel) {
        self.model=model
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:610),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Repository Folder Access – TurtleGit";window.minSize=NSSize(width:820,height:680);window.isReleasedWhenClosed=false
        window.contentViewController=NSHostingController(rootView:RepositoryAccessDialog(model:model))
        super.init(window:window);model.window=window;window.delegate=self
        window.setContentSize(NSSize(width:900,height:680));window.center()
        model.close={ [weak self] in self?.window?.performClose(nil) }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowShouldClose(_ sender:NSWindow)->Bool { !model.busy && sender.attachedSheet==nil }
    func windowWillClose(_ notification:Notification) { model.retire();window?.contentViewController=nil;onClosed() }
}

private struct RepositoryAccessDialog:View {
    @ObservedObject var model:RepositoryAccessWindowModel
    private func state(_ id:UUID)->some View {
        Text(model.checks[id] ?? "Not checked").foregroundStyle(model.checks[id]=="Available" ? Color.green : model.checks[id]==nil ? Color.secondary : Color.orange)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Repository folder access").font(.headline)
            Text("Manage the folders saved for Open Recent. Finder background watches are managed separately in Settings → Icon Overlays.").foregroundStyle(.secondary)
            Table(model.repositories,selection:$model.selection) {
                TableColumn("Repository") { saved in HStack { Image(nsImage:MenuIcon.repositoryBrowser.contextImage() ?? NSImage());Text(saved.name) } }
                TableColumn("Folder") { saved in Text(saved.lastKnownPath).lineLimit(1).truncationMode(.middle).help(saved.lastKnownPath) }
                TableColumn("Access") { saved in state(saved.id) }.width(min:120,ideal:140)
            }.accessibilityLabel("Saved repositories").frame(minHeight:140)
            HStack {
                Button { model.openSelected() } label: { CommandLabel(title:"Open",icon:.open) }.disabled(model.selected==nil)
                Button { model.checkAccess() } label: { CommandLabel(title:"Check and Renew Access",icon:.refresh) }.disabled(model.selected==nil)
                Button { model.choose(.repository) } label: { CommandLabel(title:"Choose Repository Folder…",icon:.open) }.disabled(model.selected==nil)
                Button { model.remove() } label: { CommandLabel(title:"Forget…",icon:.remove) }.disabled(model.selected==nil)
            }.disabled(!model.available)
            GroupBox("Additional folder access") {
                VStack(alignment:.leading,spacing:8) {
                    Table(model.permissions,selection:$model.permissionSelection) {
                        TableColumn("Folder") { permission in Text(permission.path).lineLimit(1).truncationMode(.middle).help(permission.path) }
                        TableColumn("Access") { permission in state(permission.id) }.width(min:120,ideal:140)
                    }.accessibilityLabel("Additional repository folders").frame(minHeight:110)
                    HStack {
                        Button { model.choose(.addPermission) } label: { CommandLabel(title:"Add…",icon:.add) }.disabled(model.selected==nil)
                        Button { if let id=model.permissionSelection { model.choose(.replacePermission(id)) } } label: { CommandLabel(title:"Choose Folder Again…",icon:.open) }.disabled(model.permissionSelection==nil)
                        Button { if let id=model.permissionSelection { model.remove(permission:id) } } label: { CommandLabel(title:"Remove…",icon:.remove) }.disabled(model.permissionSelection==nil)
                    }
                }.padding(4)
            }.disabled(!model.available)
            Text("Changes affect future openings. Existing windows and operations keep their current access until they finish.").font(.caption).foregroundStyle(.secondary)
            if let error=model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer();Button("Close") { model.close() }.keyboardShortcut(.cancelAction) }
        }.padding(16).disabled(model.busy || model.retired)
    }
}
