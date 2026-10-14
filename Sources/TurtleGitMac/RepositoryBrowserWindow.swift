// Adapts RepositoryBrowser.cpp dialog/menu workflows, GPL-2.0-or-later.
// Copyright (C) 2009-2026 TortoiseGit; 2003-2013 TortoiseSVN.
import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

private final class RepositoryBrowserNativeWindow: NSWindow {
    weak var model: RepositoryBrowserWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, firstResponder is NSTableView, event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.control,.option]).isEmpty {
            if event.charactersIgnoringModifiers?.lowercased() == "a", let model, model.active, !model.busy, !model.mutating {
                model.selection = Set(model.entries.map(\.id)); return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "c" { model?.copy(); return true }
        }
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
    private var ownedSheet: NSWindow?
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences:UserDefaults = .standard) {
        model = RepositoryBrowserWindowModel(repository: repository, access: access, revision: revision, preferences:preferences)
        let window = RepositoryBrowserNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = repository.root.lastPathComponent + " – Repository Browser – TurtleGit"
        window.contentMinSize = NSSize(width: 760, height: 440); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RepositoryBrowserDialog(model: model))
        super.init(window: window); window.delegate = self; window.model = model
        window.setContentSize(NSSize(width: 1000, height: 650))
        window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.chooseRevision = { [weak self] in self?.chooseRevision() }
        model.presentFile = { [weak self] content, action in self?.presentFile(content,action:action) }
        model.handleRevertFailure = { [weak self] message in
            guard let self, self.model.active, let window=self.window, window.attachedSheet == nil else { return false }
            let alert = NSAlert(); alert.messageText = "Could not revert file"
            alert.informativeText = message; alert.alertStyle = .warning
            alert.addButton(withTitle:"Continue"); alert.addButton(withTitle:"Cancel")
            self.ownedSheet = alert.window
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for:window) { [weak self] response in
                    if self?.ownedSheet === alert.window { self?.ownedSheet = nil }
                    continuation.resume(returning:self?.model.active == true && response == .alertFirstButtonReturn)
                }
            }
        }
        model.showRevertResult = { [weak self] message in
            guard let self, self.model.active, let window=self.window, window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.messageText = "Revert to this revision"; alert.informativeText = message
            alert.addButton(withTitle:"OK"); self.ownedSheet = alert.window
            alert.beginSheetModal(for:window) { [weak self] _ in
                if self?.ownedSheet === alert.window { self?.ownedSheet = nil }
            }
        }
        model.offerSubmoduleUpdate = { [weak self] entry in
            guard let self, self.model.active, let window=self.window, window.attachedSheet == nil else { return }
            let identity = self.model.generation
            let alert=NSAlert(); alert.messageText="Update submodule?"
            alert.informativeText="Revision " + entry.objectID + " is unavailable in submodule “" + entry.path + "”. Update the submodule to browse it."
            alert.addButton(withTitle:"Update"); alert.addButton(withTitle:"Cancel"); self.ownedSheet=alert.window
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self else { return }
                if self.ownedSheet === alert.window { self.ownedSheet=nil }
                guard self.model.active, self.model.generation == identity, response == .alertFirstButtonReturn else { return }
                self.model.onSubmoduleUpdate(entry.path)
            }
        }
        model.confirmResetColumns = { [weak self] in
            guard let self,self.model.active,let window=self.window,window.attachedSheet==nil else { return false }
            let alert=NSAlert();alert.messageText="Reset columns?";alert.informativeText="Restore the default Repository Browser columns, order and widths?"
            alert.addButton(withTitle:"No");alert.addButton(withTitle:"Yes");self.ownedSheet=alert.window
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for:window) { [weak self] response in
                    if self?.ownedSheet === alert.window { self?.ownedSheet=nil }
                    continuation.resume(returning:self?.model.active == true && response == .alertSecondButtonReturn)
                }
            }
        }
        model.refresh()

        DialogGeometry.attach(window, identifier: "TurtleGit.RepositoryBrowser", legacyName: "TurtleGit.RepositoryBrowser")
    }
    private func chooseRevision() {
        guard model.active, let window, window.attachedSheet == nil else { return }
        let controller = LogWindowController(repository: model.repository, access: model.access, onChoose: { [weak self] entry in
            guard let self, self.model.active else { return }
            self.picker = nil
            if let entry { self.model.revision = entry.hash; self.model.refresh() }
        })
        controller.model.endRevision = model.snapshot?.objectID; controller.model.reload()
        picker = controller
        if let child = controller.window { window.beginSheet(child) }
    }
    private func presentFile(_ content: ComparisonFileContent, action: RepositoryBrowserWindowModel.FileAction) {
        guard model.active, let window, window.attachedSheet == nil else { return }
        if action == .save {
            let panel = NSSavePanel(); panel.title = "Save revision to…"
            panel.nameFieldStringValue = (content.path as NSString).lastPathComponent
            let identity = model.generation; ownedSheet = panel
            panel.beginSheetModal(for:window) { [weak self] response in
                guard let self else { return }
                if self.ownedSheet === panel { self.ownedSheet = nil }
                guard self.model.active, self.model.generation == identity, response == .OK, let url=panel.url else { return }
                do { try content.bytes.write(to:url,options:.atomic) } catch { self.model.error = error.localizedDescription }
            }
        } else if action == .openWith {
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
            let identity = model.generation; ownedSheet = panel
            panel.beginSheetModal(for:window) { [weak self] response in
                guard let self else { return }
                if self.ownedSheet === panel { self.ownedSheet = nil }
                guard self.model.active, self.model.generation == identity else { return }
                if response == .OK, let app=panel.url { self.open(content,action:action,application:app) }
            }
        } else { open(content, action: action) }
    }
    private func open(_ content: ComparisonFileContent, action: RepositoryBrowserWindowModel.FileAction, application: URL? = nil) {
        guard model.active else { return }
        do {
            let identity = model.generation
            let preview = try HistoricalFilePreview.create(content); HistoricalPreviewFiles.retain(preview)
            let failed: @MainActor @Sendable (String?) -> Void = { [weak model] error in
                if let error {
                    HistoricalPreviewFiles.discard(preview.file)
                    if model?.active == true && model?.generation == identity { model?.error = error }
                }
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
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        if let sheet=ownedSheet, window?.attachedSheet === sheet { window?.endSheet(sheet,returnCode:.cancel); sheet.orderOut(nil) }
        ownedSheet = nil
        if let picker {
            if let child=picker.window, window?.attachedSheet === child { window?.endSheet(child,returnCode:.cancel) }
            picker.close(); self.picker = nil
        }
        onClosed()
    }
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
    private(set) var generation = UUID()
    private var menuGeneration = UUID()
    private var loads = Set<String>()
    private var listings: [String: RepositoryBrowserSnapshot] = [:]
    private var requestedDirectory = ""
    private(set) var active = true
    private(set) static var activeOperations = 0
    private var requests: [UUID: OperationCancellation] = [:]
    private var openRequest: UUID?
    private func startRequest() -> (UUID, OperationCancellation) {
        let id = UUID(), cancellation = OperationCancellation()
        requests[id] = cancellation; Self.activeOperations += 1
        return (id, cancellation)
    }
    private func finishRequest(_ id: UUID) {
        if requests.removeValue(forKey:id) != nil { Self.activeOperations -= 1 }
        if openRequest == id { openRequest = nil }
    }
    private func cancelRequests() { requests.values.forEach { $0.cancel() } }
    var handleRevertFailure: (String) async -> Bool = { _ in false }
    var showRevertResult: (String) -> Void = { _ in }
    var onChanged: () -> Void = {}
    var close: () -> Void = {}
    var chooseRevision: () -> Void = {}
    var offerSubmoduleUpdate: (RepositoryBrowserEntry) -> Void = { _ in }
    var onSubmoduleUpdate: (String) -> Void = { _ in }
    let preferences:UserDefaults
    @Published private(set) var columns:RepositoryBrowserColumns
    @Published private(set) var confirmingColumns=false
    var confirmResetColumns: () async -> Bool = { false }
    var canEditColumns:Bool { active && !busy && !mutating && !confirmingQuit && !confirmingColumns }
    func saveColumns(_ value:RepositoryBrowserColumns) {
        guard canEditColumns else { return }
        columns=RepositoryBrowserColumns(visible:value.visible,order:value.order,widths:value.widths);columns.save(preferences)
    }
    func requestResetColumns() {
        guard canEditColumns else { return };confirmingColumns=true
        let identity=generation,(request,cancellation)=startRequest()
        Task { [self] in
            defer { confirmingColumns=false;finishRequest(request) }
            let accepted=await confirmResetColumns()
            guard active,generation==identity,!cancellation.isCancelled,accepted else { return }
            columns=RepositoryBrowserColumns();columns.save(preferences)
        }
    }
    var onLog: (String, String) -> Void = { _, _ in }
    var onBlame: (String, String) -> Void = { _, _ in }
    var onCompare: (String, String) -> Void = { _, _ in }
    var onSubmodule: (SubmoduleComparison, RepositoryBrowserEntry, Bool) -> Void = { _, _, _ in }
    var onPreparedFileCompare: ((PreparedFileComparisonMark, PreparedFileComparisonMark) -> Void)?
    enum FileAction { case open, openWith, alternativeEditor, save }
    var presentFile: (ComparisonFileContent, FileAction) -> Void = { _, _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences:UserDefaults = .standard) { self.repository = repository; self.access = access; self.revision = revision; self.preferences=preferences;self.columns = .load(preferences) }
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
    func invalidate() { active = false; generation = UUID(); cancelRequests() }
    func canReuseForRevision(_ requestedRevision: String) -> Bool {
        active && !busy && !mutating && !confirmingQuit && revision == requestedRevision && snapshot?.revision == requestedRevision && snapshot?.directory == ""
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func refresh() {
        guard active, !mutating, !confirmingQuit, !confirmingColumns else { return }
        cancelRequests()
        let identity = UUID(); generation = identity; busy = true; error = nil; loads = []
        let value = revision, directory = snapshot?.directory ?? "", retainedSelection = selection
        var wanted = expanded
        var parent = directory
        while !parent.isEmpty { wanted.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        wanted.insert("")
        let ordered = wanted.sorted { lhs, rhs in
            let a=lhs.split(separator:"/").count, b=rhs.split(separator:"/").count
            return a == b ? lhs < rhs : a < b
        }
        let (request, cancellation) = startRequest()
        Task { [self, repository, access] in
            defer { finishRequest(request); if active && generation == identity { busy = false }; withExtendedLifetime(access) {} }
            do {
                try validateAccess()
                let root = try await repository.browseRepository(revision:value, cancellation:cancellation)
                var restored = ["":root]
                if root.treeID != nil {
                    for path in ordered where !path.isEmpty {
                        if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                        let ancestor = (path as NSString).deletingLastPathComponent
                        guard let listing = restored[ancestor], listing.entries.contains(where: { $0.path == path && $0.kind == .directory }) else { continue }
                        do { restored[path] = try await repository.browseRepositoryDirectory(root,directory:path,cancellation:cancellation) }
                        catch { if cancellation.isCancelled { throw OperationCancellationFailure.cancelled } /* A removed directory falls back to its surviving ancestor. */ }
                    }
                }
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                guard active, generation == identity else { return }
                var currentPath = directory
                while restored[currentPath] == nil && !currentPath.isEmpty { currentPath = (currentPath as NSString).deletingLastPathComponent }
                let current = restored[currentPath] ?? root
                directories = restored.mapValues(\.entries); listings = restored; requestedDirectory = current.directory
                snapshot = current; expanded = wanted.intersection(Set(restored.keys)); expanded.insert("")
                selection = retainedSelection.intersection(Set(current.entries.map(\.id)))
            } catch { if active && generation == identity && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func loadDirectory(_ path: String, select: Bool) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns, let snapshot, snapshot.treeID != nil else { return }
        let identity = generation
        if select { menuGeneration = UUID(); requestedDirectory = path }
        if let cached = listings[path] {
            if select { self.snapshot = cached; selection = [] }
            return
        }
        guard !loads.contains(path) else { return }; loads.insert(path)
        let (request, cancellation) = startRequest()
        Task { [self, repository, access] in
            defer { finishRequest(request); if active && generation == identity { loads.remove(path) }; withExtendedLifetime(access) {} }
            do {
                try validateAccess()
                let result = try await repository.browseRepositoryDirectory(snapshot,directory:path,cancellation:cancellation)
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                guard active, generation == identity else { return }
                directories[path] = result.entries; listings[path] = result
                if requestedDirectory == path { self.snapshot = result; selection = [] }
            } catch { if active && generation == identity && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func open(_ entry: RepositoryBrowserEntry, action: FileAction = .open) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns, let snapshot, snapshot.entries.contains(entry) else { return }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        if entry.kind == .directory { expanded.insert(entry.path); loadDirectory(entry.path,select:true); return }
        if entry.kind == .submodule && action == .open && !snapshot.bare { loadSubmodule(snapshot,entry:entry,showLog:false); return }
        if let openRequest { requests[openRequest]?.cancel() }
        let (request,cancellation) = startRequest(), identity = generation
        openRequest = request
        Task { [self, repository, access] in
            defer { finishRequest(request); withExtendedLifetime(access) {} }
            do {
                try validateAccess()
                let content = try await repository.repositoryBrowserFile(snapshot,entry:entry,cancellation:cancellation)
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                guard active, generation == identity, openRequest == request else { return }
                presentFile(content,action)
            } catch { if active && generation == identity && openRequest == request && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func dragProvider(_ entry: RepositoryBrowserEntry? = nil, directory: String? = nil) -> NSItemProvider? {
        guard active, !busy, !confirmingQuit, !confirmingColumns, let snapshot, snapshot.objectID != nil,
              entry.map({ snapshot.entries.contains($0) && $0.kind != .submodule }) ?? true else { return nil }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return nil }
        let folder = directory != nil || entry == nil || entry?.kind == .directory
        let name = entry?.name ?? (directory.map { $0.isEmpty ? repository.root.lastPathComponent : ($0 as NSString).lastPathComponent } ?? repository.root.lastPathComponent)
        return RepositoryBrowserDrag.provider(repository: repository, access: access, snapshot: snapshot, entry: entry, directory: directory, name: name, folder: folder)
    }
    func showSubmoduleLog(_ entry: RepositoryBrowserEntry) {
        guard active, !busy, !confirmingQuit, !confirmingColumns, let snapshot, snapshot.entries.contains(entry), entry.kind == .submodule else { return }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        guard !snapshot.bare else { error = "This bare repository has no child working checkout. Open an initialized working repository to show submodule history."; return }
        loadSubmodule(snapshot,entry:entry,showLog:true)
    }
    private func loadSubmodule(_ snapshot: RepositoryBrowserSnapshot, entry: RepositoryBrowserEntry, showLog: Bool) {
        let (request,cancellation) = startRequest(), identity = generation
        busy = true
        Task { [self,repository,access] in
            defer { finishRequest(request); if active && generation == identity { busy = false }; withExtendedLifetime(access) {} }
            do {
                let module = try await repository.repositoryBrowserSubmodule(snapshot,entry:entry,cancellation:cancellation)
                if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                guard active, generation == identity else { return }
                onSubmodule(module,entry,showLog)
            } catch { if active && generation == identity && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func revert(_ entries: [RepositoryBrowserEntry]) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns, let snapshot, !snapshot.bare, !entries.isEmpty,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ snapshot.entries.contains($0) && ![.directory,.submodule].contains($0.kind) }) else { return }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return }
        cancelRequests()
        let (request,cancellation) = startRequest(), identity = generation
        busy = true; mutating = true
        Task { [self, repository, access] in
            defer { finishRequest(request); mutating = false; busy = false; withExtendedLifetime(access) {} }
            var restored = 0, failed = 0, attempted = 0
            for entry in entries {
                guard active, generation == identity, !cancellation.isCancelled else { break }
                attempted += 1
                do {
                    try validateAccess()
                    try await repository.revertRepositoryBrowserFile(snapshot,entry:entry,cancellation:cancellation)
                    restored += 1
                } catch {
                    guard active, generation == identity, !cancellation.isCancelled else { break }
                    failed += 1
                    let proceed = await handleRevertFailure(entry.path + "\n\n" + error.localizedDescription)
                    guard active, generation == identity, !cancellation.isCancelled, proceed else { break }
                }
            }
            guard active, generation == identity, !cancellation.isCancelled else { return }
            onChanged()
            showRevertResult("\(restored) file(s) reverted to \(snapshot.revision)." + (failed == 0 ? "" : "\n\(failed) file(s) failed. \(entries.count - attempted) file(s) were not attempted."))
        }
    }
    func importWorkingComparisonMark(_ access: WorkingComparisonAccess?) {
        guard let access, access.mark.id != lastImportedWorkingMark else { return }
        lastImportedWorkingMark = access.mark.id
        comparisonMark = PreparedFileComparisonMark(path: access.file.path, revision: "", workingAccess: access)
    }
    func markForComparison(_ entry: RepositoryBrowserEntry) {
        guard active, !busy, !confirmingQuit, !confirmingColumns, let snapshot, let revision = snapshot.objectID,
              snapshot.entries.contains(entry), ![.directory, .submodule].contains(entry.kind) else { return }
        comparisonMark = PreparedFileComparisonMark(path: entry.path, revision: revision)
    }
    func compareWithMarkedFile(_ entry: RepositoryBrowserEntry, capturedMark: PreparedFileComparisonMark? = nil) {
        guard active, !busy, !confirmingQuit, !confirmingColumns, let snapshot, let revision = snapshot.objectID, let comparisonMark = capturedMark ?? comparisonMark,
              snapshot.entries.contains(entry), ![.directory, .submodule].contains(entry.kind) else { return }
        onPreparedFileCompare?(comparisonMark, PreparedFileComparisonMark(path: entry.path, revision: revision))
    }
    struct MenuTarget {
        let owner: ObjectIdentifier
        let generation: UUID
        let navigation: UUID
        let revision: String
        let directory: String
        let entries: [RepositoryBrowserEntry]
        let comparisonMark: PreparedFileComparisonMark?
    }
    func menuTarget(_ entries: [RepositoryBrowserEntry] = []) -> MenuTarget? {
        guard canUseMenu, let snapshot, let revision = snapshot.objectID,
              entries.allSatisfy({ snapshot.entries.contains($0) }) else { return nil }
        return MenuTarget(owner:ObjectIdentifier(self),generation:generation,navigation:menuGeneration,revision:revision,directory:snapshot.directory,entries:entries,comparisonMark:comparisonMark)
    }
    func acceptsMenu(_ target: MenuTarget) -> Bool {
        canUseMenu && target.owner == ObjectIdentifier(self) && target.generation == generation && target.navigation == menuGeneration &&
        target.revision == snapshot?.objectID && target.directory == snapshot?.directory &&
        target.entries.allSatisfy { snapshot?.entries.contains($0) == true }
    }
    var canUseMenu: Bool { active && !busy && !mutating && !confirmingQuit && !confirmingColumns }
    func folderObjectID(_ path: String) -> String? {
        guard canUseMenu, let snapshot, snapshot.objectID != nil else { return nil }
        if path.isEmpty { return snapshot.treeID }
        let parent = (path as NSString).deletingLastPathComponent
        return directories[parent == "." ? "" : parent]?.first { $0.path == path && $0.kind == .directory }?.objectID
    }
    func openFolder(_ path: String) {
        guard folderObjectID(path) != nil else { return }
        expanded.insert(path); loadDirectory(path,select:true)
    }
    func folderPromise(_ path: String) -> NSFilePromiseProvider? {
        guard folderObjectID(path) != nil, let snapshot else { return nil }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return nil }
        return RepositoryBrowserFilePromise(repository:repository,access:access,snapshot:snapshot,directory:path).provider()
    }
    func showFolderLog(_ path: String) {
        guard folderObjectID(path) != nil, let revision = snapshot?.objectID else { return }
        onLog(path,revision)
    }
    func copyFolder(_ path: String, hashes: Bool = false, pasteboard: NSPasteboard = .general) {
        guard let hash = folderObjectID(path) else { return }
        let name = path.isEmpty ? repository.root.lastPathComponent : (path as NSString).lastPathComponent
        pasteboard.clearContents(); pasteboard.setString(hashes ? hash : name + "\r\n",forType:.string)
    }
    func showEntryLog(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, snapshot.entries.contains(entry), let revision = snapshot.objectID else { return }
        onLog(entry.path,revision)
    }
    func showEntryBlame(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, !snapshot.bare, snapshot.entries.contains(entry),
              ![.directory,.submodule].contains(entry.kind), let revision = snapshot.objectID else { return }
        onBlame(entry.path,revision)
    }
    func compareEntryToWorkingTree(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, !snapshot.bare, snapshot.entries.contains(entry),
              entry.kind != .directory, let revision = snapshot.objectID else { return }
        onCompare(entry.path,revision)
    }
    func copy(hashes: Bool = false, pasteboard: NSPasteboard = .general, entries: [RepositoryBrowserEntry]? = nil) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns else { return }
        let values = entries ?? selected
        guard let snapshot, !values.isEmpty, values.allSatisfy({ snapshot.entries.contains($0) }) else { return }
        pasteboard.clearContents()
        pasteboard.setString(hashes ? values.map(\.objectID).joined(separator:"\r\n") : values.map { $0.name + "\r\n" }.joined(), forType: .string)
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
                RepositoryBrowserContentsTable(model:model)
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
        if let children = model.directories[path], !children.contains(where: { $0.kind == .directory }) {
            folderButton.padding(.leading,18)
        } else {
            DisclosureGroup(isExpanded:Binding(get:{ model.expanded.contains(path) },set:{ expanded in
                if expanded { model.expanded.insert(path); model.loadDirectory(path,select:false) }
                else { model.expanded.remove(path) }
            })) {
                if let children=model.directories[path] {
                    ForEach(RepositoryBrowserListing.sorted(children).filter { $0.kind == .directory }) { entry in
                        AnyView(RepositoryFolderRow(model:model,path:entry.path,name:entry.name))
                    }
                } else { ProgressView().controlSize(.small) }
            } label: { folderButton }
        }
    }
    private var folderButton: some View {
        RepositoryFolderDragButton(model:model,path:path,name:name).frame(height:24).contextMenu {
            TurtleGitContextMenu {
                if model.folderObjectID(path) != nil, let target = model.menuTarget() {
                    Button { if model.acceptsMenu(target) { model.openFolder(path) } } label: { CommandLabel(title:"Open",icon:.open) }
                    Divider()
                    Button { if model.acceptsMenu(target) { model.showFolderLog(path) } } label: { CommandLabel(title:"Show log",icon:.log) }
                    Divider()
                    Button { if model.acceptsMenu(target) { model.copyFolder(path) } } label: { CommandLabel(title:"Copy to clipboard",icon:.copy) }
                    Button { if model.acceptsMenu(target) { model.copyFolder(path,hashes:true) } } label: { CommandLabel(title:"Copy hash",icon:.copy) }
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

/// Tree and root rows use AppKit's promised-file drag surface, like the list.
@MainActor struct RepositoryFolderDragButton: NSViewRepresentable {
    @ObservedObject var model: RepositoryBrowserWindowModel
    let path: String
    let name: String
    func makeNSView(context: Context) -> RepositoryFolderNativeButton { RepositoryFolderNativeButton() }
    func updateNSView(_ button: RepositoryFolderNativeButton, context: Context) {
        button.model=model; button.path=path; button.title=name
        button.isEnabled=model.canUseMenu
        button.layer?.backgroundColor=(model.snapshot?.directory == path ? NSColor.controlAccentColor.withAlphaComponent(0.2) : NSColor.clear).cgColor
    }
}
@MainActor final class RepositoryFolderNativeButton: NSButton, NSDraggingSource {
    weak var model: RepositoryBrowserWindowModel?
    var path=""
    override init(frame: NSRect) {
        super.init(frame:frame); isBordered=false; alignment = .left; imagePosition = .imageLeft
        image=NSWorkspace.shared.icon(for:.folder); imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize:12); cell?.lineBreakMode = .byTruncatingTail
        wantsLayer=true; layer?.cornerRadius=3; target=self; action=#selector(openFolder)
        setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    }
    convenience init() { self.init(frame:.zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func openFolder() { model?.openFolder(path) }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let owner=window, let model, let target=model.menuTarget() else { return }
        let start=convert(event.locationInWindow,from:nil)
        highlight(true); defer { highlight(false) }
        while self.window === owner && model.acceptsMenu(target) {
            guard let next=owner.nextEvent(matching:[.leftMouseDragged,.leftMouseUp,.keyDown],until:Date().addingTimeInterval(0.1),inMode:.eventTracking,dequeue:true) else { continue }
            if next.type == .keyDown { if next.keyCode == 53 { return }; continue }
            if next.type == .leftMouseUp { if bounds.contains(convert(next.locationInWindow,from:nil)) { performClick(nil) }; return }
            let point=convert(next.locationInWindow,from:nil)
            guard hypot(point.x-start.x,point.y-start.y) >= 4, let promise=model.folderPromise(path) else { continue }
            let item=NSDraggingItem(pasteboardWriter:promise)
            let preview=NSImage(size:bounds.size)
            if let bitmap=bitmapImageRepForCachingDisplay(in:bounds) { cacheDisplay(in:bounds,to:bitmap); preview.addRepresentation(bitmap) }
            item.setDraggingFrame(bounds,contents:preview)
            beginDraggingSession(with:[item],event:next,source:self); return
        }
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .copy }
}
