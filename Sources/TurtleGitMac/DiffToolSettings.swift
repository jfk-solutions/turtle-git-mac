// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class ToolApplicationChooser {
    weak var window: NSWindow?
    private var panel: NSOpenPanel?
    func cancel() { if let panel { (panel.sheetParent ?? window)?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil }
    func choose(_ completion: @escaping (URL, Data) -> Void, failure: @escaping (String) -> Void, allowExecutables: Bool = false) {
        guard let window, panel == nil, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.allowedContentTypes = allowExecutables ? [] : [.applicationBundle]; chooser.allowsOtherFileTypes = allowExecutables
        chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false
        chooser.title = allowExecutables ? "Select tool application or executable" : "Select tool application"; chooser.prompt = "Select"; chooser.directoryURL = URL(fileURLWithPath: "/Applications")
        panel = chooser
        chooser.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.panel === chooser else { return }; self.panel = nil
            guard response == .OK, let application = chooser.url else { return }
            do { completion(application, try application.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) }
            catch { failure(error.localizedDescription) }
        }
    }
}
struct ToolChooserProbe: NSViewRepresentable {
    let chooser: ToolApplicationChooser
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.chooser = chooser; return probe }
    func updateNSView(_ view: Probe, context: Context) { chooser.window = view.window }
    final class Probe: NSView {
        weak var chooser: ToolApplicationChooser?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); chooser?.window = window }
    }
}
struct DiffProgramForm: View {
    @Binding var program: DiffToolProgram
    var tool = "diff"
    @State private var chooser = ToolApplicationChooser()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(tool == "merge" ? "Merge tool" : "Diff tool", selection: Binding(get: { !program.enabled ? "internal" : program.builtIn?.rawValue ?? "external" }, set: { value in
                program.enabled = value != "internal"
                if value != "internal" { program.builtIn = BuiltInDiffTool(rawValue: value) }
            })) {
                Text("TurtleGitMerge").tag("internal"); Text("External").tag("external")
                ForEach(tool == "merge" ? [.wordDocument, .libreOfficeDocument] : BuiltInDiffTool.allCases, id: \.self) { value in
                    Text(tool == "merge" ? (value == .wordDocument ? "Microsoft Word document merge" : "LibreOffice document merge") : value.title).tag(value.rawValue)
                }
            }.pickerStyle(.radioGroup).labelsHidden()
            HStack {
                TextField("Application or executable", text: Binding(get: { program.applicationPath }, set: { guard program.applicationPath != $0 else { return }; program.applicationPath = $0; program.bookmark = nil }))
                Button("Browse…") { chooser.choose({ application, bookmark in program.applicationPath = application.path; program.bookmark = bookmark }, failure: { error = $0 }, allowExecutables: true) }
            }.disabled(!program.enabled || program.builtIn != nil)
            TextField("Arguments", text: $program.arguments).disabled(!program.enabled || program.builtIn != nil)
            if !program.valid { Text(DiffToolFailure.application.localizedDescription).foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red) }
        }.background(ToolChooserProbe(chooser: chooser).frame(width: 0, height: 0)).onDisappear { chooser.cancel() }
    }
}
@MainActor final class ToolSettingsDraft<Value: Equatable>: ObservableObject {
    @Published var value: Value
    @Published private(set) var error: String?
    private var saved: Value
    private let valid: (Value) -> Bool
    private let persist: (Value) throws -> Void
    init(_ value: Value, valid: @escaping (Value) -> Bool, persist: @escaping (Value) throws -> Void) {
        self.value = value; saved = value; self.valid = valid; self.persist = persist
    }
    var modified: Bool { value != saved }
    var validationError: String? { valid(value) ? nil : "Review the application and file associations." }
    func apply() -> Bool {
        guard validationError == nil else { error = validationError; return false }
        do { try persist(value); saved = value; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func cancel() { value = saved; error = nil }
}

struct DiffToolSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    private let preferences: UserDefaults
    @StateObject private var model: ToolSettingsDraft<DiffToolPreferences>
    @State private var advanced = false
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        _model = StateObject(wrappedValue: ToolSettingsDraft(DiffToolPreferences.load(from: preferences), valid: { $0.valid }, persist: { try $0.save(to: preferences) }))
    }
    init(model: ToolSettingsDraft<DiffToolPreferences>, preferences: UserDefaults = .standard) { self.preferences = preferences; _model = StateObject(wrappedValue: model) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Configure the program used for comparing different revisions of files") {
                    VStack(alignment: .leading, spacing: 10) {
                        DiffProgramForm(program: $model.value.program)
                        HStack { Spacer(); Button("Advanced…") { advanced = true } }
                    }.padding(8)
                }
                Text("Arguments: %base, %mine, %bname, %yname, %bpath, %ypath, %brev, %yrev and %wtroot. Quote arguments containing spaces. Hold Shift when opening a comparison to reverse the internal/external choice.").font(.caption).foregroundStyle(.secondary)
                UnifiedDiffViewerSettings(settingsPage: .diff, preferences: preferences)
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }.padding(20)
        }
        .settingsParticipant("diff", page: .diff, value: model.value, modified: { model.modified }, validate: { model.validationError }, apply: { model.apply() }, cancel: model.cancel)
        .sheet(isPresented: $advanced) { DiffToolAssociations(associations: model.value.associations) { value in if let value { model.value.associations = value }; advanced = false } }
    }
}
@MainActor final class ToolAssociationsModel: ObservableObject {
    @Published var draft: [DiffToolAssociation]
    @Published var selected: UUID?
    @Published var editing: DiffToolAssociation?
    let tool: String
    init(associations: [DiffToolAssociation], tool: String) { draft = associations; self.tool = tool }
    var rows: [DiffToolAssociation] { draft.sorted { $0.normalizedPattern.localizedStandardCompare($1.normalizedPattern) == .orderedAscending } }
    var valid: Bool { draft.allSatisfy(\.valid) && Set(draft.map(\.normalizedPattern)).count == draft.count && (tool != "merge" || draft.allSatisfy { MergeToolPreferences.supports($0.program.builtIn) }) }
    func restoreDefaults() {
        guard editing == nil else { return }
        if tool == "merge" {
            var value=MergeToolPreferences(); value.associations=draft; value.restoreBundledAssociations(); draft=value.associations
            selected=draft.first { $0.normalizedPattern == ".docx" }?.id
        } else {
            var value=DiffToolPreferences(); value.associations=draft; value.restoreBundledAssociations(); draft=value.associations
            selected=draft.first { $0.normalizedPattern == ".zip" }?.id
        }
    }
    func add() {
        guard editing == nil else { return }
        var entry = DiffToolAssociation()
        if tool == "merge" { entry.program.arguments = "%base %theirs %mine %merged" }
        editing = entry
    }
    func edit() { guard editing == nil else { return }; editing = draft.first { $0.id == selected } }
    func accept(_ value: DiffToolAssociation?) {
        guard let original = editing else { return }
        defer { editing = nil }
        guard var value, value.id == original.id, value.valid,
              !draft.contains(where: { $0.id != value.id && $0.normalizedPattern == value.normalizedPattern }) else { return }
        value.pattern = value.normalizedPattern
        if let index = draft.firstIndex(where: { $0.id == value.id }) { draft[index] = value } else { draft.append(value) }
        selected = value.id
    }
    func remove() {
        guard editing == nil, let selected, let index = rows.firstIndex(where: { $0.id == selected }) else { return }
        let ordered = rows; draft.removeAll { $0.id == selected }
        let survivors = ordered.filter { $0.id != selected }
        self.selected = survivors.isEmpty ? nil : survivors[min(index, survivors.count - 1)].id
    }
}

struct DiffToolAssociations: View {
    @StateObject private var model: ToolAssociationsModel
    let completed: ([DiffToolAssociation]?) -> Void
    init(associations: [DiffToolAssociation], tool: String = "diff", completed: @escaping ([DiffToolAssociation]?) -> Void) {
        _model = StateObject(wrappedValue: ToolAssociationsModel(associations: associations, tool: tool)); self.completed = completed
    }
    init(model: ToolAssociationsModel, completed: @escaping ([DiffToolAssociation]?) -> Void) { _model = StateObject(wrappedValue: model); self.completed = completed }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced " + model.tool + " settings").font(.headline)
            ToolAssociationsTable(model: model).frame(minHeight: 240)
            if model.tool == "diff" { Text("Restore Defaults restores bundled archive, binary, Mathematica, Word, Excel and LibreOffice comparisons, preserving other associations. Office and Mathematica comparisons require those applications.").font(.caption).foregroundStyle(.secondary) }
            if model.tool == "merge" { Text("Restore Defaults restores Word document merging for .doc/.docx/.docm, preserving other associations. Review changes in Word and Save As the original conflicting file.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Add…", action: model.add)
                Button("Edit…", action: model.edit).disabled(model.selected == nil)
                Button("Remove", action: model.remove).disabled(model.selected == nil)
                Button("Restore Defaults", action: model.restoreDefaults)
                Spacer(); Button("Cancel") { completed(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { completed(model.draft) }.keyboardShortcut(.defaultAction).disabled(!model.valid)
            }.disabled(model.editing != nil)
        }.padding(20).frame(width: 720)
        .sheet(item: $model.editing) { entry in
            DiffToolAssociationEditor(entry: entry, existing: model.draft, tool: model.tool, completed: model.accept)
        }
    }
}

struct ToolAssociationsTable: NSViewRepresentable {
    @ObservedObject var model: ToolAssociationsModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(); table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 24
        table.setAccessibilityLabel("Advanced " + model.tool + " tool associations")
        for (identifier, title, width) in [("extension", "Extension", 160.0), ("program", "Program", 490.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.edit(_:))
        context.coordinator.table = table
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.model = model; coordinator.rows = model.rows
        guard let table = coordinator.table else { return }
        coordinator.updating = true; table.reloadData()
        if let index = coordinator.rows.firstIndex(where: { $0.id == model.selected }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        coordinator.updating = false
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil; coordinator.table?.target = nil; coordinator.table = nil
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: ToolAssociationsModel
        var rows: [DiffToolAssociation] = []
        var updating = false
        weak var table: NSTableView?
        init(model: ToolAssociationsModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let entry = rows[row], text: String
            if tableColumn?.identifier.rawValue == "extension" { text = entry.pattern }
            else if !entry.program.enabled { text = "TurtleGitMerge (external disabled)" }
            else { text = (model.tool == "merge" && entry.program.builtIn == .libreOfficeDocument ? "LibreOffice document merge" : entry.program.builtIn == .wordDocument && model.tool == "merge" ? "Microsoft Word document merge" : entry.program.displayName) + (entry.program.builtIn != nil || entry.program.arguments.isEmpty ? "" : " " + entry.program.arguments) }
            let cell = NSTableCellView(), field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingTail; field.toolTip = text
            field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field); cell.textField = field
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }; model.selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        }
        @objc func edit(_ sender: NSTableView) {
            guard rows.indices.contains(sender.clickedRow), model.editing == nil else { return }
            model.selected = rows[sender.clickedRow].id; model.edit()
        }
    }
}

private struct DiffToolAssociationEditor: View {
    @State private var draft: DiffToolAssociation
    let existing: [DiffToolAssociation]
    let tool: String
    let completed: (DiffToolAssociation?) -> Void
    init(entry: DiffToolAssociation, existing: [DiffToolAssociation], tool: String, completed: @escaping (DiffToolAssociation?) -> Void) { _draft = State(initialValue: entry); self.existing = existing; self.completed = completed; self.tool = tool }
    private var valid: Bool { draft.valid && !existing.contains { $0.id != draft.id && $0.normalizedPattern == draft.normalizedPattern } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((existing.contains { $0.id == draft.id } ? "Edit " : "Add ") + tool + " tool").font(.headline)
            TextField("Extension or filename", text: $draft.pattern)
            DiffProgramForm(program: $draft.program, tool: tool)
            if tool == "merge" { Text("Use .swift for an extension, or .filename for an exact filename.").font(.caption) }
            if !valid { Text("Choose a unique extension (such as .swift) or filename, and a valid program.").font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { completed(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { draft.pattern = draft.normalizedPattern; completed(draft) }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(20).frame(width: 600)
    }
}

@MainActor enum ExternalToolProcesses {
    private static var executions: [UUID: ExternalToolExecution] = [:]
    static var activeRequests: Int { executions.count }
    static func cancelAll() { for execution in executions.values { execution.cancel() } }
    static func start(_ executable: URL, arguments: [String], root: URL, permissions: [RepositoryAccessLease], cancellation: OperationCancellation? = nil) async throws -> ExternalToolExecution {
        let execution = try await ExternalToolExecution.start(executable: executable, arguments: arguments, directory: root, cancellation: cancellation ?? OperationCancellation())
        let id = UUID(); executions[id] = execution
        Task {
            defer { executions.removeValue(forKey: id); withExtendedLifetime(permissions) {} }
            _ = try? await execution.completion.value
        }
        return execution
    }
}

@MainActor enum DiffToolApplication {
    private static var previews: [URL] = []
    private static var inventoryWindows: [UUID: FileComparisonWindowController] = [:]
    private static var excelWarnings: [UUID: ExcelComparisonWarningController] = [:]
    static var presentExcelWarning: (ExcelComparisonWarningController) -> Bool = { controller in controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil);return true }
    static var compareExcel: (ExcelComparisonPreview,OperationCancellation) async throws -> ExcelComparisonOutcome = { try await ExcelComparisonAutomation.compare($0,cancellation:$1) }
    private static var binaryWindows: [UUID: BinaryComparisonWindowController] = [:]
    static var presentBinary: (BinaryComparisonWindowController) -> Bool = { controller in controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return true }
    static var openNotebook: (URL) async throws -> Void = { file in
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: file) else { throw NotebookComparisonFailure.application }
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([file], withApplicationAt: application, configuration: .init()) { _, error in
                if let error { reply.resume(throwing: error) } else { reply.resume() }
            }
        }
    }
    static var presentInventory: (FileComparisonWindowController) -> Bool = { controller in controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return true }
    static var compareLibreOffice: (LibreOfficeComparisonPreview, OperationCancellation) async throws -> Void = { try await LibreOfficeComparisonAutomation.compare($0, cancellation: $1) }
    static var compareWord: (WordComparisonPreview, OperationCancellation) async throws -> Void = { try await WordComparisonAutomation.compare($0,cancellation:$1) }
    private(set) static var activeRequests = 0
    static func discardAll() { let windows = Array(inventoryWindows.values); inventoryWindows = [:]; for window in windows { window.close() }; let reports = Array(binaryWindows.values); binaryWindows = [:]; for report in reports { report.close() };let warnings=Array(excelWarnings.values);excelWarnings=[:];for warning in warnings{warning.close()}; for folder in previews { try? FileManager.default.removeItem(at: folder) }; previews = [] }
    static func open(_ document: FileComparisonDocument, root: URL, permissions: [RepositoryAccessLease], alternate: Bool, preferences: UserDefaults = .standard, cancellation: OperationCancellation? = nil, owner: NSWindow? = nil, selection: DiffToolSelection? = nil, launch: ((URL, NSWorkspace.OpenConfiguration) async throws -> Void)? = nil) async throws -> Bool {
        try cancellation?.check()
        let chosen = try selection ?? DiffToolPreferences.load(from: preferences).selection(base: document.base.path, destination: document.destination.path, alternate: alternate)
        guard case .program(let program) = chosen else { return false }
        if program.builtIn == .zipInventory {
            activeRequests += 1; defer { activeRequests -= 1 }
            let inventory = try await Task.detached { try document.zipInventories(cancellation: cancellation) }.value
            try cancellation?.check()
            let controller = FileComparisonWindowController(readOnly: inventory, root: root, preferences: preferences)
            controller.window?.appearance = owner?.appearance
            let identity = UUID(); inventoryWindows[identity] = controller
            controller.onClosed = { inventoryWindows.removeValue(forKey: identity) }
            guard presentInventory(controller) else { inventoryWindows.removeValue(forKey: identity); controller.close(); throw CocoaError(.userCancelled) }
            return true
        }
        if program.builtIn == .binaryReport {
            activeRequests += 1; defer { activeRequests -= 1 }
            let report = try await Task.detached { try BinaryComparisonReport(document, cancellation: cancellation) }.value
            try cancellation?.check()
            let controller = BinaryComparisonWindowController(report: report); controller.window?.appearance = owner?.appearance
            let identity = UUID(); binaryWindows[identity] = controller
            controller.onClosed = { binaryWindows.removeValue(forKey: identity) }
            guard presentBinary(controller) else { binaryWindows.removeValue(forKey: identity); controller.close(); throw CocoaError(.userCancelled) }
            return true
        }
        if program.builtIn == .mathematicaNotebook {
            activeRequests += 1; defer { activeRequests -= 1 }
            let root = try TurtleGitTemporaryStorage.root
            let preview = try await Task.detached { try NotebookComparisonPreview.prepare(document, in: root, cancellation: cancellation) }.value
            do {
                try cancellation?.check(); try await openNotebook(preview.notebook)
                // The notebook's Compare button may be used after TurtleGit exits.
                // Like upstream, retain successful driver/inputs for explicit
                // Saved Data cleanup (or the OS temporary-directory cleanup).
                return true
            } catch { preview.discard(); throw error }
        }
        if program.builtIn == .libreOfficeDocument {
            let token = cancellation ?? OperationCancellation()
            activeRequests += 1; defer { activeRequests -= 1; withExtendedLifetime(permissions) {} }
            let root = try TurtleGitTemporaryStorage.root
            let preview = try await Task.detached { try LibreOfficeComparisonPreview.prepare(document, in: root, cancellation: token) }.value
            var dispatched = false
            do {
                try token.check(); dispatched = true
                try await compareLibreOffice(preview, token)
                return true
            } catch {
                if !dispatched || (error as? LibreOfficeComparisonFailure)?.possiblyOpened == false { preview.discard() }
                throw error
            }
        }
        if program.builtIn == .wordDocument {
            let token = cancellation ?? OperationCancellation()
            activeRequests += 1
            defer { activeRequests -= 1; withExtendedLifetime(permissions) {} }
            let root = try TurtleGitTemporaryStorage.root
            let preview = try await Task.detached { try WordComparisonPreview.prepare(document,in:root,cancellation:token) }.value
            var dispatched = false
            do {
                try token.check(); dispatched = true
                try await compareWord(preview,token)
                // Word may keep result/source references beyond this callback.
                // Successful or uncertain handoffs survive normal app cleanup.
                return true
            } catch {
                if !dispatched || (error as? WordComparisonFailure)?.possiblyOpened == false { preview.discard() }
                throw error
            }
        }
        if program.builtIn == .excelWorkbook || program.builtIn == .excelWorkbookFast {
            let token=cancellation ?? OperationCancellation()
            activeRequests += 1;defer { activeRequests -= 1;withExtendedLifetime(permissions) {} }
            let root=try TurtleGitTemporaryStorage.root,fast=program.builtIn == .excelWorkbookFast
            let preview=try await Task.detached { try ExcelComparisonPreview.prepare(document,in:root,fast:fast,cancellation:token) }.value
            var dispatched=false
            do {
                try token.check();dispatched=true
                let outcome=try await compareExcel(preview,token)
                if !token.isCancelled,!outcome.warnings.isEmpty {
                    let controller=ExcelComparisonWarningController(outcome:outcome);controller.window?.appearance=owner?.appearance
                    let identity=UUID();excelWarnings[identity]=controller;controller.onClosed={excelWarnings.removeValue(forKey:identity)}
                    if !presentExcelWarning(controller) { excelWarnings.removeValue(forKey:identity);controller.close() }
                }
                return true
            } catch {
                if !dispatched || (error as? ExcelComparisonFailure)?.possiblyOpened == false {preview.discard()}
                throw error
            }
        }
        let provider = SystemRepositoryBookmarkProvider()
        let application: URL
        if let bookmark = program.bookmark { application = try provider.resolve(bookmark).url } else { application = URL(fileURLWithPath: program.applicationPath) }
        let grant = RepositoryAccessLease(url: application)
        guard !GitRuntime.isAppStoreBuild || grant.hasSecurityScope else { throw DiffToolFailure.application }
        let manager = FileManager.default
        let folder = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitDiffTool-" + UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            func file(_ content: ComparisonFileContent, side: String) throws -> URL {
                let original = content.path.hasPrefix("/") ? URL(fileURLWithPath: content.path) : root.appendingPathComponent(content.path)
                if content.revision == .workingTree, ["100644", "100755"].contains(content.mode ?? ""), manager.fileExists(atPath: original.path) {
                    guard !GitRuntime.isAppStoreBuild || permissions.contains(where: { $0.hasSecurityScope && $0.contains(original) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    return original
                }
                let directory = folder.appendingPathComponent(side); try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let name = (content.path as NSString).lastPathComponent
                let target = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "empty" : name)
                try content.bytes.write(to: target, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: target.path); return target
            }
            try cancellation?.check()
            let base = try file(document.base, side: "base"), mine = try file(document.destination, side: "mine")
            func revisionID(_ revision: ComparisonRevision) -> String { if case .revision(let value) = revision { return value }; return "" }
            let arguments = try program.expandedArguments(values: ["base": base.path, "mine": mine.path, "bname": document.base.path + " : " + document.base.revision.label, "yname": document.destination.path + " : " + document.destination.revision.label, "bpath": document.base.path, "ypath": document.destination.path, "brev": revisionID(document.base.revision), "yrev": revisionID(document.destination.revision), "wtroot": root.path])
            let configuration = NSWorkspace.OpenConfiguration(); configuration.arguments = arguments; configuration.createsNewApplicationInstance = true
            activeRequests += 1
            defer { activeRequests -= 1; withExtendedLifetime(grant) {}; withExtendedLifetime(permissions) {} }
            try cancellation?.check()
            if !program.isApplicationBundle {
                _ = try await ExternalToolProcesses.start(application, arguments: arguments, root: root, permissions: permissions + [grant])
            } else if let launch { try await launch(application, configuration) }
            else {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            previews.append(folder); return true
        } catch { try? manager.removeItem(at: folder); throw error }
    }
}

struct MergeToolSettings: View {
    @StateObject private var model: ToolSettingsDraft<MergeToolPreferences>
    @State private var advanced = false
    init(preferences: UserDefaults = .standard) {
        _model = StateObject(wrappedValue: ToolSettingsDraft(MergeToolPreferences.load(from: preferences), valid: { $0.valid }, persist: { try $0.save(to: preferences) }))
    }
    init(model: ToolSettingsDraft<MergeToolPreferences>) { _model = StateObject(wrappedValue: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Configure the program used for merging different revisions of files") {
                VStack(alignment: .leading, spacing: 12) {
                    DiffProgramForm(program: $model.value.program, tool: "merge")
                    Toggle("Block while merging", isOn: $model.value.blockWhileMerging).disabled(!model.value.program.enabled && !model.value.associations.contains { $0.program.enabled }).onChange(of: model.value.blockWhileMerging) { if !$0 { model.value.trustExitCode = false } }
                    Toggle("Trust the exit code", isOn: $model.value.trustExitCode).disabled(!model.value.trustExitCode && (!model.value.blockWhileMerging || !model.value.supportsTrustedExit))
                    Text("Executable tools report an exit code. Trust resolves only exit code zero; otherwise blocking mode asks whether to mark the result resolved. App bundles use that question. Word merging has no trusted exit status; save the reviewed document as the original conflicting file before marking it resolved.").font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Advanced…") { advanced = true } }
                }.padding(8)
            }
            Text("Arguments: %base, %theirs, %mine, %merged, %bname, %tname, %yname, %mname and %wtroot. Hold Shift when opening a conflict to reverse the internal/external choice.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            Spacer()
        }.padding(20)
        .settingsParticipant("mergeTool", page: .mergeTool, value: model.value, modified: { model.modified }, validate: { model.validationError }, apply: { model.apply() }, cancel: model.cancel)
        .sheet(isPresented: $advanced) { DiffToolAssociations(associations: model.value.associations, tool: "merge") { value in if let value { model.value.associations = value }; advanced = false } }
    }
}

/// Owns wait and confirmation. App bundles are observed; a blocking CLI tool
/// shares this cancellation token with its separately owned process group.
@MainActor final class ExternalMergeSession {
    private(set) var retired = false
    let cancellation: OperationCancellation
    private var cancellationMonitor: Task<Void, Never>?
    private weak var owner: NSWindow?
    private var ownerObserver: NSObjectProtocol?
    private var stopObservation: (() -> Void)?
    private var answer: ((Bool) -> Void)?
    private var alert: NSAlert?
    var presentConfirmation: ((NSWindow, NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    init(owner: NSWindow?, cancellation: OperationCancellation? = nil) {
        self.owner = owner; self.cancellation = cancellation ?? OperationCancellation()
        if let owner {
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retire() }
            }
        }
        let token = self.cancellation
        cancellationMonitor = Task { [weak self] in
            while !Task.isCancelled && !token.isCancelled {
                guard self?.retired == false else { return }
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
            if token.isCancelled { self?.retire() }
        }
    }
    func retire(cancelWork: Bool = true) {
        guard !retired else { return }; retired = true; if cancelWork { cancellation.cancel() }; cancellationMonitor?.cancel(); cancellationMonitor = nil
        let stop = stopObservation; stopObservation = nil; stop?()
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
        alert?.window.orderOut(nil); alert = nil
        let reply = answer; answer = nil; reply?(false)
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }; ownerObserver = nil
    }
    /// The returned cleanup is called once, including synchronous completion.
    func wait(observe: (@escaping () -> Void) -> (() -> Void)) async -> Bool {
        guard !retired, !cancellation.isCancelled, !Task.isCancelled else { retire(); return false }
        guard answer == nil else { return false }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                var finished = false
                let finish: (Bool) -> Void = { [weak self] value in
                    guard !finished else { return }; finished = true
                    let stop = self?.stopObservation; self?.stopObservation = nil; self?.answer = nil; stop?()
                    continuation.resume(returning: value)
                }
                answer = finish
                let stop = observe { [weak self] in finish(self?.retired == false && self?.cancellation.isCancelled == false) }
                if finished { stop() } else { stopObservation = stop }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.retire() } })
    }
    func wait(for application: NSRunningApplication) async -> Bool {
        await wait { finish in
            if application.isTerminated { finish(); return {} }
            let observation = application.observe(\.isTerminated, options: [.new]) { _, change in
                if change.newValue == true { DispatchQueue.main.async { finish() } }
            }
            if application.isTerminated { finish() }
            return { observation.invalidate() }
        }
    }
    func confirmWordPreparation(path: String, libreOffice: Bool = false) async -> Bool {
        let question=NSAlert(); question.messageText=libreOffice ? "TurtleGit LibreOffice Merge" : "TurtleGit Word Merge"; question.alertStyle = .informational
        question.informativeText="After you click OK we'll create a merge document. Please wait.\nThen reject or accept changes and use Save As to save the original conflicting file:\n\n"+path
        question.addButton(withTitle:"OK"); question.addButton(withTitle:"Cancel")
        return await ask(question)
    }
    func confirmImageResolution(path: String) async -> Bool {
        let question = NSAlert(); question.alertStyle = .informational
        question.messageText = "Mark “" + (path as NSString).lastPathComponent + "” as resolved?"
        question.informativeText = "The selected content has been copied to the working file."
        question.addButton(withTitle: "Yes"); question.addButton(withTitle: "No")
        return await ask(question)
    }
    func confirmResolution(path: String) async -> Bool {
        let question = NSAlert(); question.messageText = "Was the merge of “" + path + "” successful?"
        question.addButton(withTitle: "Mark Resolved"); question.addButton(withTitle: "No")
        question.buttons[0].keyEquivalent = ""; question.buttons[1].keyEquivalent = "\r"
        question.window.defaultButtonCell = question.buttons[1].cell as? NSButtonCell
        return await ask(question)
    }
    private func ask(_ question:NSAlert) async -> Bool {
        guard !retired, !cancellation.isCancelled, !Task.isCancelled, answer == nil, let owner, owner.isVisible, owner.attachedSheet == nil else { return false }
        alert = question
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                var finished = false
                let reply: (Bool) -> Void = { [weak self] value in
                    guard !finished else { return }; finished = true; self?.answer = nil; self?.alert = nil
                    continuation.resume(returning: value)
                }
                answer = reply
                let response: (NSApplication.ModalResponse) -> Void = { [weak self, weak owner] result in
                    reply(result == .alertFirstButtonReturn && self?.retired == false && self?.cancellation.isCancelled == false && owner?.isVisible == true)
                }
                if let presentConfirmation { presentConfirmation(owner, question, response) }
                else { question.beginSheetModal(for: owner, completionHandler: response) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.retire() } })
    }
    func resolveIfConfirmed(repository: GitRepository, entry: ConflictEntry, path: String) async throws {
        guard await confirmResolution(path: path), !retired, !cancellation.isCancelled, !Task.isCancelled else { return }
        _ = try await repository.resolveConflicts([entry], using: .current, cancellation: cancellation)
    }
}

@MainActor enum MergeToolApplication {
    private(set) static var previews: [URL] = []
    static var mergeLibreOffice: (LibreOfficeComparisonPreview, OperationCancellation) async throws -> Void = { try await LibreOfficeComparisonAutomation.compare($0, cancellation: $1) }
    static var mergeWord: (WordMergePreview,OperationCancellation) async throws -> Void = { try await WordComparisonAutomation.merge($0,cancellation:$1) }
    static var configureLibreOfficeSession: (ExternalMergeSession) -> Void = { _ in }
    static var configureWordSession: (ExternalMergeSession) -> Void = { _ in }
    private(set) static var activeRequests = 0
    static func discardAll() { for folder in previews { try? FileManager.default.removeItem(at: folder) }; previews = [] }
    static func open(repository: GitRepository, access: RepositoryAccessLease?, path: String, alternate: Bool, owner: NSWindow?, cancellation: OperationCancellation? = nil, onPrepared: () -> Void = {}, preferences: MergeToolPreferences? = nil, expectedEntry: ConflictEntry? = nil, identityOptions: ConflictIdentityOptions = .init(defaults: .standard), launch: ((URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication)? = nil) async throws -> Bool {
        let token = cancellation ?? OperationCancellation(); try token.check()
        let settings = preferences ?? MergeToolPreferences.load()
        guard let program = try settings.selected(path: path, alternate: alternate) else { return false }
        guard !settings.blockWhileMerging || !settings.trustExitCode || (!program.isApplicationBundle && program.builtIn == nil) else { throw NSError(domain: "TurtleGit.MergeTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "This application does not expose an exit code. Turn off Trust the exit code in Merge Tool settings."]) }
        guard !GitRuntime.isAppStoreBuild || (access?.hasSecurityScope == true && access?.contains(repository.root) == true) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        activeRequests += 1
        defer { activeRequests -= 1; withExtendedLifetime(access) {} }
        let session = ExternalMergeSession(owner: owner, cancellation: token)
        defer { session.retire(cancelWork: false) }
        return try await withTaskCancellationHandler(operation: {
        let input = try await repository.externalMergeInputs(path: path, identityOptions: identityOptions, cancellation: token)
        try Task.checkCancellation(); try token.check()
        if let expectedEntry, input.entry != expectedEntry { throw ResolveFailure.stale }
        guard !session.retired else { return true }
        guard !GitRuntime.isAppStoreBuild || access?.contains(input.result) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
        if program.builtIn == .libreOfficeDocument {
            configureLibreOfficeSession(session)
            onPrepared()
            guard await session.confirmWordPreparation(path: input.result.path, libreOffice: true), !session.retired else { return true }
            let root = try TurtleGitTemporaryStorage.root
            let preview = try await Task.detached { try LibreOfficeComparisonPreview.prepare(input, in: root, cancellation: token) }.value
            var dispatched = false
            do {
                try await repository.validateExternalMergeInputs(input, cancellation: token)
                try token.check(); guard !session.retired else { throw OperationCancellationFailure.cancelled }
                dispatched = true; try await mergeLibreOffice(preview, token)
                if settings.blockWhileMerging, !session.retired, !token.isCancelled {
                    try await session.resolveIfConfirmed(repository: repository, entry: input.entry, path: path)
                }
                return true
            } catch {
                if !dispatched || (error as? LibreOfficeComparisonFailure)?.possiblyOpened == false { preview.discard() }
                throw error
            }
        }
        if program.builtIn == .wordDocument {
            configureWordSession(session)
            onPrepared()
            guard await session.confirmWordPreparation(path:input.result.path), !session.retired else { return true }
            let root=try TurtleGitTemporaryStorage.root
            let preview=try await Task.detached { try WordMergePreview.prepare(input,in:root,cancellation:token) }.value
            var dispatched=false
            do {
                try await repository.validateExternalMergeInputs(input,cancellation:token)
                try token.check(); guard !session.retired else { throw OperationCancellationFailure.cancelled }
                dispatched=true; try await mergeWord(preview,token)
                if settings.blockWhileMerging, !session.retired, !token.isCancelled {
                    try await session.resolveIfConfirmed(repository:repository,entry:input.entry,path:path)
                }
                return true
            } catch {
                if !dispatched || (error as? WordMergeFailure)?.possiblyOpened == false { preview.discard() }
                throw error
            }
        }
        let target: URL
        if let bookmark = program.bookmark { target = try SystemRepositoryBookmarkProvider().resolve(bookmark).url }
        else { target = URL(fileURLWithPath: program.applicationPath) }
        let grant = RepositoryAccessLease(url: target)
        guard !GitRuntime.isAppStoreBuild || grant.hasSecurityScope else { throw DiffToolFailure.application }
        let manager = FileManager.default
        let folder = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitMergeTool-" + UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { withExtendedLifetime(grant) {} }
        do {
            // Keep title expansion outside the heterogeneous dictionary expression:
            // Swift 6.1 otherwise times out while inferring the cancellation body.
            let baseTitle: String = input.conflictTitles?.base ?? "Base"
            let theirsTitle: String = input.conflictTitles?.theirs.title ?? "Theirs"
            let mineTitle: String = input.conflictTitles?.mine.title ?? "Mine"
            var values: [String: String] = [:]
            values["merged"] = input.result.path
            values["bname"] = "\(path) : \(baseTitle)"
            values["tname"] = "\(path) : \(theirsTitle)"
            values["yname"] = "\(path) : \(mineTitle)"
            values["mname"] = path
            values["wtroot"] = repository.root.path
            let privateFiles = try await Task.detached(priority: .userInitiated) { () throws -> [String: String] in
                var files: [String: String] = [:]
                for (side, bytes) in [("base", input.base), ("theirs", input.theirs), ("mine", input.mine)] {
                    try token.check()
                    let file = folder.appendingPathComponent(side + "-" + (path as NSString).lastPathComponent)
                    try bytes.write(to: file, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
                    try token.check(); files[side] = file.path
                }
                return files
            }.value
            try Task.checkCancellation(); for (side, file) in privateFiles { values[side] = file }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true
            configuration.arguments = try program.expandedArguments(values: values, files: ["base", "theirs", "mine", "merged"])
            try await repository.validateExternalMergeInputs(input, cancellation: token)
            try token.check(); guard !session.retired else { throw OperationCancellationFailure.cancelled }
            onPrepared()
            if !program.isApplicationBundle {
                let execution = try await ExternalToolProcesses.start(target, arguments: configuration.arguments, root: repository.root,
                    permissions: [grant] + (access.map { [$0] } ?? []), cancellation: settings.blockWhileMerging ? token : nil)
                previews.append(folder)
                if settings.blockWhileMerging {
                    let status = try await execution.completion.value
                    try token.check(); guard !session.retired else { return true }
                    if settings.trustExitCode {
                        if status == 0 { _ = try await repository.resolveConflicts([input.entry], using: .current, cancellation: token) }
                    } else { try await session.resolveIfConfirmed(repository: repository, entry: input.entry, path: path) }
                }
                return true
            }
            let app: NSRunningApplication
            if let launch { app = try await launch(target, configuration) }
            else { app = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication, Error>) in
                NSWorkspace.shared.openApplication(at: target, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let application { continuation.resume(returning: application) }
                    else { continuation.resume(throwing: DiffToolFailure.application) }
                }
            } }
            // A receiving app may already hold these files even if its caller
            // closed while NSWorkspace was returning. Never kill that app or
            // delete its inputs merely because TurtleGit's request was cancelled.
            previews.append(folder)
            guard !session.retired, !token.isCancelled else { return true }
            if settings.blockWhileMerging, !session.retired {
                if await session.wait(for: app) { try await session.resolveIfConfirmed(repository: repository, entry: input.entry, path: path) }
            }
            return true
        } catch { if !previews.contains(folder) { try? manager.removeItem(at: folder) }; throw error }
        }, onCancel: { token.cancel() })
    }
}
