// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of RegexFiltersDlg / RegexFilterDlg, TortoiseGit 2023-2025
// and TortoiseSVN 2013-2014, 2016, 2020. See NOTICE and LICENSE.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

extension Notification.Name {
    static let mergeRegexFiltersChanged = Notification.Name("TurtleGitMerge.RegexFiltersChanged")
}
@MainActor enum MergeRegexOperations { static var activeRequests = 0 }

@MainActor final class MergeRegexFilterListModel: ObservableObject {
    struct Context: Equatable { let revision: UUID; let filters: [MergeRegexFilter] }
    struct EditSession: Equatable { let id = UUID(); let context: Context; let original: MergeRegexFilter? }
    @Published private(set) var filters: [MergeRegexFilter]
    @Published var selection: String?
    @Published private(set) var error: String?
    @Published private(set) var retired = false
    @Published private(set) var session: EditSession?
    @Published private(set) var transferring = false
    @Published private var revision = UUID()
    private let original: [MergeRegexFilter]
    var edit: (MergeRegexFilter?) -> Void = { _ in }
    var close: () -> Void = {}
    var importFile: (Context) -> Void = { _ in }
    var exportFile: (Context) -> Void = { _ in }
    var cancelTransfer: (Context) -> Void = { _ in }
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; let values = MergeRegexFilters.load(defaults: defaults)
        filters = values; original = values
    }
    var context: Context { .init(revision: revision, filters: filters) }
    var canEdit: Bool { !retired && session == nil && !transferring }
    var selected: MergeRegexFilter? { filters.first { $0.id == selection } }
    func current(_ context: Context) -> Bool { canEdit && self.context == context }
    func requestEdit(_ filter: MergeRegexFilter?, context: Context) {
        guard current(context), filter == nil || filters.contains(filter!) else { return }
        edit(filter)
    }
    func beginEdit(_ filter: MergeRegexFilter?) -> EditSession? {
        guard canEdit, filter == nil || filters.contains(filter!) else { return nil }
        let value = EditSession(context: context, original: filter); session = value; return value
    }
    func finishEdit(_ session: EditSession, value: MergeRegexFilter?) {
        guard !retired, self.session == session else { return }
        self.session = nil
        guard context == session.context, let value else { return }
        accept(value, oldName: session.original?.name)
    }
    func accept(_ filter: MergeRegexFilter, oldName: String?) {
        guard canEdit else { return }
        filters = MergeRegexFilters.updating(filters, oldName: oldName, filter: filter)
        selection = filter.id; revision = UUID(); error = nil
    }
    func remove() { guard let selected else { return }; remove(selected, context: context) }
    func remove(_ filter: MergeRegexFilter, context: Context) {
        guard current(context), filters.contains(filter) else { return }
        filters.removeAll { $0.id == filter.id }; selection = nil; revision = UUID(); error = nil
    }
    func beginTransfer(context: Context) -> Context? {
        guard current(context) else { return nil }; transferring = true; revision = UUID(); error = nil
        return self.context
    }
    func finishTransfer(context: Context, imported: [MergeRegexFilter]? = nil, failure: String? = nil) {
        guard !retired, transferring, self.context == context else { return }
        if let imported {
            for filter in imported { filters = MergeRegexFilters.updating(filters, oldName: nil, filter: filter) }
            selection = imported.last?.id
        }
        transferring = false; revision = UUID(); error = failure
    }
    func saveAndClose() {
        guard canEdit else { return }
        // Another comparison may have saved the same shared definitions while
        // this list was open. Keep this draft instead of overwriting that save.
        guard MergeRegexFilters.load(defaults: defaults) == original else {
            error = "Filters changed in another window. Your draft is retained. Cancel and reopen to load the saved definitions."
            return
        }
        do {
            try MergeRegexFilters.save(filters, defaults: defaults); error = nil
            retire()
            NotificationCenter.default.post(name: .mergeRegexFiltersChanged, object: defaults)
            close()
        } catch { self.error = error.localizedDescription }
    }
    func cancel() { guard canEdit else { return }; retire(); close() }
    func retire() { guard !retired else { return }; retired = true; session = nil; transferring = false; revision = UUID(); edit = { _ in }; importFile = { _ in }; exportFile = { _ in }; cancelTransfer = { _ in } }
}

@MainActor final class MergeRegexFilterEditModel: ObservableObject {
    @Published var name: String
    @Published var expression: String
    @Published var replacement: String
    @Published private(set) var validating = false
    @Published private(set) var retired = false
    @Published private(set) var error: String?
    private var generation = 0
    private var cancellation: OperationCancellation?
    var executable: URL?
    var accepted: (MergeRegexFilter) -> Void = { _ in }
    var close: () -> Void = {}
    init(filter: MergeRegexFilter?) {
        name = filter?.name ?? ""; expression = filter?.expression ?? ""; replacement = filter?.replacement ?? ""
    }
    var value: MergeRegexFilter { .init(name: name, expression: expression, replacement: replacement) }
    var canEdit: Bool { !validating && !retired }
    func field(_ key: ReferenceWritableKeyPath<MergeRegexFilterEditModel, String>) -> Binding<String> {
        let current = generation
        return Binding(get: { self[keyPath: key] }, set: { [weak self] text in
            guard let self, self.canEdit, self.generation == current else { return }
            self[keyPath: key] = text
        })
    }
    func accept() {
        guard canEdit else { return }
        let filter = value
        // macOS storage needs a usable named section, as does the source menu.
        guard !filter.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a name for the filter."; return }
        generation += 1; let current = generation, token = OperationCancellation(), executable = executable
        cancellation = token; validating = true; error = nil
        MergeRegexOperations.activeRequests += 1
        Task {
            defer { MergeRegexOperations.activeRequests -= 1 }
            let result = await Task.detached { Result { try MergeRegexFilters.validate(filter, executable: executable, cancellation: token) } }.value
            guard !retired, generation == current else { return }
            validating = false; cancellation = nil
            guard value == filter else { error = "The filter changed during validation. Validate it again."; return }
            switch result {
            case .success:
                // Retire delivery before callbacks: repeated OK and reentrant
                // parent changes must never accept this child a second time.
                retire(); accepted(filter); close()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    func cancel() { guard !retired else { return }; retire(); close() }
    func retire() {
        guard !retired else { return }; retired = true; generation += 1
        cancellation?.cancel(); cancellation = nil; validating = false
        // Actual operation accounting remains owned by the suspended task.
    }
}

@MainActor final class MergeRegexFilterListController: NSWindowController, NSWindowDelegate {
    static private(set) var activeEditors = 0
    let model: MergeRegexFilterListModel
    private(set) var editor: MergeRegexFilterEditController?
    var onClosed: () -> Void = {}
    var executable: URL?
    private var retired = false
    private final class Transfer {
        let context: MergeRegexFilterListModel.Context
        let data: Data?
        let token = OperationCancellation()
        var panel: NSSavePanel?
        var delivered = false
        var working = false
        var settled = false
        var task: Task<Void,Never>?
        init(context: MergeRegexFilterListModel.Context, data: Data?) { self.context=context;self.data=data }
    }
    private var transfer: Transfer?
    var presentOpen: ((NSOpenPanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    var presentSave: ((NSSavePanel,NSWindow,@escaping (NSApplication.ModalResponse)->Void)->Void)?
    var chosenOpenURL: (NSOpenPanel)->URL? = { $0.url }
    var chosenSaveURL: (NSSavePanel)->URL? = { $0.url }
    var startScope: (URL)->Bool = { $0.startAccessingSecurityScopedResource() }
    var stopScope: (URL)->Void = { $0.stopAccessingSecurityScopedResource() }
    var readFile: (URL,URL?,OperationCancellation) async throws -> [MergeRegexFilter] = { url,helper,token in
        try await Task.detached { try MergeRegexFilters.readINI(url,executable:helper,cancellation:token) }.value
    }
    var writeFile: (Data,URL,OperationCancellation) async throws -> Void = { data,url,token in
        try await Task.detached { try MergeRegexFilters.writeINI(data,to:url,cancellation:token) }.value
    }
    init(defaults: UserDefaults = .standard) {
        model = MergeRegexFilterListModel(defaults: defaults)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 570, height: 350), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Regex Filters"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 450, height: 290)
        super.init(window: window); window.delegate = self; window.center()
        window.contentViewController = NSHostingController(rootView: MergeRegexFilterListView(model: model))
        model.edit = { [weak self] in self?.edit($0) }; model.close = { [weak self] in self?.window?.performClose(nil) }
        model.importFile = { [weak self] in self?.chooseTransfer(exporting:false,context:$0) }
        model.exportFile = { [weak self] in self?.chooseTransfer(exporting:true,context:$0) }
        model.cancelTransfer = { [weak self] context in guard self?.transfer?.context == context else { return }; self?.cancelFileTransfer() }
    }
    private func edit(_ filter: MergeRegexFilter?) {
        guard !retired, editor == nil, let window, window.attachedSheet == nil,
              let session = model.beginEdit(filter) else { return }
        let child = MergeRegexFilterEditController(filter: filter, executable: executable)
        editor = child; Self.activeEditors += 1
        child.finished = { [weak self, weak child] value in
            guard let self, self.editor === child else { return }
            if let sheet = child?.window, sheet.sheetParent === self.window { self.window?.endSheet(sheet, returnCode: value == nil ? .cancel : .OK) }
            self.editor = nil; Self.activeEditors -= 1
            self.model.finishEdit(session, value: value)
        }
        window.beginSheet(child.window!) { [weak child] _ in child?.cancel() }
    }
    private func chooseTransfer(exporting: Bool, context: MergeRegexFilterListModel.Context) {
        guard !retired, transfer == nil, editor == nil, let window, window.attachedSheet == nil,
              let accepted = model.beginTransfer(context:context) else { return }
        let data: Data?
        do { data = exporting ? try MergeRegexFilters.encodeINI(accepted.filters) : nil }
        catch { model.finishTransfer(context:accepted,failure:error.localizedDescription);return }
        let request=Transfer(context:accepted,data:data);transfer=request;MergeRegexOperations.activeRequests += 1
        if exporting {
            let panel=NSSavePanel();request.panel=panel;panel.nameFieldStringValue="regexfilters.ini";panel.canCreateDirectories=true;panel.allowsOtherFileTypes=true
            panel.allowedContentTypes=[UTType(filenameExtension:"ini") ?? .plainText]
            let reply: (NSApplication.ModalResponse)->Void = { [weak self,weak request,weak panel] response in
                guard let self,let request,let panel else { return };self.receiveTransfer(request,response:response,url:self.chosenSaveURL(panel))
            }
            if let presentSave { presentSave(panel,window,reply) } else { panel.beginSheetModal(for:window,completionHandler:reply) }
        } else {
            let panel=NSOpenPanel();request.panel=panel;panel.canChooseDirectories=false;panel.canChooseFiles=true;panel.allowsMultipleSelection=false
            panel.allowedContentTypes=[UTType(filenameExtension:"ini") ?? .plainText];panel.allowsOtherFileTypes=true
            let reply: (NSApplication.ModalResponse)->Void = { [weak self,weak request,weak panel] response in
                guard let self,let request,let panel else { return };self.receiveTransfer(request,response:response,url:self.chosenOpenURL(panel))
            }
            if let presentOpen { presentOpen(panel,window,reply) } else { panel.beginSheetModal(for:window,completionHandler:reply) }
        }
    }
    private func dismissPanel(_ request: Transfer) {
        guard let panel=request.panel else { return };request.panel=nil
        if let parent=panel.sheetParent { parent.endSheet(panel,returnCode:.cancel) };panel.orderOut(nil)
    }
    private func receiveTransfer(_ request: Transfer, response: NSApplication.ModalResponse, url: URL?) {
        guard transfer === request, !request.delivered, !request.settled, !retired else { return }
        request.delivered=true;dismissPanel(request)
        guard response == .OK, let url else { finishTransfer(request);return }
        request.working=true
        let scoped=startScope(url),release=stopScope,read=readFile,write=writeFile,helper=executable
        request.task=Task { [self] in
            defer { if scoped { release(url) };finishTransfer(request);request.task=nil }
            do {
                if let data=request.data { try await write(data,url,request.token) }
                else {
                    let imported=try await read(url,helper,request.token)
                    guard !retired,!request.token.isCancelled else { return }
                    model.finishTransfer(context:request.context,imported:imported)
                }
            } catch {
                if !retired,!request.token.isCancelled { model.finishTransfer(context:request.context,failure:error.localizedDescription) }
            }
        }
    }
    private func finishTransfer(_ request: Transfer) {
        guard transfer === request, !request.settled else { return }
        request.settled=true;request.delivered=true;dismissPanel(request);transfer=nil
        MergeRegexOperations.activeRequests -= 1;model.finishTransfer(context:request.context)
    }
    private func cancelFileTransfer() {
        guard let request=transfer else { return };request.delivered=true;request.token.cancel();request.task?.cancel();dismissPanel(request)
        if !request.working { finishTransfer(request) }
    }
    func retire() { window?.close(); retireOwnedState() }
    private func retireOwnedState() {
        guard !retired else { return }; retired = true; model.retire(); cancelFileTransfer()
        editor?.cancel(); editor = nil
        model.edit = { _ in }; model.close = {}
        let callback = onClosed; onClosed = {}; callback()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { editor == nil && transfer == nil && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { retireOwnedState() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class MergeRegexFilterEditController: NSWindowController, NSWindowDelegate {
    let model: MergeRegexFilterEditModel
    var finished: (MergeRegexFilter?) -> Void = { _ in }
    private var settled = false
    init(filter: MergeRegexFilter?, executable: URL? = nil) {
        model = MergeRegexFilterEditModel(filter: filter); model.executable = executable
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 570, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Regex Filter"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentViewController = NSHostingController(rootView: MergeRegexFilterEditView(model: model).frame(width: 570, height: 230))
        model.accepted = { [weak self] value in self?.finish(value) }
        model.close = { [weak self] in self?.cancel() }
    }
    func cancel() { finish(nil) }
    private func finish(_ value: MergeRegexFilter?, closing: Bool = false) {
        guard !settled else { return }; settled = true; model.retire()
        let callback = finished; finished = { _ in }; callback(value)
        model.accepted = { _ in }; model.close = {}
        if !closing { window?.close() }
    }
    func windowWillClose(_ notification: Notification) { finish(nil, closing: true) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct MergeRegexFilterListView: View {
    @ObservedObject var model: MergeRegexFilterListModel
    var body: some View {
        let context = model.context, selected = model.selected
        VStack(alignment: .leading, spacing: 10) {
            Table(model.filters, selection: Binding(get: { model.selection }, set: { if model.current(context) { model.selection = $0 } })) { TableColumn("Regex", value: \.name) }
                .contextMenu(forSelectionType: String.self) { selection in
                    let filter = context.filters.first { $0.id == selection.first }
                    Button { if let filter { model.requestEdit(filter, context: context) } } label: { CommandLabel(title: "Edit Filter", icon: .settingsGeneral) }.disabled(selection.count != 1 || !model.canEdit)
                    Button { if let filter { model.remove(filter, context: context) } } label: { CommandLabel(title: "Delete Filter", icon: .remove) }.disabled(selection.count != 1 || !model.canEdit)
                } primaryAction: { selection in
                    if selection.count == 1, let filter = context.filters.first(where: { $0.id == selection.first }) { model.requestEdit(filter, context: context) }
                }
                .disabled(!model.canEdit)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if model.transferring { HStack { ProgressView().controlSize(.small); Text("Transferring filters…"); Button("Cancel operation") { model.cancelTransfer(context) } } }
            HStack {
                Spacer()
                Button { model.requestEdit(nil, context: context) } label: { CommandLabel(title: "Add Filter", icon: .add) }
                Button { if let selected { model.requestEdit(selected, context: context) } } label: { CommandLabel(title: "Edit Filter", icon: .settingsGeneral) }.disabled(selected == nil)
                Button { if let selected { model.remove(selected, context: context) } } label: { CommandLabel(title: "Delete Filter", icon: .remove) }.disabled(selected == nil)
            }.disabled(!model.canEdit)
            HStack {
                Menu("Filter Files") {
                    Button { model.importFile(context) } label: { CommandLabel(title:"Import Filters…",icon:.patch) }
                    Button { model.exportFile(context) } label: { CommandLabel(title:"Export Filters…",icon:.export) }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer(); Button("OK") { if model.current(context) { model.saveAndClose() } }.keyboardShortcut(.defaultAction); Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }.disabled(!model.canEdit)
        }.padding(14)
    }
}
private struct MergeRegexFilterEditView: View {
    @ObservedObject var model: MergeRegexFilterEditModel
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading) {
                GridRow { Text("Name:").frame(width: 75, alignment: .leading); TextField("Name", text: model.field(\.name)).focused($nameFocused).accessibilityLabel("Filter name") }
                GridRow { Text("Regex:"); TextField("Regex", text: model.field(\.expression)).font(.system(.body, design: .monospaced)).accessibilityLabel("Filter regular expression") }
                GridRow { Text("Replace:"); TextField("Replace", text: model.field(\.replacement)).font(.system(.body, design: .monospaced)).accessibilityLabel("Filter replacement") }
            }.disabled(!model.canEdit)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                if model.validating { ProgressView().controlSize(.small) }
                Spacer(); Button("OK") { model.accept() }.keyboardShortcut(.defaultAction).disabled(!model.canEdit)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.retired)
            }
        }.padding(16).onAppear { nameFocused = true }
    }
}
