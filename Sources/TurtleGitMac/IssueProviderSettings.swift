// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class IssueProviderSettingsModel:ObservableObject {
    let preferences:UserDefaults
    let credentials:IssueProviderCredentialDrafts
    @Published var rows:[NativeIssueAssociation]=[]
    @Published var selection:Set<UUID>=[]
    @Published private(set) var hasChild=false
    @Published private(set) var loaded=false
    @Published private(set) var saving=false
    @Published var error:String?
    private var saved:[NativeIssueAssociation]=[]
    private var credentialObservation:AnyCancellable?
    private var retired=false
    private(set) var editor:IssueProviderAssociationEditor?
    weak var window:NSWindow?
    var modified:Bool {!Self.same(rows,saved) || credentials.modified}
    var chosen:NativeIssueAssociation? {guard selection.count==1,let id=selection.first else{return nil};return rows.first{$0.id==id}}
    init(preferences:UserDefaults = .standard,credentialStore:any IssueProviderCredentialStore = IssueProviderKeychainStore.shared){
        self.preferences=preferences;credentials=IssueProviderCredentialDrafts(store:credentialStore)
        do{saved=try NativeIssueAssociations.load(from:preferences);rows=saved;loaded=true}catch{self.error=error.localizedDescription}
        credentialObservation=credentials.objectWillChange.sink{ [weak self] _ in self?.objectWillChange.send() }
    }
    private static func same(_ lhs:[NativeIssueAssociation],_ rhs:[NativeIssueAssociation])->Bool {
        lhs.count==rhs.count && zip(lhs,rhs).allSatisfy{a,b in a.id==b.id && a.enabled==b.enabled && a.path.utf8.elementsEqual(b.path.utf8) && a.provider.utf8.elementsEqual(b.provider.utf8) && a.parameters.utf8.elementsEqual(b.parameters.utf8)}
    }
    func edit(copy:Bool=false,root:URL?=nil){
        guard loaded,!hasChild,!saving,!retired,let window,window.attachedSheet==nil else{return}
        var value=chosen ?? NativeIssueAssociation(path:root?.path ?? "");if copy{value.id=UUID()}
        let controller=IssueProviderAssociationEditor(association:value){[weak self] row in
            guard let self else{return};self.editor=nil;self.hasChild=false
            guard !self.retired,let row else{return}
            if let index=self.rows.firstIndex(where:{$0.id==row.id}){self.rows[index]=row}else{self.rows.append(row)};self.selection=[row.id]
        }
        controller.readCredential={ [credentials] in try await credentials.token(for:$0) }
        controller.commitCredentials={ [weak self] updates in guard let self,!self.retired else{return};for (endpoint,value) in updates{self.credentials.stage(token:value.value,for:endpoint)} }
        editor=controller;hasChild=true;controller.window?.alphaValue=window.alphaValue;controller.window?.appearance=window.appearance
        if let sheet=controller.window{window.beginSheet(sheet)}else{controller.close()}
    }
    func add(root:URL?){guard !hasChild,!saving,!retired else{return};selection=[];edit(root:root)}
    func remove(){guard loaded,!hasChild,!saving,!retired else{return};rows.removeAll{selection.contains($0.id)};selection=[]}
    private func validate(_ values:[NativeIssueAssociation])throws {
        for row in values where row.enabled && !saved.contains(where:{Self.same([$0],[row])}){try NativeIssueAssociations.validate(row)}
    }
    /// Retained synchronous catalog-only entry for existing consumers. UI Apply
    /// uses applySettings so bearer drafts participate in the same publication.
    func apply()->Bool {
        guard loaded,!hasChild,!saving,!retired,!credentials.modified else{return false}
        do{try validate(rows);try NativeIssueAssociations.save(rows,to:preferences);saved=rows;error=nil;return true}catch{self.error=error.localizedDescription;return false}
    }
    func applySettings()async->Bool {
        guard loaded,!hasChild,!saving,!retired else{return false};let accepted=rows
        do{try validate(accepted)}catch{self.error=error.localizedDescription;return false}
        saving=true;defer{saving=false}
        var publicationError:Error?
        do {
            let success=try await credentials.apply(publish:{
                do{try NativeIssueAssociations.save(accepted,to:self.preferences);return true}catch{publicationError=error;return false}
            },isValid:{!self.retired && Self.same(self.rows,accepted)})
            guard success else{return false};saved=accepted;error=nil;return true
        }catch{if !retired{self.error=(publicationError ?? error).localizedDescription};return false}
    }
    func cancel(){guard !hasChild,!saving else{return};rows=saved;credentials.cancel();selection.formIntersection(Set(rows.map(\.id)));error=nil}
    func suspend(){editor?.close();editor=nil;hasChild=false}
    func retire(){guard !retired else{return};retired=true;suspend();credentials.retire()}
}
struct IssueProviderSettingsPage: View {
    @ObservedObject var workspace: RepositoryModel
    @StateObject private var model: IssueProviderSettingsModel
    @Environment(\.settingsTransaction) private var transaction
    init(workspace: RepositoryModel, preferences: UserDefaults, model: IssueProviderSettingsModel? = nil) { self.workspace = workspace; _model = StateObject(wrappedValue: model ?? IssueProviderSettingsModel(preferences: preferences)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Issue tracker integration").font(.headline)
            Table(model.rows, selection: $model.selection) {
                TableColumn("Enabled") { row in Toggle("Enabled", isOn: Binding(get: { model.rows.first { $0.id == row.id }?.enabled == true }, set: { value in if let index = model.rows.firstIndex(where: { $0.id == row.id }) { model.rows[index].enabled = value } })).labelsHidden() }.width(65)
                TableColumn("Working tree", value: \.path)
                TableColumn("Provider") { row in Text(NativeIssueProviderRegistry.descriptor(identifier:row.provider)?.name ?? row.provider) }
                TableColumn("Parameters", value: \.parameters)
            }.disabled(model.hasChild || !model.loaded || model.saving)
            .contextMenu(forSelectionType: UUID.self) { _ in TurtleGitContextMenu { Button { model.edit() } label: { CommandLabel(title:"Edit…",icon:.editor) }.disabled(model.chosen == nil) }.defaultAppStorage(model.preferences) } primaryAction: { ids in model.selection = ids; model.edit() }
            HStack {
                Button { model.add(root: workspace.root) } label: { CommandLabel(title: "Add…", icon: .add) }
                Button("Edit…") { model.edit() }.disabled(model.chosen == nil)
                Button { model.edit(copy: true) } label: { CommandLabel(title: "Copy…", icon: .copy) }.disabled(model.chosen == nil)
                Button { model.remove() } label: { CommandLabel(title: "Remove", icon: .remove) }.disabled(model.selection.isEmpty)
            }.disabled(model.hasChild || !model.loaded || model.saving)
            Text("Enabled associations match the exact working-tree folder. They take priority over project provider configuration. HTTP providers use the native issue picker and optional endpoint credentials in Keychain. Windows COM provider settings remain separate.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).background(IssueProviderSettingsWindowProbe(model: model).frame(width: 0, height: 0))
        .settingsParticipant("issueProviders", page: .issueProviders, value: model.rows, modified: { model.modified }, validate: { model.loaded ? nil : model.error }, apply: { await model.applySettings() }, cancel: model.cancel)
        .onChange(of: model.hasChild) { _ in transaction?.notify() }.onChange(of:model.credentials.revision){_ in transaction?.notify()}.onChange(of:model.saving){_ in transaction?.notify()}.onDisappear { model.suspend() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in if let window = notification.object as? NSWindow, window === model.window { model.retire() } }
    }
}
private struct IssueProviderSettingsWindowProbe: NSViewRepresentable {
    let model: IssueProviderSettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { view.model=model;model.window = view.window;view.scheduleSelection() }
    static func dismantleNSView(_ view:Probe,coordinator:()) {view.retire();view.model=nil}
    final class Probe: NSView {
        weak var model: IssueProviderSettingsModel?
        private weak var table:NSTableView?
        private weak var primary:NSTableColumn?
        private var generation=UUID(),retired=false
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();model?.window=window;if window==nil {detach()}else{scheduleSelection()}}
        override func viewDidMoveToSuperview() {super.viewDidMoveToSuperview();scheduleSelection()}
        override func layout() {super.layout();scheduleSelection()}
        private func findTable(in view:NSView)->NSTableView? {
            if let table=view as? NSTableView,!(table is NSOutlineView) {return table}
            for child in view.subviews {if let table=findTable(in:child){return table}}
            return nil
        }
        func scheduleSelection() {
            guard !retired,window != nil else{return}
            let receipt=UUID();generation=receipt
            DispatchQueue.main.async {[weak self] in
                guard let self,!self.retired,self.generation==receipt,self.window != nil,let model=self.model else{return}
                var ancestor=self.superview,found:NSTableView?
                while let view=ancestor,found==nil {found=self.findTable(in:view);ancestor=view.superview}
                guard let found,found.tableColumns.count>=2 else{return}
                if self.table !== found {self.detach();self.table=found;self.primary=found.tableColumns[1]}
                // Native Enabled is a separate checkbox column; the source's
                // logical first label is the Working tree path, not that state.
                NativeListSelection.install(on:found,preferences:model.preferences,primaryColumn:self.primary,labelText:{[weak model] row in guard let model,model.rows.indices.contains(row) else{return nil};return model.rows[row].path})
            }
        }
        private func detach() {generation=UUID();if let table {NativeListSelection.remove(from:table)};table=nil;primary=nil}
        func retire() {retired=true;detach()}
    }
}
