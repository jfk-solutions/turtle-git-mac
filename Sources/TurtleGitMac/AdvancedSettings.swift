import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class AdvancedSettingsModel: ObservableObject {
    let store: AdvancedSettingsStore
    @Published var values: [String: String]
    @Published var error: String?
    @Published private var original: [String: String]
    var onApplied: () -> Void = {}
    var modified: Bool { values != original }
    init(defaults: UserDefaults = .standard) {
        store = AdvancedSettingsStore(defaults: defaults); let initial = store.values(); original = initial; values = initial
    }
    func edit(_ name: String, text: String) -> Bool {
        guard let setting = AdvancedSettingDefinition.all.first(where: { $0.name == name }), setting.accepts(text) else { return false }
        values[name] = text; return true
    }
    func apply() {
        do { try store.apply(values.filter { original[$0.key] != $0.value }); original = values; onApplied() }
        catch { self.error = error.localizedDescription }
    }
    func cancel() { original = store.values(); values = original; error = nil }
}

struct AdvancedSettingsPage: View {
    @StateObject private var model = AdvancedSettingsModel()
    @StateObject private var windowReference = AdvancedSettingsWindowReference()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdvancedSettingsTable(model: model)
            Text("WARNING:\nOnly change these settings if you are absolutely sure what you are doing!\nTo set the values to their default, delete the value text.")
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer()
                Button("Cancel") { windowReference.window?.makeFirstResponder(nil); model.cancel(); windowReference.window?.performClose(nil) }
                Button("Apply") { windowReference.window?.makeFirstResponder(nil); model.apply() }.disabled(!model.modified)
            }
        }.padding(20)
        .onAppear { if !model.modified { model.cancel() }; model.onApplied = { for window in NSApp.windows { if let view = window.contentView { Self.invalidate(view) } } } }
        .alert("Advanced Settings", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let closed = notification.object as? NSWindow, closed === windowReference.window { model.cancel() }
        }
        .background(AdvancedWindowProbe(reference: windowReference))
    }
    private static func invalidate(_ view: NSView) { view.needsDisplay = true; for child in view.subviews { invalidate(child) } }
}

struct AdvancedSettingsTable: NSViewRepresentable {
    @ObservedObject var model: AdvancedSettingsModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.model = model; context.coordinator.table?.reloadData() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AdvancedSettingsModel
        weak var table: NSTableView?
        init(model: AdvancedSettingsModel) { self.model = model }
        func makeScrollView() -> NSScrollView {
            let table = AdvancedTableView(); table.rowHeight = 23; table.allowsMultipleSelection = false; table.allowsColumnReordering = false
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            for (id, title, width) in [("name", "Name", 420.0), ("value", "Value", 130.0)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
                column.isEditable = id == "value"; column.minWidth = 80; table.addTableColumn(column)
            }
            table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(beginEdit)
            table.setAccessibilityLabel("Advanced settings")
            self.table = table
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.borderType = .bezelBorder; scroll.documentView = table; return scroll
        }
        func numberOfRows(in tableView: NSTableView) -> Int { AdvancedSettingDefinition.all.count }
        func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
            guard AdvancedSettingDefinition.all.indices.contains(row) else { return nil }
            let setting = AdvancedSettingDefinition.all[row]
            return column?.identifier.rawValue == "name" ? setting.name : model.values[setting.name]
        }
        func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for column: NSTableColumn?, row: Int) {
            guard column?.identifier.rawValue == "value", AdvancedSettingDefinition.all.indices.contains(row), let text = object as? String else { return }
            if !model.edit(AdvancedSettingDefinition.all[row].name, text: text) { NSSound.beep() }
            tableView.reloadData()
        }
        func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
            guard AdvancedSettingDefinition.all.indices.contains(row) else { return "" }
            let setting = AdvancedSettingDefinition.all[row]
            let effective: Set<String> = ["AutoCompleteMinChars", "AutocompleteParseMaxSize", "AutocompleteParseUnversioned", "AutocompleteRemovesExtensions", "StyleCommitMessages", "ShowListBackgroundImage", "ShowAppContextMenuIcons"]
            return effective.contains(setting.name) ? setting.name : "This preference has no effect on TurtleGit yet."
        }
        @objc func beginEdit() {
            guard let table, table.selectedRow >= 0 else { return }
            let valueColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("value"))
            guard valueColumn >= 0 else { return }
            table.editColumn(valueColumn, row: table.selectedRow, with: nil, select: true)
        }
    }
}

private final class AdvancedTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 120, let coordinator = delegate as? AdvancedSettingsTable.Coordinator { coordinator.beginEdit(); return }
        super.keyDown(with: event)
    }
}

@MainActor private final class AdvancedSettingsWindowReference: ObservableObject {
    weak var window: NSWindow?
}

private struct AdvancedWindowProbe: NSViewRepresentable {
    let reference: AdvancedSettingsWindowReference
    func makeNSView(context: Context) -> NSView { let view = Probe(); view.reference = reference; return view }
    func updateNSView(_ view: NSView, context: Context) { reference.window = view.window }
    private final class Probe: NSView {
        var reference: AdvancedSettingsWindowReference?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reference?.window = window }
    }
}
