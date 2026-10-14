// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class IssueProviderPickerController: NSWindowController, NSWindowDelegate {
    let model: IssueProviderPickerModel
    private var completion: ((NativeIssueProviderResult?) -> Void)?
    init(provider: NativeIssueCatalogProvider, context: NativeIssueProviderContext, completion: @escaping (NativeIssueProviderResult?) -> Void) {
        model = IssueProviderPickerModel(provider: provider, context: context); self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = provider.linkText; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 500, height: 300)
        window.contentViewController = NSHostingController(rootView: IssueProviderPickerDialog(model: model))
        super.init(window: window); window.delegate = self; window.center(); DialogGeometry.attach(window, identifier: "TurtleGit.IssueProviderPicker")
        model.accept = { [weak self] in guard let self, let result = self.model.result else { return }; self.finish(result) }
        model.cancel = { [weak self] in self?.finish(nil) }
    }
    func finish(_ value: NativeIssueProviderResult?) { guard let completion else { return }; self.completion = nil; if let window { window.sheetParent?.endSheet(window); window.close() }; completion(value) }
    override func close() { finish(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(nil); return false }
    func windowWillClose(_ notification: Notification) { let completion = completion; self.completion = nil; completion?(nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class IssueProviderPickerModel: ObservableObject {
    let provider: NativeIssueCatalogProvider
    let context: NativeIssueProviderContext
    @Published var query = ""
    @Published var selected: Set<String>
    var accept: () -> Void = {}
    var cancel: () -> Void = {}
    init(provider: NativeIssueCatalogProvider, context: NativeIssueProviderContext) { self.provider = provider; self.context = context; selected = provider.selectedIDs(in: context.issueID) }
    var rows: [NativeIssueCatalogItem] { provider.issues.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) } }
    var result: NativeIssueProviderResult? { try? provider.commitMessage(context: context, selected: selected) }
}
private struct IssueProviderPickerDialog: View {
    @ObservedObject var model: IssueProviderPickerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.context.repositoryRoot.path).font(.caption).textSelection(.enabled)
            HStack { Text("Filter:"); TextField("Issue ID or summary", text: $model.query) }
            Table(model.rows, selection: $model.selected) { TableColumn("Issue ID", value: \.id).width(min: 80, ideal: 120); TableColumn("Summary", value: \.summary) }
            Text("\(model.selected.count) issue(s) selected · \(model.context.paths.count) path(s)").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction); Button("OK") { model.accept() }.keyboardShortcut(.defaultAction).disabled(model.result == nil) }
        }.padding(16)
    }
}

@MainActor final class IssueProviderAssociationEditor: NSWindowController, NSWindowDelegate {
    let model: IssueProviderAssociationDraft
    private var completion: ((NativeIssueAssociation?) -> Void)?
    private var panel: NSOpenPanel?
    init(association: NativeIssueAssociation, completion: @escaping (NativeIssueAssociation?) -> Void) {
        model = IssueProviderAssociationDraft(association); self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 390), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Issue tracker integration"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 620, height: 320)
        window.contentViewController = NSHostingController(rootView: IssueProviderAssociationDialog(model: model))
        super.init(window: window); window.delegate = self; window.center(); DialogGeometry.attach(window, identifier: "SetBugTraqAdvDlg")
        model.accept = { [weak self] in guard let self, self.completion != nil else { return }; do { try NativeIssueAssociations.validate(self.model.row); self.finish(self.model.row) } catch { self.model.error = error.localizedDescription } }
        model.cancel = { [weak self] in self?.finish(nil) }; model.browse = { [weak self] in self?.browse() }
    }
    private func browse() {
        guard panel == nil, let window, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.canChooseFiles = false; chooser.canChooseDirectories = true; chooser.directoryURL = URL(fileURLWithPath: model.row.path); chooser.prompt = "Choose working tree"; panel = chooser; model.choosing = true
        chooser.beginSheetModal(for: window) { [weak self] response in guard let self, self.panel === chooser else { return }; self.panel = nil; self.model.choosing = false; if response == .OK, let url = chooser.url { self.model.row.path = url.path } }
    }
    func finish(_ row: NativeIssueAssociation?) { guard let completion else { return }; self.completion = nil; if let panel { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil; if let window { window.sheetParent?.endSheet(window); window.close() }; completion(row) }
    override func close() { finish(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { guard panel == nil else { return false }; finish(nil); return false }
    func windowWillClose(_ notification: Notification) { if let panel { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil; let completion = completion; self.completion = nil; completion?(nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class IssueProviderAssociationDraft: ObservableObject {
    @Published var row: NativeIssueAssociation
    @Published var choosing = false
    @Published var error: String?
    @Published var options = false
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
            Picker("Provider", selection: $model.row.provider) { Text(NativeIssueCatalogProvider.name).tag(NativeIssueCatalogProvider.identifier); if model.row.provider != NativeIssueCatalogProvider.identifier { Text(model.row.provider + " (unavailable)").tag(model.row.provider) } }.labelsHidden()
            HStack { Text("Parameters:"); Spacer(); Button("Options…") { model.options = true } }
            TextEditor(text: $model.row.parameters).font(.system(.body, design: .monospaced)).frame(minHeight: 80).border(Color.secondary.opacity(0.4))
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction); Button("OK") { model.accept() }.keyboardShortcut(.defaultAction) }
        }.padding(16).disabled(model.choosing).sheet(isPresented: $model.options) { IssueProviderOptionsDraft(parameters: $model.row.parameters) }
    }
}
private struct IssueProviderOptionsDraft: View {
    @Binding var parameters: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    private var error: String? { do { _ = try NativeIssueCatalogProvider(parameters: draft); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Native issue catalog options").font(.headline)
            Text("JSON fields: linkText, messageTemplate (%BUGID%), requireIssue, and issues with id/summary. An empty messageTemplate updates only the issue field.").font(.caption)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.4))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Example") { draft = NativeIssueCatalogProvider.exampleParameters }; Spacer(); Button("Cancel") { dismiss() }; Button("OK") { parameters = draft; dismiss() }.disabled(error != nil) }
        }.padding(16).frame(width: 720, height: 420).onAppear { draft = parameters }
    }
}
