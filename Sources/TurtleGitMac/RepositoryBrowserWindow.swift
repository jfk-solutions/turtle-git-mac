// Adapts RepositoryBrowser.cpp dialog/menu workflows, GPL-2.0-or-later.
// Copyright (C) 2009-2026 TortoiseGit; 2003-2013 TortoiseSVN.
import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

private final class RepositoryBrowserNativeWindow: NSWindow {
    weak var model: RepositoryBrowserWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, firstResponder is NSTableView, !(firstResponder is NSOutlineView), event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.control,.option]).isEmpty {
            if event.charactersIgnoringModifiers?.lowercased() == "a", let model, model.active, !model.busy, !model.mutating {
                model.selection = Set(model.entries.map(\.id)); return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "c" { model?.copy(); return true }
        }
        if attachedSheet == nil, event.keyCode == 96 { model?.refresh(); return true }
        if attachedSheet == nil, [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.option), firstResponder is NSTableView, !(firstResponder is NSOutlineView) {
            if let model, model.selected.count == 1, let entry = model.selected.first { model.open(entry) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class RepositoryBrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: RepositoryBrowserWindowModel
    var onClosed: () -> Void = {}
    private(set) var picker: LogWindowController?
    private var pickerIdentity:UUID?
    var configureLogPicker:(LogWindowModel)->Void = { _ in }
    private var ownedSheet: NSWindow?
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences:UserDefaults = .standard) {
        model = RepositoryBrowserWindowModel(repository: repository, access: access, revision: revision, preferences:preferences)
        let window = RepositoryBrowserNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Repository Browser", preferences: preferences)
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
        guard model.canUseMenu,picker == nil,let window,window.attachedSheet == nil else { return }
        let identity=UUID(),generation=model.generation
        pickerIdentity=identity;model.choosingRevision=true
        let controller=LogWindowController(repository:model.repository,access:model.access,onChoose:{ [weak self] entry in
            guard let self,self.pickerIdentity==identity else { return }
            self.pickerIdentity=nil;self.picker=nil;self.model.choosingRevision=false
            guard self.model.active,self.model.generation==generation else { return }
            if let entry { self.model.revision=entry.hash;self.model.refresh() }
        },labelDefaults:model.preferences,initialRevision:model.snapshot?.objectID)
        configureLogPicker(controller.model)
        picker=controller
        if let child=controller.window {
            child.appearance=window.appearance;child.alphaValue=window.alphaValue
            window.beginSheet(child)
        } else {pickerIdentity=nil;picker=nil;model.choosingRevision=false}
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
            if action == .alternativeEditor { AlternativeEditor.open(preview.file, preferences: model.preferences, permissions: model.access.map { [$0] } ?? [], completion: failed) }
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
        pickerIdentity=nil;model.choosingRevision=false
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
    @Published private(set) var revisionLabel:String
    @Published var choosingRevision=false
    var clipboard:NSPasteboard = .general
    @Published private(set) var snapshot: RepositoryBrowserSnapshot?
    @Published private(set) var directories: RepositoryBrowserPathMap<[RepositoryBrowserEntry]> = [:]
    @Published var expanded: RepositoryBrowserPathSet = [""]
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
    private var loads = RepositoryBrowserPathSet()
    private var listings: RepositoryBrowserPathMap<RepositoryBrowserSnapshot> = [:]
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
    var canEditColumns:Bool { canUseMenu }
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
    init(repository: GitRepository, access: RepositoryAccessLease?, revision: String, preferences:UserDefaults = .standard) { self.repository = repository; self.access = access; self.revision = revision;self.revisionLabel=revision; self.preferences=preferences;self.columns = .load(preferences) }
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
        let name=snapshot?.directory.isEmpty == false ? (snapshot!.directory as NSString).lastPathComponent : repository.root.lastPathComponent
        return "\(name): Showing \(values.filter { ![.directory, .submodule].contains($0.kind) }.count) files, \(values.filter { $0.kind == .submodule }.count) submodules and \(values.filter { $0.kind == .directory }.count) folders, \(values.count) items in total"
    }
    func sizeText(_ entry: RepositoryBrowserEntry) -> String { entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "" }
    func invalidate() { active = false; generation = UUID(); cancelRequests() }
    func canReuseForRevision(_ requestedRevision: String) -> Bool {
        canUseMenu && revision == requestedRevision && snapshot?.revision == requestedRevision && snapshot?.directory == ""
    }
    private func validateAccess() throws {
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func refresh() {
        guard active,!mutating,!confirmingQuit,!confirmingColumns,!choosingRevision else { return }
        cancelRequests()
        let identity = UUID(); generation = identity; busy = true; error = nil; loads = []
        let value = revision, directory = snapshot?.directory ?? "", retainedSelection = selection
        var wanted = expanded
        var parent = directory
        while !parent.isEmpty { wanted.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        wanted.insert("")
        let ordered = wanted.sorted { lhs, rhs in
            let a=lhs.split(separator:"/").count, b=rhs.split(separator:"/").count
            return a == b ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8) : a < b
        }
        let (request, cancellation) = startRequest()
        Task { [self, repository, access] in
            defer { finishRequest(request); if active && generation == identity { busy = false }; withExtendedLifetime(access) {} }
            do {
                try validateAccess()
                let root = try await repository.browseRepository(revision:value, cancellation:cancellation)
                var label=value,labelError:String?
                do {label=try await repository.repositoryBrowserRevisionLabel(root,cancellation:cancellation)}
                catch {if cancellation.isCancelled {throw OperationCancellationFailure.cancelled};labelError=error.localizedDescription}
                var restored:RepositoryBrowserPathMap<RepositoryBrowserSnapshot> = ["":root]
                if root.treeID != nil {
                    for path in ordered where !path.isEmpty {
                        if cancellation.isCancelled { throw OperationCancellationFailure.cancelled }
                        let ancestor = (path as NSString).deletingLastPathComponent
                        guard let listing = restored[ancestor], listing.entries.contains(where: { RepositoryBrowserPathIdentity.equal($0.path,path) && $0.kind == .directory }) else { continue }
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
                snapshot = current;revisionLabel=label;error=labelError; expanded = wanted.intersection(restored.keys); expanded.insert("")
                selection = retainedSelection.intersection(Set(current.entries.map(\.id)))
            } catch { if active && generation == identity && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func loadDirectory(_ path: String, select: Bool) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns,!choosingRevision, let snapshot, snapshot.treeID != nil else { return }
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
                if RepositoryBrowserPathIdentity.equal(requestedDirectory,path) { self.snapshot = result; selection = [] }
            } catch { if active && generation == identity && !cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func open(_ entry: RepositoryBrowserEntry, action: FileAction = .open) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns,!choosingRevision, let snapshot, snapshot.entries.contains(entry) else { return }
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
        guard active, !busy, !confirmingQuit, !confirmingColumns,!choosingRevision, let snapshot, snapshot.objectID != nil,
              entry.map({ snapshot.entries.contains($0) && $0.kind != .submodule }) ?? true else { return nil }
        do { try validateAccess() } catch { self.error = error.localizedDescription; return nil }
        let folder = directory != nil || entry == nil || entry?.kind == .directory
        let name = entry?.name ?? (directory.map { $0.isEmpty ? repository.root.lastPathComponent : ($0 as NSString).lastPathComponent } ?? repository.root.lastPathComponent)
        return RepositoryBrowserDrag.provider(repository: repository, access: access, snapshot: snapshot, entry: entry, directory: directory, name: name, folder: folder)
    }
    func showSubmoduleLog(_ entry: RepositoryBrowserEntry) {
        guard active, !busy, !confirmingQuit, !confirmingColumns,!choosingRevision, let snapshot, snapshot.entries.contains(entry), entry.kind == .submodule else { return }
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
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns,!choosingRevision, let snapshot, !snapshot.bare, !entries.isEmpty,
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
        guard active, !busy, !confirmingQuit, !confirmingColumns,!choosingRevision, let snapshot, let revision = snapshot.objectID,
              snapshot.entries.contains(entry), ![.directory, .submodule].contains(entry.kind) else { return }
        comparisonMark = PreparedFileComparisonMark(path: entry.path, revision: revision)
    }
    func compareWithMarkedFile(_ entry: RepositoryBrowserEntry, capturedMark: PreparedFileComparisonMark? = nil) {
        guard active, !busy, !confirmingQuit, !confirmingColumns,!choosingRevision, let snapshot, let revision = snapshot.objectID, let comparisonMark = capturedMark ?? comparisonMark,
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
        target.revision == snapshot?.objectID && snapshot.map { RepositoryBrowserPathIdentity.equal(target.directory,$0.directory) } == true &&
        target.entries.allSatisfy { snapshot?.entries.contains($0) == true }
    }
    var canUseMenu: Bool { active && !busy && !mutating && !confirmingQuit && !confirmingColumns && !choosingRevision }
    func folderObjectID(_ path: String) -> String? {
        guard canUseMenu, let snapshot, snapshot.objectID != nil else { return nil }
        if path.isEmpty { return snapshot.treeID }
        let parent = (path as NSString).deletingLastPathComponent
        return directories[parent == "." ? "" : parent]?.first { RepositoryBrowserPathIdentity.equal($0.path,path) && $0.kind == .directory }?.objectID
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
        guard snapshot?.treeID != revision else { error = "Tree objects contain file snapshots, but have no commit history or blame information. Choose a commit or tag to view history."; return }
        onLog(path,revision)
    }
    func copyFolder(_ path: String, hashes: Bool = false, pasteboard:NSPasteboard? = nil) {
        guard let hash = folderObjectID(path) else { return }
        let name = path.isEmpty ? repository.root.lastPathComponent : (path as NSString).lastPathComponent
        let pasteboard=pasteboard ?? clipboard
        pasteboard.clearContents(); pasteboard.setString(hashes ? hash : name + "\r\n",forType:.string)
    }
    func showEntryLog(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, snapshot.entries.contains(entry), let revision = snapshot.objectID else { return }
        guard snapshot.treeID != revision else { error = "Tree objects contain file snapshots, but have no commit history or blame information. Choose a commit or tag to view history."; return }
        onLog(entry.path,revision)
    }
    func showEntryBlame(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, !snapshot.bare, snapshot.entries.contains(entry),
              ![.directory,.submodule].contains(entry.kind), let revision = snapshot.objectID else { return }
        guard snapshot.treeID != revision else { error = "Tree objects contain file snapshots, but have no commit history or blame information. Choose a commit or tag to view history."; return }
        onBlame(entry.path,revision)
    }
    func compareEntryToWorkingTree(_ entry: RepositoryBrowserEntry) {
        guard canUseMenu, let snapshot, !snapshot.bare, snapshot.entries.contains(entry),
              entry.kind != .directory, let revision = snapshot.objectID else { return }
        let identity=generation,navigation=menuGeneration,callback=onCompare
        let (request,cancellation)=startRequest();busy=true
        Task { [self,repository,access] in
            defer {finishRequest(request);if active,generation==identity {busy=false};withExtendedLifetime(access){}}
            do {
                try validateAccess()
                try await repository.validateRepositoryBrowserWorkingPath(snapshot,entry:entry,cancellation:cancellation)
                guard active,generation==identity,menuGeneration==navigation,!cancellation.isCancelled else {return}
                callback(entry.path,revision)
            } catch {if active,generation==identity,!cancellation.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func copy(hashes: Bool = false, pasteboard:NSPasteboard? = nil, entries: [RepositoryBrowserEntry]? = nil) {
        guard active, !busy, !mutating, !confirmingQuit, !confirmingColumns,!choosingRevision else { return }
        let values = entries ?? selected
        guard let snapshot, !values.isEmpty, values.allSatisfy({ snapshot.entries.contains($0) }) else { return }
        let pasteboard=pasteboard ?? clipboard
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
                Button(model.revisionLabel) { model.chooseRevision() }.lineLimit(1).frame(minWidth:180,maxWidth:300).help(model.revisionLabel + ((model.snapshot?.objectID).map { "\n" + $0 } ?? "")).disabled(!model.canUseMenu)
            }
            RepositoryBrowserSplit {
                RepositoryBrowserFolderTree(model:model)
            } right: {
                RepositoryBrowserContentsTable(model:model)
            }.border(Color.secondary.opacity(0.4))
            HStack {
                Text(model.info).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                if model.busy { ProgressView().controlSize(.small) }
                Button("OK", action: model.close).keyboardShortcut(.defaultAction).disabled(model.mutating)
                Button("Cancel", action: model.close).keyboardShortcut(.cancelAction).disabled(model.mutating)
                Button("Help") { TurtleGitHelp.show(.browser) }
            }
        }.padding(12).disabled(model.confirmingQuit || model.choosingRevision).alert("Repository Browser", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
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

/// Native historical folder navigation. Items keep identity across lazy loads;
/// every action still validates the pinned browser generation and permission.
@MainActor struct RepositoryBrowserFolderTree: NSViewRepresentable {
    @ObservedObject var model: RepositoryBrowserWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeView() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update() }
    static func dismantleNSView(_ view:NSScrollView, coordinator:Coordinator) { coordinator.retired=true;coordinator.outline?.delegate=nil;coordinator.outline?.dataSource=nil }

    @MainActor final class Node: NSObject {
        let path:String
        init(_ path:String) { self.path=path }
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let model:RepositoryBrowserWindowModel
        weak var outline:RepositoryBrowserFolderOutline?
        private var nodes:RepositoryBrowserPathMap<Node>=["":Node("")]
        private var children:RepositoryBrowserPathMap<[RepositoryBrowserEntry]>=[:]
        private var generation:UUID?
        private var updating=false
        var retired=false
        var available:Bool { !retired && model.canUseMenu && outline?.window?.attachedSheet==nil }
        init(_ model:RepositoryBrowserWindowModel) { self.model=model }
        func node(_ path:String) -> Node { if let value=nodes[path] { return value };let value=Node(path);nodes[path]=value;return value }
        func folders(_ path:String) -> [RepositoryBrowserEntry] { RepositoryBrowserListing.sorted(children[path] ?? []).filter { $0.kind == .directory } }
        func makeView() -> NSScrollView {
            let scroll=NSScrollView(),tree=RepositoryBrowserFolderOutline()
            scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true
            let column=NSTableColumn(identifier:.init("folder"));column.title="Folders";column.width=250;column.minWidth=100
            tree.addTableColumn(column);tree.outlineTableColumn=column;tree.headerView=nil
            tree.rowHeight=23;tree.indentationPerLevel=16;tree.intercellSpacing=NSSize(width:2,height:2)
            tree.allowsMultipleSelection=false;tree.allowsEmptySelection=false;tree.allowsTypeSelect=true;tree.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            tree.setAccessibilityLabel("Repository folders");tree.dataSource=self;tree.delegate=self
            tree.target=self;tree.doubleAction=#selector(openSelected)
            tree.openSelection={ [weak self] in self?.openSelected() }
            tree.copySelection={ [weak self] in self?.copySelected() }
            tree.contextSelection={ [weak self] row in self?.selectContext(row) }
            let menu=NSMenu();menu.delegate=self;menu.autoenablesItems=false;tree.menu=menu
            tree.setDraggingSourceOperationMask(.copy,forLocal:false);tree.setDraggingSourceOperationMask(.copy,forLocal:true)
            scroll.documentView=tree;outline=tree;update();return scroll
        }
        func update() {
            guard !retired,let outline else { return };updating=true;defer { updating=false }
            if children != model.directories || generation != model.generation {
                children=model.directories;generation=model.generation
                // Retain identity only for paths belonging to the current tree.
                let paths=RepositoryBrowserPathSet([""]+children.values.flatMap { $0.filter { $0.kind == .directory }.map(\.path) })
                nodes=nodes.filter { paths.contains($0.key) };outline.reloadData()
            }
            for path in model.expanded.sorted(by:{ $0.split(separator:"/").count < $1.split(separator:"/").count }) {
                if path.isEmpty || model.folderObjectID(path) != nil { outline.expandItem(node(path)) }
            }
            if let path=model.snapshot?.directory {
                let row=outline.row(forItem:node(path))
                if row>=0 && outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);outline.scrollRowToVisible(row) }
            }
            // Sheets suppress actions through available, but must not leave the
            // outline disabled after dismissal without a model publication.
            outline.isEnabled = !retired && model.canUseMenu
        }
        func outlineView(_ outlineView:NSOutlineView, numberOfChildrenOfItem item:Any?) -> Int { item == nil ? 1 : (item as? Node).map { folders($0.path).count } ?? 0 }
        func outlineView(_ outlineView:NSOutlineView, child index:Int, ofItem item:Any?) -> Any {
            guard let parent=item as? Node else { return node("") };return node(folders(parent.path)[index].path)
        }
        func outlineView(_ outlineView:NSOutlineView, isItemExpandable item:Any) -> Bool {
            guard let item=item as? Node else { return false };return children[item.path] == nil || !folders(item.path).isEmpty
        }
        func outlineView(_ outlineView:NSOutlineView, viewFor tableColumn:NSTableColumn?, item:Any) -> NSView? {
            guard let node=item as? Node else { return nil }
            let cell=NSTableCellView(),label=NSTextField(labelWithString:node.path.isEmpty ? model.repository.root.lastPathComponent : (node.path as NSString).lastPathComponent)
            let image=NSImageView(image:NSWorkspace.shared.icon(for:.folder));cell.imageView=image;cell.textField=label
            label.font = .systemFont(ofSize:12);label.lineBreakMode = .byTruncatingMiddle;label.maximumNumberOfLines=1
            cell.toolTip=node.path.isEmpty ? model.repository.root.path : node.path
            cell.addSubview(image);cell.addSubview(label);image.translatesAutoresizingMaskIntoConstraints=false;label.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:2),image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),image.widthAnchor.constraint(equalToConstant:16),image.heightAnchor.constraint(equalToConstant:16),label.leadingAnchor.constraint(equalTo:image.trailingAnchor,constant:5),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-3),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        func outlineView(_ outlineView:NSOutlineView, typeSelectStringFor tableColumn:NSTableColumn?, item:Any) -> String? {
            (item as? Node).map { $0.path.isEmpty ? model.repository.root.lastPathComponent : ($0.path as NSString).lastPathComponent }
        }
        func outlineView(_ outlineView:NSOutlineView, shouldExpandItem item:Any) -> Bool { updating || available }
        func outlineView(_ outlineView:NSOutlineView, shouldCollapseItem item:Any) -> Bool { updating || available }
        func outlineView(_ outlineView:NSOutlineView, shouldSelectItem item:Any) -> Bool { updating || available }
        func outlineViewItemDidExpand(_ notification:Notification) {
            guard !updating,available,let item=notification.userInfo?["NSObject"] as? Node else { return }
            model.expanded.insert(item.path);model.loadDirectory(item.path,select:false)
        }
        func outlineViewItemDidCollapse(_ notification:Notification) {
            guard !updating,available,let item=notification.userInfo?["NSObject"] as? Node else { return }
            model.expanded.remove(item.path)
        }
        func outlineViewSelectionDidChange(_ notification:Notification) {
            guard !updating,available,let outline,let item=outline.item(atRow:outline.selectedRow) as? Node else { return }
            model.loadDirectory(item.path,select:true)
        }
        @objc func openSelected() {
            guard available,let outline,let item=outline.item(atRow:outline.selectedRow) as? Node else { return }
            model.openFolder(item.path)
        }
        func copySelected() {
            guard available,let outline,let item=outline.item(atRow:outline.selectedRow) as? Node else { return };model.copyFolder(item.path)
        }
        func selectContext(_ row:Int) {
            guard available,let outline,row>=0 else { return };updating=true
            outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);updating=false
        }
        private final class Invocation:NSObject {
            let path:String,target:RepositoryBrowserWindowModel.MenuTarget,command:Int
            var used=false
            init(path:String,target:RepositoryBrowserWindowModel.MenuTarget,command:Int) { self.path=path;self.target=target;self.command=command }
        }
        func menuNeedsUpdate(_ menu:NSMenu) {
            menu.removeAllItems()
            guard available,let outline,let item=outline.item(atRow:outline.selectedRow) as? Node,model.folderObjectID(item.path) != nil,let target=model.menuTarget() else { return }
            for (index,title,icon) in [(0,"Open",MenuIcon.open),(1,"Show log",.log),(2,"Copy to clipboard",.copy),(3,"Copy hash",.copy)] {
                if index==1 || index==2 { menu.addItem(.separator()) }
                let entry=NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"");entry.target=self
                entry.image=icon.contextImage(defaults:model.preferences);entry.representedObject=Invocation(path:item.path,target:target,command:index);menu.addItem(entry)
            }
        }
        @objc func invoke(_ sender:NSMenuItem) {
            guard available,let action=sender.representedObject as? Invocation,!action.used,model.acceptsMenu(action.target) else { return }
            action.used=true
            switch action.command { case 0:model.openFolder(action.path);case 1:model.showFolderLog(action.path);case 2:model.copyFolder(action.path);case 3:model.copyFolder(action.path,hashes:true);default:break }
        }
        func outlineView(_ outlineView:NSOutlineView, pasteboardWriterForItem item:Any) -> NSPasteboardWriting? {
            guard available,let item=item as? Node else { return nil };return model.folderPromise(item.path)
        }
    }
}
@MainActor final class RepositoryBrowserFolderOutline:NSOutlineView {
    var openSelection:()->Void = {},copySelection:()->Void = {}
    var contextSelection:(Int)->Void = { _ in }
    override func keyDown(with event:NSEvent) {
        if isEnabled,event.keyCode==36 || event.keyCode==76 { openSelection();return }
        super.keyDown(with:event)
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if isEnabled,event.modifierFlags.intersection([.command,.control,.option]) == .command,event.charactersIgnoringModifiers?.lowercased()=="c" { copySelection();return true }
        return super.performKeyEquivalent(with:event)
    }
    override func menu(for event:NSEvent) -> NSMenu? {
        guard isEnabled else { return nil };let clicked=row(at:convert(event.locationInWindow,from:nil));guard clicked>=0 else { return nil }
        contextSelection(clicked);menu?.update();return menu
    }
}
