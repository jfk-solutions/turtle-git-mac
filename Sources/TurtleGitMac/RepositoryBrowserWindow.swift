// Adapts RepositoryBrowser.cpp dialog/menu workflows, GPL-2.0-or-later.
// Copyright (C) 2009-2026 TortoiseGit; 2003-2013 TortoiseSVN.
import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

private final class RepositoryBrowserNativeWindow: NSWindow {
    weak var model: RepositoryBrowserWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, event.keyCode == 96 { model?.refresh(); return true }
        if attachedSheet == nil, [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.option), firstResponder is NSTableView {
            if let model, model.selected.count == 1, let entry = model.selected.first { model.open(entry) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class RepositoryBrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: RepositoryBrowserWindowModel
    var onClosed: () -> Void = {}
    private var picker: LogWindowController?
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String) {
        model = RepositoryBrowserWindowModel(repository: repository, access: access, revision: revision)
        let window = RepositoryBrowserNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = repository.root.lastPathComponent + " – Repository Browser – TurtleGit"
        window.contentMinSize = NSSize(width: 760, height: 440); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RepositoryBrowserDialog(model: model))
        super.init(window: window); window.delegate = self; window.model = model
        window.setContentSize(NSSize(width: 1000, height: 650))
        window.setFrameAutosaveName("TurtleGit.RepositoryBrowser"); window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.chooseRevision = { [weak self] in self?.chooseRevision() }
        model.presentFile = { [weak self] content, action in
            DispatchQueue.main.async { [weak self] in self?.presentFile(content, action: action) }
        }
        model.handleRevertFailure = { [weak window] message in
            guard let window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Could not revert file"
            alert.informativeText = message; alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        model.showRevertResult = { [weak window] message in
            guard let window, window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.messageText = "Revert to this revision"; alert.informativeText = message
            alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
        }
        model.refresh()
    }
    private func chooseRevision() {
        guard let window, window.attachedSheet == nil else { return }
        let controller = LogWindowController(repository: model.repository, access: model.access) { [weak self] entry in
            self?.picker = nil
            if let entry { self?.model.revision = entry.hash; self?.model.refresh() }
        }
        controller.model.endRevision = model.snapshot?.objectID; controller.model.reload()
        picker = controller
        if let child = controller.window { window.beginSheet(child) }
    }
    private func presentFile(_ content: ComparisonFileContent, action: RepositoryBrowserWindowModel.FileAction) {
        guard let window, window.attachedSheet == nil else { return }
        if action == .save {
            let panel = NSSavePanel(); panel.title = "Save revision to…"
            panel.nameFieldStringValue = (content.path as NSString).lastPathComponent
            panel.beginSheetModal(for: window) { [weak model] response in
                guard response == .OK, let url = panel.url else { return }
                do { try content.bytes.write(to: url, options: .atomic) } catch { model?.error = error.localizedDescription }
            }
        } else if action == .openWith {
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let app = panel.url { self?.open(content, action: action, application: app) }
            }
        } else { open(content, action: action) }
    }
    private func open(_ content: ComparisonFileContent, action: RepositoryBrowserWindowModel.FileAction, application: URL? = nil) {
        do {
            let preview = try HistoricalFilePreview.create(content); HistoricalPreviewFiles.retain(preview)
            let failed: (String?) -> Void = { [weak model] error in
                if let error { HistoricalPreviewFiles.discard(preview.file); model?.error = error }
            }
            if action == .alternativeEditor { AlternativeEditor.open(preview.file, completion: failed) }
            else if let application {
                let scoped = application.startAccessingSecurityScopedResource()
                NSWorkspace.shared.open([preview.file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if scoped { application.stopAccessingSecurityScopedResource() }
                    DispatchQueue.main.async { failed(error?.localizedDescription) }
                }
            } else if !NSWorkspace.shared.open(preview.file) { failed("Could not open the historical file. Choose an application using Open With.") }
        } catch { model.error = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.attachedSheet == nil && !model.mutating && !model.confirmingQuit }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class RepositoryBrowserWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    @Published var revision: String
    @Published private(set) var snapshot: RepositoryBrowserSnapshot?
    @Published private(set) var directories: [String: [RepositoryBrowserEntry]] = [:]
    @Published var expanded: Set<String> = [""]
    @Published var selection = Set<String>()
    @Published var sortOrder = [KeyPathComparator(\RepositoryBrowserEntry.name)]
    @Published var busy = false
    @Published var mutating = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var comparisonMark: PreparedFileComparisonMark?
    private var lastImportedWorkingMark: UUID?
    private var generation = UUID()
    private var loads = Set<String>()
    private var listings: [String: RepositoryBrowserSnapshot] = [:]
    private var requestedDirectory = ""
    private var active = true
    var handleRevertFailure: (String) async -> Bool = { _ in false }
    var showRevertResult: (String) -> Void = { _ in }
    var onChanged: () -> Void = {}
    var close: () -> Void = {}
    var chooseRevision: () -> Void = {}
    var onLog: (String, String) -> Void = { _, _ in }
    var onBlame: (String, String) -> Void = { _, _ in }
    var onCompare: (String, String) -> Void = { _, _ in }
    var onSubmodule: (RepositoryBrowserSnapshot, RepositoryBrowserEntry, Bool) -> Void = { _, _, _ in }
    var onPreparedFileCompare: ((PreparedFileComparisonMark, PreparedFileComparisonMark) -> Void)?
    enum FileAction { case open, openWith, alternativeEditor, save }
    var presentFile: (ComparisonFileContent, FileAction) -> Void = { _, _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String) { self.repository = repository; self.access = access; self.revision = revision }
    var entries: [RepositoryBrowserEntry] {
        let first = sortOrder.first
        let column: RepositoryBrowserSort = first?.keyPath == \RepositoryBrowserEntry.fileExtension ? .fileExtension : first?.keyPath == \RepositoryBrowserEntry.sizeSort ? .size : .name
        return RepositoryBrowserListing.sorted(snapshot?.entries ?? [], by: column, descending: first?.order == .reverse)
    }
    var selected: [RepositoryBrowserEntry] { entries.filter { selection.contains($0.id) } }
    var info: String {
        if selected.count > 1 { return "\(selected.count) items selected" }
        if let entry = selected.first {
            if entry.kind == .directory { return entry.name }
            if entry.kind == .submodule { return "Submodule \(entry.name)\nRevision \(entry.objectID)" }
            return entry.name + "\nSize " + sizeText(entry)
        }
        let values = snapshot?.entries ?? []
        return "Showing \(values.filter { ![.directory, .submodule].contains($0.kind) }.count) files, \(values.filter { $0.kind == .submodule }.count) submodules and \(values.filter { $0.kind == .directory }.count) folders, \(values.count) items in total"
    }
    func sizeText(_ entry: RepositoryBrowserEntry) -> String { entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "" }
    func invalidate() { active = false; generation = UUID() }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func refresh() {
        guard active, !mutating, !confirmingQuit else { return }
        let token = UUID(); generation = token; busy = true
        let value = revision, directory = snapshot?.directory ?? ""
        Task { [weak self, repository, access] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false }; withExtendedLifetime(access) {} }
            do {
                try self.validateAccess()
                let root = try await repository.browseRepository(revision: value)
                let current = directory.isEmpty || root.treeID == nil ? root : (try? await repository.browseRepositoryDirectory(root, directory: directory)) ?? root
                guard self.active, self.generation == token else { return }
                self.directories = ["": root.entries]; self.loads = []; self.listings = ["": root]; self.listings[current.directory] = current; self.requestedDirectory = current.directory
                self.snapshot = current; self.directories[current.directory] = current.entries
                self.expanded = [""]; self.selection = []
            } catch { if self.active && self.generation == token { self.error = error.localizedDescription } }
        }
    }
    func loadDirectory(_ path: String, select: Bool) {
        guard active, !busy, !confirmingQuit, let snapshot, snapshot.treeID != nil else { return }
        let token = generation
        if select { requestedDirectory = path }
        if let cached = listings[path] {
            if select { self.snapshot = cached; selection = [] }
            return
        }
        guard !loads.contains(path) else { return }; loads.insert(path)
        Task { [weak self, repository, access] in
            guard let self else { return }
            defer { if self.generation == token { self.loads.remove(path) }; withExtendedLifetime(access) {} }
            do {
                try self.validateAccess()
                let result = try await repository.browseRepositoryDirectory(snapshot, directory: path)
                guard self.active, self.generation == token else { return }
                self.directories[path] = result.entries; self.listings[path] = result
                if self.requestedDirectory == path { self.snapshot = result; self.selection = [] }
            } catch { if self.active && self.generation == token { self.error = error.localizedDescription } }
        }
    }
    func open(_ entry: RepositoryBrowserEntry, action: FileAction = .open) {
        guard active, !busy, !confirmingQuit, let snapshot, snapshot.entries.contains(entry) else { return }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        if entry.kind == .directory { expanded.insert(entry.path); loadDirectory(entry.path, select: true); return }
        if entry.kind == .submodule && action == .open && !snapshot.bare { onSubmodule(snapshot, entry, false); return }
        Task { [weak self, repository, access] in
            do {
                guard let self else { return }; try self.validateAccess()
                let content = try await repository.repositoryBrowserFile(snapshot, entry: entry)
                guard self.active else { return }; self.presentFile(content, action)
            } catch { self?.error = error.localizedDescription }
            withExtendedLifetime(access) {}
        }
    }
    func showSubmoduleLog(_ entry: RepositoryBrowserEntry) {
        guard active, !busy, !confirmingQuit, let snapshot, snapshot.entries.contains(entry), entry.kind == .submodule else { return }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        guard !snapshot.bare else { error = "This bare repository has no child working checkout. Open an initialized working repository to show submodule history."; return }
        onSubmodule(snapshot, entry, true)
    }
    func revert(_ entries: [RepositoryBrowserEntry]) {
        guard active, !busy, !confirmingQuit, let snapshot, !snapshot.bare, !entries.isEmpty,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ snapshot.entries.contains($0) && ![.directory, .submodule].contains($0.kind) }) else { return }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        busy = true; mutating = true
        Task { [self, repository, access] in
            var restored = 0, failed = 0, attempted = 0
            for entry in entries {
                attempted += 1
                do {
                    try validateAccess()
                    try await repository.revertRepositoryBrowserFile(snapshot, entry: entry)
                    restored += 1
                } catch {
                    failed += 1
                    if !(await handleRevertFailure(entry.path + "\n\n" + error.localizedDescription)) { break }
                }
            }
            mutating = false; busy = false; onChanged()
            showRevertResult("\(restored) file(s) reverted to \(snapshot.revision)." + (failed == 0 ? "" : "\n\(failed) file(s) failed. \(entries.count - attempted) file(s) were not attempted."))
            withExtendedLifetime(access) {}
        }
    }
    func importWorkingComparisonMark(_ access: WorkingComparisonAccess?) {
        guard let access, access.mark.id != lastImportedWorkingMark else { return }
        lastImportedWorkingMark = access.mark.id
        comparisonMark = PreparedFileComparisonMark(path: access.file.path, revision: "", workingAccess: access)
    }
    func markForComparison(_ entry: RepositoryBrowserEntry) {
        guard active, !busy, !confirmingQuit, let snapshot, let revision = snapshot.objectID,
              snapshot.entries.contains(entry), ![.directory, .submodule].contains(entry.kind) else { return }
        comparisonMark = PreparedFileComparisonMark(path: entry.path, revision: revision)
    }
    func compareWithMarkedFile(_ entry: RepositoryBrowserEntry) {
        guard active, !busy, !confirmingQuit, let snapshot, let revision = snapshot.objectID, let comparisonMark,
              snapshot.entries.contains(entry), ![.directory, .submodule].contains(entry.kind) else { return }
        onPreparedFileCompare?(comparisonMark, PreparedFileComparisonMark(path: entry.path, revision: revision))
    }
    func copy(hashes: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.map { hashes ? $0.objectID : $0.name }.joined(separator: "\n"), forType: .string)
    }
}

private struct RepositoryBrowserDialog: View {
    @ObservedObject var model: RepositoryBrowserWindowModel
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Path:")
                Text(model.repository.root.path + (model.snapshot?.directory.isEmpty == false ? "/" + model.snapshot!.directory : "")).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Revision:")
                Button(model.revision) { model.chooseRevision() }.lineLimit(1).frame(minWidth: 180).disabled(model.busy)
            }
            RepositoryBrowserSplit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        RepositoryFolderRow(model: model, path: "", name: model.repository.root.lastPathComponent)
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(model.busy).accessibilityLabel("Repository folders")
            } right: {
                Table(model.entries, selection: $model.selection, sortOrder: $model.sortOrder) {
                    TableColumn("Name", value: \.name) { entry in
                        HStack(spacing: 6) {
                            Image(nsImage: browserIcon(entry)).resizable().frame(width: 16, height: 16).overlay {
                                if let overlay = overlay(entry)?.image() { Image(nsImage: overlay).resizable().frame(width: 16, height: 16) }
                            }
                            Text(verbatim: entry.name)
                        }.help(entry.path + "\n" + entry.objectID)
                    }.width(min: 160, ideal: 310)
                    TableColumn("Extension", value: \.fileExtension).width(min: 70, ideal: 100)
                    TableColumn("Size", value: \.sizeSort) { entry in Text(model.sizeText(entry)).frame(maxWidth: .infinity, alignment: .trailing) }.width(min: 70, ideal: 100)
                }.contextMenu(forSelectionType: String.self) { ids in
                    let values = model.entries.filter { ids.contains($0.id) }
                    if values.count == 1, let entry = values.first, let revision = model.snapshot?.objectID {
                        Button { model.open(entry) } label: { CommandLabel(title: "Open", icon: .open) }
                        if entry.kind != .directory {
                            Button { model.open(entry, action: .openWith) } label: { CommandLabel(title: "Open With…", icon: .open) }
                            Button { model.open(entry, action: .alternativeEditor) } label: { CommandLabel(title: "View revision with alternative editor", icon: .editor) }
                        }
                        Divider()
                        if entry.kind != .directory && model.snapshot?.bare == false {
                            Button { model.onCompare(entry.path, revision) } label: { CommandLabel(title: "Compare with working tree", icon: .compare) }
                            Divider()
                        }
                        Button { model.onLog(entry.path, revision) } label: { CommandLabel(title: "Show log", icon: .log) }
                        if entry.kind == .submodule {
                            Button { model.showSubmoduleLog(entry) } label: { CommandLabel(title: "Show submodule log", icon: .log) }
                        }
                        if ![.directory, .submodule].contains(entry.kind) {
                            if model.snapshot?.bare == false {
                                Button { model.onBlame(entry.path, revision) } label: { CommandLabel(title: "Blame", icon: .blame) }
                            }
                            Divider()
                            Button { model.open(entry, action: .save) } label: { CommandLabel(title: "Save revision to…", icon: .saveAs) }

                        }
                        Divider()
                    }
                    if !values.isEmpty && model.snapshot?.bare == false && values.allSatisfy({ ![.directory, .submodule].contains($0.kind) }) {
                        Button { model.revert(values) } label: { CommandLabel(title: "Revert to this revision", icon: .revert) }
                        Divider()
                    }
                    if values.count == 1, let entry = values.first, ![.directory, .submodule].contains(entry.kind) {
                        Button { model.markForComparison(entry) } label: { CommandLabel(title: "Mark for comparison", icon: .compare) }
                        if let mark = model.comparisonMark {
                            Button { model.compareWithMarkedFile(entry) } label: { CommandLabel(title: "Compare with " + mark.label(for: entry.path), icon: .compare) }.disabled(model.onPreparedFileCompare == nil)
                        }
                        Divider()
                    }
                    if !values.isEmpty {
                        Button { model.selection = ids; model.copy() } label: { CommandLabel(title: "Copy to clipboard", icon: .copy) }
                        Button { model.selection = ids; model.copy(hashes: true) } label: { CommandLabel(title: "Copy hash", icon: .copy) }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }) { model.open(entry) }
                }.disabled(model.busy).accessibilityLabel("Repository contents")
            }.border(Color.secondary.opacity(0.4))
            HStack {
                Text(model.info).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                if model.busy { ProgressView().controlSize(.small) }
                Button("OK", action: model.close).keyboardShortcut(.defaultAction).disabled(model.mutating)
                Button("Cancel", action: model.close).keyboardShortcut(.cancelAction).disabled(model.mutating)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-repobrowser.html")!) }
            }
        }.padding(12).disabled(model.confirmingQuit).alert("Repository Browser", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func browserIcon(_ entry: RepositoryBrowserEntry) -> NSImage {
        if [.directory, .submodule].contains(entry.kind) { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
    }
    private func overlay(_ entry: RepositoryBrowserEntry) -> MenuIcon? {
        switch entry.kind { case .executable: return .executableOverlay; case .symlink: return .symlinkOverlay; case .submodule: return .externalOverlay; default: return nil }
    }
}
private struct RepositoryFolderRow: View {
    @ObservedObject var model: RepositoryBrowserWindowModel
    let path: String
    let name: String
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { model.expanded.contains(path) }, set: { expanded in
            if expanded { model.expanded.insert(path); model.loadDirectory(path, select: false) }
            else { model.expanded.remove(path) }
        })) {
            if let children = model.directories[path] {
                ForEach(RepositoryBrowserListing.sorted(children).filter { $0.kind == .directory }) { entry in
                    AnyView(RepositoryFolderRow(model: model, path: entry.path, name: entry.name))
                }
            } else { ProgressView().controlSize(.small) }
        } label: {
            Button { model.loadDirectory(path, select: true) } label: {
                HStack(spacing: 5) {
                    Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 16, height: 16)
                    Text(verbatim: name).lineLimit(1)
                }.padding(3).background(model.snapshot?.directory == path ? Color.accentColor.opacity(0.2) : Color.clear)
            }.buttonStyle(.plain).contextMenu {
                if let revision = model.snapshot?.objectID {
                    Button { model.onLog(path, revision) } label: { CommandLabel(title: "Show log", icon: .log) }
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(name, forType: .string)
                    } label: { CommandLabel(title: "Copy to clipboard", icon: .copy) }
                }
            }
        }
    }
}


private struct RepositoryBrowserSplit<Left: View, Right: View>: NSViewControllerRepresentable {
    let left: Left
    let right: Right
    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) { self.left = left(); self.right = right() }
    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true; controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = "TurtleGit.RepositoryBrowserDivider"
        let folders = NSSplitViewItem(viewController: NSHostingController(rootView: left))
        folders.minimumThickness = 160; folders.preferredThicknessFraction = 0.28
        let contents = NSSplitViewItem(viewController: NSHostingController(rootView: right))
        contents.minimumThickness = 300
        controller.addSplitViewItem(folders); controller.addSplitViewItem(contents)
        return controller
    }
    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        (controller.splitViewItems[0].viewController as? NSHostingController<Left>)?.rootView = left
        (controller.splitViewItems[1].viewController as? NSHostingController<Right>)?.rootView = right
    }
}
