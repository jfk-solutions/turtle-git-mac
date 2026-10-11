// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class ToolApplicationChooser {
    weak var window: NSWindow?
    private var panel: NSOpenPanel?
    func cancel() { if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil }
    func choose(_ completion: @escaping (URL, Data) -> Void, failure: @escaping (String) -> Void) {
        guard let window, panel == nil, window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel(); chooser.allowedContentTypes = [.applicationBundle]
        chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false
        chooser.title = "Select diff application"; chooser.prompt = "Select"; chooser.directoryURL = URL(fileURLWithPath: "/Applications")
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
private struct DiffProgramForm: View {
    @Binding var program: DiffToolProgram
    @State private var chooser = ToolApplicationChooser()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Diff tool", selection: $program.enabled) { Text("TurtleGitMerge").tag(false); Text("External").tag(true) }.pickerStyle(.radioGroup).labelsHidden()
            HStack {
                TextField("Application", text: Binding(get: { program.applicationPath }, set: { guard program.applicationPath != $0 else { return }; program.applicationPath = $0; program.bookmark = nil }))
                Button("Browse…") { chooser.choose({ application, bookmark in program.applicationPath = application.path; program.bookmark = bookmark }, failure: { error = $0 }) }
            }.disabled(!program.enabled)
            TextField("Arguments", text: $program.arguments).disabled(!program.enabled)
            if !program.valid { Text(DiffToolFailure.application.localizedDescription).foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red) }
        }.background(ToolChooserProbe(chooser: chooser).frame(width: 0, height: 0)).onDisappear { chooser.cancel() }
    }
}
struct DiffToolSettings: View {
    @Environment(\.settingsTransaction) private var transaction
    @State private var draft = DiffToolPreferences.load()
    @State private var saved = DiffToolPreferences.load()
    @State private var advanced = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Configure the program used for comparing different revisions of files") {
                    VStack(alignment: .leading, spacing: 10) {
                        DiffProgramForm(program: $draft.program)
                        HStack { Spacer(); Button("Advanced…") { advanced = true } }
                    }.padding(8)
                }
                Text("Arguments: %base, %mine, %bname, %yname, %bpath, %ypath, %brev, %yrev and %wtroot. Quote arguments containing spaces. Hold Shift when opening a comparison to reverse the internal/external choice.").font(.caption).foregroundStyle(.secondary)
                UnifiedDiffViewerSettings(settingsPage: .diff)
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(20)
        }
        .settingsParticipant("diff", page: .diff, value: draft, modified: { draft != saved }, validate: { draft.valid ? nil : "Review the diff application and file associations." }, apply: {
            do { try draft.save(); saved = draft; error = nil; return true } catch { self.error = error.localizedDescription; return false }
        }, cancel: { draft = saved; error = nil })
        .sheet(isPresented: $advanced) { DiffToolAssociations(associations: draft.associations) { value in if let value { draft.associations = value }; advanced = false } }
    }
}
private struct DiffToolAssociations: View {
    @State private var draft: [DiffToolAssociation]
    @State private var selected = Set<UUID>()
    @State private var editing: DiffToolAssociation?
    let completed: ([DiffToolAssociation]?) -> Void
    init(associations: [DiffToolAssociation], completed: @escaping ([DiffToolAssociation]?) -> Void) { _draft = State(initialValue: associations); self.completed = completed }
    private var valid: Bool { draft.allSatisfy(\.valid) && Set(draft.map(\.normalizedPattern)).count == draft.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced diff settings").font(.headline)
            Table(draft.sorted { $0.normalizedPattern.localizedStandardCompare($1.normalizedPattern) == .orderedAscending }, selection: $selected) {
                TableColumn("Extension") { Text($0.pattern) }
                TableColumn("Program") { Text($0.program.enabled ? $0.program.applicationPath : "TurtleGitMerge (external disabled)") }
            }.frame(minHeight: 240)
            HStack {
                Button("Add…") { editing = DiffToolAssociation() }
                Button("Edit…") { editing = draft.first { selected.contains($0.id) } }.disabled(selected.count != 1)
                Button("Remove") { draft.removeAll { selected.contains($0.id) }; selected = [] }.disabled(selected.isEmpty)
                Spacer(); Button("Cancel") { completed(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { completed(draft) }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(20).frame(width: 720)
        .sheet(item: $editing) { entry in
            DiffToolAssociationEditor(entry: entry, existing: draft) { value in
                if let value {
                    if let index = draft.firstIndex(where: { $0.id == value.id }) { draft[index] = value } else { draft.append(value) }
                    selected = [value.id]
                }; editing = nil
            }
        }
    }
}
private struct DiffToolAssociationEditor: View {
    @State private var draft: DiffToolAssociation
    let existing: [DiffToolAssociation]
    let completed: (DiffToolAssociation?) -> Void
    init(entry: DiffToolAssociation, existing: [DiffToolAssociation], completed: @escaping (DiffToolAssociation?) -> Void) { _draft = State(initialValue: entry); self.existing = existing; self.completed = completed }
    private var valid: Bool { draft.valid && !existing.contains { $0.id != draft.id && $0.normalizedPattern == draft.normalizedPattern } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing.contains { $0.id == draft.id } ? "Edit diff tool" : "Add diff tool").font(.headline)
            TextField("Extension or filename", text: $draft.pattern)
            DiffProgramForm(program: $draft.program)
            if !valid { Text("Choose a unique extension (such as .swift) or filename, and a valid program.").font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { completed(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { draft.pattern = draft.normalizedPattern; completed(draft) }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(20).frame(width: 600)
    }
}

@MainActor enum DiffToolApplication {
    private static var previews: [URL] = []
    private(set) static var activeRequests = 0
    static func discardAll() { for folder in previews { try? FileManager.default.removeItem(at: folder) }; previews = [] }
    static func open(_ document: FileComparisonDocument, root: URL, permissions: [RepositoryAccessLease], alternate: Bool) async throws -> Bool {
        guard let program = try DiffToolPreferences.load().selected(base: document.base.path, destination: document.destination.path, alternate: alternate) else { return false }
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
            let base = try file(document.base, side: "base"), mine = try file(document.destination, side: "mine")
            func revisionID(_ revision: ComparisonRevision) -> String { if case .revision(let value) = revision { return value }; return "" }
            let arguments = try program.expandedArguments(values: ["base": base.path, "mine": mine.path, "bname": document.base.path + " : " + document.base.revision.label, "yname": document.destination.path + " : " + document.destination.revision.label, "bpath": document.base.path, "ypath": document.destination.path, "brev": revisionID(document.base.revision), "yrev": revisionID(document.destination.revision), "wtroot": root.path])
            let configuration = NSWorkspace.OpenConfiguration(); configuration.arguments = arguments; configuration.createsNewApplicationInstance = true
            activeRequests += 1
            defer { activeRequests -= 1; withExtendedLifetime(grant) {}; withExtendedLifetime(permissions) {} }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            previews.append(folder); return true
        } catch { try? manager.removeItem(at: folder); throw error }
    }
}
