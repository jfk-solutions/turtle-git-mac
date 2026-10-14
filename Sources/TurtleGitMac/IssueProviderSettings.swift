// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class IssueProviderSettingsModel: ObservableObject {
    let preferences: UserDefaults
    @Published var rows: [NativeIssueAssociation] = []
    @Published var selection: Set<UUID> = []
    @Published private(set) var hasChild = false
    @Published private(set) var loaded = false
    @Published var error: String?
    private var saved: [NativeIssueAssociation] = []
    private(set) var editor: IssueProviderAssociationEditor?
    weak var window: NSWindow?
    var modified: Bool { rows != saved }
    var chosen: NativeIssueAssociation? { guard selection.count == 1, let id = selection.first else { return nil }; return rows.first { $0.id == id } }
    init(preferences: UserDefaults = .standard) { self.preferences = preferences; do { saved = try NativeIssueAssociations.load(from: preferences); rows = saved; loaded = true } catch { self.error = error.localizedDescription } }
    func edit(copy: Bool = false, root: URL? = nil) {
        guard loaded, !hasChild, let window, window.attachedSheet == nil else { return }
        var value = chosen ?? NativeIssueAssociation(path: root?.path ?? "")
        if copy { value.id = UUID() }
        let controller = IssueProviderAssociationEditor(association: value) { [weak self] row in
            guard let self else { return }; self.editor = nil; self.hasChild = false
            if let row { if let index = self.rows.firstIndex(where: { $0.id == row.id }) { self.rows[index] = row } else { self.rows.append(row) }; self.selection = [row.id] }
        }
        editor = controller; hasChild = true
        if let sheet = controller.window { window.beginSheet(sheet) } else { controller.close() }
    }
    func add(root: URL?) { guard !hasChild else { return }; selection = []; edit(root: root) }
    func remove() { guard loaded, !hasChild else { return }; rows.removeAll { selection.contains($0.id) }; selection = [] }
    func apply() -> Bool {
        guard loaded, !hasChild else { return false }
        do {
            for row in rows where row.enabled && !saved.contains(row) { try NativeIssueAssociations.validate(row) }
            try NativeIssueAssociations.save(rows, to: preferences); saved = rows; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func cancel() { guard !hasChild else { return }; rows = saved; selection.formIntersection(Set(rows.map(\.id))); error = nil }
    func suspend() { editor?.close(); editor = nil; hasChild = false }
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
                TableColumn("Provider") { row in Text(row.provider == NativeIssueCatalogProvider.identifier ? NativeIssueCatalogProvider.name : row.provider) }
                TableColumn("Parameters", value: \.parameters)
            }.disabled(model.hasChild || !model.loaded)
            .contextMenu(forSelectionType: UUID.self) { _ in Button("Edit…") { model.edit() }.disabled(model.chosen == nil) } primaryAction: { ids in model.selection = ids; model.edit() }
            HStack {
                Button { model.add(root: workspace.root) } label: { CommandLabel(title: "Add…", icon: .add) }
                Button("Edit…") { model.edit() }.disabled(model.chosen == nil)
                Button { model.edit(copy: true) } label: { CommandLabel(title: "Copy…", icon: .copy) }.disabled(model.chosen == nil)
                Button { model.remove() } label: { CommandLabel(title: "Remove", icon: .remove) }.disabled(model.selection.isEmpty)
            }.disabled(model.hasChild || !model.loaded)
            Text("Enabled associations match the exact working-tree folder. They take priority over project provider configuration. Native providers are embedded in TurtleGit; Windows COM provider settings remain separate.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).background(IssueProviderSettingsWindowProbe(model: model).frame(width: 0, height: 0))
        .settingsParticipant("issueProviders", page: .issueProviders, value: model.rows, modified: { model.modified }, validate: { model.loaded ? nil : model.error }, apply: { model.apply() }, cancel: model.cancel)
        .onChange(of: model.hasChild) { _ in transaction?.notify() }.onDisappear { model.suspend() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in if let window = notification.object as? NSWindow, window === model.window { model.suspend() } }
    }
}
private struct IssueProviderSettingsWindowProbe: NSViewRepresentable {
    let model: IssueProviderSettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { model.window = view.window }
    final class Probe: NSView { weak var model: IssueProviderSettingsModel?; override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.window = window } }
}
