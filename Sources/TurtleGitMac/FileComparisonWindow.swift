import AppKit
import UniformTypeIdentifiers
import SwiftUI
import TurtleGitCore

private extension FileComparisonDocument {
    func exchangingSides() -> Self { replacingPane(base:true,content:destination).replacingPane(base:false,content:base) }
}

@MainActor class FileComparisonNativeWindow: NSWindow, ImageComparisonKeyRouting {
    weak var imageKeyModel: ImageComparisonViewModel?
    var imageKeyOwner: UUID?
    var imageKeysRetired = false
    weak var model: FileComparisonWindowModel?
    var openMergeDocument: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let owner = delegate as? FileComparisonWindowController,owner.editorCommandMenu?.performKeyEquivalent(event) == true { return true }
        if let imageKeyModel, !imageKeysRetired {
            if attachedSheet == nil, (firstResponder as? NSTextView)?.isFieldEditor != true,
               imageKeyModel.performKey(event, window: self) { return true }
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, event.charactersIgnoringModifiers?.lowercased() == "o" { openMergeDocument(); return true }
        if (firstResponder as? NSTextView)?.isFieldEditor != true, MergeFindInterface.performKey(event, in: model?.activeFindText) { return true }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", (firstResponder as? NSTextView)?.isFieldEditor != true {
            if flags.contains(.shift) { model?.redo() } else { model?.undo() }; return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "s" { model?.save(); return true }
        if flags == .command, event.charactersIgnoringModifiers == "f" { model?.find(.showFindInterface); return true }
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            model?.find(flags.contains(.shift) ? .previousMatch : .nextMatch); return true
        }
        if flags == .control, event.charactersIgnoringModifiers?.lowercased() == "g", let text = firstResponder as? FileComparisonTextView {
            text.goToSourceLine(nil); return true
        }
        if event.keyCode == 96 { (delegate as? FileComparisonWindowController)?.reloadEditor(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class FileComparisonWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: FileComparisonWindowModel
    private(set) var editorToolbar: MergeEditorToolbar?
    private(set) var editorCommandMenu: MergeEditorCommandMenu?
    private(set) var imageToolbar: ImageEditorToolbar?
    var showEditorHelp: () -> Void = { TurtleGitHelp.show(.compare) }
    private let editorFileMenu = MergeEditorFileMenu()
    private weak var patchMenu: NSMenu?
    private var patchMenuItem: NSMenuItem?
    func windowDidBecomeKey(_ notification: Notification) {
        refreshScopedFileMenu()
    }
    func refreshScopedFileMenu() {
        editorFileMenu.remove();removePatchMenu()
        if model.imageComparison != nil {
            editorCommandMenu?.remove()
            editorFileMenu.install(target:self,open:#selector(openMergeDocument(_:)),reload:#selector(reloadEditor(_:)),images:true)
        } else { editorCommandMenu?.install() }
    }
    func windowDidResignKey(_ notification: Notification) { editorCommandMenu?.remove(); removePatchMenu(); editorFileMenu.remove() }
    private func removePatchMenu() {
        if let item = patchMenuItem, let menu = patchMenu, menu.items.contains(item) { menu.removeItem(item) }
        patchMenuItem = nil; patchMenu = nil
    }
    func detachForReplacement() {
        imageToolbar?.retire(); editorCommandMenu?.retire(); editorToolbar?.retire(); editorFileMenu.remove(); removePatchMenu(); model.retireImageLoader(); model.resetHistory(); model.window = nil
    }
    @objc func createPatchFile(_ sender: Any?) { model.createUnifiedPatch() }
    @objc func reloadEditor(_ sender: Any?) {
        guard !preparingReplacement, editorOpenWorkflow == nil, window?.attachedSheet == nil else { return }; model.load()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if model.imageComparison != nil, item.action == #selector(openMergeDocument(_:)) || item.action == #selector(reloadEditor(_:)) { return model.imageCommandsAllowed && !preparingReplacement && editorOpenWorkflow == nil }
        if item.action == #selector(openMergeDocument(_:)) || item.action == #selector(reloadEditor(_:)) { return !preparingReplacement && !preparingReplacement && editorOpenWorkflow == nil && !model.busy && !model.hasPendingEditorChoice && !model.filtering && !model.confirmingQuit && window?.attachedSheet == nil }
        return item.action == #selector(createPatchFile(_:)) && model.canCreateUnifiedPatch
    }
    var onClosed: () -> Void = {}
    var editorOpenWorkflow: MergeEditorOpenWorkflow?
    var makeEditorOpenWorkflow: (NSWindow, [RepositoryAccessLease], UserDefaults) -> MergeEditorOpenWorkflow = { MergeEditorOpenWorkflow(window: $0, permissions: $1, preferences: $2) }
    var replacementOwner: MergeEditorReplacementOwner?
    weak var sharedReplacementOwner: MergeEditorReplacementOwner?
    var preparingReplacement: Bool { (sharedReplacementOwner ?? replacementOwner)?.preparingPatch == true }
    @objc func openMergeDocument(_ sender: Any?) {
        if model.imageComparison != nil { model.imageViewerModel.perform(.open); return }
        guard !preparingReplacement, editorOpenWorkflow == nil, let window, !model.busy, !model.hasPendingEditorChoice, !model.filtering, !model.confirmingQuit, window.attachedSheet == nil else { return }
        let workflow = makeEditorOpenWorkflow(window, model.openPermissions, model.comparisonDefaults)
        editorOpenWorkflow = workflow
        workflow.onClosed = { [weak self] in self?.editorOpenWorkflow = nil }
        workflow.accept = { [weak self] request, permissions in try self?.replaceEditor(request, permissions: permissions) }
        workflow.start(dirty: model.dirty, description: model.unsavedFilesDescription, save: { [weak self] completion in self?.model.saveAll(completion: completion) })
    }
    func replaceEditor(_ request: MergeOpenRequest, permissions: [RepositoryAccessLease]) throws {
        guard let window, !model.busy, !model.hasPendingEditorChoice, !model.filtering, !model.confirmingQuit else { return }
        let owner = sharedReplacementOwner ?? replacementOwner ?? MergeEditorReplacementOwner(onClosed: onClosed)
        if sharedReplacementOwner == nil { replacementOwner = owner }
        try owner.replace(request, permissions: permissions, preferences: model.comparisonDefaults, window: window, previous: self)
    }
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, path: String) {
        self.init(model: FileComparisonWindowModel(repository: repository, access: access, snapshot: snapshot, path: path))
    }
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, conflict: ConflictBaseComparison, preferences: UserDefaults = .standard) {
        let model = FileComparisonWindowModel(repository: repository, access: access, conflict: conflict)
        model.comparisonDefaults = preferences; self.init(model: model)
    }
    convenience init(images: ImageFileComparison, permissions: [RepositoryAccessLease], preferences: UserDefaults = .standard) {
        let model = FileComparisonWindowModel(images: images, permissions: permissions); model.comparisonDefaults = preferences
        self.init(model: model)
    }
    convenience init(comparison: WorkingFileComparison, permissions: [RepositoryAccessLease], preferences: UserDefaults = .standard, deferInitialLoad: Bool = false) {
        let model = FileComparisonWindowModel(comparison: comparison, permissions: permissions)
        model.comparisonDefaults = preferences; model.initialLoadDeferred = deferInitialLoad
        self.init(model: model)
    }
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, comparison: HistoricalWorkingFileComparison, permission: RepositoryAccessLease) {
        self.init(model: FileComparisonWindowModel(repository: repository, access: access, comparison: comparison, permission: permission))
    }
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, changeSets: CommitChangeSetComparison) {
        self.init(model: FileComparisonWindowModel(repository: repository, access: access, changeSets: changeSets))
    }
    convenience init(readOnly document: FileComparisonDocument, root: URL, preferences: UserDefaults = .standard) {
        let model = FileComparisonWindowModel(readOnly: document, root: root); model.comparisonDefaults = preferences
        self.init(model: model)
    }
    private init(model: FileComparisonWindowModel) {
        self.model = model
        let path = model.path
        let window = TextConflictNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(path) – TurtleGitMerge"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: 440)
        window.contentViewController = NSHostingController(rootView: FileComparisonDialog(model: model))
        super.init(window: window); TurtleGitHelp.attach(window, topic: .compare); window.model = model; window.openMergeDocument = { [weak self] in self?.openMergeDocument(nil) }; window.delegate = self; model.window = window; model.installMarkedSavePrompt()
        model.externalDidOpen = { [weak window] in window?.close() }
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.center()
        installEditorToolbar()
        imageToolbar = ImageEditorToolbar.comparison(self)

        DialogGeometry.attach(window, identifier: "TurtleGit.TwoFileDiff", legacyName: "TurtleGit.TwoFileDiff")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !preparingReplacement, editorOpenWorkflow == nil else { return false }
        if model.cancelLoadForClose() { return false }
        guard sender.attachedSheet == nil, !model.busy, !model.hasPendingEditorChoice, !model.confirmingQuit else { return false }
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to “\(model.unsavedFilesDescription)” before closing?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.saveAll { [weak self] saved in if saved { self?.window?.performClose(nil) } }; return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        MergeLineRuler.retire(in:window?.contentView)
        imageToolbar?.retire(); editorCommandMenu?.retire(); editorToolbar?.retire(); editorFileMenu.remove(); removePatchMenu()
        if let window = window as? FileComparisonNativeWindow { window.imageKeyModel?.presentation.retire(); window.imageKeyModel?.retire(); window.imageKeysRetired = true; window.imageKeyModel = nil; window.imageKeyOwner = nil }
        editorOpenWorkflow?.retire(); editorOpenWorkflow = nil; model.retireImageLoader(); model.resetHistory(); onClosed()
    }
    func installEditorToolbar() {
        editorCommandMenu?.retire();editorToolbar?.retire();editorToolbar = MergeEditorToolbar.comparison(self)
        editorCommandMenu = MergeEditorCommandMenu.comparison(self)
        if window?.isKeyWindow == true { editorCommandMenu?.install() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class FileComparisonWindowModel: ObservableObject {
    private let repository: GitRepository?
    private var historicalWorkingComparison: HistoricalWorkingFileComparison?
    private var workingComparison: WorkingFileComparison?
    private var standaloneImages: ImageFileComparison?
    private var imageLoader: ImageLoadWindowController?
    var retainedImageModel: ImageComparisonViewModel?
    var imageCommandsAllowed: Bool { contextCommandsAllowed && imageComparison != nil && imageLoader == nil }
    var imageViewerModel: ImageComparisonViewModel {
        if let retainedImageModel { return retainedImageModel }
        let image = ImageComparisonViewModel(presentation: imagePresentation)
        image.commandsAllowed = { [weak self] in self?.imageCommandsAllowed == true }
        image.reloadImages = { [weak self] in if self?.imageCommandsAllowed == true { self?.load() } }
        retainedImageModel = image; return image
    }
    var makeImageLoader: (String, [RepositoryAccessLease]) -> ImageLoadWindowController = { ImageLoadWindowController(leftPath: $0, permissions: $1) }
    private var workingPermissions: [RepositoryAccessLease] = []
    private(set) var paneTargets: [Bool: SavedMergePane] = [:]
    private var originalPaneDocument: FileComparisonDocument?
    func savedPaneURL(base: Bool) -> URL? { paneTargets[base]?.url }
    private func mutablePane(_ base: Bool) -> Bool { sourceSnapshotRoot == nil || paneTargets[base] != nil }
    private func savingContext(_ document: FileComparisonDocument) -> FileComparisonDocument {
        guard let originalPaneDocument else { return document }
        return paneTargets.keys.reduce(document) { $0.replacingPane(base: $1, content: $1 ? originalPaneDocument.base : originalPaneDocument.destination) }
    }
    private var sourceSnapshotRoot: URL?
    func retainSourceSnapshotDirectory(_ folder: URL) throws {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard root.deletingLastPathComponent() == temporary, root.lastPathComponent.hasPrefix("TurtleGitSourceCompare-"),
              let comparison = workingComparison, [comparison.base, comparison.destination].allSatisfy({ $0.resolvingSymlinksInPath().deletingLastPathComponent() == root }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        sourceSnapshotRoot = root
    }
    var openPermissions: [RepositoryAccessLease] { workingPermissions + [access].compactMap { $0 } }
    func retainPermissions(_ permissions: [RepositoryAccessLease]) {
        guard !retired else { return }
        for permission in permissions where !workingPermissions.contains(where: { $0 === permission }) { workingPermissions.append(permission) }
    }
    private let access: RepositoryAccessLease?
    let snapshot: RevisionComparisonSnapshot
    let path: String
    let imagePresentation = ImageWindowPresentation()
    @Published var imageComparison: ImageComparisonDocument?
    var externalDidOpen: () -> Void = {}
    private(set) var alternateTool = ComparisonToolInvocation.capture
    private var externalAttempted = false, retired = false
    private(set) var viewerSelection: DiffToolSelection = .merge
    private var pendingToolSelection: DiffToolSelection?
    /// Explicit Merge Open/source comparisons never re-enter configured tools or
    /// silently switch to IDiff because their bytes happen to decode as an image.
    func useInternalMergeViewer() {
        guard !busy, !retired else { return }
        externalAttempted = true; viewerSelection = .merge; pendingToolSelection = nil
    }
    lazy var openExternalComparison: (FileComparisonDocument, URL, [RepositoryAccessLease], Bool) async throws -> Bool = { [weak self] document, root, permissions, alternate in
        guard let self, !self.retired else { throw OperationCancellationFailure.cancelled }
        return try await DiffToolApplication.open(document, root: root, permissions: permissions, alternate: alternate, preferences: self.comparisonDefaults, cancellation: self.loadSession?.cancellation, owner: self.window, selection: self.pendingToolSelection)
    }
    func captureToolChoice(_ alternate: Bool) { guard !busy, !externalAttempted, !retired else { return }; alternateTool = alternate }
    @Published var document: FileComparisonDocument?
    var singleFileMode = false
    @Published var nativeToolbarInstalled = false
    @Published private(set) var showToolbar = MergeEditorChrome.visible("Toolbar",defaults:.standard)
    @Published private(set) var showStatusBar = MergeEditorChrome.visible("StatusBar",defaults:.standard)
    func setToolbarVisible(_ value: Bool) {
        guard !retired, showToolbar != value else { return }
        showToolbar = value;comparisonDefaults.set(value,forKey:"TurtleGitMerge.ToolbarVisible")
    }
    func setStatusBarVisible(_ value: Bool) {
        guard !retired, !busy, !confirmingQuit, showStatusBar != value else { return }
        showStatusBar = value;comparisonDefaults.set(value,forKey:"TurtleGitMerge.StatusBarVisible")
    }
    private(set) var sidesReversed = false
    var canSwitchSides: Bool {
        guard contextCommandsAllowed,!filtering,!singleFileMode,imageComparison == nil,alignment != nil,
              let owner = window?.delegate as? FileComparisonWindowController else { return false }
        return owner.editorOpenWorkflow == nil && !owner.preparingReplacement
    }
    private func storageSide(_ base: Bool) -> Bool { sidesReversed ? !base : base }
    private func oriented(_ value: FileComparisonDocument) -> FileComparisonDocument { sidesReversed ? value.exchangingSides() : value }
    func switchSides() {
        guard canSwitchSides else { return }
        requestProjectionChange(reason:"switching left and right",detail:"Switching left and right reloads the files and clears Undo history.") { [self] in
            sidesReversed.toggle()
            paneTargets = Dictionary(uniqueKeysWithValues:paneTargets.map { (!$0.key,$0.value) })
            originalPaneDocument = originalPaneDocument?.exchangingSides()
        }
    }
    @Published var alignment: FileComparisonAlignment? { didSet { combinedCache = nil } }
    @Published private(set) var onePaneMode = false
    private var loadedPaneMode = false
    private var combinedCache: OnePaneFileComparison?
    private var retainingViewEdits = false
    @Published var overwriteModes: [Bool:Bool] = [:]
    struct EditingPresentation {
        let alignment: FileComparisonAlignment
        let combined: OnePaneFileComparison?
        let annotations: [Bool: FileComparisonEditing.Annotations]
        let revisions: [Bool: UUID]
        let moves: [MergeMovedBlock]
        let moveLinks: [Bool:[Int:MovedRowLink]]?
    }
    func captureEditingPresentation() -> EditingPresentation? {
        alignment.map { .init(alignment:$0,combined:onePaneActive ? combined : nil,annotations:[true:annotations(base:true),false:annotations(base:false)],revisions:editRevisions,moves:movedBlockRecords,moveLinks:retainedMoveLinks) }
    }
    private var editRevisions: [Bool:UUID] { Dictionary(uniqueKeysWithValues:[true,false].compactMap { side in drafts?.editRevision(base:side).map { (side,$0) } }) }
    func installEditingPresentation(_ presentation: EditingPresentation) {
        regexCancellation?.cancel(); regexCancellation = nil; filtering = false
        cancelDeferredNavigation(); alignmentGeneration += 1
        alignment = presentation.alignment; combinedCache = presentation.combined; movedBlockRecords = presentation.moves; retainedMoveLinks = presentation.moveLinks
        retainingViewEdits = true
        for (side,value) in presentation.annotations { updateAnnotations(value,base:side) }
        for side in [true,false] { drafts?.setEditRevision(presentation.revisions[side],base:side) }
        selectedRows = nil; difference = -1; previewRow = nil
        inlineCache = [:]; inlineNavigationCache = [:]
    }
    func presentation(for edit: FileComparisonInPlaceEdit, base: Bool) -> EditingPresentation {
        var values: [Bool:FileComparisonEditing.Annotations] = [:]
        for side in [true,false] {
            var value = alignment.map { annotations(base:side).remapped(from:$0,to:edit.alignment,targetBase:side,typing:false) } ?? .init()
            value.edited.formUnion(edit.alignment.rows.indices.filter { (side ? edit.alignment.rows[$0].base : edit.alignment.rows[$0].destination).state == .edited })
            values[side] = value
        }
        var revisions = editRevisions; revisions[base] = UUID()
        return .init(alignment:edit.alignment,combined:edit.combined,annotations:values,revisions:revisions,moves:movedBlockRecords,moveLinks:remappedMoves(for:edit,base:base))
    }
    var onePaneActive: Bool { onePaneMode && !singleFileMode && document?.base.text != nil && document?.destination.text != nil }
    var combined: OnePaneFileComparison? {
        guard let alignment else { return nil }
        if combinedCache == nil { combinedCache = OnePaneFileComparison(alignment: alignment, options: comparisonOptions) }
        return combinedCache
    }
    lazy var folding: MergeFoldingController = {
        let value = MergeFoldingController(preferences: comparisonDefaults)
        value.geometryChanged = { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } }
        value.actionsAllowed = { [weak self] in self?.contextCommandsAllowed == true && self?.filtering == false }
        return value
    }()
    func setCollapsed(_ value: Bool) {
        guard !retired, !busy, !filtering, !confirmingQuit else { return }
        folding.setCollapsed(value)
    }
    func updateFolding() {
        let unchanged: [Bool]
        if onePaneActive { unchanged = combined?.rows.map { $0.cell.hiddenByComparison } ?? [] }
        else { unchanged = alignment?.rows.map { $0.base.hiddenByComparison && $0.destination.hiddenByComparison } ?? [] }
        folding.update(unchanged: unchanged)
    }
    func displayCells(base: Bool) -> [MergeSourceCell] {
        func paint(_ cell: MergeSourceCell, row: Int, side: Bool) -> MergeSourceCell {
            guard annotations(base: side).edited.contains(row), cell.lineNumber != nil else { return cell }
            return MergeSourceCell(text: cell.text, lineNumber: cell.lineNumber, state: .edited)
        }
        if onePaneActive, !base { return combined?.rows.map { paint($0.cell, row: $0.alignmentRow, side: $0.base) } ?? [] }
        return alignment?.rows.enumerated().map { paint(base ? $0.element.base : $0.element.destination, row: $0.offset, side: base) } ?? []
    }
    var choosePaneSwitch: (String) -> NSApplication.ModalResponse = { description in
        let alert = NSAlert(); alert.messageText = "Save changes to “" + description + "” before changing the view?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }
    func switchPaneMode(_ value: Bool) {
        guard !retired, !busy, !filtering, !confirmingQuit, !singleFileMode, value != onePaneMode, window?.attachedSheet == nil else { return }
        func switchAndReload() {
            guard !retired, let document else { return }
            drafts = FileComparisonDrafts(document); resetHistory(); scrolls.removeValue(forKey: true)
            onePaneMode = value; loadedPaneMode = true; comparisonDefaults.set(value, forKey: "TurtleGitMerge.OnePane")
            activatePane(base: false); load()
        }
        if dirty {
            confirmingQuit = true; let answer = choosePaneSwitch(unsavedFilesDescription); confirmingQuit = false
            guard !retired else { return }
            if answer == .alertFirstButtonReturn { saveAll { saved in if saved { switchAndReload() } }; return }
            guard answer == .alertSecondButtonReturn else { return }
        }
        switchAndReload()
    }
    @Published private(set) var regexFilters = MergeRegexFilters.load()
    @Published private(set) var regexFilterName: String?
    @Published private(set) var filtering = false
    var regexExecutable: URL?
    var engineConfiguration: SubversionMergeConfiguration?
    @Published private(set) var comparisonOptions = MergeComparisonOptions.load()
    var comparisonDefaults: UserDefaults = .standard {
        didSet { if document == nil { comparisonOptions = .load(from:comparisonDefaults); showMovedBlocks = MergeMovedBlock.enabled(defaults:comparisonDefaults)
            showToolbar = MergeEditorChrome.visible("Toolbar",defaults:comparisonDefaults)
            showStatusBar = MergeEditorChrome.visible("StatusBar",defaults:comparisonDefaults)
            editorPreferences = .load(from:comparisonDefaults); showLineNumbers = editorPreferences.showLineNumbers
            editorConfigEnabled = [true:editorPreferences.enableEditorConfig,false:editorPreferences.enableEditorConfig]
        } }
    }
    @Published private(set) var generalPreferences = MergeGeneralPreferences.load()
    private var pendingLoadNavigation = false
    var initialNavigationPending: Bool { pendingLoadNavigation || initialBlockGeneration != nil }
    private var initialBlockGeneration: Int?
    @Published private(set) var whitespaceDisplay = MergeWhitespaceDisplayPreferences.load()
    func setWhitespaceDisplay(_ value: MergeWhitespaceDisplayPreferences) {
        guard !busy, !confirmingQuit, !retired else { return }
        whitespaceDisplay = value; value.save(to: comparisonDefaults)
    }
    @Published private(set) var locatorPreferences = MergeLocatorPreferences.load()
    @Published private(set) var locatorViewport = MergeLocatorViewport()
    @Published private(set) var locatorHighlights = [MergeLocatorHighlights(), .init(), .init()]
    private var locatorHighlightsScheduled = false
    func refreshLocatorHighlights() {
        guard !retired, !locatorHighlightsScheduled else { return }
        locatorHighlightsScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }; self.locatorHighlightsScheduled = false
            guard !self.retired else { return }
            let next: [MergeLocatorHighlights] = self.onePaneActive
                ? [.read(self.scrolls[false]), .init(), .init()]
                : [.read(self.scrolls[true]), .init(), .read(self.scrolls[false])]
            if self.locatorHighlights != next { self.locatorHighlights = next }
        }
    }
    var locatorMap: MergeLocatorMap {
        if onePaneActive { return MergeLocatorMap(columns: [displayCells(base: false).map(\.state), [], []]) }
        return MergeLocatorMap(columns: [displayCells(base: true).map(\.state), [], displayCells(base: false).map(\.state)])
    }
    func setLocatorPreferences(_ value: MergeLocatorPreferences) {
        guard !retired, !busy, !confirmingQuit else { return }
        locatorPreferences = value; value.save(to: comparisonDefaults)
    }
    func scrollLocator(to row: Int) {
        guard !retired, !busy, !filtering, !confirmingQuit else { return }
        lineWrapping.prepareForInput()
        for scroll in scrolls.values { MergeLocatorScrolling.scroll(scroll, to: row) }
        lineWrapping.recordViewportIntent(); refreshLocatorViewport()
    }
    func refreshLocatorViewport() {
        guard !retired, !lineWrapping.isGeometryPending else { return }
        let value = MergeLocatorScrolling.viewport(onePaneActive ? scrolls[false] : scrolls[true] ?? scrolls[false])
        if value != locatorViewport { locatorViewport = value }
    }
    var commentProfileURL = MergeCommentProfileFile.url
    private var commentProfiles = MergeCommentProfiles.bundled()
    private var reloadCommentProfiles = true
    private var commentTokens: MergeCommentTokens? {
        document.flatMap { commentProfiles.tokens(paths: [$0.base.path, $0.destination.path]) }
    }
    var supportsComments: Bool { commentTokens != nil }
    @Published private(set) var showMovedBlocks = MergeMovedBlock.enabled()
    @Published private(set) var movedBlockRecords: [MergeMovedBlock] = []
    var canChangeMovedBlocks: Bool { !retired && !busy && !filtering && !confirmingQuit && !singleFileMode && imageComparison == nil && alignment != nil }
    func setMovedBlocks(_ enabled: Bool) {
        guard canChangeMovedBlocks, enabled != showMovedBlocks else { return }
        requestProjectionChange { [self] in
            showMovedBlocks = enabled; comparisonDefaults.set(enabled,forKey:"TurtleGitMerge.ViewMovedBlocks")
        }
    }
    struct MovedRowLink {
        let targetBase: Bool, targetRow: Int, rows: Range<Int>, tooltip: String
    }
    private var retainedMoveLinks: [Bool:[Int:MovedRowLink]]?
    /// In-place edits keep view-record identities, as BaseView does. New records
    /// have no move marker; deleted records retire their links. History captures
    /// both directions with the exact matching display projection.
    private func remappedMoves(for edit: FileComparisonInPlaceEdit, base: Bool) -> [Bool:[Int:MovedRowLink]] {
        let oldCount = onePaneActive ? combined?.rows.count ?? 0 : alignment?.rows.count ?? 0
        let newCount = onePaneActive ? edit.combined?.rows.count ?? 0 : edit.alignment.rows.count
        let delta = newCount + edit.removedEmptyRows.count - oldCount
        let removed = Set(edit.removedEmptyRows)
        func map(_ row: Int, side: Bool) -> Int? {
            var next = row
            if onePaneActive || side == base {
                if edit.replacedRows.contains(row),row != edit.replacedRows.lowerBound { return nil }
                if row >= edit.replacedRows.upperBound { next += delta }
            } else if row >= edit.replacedRows.upperBound { next += max(0,delta) }
            guard !removed.contains(next) else { return nil }
            next -= edit.removedEmptyRows.filter { $0 < next }.count
            return (0..<newCount).contains(next) ? next : nil
        }
        var result: [Bool:[Int:MovedRowLink]] = [:]
        for side in onePaneActive ? [false] : [true,false] {
            for (row,link) in movedRowLinks(base:side) {
                guard let origin = map(row,side:side),let target = map(link.targetRow,side:link.targetBase) else { continue }
                result[side,default:[:]][origin] = .init(targetBase:link.targetBase,targetRow:target,rows:target..<(target + 1),tooltip:link.tooltip)
            }
        }
        // Rebuild the destination's contiguous marked run after insertion or
        // deletion. An inserted unmarked row divides that selection, as source.
        for side in Array(result.keys) {
            for (row,link) in result[side] ?? [:] {
                let peers = result[link.targetBase] ?? [:]
                var first = link.targetRow,last = first
                while peers[first - 1] != nil { first -= 1 }
                while peers[last + 1] != nil { last += 1 }
                result[side]?[row] = .init(targetBase:link.targetBase,targetRow:link.targetRow,rows:first..<(last + 1),tooltip:link.tooltip)
            }
        }
        return result
    }
    func movedRowLinks(base: Bool) -> [Int:MovedRowLink] {
        guard !retired, !filtering, showMovedBlocks, let alignment, !movedBlockRecords.isEmpty else { return [:] }
        if let retainedMoveLinks { return retainedMoveLinks[base] ?? [:] }
        var left: [Int:Int] = [:], right: [Int:Int] = [:]
        if onePaneActive {
            for (index,row) in (combined?.rows ?? []).enumerated() {
                let cell = row.base ? alignment.rows[row.alignmentRow].base : alignment.rows[row.alignmentRow].destination
                if let number = cell.lineNumber { if row.base { left[number - 1] = index } else { right[number - 1] = index } }
            }
        } else {
            for (index,row) in alignment.rows.enumerated() {
                if let number = row.base.lineNumber { left[number - 1] = index }
                if let number = row.destination.lineNumber { right[number - 1] = index }
            }
        }
        var result: [Int:MovedRowLink] = [:]
        for block in movedBlockRecords {
            let a = block.base.compactMap { left[$0] }, b = block.mine.compactMap { right[$0] }
            guard let af = a.min(),let al = a.max(),let bf = b.min(),let bl = b.max() else { continue }
            if base || onePaneActive {
                for (offset,i) in block.base.enumerated() { if let row = left[i] { result[row] = .init(targetBase:false,targetRow:right[block.mine.lowerBound + offset] ?? bf,rows:bf..<(bl + 1),tooltip:"Moved to line \(block.mine.lowerBound + offset + 1)") } }
            }
            if !base || onePaneActive {
                for (offset,j) in block.mine.enumerated() { if let row = right[j] { result[row] = .init(targetBase:!onePaneActive,targetRow:left[block.base.lowerBound + offset] ?? af,rows:af..<(al + 1),tooltip:"Moved from line \(block.base.lowerBound + offset + 1)") } }
            }
        }
        return result
    }
    func followMovedBlock(row: Int, base: Bool, generation: Int) {
        guard generation == alignmentGeneration, contextCommandsAllowed, !filtering,
              let link = movedRowLinks(base:base)[row],let view = scrolls[link.targetBase]?.documentView as? FileComparisonTextView else { return }
        let cells = displayCells(base:link.targetBase)
        guard link.rows.lowerBound >= 0, link.rows.upperBound <= cells.count else { return }
        view.beginUserNavigation();clearNavigationBlockSelection(clearTextSelections:true)
        let start = cells.prefix(link.rows.lowerBound).reduce(0) { $0 + $1.displayText.utf16.count + 1 }
        let length = cells[link.rows].reduce(0) { $0 + $1.displayText.utf16.count + 1 } - 1
        let range = NSRange(location:start,length:max(0,length))
        guard NSMaxRange(range) <= view.string.utf16.count else { return }
        selectingDifferenceBlock = true
        defer { selectingDifferenceBlock = false; lineWrapping.recordViewportIntent() }
        view.foldLayout.reveal(selection:range,in:view,includeMarker:true)
        activatePane(base:link.targetBase);view.window?.makeFirstResponder(view)
        view.blockSelection.install(range,caret:start,in:view);view.blockSelection.centerCaret(in:view)
        updateSelection(view.selectedRange(),cells:cells)
    }
    func setComparisonOptions(_ value: MergeComparisonOptions) {
        guard value != comparisonOptions else { return }
        requestProjectionChange { [self] in comparisonOptions = value; value.save(to:comparisonDefaults) }
    }
    private final class ProjectionChange {
        enum Answer { case save([Bool]), discard, cancel }
        let change: () -> Void
        var question: NSAlert?
        var answers: [Answer] = []
        var answered = false
        init(_ change: @escaping () -> Void) { self.change = change }
    }
    private var projectionChange: ProjectionChange?
    private(set) static var activeProjectionChoices = 0
    var presentProjectionQuestion: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert,owner,answer in alert.beginSheetModal(for:owner,completionHandler:answer) }
    private func finishProjectionChange(_ request: ProjectionChange) {
        guard projectionChange === request else { return }
        projectionChange = nil; confirmingQuit = false; Self.activeProjectionChoices -= 1
        if let question = request.question {
            if let owner = question.window.sheetParent { owner.endSheet(question.window) }
            question.window.orderOut(nil); request.question = nil
        }
    }
    private func applyProjectionChange(_ request: ProjectionChange) {
        guard !retired, projectionChange === request else { return }
        finishProjectionChange(request); request.change()
        regexCancellation?.cancel(); regexCancellation = nil; filtering = false
        cancelDeferredNavigation(); alignmentGeneration += 1; resetHistory()
        load(discardingDraft:true)
    }
    private func requestProjectionChange(reason: String = "changing comparison options", detail: String = "Changing comparison options reloads the files and clears Undo history.", _ change: @escaping () -> Void) {
        guard !retired, !busy, !confirmingQuit, !hasPendingEditorChoice, window?.attachedSheet == nil else { return }
        guard document != nil else { change(); return }
        let request = ProjectionChange(change)
        projectionChange = request; Self.activeProjectionChoices += 1
        guard dirty else { applyProjectionChange(request); return }
        guard let window else { finishProjectionChange(request); return }
        confirmingQuit = true
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Save changes to “" + unsavedFilesDescription + "” before " + reason + "?"
        alert.informativeText = detail + " Any pane you do not save will be reloaded from disk."
        let sides = drafts?.dirtySides ?? []
        let choices: [(String,ProjectionChange.Answer)] = sides.count > 1
            ? [("Save left pane",.save([true])),("Save right pane",.save([false])),("Save both panes",.save(sides)),("Don’t Save",.discard),("Cancel",.cancel)]
            : [("Save",.save(sides)),("Don’t Save",.discard),("Cancel",.cancel)]
        request.answers = choices.map { $0.1 }
        for (title,_) in choices { alert.addButton(withTitle:title).keyEquivalent = title == "Cancel" ? "\u{1b}" : "" }
        let defaultButton = alert.buttons[sides.count > 1 ? 2 : 0]
        defaultButton.keyEquivalent = "\r"; alert.window.defaultButtonCell = defaultButton.cell as? NSButtonCell
        request.question = alert
        presentProjectionQuestion(alert,window) { [weak self, weak request] answer in
            guard let self, let request, !self.retired, self.projectionChange === request, !request.answered else { return }
            request.answered = true
            if let question = request.question {
                if let parent = question.window.sheetParent { parent.endSheet(question.window) }
                question.window.orderOut(nil); request.question = nil
            }
            let index = answer.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            switch request.answers.indices.contains(index) ? request.answers[index] : .cancel {
            case .save(let sides):
                self.save(sides:sides,ownerInitiated:true) { [weak self, weak request] saved in
                    guard let self, let request, self.projectionChange === request else { return }
                    if saved { self.applyProjectionChange(request) } else { self.finishProjectionChange(request) }
                }
            case .discard: self.applyProjectionChange(request)
            default: self.finishProjectionChange(request)
            }
        }
    }
    struct AlignmentSelection { let id = UUID(); let sourceRange: NSRange; var scroll = false }
    @Published var alignmentSelections: [Bool: AlignmentSelection] = [:]
    var regexDefaults: UserDefaults = .standard
    private var regexCancellation: OperationCancellation?
    private var regexList: MergeRegexFilterListController?
    func refreshRegexFilters() {
        guard !retired else { return }
        let incoming = MergeRegexFilters.load(defaults:regexDefaults)
        let old = regexFilters.first { $0.name == regexFilterName }, next = incoming.first { $0.name == regexFilterName }
        if regexFilterName == nil || old == next { regexFilters = incoming; return }
        requestProjectionChange { [self] in regexFilters = incoming; if next == nil { regexFilterName = nil } }
    }
    func selectRegexFilter(_ name: String?) {
        guard name != regexFilterName, name == nil || regexFilters.contains(where: { $0.name == name }) else { return }
        requestProjectionChange { [self] in regexFilterName = name; difference = -1 }
    }
    private func rebuildFilterAlignment() {
        let previous = alignment; rebuildAlignment()
        if let previous, let alignment {
            drafts?.remapAnnotations(from: previous, to: alignment, base: true)
            drafts?.remapAnnotations(from: previous, to: alignment, base: false)
        }
    }
    func manageRegexFilters() {
        guard !busy, !confirmingQuit, !retired else { return }
        if let regexList { regexList.showWindow(nil); regexList.window?.makeKeyAndOrderFront(nil); return }
        let controller = MergeRegexFilterListController(defaults: regexDefaults); controller.executable = regexExecutable
        controller.onClosed = { [weak self] in self?.regexList = nil; self?.refreshRegexFilters() }
        regexList = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private var loadSession: FileListComparisonSession?
    private var closeAfterLoad = false
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var difference = -1
    @Published var showLineNumbers = MergeEditorPreferences.load().showLineNumbers
    @Published private(set) var wrapLines = UserDefaults.standard.bool(forKey: "TurtleGitMerge.WrapLines")
    let lineWrapping = MergeLineWrapping()
    func setWrapLines(_ value: Bool) {
        guard !retired, !busy, !confirmingQuit else { return }
        wrapLines = value; comparisonDefaults.set(value, forKey: "TurtleGitMerge.WrapLines")
    }
    @Published var showLineDiffBar = UserDefaults.standard.object(forKey: "TurtleGitMerge.LineDiff") == nil || UserDefaults.standard.bool(forKey: "TurtleGitMerge.LineDiff") {
        didSet { comparisonDefaults.set(showLineDiffBar, forKey: "TurtleGitMerge.LineDiff") }
    }
    @Published private(set) var previewRow: Int?
    @Published private(set) var previewHorizontalOffsets: [Bool: CGFloat] = [:]
    var lineDiffRow: FileComparisonRow? {
        guard !retired, !singleFileMode, !onePaneActive, !filtering, let index = previewRow,
              let alignment, alignment.rows.indices.contains(index) else { return nil }
        return alignment.rows[index]
    }
    func previewLine(atRow index: Int?) {
        guard !retired, !singleFileMode, !onePaneActive, !filtering, let index, let alignment,
              alignment.rows.indices.contains(index) else { if previewRow != nil { previewRow = nil }; return }
        if previewRow != index { previewRow = index }
    }
    @Published var showInlineDiff = true
    @Published var inlineWordDiff = false
    func setInlineDiff(_ value: Bool) {
        guard !retired, !busy, !filtering, !confirmingQuit, !singleFileMode else { return }
        showInlineDiff = value; MergeInlinePresentation.saveEnabled(value, to: comparisonDefaults)
    }
    func setInlineWordDiff(_ value: Bool) {
        guard !retired, !busy, !filtering, !confirmingQuit, showInlineDiff, !singleFileMode else { return }
        inlineWordDiff = value
    }
    func canNavigateInline(forward: Bool) -> Bool {
        (scrolls[activeBase]?.documentView as? MergeInlineNavigationProviding)?.canNavigateInline(forward: forward) == true
    }
    func navigateInline(forward: Bool) {
        (scrolls[activeBase]?.documentView as? MergeInlineNavigationProviding)?.navigateInline(forward: forward)
    }

    @Published var editorPreferences = MergeEditorPreferences.load()
    @Published var tabWidths: [Bool: Int] = [:]
    @Published var spacePanes: [Bool: Bool] = [:]
    @Published var smartTabPanes: [Bool: Bool] = [:]
    @Published var editorConfigEnabled: [Bool: Bool] = {
        let enabled = MergeEditorPreferences.load().enableEditorConfig
        return [true: enabled, false: enabled]
    }()
    @Published var editorConfigLoaded: [Bool: Bool] = [:]
    @Published var editorConfigLoading: Set<Bool> = []
    private var editorConfigRequests: [Bool: UUID] = [:]
    func setEditorConfig(_ enabled: Bool, base: Bool) {
        guard let document, !confirmingQuit else { return }
        let content = base ? document.base : document.destination
        let file = content.path.hasPrefix("/") ? URL(fileURLWithPath: content.path) : snapshot.root.appendingPathComponent(content.path)
        if enabled, GitRuntime.isAppStoreBuild {
            let parent = file.deletingLastPathComponent()
            let permissions = workingPermissions + [access].compactMap { $0 }
            if !permissions.contains(where: { $0.hasSecurityScope && $0.contains(parent) }) {
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.directoryURL = parent; panel.prompt = "Read EditorConfig"
                panel.message = "Choose the folder containing “" + file.lastPathComponent + "” to read its EditorConfig settings."
                guard panel.runModal() == .OK, let folder = panel.url else { return }
                let permission = RepositoryAccessLease(url: folder)
                guard permission.hasSecurityScope, permission.contains(parent) else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return }
                workingPermissions.append(permission)
            }
        }
        let request = UUID(); editorConfigRequests[base] = request
        editorConfigEnabled[base] = enabled; editorConfigLoaded[base] = false
        tabWidths[base] = editorPreferences.tabWidth
        spacePanes[base] = editorPreferences.useSpaces
        smartTabPanes[base] = editorPreferences.smartTab
        editorConfigLoading.remove(base)
        guard enabled else { return }
        editorConfigLoading.insert(base)
        Task {
            let resolved = await Task.detached { Result { try EditorConfigRuntime.resolve(file: file) } }.value
            guard editorConfigRequests[base] == request else { return }
            editorConfigLoading.remove(base)
            switch resolved {
            case .success(let values):
                editorConfigLoaded[base] = values.loaded
                let settings = values.applying(to: editorPreferences)
                tabWidths[base] = settings.tabWidth; spacePanes[base] = settings.useSpaces
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    private func reloadEditorConfig() {
        for base in editorConfigEnabled.keys where editorConfigEnabled[base] == true { setEditorConfig(true, base: base) }
    }

    func tabWidth(base: Bool) -> Int { tabWidths[base] ?? editorPreferences.tabWidth }
    func useSpaces(base: Bool) -> Bool { spacePanes[base] ?? editorPreferences.useSpaces }
    func smartTab(base: Bool) -> Bool { smartTabPanes[base] ?? editorPreferences.smartTab }
    func refreshPreferences() {
        let general = MergeGeneralPreferences.load(from: comparisonDefaults)
        if general != generalPreferences { generalPreferences = general; inlineCache = [:] }
        if !singleFileMode { showInlineDiff = MergeInlinePresentation.defaultEnabled(from: comparisonDefaults) }
        showLineDiffBar = comparisonDefaults.object(forKey: "TurtleGitMerge.LineDiff") == nil || comparisonDefaults.bool(forKey: "TurtleGitMerge.LineDiff")
        wrapLines = comparisonDefaults.bool(forKey: "TurtleGitMerge.WrapLines")
        locatorPreferences = .load(from: comparisonDefaults)
        whitespaceDisplay = .load(from: comparisonDefaults)
        let options = MergeComparisonOptions.load(from: comparisonDefaults)
        if options != comparisonOptions { setComparisonOptions(options) }
        let next = MergeEditorPreferences.load(from: comparisonDefaults)
        if next.tabWidth != editorPreferences.tabWidth || next.useSpaces != editorPreferences.useSpaces || next.smartTab != editorPreferences.smartTab {
            tabWidths = [:]; spacePanes = [:]; smartTabPanes = [:]
            editorPreferences = next
            reloadEditorConfig()
        }
        editorPreferences = next; showLineNumbers = next.showLineNumbers
    }
    @Published private var drafts: FileComparisonDrafts?
    @Published private(set) var activeBase = false
    var editingEnabled: Bool {
        get { mutablePane(activeBase) && !retired && drafts?.editingEnabled(base: activeBase) == true }
        set { guard mutablePane(activeBase), !retired, !busy, !hasPendingEditorChoice, !confirmingQuit else { return }; drafts?.setEditing(newValue, base: activeBase) }
    }
    func canEdit(base: Bool) -> Bool { mutablePane(base) && !retired && drafts?.canEdit(base: base) == true }
    func draftText(base: Bool) -> String { drafts?.text(base: base) ?? "" }
    func updateDraft(_ text: String, base: Bool) {
        guard mutablePane(base), !retired, !hasPendingEditorChoice || updatingSaveDecision else { return }
        do { try drafts?.update(text: text, base: base) } catch { self.error = error.localizedDescription }
    }
    func updateAnnotations(_ value: FileComparisonEditing.Annotations, base: Bool) { guard !retired, !hasPendingEditorChoice || updatingSaveDecision else { return }; drafts?.update(annotations: value, base: base) }
    func recordTypingEdit(base: Bool) { drafts?.setEditRevision(UUID(),base:base) }
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var selectedRows: Range<Int>?
    private(set) var alignmentGeneration = 0
    private struct InlineResult { let value: MergeInlineComparison? }
    private var inlineCache: [Int: InlineResult] = [:]
    private var inlineNavigationCache: [Int: InlineResult] = [:]
    private var inlineGeneration = -1
    private var cachedWordMode = false
    func inlineDifference(_ index: Int, force: Bool = false) -> MergeInlineComparison? {
        guard !filtering, (showInlineDiff || force), let alignment, alignment.rows.indices.contains(index), alignment.rows[index].changed else { return nil }
        if inlineGeneration != alignmentGeneration || cachedWordMode != inlineWordDiff {
            inlineCache = [:]; inlineNavigationCache = [:]; inlineGeneration = alignmentGeneration; cachedWordMode = inlineWordDiff
        }
        if let cached = inlineCache[index] { return cached.value }
        let row = alignment.rows[index]
        guard min(row.base.displayText.utf16.count, row.destination.displayText.utf16.count) <= generalPreferences.maximumInlineLength else { return nil }
        let value = row.base.lineNumber != nil && row.destination.lineNumber != nil ? MergeInlineComparison(base: row.base.displayText, destination: row.destination.displayText, word: inlineWordDiff, maximumLength: generalPreferences.maximumInlineLength) : nil
        inlineCache[index] = InlineResult(value: value); return value
    }
    func inlineNavigationDifference(_ row: Int) -> MergeInlineComparison? {
        guard !retired, !busy, !filtering, !confirmingQuit, showInlineDiff, !onePaneActive,
              let alignment, alignment.rows.indices.contains(row) else { return nil }
        if inlineGeneration != alignmentGeneration || cachedWordMode != inlineWordDiff {
            inlineCache = [:]; inlineNavigationCache = [:]; inlineGeneration = alignmentGeneration; cachedWordMode = inlineWordDiff
        }
        if let cached = inlineNavigationCache[row] { return cached.value }
        let pair = alignment.rows[row]
        // Source navigation does not use the painting cutoff. Retain the native
        // upper input bound while permitting navigation beyond a smaller saved
        // painting limit. The current-line similarity gate still applies.
        let value = MergeInlineComparison(base: pair.base.displayText, destination: pair.destination.displayText,
                                          word: inlineWordDiff, maximumLength: 100_000)
        inlineNavigationCache[row] = InlineResult(value: value); return value
    }
    weak var window: NSWindow?
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var canTransfer: Bool { canTransfer(toBase: activeBase) }
    func canTransfer(toBase base: Bool) -> Bool { mutablePane(base) && drafts?.editingEnabled(base: base) == true && alignment != nil && !busy && !hasPendingEditorChoice && !confirmingQuit && !filtering }
    var copyCommandsAllowed: Bool { !retired }
    var contextCommandsAllowed: Bool { !retired && !busy && !hasPendingEditorChoice && !confirmingQuit && window?.attachedSheet == nil }
    var oppositeViewCommandsAllowed: Bool { !onePaneActive && contextCommandsAllowed }
    var transferRows: Range<Int>? { selectedRows }
    func useOtherBlock(_ choice: FileComparisonEditing.BlockChoice = .other, targetBase: Bool? = nil) {
        let base = targetBase ?? activeBase
        guard !onePaneActive, canTransfer(toBase: base), let alignment, let rows = transferRows else { return }
        do { let edit = try FileComparisonEditing.takingOtherRows(alignment, rows: rows, targetBase: base, choice: choice); editorActions[base]?.replace(edit.text, edit.caret, choice == .other ? rows : nil) }
        catch { self.error = error.localizedDescription }
    }
    func useOtherFile(targetBase: Bool? = nil) {
        let base = targetBase ?? activeBase
        guard !onePaneActive, canTransfer(toBase: base), let alignment else { return }
        if alignment.rows.isEmpty { editorActions[base]?.replace("", 0, nil); return }
        do { let edit = try FileComparisonEditing.takingOtherRows(alignment, rows: alignment.rows.indices, targetBase: base); editorActions[base]?.replace(edit.text, 0, alignment.rows.indices) }
        catch { self.error = error.localizedDescription }
    }
    func markBlock(_ marked: Bool, targetBase: Bool? = nil) {
        let base = targetBase ?? activeBase
        guard !onePaneActive, canTransfer(toBase: base), let rows = transferRows else { return }
        var value = annotations(base: base)
        if marked { value.marked.formUnion(rows) } else { value.marked.subtract(rows) }
        editorActions[base]?.annotate(value)
    }
    func leaveOnlyMarked(targetBase: Bool? = nil) {
        let base = targetBase ?? activeBase
        guard !onePaneActive, canTransfer(toBase: base), let alignment else { return }
        do { editorActions[base]?.keep(try FileComparisonEditing.leavingOnlyMarked(alignment, targetBase: base, annotations: annotations(base: base))) }
        catch { self.error = error.localizedDescription }
    }
    func encoding(base: Bool) -> ComparisonTextEncoding? { drafts?.encoding(base: base) }
    private var formatRequest: UUID?
    var hasPendingEditorChoice: Bool { exporting || formatRequest != nil || paneSave != nil || projectionChange != nil }
    var chooseFormat: ((NSWindow, String, MergeFormatSelection) async -> MergeFormatSelection?)?
    private var formatPrompt: MergeFormatPrompt?
    func showFormatDialog(base: Bool) {
        guard canTransfer(toBase: base), let window, window.attachedSheet == nil,
              let originalEncoding = encoding(base: base) else { return }
        let original = draftText(base: base), request = UUID(), generation = alignmentGeneration
        let permissions = openPermissions
        formatRequest = request; Self.activePaneExports += 1; onExportStateChanged()
        Task {
            defer {
                withExtendedLifetime(permissions) {}
                Self.activePaneExports -= 1
                if formatRequest == request { formatRequest = nil; formatPrompt = nil; onExportStateChanged() }
            }
            guard !retired, formatRequest == request, self.window === window else { return }
            let initial = MergeFormatSelection.initial(encoding: originalEncoding, text: original)
            let choice: MergeFormatSelection?
            if let chooseFormat { choice = await chooseFormat(window, base ? "Base" : "Mine", initial) }
            else {
                let prompt = MergeFormatPrompt(pane: base ? "Base" : "Mine", selection: initial); formatPrompt = prompt
                choice = await prompt.choose(window: window)
            }
            guard let choice,
                  !retired, formatRequest == request, alignmentGeneration == generation, self.window === window, window.attachedSheet == nil,
                  draftText(base: base).utf8.elementsEqual(original.utf8), encoding(base: base) == originalEncoding else { return }
            // Release this chooser's lock before applying its captured result.
            formatRequest = nil; formatPrompt = nil; onExportStateChanged()
            guard canTransfer(toBase: base) else { return }
            do {
                let converted = try choice.applying(to: original)
                if !converted.utf8.elementsEqual(original.utf8) { editorActions[base]?.replace(converted, 0, nil) }
                try drafts?.setEncoding(choice.encoding, base: base)
            } catch { self.error = error.localizedDescription }
        }
    }
    func changeEncoding(_ value: ComparisonTextEncoding, base: Bool) {
        guard canTransfer(toBase: base) else { return }
        do { try drafts?.setEncoding(value, base: base) } catch { self.error = error.localizedDescription }
    }
    func changeWhitespace(_ command: MergeWhitespaceCommand, base: Bool) {
        guard canTransfer(toBase: base) else { return }
        let text = MergeWhitespace.applying(command, to: draftText(base: base), tabWidth: tabWidth(base: base))
        editorActions[base]?.replace(text, 0, nil)
    }
    func indent(_ range: NSRange, cells: [MergeSourceCell], base: Bool, remove: Bool) -> NSRange? {
        guard activeBase == base, canTransfer(toBase: base) else { return nil }
        do {
            if onePaneActive, !base, let combined {
                let expanded = try combined.editingSource(for: [range]), source = expanded.ranges[0]
                if let edit = MergeWhitespace.indentSelection(in: expanded.text, selection: source, tabWidth: tabWidth(base: false), useSpaces: useSpaces(base: false), smart: smartTab(base: false), remove: remove) {
                    let text = (expanded.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                    editorActions[false]?.type(text, edit.range.location + edit.replacement.utf16.count)
                    return NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
                }
                guard !remove else { return nil }
                let remaining = (expanded.text as NSString).replacingCharacters(in: source, with: "")
                let inserted = MergeWhitespace.tabInsertion(in: remaining, utf16Offset: source.location, tabWidth: tabWidth(base: false), useSpaces: useSpaces(base: false), smart: smartTab(base: false))
                editorActions[false]?.type((remaining as NSString).replacingCharacters(in: NSRange(location: source.location, length: 0), with: inserted), source.location + inserted.utf16.count)
                return NSRange(location: source.location + inserted.utf16.count, length: 0)
            }
            guard let edit = try FileComparisonEditing.indentation(range, cells: cells, tabWidth: tabWidth(base: base), useSpaces: useSpaces(base: base), smart: smartTab(base: base), remove: remove) else { return nil }
            editorActions[base]?.type(edit.text, edit.selection.location)
            selectionRequest = nil
            return edit.selection
        } catch { self.error = error.localizedDescription; return nil }
    }
    func changeLineEnding(_ ending: MergeLineEnding, base: Bool) {
        guard canTransfer(toBase: base) else { return }
        editorActions[base]?.replace(MergeLineEndings.converting(draftText(base: base), to: ending), 0, nil)
    }
    func updateSelection(_ range: NSRange, cells: [MergeSourceCell]) {
        guard !retired, let alignment else { return }
        let active = scrolls[activeBase]?.documentView as? FileComparisonTextView
        let block = active?.mergeSelectedBlockRange
        var nextRows = block.flatMap { MergeBlockSelection.rows($0,cells:cells) }
            ?? (try? FileComparisonEditing.selectedRows(range,cells:cells))
        if !selectingDifferenceBlock, block == nil {
            for scroll in scrolls.values { if let view = scroll.documentView as? FileComparisonTextView { view.blockSelection.clear(in:view) } }
        }
        if onePaneActive, let selection = nextRows, let combined {
            let mapped = selection.compactMap { combined.rows.indices.contains($0) ? combined.rows[$0].alignmentRow : nil }
            nextRows = mapped.min().flatMap { start in mapped.max().map { start..<($0 + 1) } }
        }
        if selectedRows != nextRows { selectedRows = nextRows }
        previewLine(atRow: nextRows?.lowerBound)
        var cursor = 0, row = cells.count
        for (index, cell) in cells.enumerated() { cursor += (cell.displayText as NSString).length + 1; if range.location < cursor { row = index; break } }
        if onePaneActive, let combined, combined.rows.indices.contains(row) { row = combined.rows[row].alignmentRow }
        let index = alignment.differences.firstIndex { $0.contains(row) } ?? -1
        if difference != index { difference = index }
    }
    @Published private(set) var exporting = false { didSet { onExportStateChanged() } }
    // Includes held output/format choices after their owner has retired.
    static private(set) var activePaneExports = 0
    var onExportStateChanged: () -> Void = {}
    private final class OutputRequest {
        let cancellation = OperationCancellation()
        let permissions: [RepositoryAccessLease]
        weak var panel: NSSavePanel?
        init(permissions: [RepositoryAccessLease]) { self.permissions = permissions }
    }
    private var outputRequest: OutputRequest?
    var canSavePaneAs: Bool { canBeginOutput && document != nil }
    private var canBeginOutput: Bool { !retired && !busy && !hasPendingEditorChoice && !confirmingQuit && window?.attachedSheet == nil }
    private func beginOutput() -> OutputRequest? {
        guard canBeginOutput else { return nil }
        let request = OutputRequest(permissions: openPermissions)
        outputRequest = request; Self.activePaneExports += 1
        error = nil; exporting = true; busy = true
        return request
    }
    private func acceptsOutput(_ request: OutputRequest) -> Bool {
        !retired && outputRequest === request && !request.cancellation.isCancelled
    }
    private func finishOutput(_ request: OutputRequest) {
        Self.activePaneExports -= 1
        guard outputRequest === request else { return }
        outputRequest = nil; busy = false; exporting = false
        withExtendedLifetime(request.permissions) {}
    }
    func cancelOutput() {
        guard let request = outputRequest else { return }
        request.cancellation.cancel();saveFolderAccess.cancel()
        if let panel = request.panel {
            panel.sheetParent?.endSheet(panel, returnCode: .cancel)
            panel.orderOut(nil)
        }
    }
    private func chooseOutput(_ window: NSWindow, name: String, directory: URL, patch: Bool) async -> URL? {
        if outputRequest == nil, let paneSave, (try? ensurePaneSave(paneSave)) != nil {return await saveChoices.output(window:window,name:name,directory:directory)}
        guard let request = outputRequest, acceptsOutput(request), window.attachedSheet == nil else { return nil }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.canCreateDirectories = true; panel.directoryURL = directory
        if patch {
            panel.title = "Create unified diff file"; panel.prompt = "Save"
            panel.allowedContentTypes = [UTType(filenameExtension: "diff") ?? .plainText, UTType(filenameExtension: "patch") ?? .plainText]
        }
        request.panel = panel
        defer { request.panel = nil }
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .OK && acceptsOutput(request) ? panel.url : nil
    }
    lazy var chooseExportLocation: (NSWindow, String, URL) async -> URL? = { [weak self] window, name, directory in
        await self?.chooseOutput(window, name: name, directory: directory, patch: false)
    }
    func export(base: Bool) { writePane(base: base, rebind: false) }
    func saveAs(base: Bool) { writePane(base: base, rebind: true) }
    private func writePane(base: Bool, rebind: Bool) {
        guard canBeginOutput, let window, let document else { return }
        let content = base ? document.base : document.destination
        do {
            let selectedEncoding = drafts?.encoding(base: base) ?? content.encoding
            let bytes: Data
            if onePaneActive, !base, let combined, let selectedEncoding { bytes = try selectedEncoding.encode(combined.sourceSaveText) }
            else { bytes = try drafts?.exported(base: base) ?? content.bytes }
            let directory = paneTargets[base]?.url.deletingLastPathComponent() ?? (sourceSnapshotRoot == nil ? snapshot.root : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            let name = (content.path as NSString).lastPathComponent
            let chooser = chooseExportLocation
            guard let request = beginOutput() else { return }
            Task {
                defer { finishOutput(request) }
                guard acceptsOutput(request), let url = await chooser(window, name, directory), acceptsOutput(request) else { return }
                let permission = RepositoryAccessLease(url: url)
                do {
                    if rebind, let sourceSnapshotRoot,
                       url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(sourceSnapshotRoot.path + "/") { throw FileComparisonEditFailure.unsupported }
                    guard try await authorizeWorkingReplacement(at:url,cancellation:request.cancellation),acceptsOutput(request) else {return}
                    try withExtendedLifetime(permission) { try MergePaneSaveAs.write(bytes,to:url) }
                    if rebind, acceptsOutput(request) {
                        let target = try SavedMergePane(url: url, writtenBytes: bytes, encoding: selectedEncoding)
                        if originalPaneDocument == nil { originalPaneDocument = document }
                        paneTargets[base] = target; retainPermissions([permission])
                        self.document = document.replacingPane(base: base, content: target.content)
                        try drafts?.didSaveAs(target.content, base: base)
                        selectEditorActions(); rebuildAlignment(); reloadEditorConfig()
                    }
                } catch { if acceptsOutput(request) { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    var patchExecutable: URL?
    lazy var choosePatchLocation: (NSWindow, String, URL) async -> URL? = { [weak self] window, name, directory in
        await self?.chooseOutput(window, name: name, directory: directory, patch: true)
    }
    var canCreateUnifiedPatch: Bool { canBeginOutput && !singleFileMode && !onePaneActive && document != nil }
    func createUnifiedPatch() {
        guard canCreateUnifiedPatch, let document, let window, let request = beginOutput() else { return }
        let context = MergeUnifiedPatch.contextLines(from: comparisonDefaults)
        let generator = patchExecutable, directory = snapshot.root, chooser = choosePatchLocation
        func label(_ content: ComparisonFileContent) -> String {
            content.path.hasPrefix("/") ? (content.path as NSString).lastPathComponent : content.path
        }
        Task {
            defer { finishOutput(request) }
            do {
                guard acceptsOutput(request), let target = await chooser(window, label(document.destination) + ".diff", directory), acceptsOutput(request) else { return }
                let permission = RepositoryAccessLease(url: target)
                let executable = try generator ?? GitRuntime.executable()
                func savedContent(_ content: ComparisonFileContent) throws -> ComparisonFileContent {
                    guard content.revision == .workingTree, !content.isDeleted else { return content }
                    let file = content.path.hasPrefix("/") ? URL(fileURLWithPath: content.path) : directory.appendingPathComponent(content.path)
                    return try WorkingFileComparison.workingContent(at: file)
                }
                guard try await authorizeWorkingReplacement(at:target,cancellation:request.cancellation),acceptsOutput(request) else {return}
                let savedBase = try savedContent(document.base), savedDestination = try savedContent(document.destination)
                let bytes = try await MergeUnifiedPatch.create(base: savedBase, destination: savedDestination,
                    baseLabel: label(document.base), destinationLabel: label(document.destination), contextLines: context,
                    executable: executable, cancellation: request.cancellation)
                guard acceptsOutput(request) else { return }
                try withExtendedLifetime(permission) { try bytes.write(to: target, options: .atomic) }
            } catch {
                if acceptsOutput(request) { self.error = error.localizedDescription }
            }
        }
    }
    var editableBase: Bool? { canEdit(base: activeBase) ? activeBase : nil }
    var editedFilePath: String { activeBase ? document?.base.path ?? path : document?.destination.path ?? path }
    var unsavedFilesDescription: String { drafts?.dirtyPaths.joined(separator: "”, “") ?? editedFilePath }
    var dirty: Bool { drafts?.dirtySides.isEmpty == false }
    var activeDirty: Bool { drafts?.isDirty(base: activeBase) == true }
    func annotations(base: Bool) -> FileComparisonEditing.Annotations { drafts?.annotations(base: base) ?? .init() }
    struct EditorActions {
        var reset: () -> Void
        var refresh: () -> Void
        var undo: () -> Void
        var redo: () -> Void
        var replace: (String, Int, Range<Int>?) -> Void
        var type: (String, Int) -> Void
        var annotate: (FileComparisonEditing.Annotations) -> Void
        var keep: (String) -> Void
        var resolveForSave: (String) -> Void
    }
    private var editorActions: [Bool: EditorActions] = [:]
    // TortoiseMerge's CUndo stores one ordered all-view history. Sharing it is
    // essential now that an edit snapshot also owns the opposite row layout.
    let comparisonHistory: UndoManager = { let value = UndoManager(); value.groupsByEvent = false; return value }()
    func registerEditor(base: Bool, actions: EditorActions) {
        editorActions[base] = actions
        if base == activeBase { selectEditorActions() }
    }
    private func selectEditorActions() {
        guard let actions = editorActions[activeBase] else { canUndo = false; canRedo = false; return }
        undo = actions.undo; redo = actions.redo; actions.refresh()
    }
    func activatePane(base: Bool) {
        guard !busy, !hasPendingEditorChoice, !confirmingQuit, (!onePaneActive || !base), activeBase != base else { return }
        activeBase = base; selectedRows = nil; selectionRequest = nil; selectEditorActions()
    }
    func resetHistory() { historyCaretRequests = [:]; for actions in editorActions.values { actions.reset() }; selectEditorActions() }
    struct HistoryCaret {
        let displayText: String
        let displayOffset: Int
        let sourceOffset: Int
    }
    private var historyCaretRequests: [Bool: (generation: Int, caret: HistoryCaret)] = [:]
    func cancelDeferredNavigation() {
        historyCaretRequests = [:]; initialBlockGeneration = nil; pendingLoadNavigation = false
        alignmentSelections = [:]; selectionRequest = nil
    }
    func captureHistoryCaret(base: Bool) -> HistoryCaret? {
        guard let scroll = scrolls[base], ownsViewport(scroll, base: base), let view = scroll.documentView as? FileComparisonTextView,
              let source = try? FileComparisonEditing.sourceRange(NSRange(location:view.selectedRange().location,length:0),cells:view.sourceCells) else { return nil }
        return HistoryCaret(displayText:view.string,displayOffset:view.selectedRange().location,sourceOffset:source.location)
    }
    func requestHistoryCaret(_ caret: HistoryCaret, base: Bool) {
        guard !retired else { return }
        selectionRequest = nil
        historyCaretRequests[base] = (alignmentGeneration,caret)
    }
    func restoreHistoryCaret(base: Bool, view: NSTextView, cells: [MergeSourceCell]) {
        guard !retired, !filtering, let scroll = scrolls[base], ownsViewport(scroll, base: base), scroll.documentView === view, let request = historyCaretRequests[base] else { return }
        guard request.generation == alignmentGeneration else { historyCaretRequests.removeValue(forKey:base); return }
        let expected = cells.map(\.displayText).joined(separator:"\n") + (cells.isEmpty ? "" : "\n")
        guard view.string.utf8.elementsEqual(expected.utf8) else { return }
        historyCaretRequests.removeValue(forKey:base); alignmentSelections.removeValue(forKey:base)
        let offset = view.string.utf8.elementsEqual(request.caret.displayText.utf8)
            ? request.caret.displayOffset : FileComparisonEditing.displayOffset(sourceOffset:request.caret.sourceOffset,cells:cells)
        clearNavigationBlockSelection(clearTextSelections:true)
        view.setSelectedRange(NSRange(location:min(offset,view.string.utf16.count),length:0))
        view.scrollRangeToVisible(view.selectedRange())
    }
    var selectionRequest: Int?
    private var scrolls: [Bool: NSScrollView] = [:]
    private var viewportNavigation: [Bool: () -> Void] = [:]
    func registerViewportNavigation(base: Bool, scroll: NSScrollView, action: @escaping () -> Void) {
        guard !retired, scrolls[base] === scroll else { return }
        viewportNavigation[base] = { [weak self, weak scroll] in
            guard let self, let scroll, self.ownsViewport(scroll, base: base) else { return }
            action()
        }
    }
    func ownsViewport(_ scroll: NSScrollView, base: Bool) -> Bool {
        guard !retired, !base || !onePaneActive && !singleFileMode, let window,
              scrolls[base] === scroll, scroll.window === window,
              let view = scroll.documentView as? FileComparisonTextView else { return false }
        return view.window === window && view.model === self
    }
    func unregister(_ scroll: NSScrollView, base: Bool) {
        guard scrolls[base] === scroll else { return }
        scrolls.removeValue(forKey: base); viewportNavigation.removeValue(forKey: base)
    }
    func applyViewportNavigation() { guard !retired else { return }; for action in viewportNavigation.values { action() } }
    private var synchronizing = false
    var onRegisterScroll: (NSScrollView, Bool) -> Void = { _, _ in }
    var patchEditingEnabled: Bool { drafts?.editingEnabled(base: false) == true }
    func setPatchEditing(_ enabled: Bool) {
        guard !retired, !busy, !hasPendingEditorChoice, !confirmingQuit else { return }
        drafts?.setEditing(enabled, base: false); activeBase = false; selectEditorActions()
    }
    func acceptPatchSave(_ saved: FileComparisonDocument) throws {
        guard !retired, let document, document.destination.path == saved.destination.path else { throw FileComparisonEditFailure.changed }
        try drafts?.didSave(saved.destination, base: false)
        drafts?.setEditing(false, base: false)
        self.document = saved; resetHistory(); rebuildAlignment()
    }
    init(patchComparison: WorkingTreePatchFileComparison, access: RepositoryAccessLease?, preferences: UserDefaults) {
        repository = nil; self.access = access; snapshot = patchComparison.snapshot; path = patchComparison.document.destination.path
        let value = patchComparison.editingDocument.usingMergeEncoding(preferUTF8: ComparisonTextEncoding.preferUTF8(from: preferences))
        document = value; originalPaneDocument = value; drafts = FileComparisonDrafts(value)
        comparisonDefaults = preferences; comparisonOptions = .load(from:preferences)
        drafts?.setEditing(false, base: false); showInlineDiff = false
        editorPreferences = .load(from: preferences); showLineNumbers = editorPreferences.showLineNumbers
        editorConfigEnabled = [true: editorPreferences.enableEditorConfig, false: editorPreferences.enableEditorConfig]
        rebuildAlignment(); reloadEditorConfig()
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, path: String) {
        self.repository = repository; self.access = access; self.snapshot = snapshot; self.path = path
    }
    init(images: ImageFileComparison, permissions: [RepositoryAccessLease]) {
        repository = nil; access = nil; standaloneImages = images; workingPermissions = permissions
        snapshot = images.snapshot; path = images.destination?.path ?? images.base?.path ?? "Images"
        externalAttempted = true; viewerSelection = .image
    }
    func retireImageLoader() {
        if let request = projectionChange { finishProjectionChange(request) }
        folding.retire()
        loadSession?.cancel(); closeAfterLoad = false
        lineWrapping.retire(); viewportNavigation.removeAll()
        cancelOutput(); cancelPaneSave()
        formatPrompt?.cancel(); formatPrompt = nil; formatRequest = nil; previewRow = nil
        onExportStateChanged = {}
        retired = true; movedBlockRecords = []; retainedMoveLinks = nil; regexCancellation?.cancel(); regexCancellation = nil; regexList?.retire(); regexList = nil
        imageLoader?.retire(); imageLoader = nil
        retainedImageModel?.retire(); retainedImageModel?.presentation.retire()
    }
    func chooseImageFiles() {
        guard !retired, !busy, !confirmingQuit, imageLoader == nil, let window, window.attachedSheet == nil else { return }
        let left = document?.base.path ?? ""
        let loader = makeImageLoader(left.hasPrefix("/") ? left : "", workingPermissions + [access].compactMap { $0 })
        objectWillChange.send(); imageLoader = loader
        var accepted: (ImageFileComparison, [RepositoryAccessLease])?
        loader.onAccepted = { [weak self, weak loader] comparison, permissions in
            guard let self, let loader, !self.retired, self.imageLoader === loader else { throw CocoaError(.userCancelled) }
            accepted = (comparison, permissions)
        }
        loader.onClosed = { [weak self, weak loader] in
            guard let self, let loader, self.imageLoader === loader else { accepted = nil; return }
            self.objectWillChange.send(); self.imageLoader = nil
            guard let request = accepted, !self.retired else { accepted = nil; return }
            accepted = nil
            self.imageViewerModel.fit = true
            self.standaloneImages = request.0; self.workingPermissions = request.1
            self.externalAttempted = true; self.viewerSelection = .image
            // The chooser must end its sheet before the ordinary reload guards
            // can admit this captured replacement. Cancel never supplies input.
            self.load()
        }
        loader.present(parent: window)
    }
    private var conflictBaseEntry: ConflictEntry?
    init(repository: GitRepository, access: RepositoryAccessLease?, conflict: ConflictBaseComparison) {
        self.repository = repository; self.access = access; snapshot = conflict.snapshot; path = conflict.entry.path
        conflictBaseEntry = conflict.entry
    }
    private var changeSetDocument: FileComparisonDocument?
    init(readOnly document: FileComparisonDocument, root: URL) {
        repository = nil; access = nil
        snapshot = RevisionComparisonSnapshot(root: root, from: document.base.revision, to: document.destination.revision, fromDetails: nil, toDetails: nil, files: [], options: .init())
        path = document.destination.path; changeSetDocument = document; externalAttempted = true
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, changeSets: CommitChangeSetComparison) {
        self.repository = repository; self.access = access
        snapshot = changeSets.snapshot; path = changeSets.document.destination.path
        changeSetDocument = changeSets.document
    }
    init(comparison: WorkingFileComparison, permissions: [RepositoryAccessLease]) {
        repository = nil; access = nil; workingComparison = comparison; workingPermissions = permissions
        snapshot = comparison.snapshot; path = comparison.destination.path
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, comparison: HistoricalWorkingFileComparison, permission: RepositoryAccessLease) {
        self.repository = repository; self.access = access; historicalWorkingComparison = comparison; workingPermissions = [permission]
        snapshot = comparison.snapshot; path = comparison.path
    }
    private func validateHistoricalWorkingAccess(_ comparison: HistoricalWorkingFileComparison) throws {
        guard !GitRuntime.isAppStoreBuild || (access?.hasSecurityScope == true && access?.contains(snapshot.root) == true && workingPermissions.contains { $0.hasSecurityScope && $0.contains(comparison.workingFile) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    private func validateWorkingAccess(_ comparison: WorkingFileComparison) throws {
        if let sourceSnapshotRoot, [comparison.base, comparison.destination].allSatisfy({ $0.resolvingSymlinksInPath().deletingLastPathComponent() == sourceSnapshotRoot }) { return }
        guard !GitRuntime.isAppStoreBuild || [comparison.base, comparison.destination].allSatisfy({ file in
            workingPermissions.contains { $0.hasSecurityScope && $0.contains(file) }
        }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func cancelLoadForClose() -> Bool {
        guard let loadSession else { return false }
        closeAfterLoad = true; loadSession.cancel(); return true
    }
    var initialLoadDeferred = false
    private var attemptedAppearanceLoad = false
    func loadOnAppearance() {
        guard !attemptedAppearanceLoad else { return }
        load()
    }
    func beginTransferredDocument() { initialLoadDeferred = false; load() }
    func load(discardingDraft: Bool = false) {
        guard !initialLoadDeferred, !retired, !busy, !hasPendingEditorChoice, !confirmingQuit, window?.attachedSheet == nil else { return }
        attemptedAppearanceLoad = true
        wrapLines = comparisonDefaults.bool(forKey: "TurtleGitMerge.WrapLines")
        if !singleFileMode { showInlineDiff = MergeInlinePresentation.defaultEnabled(from: comparisonDefaults) }
        if !loadedPaneMode { onePaneMode = OnePaneFileComparison.defaultEnabled(from: comparisonDefaults); loadedPaneMode = true }
        if dirty && !discardingDraft {
            let alert = NSAlert(); alert.messageText = "Save changes to “\(unsavedFilesDescription)” before reloading?"
            alert.addButton(withTitle: "Save and Reload"); alert.addButton(withTitle: "Reload Without Saving"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: saveAll { [weak self] saved in if saved { self?.load() } }; return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        reloadCommentProfiles = true
        generalPreferences = .load(from: comparisonDefaults); pendingLoadNavigation = generalPreferences.firstDifference
        initialBlockGeneration = nil
        let session = FileListComparisonSession(window: window, preferences: comparisonDefaults)
        loadSession = session; busy = true; error = nil
        Task {
            var externalOpened = false
            defer {
                if loadSession === session { loadSession = nil; busy = false }
                if !retired {
                    if externalOpened { externalDidOpen() }
                    else if closeAfterLoad { closeAfterLoad = false; window?.performClose(nil) }
                }
                withExtendedLifetime(access) {}; withExtendedLifetime(workingPermissions) {}
            }
            do {
                try await session.run(selectedCount: 0) { [self] token in
                    var replacements: [Bool: ComparisonFileContent] = [:]
                    for (base, target) in paneTargets {
                        guard !saveFolderAccess.requireScope || openPermissions.contains(where: { $0.permits(target.url) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                        replacements[base] = try target.read()
                    }
                    let storageReplacements = Dictionary(uniqueKeysWithValues:replacements.map { (storageSide($0.key),$0.value) })
                    var value: FileComparisonDocument
                    if replacements.count == 2, let originalPaneDocument { value = oriented(originalPaneDocument) }
                    else if let conflictBaseEntry, let repository {
                        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                        value = try await repository.conflictBaseComparison(conflictBaseEntry, cancellation: token).document
                    } else if let changeSetDocument {
                        value = changeSetDocument
                    } else if let standaloneImages {
                        guard !GitRuntime.isAppStoreBuild || [standaloneImages.base, standaloneImages.destination].compactMap({ $0 }).allSatisfy({ file in workingPermissions.contains { $0.hasSecurityScope && $0.contains(file) } }) else { throw ImageFileComparisonFailure.filePermissionRequired }
                        value = try standaloneImages.read()
                    } else if let historicalWorkingComparison, let repository {
                        try validateHistoricalWorkingAccess(historicalWorkingComparison)
                        value = try await repository.comparisonFile(historicalWorkingComparison, replacements: storageReplacements, cancellation: token)
                    } else if let workingComparison {
                        try validateWorkingAccess(workingComparison)
                        value = try workingComparison.read(replacements: storageReplacements)
                    } else if let repository {
                        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                        value = try await repository.comparisonFile(snapshot, path: path, replacements: storageReplacements, cancellation: token)
                    } else { throw RevisionComparisonFailure.selection }
                    value = oriented(value)
                    var original = value
                    for (base, replacement) in replacements {
                        if let prior = originalPaneDocument { original = original.replacingPane(base: base, content: base ? prior.base : prior.destination) }
                        value = value.replacingPane(base: base, content: replacement)
                    }
                    originalPaneDocument = original
                    guard !retired, !token.isCancelled else { return }
                    if !externalAttempted {
                        let chosen = try DiffToolPreferences.load(from: comparisonDefaults).selection(base: value.base.path, destination: value.destination.path, alternate: alternateTool)
                        pendingToolSelection = chosen
                        defer { pendingToolSelection = nil }
                        externalOpened = try await openExternalComparison(value, snapshot.root, workingPermissions + [access].compactMap { $0 }, alternateTool)
                        externalAttempted = true
                        viewerSelection = chosen == .image ? .image : .merge
                        guard !externalOpened, !retired, !token.isCancelled else { return }
                }
                let adapted = value.usingMergeEncoding(preferUTF8: ComparisonTextEncoding.preferUTF8(from: comparisonDefaults))
                document = adapted
                for (base, target) in paneTargets { paneTargets[base] = try target.recording(base ? adapted.base : adapted.destination) }
                imagePresentation.openImages = { [weak self] in self?.chooseImageFiles() }
                // Source dispatch chooses the viewer before decoding. Failed/empty
                // image sides stay in IDiff; Merge stays Merge even for PNG bytes.
                imageComparison = viewerSelection == .image ? ImageComparisonDocument(base: ComparisonImage(bytes: adapted.base.bytes), destination: ComparisonImage(bytes: adapted.destination.bytes)) : nil
                if let images = imageComparison {retainedImageModel?.configureImages(base:images.base,destination:images.destination,force:true)}
                window?.title = "\(standaloneImages == nil ? (sidesReversed ? adapted.destination.path : path) : (standaloneImages?.destination?.path ?? standaloneImages?.base?.path ?? "Images")) – " + (imageComparison == nil ? "TurtleGitMerge" : "TurtleGitIDiff")
                drafts = imageComparison == nil ? FileComparisonDrafts(adapted) : nil
                activeBase = drafts?.preferredBase ?? false
                selectEditorActions()
                rebuildAlignment(); resetHistory(); selectionRequest = nil
                difference = -1
                if imageComparison == nil { reloadEditorConfig() }
                }
            } catch { if !retired, !session.cancellation.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func rebuildAlignment() {
        guard let document else { return }
        retainingViewEdits = false
        regexCancellation?.cancel(); regexCancellation = nil; filtering = false
        historyCaretRequests = [:]; initialBlockGeneration = nil
        alignmentSelections = [:]
        alignmentGeneration += 1; selectedRows = nil; previewRow = nil; movedBlockRecords = []; retainedMoveLinks = nil
        let a = drafts?.text(base: true) ?? document.base.text
        let b = drafts?.text(base: false) ?? document.destination.text
        // Immediate projection supports native text/Undo coordinate updates.
        // It is unverified while filtering is true; transfers, navigation and
        // inline comparison are gated until Subversion publishes its ranges.
        alignment = a.flatMap { old in b.map { FileComparisonAlignment(base: old, destination: $0) } }
        guard let a, let b, imageComparison == nil, !retired else { return }
        let filter = regexFilters.first(where: { $0.name == regexFilterName })
        let current = alignmentGeneration, token = OperationCancellation(), detectMoves = showMovedBlocks
        let configuration = Result { () throws -> SubversionMergeConfiguration in
            if reloadCommentProfiles {
                commentProfiles = try MergeCommentProfileFile.load(at: commentProfileURL)
                reloadCommentProfiles = false
            }
            var value = try engineConfiguration ?? SubversionMergeConfiguration.bundled(filter: filter)
            value.filter = filter; value.options = comparisonOptions; value.commentTokens = commentTokens; value.regexExecutable = regexExecutable ?? value.regexExecutable
            return value
        }
        filtering = true; regexCancellation = token
        MergeRegexOperations.activeRequests += 1
        Task {
            defer { MergeRegexOperations.activeRequests -= 1 }
            // Editing uses an immediate coordinate projection. Debounce the
            // authoritative engine request so typing does not spawn a helper
            // for every intermediate keystroke; stale requests never publish.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !retired, alignmentGeneration == current, !token.isCancelled else { return }
            let result = await Task.detached { Result { try SubversionComparisonPresentation(plan: configuration.get().plan(base: a, mine: b, cancellation: token), detectMovedBlocks:detectMoves, whitespace:configuration.get().options.whitespace, cancellation:token) } }.value
            guard !retired, alignmentGeneration == current else { return }
            filtering = false; regexCancellation = nil
            switch result {
            case .success(let presentation):
                let value = presentation.alignment
                movedBlockRecords = presentation.movedBlocks
                var selections: [Bool: AlignmentSelection] = [:]
                for (side, scroll) in scrolls where !side || !onePaneActive && !singleFileMode {
                    // An outgoing native split child can register after the
                    // mode switch. Never queue a restore for a hidden pane.
                    if let owner=window,let text = scroll.documentView as? FileComparisonTextView,text.window === owner,
                       let source = try? FileComparisonEditing.sourceRange(text.selectedRange(), cells: text.sourceCells) {
                        selections[side] = .init(sourceRange: source)
                    }
                }
                if let previous = alignment {
                    drafts?.remapAnnotations(from: previous, to: value, base: true)
                    drafts?.remapAnnotations(from: previous, to: value, base: false)
                }
                alignment = value; difference = -1; selectedRows = nil; inlineCache = [:]
                alignmentSelections = selections
                if pendingLoadNavigation {
                    pendingLoadNavigation = false
                    initialBlockGeneration = current
                }

            case .failure(let failure): pendingLoadNavigation = false; alignment = nil; regexFilterName = nil; error = failure.localizedDescription
            }
        }
    }
    let saveFolderAccess=MergeSaveFolderAccess()
    private func authorizeWorkingReplacement(at file:URL,cancellation:OperationCancellation) async throws -> Bool {
        guard let acquired=try await saveFolderAccess.authorize(file:file,permissions:openPermissions,window:window,cancellation:cancellation) else {return false}
        try cancellation.check();guard !retired else {throw OperationCancellationFailure.cancelled}
        retainPermissions(acquired);return true
    }
    func save(completion: ((Bool) -> Void)? = nil) {
        guard let base = editableBase else { completion?(false); return }
        save(sides: [base], completion: completion)
    }
    func saveAll(completion: ((Bool) -> Void)? = nil) { save(sides: drafts?.dirtySides ?? [], completion: completion) }
    func saveAllForQuit(completion: @escaping (Bool) -> Void) {
        guard confirmingQuit else { completion(false); return }
        save(sides: drafts?.dirtySides ?? [], ownerInitiated: true, completion: completion)
    }
    func saveReboundResultFromOwner(completion: @escaping (Bool) -> Void) {
        guard paneTargets[false] != nil else { completion(false); return }
        save(sides: [false], ownerInitiated: true, completion: completion)
    }
    private var paneSave: OperationCancellation?
    private let saveChoices=MergeSaveChoices()
    private var updatingSaveDecision = false
    func cancelPaneSave() {paneSave?.cancel();saveChoices.cancel();saveFolderAccess.cancel()}
    private func ensurePaneSave(_ request: OperationCancellation) throws {
        guard !retired, paneSave === request else { throw OperationCancellationFailure.cancelled }
        try request.check()
    }
    var chooseMarkedSave: () async -> FileComparisonEditing.MarkedSaveChoice? = { nil }
    var chooseEmptyResult: ((String) async -> MergeEmptyResult)?
    func installMarkedSavePrompt() {
        chooseMarkedSave = { [weak self] in
            guard let self else {return nil}
            return await self.saveChoices.marked(window:self.window)
        }
    }
    private func saveReadOnlyPane(base:Bool,document:FileComparisonDocument,text:String,request:OperationCancellation) async throws -> Bool {
        guard let window else {return false}
        let content=base ? document.base : document.destination
        let directory=paneTargets[base]?.url.deletingLastPathComponent() ?? snapshot.root
        guard let url=await chooseExportLocation(window,(content.path as NSString).lastPathComponent,directory) else {return false}
        try ensurePaneSave(request)
        let permission=RepositoryAccessLease(url:url)
        if let sourceSnapshotRoot,url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(sourceSnapshotRoot.path + "/") {throw FileComparisonEditFailure.unsupported}
        let encoding=drafts?.encoding(base:base) ?? content.encoding
        let bytes=try encoding?.encode(text) ?? FileComparisonEditing.encoded(text,like:content)
        guard try await authorizeWorkingReplacement(at:url,cancellation:request) else {return false}
        try ensurePaneSave(request)
        try withExtendedLifetime(permission) {try MergePaneSaveAs.write(bytes,to:url)}
        let target=try SavedMergePane(url:url,writtenBytes:bytes,encoding:encoding)
        if originalPaneDocument==nil {originalPaneDocument=document}
        paneTargets[base]=target;retainPermissions([permission])
        self.document=document.replacingPane(base:base,content:target.content)
        try drafts?.didSaveAs(target.content,base:base)
        selectEditorActions();rebuildAlignment();reloadEditorConfig()
        return true
    }
    private func save(sides: [Bool], ownerInitiated: Bool = false, completion: ((Bool) -> Void)?) {
        let choiceAllowed = !hasPendingEditorChoice || ownerInitiated && projectionChange != nil && !exporting && formatRequest == nil && paneSave == nil
        guard paneSave == nil, (!busy && !confirmingQuit || ownerInitiated), choiceAllowed, !retired, window?.attachedSheet == nil, document != nil else { completion?(false); return }
        let request = OperationCancellation(), permissions = openPermissions
        paneSave = request;saveChoices.reset();error=nil; Self.activePaneExports += 1; busy = true
        Task {
            var saved = false
            defer {
                if paneSave === request { paneSave = nil; busy = false }
                Self.activePaneExports -= 1; withExtendedLifetime(permissions) {}; completion?(saved)
            }
            do {
                try ensurePaneSave(request)
                for base in sides where drafts?.isDirty(base: base) == true {
                    // Upstream FileSave resolves marks in Mine; the writable Base save
                    // and automatic PatchSave use separate paths without this prompt.
                    if !base, !annotations(base: false).marked.isEmpty {
                        guard let choice = await chooseMarkedSave() else { return }
                        try ensurePaneSave(request)
                        guard let alignment, let actions = editorActions[false] else { throw FileComparisonEditFailure.unsupported }
                        let text = try FileComparisonEditing.resolvingMarkedBlocks(alignment, targetBase: false, annotations: annotations(base: false), choice: choice)
                        updatingSaveDecision = true; actions.resolveForSave(text); updatingSaveDecision = false
                    }
                    guard let document, let text = drafts?.text(base: base) else { throw FileComparisonEditFailure.unsupported }
                    let content=base ? document.base : document.destination
                    let file=content.path.hasPrefix("/") ? URL(fileURLWithPath:content.path) : snapshot.root.appendingPathComponent(content.path)
                    if MergePaneSaveAs.requiresSaveAs(at:file,permissions:content.permissions,absent:content.isDeleted) {
                        guard try await saveReadOnlyPane(base:base,document:document,text:text,request:request) else {return}
                        continue
                    }
                    guard try await authorizeWorkingReplacement(at:file,cancellation:request) else {return}
                    try ensurePaneSave(request)
                    let choice: MergeEmptyResult
                    if text.isEmpty {
                        let savePath = base ? document.base.path : document.destination.path
                        if let chooseEmptyResult { choice = await chooseEmptyResult(savePath) }
                        else {guard let answer=await saveChoices.empty(window:window,path:savePath) else {return};choice=answer}
                    }
                    else { choice = .keep }
                    try ensurePaneSave(request)
                    let options = MergeFileSaveOptions(backupOriginal: MergeFileSaveOptions.backupEnabled(from: comparisonDefaults), emptyResult: choice)
                    let result: FileComparisonDocument
                    let context = oriented(savingContext(document)), physicalBase = storageSide(base)
                    if let target = paneTargets[base] {
                        guard !saveFolderAccess.requireScope || openPermissions.contains(where: { $0.permits(target.url) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                        result = try target.save(document, base: base, text: text, encoding: drafts?.encoding(base: base), options: options)
                    } else if let conflictBaseEntry, let repository {
                        guard !physicalBase else { throw FileComparisonEditFailure.unsupported }
                        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                        result = oriented(try await repository.saveConflictBaseComparison(conflictBaseEntry, document: context, text: text, encoding: drafts?.encoding(base: base), options: options,cancellation:request))
                    } else if let historicalWorkingComparison {
                        try validateHistoricalWorkingAccess(historicalWorkingComparison)
                        guard physicalBase else { throw FileComparisonEditFailure.unsupported }
                        result = oriented(try historicalWorkingComparison.saveBase(context, text: text, encoding: drafts?.encoding(base: base), options: options))
                    } else if let workingComparison {
                        try validateWorkingAccess(workingComparison)
                        result = oriented(try workingComparison.save(context, base: physicalBase, text: text, encoding: drafts?.encoding(base: base), options: options))
                    } else if let repository {
                        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                        result = oriented(try await repository.saveComparisonFile(snapshot, document: context, base: physicalBase, text: text, encoding: drafts?.encoding(base: base), options: options,cancellation:request))
                    } else { throw RevisionComparisonFailure.selection }
                    try ensurePaneSave(request)
                    var combined = result
                    for other in paneTargets.keys where other != base { combined = combined.replacingPane(base: other, content: other ? document.base : document.destination) }
                    self.document = combined
                    let savedContent = base ? result.base : result.destination
                    try drafts?.didSave(savedContent, base: base)
                    if let target = paneTargets[base] { paneTargets[base] = try target.recording(savedContent) }
                    else { originalPaneDocument = originalPaneDocument?.replacingPane(base: base, content: savedContent) }
                }
                if !retainingViewEdits { rebuildAlignment() }; saved = true
            } catch { if !retired && !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func remapOtherAnnotations(from old: FileComparisonAlignment, to new: FileComparisonAlignment, changedBase: Bool) {
        drafts?.remapAnnotations(from: old, to: new, base: !changedBase)
    }
    func applyInitialBlockSelection() {
        guard let generation = initialBlockGeneration, !retired, !filtering, contextCommandsAllowed else { return }
        guard generation == alignmentGeneration else { initialBlockGeneration = nil; return }
        let sides: [Bool] = onePaneActive || singleFileMode ? [false] : [true,false]
        for side in sides {
            guard let scroll = scrolls[side], ownsViewport(scroll, base: side), scroll.contentSize.width > 32, scroll.contentSize.height > 32,
                  let view = scroll.documentView as? FileComparisonTextView,
                  view.blockGeneration == generation else { return }
            let cells = displayCells(base:side)
            let expected = cells.map(\.displayText).joined(separator:"\n") + (cells.isEmpty ? "" : "\n")
            guard view.string.utf8.elementsEqual(expected.utf8), let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
        }
        initialBlockGeneration = nil; alignmentSelections = [:]; selectionRequest = nil
        updateFolding()
        let base = false, cells = displayCells(base:false), visible = folding.projection.rows.map(\.sourceRow)
        guard let first = visible.first,
              let target = MergeBlockNavigation.target(states:cells.map(\.state),visibleRows:visible,caret:first,direction:1,skipCurrent:false) else { return }
        if let view = scrolls[base]?.documentView as? NSTextView { window?.makeFirstResponder(view) }
        selectDifferenceBlock(target,base:base,advanceInline:true)
    }
    func register(_ scroll: NSScrollView, base: Bool) {
        guard !retired, !base || !onePaneActive && !singleFileMode,
              let view = scroll.documentView as? FileComparisonTextView, view.model === self,
              scroll.window == nil || scroll.window === window else { return }
        guard scrolls[base] !== scroll else { return }
        // A new representable registers before attachment. Keep the live pane
        // authoritative until its replacement actually joins this editor window.
        if let current = scrolls[base], current.window != nil, scroll.window == nil { return }
        scrolls[base] = scroll; onRegisterScroll(scroll,base); refreshLocatorViewport()
    }
    func scrolled(_ source: NSScrollView) {
        defer {
            refreshLocatorViewport()
            let next = scrolls.mapValues { $0.contentView.bounds.minX }
            if next != previewHorizontalOffsets { previewHorizontalOffsets = next }
        }
        guard !synchronizing else { return }; synchronizing = true; defer { synchronizing = false }
        for target in scrolls.values where target !== source {
            var point = target.contentView.bounds.origin; point.y = source.contentView.bounds.origin.y
            let constrained = target.contentView.constrainBoundsRect(NSRect(origin: point, size: target.contentView.bounds.size)).origin
            if constrained != target.contentView.bounds.origin {
                target.contentView.scroll(to: constrained); target.reflectScrolledClipView(target.contentView)
            }
        }
    }
    func clearNavigationBlockSelection(clearTextSelections: Bool = false) {
        for scroll in scrolls.values {
            if let view = scroll.documentView as? FileComparisonTextView {
                view.blockSelection.clear(in:view)
                if clearTextSelections { view.setSelectedRange(NSRange(location:view.selectedRange().location,length:0)) }
            }
        }
        selectedRows = nil
    }
    private(set) var selectingDifferenceBlock = false
    func selectMargin(rows: Range<Int>, selection: NSRange, caret: Int, base: Bool) {
        guard contextCommandsAllowed, !filtering, let scroll = scrolls[base], ownsViewport(scroll, base: base), let active = scroll.documentView as? FileComparisonTextView,
              MergeMarginGeometry.range(rows:rows,in:active) != nil, NSMaxRange(selection) <= active.string.utf16.count else { return }
        selectingDifferenceBlock = true
        defer { selectingDifferenceBlock = false; lineWrapping.recordViewportIntent() }
        activeBase = base; selectionRequest = nil
        for (side,scroll) in scrolls where !onePaneActive || !side {
            guard let view = scroll.documentView as? FileComparisonTextView, let block = MergeMarginGeometry.range(rows:rows,in:view) else { continue }
            view.blockSelection.install(block,caret:side == base ? caret:block.location,selection:side == base ? selection:nil,in:view)
        }
        updateSelection(selection,cells:displayCells(base:base));objectWillChange.send()
    }
    private func differenceTarget(_ step: Int) -> (MergeBlockNavigation.Target, Bool)? {
        guard contextCommandsAllowed, !filtering, alignment != nil,
              let view = activeFindText else { return nil }
        let base = onePaneActive ? false : scrolls[true]?.documentView === view
        let cells = displayCells(base: base)
        let selection = view.selectedRange()
        var offset = 0, row = max(0,cells.count - 1)
        for (index,cell) in cells.enumerated() {
            offset += cell.displayText.utf16.count + 1
            if selection.location < offset { row = index; break }
        }
        let visible = folding.projection.rows.map(\.sourceRow)
        return MergeBlockNavigation.target(states: cells.map(\.state), visibleRows: visible,
                                           caret: row, direction: step).map { ($0, base) }
    }
    func canNavigateDifference(_ step: Int) -> Bool { differenceTarget(step) != nil }
    func navigate(_ step: Int) {
        (activeFindText as? MergeLineNavigationProviding)?.beginUserNavigation()
        guard let (target,base) = differenceTarget(step) else { return }
        selectDifferenceBlock(target,base:base,advanceInline:true,reverseEntry:step < 0)
    }
    func selectContextBlock(at offset: Int, base: Bool) {
        guard contextCommandsAllowed, !filtering else { return }
        let cells = displayCells(base:base), lines = MergeFindLine.displayCells(cells)
        guard let row = lines.lastIndex(where: { $0.offset <= offset }),
              let block = MergeBlockNavigation.block(states:cells.map(\.state),containing:row) else { return }
        activatePane(base:base)
        clearNavigationBlockSelection(clearTextSelections:true)
        selectDifferenceBlock(block,base:base,advanceInline:false,contextOffset:offset)
    }
    private func selectDifferenceBlock(_ target: MergeBlockNavigation.Target, base: Bool, advanceInline: Bool, reverseEntry: Bool = false, contextOffset: Int? = nil) {
        lineWrapping.prepareForInput()
        selectingDifferenceBlock = true
        defer { selectingDifferenceBlock = false; lineWrapping.recordViewportIntent() }
        activeBase = base
        selectionRequest = nil
        var clickedSubline: Int?
        if let contextOffset, let view = scrolls[base]?.documentView as? NSTextView {
            let cells = displayCells(base:base)
            if cells.indices.contains(target.caret) {
                let start = cells.prefix(target.caret).reduce(0) { $0 + $1.displayText.utf16.count + 1 }
                clickedSubline = MergeWrappedCaret.subline(in:MergeWrappedCaret.starts(in:view,row:NSRange(location:start,length:cells[target.caret].displayText.utf16.count)),containing:contextOffset)
            }
        }
        for (side, scroll) in scrolls {
            guard ownsViewport(scroll, base: side), let text = scroll.documentView as? NSTextView else { continue }
            let cells = displayCells(base: side)
            guard cells.indices.contains(target.rows.lowerBound), cells.indices.contains(target.rows.upperBound - 1) else { continue }
            let start = cells.prefix(target.rows.lowerBound).reduce(0) { $0 + $1.displayText.utf16.count + 1 }
            let length = cells[target.rows].reduce(0) { $0 + $1.displayText.utf16.count + 1 } - 1
            let range = NSRange(location: start, length: max(0, length))
            guard NSMaxRange(range) <= text.string.utf16.count else { continue }
            let rowStart = cells.prefix(target.caret).reduce(0) { $0 + $1.displayText.utf16.count + 1 }
            let rowRange = NSRange(location:rowStart,length:cells[target.caret].displayText.utf16.count)
            let caret = MergeWrappedCaret.offset(in:text,row:rowRange,reverse:reverseEntry,subline:clickedSubline)
            if let view = text as? FileComparisonTextView {
                view.blockSelection.install(range,caret:caret,in:view)
            }
        }
        // Source SelectNextBlock advances within the entry line after setting
        // the block, and only when inline navigation is available.
        if advanceInline { (scrolls[base]?.documentView as? FileComparisonTextView)?.navigateInline(forward:true) }
        // One active-pane center keeps the linked viewports aligned when peer
        // lines wrap into different numbers of actual TextKit fragments.
        if let view = scrolls[base]?.documentView as? FileComparisonTextView { view.blockSelection.centerCaret(in:view) }
        if let text = scrolls[base]?.documentView as? NSTextView {
            updateSelection(text.selectedRange(), cells: displayCells(base: base))
        }
        objectWillChange.send()
    }
    var activeFindText: NSTextView? {
        let current = scrolls.filter { ownsViewport($0.value, base: $0.key) }
        return current.values.compactMap { $0.documentView as? NSTextView }.first { $0.window?.firstResponder === $0 }
            ?? (current[activeBase]?.documentView as? NSTextView)
    }
    func find(_ action: NSTextFinder.Action) {
        (activeFindText as? MergeLineNavigationProviding)?.beginUserNavigation()
        if let text = activeFindText { MergeFindInterface.perform(action, in: text) }
    }
    func replaceFindMatches(_ ranges: [NSRange], cells: [MergeSourceCell], base: Bool, replacement: String) -> Bool {
        guard canTransfer(toBase: base), let actions = editorActions[base], !ranges.isEmpty else { return false }
        do {
            if onePaneActive, !base, let combined {
                let edit = try combined.applying(replacement, ranges: ranges); actions.replace(edit.text, edit.caret, nil); return true
            }
            let sourceRanges = try ranges.map { try FileComparisonEditing.sourceRange($0, cells: cells) }
            let value = NSMutableString(string: draftText(base: base))
            guard sourceRanges.allSatisfy({ NSMaxRange($0) <= value.length }) else { return false }
            for range in sourceRanges.reversed() { value.replaceCharacters(in: range, with: replacement) }
            activatePane(base: base)
            let delta = sourceRanges.dropLast().reduce(0) { $0 + (replacement as NSString).length - $1.length }
            let caret = sourceRanges.last!.location + delta + (replacement as NSString).length
            actions.replace(value as String, caret, nil)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
private struct FileComparisonDialog: View {
    @ObservedObject var model: FileComparisonWindowModel
    private func pane(base: Bool) -> some View {
        let content = base ? model.document?.base : model.document?.destination
        let header: String
        if model.onePaneActive, let document = model.document {
            header = document.base.path + " : " + document.base.revision.label + " – " + document.destination.path + " : " + document.destination.revision.label
        } else { header = (content?.path ?? model.path) + " : " + (content?.revision.label ?? (base ? model.snapshot.from.label : model.snapshot.to.label)) }
        return VStack(alignment: .leading, spacing: 5) {
            Text(model.onePaneActive ? "Base – Mine" : base ? "Base" : "Mine").font(.headline)
            Text(header).font(.system(.caption, design: .monospaced)).lineLimit(1).help(header)
            if let alignment = model.alignment {
                FileComparisonEditor(model: model, cells: model.displayCells(base: base), base: base)
            } else if let content {
                if let text = content.text { FileComparisonEditor(model: model, cells: FileComparisonAlignment(base: text, destination: text).rows.map(\.base), base: base) }
                else if let image = NSImage(data: content.bytes) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ScrollView { Text("Binary or unsupported text encoding · \(content.bytes.count) bytes\n\n" + content.bytes.prefix(4096).enumerated().map { ($0.offset % 16 == 0 ? "\n" : " ") + String(format: "%02X", $0.element) }.joined()).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            } else { Color(nsColor: .textBackgroundColor) }
            if let alignment=model.alignment {
                let states=model.onePaneActive ? model.combined?.rows.map { $0.cell.state } ?? []:alignment.rows.map {base ? $0.base.state:$0.destination.state}
                let counts=MergeLineStatistics(states:states)
                if !counts.isEmpty {MergeLineStatisticsView(statistics:counts)}
            }
            HStack {
                MergeFormatControls(label: base ? "Base" : "Mine", encoding: model.encoding(base: base) ?? content?.encoding, text: content?.text == nil ? nil : model.draftText(base: base), editable: model.canTransfer(toBase: base), changeEncoding: { model.changeEncoding($0, base: base) }, changeEnding: { model.changeLineEnding($0, base: base) }, showFormatDialog:{ model.showFormatDialog(base:base) })
                Spacer()
                MergeTabControls(label: base ? "Base" : "Mine", tabWidth: model.tabWidth(base: base), useSpaces: model.useSpaces(base: base), smartTab: model.smartTab(base: base), changeWidth: { model.tabWidths[base] = $0 }, changeSpaces: { model.spacePanes[base] = $0 }, changeSmart: { model.smartTabPanes[base] = $0 }, editorConfigEnabled: model.editorConfigEnabled[base] == true, editorConfigLoaded: model.editorConfigLoaded[base] == true, changeEditorConfig: { model.setEditorConfig($0, base: base) }).disabled(model.busy || model.confirmingQuit || model.editorConfigLoading.contains(base))
                Text("\(content?.isDeleted == true ? "Deleted" : content?.mode ?? "Absent") · \(content?.bytes.count ?? 0) saved bytes").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
    var body: some View {
        Group {
            if let images = model.imageComparison, let document = model.document {
                ImageComparisonDialog(images: images, document: document, model: model.imageViewerModel).id(images.id)
            } else { textBody }
        }.onAppear { model.loadOnAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: .mergeEditorPreferencesChanged)) { _ in model.refreshPreferences() }
        .onReceive(NotificationCenter.default.publisher(for: .mergeRegexFiltersChanged)) { _ in model.refreshRegexFilters() }
        .alert("Comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var textBody: some View {
        VStack(spacing: 0) {
            if !model.nativeToolbarInstalled {
            HStack {
                Button { model.save() } label: { CommandLabel(title: "Save", icon: .mergeSave) }.disabled(!model.activeDirty)
                Menu { if !model.onePaneActive { Button("Save left pane as…") { model.saveAs(base: true) } }; Button("Save right pane as…") { model.saveAs(base: false) } } label: { CommandLabel(title: "Save As", icon: .mergeSaveAs) }.disabled(!model.canSavePaneAs)
                Button { model.undo() } label: { Image(nsImage: MenuIcon.mergeUndo.image() ?? NSImage()) }.help("Undo").accessibilityLabel("Undo").disabled(!model.canUndo)
                Button { model.redo() } label: { Image(nsImage: MenuIcon.mergeRedo.image() ?? NSImage()) }.help("Redo").accessibilityLabel("Redo").disabled(!model.canRedo)
                Button { model.load() } label: { CommandLabel(title: "Reload", icon: .mergeReload) }
                Button { model.navigate(-1) } label: { CommandLabel(title: "Previous difference", icon: .mergePreviousConflict) }.disabled(!model.canNavigateDifference(-1))
                Button { model.navigate(1) } label: { CommandLabel(title: "Next difference", icon: .mergeNextConflict) }.disabled(!model.canNavigateDifference(1))
                Button { model.find(.showFindInterface) } label: { CommandLabel(title: "Find", icon: .mergeFind) }.disabled(model.alignment == nil)
                Button { model.createUnifiedPatch() } label: { CommandLabel(title: "Create patch file", icon: .patch) }.disabled(!model.canCreateUnifiedPatch)
                Spacer()
            }.padding(10).disabled(model.busy || model.confirmingQuit)
            }
            HStack {
                Toggle("Enable editing", isOn: $model.editingEnabled).disabled(model.editableBase == nil || model.busy || model.confirmingQuit)
                Spacer()
                MergeInlineControls(enabled: model.showInlineDiff, word: model.inlineWordDiff, applyEnabled: model.setInlineDiff, applyWord: model.setInlineWordDiff).disabled(model.singleFileMode || model.filtering || model.alignment == nil)
                Menu("Inline navigation") {
                    Button { model.navigateInline(forward: true) } label: { CommandLabel(title: "Next inline difference", icon: .mergeNextInline) }.disabled(!model.canNavigateInline(forward: true))
                    Button { model.navigateInline(forward: false) } label: { CommandLabel(title: "Previous inline difference", icon: .mergePreviousInline) }.disabled(!model.canNavigateInline(forward: false))
                }.fixedSize().disabled(model.onePaneActive || model.filtering || model.alignment == nil)
                Toggle("Two-pane view", isOn: Binding(get: { !model.onePaneMode }, set: { model.switchPaneMode(!$0) })).disabled(model.singleFileMode || model.filtering || model.alignment == nil)
                Toggle("Line diff bar", isOn: $model.showLineDiffBar).disabled(model.singleFileMode || model.onePaneActive)
                Toggle("Line numbers", isOn: $model.showLineNumbers)
            }.toggleStyle(.checkbox).padding(.horizontal, 10).padding(.bottom, 8)
            HStack {
                MergeViewControls(preferences: model.locatorPreferences, apply: model.setLocatorPreferences, whitespace: model.whitespaceDisplay, applyWhitespace: model.setWhitespaceDisplay, wrapLines: model.wrapLines, applyWrap: model.setWrapLines, collapsed: model.folding.collapsed, applyCollapsed: model.setCollapsed, movedBlocks:model.showMovedBlocks, canChangeMovedBlocks:model.canChangeMovedBlocks, applyMovedBlocks:model.setMovedBlocks, toolbarVisible:model.showToolbar, applyToolbar:model.setToolbarVisible, statusBarVisible:model.showStatusBar, applyStatusBar:model.setStatusBarVisible, canSwitchSides:model.canSwitchSides, switchSides:model.switchSides).disabled(model.busy || model.confirmingQuit)
                MergeComparisonControls(options: model.comparisonOptions, apply: model.setComparisonOptions, supportsComments: model.supportsComments).disabled(model.busy || model.confirmingQuit)
                Menu {
                    Button { model.selectRegexFilter(nil) } label: {
                        if model.regexFilterName == nil { Label("No Filter", systemImage: "checkmark") } else { Text("No Filter") }
                    }
                    ForEach(model.regexFilters) { filter in
                        Button { model.selectRegexFilter(filter.name) } label: {
                            if model.regexFilterName == filter.name { Label(filter.name, systemImage: "checkmark") } else { Text(filter.name) }
                        }
                    }
                    Divider(); Button("Edit Filters…") { model.manageRegexFilters() }
                } label: { Text("Regex Filter: " + (model.regexFilterName ?? "No Filter")) }
                .fixedSize().disabled(model.busy || model.confirmingQuit)
                if model.filtering { ProgressView().controlSize(.small); Text("Comparing…").font(.caption) }
                Spacer()
            }.padding(.horizontal, 10).padding(.bottom, 8)
            HStack {
                Menu {
                    Button { model.useOtherBlock() } label: { CommandLabel(title: "Use other block", icon: .mergeUseTheirs) }
                    Button { model.useOtherBlock(.currentThenOther) } label: { CommandLabel(title: "Use both blocks, this one first", icon: .mergeMineThenTheirs) }
                    Button { model.useOtherBlock(.otherThenCurrent) } label: { CommandLabel(title: "Use both blocks, this one last", icon: .mergeTheirsThenMine) }
                } label: { CommandLabel(title: "Use other block", icon: .mergeUseTheirs) }.disabled(!model.oppositeViewCommandsAllowed || !model.canTransfer || model.transferRows == nil)
                Button { model.useOtherFile() } label: { CommandLabel(title: "Use other file", icon: .mergeUseTheirs) }.disabled(!model.oppositeViewCommandsAllowed || !model.canTransfer)
                Spacer()
            }.padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            HStack(spacing: 0) {
                if model.locatorPreferences.visible {
                    MergeLocatorBar(map: model.locatorMap, viewport: model.locatorViewport, highlights: model.locatorHighlights, fishEye: model.locatorPreferences.fishEye,
                                    enabled: !model.busy && !model.filtering && !model.confirmingQuit, navigate: model.scrollLocator)
                        .frame(width: 44).help("Left and right file overview; click or drag to scroll")
                }
                if !model.singleFileMode && !model.onePaneActive {
                    MergeComparisonSplit(preferences:model.comparisonDefaults,left:AnyView(pane(base:true)),right:AnyView(pane(base:false)))
                } else { pane(base:false) }
            }
            if model.showLineDiffBar && !model.singleFileMode && !model.onePaneActive {
                Divider()
                MergeLineDiffBar(model: model).frame(height: MergeLineDiffPreview.lineHeight(model.generalPreferences.nativeFont) * 2)
            }
            if model.showStatusBar {
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.filtering ? "Comparing…" : model.alignment.map { "\($0.differences.count) difference(s)" } ?? "").font(.caption)
                Spacer()
                MergeTypingModeControl(overwrite:model.overwriteModes[model.activeBase] == true,enabled:model.canTransfer(toBase:model.activeBase),toggle:{ model.overwriteModes[model.activeBase] = !(model.overwriteModes[model.activeBase] ?? false) })
                Text(model.dirty ? "Modified · working file not saved" : model.editingEnabled && model.editableBase != nil ? "Editing working file" : "Read-only comparison").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
            }
        }
    }
}
struct FileComparisonEditor: NSViewRepresentable {
    @ObservedObject var model: FileComparisonWindowModel
    let cells: [MergeSourceCell]
    let base: Bool
    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.base = base
        let view = FileComparisonTextView(); view.isEditable = false; view.isRichText = false
        view.model = model; view.baseSide = base
        view.allowsUndo = true; view.delegate = context.coordinator
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.font = model.generalPreferences.nativeFont
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false; view.textContainer?.containerSize = view.maxSize
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.setAccessibilityLabel(base ? "Base file" : "Destination file")
        let scroll = NSScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.findBarPosition = .belowContent
        scroll.hasVerticalRuler = true; scroll.verticalRulerView = MergeLineRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        model.registerEditor(base: base, actions: .init(
            reset: { [weak coordinator = context.coordinator] in coordinator?.history.removeAllActions(); coordinator?.updateUndoState() },
            refresh: { [weak coordinator = context.coordinator] in coordinator?.updateUndoState() },
            undo: { [weak coordinator = context.coordinator] in guard let coordinator, !coordinator.model.busy, !coordinator.model.confirmingQuit else { return }; coordinator.history.undo(); coordinator.updateUndoState() },
            redo: { [weak coordinator = context.coordinator] in guard let coordinator, !coordinator.model.busy, !coordinator.model.confirmingQuit else { return }; coordinator.history.redo(); coordinator.updateUndoState() },
            replace: { [weak coordinator = context.coordinator] text, caret, cleared in coordinator?.replace(text, caret: caret, cleared: cleared) },
            type: { [weak coordinator = context.coordinator] text, caret in coordinator?.replace(text, caret: caret, typing: true) },
            annotate: { [weak coordinator = context.coordinator] value in coordinator?.annotate(value) },
            keep: { [weak coordinator = context.coordinator] text in coordinator?.replace(text, caret: 0, clearMarks: true) },
            resolveForSave: { [weak coordinator = context.coordinator] text in coordinator?.replace(text, caret: 0, clearMarks: true, resolvingSave: true) }
        ))
        view.history = context.coordinator.history
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        model.register(scroll, base: base)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        (view as? FileComparisonTextView)?.baseSide = base
        model.register(scroll, base: base)
        view.backgroundColor = MergePalette.color(MergeSourceState.normal)
        view.insertionPointColor = MergePalette.foreground(.normal)
        view.font = model.generalPreferences.nativeFont
        if !model.wrapLines { DispatchQueue.main.async { model.refreshLocatorViewport() } }
        // Hosting can deliver a previously captured View value after an edit.
        // Read the current alignment and preserve the selection in source
        // coordinates before replacing attributed display text.
        (view as? FileComparisonTextView)?.foldLayout.prepare(view)
        let oldDisplay = view.string
        let previousCells = (view as? FileComparisonTextView)?.sourceCells ?? context.coordinator.cells
        let sourceSelection = try? FileComparisonEditing.sourceRange(view.selectedRange(), cells: previousCells)
        let cells = model.alignment == nil ? self.cells : model.displayCells(base: base)
        context.coordinator.cells = cells; context.coordinator.base = base
        if let target = view as? FileComparisonTextView, target.blockGeneration != model.alignmentGeneration {
            target.blockSelection.clear(in:target); target.invalidateNavigationRevision(); target.blockGeneration = model.alignmentGeneration
        }
        (view as? FileComparisonTextView)?.sourceCells = cells
        if let renderer = (view as? MergeWhitespaceDisplaying)?.whitespaceRenderer {
            renderer.update(text: cells.map(\.displayText).joined(separator: "\n") + (cells.isEmpty ? "" : "\n"), cells: cells,
                            otherCells: model.onePaneActive ? nil : model.alignment?.rows.map { base ? $0.destination : $0.base }, preferences: model.whitespaceDisplay)
            renderer.removal = base; renderer.highlightEndings = model.showInlineDiff
        }
        view.isEditable = model.editingEnabled && model.editableBase == base && !model.busy && !model.confirmingQuit
        (view as? FileComparisonTextView)?.mergeFindController?.updateGates()
        let value = Self.attributed(cells, font: view.font!, model: model, base: base)
        (view as? FileComparisonTextView)?.missingOffsets = Self.missingOffsets(cells, model: model, base: base)
        view.needsDisplay = true
        if !view.string.utf8.elementsEqual(value.string.utf8) { view.textStorage?.setAttributedString(value) }
        else { value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in view.textStorage?.setAttributes(attributes, range: range) } }
        if let sourceSelection, !oldDisplay.utf8.elementsEqual(value.string.utf8) {
            let start = min(FileComparisonEditing.displayOffset(sourceOffset: sourceSelection.location, cells: cells), value.length)
            let end = min(FileComparisonEditing.displayOffset(sourceOffset: NSMaxRange(sourceSelection), cells: cells), value.length)
            let range = NSRange(location: start, length: max(0, end - start))
            if view.selectedRange() != range { view.setSelectedRange(range) }
        }
        model.updateFolding()
        (view as? FileComparisonTextView)?.foldLayout.apply(to: view, controller: model.folding)
        model.lineWrapping.geometryChanged = { [weak model] in DispatchQueue.main.async { model?.applyViewportNavigation(); model?.refreshLocatorViewport() } }
        model.lineWrapping.update(scroll, key: base ? "Base" : "Mine", aligned: !model.onePaneActive && !model.singleFileMode, enabled: model.wrapLines)
        let moved = model.movedRowLinks(base:base), generation = model.alignmentGeneration
        scroll.rulersVisible = true
        if let ruler = scroll.verticalRulerView as? MergeLineRuler {
            ruler.showNumbers = model.showLineNumbers
            ruler.movedRows = moved.mapValues(\.tooltip)
            ruler.followMovedRow = { [weak model] row in model?.followMovedBlock(row:row,base:base,generation:generation) }
            ruler.updateRecords(cells,peers:model.onePaneActive || model.singleFileMode ? nil : model.displayCells(base:!base))
        }
        (scroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers = cells.map(\.lineNumber)
        (scroll.verticalRulerView as? MergeLineRuler)?.updateMetrics(for: view)
        (scroll.verticalRulerView as? MergeLineRuler)?.markedRows = model.onePaneActive ? Set((model.combined?.rows ?? []).enumerated().compactMap { model.annotations(base: false).marked.contains($0.element.alignmentRow) ? $0.offset : nil }) : model.annotations(base: base).marked
        scroll.verticalRulerView?.needsDisplay = true
        model.registerViewportNavigation(base: base, scroll: scroll) { [weak coordinator = context.coordinator] in coordinator?.applyViewportSelection() }
        if let target = view as? MergeFindProviding {
            target.mergeFindHighlights.annotationsChanged = { [weak model] in model?.refreshLocatorHighlights() }
            target.mergeFindHighlights.refresh(in: view)
        }
        model.refreshLocatorHighlights()
        // Run once after layout, including the first representable update.
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in coordinator?.applyViewportSelection() }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.model.unregister(scroll, base: coordinator.base)
        NotificationCenter.default.removeObserver(coordinator)
        if let view = scroll.documentView as? FileComparisonTextView {
            view.mergeFindController?.close(); view.delegate = nil; view.model = nil; view.history = nil
        }
        coordinator.scroll = nil
    }
    static func inline(_ row: Int, model: FileComparisonWindowModel, base: Bool) -> MergeInlineComparison? {
        if model.onePaneActive, !base, model.showInlineDiff, let combined = model.combined, combined.rows.indices.contains(row) {
            let current = combined.rows[row], neighbor = current.base ? row + 1 : row - 1
            guard current.cell.displayText.utf16.count <= model.generalPreferences.maximumInlineLength, combined.rows.indices.contains(neighbor), combined.rows[neighbor].base != current.base,
                  current.cell.state == (current.base ? .removed : .added),
                  combined.rows[neighbor].cell.state == (current.base ? .added : .removed) else { return nil }
            let old = current.base ? current.cell.displayText : combined.rows[neighbor].cell.displayText
            let new = current.base ? combined.rows[neighbor].cell.displayText : current.cell.displayText
            return MergeInlineComparison(base: old, destination: new, word: model.inlineWordDiff, maximumLength: model.generalPreferences.maximumInlineLength)
        }
        guard let alignment = model.alignment, alignment.rows.indices.contains(row),
              (base ? alignment.rows[row].base : alignment.rows[row].destination).displayText.utf16.count <= model.generalPreferences.maximumInlineLength else { return nil }
        return model.inlineDifference(row)
    }
    static func missingOffsets(_ cells: [MergeSourceCell], model: FileComparisonWindowModel, base: Bool) -> [Int] {
        var offset = 0, result: [Int] = []
        for (index, cell) in cells.enumerated() {
            if let diff = inline(index, model: model, base: base) { result += ((model.onePaneActive && !base ? model.combined?.rows[index].base == true : base) ? diff.baseMissing : diff.destinationMissing).map { offset + $0 } }
            offset += (cell.displayText as NSString).length + 1
        }
        return result
    }
    static func attributed(_ cells: [MergeSourceCell], font: NSFont, model: FileComparisonWindowModel, base: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        paragraph.defaultTabInterval = CGFloat(model.tabWidth(base: base)) * (" " as NSString).size(withAttributes: [.font: font]).width
        let value = NSMutableAttributedString(string: "")
        for (index, cell) in cells.enumerated() {
            let diff = inline(index, model: model, base: base), offset = value.length
            value.append(NSAttributedString(string: cell.displayText + "\n", attributes: [.font: font, .foregroundColor: MergePalette.foreground(cell.state), .backgroundColor: diff == nil ? MergePalette.color(cell.state) : MergePalette.inlineCommon, .paragraphStyle: paragraph]))
            if let diff {
                let removal = model.onePaneActive && !base ? model.combined?.rows[index].base == true : base
                for range in removal ? diff.base : diff.destination { value.addAttribute(.backgroundColor, value: removal ? MergePalette.inlineRemoved : MergePalette.inlineAdded, range: NSRange(location: offset + range.location, length: range.length)) }
            }
        }
        return value
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: FileComparisonWindowModel
        var appliedSelection: UUID?
        weak var scroll: NSScrollView?
        var cells: [MergeSourceCell] = []
        var base = false
        let history: UndoManager
        init(model: FileComparisonWindowModel) { self.model = model; history = model.comparisonHistory }
        func applyViewportSelection() {
            let model = self.model, base = self.base
            guard let scroll, model.ownsViewport(scroll, base: base), scroll.contentSize.width > 32, scroll.contentSize.height > 32,
                  let view = scroll.documentView as? FileComparisonTextView, view.blockGeneration == model.alignmentGeneration,
                  let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for:container)
            model.applyInitialBlockSelection()
            if let selection = model.alignmentSelections[base], appliedSelection != selection.id {
                appliedSelection = selection.id
                let start = FileComparisonEditing.displayOffset(sourceOffset: selection.sourceRange.location, cells: cells)
                let end = FileComparisonEditing.displayOffset(sourceOffset: NSMaxRange(selection.sourceRange), cells: cells)
                view.setSelectedRange(NSRange(location: min(start, (view.string as NSString).length), length: max(0, min(end, (view.string as NSString).length) - min(start, (view.string as NSString).length))))
                if selection.scroll { view.scrollRangeToVisible(view.selectedRange()) }
                DispatchQueue.main.async { if model.alignmentSelections[base]?.id == selection.id { model.alignmentSelections.removeValue(forKey: base) } }
            }
            if model.editableBase == base, let caret = model.selectionRequest {
                let offset = FileComparisonEditing.displayOffset(sourceOffset: caret, cells: cells)
                view.setSelectedRange(NSRange(location: min(offset, (view.string as NSString).length), length: 0))
                view.scrollRangeToVisible(view.selectedRange())
                DispatchQueue.main.async { if model.selectionRequest == caret { model.selectionRequest = nil } }
            }
            model.restoreHistoryCaret(base:base,view:view,cells:cells)
        }
        @objc func scrolled(_ notification: Notification) { if let scroll { model.scrolled(scroll) } }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard model.editingEnabled, model.editableBase == base, !model.busy, !model.confirmingQuit else { return false }
            if affectedCharRange.length == 0 && (replacementString ?? "").isEmpty { return false }
            do {
                if !model.filtering, let alignment = model.alignment {
                    let edit = try FileComparisonInPlaceEdit(alignment:alignment,combined:model.onePaneActive && !base ? model.combined : nil,base:base,range:affectedCharRange,replacement:replacementString ?? "")
                    replace(edit.text,caret:edit.caret,typing:true,presentation:model.presentation(for:edit,base:base),displayCaret:edit.displayCaret)
                    return false
                }
                let edit: (text: String, caret: Int)
                if model.onePaneActive, !base, let combined = model.combined { edit = try combined.applying(replacementString ?? "", ranges: [affectedCharRange]) }
                else { edit = try FileComparisonEditing.applying(replacementString ?? "", range: affectedCharRange, cells: cells) }
                replace(edit.text, caret: edit.caret, typing: true)
            } catch { model.error = error.localizedDescription }
            return false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if !model.selectingDifferenceBlock { (view as? FileComparisonTextView)?.foldLayout.reveal(selection: view.selectedRange(), in: view) }
            let range = view.selectedRange(), cells = cells, generation = model.alignmentGeneration
            // A user's new selection supersedes the caret requested by the
            // preceding edit. Clear it synchronously before a queued hosting
            // update can collapse that selection while the engine is pending.
            if let caret = model.selectionRequest,
               let source = try? FileComparisonEditing.sourceRange(range, cells: cells),
               source.length > 0 || source.location != caret {
                model.selectionRequest = nil
            }
            DispatchQueue.main.async { if self.model.activeBase == self.base, self.model.alignmentGeneration == generation, view.selectedRange() == range { self.model.updateSelection(range, cells: cells) } }
        }
        func updateUndoState() { guard model.activeBase == base else { return }; model.canUndo = history.canUndo; model.canRedo = history.canRedo }
        func annotate(_ value:FileComparisonEditing.Annotations) {
            guard model.canTransfer(toBase:base),let view = scroll?.documentView as? FileComparisonTextView else {return}
            let selection = view.selectedRange(),block = view.mergeSelectedBlockRange
            let sourceCaret = (try? FileComparisonEditing.sourceRange(NSRange(location:selection.location,length:0),cells:cells).location) ?? 0
            replace(model.draftText(base:base),caret:sourceCaret,restored:value,presentation:model.captureEditingPresentation(),displayCaret:selection.location,actionName:"Mark block")
            view.setSelectedRange(selection)
            if let block {view.blockGeneration = model.alignmentGeneration;view.blockSelection.install(block,caret:selection.location,in:view)}
            model.updateSelection(selection,cells:cells)
        }
        func cycleEnding(_ edit:FileComparisonLineEndingEdit,displayCaret:Int) {
            guard model.canTransfer(toBase:base),let old = model.captureEditingPresentation() else {return}
            var annotations = old.annotations,revisions = old.revisions
            if edit.combined != nil {
                for side in [true,false] { annotations[side] = model.annotations(base:side).remapped(from:old.alignment,to:edit.alignment,targetBase:side,typing:false) }
            }
            var changed = annotations[base] ?? .init();changed.edited.insert(edit.alignmentRow);annotations[base] = changed;revisions[base] = UUID()
            // The combined display keeps its record order even when its
            // alignment indices change; retained links use display coordinates.
            let links = edit.combined == nil ? old.moveLinks : [false:model.movedRowLinks(base:false)]
            let next = FileComparisonWindowModel.EditingPresentation(alignment:edit.alignment,combined:edit.combined,annotations:annotations,revisions:revisions,moves:old.moves,moveLinks:links)
            let sourceCaret = (try? FileComparisonEditing.sourceRange(NSRange(location:displayCaret,length:0),cells:cells).location) ?? 0
            replace(edit.text,caret:sourceCaret,presentation:next,displayCaret:displayCaret,actionName:"Cycle line ending")
        }
        func replace(_ text: String, caret: Int, restored: FileComparisonEditing.Annotations? = nil, cleared: Range<Int>? = nil, typing: Bool = false, clearMarks: Bool = false, resolvingSave: Bool = false, historyCaret: FileComparisonWindowModel.HistoryCaret? = nil, presentation: FileComparisonWindowModel.EditingPresentation? = nil, displayCaret: Int? = nil, actionName:String = "Edit comparison") {
            guard model.canEdit(base: base), resolvingSave || (!model.busy && !model.confirmingQuit) else { return }
            let old = model.draftText(base: base), previous = model.annotations(base: base), oldAlignment = model.alignment
            var next = previous
            if clearMarks { next.marked = [] }
            if let cleared { next.marked.subtract(cleared); next.edited.subtract(cleared) }
            let textChanged = !old.utf8.elementsEqual(text.utf8)
            guard textChanged || restored != nil || next != previous || presentation != nil || typing else { return }
            if !textChanged, (restored ?? next) == previous, presentation == nil, !typing { return }
            let previousCaret = model.captureHistoryCaret(base:base)
            let previousPresentation = model.captureEditingPresentation()
            history.beginUndoGrouping(); defer { history.endUndoGrouping(); updateUndoState() }
            history.registerUndo(withTarget:self) { target in
                target.replace(old,caret:previousCaret?.sourceOffset ?? min(caret,old.utf16.count),restored:previous,historyCaret:previousCaret,presentation:previousPresentation)
            }
            history.setActionName(actionName)
            model.updateDraft(text, base: base)
            if model.activeBase == base { model.selectionRequest = caret }
            if let presentation { model.installEditingPresentation(presentation) }
            else { model.rebuildAlignment() }
            if typing && presentation == nil { model.recordTypingEdit(base:base) }
            if presentation == nil, let oldAlignment, let alignment = model.alignment { model.remapOtherAnnotations(from: oldAlignment, to: alignment, changedBase: base) }
            if let restored { model.updateAnnotations(restored, base: base) }
            else if presentation == nil, let oldAlignment, let alignment = model.alignment { model.updateAnnotations(next.remapped(from: oldAlignment, to: alignment, targetBase: base, typing: typing), base: base) }
            if let alignment = model.alignment, let view = scroll?.documentView as? NSTextView {
                cells = model.displayCells(base: base)
                (view as? FileComparisonTextView)?.sourceCells = cells
                view.textStorage?.setAttributedString(FileComparisonEditor.attributed(cells, font: view.font!, model: model, base: base))
                (view as? FileComparisonTextView)?.missingOffsets = FileComparisonEditor.missingOffsets(cells, model: model, base: base)
                if model.activeBase == base {
                    view.setSelectedRange(NSRange(location: min(displayCaret ?? FileComparisonEditing.displayOffset(sourceOffset: caret, cells: cells), (view.string as NSString).length), length: 0))
                    // The native editor has consumed this edit's caret. Do not
                    // replay it during a later hosting update after the user
                    // has selected another range.
                    if model.selectionRequest == caret { model.selectionRequest = nil }
                }
            }
            if let historyCaret {
                model.clearNavigationBlockSelection(clearTextSelections:true)
                model.requestHistoryCaret(historyCaret,base:base)
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
@MainActor protocol ComparisonContextMenuProviding {
    func comparisonContextMenu(defaults: UserDefaults, pasteboard: NSPasteboard) -> NSMenu
}
private final class FileComparisonTextView: NSTextView, NSMenuDelegate, ComparisonContextMenuProviding, MergeLineNavigationProviding, MergeWhitespaceDisplaying, MergeFindProviding, MergeLineDiffHoverProviding, MergeInlineNavigationProviding, MergeBlockSelecting, MergeTypingProviding, MergeMarginSelecting {
    var marginSelectionAllowed: Bool { navigationAllowed && window?.attachedSheet == nil }
    var marginSelectionStamp: MergeMarginStamp { .init(values:[model?.alignmentGeneration ?? -1,model?.folding.revision ?? -1,navigationIntentRevision],text:string) }
    func beginMarginSelection() { beginUserNavigation();model?.activatePane(base:baseSide) }
    func selectMargin(rows:Range<Int>,selection:NSRange,caret:Int) { model?.selectMargin(rows:rows,selection:selection,caret:caret,base:baseSide) }
    func expandMarginFold(row:Int) -> Bool {
        guard marginSelectionAllowed,let controller = foldLayout.controller,let screen = controller.projection.screenRow(containing:row) else { return false }
        return controller.expand(screenRow:screen)
    }
    var chooseNavigationLine: (NSWindow, Int) async -> Int? = MergeLineNumberPrompt.choose
    var navigationPending = false
    var navigationCells: [MergeSourceCell]? { sourceCells }
    var navigationAllowed: Bool { model?.contextCommandsAllowed == true && model?.filtering == false }
    private(set) var navigationIntentRevision = 0
    func invalidateNavigationRevision() { navigationIntentRevision &+= 1 }
    func beginUserNavigation() { model?.lineWrapping.prepareForInput(); invalidateNavigationRevision(); model?.cancelDeferredNavigation() }
    override func scrollWheel(with event: NSEvent) { beginUserNavigation(); model?.lineWrapping.beginViewportInput(); defer { model?.lineWrapping.endViewportInput() }; super.scrollWheel(with:event) }
    func didNavigateViewport() { model?.lineWrapping.recordViewportIntent() }
    @objc func goToSourceLine(_ sender: Any?) { navigateToSourceLine() }
    @objc private func expandFoldedSection(_ sender: Any?) { _ = foldLayout.expandSelection(in: self) }
    private func inlineTarget(forward: Bool) -> Int? {
        guard let model, window != nil, window?.attachedSheet == nil, model.contextCommandsAllowed,
              !model.onePaneActive, !model.filtering, model.showInlineDiff else { return nil }
        let caret = selectedRange().location
        var start = 0
        for (row, cell) in sourceCells.enumerated() {
            let length = cell.displayText.utf16.count
            if caret <= start + length {
                return model.inlineNavigationDifference(row)?.navigationOffset(from: caret - start, base: baseSide, forward: forward).map { start + $0 }
            }
            start += length + 1
        }
        return nil
    }
    func canNavigateInline(forward: Bool) -> Bool { inlineTarget(forward: forward) != nil }
    func navigateInline(forward: Bool) {
        // Automatic block-entry advancement must not cancel its own selection.
        if model?.selectingDifferenceBlock != true { beginUserNavigation() }
        guard let target = inlineTarget(forward: forward) else { return }
        model?.selectionRequest = nil
        blockSelection.moveCaret(target,in:self); scrollRangeToVisible(selectedRange())
    }
    @objc private func nextInlineDifference(_ sender: Any?) { navigateInline(forward: true) }
    @objc private func previousInlineDifference(_ sender: Any?) { navigateInline(forward: false) }

    @objc private func nextDifferenceBlock(_ sender: Any?) { model?.navigate(1) }
    @objc private func previousDifferenceBlock(_ sender: Any?) { model?.navigate(-1) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 125 || event.keyCode == 126,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .control {
            model?.navigate(event.keyCode == 125 ? 1 : -1); return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if (event.keyCode == 98 || event.keyCode == 103), modifiers.isEmpty || modifiers == .shift || event.keyCode == 103 && modifiers == .control {
            model?.navigate(modifiers.isEmpty ? 1 : -1); return true
        }
        if modifiers == .option, event.keyCode == 125 || event.keyCode == 126 {
            model?.navigate(event.keyCode == 125 ? 1 : -1); return true
        }
        if modifiers == .control, event.charactersIgnoringModifiers?.lowercased() == "g" {
            goToSourceLine(nil); return true
        }
        if modifiers == [.control, .option], event.keyCode == 123 || event.keyCode == 124 {
            navigateInline(forward: event.keyCode == 124); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    var mergeOverwrite:Bool { model?.overwriteModes[baseSide] == true }
    var mergeTypingAllowed:Bool { isEditable && model?.contextCommandsAllowed == true && model?.canTransfer(toBase:baseSide) == true }
    func toggleMergeOverwrite() { guard mergeTypingAllowed else {return};model?.overwriteModes[baseSide] = !mergeOverwrite;needsDisplay = true }
    private var currentEndingEdit:FileComparisonLineEndingEdit? {
        guard mergeTypingAllowed,let model,let alignment = model.alignment,let row = MergeTyping.displayRow(in:string,offset:selectedRange().location) else {return nil}
        return FileComparisonLineEndingEdit(alignment:alignment,combined:model.onePaneActive ? model.combined : nil,base:baseSide,row:row)
    }
    var canCycleCurrentEnding:Bool {
        guard mergeTypingAllowed,let row = MergeTyping.displayRow(in:string,offset:selectedRange().location),sourceCells.indices.contains(row),
              !sourceCells[row].state.isViewEmpty else {return false}
        return MergeTyping.cycledLine(sourceCells[row].text) != nil
    }
    func cycleCurrentEnding() {
        guard let edit = currentEndingEdit else {return}
        (delegate as? FileComparisonEditor.Coordinator)?.cycleEnding(edit,displayCaret:selectedRange().location)
    }
    override func drawInsertionPoint(in rect:NSRect,color:NSColor,turnedOn flag:Bool) {
        if mergeOverwrite,mergeTypingAllowed {MergeTypingCaret.draw(in:self,rect:rect,color:color,on:flag)}
        else {super.drawInsertionPoint(in:rect,color:color,turnedOn:flag)}
    }
    override func insertText(_ insertString:Any,replacementRange:NSRange) {
        var range = replacementRange
        let payload = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        if mergeOverwrite,mergeTypingAllowed,!hasMarkedText(),range.location == NSNotFound,let payload {
            range = MergeTyping.overwriteRange(in:string,range:selectedRange(),inserted:payload)
        }
        super.insertText(insertString,replacementRange:range)
    }
    var history: UndoManager?
    weak var model: FileComparisonWindowModel?
    var baseSide = false
    var sourceCells: [MergeSourceCell] = []
    var blockGeneration = -1
    let blockSelection = MergeBlockSelection()
    var mergeSelectedBlockRange: NSRange? { blockSelection.range(in:self) }
    var mergeBlockBoundaryRects: [NSRect] { blockSelection.boundaryRects(in:self) }
    let foldLayout = MergeFoldTextLayout()
    override func scrollRangeToVisible(_ range: NSRange) {
        if model?.selectingDifferenceBlock != true { foldLayout.reveal(selection: range, in: self, includeMarker: true) }
        super.scrollRangeToVisible(range)
    }
    private var lineDiffTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let lineDiffTracking { removeTrackingArea(lineDiffTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); lineDiffTracking = area
        super.updateTrackingAreas()
    }
    func previewLine(atDisplayOffset offset: Int?) {
        guard let offset, offset >= 0 else { model?.previewLine(atRow: nil); return }
        var start = 0
        for (index, cell) in sourceCells.enumerated() {
            let end = start + cell.displayText.utf16.count + 1
            if offset < end { model?.previewLine(atRow: index); return }
            start = end
        }
        model?.previewLine(atRow: nil)
    }
    override func mouseMoved(with event: NSEvent) {
        guard let layoutManager, let textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let used = layoutManager.usedRect(for: textContainer)
        guard local.y >= used.minY, local.y < used.maxY else { previewLine(atDisplayOffset: nil); return }
        let offset = layoutManager.characterIndex(for: local, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        previewLine(atDisplayOffset: offset)
    }
    override func mouseExited(with event: NSEvent) { previewLine(atDisplayOffset: nil) }

    let mergeFindHighlights = MergeFindHighlights()
    var mergeFindController: MergeFindWindowController?
    var mergeFindDefaults: UserDefaults { model?.comparisonDefaults ?? .standard }
    var mergeFindPaneID: Int { baseSide ? 1 : 2 }
    var mergeFindAllowed: Bool { window != nil && !navigationPending && model?.contextCommandsAllowed == true && model?.filtering == false }
    var mergeFindWritable: Bool { mergeFindAllowed && isEditable }
    var mergeFindLines: [MergeFindLine] { MergeFindLine.displayCells(sourceCells) }
    func replaceFindMatches(_ ranges: [NSRange], with replacement: String) -> Bool {
        guard mergeFindWritable else { return false }
        return model?.replaceFindMatches(ranges, cells: sourceCells, base: baseSide, replacement: replacement) == true
    }
    let whitespaceRenderer = MergeWhitespaceRenderer()
    var missingOffsets: [Int] = []
    func menuDidClose(_ menu: NSMenu) {
        guard let model, model.activeBase == baseSide, !model.busy, !model.confirmingQuit,
              let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(self)
        setAccessibilityFocused(true)
    }
    override func keyDown(with event: NSEvent) { beginUserNavigation(); model?.lineWrapping.beginViewportInput(); defer { model?.lineWrapping.endViewportInput() }; model?.clearNavigationBlockSelection(); super.keyDown(with:event) }
    override func mouseDown(with event: NSEvent) {
        beginUserNavigation(); model?.lineWrapping.beginViewportInput(); defer { model?.lineWrapping.endViewportInput() }
        model?.clearNavigationBlockSelection()
        model?.activatePane(base: baseSide)
        if MergeMarkedWordInterface.mouse(event, in: self) { window?.makeFirstResponder(self); return }
        if model?.contextCommandsAllowed == true, foldLayout.expand(at: event, in: self) { return }
        super.mouseDown(with: event)
    }
    @objc(undo:) func undoComparison(_ sender: Any?) { model?.undo() }
    @objc(redo:) func redoComparison(_ sender: Any?) { model?.redo() }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == NSSelectorFromString("undo:") { return model?.canUndo == true && model?.busy == false && model?.confirmingQuit == false }
        if item.action == NSSelectorFromString("redo:") { return model?.canRedo == true && model?.busy == false && model?.confirmingQuit == false }
        if item.action == NSSelectorFromString("copy:") { return !(clipboardText ?? "").isEmpty }
        if item.action == NSSelectorFromString("cut:") { return isEditable && model?.canTransfer(toBase: baseSide) == true && !(clipboardText ?? "").isEmpty }
        if item.action == #selector(goToSourceLine(_:)) { return canNavigateToSourceLine }
        return super.validateMenuItem(item)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { model?.activatePane(base: baseSide) }
        return accepted
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        whitespaceRenderer.draw(in: self, dirtyRect: dirtyRect)
        MergeInlineTicks.draw(in: self, offsets: missingOffsets, dirtyRect: dirtyRect)
        foldLayout.draw(in: self, dirtyRect: dirtyRect)
        blockSelection.draw(in:self,dirtyRect:dirtyRect)
    }

    override var undoManager: UndoManager? { history ?? super.undoManager }
    override func insertTab(_ sender: Any?) { indent(remove: false) }
    override func insertBacktab(_ sender: Any?) { indent(remove: true) }
    private func indent(remove: Bool) {
        guard isEditable, let model, let selection = model.indent(selectedRange(), cells: sourceCells, base: baseSide, remove: remove) else { return }
        let start = FileComparisonEditing.displayOffset(sourceOffset: selection.location, cells: sourceCells)
        let end = FileComparisonEditing.displayOffset(sourceOffset: NSMaxRange(selection), cells: sourceCells)
        setSelectedRange(NSRange(location: start, length: max(0, end - start)))
    }
    override func copy(_ sender: Any?) { copySelection(to: .general) }
    override func cut(_ sender: Any?) { cutSelection(to: .general) }
    fileprivate func cutSelection(to pasteboard: NSPasteboard) {
        guard window != nil, isEditable, model?.contextCommandsAllowed == true,
              model?.canTransfer(toBase: baseSide) == true, copySelection(to: pasteboard) else { return }
        if selectedRange().length > 0 { insertText("", replacementRange: selectedRange()) }
    }
    fileprivate var clipboardText: String? {
        guard let model, model.copyCommandsAllowed, window != nil else { return nil }
        let rows = mergeSelectedBlockRange.flatMap { MergeBlockSelection.rows($0,cells:sourceCells) }
        return try? MergeClipboard.sourceText(selection:selectedRange(),cells:sourceCells,blockRows:rows)
    }
    @discardableResult fileprivate func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard model?.copyCommandsAllowed == true, let text = clipboardText, !text.isEmpty else { return false }
        pasteboard.clearContents(); return pasteboard.setString(text, forType: .string)
    }
    func selectContextBlock(at displayOffset: Int) {
        beginUserNavigation()
        window?.makeFirstResponder(self)
        let selected = selectedRange()
        if selected.length > 0, NSLocationInRange(displayOffset,selected) { return }
        if let block = mergeSelectedBlockRange, displayOffset >= block.location, displayOffset <= NSMaxRange(block) { return }
        model?.selectContextBlock(at:displayOffset,base:baseSide)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard model != nil else { return super.menu(for:event) }
        selectContextBlock(at:characterIndexForInsertion(at:convert(event.locationInWindow,from:nil)))
        return comparisonContextMenu(defaults:.standard,pasteboard:.general)
    }
    func comparisonContextMenu(defaults: UserDefaults, pasteboard: NSPasteboard) -> NSMenu {
        guard let model else { return NSMenu() }
        model.updateSelection(selectedRange(), cells: sourceCells)
        let menu = ComparisonClipboardMenu(); menu.autoenablesItems = false; menu.delegate = self
        let clipboard = ComparisonClipboardCommands(view: self, pasteboard: pasteboard); menu.clipboard = clipboard
        func add(_ title: String, _ action: Selector, _ icon: NSImage?, _ enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.image = MenuPresentationSettings.applicationContextIcons(defaults: defaults) ? icon : nil; item.isEnabled = enabled; menu.addItem(item)
        }
        let caretRow = MergeLineEndings.lineRanges(in:string).lastIndex { $0.location <= selectedRange().location }
        if let caretRow, let link = model.movedRowLinks(base:baseSide)[caretRow] {
            add("Go to moved block", #selector(goToMovedBlock(_:)), MenuIcon.mergeMoved.image(), model.contextCommandsAllowed && !model.filtering)
            menu.items.last?.representedObject = [caretRow,model.alignmentGeneration]
            menu.items.last?.toolTip = link.tooltip
            menu.addItem(.separator())
        }
        if model.folding.collapsed {
            add("Expand unchanged section", #selector(expandFoldedSection(_:)), NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand"), model.contextCommandsAllowed && foldLayout.canExpandSelection(in: self))
            menu.addItem(.separator())
        }
        let displayLeft = baseSide || model.onePaneActive
        let block = model.oppositeViewCommandsAllowed && model.canTransfer(toBase: false) && model.transferRows != nil
        add(displayLeft ? "Use this block" : "Use other block", #selector(useBlock), MenuIcon.mergeUseTheirs.image(), block)
        add("Use both blocks, this one first", #selector(useThisFirst), MenuIcon.mergeMineThenTheirs.image(), block)
        add("Use both blocks, this one last", #selector(useThisLast), MenuIcon.mergeTheirsThenMine.image(), block)
        if !model.onePaneActive && model.canTransfer(toBase: true) {
            menu.addItem(.separator())
            let leftBlock = model.transferRows != nil
            add(baseSide ? "Prepend right block" : "Prepend this block to left", #selector(prependRight), MenuIcon.mergeTheirsThenMine.image(), leftBlock)
            add(baseSide ? "Use right block" : "Use this block on left", #selector(replaceByRight), MenuIcon.mergeUseTheirs.image(), leftBlock)
            add(baseSide ? "Append right block" : "Append this block to left", #selector(appendRight), MenuIcon.mergeMineThenTheirs.image(), leftBlock)
        }
        if !baseSide && !model.onePaneActive {
            menu.addItem(.separator())
            if let rows = model.transferRows {
                let marks = model.annotations(base: false).marked
                if rows.count > 1 || !marks.contains(rows.lowerBound) { add("Mark block", #selector(markBlock), MenuIcon.mergeMarked.image(), block) }
                if rows.count > 1 || marks.contains(rows.lowerBound) { add("Unmark block", #selector(unmarkBlock), MenuIcon.mergeMarked.image(), block) }
            }
            add("Leave only marked blocks", #selector(leaveOnlyMarked), MenuIcon.mergeMarked.image(), model.canTransfer(toBase: false))
        }
        add(displayLeft ? "Use this whole file" : "Use other file", #selector(useFile), MenuIcon.mergeUseTheirs.image(), model.oppositeViewCommandsAllowed && model.canTransfer(toBase: false))
        if model.canTransfer(toBase: true) {
            add(baseSide ? "Use other file" : "Use this whole file", #selector(useRightFile), MenuIcon.mergeUseTheirs.image(), true)
        }
        func clipboardItems() {
            menu.addItem(.separator())
            add("Copy", #selector(ComparisonClipboardCommands.copySelection(_:)), MenuIcon.copy.image(), model.copyCommandsAllowed && !(clipboardText ?? "").isEmpty)
            menu.items.last?.target = clipboard; menu.items.last?.representedObject = clipboard
            if !model.onePaneActive || isEditable && model.canTransfer(toBase: baseSide) {
                add("Cut", #selector(ComparisonClipboardCommands.cutSelection(_:)), NSImage(systemSymbolName: "scissors", accessibilityDescription: nil), isEditable && model.canTransfer(toBase: baseSide) && !(clipboardText ?? "").isEmpty)
                menu.items.last?.target = clipboard; menu.items.last?.representedObject = clipboard
                add("Paste", #selector(ComparisonClipboardCommands.pasteSelection(_:)), MenuIcon.mergePaste.image(), isEditable && model.canTransfer(toBase: baseSide) && pasteboard.availableType(from: [.string]) != nil)
                menu.items.last?.target = clipboard; menu.items.last?.representedObject = clipboard
            }
        }
        if model.onePaneActive { clipboardItems() }
        if model.canTransfer(toBase: baseSide) {
            menu.addItem(.separator())
            let text = model.draftText(base: baseSide), width = model.tabWidth(base: baseSide)
            for (index, command) in MergeWhitespaceCommand.allCases.enumerated() {
                let item = NSMenuItem(title: command.rawValue, action: #selector(changeWhitespace(_:)), keyEquivalent: "")
                item.target = self; item.tag = index
                item.isEnabled = MergeWhitespace.canApply(command, to: text, tabWidth: width)
                menu.addItem(item)
            }
            let endings = NSMenu(title: "End of Line Style"); endings.autoenablesItems = false
            let styles = MergeLineEndings.styles(in: text)
            for (index, ending) in MergeLineEnding.allCases.enumerated() {
                let item = NSMenuItem(title: ending.menuTitle, action: #selector(changeLineEnding(_:)), keyEquivalent: "")
                item.target = self; item.tag = index; item.state = styles == [ending] ? .on : .off
                endings.addItem(item)
            }
            let item = NSMenuItem(title: "End of Line Style", action: nil, keyEquivalent: "")
            item.submenu = endings; menu.addItem(item)
            let encodings = NSMenu(title: "File Encoding"); encodings.autoenablesItems = false
            for (index, encoding) in (model.onePaneActive ? MergeFormatSelection.encodings : ComparisonTextEncoding.allCases).enumerated() {
                let choice = NSMenuItem(title: encoding.rawValue, action: #selector(changeEncoding(_:)), keyEquivalent: "")
                choice.target = self; choice.tag = index; choice.representedObject = encoding.rawValue; choice.state = model.encoding(base: baseSide) == encoding ? .on : .off
                encodings.addItem(choice)
            }
            let encodingItem = NSMenuItem(title: "File Encoding", action: nil, keyEquivalent: "")
            encodingItem.submenu = encodings; menu.addItem(encodingItem)

        }
        menu.addItem(.separator())
        add("Previous difference", #selector(previousDifferenceBlock(_:)), MenuIcon.mergePreviousDifference.image(), model.canNavigateDifference(-1))
        add("Next difference", #selector(nextDifferenceBlock(_:)), MenuIcon.mergeNextDifference.image(), model.canNavigateDifference(1))
        add("Find…", #selector(turtleShowMergeFind(_:)), MenuIcon.mergeFind.image(), model.contextCommandsAllowed)
        MergeFindInterface.appendSelectionCommands(to: menu, text: self, defaults: defaults)
        add("Next inline difference", #selector(nextInlineDifference(_:)), MenuIcon.mergeNextInline.image(), canNavigateInline(forward: true))
        add("Previous inline difference", #selector(previousInlineDifference(_:)), MenuIcon.mergePreviousInline.image(), canNavigateInline(forward: false))
        add("Go to Line…", #selector(goToSourceLine(_:)), NSImage(systemSymbolName: "number", accessibilityDescription: "Go to Line"), canNavigateToSourceLine)
        menu.items.last?.keyEquivalent = "g"; menu.items.last?.keyEquivalentModifierMask = .control
        add("Save As…", #selector(exportPane), MenuIcon.mergeSaveAs.image(), model.canSavePaneAs)
        add("Undo", #selector(undoEdit), MenuIcon.mergeUndo.image(), model.canUndo && !model.busy && !model.confirmingQuit)
        add("Redo", #selector(redoEdit), MenuIcon.mergeRedo.image(), model.canRedo && !model.busy && !model.confirmingQuit)
        if !model.onePaneActive { clipboardItems() }
        return menu
    }
    @objc private func goToMovedBlock(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? [Int],target.count == 2 else { return }
        model?.followMovedBlock(row:target[0],base:baseSide,generation:target[1])
    }
    @objc private func useBlock() { model?.useOtherBlock(targetBase: false) }
    @objc private func useThisFirst() { model?.useOtherBlock(baseSide ? .otherThenCurrent : .currentThenOther, targetBase: false) }
    @objc private func useThisLast() { model?.useOtherBlock(baseSide ? .currentThenOther : .otherThenCurrent, targetBase: false) }
    @objc private func useFile() { model?.useOtherFile(targetBase: false) }
    @objc private func prependRight() { model?.useOtherBlock(.otherThenCurrent, targetBase: true) }
    @objc private func replaceByRight() { model?.useOtherBlock(targetBase: true) }
    @objc private func appendRight() { model?.useOtherBlock(.currentThenOther, targetBase: true) }
    @objc private func useRightFile() { model?.useOtherFile(targetBase: true) }
    @objc private func changeEncoding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let encoding = ComparisonTextEncoding(rawValue: raw) else { return }
        model?.changeEncoding(encoding, base: baseSide)
    }
    @objc private func changeWhitespace(_ sender: NSMenuItem) {
        guard MergeWhitespaceCommand.allCases.indices.contains(sender.tag) else { return }
        model?.changeWhitespace(MergeWhitespaceCommand.allCases[sender.tag], base: baseSide)
    }
    @objc private func changeLineEnding(_ sender: NSMenuItem) {
        guard MergeLineEnding.allCases.indices.contains(sender.tag) else { return }
        model?.changeLineEnding(MergeLineEnding.allCases[sender.tag], base: baseSide)
    }
    @objc private func markBlock() { model?.markBlock(true, targetBase: false) }
    @objc private func unmarkBlock() { model?.markBlock(false, targetBase: false) }
    @objc private func leaveOnlyMarked() { model?.leaveOnlyMarked(targetBase: false) }
    @objc private func exportPane() { model?.saveAs(base: baseSide) }
    @objc private func undoEdit() { model?.undo() }
    @objc private func redoEdit() { model?.redo() }

}

@MainActor private final class ComparisonClipboardMenu: NSMenu {
    var clipboard: ComparisonClipboardCommands?
}
@MainActor private final class ComparisonClipboardCommands: NSObject {
    private weak var view: FileComparisonTextView?
    private let pasteboard: NSPasteboard
    init(view: FileComparisonTextView, pasteboard: NSPasteboard) { self.view = view; self.pasteboard = pasteboard }
    @objc func copySelection(_ sender: Any?) { view?.copySelection(to: pasteboard) }
    @objc func cutSelection(_ sender: Any?) { view?.cutSelection(to: pasteboard) }
    @objc func pasteSelection(_ sender: Any?) {
        guard let view, view.window != nil, view.isEditable, view.model?.contextCommandsAllowed == true,
              view.model?.canTransfer(toBase: view.baseSide) == true, let text = pasteboard.string(forType: .string) else { return }
        view.insertText(text, replacementRange: view.selectedRange())
    }
}

/// Native IDD_GOTO: a permanent range label, initially empty numeric input,
/// inline validation and source OK/Cancel order, owned by the invoking editor.
@MainActor final class MergeLineNumberPrompt: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let field = NSTextField(), label = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let limit: Int
    private var ownerObserver: NSObjectProtocol?
    private var completion: ((Int?) -> Void)?
    private var finished = false
    init(limit: Int) {
        self.limit = limit
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 156), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Go To Line"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        label.stringValue = "Line number (1 – \(limit))"; field.setAccessibilityLabel(label.stringValue)
        (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true; (field.cell as? NSTextFieldCell)?.isScrollable = true
        field.delegate = self; field.widthAnchor.constraint(equalToConstant: 308).isActive = true
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"; ok.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [ok, cancel]); buttons.spacing = 10
        let footer = NSView(); footer.widthAnchor.constraint(equalToConstant: 308).isActive = true; footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        footer.addSubview(buttons); buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor), buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor)])
        status.textColor = .systemRed; status.isSelectable = true; status.maximumNumberOfLines = 2
        status.heightAnchor.constraint(equalToConstant: 30).isActive = true; status.widthAnchor.constraint(equalToConstant: 308).isActive = true
        status.setAccessibilityLabel("Line number validation")
        let stack = NSStackView(views: [label, field, status, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let host = NSView(); window.contentView = host; host.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 14), stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16)])
        window.initialFirstResponder = field
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    static func validated(_ input: String, limit: Int) -> Int? {
        guard !input.isEmpty, input.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(input), (1...max(1, limit)).contains(value), limit > 1 else { return nil }
        return value
    }
    func controlTextDidChange(_ notification: Notification) {
        guard !finished else { return }
        ok.isEnabled = Self.validated(field.stringValue, limit: limit) != nil
        status.stringValue = field.stringValue.isEmpty || ok.isEnabled ? "" : "Enter a whole number from 1 to \(limit)."
    }
    @objc func accept() {
        guard !finished else { return }
        guard let value = Self.validated(field.stringValue, limit: limit) else {
            status.stringValue = "Enter a whole number from 1 to \(limit)."; field.selectText(nil); return
        }
        finish(value)
    }
    private func finish(_ value: Int?, closing: Bool = false) {
        guard !finished else { return }; finished = true
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver); self.ownerObserver = nil }
        if let window, let parent = window.sheetParent { parent.endSheet(window); window.orderOut(nil) }
        ok.isEnabled = false; field.isEnabled = false; field.delegate = nil
        let callback = completion; completion = nil; if !closing { close() }; callback?(value)
    }
    func present(owner: NSWindow, completion: @escaping (Int?) -> Void) {
        guard !finished, self.completion == nil, owner.attachedSheet == nil, let window else { completion(nil); return }
        self.completion = completion
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.finish(nil) } }
        owner.beginSheet(window); window.makeFirstResponder(field)
    }
    func windowWillClose(_ notification: Notification) { finish(nil, closing: true) }
    @objc private func cancelClicked() { finish(nil) }
    static func choose(window: NSWindow, limit: Int) async -> Int? {
        let prompt = MergeLineNumberPrompt(limit: limit)
        let result: Int? = await withCheckedContinuation { continuation in prompt.present(owner: window) { continuation.resume(returning: $0) } }
        withExtendedLifetime(prompt) {}; return result
    }
}
@MainActor enum MergeNavigationRequests { static var activeRequests = 0 }
@MainActor protocol MergeLineNavigationProviding: AnyObject {
    var chooseNavigationLine: (NSWindow, Int) async -> Int? { get set }
    var navigationPending: Bool { get set }
    var navigationCells: [MergeSourceCell]? { get }
    var navigationAllowed: Bool { get }
    var navigationIntentRevision: Int { get }
    func beginUserNavigation()
    func didNavigateViewport()
}
extension MergeLineNavigationProviding where Self: NSTextView {
    var navigationIntentRevision: Int { 0 }
    func beginUserNavigation() {}
    func didNavigateViewport() {}
    var navigationLimit: Int? {
        if let cells = navigationCells { return MergeSourceComparison.navigationLimit(cells: cells) }
        let count = MergeSourceComparison.navigationRanges(text: string).count
        return count > 1 ? count : nil
    }
    var canNavigateToSourceLine: Bool {
        navigationAllowed && !navigationPending && window?.attachedSheet == nil && navigationLimit != nil
    }
    func navigateToSourceLine() {
        guard canNavigateToSourceLine, let window, let limit = navigationLimit else { return }
        beginUserNavigation()
        let original = string, revision = navigationIntentRevision
        navigationPending = true; MergeNavigationRequests.activeRequests += 1
        Task { @MainActor in
            defer { navigationPending = false; MergeNavigationRequests.activeRequests -= 1 }
            guard let line = await chooseNavigationLine(window, limit), line >= 1, line <= limit,
                  navigationAllowed, window.attachedSheet == nil, self.window === window,
                  navigationIntentRevision == revision, string.utf8.elementsEqual(original.utf8) else { return }
            let range: NSRange?
            if let cells = navigationCells { range = MergeSourceComparison.navigationRange(line: line, cells: cells) }
            else { range = MergeSourceComparison.navigationRanges(text: string)[line - 1] }
            guard let range, NSMaxRange(range) <= (string as NSString).length else { return }
            window.makeFirstResponder(self); setSelectedRange(range); scrollRangeToVisible(range); didNavigateViewport()
        }
    }
}

/// Native IDD_ENCODING, adapted from EncodingDlg (TortoiseGit 2023, 2026;
/// TortoiseSVN 2013, 2020), GPL-2.0-or-later. Pane/Encoding/EOL and OK/Cancel
/// retain source order while macOS owns the sheet and cancellation lifecycle.
@MainActor final class MergeFormatPrompt: NSWindowController, NSWindowDelegate {
    static private(set) var activeDialogs = 0
    let encoding = NSPopUpButton(), ending = NSPopUpButton()
    let paneLabel = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let endings: [MergeLineEnding?] = [nil,.crlf,.lf,.cr,.lfcr,.verticalTab,.formFeed,.nextLine,.lineSeparator,.paragraphSeparator]
    private let initial: MergeFormatSelection
    private var completion: ((MergeFormatSelection?) -> Void)?
    private var ownerObserver: NSObjectProtocol?
    private var finished = false, registered = false
    init(pane: String, selection: MergeFormatSelection) {
        initial = selection
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 216), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = pane + " Encoding"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        paneLabel.stringValue = pane; paneLabel.isSelectable = true; paneLabel.setAccessibilityLabel("Encoding pane")
        encoding.addItems(withTitles: MergeFormatSelection.encodings.map(\.rawValue))
        encoding.selectItem(at: MergeFormatSelection.encodings.firstIndex(of: selection.encoding) ?? 7)
        ending.addItems(withTitles: endings.map { $0?.menuTitle ?? "Auto" })
        ending.selectItem(at: endings.firstIndex(where: { $0 == selection.ending }) ?? 0)
        encoding.widthAnchor.constraint(equalToConstant: 300).isActive = true
        encoding.setAccessibilityLabel(pane + " encoding"); ending.setAccessibilityLabel(pane + " line endings")
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Encoding"), encoding], [NSTextField(labelWithString: "EOL"), ending]])
        grid.columnSpacing = 14; grid.rowSpacing = 10
        ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [ok, cancel]); buttons.spacing = 10
        let footer = NSView(); footer.widthAnchor.constraint(equalToConstant: 408).isActive = true; footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        footer.addSubview(buttons); buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor), buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor)])
        status.isSelectable = true; status.maximumNumberOfLines = 2; status.textColor = .systemRed
        status.setAccessibilityLabel("Encoding validation"); status.widthAnchor.constraint(equalToConstant: 408).isActive = true; status.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let stack = NSStackView(views: [paneLabel, grid, status, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        let host = NSView(); window.contentView = host; host.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16), stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 14)])
        window.initialFirstResponder = encoding
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    private var validatedSelection: MergeFormatSelection? {
        guard MergeFormatSelection.encodings.indices.contains(encoding.indexOfSelectedItem), endings.indices.contains(ending.indexOfSelectedItem) else { return nil }
        return .init(encoding: MergeFormatSelection.encodings[encoding.indexOfSelectedItem], ending: endings[ending.indexOfSelectedItem])
    }
    var selection: MergeFormatSelection { validatedSelection ?? initial }
    @objc func accept() {
        guard !finished else { return }
        guard let choice = validatedSelection else { status.stringValue = "Choose an encoding and a line ending."; return }
        finish(choice)
    }
    func cancel() { finish(nil) }
    private func finish(_ value: MergeFormatSelection?, closing: Bool = false) {
        guard !finished else { return }; finished = true
        if registered { registered = false; Self.activeDialogs -= 1 }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver); self.ownerObserver = nil }
        if let window, let parent = window.sheetParent { parent.endSheet(window, returnCode: value == nil ? .cancel : .OK); window.orderOut(nil) }
        encoding.isEnabled = false; ending.isEnabled = false; ok.isEnabled = false
        let callback = completion; completion = nil; if !closing { close() }; callback?(value)
    }
    func present(owner: NSWindow, completion: @escaping (MergeFormatSelection?) -> Void) {
        guard !finished, self.completion == nil else { completion(nil); return }
        guard owner.attachedSheet == nil, let window else { completion(nil); cancel(); return }
        self.completion = completion; registered = true; Self.activeDialogs += 1
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        owner.beginSheet(window) { [weak self] response in
            guard let self, !self.finished else { return }
            if response == .OK || response == .alertFirstButtonReturn { self.accept() } else { self.cancel() }
        }
        window.makeFirstResponder(encoding)
    }
    func windowWillClose(_ notification: Notification) { finish(nil, closing: true) }
    @objc private func cancelClicked() { cancel() }
    static func choose(window: NSWindow, pane: String, selection: MergeFormatSelection) async -> MergeFormatSelection? {
        await MergeFormatPrompt(pane: pane, selection: selection).choose(window: window)
    }
    func choose(window: NSWindow) async -> MergeFormatSelection? {
        let result: MergeFormatSelection? = await withCheckedContinuation { continuation in present(owner: window) { continuation.resume(returning: $0) } }
        withExtendedLifetime(self) {}; return result
    }
}

@MainActor protocol MergeLineDiffHoverProviding {
    func previewLine(atDisplayOffset offset: Int?)
}

private struct MergeLineDiffBar: NSViewRepresentable {
    @ObservedObject var model: FileComparisonWindowModel
    func makeNSView(context: Context) -> MergeLineDiffPreview { MergeLineDiffPreview() }
    func updateNSView(_ view: MergeLineDiffPreview, context: Context) { view.update(model) }
}

/// Two TextKit lines, without additional editors, selection or focus ownership.
@MainActor final class MergeLineDiffPreview: NSView {
    private struct Line {
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        let renderer: MergeWhitespaceRenderer
        let font: NSFont
        let background: NSColor
        let missing: [Int]
        let horizontalOffset: CGFloat
    }
    private var lines: [Line] = []
    private(set) var displayedStrings: [String] = []
    var displayedAttributes: [NSAttributedString] { lines.map { NSAttributedString(attributedString: $0.storage) } }
    var displayedMarkers: [[MergeWhitespaceMarker]] { lines.map { $0.renderer.markers } }
    var horizontalOffsets: [CGFloat] { lines.map(\.horizontalOffset) }
    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) + 4 }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel("Line diff bar, Base above Mine")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ model: FileComparisonWindowModel) {
        lines = []; displayedStrings = []
        guard let row = model.lineDiffRow, let index = model.previewRow else {
            setAccessibilityValue("No line under pointer"); needsDisplay = true; return
        }
        let pairedDiff = model.inlineDifference(index, force: true)
        let font = model.generalPreferences.nativeFont
        for base in [true, false] {
            let cell = base ? row.base : row.destination, other = base ? row.destination : row.base
            let diff = cell.displayText.utf16.count <= model.generalPreferences.maximumInlineLength ? pairedDiff : nil
            let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
            paragraph.defaultTabInterval = CGFloat(model.tabWidth(base: base)) * (" " as NSString).size(withAttributes: [.font: font]).width
            let background = diff == nil ? MergePalette.color(cell.state) : MergePalette.inlineCommon
            let storage = NSTextStorage(string: cell.displayText + "\n", attributes: [.font: font, .foregroundColor: MergePalette.foreground(cell.state), .backgroundColor: background, .paragraphStyle: paragraph])
            if let diff {
                for range in base ? diff.base : diff.destination {
                    storage.addAttribute(.backgroundColor, value: base ? MergePalette.inlineRemoved : MergePalette.inlineAdded, range: range)
                }
            }
            let layout = NSLayoutManager(), container = NSTextContainer(containerSize: NSSize(width: 10_000_000, height: Self.lineHeight(font)))
            container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout)
            let renderer = MergeWhitespaceRenderer(); renderer.removal = base; renderer.highlightEndings = true
            renderer.update(text: storage.string, cells: [cell], otherCells: [other], preferences: .init(visible: true, endingIcons: model.whitespaceDisplay.endingIcons))
            lines.append(Line(storage: storage, layout: layout, container: container, renderer: renderer, font: font, background: background,
                              missing: (base ? diff?.baseMissing : diff?.destinationMissing) ?? [], horizontalOffset: model.previewHorizontalOffsets[base] ?? 0))
            displayedStrings.append(cell.displayText)
        }
        setAccessibilityValue("Base: " + displayedStrings[0] + "\nMine: " + displayedStrings[1]); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        MergePalette.color(.normal).setFill(); bounds.fill()
        for (index, line) in lines.enumerated() {
            let height = Self.lineHeight(line.font)
            let rect = NSRect(x: 0, y: CGFloat(index) * height, width: bounds.width, height: height)
            guard rect.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState(); rect.clip()
            line.background.setFill(); rect.fill()
            let origin = NSPoint(x: 6 - line.horizontalOffset, y: rect.minY + 2)
            let glyphs = line.layout.glyphRange(for: line.container)
            line.layout.drawBackground(forGlyphRange: glyphs, at: origin)
            line.layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            line.renderer.draw(layout: line.layout, container: line.container, origin: origin, appearance: effectiveAppearance, font: line.font, textLength: line.storage.length, dirtyRect: rect.intersection(dirtyRect))
            MergePalette.inlineRemoved.setFill()
            for offset in line.missing where offset < line.storage.length {
                let glyph = line.layout.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
                let marker = line.layout.boundingRect(forGlyphRange: glyph, in: line.container).offsetBy(dx: origin.x, dy: origin.y)
                NSRect(x: marker.minX, y: marker.minY, width: 2, height: marker.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
