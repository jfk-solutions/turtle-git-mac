import AppKit
import UniformTypeIdentifiers
import SwiftUI
import TurtleGitCore

@MainActor class FileComparisonNativeWindow: NSWindow, ImageComparisonKeyRouting {
    weak var imageKeyModel: ImageComparisonViewModel?
    var imageKeyOwner: UUID?
    var imageKeysRetired = false
    weak var model: FileComparisonWindowModel?
    var openMergeDocument: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let imageKeyModel, !imageKeysRetired {
            if attachedSheet == nil, (firstResponder as? NSTextView)?.isFieldEditor != true,
               imageKeyModel.performKey(event, window: self) { return true }
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, event.charactersIgnoringModifiers?.lowercased() == "o" { openMergeDocument(); return true }
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
    private let editorFileMenu = MergeEditorFileMenu()
    private weak var patchMenu: NSMenu?
    private var patchMenuItem: NSMenuItem?
    func windowDidBecomeKey(_ notification: Notification) {
        editorFileMenu.install(target: self, open: #selector(openMergeDocument(_:)), reload: #selector(reloadEditor(_:)))
        removePatchMenu()
        guard let menu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else { return }
        let item = NSMenuItem(title: "Create patch file", action: #selector(createPatchFile(_:)), keyEquivalent: "")
        item.target = self; item.image = MenuIcon.patch.image(); menu.addItem(item)
        patchMenu = menu; patchMenuItem = item
    }
    func windowDidResignKey(_ notification: Notification) { removePatchMenu(); editorFileMenu.remove() }
    private func removePatchMenu() {
        if let item = patchMenuItem, let menu = patchMenu, menu.items.contains(item) { menu.removeItem(item) }
        patchMenuItem = nil; patchMenu = nil
    }
    func detachForReplacement() {
        editorFileMenu.remove(); removePatchMenu(); model.retireImageLoader(); model.resetHistory(); model.window = nil
    }
    @objc func createPatchFile(_ sender: Any?) { model.createUnifiedPatch() }
    @objc func reloadEditor(_ sender: Any?) {
        guard !preparingReplacement, editorOpenWorkflow == nil, window?.attachedSheet == nil else { return }; model.load()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
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
    convenience init(images: ImageFileComparison, permissions: [RepositoryAccessLease]) {
        self.init(model: FileComparisonWindowModel(images: images, permissions: permissions))
    }
    convenience init(comparison: WorkingFileComparison, permissions: [RepositoryAccessLease], preferences: UserDefaults = .standard) {
        let model = FileComparisonWindowModel(comparison: comparison, permissions: permissions)
        model.comparisonDefaults = preferences
        self.init(model: model)
    }
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, comparison: HistoricalWorkingFileComparison, permission: RepositoryAccessLease) {
        self.init(model: FileComparisonWindowModel(repository: repository, access: access, comparison: comparison, permission: permission))
    }
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, changeSets: CommitChangeSetComparison) {
        self.init(model: FileComparisonWindowModel(repository: repository, access: access, changeSets: changeSets))
    }
    private init(model: FileComparisonWindowModel) {
        self.model = model
        let path = model.path
        let window = TextConflictNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(path) – TurtleGitMerge"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: 440)
        window.contentViewController = NSHostingController(rootView: FileComparisonDialog(model: model))
        super.init(window: window); window.model = model; window.openMergeDocument = { [weak self] in self?.openMergeDocument(nil) }; window.delegate = self; model.window = window; model.installMarkedSavePrompt()
        model.externalDidOpen = { [weak window] in window?.close() }
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.center()

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
        editorFileMenu.remove(); removePatchMenu()
        if let window = window as? FileComparisonNativeWindow { window.imageKeyModel?.presentation.retire(); window.imageKeyModel?.stopAllPlayback(); window.imageKeysRetired = true; window.imageKeyModel = nil; window.imageKeyOwner = nil }
        editorOpenWorkflow?.retire(); editorOpenWorkflow = nil; model.retireImageLoader(); model.resetHistory(); onClosed()
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
    lazy var openExternalComparison: (FileComparisonDocument, URL, [RepositoryAccessLease], Bool) async throws -> Bool = { [weak self] document, root, permissions, alternate in
        guard let self, !self.retired else { throw OperationCancellationFailure.cancelled }
        return try await DiffToolApplication.open(document, root: root, permissions: permissions, alternate: alternate, preferences: self.comparisonDefaults, cancellation: self.loadSession?.cancellation)
    }
    func captureToolChoice(_ alternate: Bool) { guard !busy, !externalAttempted, !retired else { return }; alternateTool = alternate }
    @Published var document: FileComparisonDocument?
    var singleFileMode = false
    @Published var alignment: FileComparisonAlignment? { didSet { combinedCache = nil } }
    @Published private(set) var onePaneMode = false
    private var loadedPaneMode = false
    private var combinedCache: OnePaneFileComparison?
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
        if onePaneActive { unchanged = combined?.rows.map { $0.cell.state == .normal || $0.cell.state == .filtered } ?? [] }
        else { unchanged = alignment?.rows.map { ($0.base.state == .normal || $0.base.state == .filtered) && ($0.destination.state == .normal || $0.destination.state == .filtered) } ?? [] }
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
    var comparisonDefaults: UserDefaults = .standard
    @Published private(set) var generalPreferences = MergeGeneralPreferences.load()
    private var pendingLoadNavigation = false
    @Published var combinedScrollRow: Int?
    private var initialScrollRow: Int?
    private var initialScrollSides = Set<Bool>()
    @Published private(set) var whitespaceDisplay = MergeWhitespaceDisplayPreferences.load()
    func setWhitespaceDisplay(_ value: MergeWhitespaceDisplayPreferences) {
        guard !busy, !confirmingQuit, !retired else { return }
        whitespaceDisplay = value; value.save(to: comparisonDefaults)
    }
    @Published private(set) var locatorPreferences = MergeLocatorPreferences.load()
    @Published private(set) var locatorViewport = MergeLocatorViewport()
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
        for scroll in scrolls.values { MergeLocatorScrolling.scroll(scroll, to: row) }
        refreshLocatorViewport()
    }
    func refreshLocatorViewport() {
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
    func setComparisonOptions(_ value: MergeComparisonOptions) {
        guard !busy, !confirmingQuit, !retired else { return }
        comparisonOptions = value; value.save(to: comparisonDefaults); rebuildFilterAlignment()
    }
    struct AlignmentSelection { let id = UUID(); let sourceRange: NSRange; var scroll = false }
    @Published var alignmentSelections: [Bool: AlignmentSelection] = [:]
    var regexDefaults: UserDefaults = .standard
    private var regexCancellation: OperationCancellation?
    private var regexList: MergeRegexFilterListController?
    func refreshRegexFilters() {
        guard !retired else { return }
        regexFilters = MergeRegexFilters.load(defaults: regexDefaults)
        if let name = regexFilterName, !regexFilters.contains(where: { $0.name == name }) { regexFilterName = nil }
        rebuildFilterAlignment()
    }
    func selectRegexFilter(_ name: String?) {
        guard !busy, !confirmingQuit, !retired, name == nil || regexFilters.contains(where: { $0.name == name }) else { return }
        regexFilterName = name; difference = -1; rebuildFilterAlignment()
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
              alignment.rows.indices.contains(index) else { previewRow = nil; return }
        previewRow = index
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
        if options != comparisonOptions { comparisonOptions = options; rebuildFilterAlignment() }
        let next = MergeEditorPreferences.load()
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
    var transferRows: Range<Int>? { selectedRows ?? alignment.flatMap { $0.differences.indices.contains(difference) ? $0.differences[difference] : nil } }
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
    var hasPendingEditorChoice: Bool { exporting || formatRequest != nil || paneSave != nil }
    var chooseFormat: (NSWindow, String, MergeFormatSelection) async -> MergeFormatSelection? = MergeFormatPrompt.choose
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
                if formatRequest == request { formatRequest = nil; onExportStateChanged() }
            }
            guard let choice = await chooseFormat(window, base ? "Base" : "Mine", .initial(encoding: originalEncoding, text: original)),
                  !retired, formatRequest == request, alignmentGeneration == generation,
                  draftText(base: base).utf8.elementsEqual(original.utf8), encoding(base: base) == originalEncoding else { return }
            // Release this chooser's lock before applying its captured result.
            formatRequest = nil; onExportStateChanged()
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
        guard let alignment else { return }
        selectedRows = try? FileComparisonEditing.selectedRows(range, cells: cells)
        if onePaneActive, let selection = selectedRows, let combined {
            let mapped = selection.compactMap { combined.rows.indices.contains($0) ? combined.rows[$0].alignmentRow : nil }
            selectedRows = mapped.min().flatMap { start in mapped.max().map { start..<($0 + 1) } }
        }
        previewLine(atRow: selectedRows?.lowerBound)
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
        request.cancellation.cancel()
        if let panel = request.panel {
            panel.sheetParent?.endSheet(panel, returnCode: .cancel)
            panel.orderOut(nil)
        }
    }
    private func chooseOutput(_ window: NSWindow, name: String, directory: URL, patch: Bool) async -> URL? {
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
            let bytes = try drafts?.exported(base: base) ?? content.bytes
            let directory = paneTargets[base]?.url.deletingLastPathComponent() ?? (sourceSnapshotRoot == nil ? snapshot.root : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            let name = (content.path as NSString).lastPathComponent
            let selectedEncoding = drafts?.encoding(base: base) ?? content.encoding
            let chooser = chooseExportLocation
            guard let request = beginOutput() else { return }
            Task {
                defer { finishOutput(request) }
                guard acceptsOutput(request), let url = await chooser(window, name, directory), acceptsOutput(request) else { return }
                let permission = RepositoryAccessLease(url: url)
                do {
                    guard !GitRuntime.isAppStoreBuild || permission.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    if rebind, let sourceSnapshotRoot,
                       url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(sourceSnapshotRoot.path + "/") { throw FileComparisonEditFailure.unsupported }
                    try withExtendedLifetime(permission) { try bytes.write(to: url, options: .atomic) }
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
                guard !GitRuntime.isAppStoreBuild || permission.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                let executable = try generator ?? GitRuntime.executable()
                func savedContent(_ content: ComparisonFileContent) throws -> ComparisonFileContent {
                    guard content.revision == .workingTree, !content.isDeleted else { return content }
                    let file = content.path.hasPrefix("/") ? URL(fileURLWithPath: content.path) : directory.appendingPathComponent(content.path)
                    return try WorkingFileComparison.workingContent(at: file)
                }
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
    func resetHistory() { for actions in editorActions.values { actions.reset() }; selectEditorActions() }
    var selectionRequest: Int?
    private var scrolls: [Bool: NSScrollView] = [:]
    private var viewportNavigation: [Bool: () -> Void] = [:]
    func registerViewportNavigation(base: Bool, action: @escaping () -> Void) { guard !retired else { return }; viewportNavigation[base] = action }
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
    }
    func retireImageLoader() {
        folding.retire()
        loadSession?.cancel(); closeAfterLoad = false
        lineWrapping.retire(); viewportNavigation.removeAll()
        cancelOutput(); cancelPaneSave()
        formatRequest = nil; previewRow = nil
        onExportStateChanged = {}
        retired = true; regexCancellation?.cancel(); regexCancellation = nil; regexList?.retire(); regexList = nil
        imageLoader?.retire(); imageLoader = nil
    }
    func chooseImageFiles() {
        guard !busy, !confirmingQuit, imageLoader == nil, let window, window.attachedSheet == nil else { return }
        let left = document?.base.path ?? ""
        let loader = makeImageLoader(left.hasPrefix("/") ? left : "", workingPermissions + [access].compactMap { $0 })
        imageLoader = loader
        loader.onAccepted = { [weak self] comparison, permissions in
            guard let self else { return }
            self.retainedImageModel = (self.window as? ImageComparisonKeyRouting)?.imageKeyModel
            self.retainedImageModel?.fit = true
            self.standaloneImages = comparison; self.workingPermissions = permissions; self.load()
        }
        loader.onClosed = { [weak self] in self?.imageLoader = nil }
        loader.present(parent: window)
    }
    private var conflictBaseEntry: ConflictEntry?
    init(repository: GitRepository, access: RepositoryAccessLease?, conflict: ConflictBaseComparison) {
        self.repository = repository; self.access = access; snapshot = conflict.snapshot; path = conflict.entry.path
        conflictBaseEntry = conflict.entry
    }
    private var changeSetDocument: FileComparisonDocument?
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
    func load() {
        guard !retired, !busy, !hasPendingEditorChoice, !confirmingQuit, window?.attachedSheet == nil else { return }
        wrapLines = comparisonDefaults.bool(forKey: "TurtleGitMerge.WrapLines")
        if !singleFileMode { showInlineDiff = MergeInlinePresentation.defaultEnabled(from: comparisonDefaults) }
        if !loadedPaneMode { onePaneMode = OnePaneFileComparison.defaultEnabled(from: comparisonDefaults); loadedPaneMode = true }
        if dirty {
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
        initialScrollRow = nil; combinedScrollRow = nil; initialScrollSides = []
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
                        guard !GitRuntime.isAppStoreBuild || openPermissions.contains(where: { $0.hasSecurityScope && $0.contains(target.url) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                        replacements[base] = try target.read()
                    }
                    var value: FileComparisonDocument
                    if replacements.count == 2, let originalPaneDocument { value = originalPaneDocument }
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
                        value = try await repository.comparisonFile(historicalWorkingComparison, replacements: replacements, cancellation: token)
                    } else if let workingComparison {
                        try validateWorkingAccess(workingComparison)
                        value = try workingComparison.read(replacements: replacements)
                    } else if let repository {
                        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                        value = try await repository.comparisonFile(snapshot, path: path, replacements: replacements, cancellation: token)
                    } else { throw RevisionComparisonFailure.selection }
                    var original = value
                    for (base, replacement) in replacements {
                        if let prior = originalPaneDocument { original = original.replacingPane(base: base, content: base ? prior.base : prior.destination) }
                        value = value.replacingPane(base: base, content: replacement)
                    }
                    originalPaneDocument = original
                    guard !retired, !token.isCancelled else { return }
                    if !externalAttempted {
                        externalOpened = try await openExternalComparison(value, snapshot.root, workingPermissions + [access].compactMap { $0 }, alternateTool)
                        externalAttempted = true
                        guard !externalOpened, !retired, !token.isCancelled else { return }
                }
                let adapted = value.usingMergeEncoding(preferUTF8: ComparisonTextEncoding.preferUTF8(from: comparisonDefaults))
                document = adapted
                for (base, target) in paneTargets { paneTargets[base] = try target.recording(base ? adapted.base : adapted.destination) }
                imagePresentation.openImages = { [weak self] in self?.chooseImageFiles() }
                imageComparison = standaloneImages == nil ? ImageComparisonDocument(adapted) : ImageComparisonDocument(base: ComparisonImage(bytes: adapted.base.bytes), destination: ComparisonImage(bytes: adapted.destination.bytes))
                window?.title = "\(standaloneImages == nil ? path : (standaloneImages?.destination?.path ?? standaloneImages?.base?.path ?? "Images")) – " + (imageComparison == nil ? "TurtleGitMerge" : "TurtleGitIDiff")
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
        regexCancellation?.cancel(); regexCancellation = nil; filtering = false
        alignmentSelections = [:]
        alignmentGeneration += 1; selectedRows = nil; previewRow = nil
        let a = drafts?.text(base: true) ?? document.base.text
        let b = drafts?.text(base: false) ?? document.destination.text
        // Immediate projection supports native text/Undo coordinate updates.
        // It is unverified while filtering is true; transfers, navigation and
        // inline comparison are gated until Subversion publishes its ranges.
        alignment = a.flatMap { old in b.map { FileComparisonAlignment(base: old, destination: $0) } }
        guard let a, let b, imageComparison == nil, !retired else { return }
        let filter = regexFilters.first(where: { $0.name == regexFilterName })
        let current = alignmentGeneration, token = OperationCancellation()
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
            let result = await Task.detached { Result { try SubversionComparisonPresentation(plan: configuration.get().plan(base: a, mine: b, cancellation: token)).alignment } }.value
            guard !retired, alignmentGeneration == current else { return }
            filtering = false; regexCancellation = nil
            switch result {
            case .success(let value):
                var selections: [Bool: AlignmentSelection] = [:]
                for (side, scroll) in scrolls {
                    if let text = scroll.documentView as? FileComparisonTextView,
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
                    if let first = value.differences.first {
                        difference = 0
                        initialScrollRow = first.lowerBound; initialScrollSides = [true, false]
                        for side in [true, false] where scrolls[side] != nil { queueInitialNavigation(base: side) }
                    }
                }
            case .failure(let failure): pendingLoadNavigation = false; alignment = nil; regexFilterName = nil; error = failure.localizedDescription
            }
        }
    }
    /// Replacement uses a temporary sibling. A file bookmark alone is retained
    /// for reads; ask for its folder only when the user explicitly saves.
    private func authorizeWorkingReplacement(at file: URL) throws -> Bool {
        guard GitRuntime.isAppStoreBuild else { return true }
        let parent = file.deletingLastPathComponent()
        if workingPermissions.contains(where: { $0.hasSecurityScope && $0.contains(file) && $0.contains(parent) }) { return true }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = parent; panel.prompt = "Allow Save"
        panel.message = "Choose the folder containing “" + file.lastPathComponent + "” to allow TurtleGit to replace the edited file."
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        let permission = RepositoryAccessLease(url: folder)
        guard permission.hasSecurityScope, permission.contains(file), permission.contains(parent) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        workingPermissions.append(permission)
        return true
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
    private var updatingSaveDecision = false
    func cancelPaneSave() { paneSave?.cancel() }
    private func ensurePaneSave(_ request: OperationCancellation) throws {
        guard !retired, paneSave === request else { throw OperationCancellationFailure.cancelled }
        try request.check()
    }
    var chooseMarkedSave: () async -> FileComparisonEditing.MarkedSaveChoice? = { nil }
    var chooseEmptyResult: ((String) async -> MergeEmptyResult)?
    func installMarkedSavePrompt() {
        chooseMarkedSave = { [weak self] in
            guard let window = self?.window, window.attachedSheet == nil else { return nil }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Marked Blocks"
            alert.informativeText = "You have marked changed blocks. How should those blocks be saved? Manual edits are retained with every choice."
            alert.addButton(withTitle: "Save and Include")
            alert.addButton(withTitle: "Save and Exclude")
            alert.addButton(withTitle: "Save Only Manual Edits")
            alert.addButton(withTitle: "Cancel")
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            switch response {
            case .alertFirstButtonReturn: return .include
            case .alertSecondButtonReturn: return .exclude
            case .alertThirdButtonReturn: return .manualEditsOnly
            default: return nil
            }
        }
    }
    private func save(sides: [Bool], ownerInitiated: Bool = false, completion: ((Bool) -> Void)?) {
        guard paneSave == nil, (!busy && !confirmingQuit || ownerInitiated), !hasPendingEditorChoice, !retired, window?.attachedSheet == nil, document != nil else { completion?(false); return }
        let request = OperationCancellation(), permissions = openPermissions
        paneSave = request; Self.activePaneExports += 1; busy = true
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
                    let choice: MergeEmptyResult
                    if text.isEmpty {
                        let savePath = base ? document.base.path : document.destination.path
                        if let chooseEmptyResult { choice = await chooseEmptyResult(savePath) }
                        else { choice = await MergeEmptyResultPrompt.choose(window: window, path: savePath) }
                    }
                    else { choice = .keep }
                    try ensurePaneSave(request)
                    let options = MergeFileSaveOptions(backupOriginal: MergeFileSaveOptions.backupEnabled(from: comparisonDefaults), emptyResult: choice)
                    let result: FileComparisonDocument
                    let context = savingContext(document)
                    if let target = paneTargets[base] {
                        guard !GitRuntime.isAppStoreBuild || openPermissions.contains(where: { $0.hasSecurityScope && $0.contains(target.url) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                        result = try target.save(document, base: base, text: text, encoding: drafts?.encoding(base: base), options: options)
                    } else if let conflictBaseEntry, let repository {
                        guard !base else { throw FileComparisonEditFailure.unsupported }
                        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                        result = try await repository.saveConflictBaseComparison(conflictBaseEntry, document: context, text: text, encoding: drafts?.encoding(base: base), options: options)
                    } else if let historicalWorkingComparison {
                        try validateHistoricalWorkingAccess(historicalWorkingComparison)
                        guard base else { throw FileComparisonEditFailure.unsupported }
                        guard try authorizeWorkingReplacement(at: historicalWorkingComparison.workingFile) else { return }
                        result = try historicalWorkingComparison.saveBase(context, text: text, encoding: drafts?.encoding(base: base), options: options)
                    } else if let workingComparison {
                        try validateWorkingAccess(workingComparison)
                        guard try authorizeWorkingReplacement(at: base ? workingComparison.base : workingComparison.destination) else { return }
                        result = try workingComparison.save(context, base: base, text: text, encoding: drafts?.encoding(base: base), options: options)
                    } else if let repository {
                        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                        result = try await repository.saveComparisonFile(snapshot, document: context, base: base, text: text, encoding: drafts?.encoding(base: base), options: options)
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
                rebuildAlignment(); saved = true
            } catch { if !retired && !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func remapOtherAnnotations(from old: FileComparisonAlignment, to new: FileComparisonAlignment, changedBase: Bool) {
        drafts?.remapAnnotations(from: old, to: new, base: !changedBase)
    }
    private func queueInitialNavigation(base: Bool) {
        guard initialScrollSides.contains(base), let row = initialScrollRow, let alignment else { return }
        let offset = alignment.rows.prefix(row).reduce(0) { sum, row in
            let cell = base ? row.base : row.destination
            return sum + (cell.lineNumber == nil ? 0 : cell.text.utf16.count)
        }
        initialScrollSides.remove(base)
        if onePaneActive, !base { combinedScrollRow = combined?.rows.firstIndex(where: { $0.alignmentRow >= row }); return }
        alignmentSelections[base] = .init(sourceRange: NSRange(location: offset, length: 0), scroll: true)
    }
    func register(_ scroll: NSScrollView, base: Bool) { scrolls[base] = scroll; queueInitialNavigation(base: base); onRegisterScroll(scroll, base); refreshLocatorViewport() }
    func scrolled(_ source: NSScrollView) {
        defer { refreshLocatorViewport(); previewHorizontalOffsets = scrolls.mapValues { $0.contentView.bounds.minX } }
        guard !synchronizing else { return }; synchronizing = true; defer { synchronizing = false }
        for target in scrolls.values where target !== source {
            var point = target.contentView.bounds.origin; point.y = source.contentView.bounds.origin.y
            target.contentView.scroll(to: target.contentView.constrainBoundsRect(NSRect(origin: point, size: target.contentView.bounds.size)).origin)
            target.reflectScrolledClipView(target.contentView)
        }
    }
    func navigate(_ step: Int) {
        guard !filtering, let alignment, !alignment.differences.isEmpty else { return }
        difference = min(alignment.differences.count - 1, max(0, difference + step))
        let row = onePaneActive ? combined?.differences[difference].lowerBound ?? 0 : alignment.differences[difference].lowerBound
        for scroll in scrolls.values {
            guard let text = scroll.documentView as? NSTextView else { continue }
            let lines = text.string.components(separatedBy: "\n")
            let offset = lines.prefix(row).reduce(0) { $0 + ($1 as NSString).length + 1 }
            text.setSelectedRange(NSRange(location: min(offset, (text.string as NSString).length), length: 0))
            text.scrollRangeToVisible(text.selectedRange())
        }
    }
    func find(_ action: NSTextFinder.Action) {
        let text = scrolls.values.compactMap { $0.documentView as? NSTextView }.first { $0.window?.firstResponder === $0 }
            ?? (scrolls[activeBase]?.documentView as? NSTextView)
        if let text { MergeFindInterface.perform(action, in: text) }
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
                ImageComparisonDialog(images: images, document: document, model: model.retainedImageModel ?? ImageComparisonViewModel(presentation: model.imagePresentation)).id(images.id)
            } else { textBody }
        }.onAppear { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .mergeEditorPreferencesChanged)) { _ in model.refreshPreferences() }
        .onReceive(NotificationCenter.default.publisher(for: .mergeRegexFiltersChanged)) { _ in model.refreshRegexFilters() }
        .alert("Comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var textBody: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.save() } label: { CommandLabel(title: "Save", icon: .mergeSave) }.disabled(!model.activeDirty)
                Menu { if !model.onePaneActive { Button("Save left pane as…") { model.saveAs(base: true) } }; Button("Save right pane as…") { model.saveAs(base: false) } } label: { CommandLabel(title: "Save As", icon: .mergeSaveAs) }.disabled(!model.canSavePaneAs)
                Button { model.undo() } label: { Image(nsImage: MenuIcon.mergeUndo.image() ?? NSImage()) }.help("Undo").accessibilityLabel("Undo").disabled(!model.canUndo)
                Button { model.redo() } label: { Image(nsImage: MenuIcon.mergeRedo.image() ?? NSImage()) }.help("Redo").accessibilityLabel("Redo").disabled(!model.canRedo)
                Button { model.load() } label: { CommandLabel(title: "Reload", icon: .mergeReload) }
                Button { model.navigate(-1) } label: { CommandLabel(title: "Previous difference", icon: .mergePreviousConflict) }.disabled(model.difference <= 0)
                Button { model.navigate(1) } label: { CommandLabel(title: "Next difference", icon: .mergeNextConflict) }.disabled(model.alignment?.differences.isEmpty != false || model.difference >= (model.alignment?.differences.count ?? 0) - 1)
                Button { model.find(.showFindInterface) } label: { CommandLabel(title: "Find", icon: .mergeFind) }.disabled(model.alignment == nil)
                Button { model.createUnifiedPatch() } label: { CommandLabel(title: "Create patch file", icon: .patch) }.disabled(!model.canCreateUnifiedPatch)
                Spacer()
            }.padding(10).disabled(model.busy || model.confirmingQuit)
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
                MergeViewControls(preferences: model.locatorPreferences, apply: model.setLocatorPreferences, whitespace: model.whitespaceDisplay, applyWhitespace: model.setWhitespaceDisplay, wrapLines: model.wrapLines, applyWrap: model.setWrapLines, collapsed: model.folding.collapsed, applyCollapsed: model.setCollapsed).disabled(model.busy || model.confirmingQuit)
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
                    MergeLocatorBar(map: model.locatorMap, viewport: model.locatorViewport, fishEye: model.locatorPreferences.fishEye,
                                    enabled: !model.busy && !model.filtering && !model.confirmingQuit, navigate: model.scrollLocator)
                        .frame(width: 44).help("Left and right file overview; click or drag to scroll")
                }
                HSplitView { if !model.singleFileMode && !model.onePaneActive { pane(base: true) }; pane(base: false) }
            }
            if model.showLineDiffBar && !model.singleFileMode && !model.onePaneActive {
                Divider()
                MergeLineDiffBar(model: model).frame(height: MergeLineDiffPreview.lineHeight(model.generalPreferences.nativeFont) * 2)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.filtering ? "Comparing…" : model.alignment.map { "\($0.differences.count) difference(s)" } ?? "").font(.caption)
                Spacer(); Text(model.dirty ? "Modified · working file not saved" : model.editingEnabled && model.editableBase != nil ? "Editing working file" : "Read-only comparison").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
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
            annotate: { [weak coordinator = context.coordinator] value in guard let coordinator else { return }; coordinator.replace(coordinator.model.draftText(base: coordinator.base), caret: 0, restored: value) },
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
        if let sourceSelection, !(model.onePaneActive && oldDisplay.utf8.elementsEqual(value.string.utf8)) {
            let start = min(FileComparisonEditing.displayOffset(sourceOffset: sourceSelection.location, cells: cells), value.length)
            let end = min(FileComparisonEditing.displayOffset(sourceOffset: NSMaxRange(sourceSelection), cells: cells), value.length)
            let range = NSRange(location: start, length: max(0, end - start))
            if view.selectedRange() != range { view.setSelectedRange(range) }
        }
        model.updateFolding()
        (view as? FileComparisonTextView)?.foldLayout.apply(to: view, controller: model.folding)
        model.lineWrapping.geometryChanged = { [weak model] in model?.applyViewportNavigation(); model?.refreshLocatorViewport() }
        model.lineWrapping.update(scroll, key: base ? "Base" : "Mine", aligned: !model.onePaneActive && !model.singleFileMode, enabled: model.wrapLines)
        scroll.rulersVisible = model.showLineNumbers
        (scroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers = cells.map(\.lineNumber)
        (scroll.verticalRulerView as? MergeLineRuler)?.updateMetrics(for: view)
        (scroll.verticalRulerView as? MergeLineRuler)?.markedRows = model.onePaneActive ? Set((model.combined?.rows ?? []).enumerated().compactMap { model.annotations(base: false).marked.contains($0.element.alignmentRow) ? $0.offset : nil }) : model.annotations(base: base).marked
        scroll.verticalRulerView?.needsDisplay = true
        model.registerViewportNavigation(base: base) { [weak coordinator = context.coordinator] in coordinator?.applyViewportSelection() }
        // Navigation is consumed after wrapping/text extents settle, not while
        // the SwiftUI representable still has an empty initial viewport.

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
        let history = UndoManager()
        init(model: FileComparisonWindowModel) { self.model = model }
        func applyViewportSelection() {
            let model = self.model, base = self.base
            guard let scroll, scroll.window != nil, scroll.contentSize.width > 32, scroll.contentSize.height > 32,
                  let view = scroll.documentView as? NSTextView,
                  let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            if let selection = model.alignmentSelections[base], appliedSelection != selection.id {
                appliedSelection = selection.id
                let start = FileComparisonEditing.displayOffset(sourceOffset: selection.sourceRange.location, cells: cells)
                let end = FileComparisonEditing.displayOffset(sourceOffset: NSMaxRange(selection.sourceRange), cells: cells)
                view.setSelectedRange(NSRange(location: min(start, (view.string as NSString).length), length: max(0, min(end, (view.string as NSString).length) - min(start, (view.string as NSString).length))))
                if selection.scroll { view.scrollRangeToVisible(view.selectedRange()) }
                DispatchQueue.main.async { if model.alignmentSelections[base]?.id == selection.id { model.alignmentSelections.removeValue(forKey: base) } }
            }
            if model.onePaneActive, !base, let row = model.combinedScrollRow {
                let offset = cells.prefix(row).reduce(0) { $0 + $1.displayText.utf16.count + 1 }
                view.setSelectedRange(NSRange(location: min(offset, (view.string as NSString).length), length: 0)); view.scrollRangeToVisible(view.selectedRange())
                DispatchQueue.main.async { if model.combinedScrollRow == row { model.combinedScrollRow = nil } }
            }
            if model.editableBase == base, let caret = model.selectionRequest {
                let offset = FileComparisonEditing.displayOffset(sourceOffset: caret, cells: cells)
                view.setSelectedRange(NSRange(location: min(offset, (view.string as NSString).length), length: 0))
                view.scrollRangeToVisible(view.selectedRange())
                DispatchQueue.main.async { if model.selectionRequest == caret { model.selectionRequest = nil } }
            }
        }
        @objc func scrolled(_ notification: Notification) { if let scroll { model.scrolled(scroll) } }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard model.editingEnabled, model.editableBase == base, !model.busy, !model.confirmingQuit else { return false }
            do {
                let edit: (text: String, caret: Int)
                if model.onePaneActive, !base, let combined = model.combined { edit = try combined.applying(replacementString ?? "", ranges: [affectedCharRange]) }
                else { edit = try FileComparisonEditing.applying(replacementString ?? "", range: affectedCharRange, cells: cells) }
                replace(edit.text, caret: edit.caret, typing: true)
            } catch { model.error = error.localizedDescription }
            return false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            (view as? FileComparisonTextView)?.foldLayout.reveal(selection: view.selectedRange(), in: view)
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
        func replace(_ text: String, caret: Int, restored: FileComparisonEditing.Annotations? = nil, cleared: Range<Int>? = nil, typing: Bool = false, clearMarks: Bool = false, resolvingSave: Bool = false) {
            guard model.canEdit(base: base), resolvingSave || (!model.busy && !model.confirmingQuit) else { return }
            let old = model.draftText(base: base), previous = model.annotations(base: base), oldAlignment = model.alignment
            var next = previous
            if clearMarks { next.marked = [] }
            if let cleared { next.marked.subtract(cleared); next.edited.subtract(cleared) }
            let textChanged = !old.utf8.elementsEqual(text.utf8)
            guard textChanged || restored != nil || next != previous else { return }
            if !textChanged, (restored ?? next) == previous { return }
            history.registerUndo(withTarget: self) { target in target.replace(old, caret: min(caret, (old as NSString).length), restored: previous) }
            history.setActionName("Edit comparison")
            model.updateDraft(text, base: base)
            if model.activeBase == base { model.selectionRequest = caret }
            model.rebuildAlignment()
            if let oldAlignment, let alignment = model.alignment { model.remapOtherAnnotations(from: oldAlignment, to: alignment, changedBase: base) }
            if let restored { model.updateAnnotations(restored, base: base) }
            else if let oldAlignment, let alignment = model.alignment { model.updateAnnotations(next.remapped(from: oldAlignment, to: alignment, targetBase: base, typing: typing), base: base) }
            if let alignment = model.alignment, let view = scroll?.documentView as? NSTextView {
                cells = model.displayCells(base: base)
                (view as? FileComparisonTextView)?.sourceCells = cells
                view.textStorage?.setAttributedString(FileComparisonEditor.attributed(cells, font: view.font!, model: model, base: base))
                (view as? FileComparisonTextView)?.missingOffsets = FileComparisonEditor.missingOffsets(cells, model: model, base: base)
                if model.activeBase == base {
                    view.setSelectedRange(NSRange(location: min(FileComparisonEditing.displayOffset(sourceOffset: caret, cells: cells), (view.string as NSString).length), length: 0))
                    // The native editor has consumed this edit's caret. Do not
                    // replay it during a later hosting update after the user
                    // has selected another range.
                    if model.selectionRequest == caret { model.selectionRequest = nil }
                }
            }
            DispatchQueue.main.async { self.updateUndoState() }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
@MainActor protocol ComparisonContextMenuProviding {
    func comparisonContextMenu(defaults: UserDefaults, pasteboard: NSPasteboard) -> NSMenu
}
private final class FileComparisonTextView: NSTextView, NSMenuDelegate, ComparisonContextMenuProviding, MergeLineNavigationProviding, MergeWhitespaceDisplaying, MergeFindProviding, MergeLineDiffHoverProviding, MergeInlineNavigationProviding {
    var chooseNavigationLine: (NSWindow, Int) async -> Int? = MergeLineNumberPrompt.choose
    var navigationPending = false
    var navigationCells: [MergeSourceCell]? { sourceCells }
    var navigationAllowed: Bool { model?.busy == false && model?.confirmingQuit == false }
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
        guard let target = inlineTarget(forward: forward) else { return }
        model?.selectionRequest = nil
        setSelectedRange(NSRange(location: target, length: 0)); scrollRangeToVisible(selectedRange())
    }
    @objc private func nextInlineDifference(_ sender: Any?) { navigateInline(forward: true) }
    @objc private func previousInlineDifference(_ sender: Any?) { navigateInline(forward: false) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .control, event.charactersIgnoringModifiers?.lowercased() == "g" {
            goToSourceLine(nil); return true
        }
        if modifiers == [.control, .option], event.keyCode == 123 || event.keyCode == 124 {
            navigateInline(forward: event.keyCode == 124); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    var history: UndoManager?
    weak var model: FileComparisonWindowModel?
    var baseSide = false
    var sourceCells: [MergeSourceCell] = []
    let foldLayout = MergeFoldTextLayout()
    override func scrollRangeToVisible(_ range: NSRange) {
        foldLayout.reveal(selection: range, in: self, includeMarker: true)
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

    var mergeFindController: MergeFindWindowController?
    var mergeFindDefaults: UserDefaults { model?.comparisonDefaults ?? .standard }
    var mergeFindAllowed: Bool { model?.busy == false && model?.confirmingQuit == false && model?.filtering == false && window?.attachedSheet == nil }
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
    override func mouseDown(with event: NSEvent) {
        model?.activatePane(base: baseSide)
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
        model.updateSelection(selectedRange(), cells: sourceCells)
        var rows = model.transferRows
        if model.onePaneActive, let selected = rows, let combined = model.combined {
            let indices = combined.rows.indices.filter { selected.contains(combined.rows[$0].alignmentRow) }
            rows = indices.first.flatMap { first in indices.last.map { first..<($0 + 1) } }
        }
        return try? MergeClipboard.sourceText(selection: selectedRange(), cells: sourceCells, blockRows: rows)
    }
    @discardableResult fileprivate func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard model?.copyCommandsAllowed == true, let text = clipboardText, !text.isEmpty else { return false }
        pasteboard.clearContents(); return pasteboard.setString(text, forType: .string)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard model != nil else { return super.menu(for: event) }
        return comparisonContextMenu(defaults: .standard, pasteboard: .general)
    }
    func comparisonContextMenu(defaults: UserDefaults, pasteboard: NSPasteboard) -> NSMenu {
        guard let model else { return NSMenu() }
        model.updateSelection(selectedRange(), cells: sourceCells)
        let menu = ComparisonClipboardMenu(); menu.autoenablesItems = false; menu.delegate = self
        let clipboard = ComparisonClipboardCommands(view: self, pasteboard: pasteboard); menu.clipboard = clipboard
        func add(_ title: String, _ action: Selector, _ icon: NSImage?, _ enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.image = MenuPresentationSettings.applicationContextIcons(defaults: defaults) ? icon : nil; item.isEnabled = enabled; menu.addItem(item)
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

/// Shared native adaptation of CGotoLineDlg. AppKit owns the sheet, focus and
/// validation; the injected choice supports tests without displaying a window.
@MainActor final class MergeLineNumberPrompt: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    let limit: Int
    init(limit: Int) {
        self.limit = limit
        super.init()
        alert.messageText = "Go To Line"
        alert.informativeText = "Line number (1 – \(limit))"
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false
        field.placeholderString = "Line number"; field.setAccessibilityLabel("Line number (1 – \(limit))")
        field.delegate = self; alert.accessoryView = field
        alert.window.initialFirstResponder = field
    }
    static func validated(_ input: String, limit: Int) -> Int? {
        guard !input.isEmpty, input.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(input), (1...max(1, limit)).contains(value), limit > 1 else { return nil }
        return value
    }
    func controlTextDidChange(_ notification: Notification) {
        alert.buttons[0].isEnabled = Self.validated(field.stringValue, limit: limit) != nil
    }
    static func choose(window: NSWindow, limit: Int) async -> Int? {
        let prompt = MergeLineNumberPrompt(limit: limit)
        let response = await withCheckedContinuation { continuation in
            prompt.alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return validated(prompt.field.stringValue, limit: limit)
    }
}
@MainActor protocol MergeLineNavigationProviding: AnyObject {
    var chooseNavigationLine: (NSWindow, Int) async -> Int? { get set }
    var navigationPending: Bool { get set }
    var navigationCells: [MergeSourceCell]? { get }
    var navigationAllowed: Bool { get }
}
extension MergeLineNavigationProviding where Self: NSTextView {
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
        let original = string
        navigationPending = true
        Task { @MainActor in
            defer { navigationPending = false }
            guard let line = await chooseNavigationLine(window, limit), line >= 1, line <= limit,
                  navigationAllowed, window.attachedSheet == nil, self.window === window,
                  string.utf8.elementsEqual(original.utf8) else { return }
            let range: NSRange?
            if let cells = navigationCells { range = MergeSourceComparison.navigationRange(line: line, cells: cells) }
            else { range = MergeSourceComparison.navigationRanges(text: string)[line - 1] }
            guard let range, NSMaxRange(range) <= (string as NSString).length else { return }
            window.makeFirstResponder(self); setSelectedRange(range); scrollRangeToVisible(range)
        }
    }
}

/// Transactional native Encoding/EOL chooser shared by both Merge viewers.
@MainActor final class MergeFormatPrompt {
    let alert = NSAlert()
    let encoding = NSPopUpButton(), ending = NSPopUpButton()
    let endings: [MergeLineEnding?] = [nil,.crlf,.lf,.cr,.lfcr,.verticalTab,.formFeed,.nextLine,.lineSeparator,.paragraphSeparator]
    init(pane: String, selection: MergeFormatSelection) {
        alert.messageText = pane + " Encoding"
        alert.addButton(withTitle:"OK"); alert.addButton(withTitle:"Cancel")
        encoding.addItems(withTitles:MergeFormatSelection.encodings.map(\.rawValue))
        encoding.selectItem(at:MergeFormatSelection.encodings.firstIndex(of:selection.encoding) ?? 7)
        ending.addItems(withTitles:endings.map { $0?.menuTitle ?? "Auto" })
        ending.selectItem(at:endings.firstIndex(where:{ $0 == selection.ending }) ?? 0)
        let grid = NSGridView(views:[[NSTextField(labelWithString:pane),NSView()], [NSTextField(labelWithString:"Encoding"),encoding], [NSTextField(labelWithString:"EOL"),ending]])
        grid.columnSpacing = 14; grid.rowSpacing = 10
        encoding.widthAnchor.constraint(equalToConstant:240).isActive = true
        grid.frame = NSRect(origin:.zero,size:grid.fittingSize)
        encoding.setAccessibilityLabel(pane + " encoding"); ending.setAccessibilityLabel(pane + " line endings")
        alert.accessoryView = grid; alert.window.initialFirstResponder = encoding
    }
    var selection: MergeFormatSelection {
        .init(encoding:MergeFormatSelection.encodings[max(0,encoding.indexOfSelectedItem)], ending:endings[max(0,ending.indexOfSelectedItem)])
    }
    static func choose(window: NSWindow, pane: String, selection: MergeFormatSelection) async -> MergeFormatSelection? {
        let prompt = MergeFormatPrompt(pane:pane,selection:selection)
        let response = await withCheckedContinuation { continuation in prompt.alert.beginSheetModal(for:window) { continuation.resume(returning:$0) } }
        return response == .alertFirstButtonReturn ? prompt.selection : nil
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
