// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

extension Notification.Name {
    static let mergeRegexFiltersChanged = Notification.Name("TurtleGitMerge.RegexFiltersChanged")
}
@MainActor enum MergeRegexOperations { static var activeRequests = 0 }

@MainActor final class MergeRegexFilterListModel: ObservableObject {
    @Published private(set) var filters: [MergeRegexFilter]
    @Published var selection: String?
    @Published var error: String?
    var edit: (MergeRegexFilter?) -> Void = { _ in }
    var close: () -> Void = {}
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; filters = MergeRegexFilters.load(defaults: defaults) }
    var selected: MergeRegexFilter? { filters.first { $0.id == selection } }
    func accept(_ filter: MergeRegexFilter, oldName: String?) {
        filters = MergeRegexFilters.updating(filters, oldName: oldName, filter: filter); selection = filter.id
    }
    func remove() {
        guard let selected else { return }
        filters.removeAll { $0.id == selected.id }; selection = nil
    }
    func saveAndClose() {
        do {
            try MergeRegexFilters.save(filters, defaults: defaults); error = nil
            NotificationCenter.default.post(name: .mergeRegexFiltersChanged, object: defaults)
            close()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class MergeRegexFilterEditModel: ObservableObject {
    @Published var name: String
    @Published var expression: String
    @Published var replacement: String
    @Published private(set) var validating = false
    @Published private(set) var error: String?
    private var generation = 0, retired = false
    private var cancellation: OperationCancellation?
    var executable: URL?
    var accepted: (MergeRegexFilter) -> Void = { _ in }
    var close: () -> Void = {}
    init(filter: MergeRegexFilter?) {
        name = filter?.name ?? ""; expression = filter?.expression ?? ""; replacement = filter?.replacement ?? ""
    }
    func accept() {
        guard !validating, !retired else { return }
        let filter = MergeRegexFilter(name: name, expression: expression, replacement: replacement)
        // macOS storage needs a usable named section, as does the source menu.
        guard !filter.name.isEmpty else { error = "Enter a name for the filter."; return }
        generation += 1; let current = generation, token = OperationCancellation(), executable = executable
        cancellation = token; validating = true; error = nil
        MergeRegexOperations.activeRequests += 1
        Task {
            defer { MergeRegexOperations.activeRequests -= 1 }
            let result = await Task.detached { Result { try MergeRegexFilters.validate(filter, executable: executable, cancellation: token) } }.value
            guard !retired, generation == current else { return }
            validating = false; cancellation = nil
            switch result {
            case .success: accepted(filter); close()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    func retire() { retired = true; generation += 1; cancellation?.cancel(); cancellation = nil }
}

@MainActor final class MergeRegexFilterListController: NSWindowController, NSWindowDelegate {
    let model: MergeRegexFilterListModel
    private var editor: NSWindowController?
    private var editorModel: MergeRegexFilterEditModel?
    var onClosed: () -> Void = {}
    var executable: URL?
    init(defaults: UserDefaults = .standard) {
        model = MergeRegexFilterListModel(defaults: defaults)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 570, height: 350), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Regex Filters"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 450, height: 290)
        super.init(window: window); window.delegate = self; window.center()
        window.contentViewController = NSHostingController(rootView: MergeRegexFilterListView(model: model))
        model.edit = { [weak self] in self?.edit($0) }; model.close = { [weak self] in self?.window?.performClose(nil) }
    }
    private func edit(_ filter: MergeRegexFilter?) {
        guard editor == nil, let window, window.attachedSheet == nil else { return }
        let model = MergeRegexFilterEditModel(filter: filter); model.executable = executable
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 550, height: 225), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Regex Filter"; sheet.isReleasedWhenClosed = false
        sheet.contentViewController = NSHostingController(rootView: MergeRegexFilterEditView(model: model))
        let controller = NSWindowController(window: sheet); editor = controller; editorModel = model
        model.accepted = { [weak self] value in self?.model.accept(value, oldName: filter?.name) }
        model.close = { [weak self, weak sheet, weak model] in
            guard let self, let sheet else { return }; model?.retire()
            self.window?.endSheet(sheet); sheet.close(); self.editor = nil; self.editorModel = nil
        }
        window.beginSheet(sheet)
    }
    func retire() {
        editorModel?.retire(); editorModel?.accepted = { _ in }; editorModel?.close = {}
        if let sheet = editor?.window { window?.endSheet(sheet, returnCode: .cancel); sheet.close() }
        editor = nil; editorModel = nil; window?.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        editorModel?.retire(); model.edit = { _ in }; model.close = {}; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct MergeRegexFilterListView: View {
    @ObservedObject var model: MergeRegexFilterListModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(model.filters, selection: $model.selection) { TableColumn("Regex", value: \.name) }
                .contextMenu(forSelectionType: String.self) { selection in
                    Button { model.selection = selection.first; if let filter = model.selected { model.edit(filter) } } label: { CommandLabel(title: "Edit Filter", icon: .settingsGeneral) }.disabled(selection.count != 1)
                    Button { model.selection = selection.first; model.remove() } label: { CommandLabel(title: "Delete Filter", icon: .remove) }.disabled(selection.count != 1)
                } primaryAction: { selection in model.selection = selection.first; if let filter = model.selected { model.edit(filter) } }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Add Filter") { model.edit(nil) }
                Button("Edit Filter") { if let filter = model.selected { model.edit(filter) } }.disabled(model.selected == nil)
                Button("Delete Filter") { model.remove() }.disabled(model.selected == nil)
            }
            HStack { Spacer(); Button("OK") { model.saveAndClose() }.keyboardShortcut(.defaultAction); Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction) }
        }.padding(14)
    }
}
private struct MergeRegexFilterEditView: View {
    @ObservedObject var model: MergeRegexFilterEditModel
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading) {
                GridRow { Text("Name:").frame(width: 75, alignment: .leading); TextField("Name", text: $model.name).focused($nameFocused) }
                GridRow { Text("Regex:"); TextField("Regex", text: $model.expression).font(.system(.body, design: .monospaced)) }
                GridRow { Text("Replace:"); TextField("Replace", text: $model.replacement).font(.system(.body, design: .monospaced)) }
            }.disabled(model.validating)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            Spacer()
            HStack {
                if model.validating { ProgressView().controlSize(.small) }
                Spacer(); Button("OK") { model.accept() }.keyboardShortcut(.defaultAction).disabled(model.validating)
                Button("Cancel") { model.retire(); model.close() }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).onAppear { nameFocused = true }
    }
}
