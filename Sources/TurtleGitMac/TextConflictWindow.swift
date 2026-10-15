import AppKit
import SwiftUI
import Combine
import TurtleGitCore
import UniformTypeIdentifiers

private extension MergeBlockChoice {
    var icon: MenuIcon {
        switch self {
        case .mine: return .mergeUseMine
        case .theirs: return .mergeUseTheirs
        case .mineThenTheirs: return .mergeMineThenTheirs
        case .theirsThenMine: return .mergeTheirsThenMine
        }
    }
}
extension MergeLineEnding {
    var menuTitle: String {
        switch self {
        case .crlf: return "CRLF"
        case .lf: return "LF"
        case .cr: return "CR"
        case .lfcr: return "LFCR"
        case .verticalTab: return "VT"
        case .formFeed: return "FF"
        case .nextLine: return "NEL"
        case .lineSeparator: return "LS"
        case .paragraphSeparator: return "PS"
        }
    }
}
/// Pane-local format indicators match TortoiseMerge's status ribbon. Read-only
/// sources report their actual file format; writable panes offer output choices.
struct MergeFormatControls: View {
    let label: String
    let encoding: ComparisonTextEncoding?
    let text: String?
    let editable: Bool
    let changeEncoding: (ComparisonTextEncoding) -> Void
    let changeEnding: (MergeLineEnding) -> Void
    var showFormatDialog: (() -> Void)? = nil
    private var styles: Set<MergeLineEnding> { text.map(MergeLineEndings.styles) ?? [] }
    private var endingTitle: String {
        guard text != nil else { return "—" }
        if styles.isEmpty { return "No line ending" }
        if styles.count == 1 { return styles.first!.menuTitle }
        return "Mixed EOL"
    }
    var body: some View {
        HStack(spacing: 8) {
            if editable {
                if let showFormatDialog { Button("Encoding…", action:showFormatDialog).accessibilityLabel("\(label) encoding and line endings") }
                Menu(encoding?.rawValue ?? "—") {
                    ForEach(ComparisonTextEncoding.allCases, id: \.rawValue) { value in
                        Button { changeEncoding(value) } label: {
                            if value == encoding { Label(value.rawValue, systemImage: "checkmark") }
                            else { Text(value.rawValue) }
                        }
                    }
                }.fixedSize().accessibilityLabel("\(label) file encoding: \(encoding?.rawValue ?? "—")")
                Menu(endingTitle) {
                    ForEach(MergeLineEnding.allCases, id: \.rawValue) { value in
                        Button { changeEnding(value) } label: {
                            if styles == [value] { Label(value.menuTitle, systemImage: "checkmark") }
                            else { Text(value.menuTitle) }
                        }
                    }
                }.fixedSize().accessibilityLabel("\(label) line endings: \(endingTitle)")
            } else {
                Text(encoding?.rawValue ?? "—")
                Text(endingTitle)
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
struct MergeTabControls: View {
    let label: String
    let tabWidth: Int
    let useSpaces: Bool
    let smartTab: Bool
    let changeWidth: (Int) -> Void
    let changeSpaces: (Bool) -> Void
    let changeSmart: (Bool) -> Void
    var editorConfigEnabled = false
    var editorConfigLoaded = false
    var changeEditorConfig: ((Bool) -> Void)? = nil
    private var settingsTitle: String { "\(useSpaces ? "Space" : "Tab") \(tabWidth)\(smartTab ? " Smart" : "")\(editorConfigEnabled && editorConfigLoaded ? " EC" : "")" }
    var body: some View {
        Menu(settingsTitle) {
            Button { changeSpaces(false) } label: {
                if !useSpaces { Label("Tab", systemImage: "checkmark") } else { Text("Tab") }
            }
            Button { changeSpaces(true) } label: {
                if useSpaces { Label("Space", systemImage: "checkmark") } else { Text("Space") }
            }
            Divider()
            Toggle("Smart tab char", isOn: Binding(get: { smartTab }, set: changeSmart))
            Divider()
            ForEach([1, 2, 4, 8], id: \.self) { width in
                Button { changeWidth(width) } label: {
                    if width == tabWidth { Label("\(width)", systemImage: "checkmark") } else { Text("\(width)") }
                }
            }
            if let changeEditorConfig {
                Divider()
                Toggle("EditorConfig", isOn: Binding(get: { editorConfigEnabled }, set: changeEditorConfig))
            }
        }.fixedSize().accessibilityLabel("\(label) tab settings: \(settingsTitle)")
    }
}
private enum MergeSourceSide {
    case mine, theirs
    var icon: MenuIcon { self == .mine ? .mergeUseMine : .mergeUseTheirs }
}

@MainActor final class TextConflictNSWindow: FileComparisonNativeWindow {
    weak var mergedText: NSTextView?
    weak var patchModel: WorkingTreePatchWindowModel?
    private weak var findText: NSTextView?
    private var activeText: NSTextView? { (firstResponder as? MergeTextView) ?? findText ?? mergedText }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let patchModel {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            #if DEBUG
            if flags == [.command, .option, .shift], event.charactersIgnoringModifiers?.lowercased() == "s", Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") == true { DocumentationCapture.saveWindow(); return true }
            #endif
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "o" { openMergeDocument(); return true }
            if flags == .command, event.charactersIgnoringModifiers == "s" { patchModel.saveDraft(); return true }
            if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", (firstResponder as? NSTextView)?.isFieldEditor != true {
                if flags.contains(.shift) { patchModel.editor?.redo() } else { patchModel.editor?.undo() }; return true
            }
            if flags == .command, event.charactersIgnoringModifiers == "f" { patchModel.findComparison(); return true }
            if event.keyCode == 96 { (delegate as? WorkingTreePatchWindowController)?.reloadEditor(nil); return true }
            return super.performKeyEquivalent(with: event)
        }
        guard mergedText != nil else { return super.performKeyEquivalent(with: event) }
        if (firstResponder as? NSTextView)?.isFieldEditor != true, MergeFindInterface.performKey(event, in: activeText) { return true }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, event.charactersIgnoringModifiers?.lowercased() == "o" { openMergeDocument(); return true }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command || modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", let undo = mergedText?.undoManager {
            if let field = firstResponder as? NSTextView, field.isFieldEditor {
                if modifiers.contains(.shift) { if field.undoManager?.canRedo == true { field.undoManager?.redo() } }
                else if field.undoManager?.canUndo == true { field.undoManager?.undo() }
                return true
            }
            guard mergedText?.isEditable == true else { return true }
            if modifiers.contains(.shift) { if undo.canRedo { undo.redo() } }
            else if undo.canUndo { undo.undo() }
            return true
        }
        if modifiers == .control, event.charactersIgnoringModifiers?.lowercased() == "g", let text = activeText as? MergeTextView {
            text.goToSourceLine(nil); return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers == "f" {
            find(.showFindInterface); return true
        }
        if modifiers == .command || modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            find(modifiers.contains(.shift) ? .previousMatch : .nextMatch); return true
        }
        if event.keyCode == 96 { (delegate as? TextConflictWindowController)?.reloadEditor(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
    func find(_ action: NSTextFinder.Action) {
        guard let text = activeText else { return }
        findText = text
        MergeFindInterface.perform(action, in: text)
    }
    override func cancelOperation(_ sender: Any?) {
        if let text = findText ?? activeText, text.enclosingScrollView?.isFindBarVisible == true {
            find(.hideFindInterface); makeFirstResponder(text)
        } else { performClose(sender) }
    }
}

@MainActor final class TextConflictWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let editorFileMenu = MergeEditorFileMenu()
    func windowDidBecomeKey(_ notification: Notification) { editorFileMenu.install(target: self, open: #selector(openMergeDocument(_:)), reload: #selector(reloadEditor(_:))) }
    func windowDidResignKey(_ notification: Notification) { editorFileMenu.remove() }
    func detachForReplacement() { editorToolbar?.retire(); editorFileMenu.remove(); model.retire(); model.window = nil }
    @objc func reloadEditor(_ sender: Any?) { guard !preparingReplacement, !model.exportingSource, editorOpenWorkflow == nil, window?.attachedSheet == nil else { return }; model.load() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { (item.action == #selector(openMergeDocument(_:)) || item.action == #selector(reloadEditor(_:))) && !preparingReplacement && editorOpenWorkflow == nil && !model.busy && !model.preparing && !model.confirmingQuit && !model.retired && !model.exportingSource && window?.attachedSheet == nil }
    private(set) var editorToolbar: MergeEditorToolbar?
    var showEditorHelp: () -> Void = { TurtleGitHelp.show(.resolve) }
    let model: TextConflictWindowModel
    var onClosed: () -> Void = {}
    var editorOpenWorkflow: MergeEditorOpenWorkflow?
    var makeEditorOpenWorkflow: (NSWindow, [RepositoryAccessLease], UserDefaults) -> MergeEditorOpenWorkflow = { MergeEditorOpenWorkflow(window: $0, permissions: $1, preferences: $2) }
    var replacementOwner: MergeEditorReplacementOwner?
    weak var sharedReplacementOwner: MergeEditorReplacementOwner?
    var preparingReplacement: Bool { (sharedReplacementOwner ?? replacementOwner)?.preparingPatch == true }
    @objc func openMergeDocument(_ sender: Any?) {
        guard !preparingReplacement, !model.exportingSource, editorOpenWorkflow == nil, let window, !model.busy, !model.preparing, !model.confirmingQuit, !model.retired, window.attachedSheet == nil else { return }
        let workflow = makeEditorOpenWorkflow(window, model.openPermissions, model.comparisonDefaults)
        editorOpenWorkflow = workflow
        workflow.onClosed = { [weak self] in self?.editorOpenWorkflow = nil }
        workflow.accept = { [weak self] request, permissions in try self?.replaceEditor(request, permissions: permissions) }
        workflow.start(dirty: model.dirty, description: model.path, save: { [weak self] completion in self?.model.save(markResolved: false, completion: completion) })
    }
    func replaceEditor(_ request: MergeOpenRequest, permissions: [RepositoryAccessLease]) throws {
        guard let window, !model.busy, !model.confirmingQuit, !model.retired, !model.exportingSource else { return }
        let owner = sharedReplacementOwner ?? replacementOwner ?? MergeEditorReplacementOwner(onClosed: onClosed)
        if sharedReplacementOwner == nil { replacementOwner = owner }
        try owner.replace(request, permissions: permissions, preferences: model.comparisonDefaults, window: window, previous: self)
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, workingMerge: WorkingTextMerge? = nil, permissions: [RepositoryAccessLease] = [], preferences: UserDefaults = .standard, deferInitialLoad: Bool = false) {
        model = TextConflictWindowModel(repository: repository, access: access, path: path)
        model.comparisonDefaults = preferences; model.initialLoadDeferred = deferInitialLoad
        model.workingMerge = workingMerge; model.workingMergePermissions = permissions
        let window = TextConflictNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(path) – TurtleGitMerge"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 860, height: 540)
        let hosting = NSHostingController(rootView: TextConflictDialog(model: model))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1120, height: 780))
        super.init(window: window); TurtleGitHelp.attach(window, topic: .resolve); window.delegate = self; window.openMergeDocument = { [weak self] in self?.openMergeDocument(nil) }; window.center(); model.window = window; model.close = { [weak window] in window?.close() }


        installEditorToolbar()
        DialogGeometry.attach(window, identifier: "TurtleGit.TextConflict", legacyName: "TurtleGit.TextConflict")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !preparingReplacement, !model.exportingSource, editorOpenWorkflow == nil else { return false }
        guard sender.attachedSheet == nil else { return false }
        if model.preparing { return true }
        guard !model.busy, !model.confirmingQuit else { return false }
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to “\(model.path)”?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.save(markResolved: false, closeAfter: true); return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) { guard let closing = notification.object as? NSWindow, closing === window else { return }; editorToolbar?.retire(); editorFileMenu.remove(); editorOpenWorkflow?.retire(); editorOpenWorkflow = nil; model.retire(); onClosed() }
    func installEditorToolbar() { editorToolbar?.retire(); editorToolbar = MergeEditorToolbar.conflict(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class TextConflictWindowModel: ObservableObject {
    let repository: GitRepository
    var workingMerge: WorkingTextMerge?
    var workingMergePermissions: [RepositoryAccessLease] = []
    var openPermissions: [RepositoryAccessLease] { workingMergePermissions + [access].compactMap { $0 } }
    private(set) var workingMergeOutput: URL?
    private var standaloneSavedResult: String?
    private var standaloneSavedEncoding: ComparisonTextEncoding?
    var chooseStandaloneOutput: ((NSWindow?, String) async -> URL?)?
    private func chooseMergeOutput() async -> URL? {
        if let chooseStandaloneOutput { return await chooseStandaloneOutput(window, path) }
        guard !retired, let window, window.attachedSheet == nil else { return nil }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "merged-" + (path as NSString).lastPathComponent
        panel.title = "Save merged result"; panel.canCreateDirectories = true
        let answer = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        guard !retired, answer == .OK, let url = panel.url else { return nil }
        let lease = RepositoryAccessLease(url: url)
        guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { error = RepositoryAccessFailure.securityScopeUnavailable.localizedDescription; return nil }
        workingMergePermissions.append(lease); return url
    }
    let path: String
    private let access: RepositoryAccessLease?
    @Published var document: TextConflictDocument?
    @Published var sourceComparison: MergeSourceComparison? { didSet { inlineCache = [:] } }
    lazy var folding: MergeFoldingController = {
        let value = makeFoldingController()
        value.expanded = { [weak self] _ in self?.synchronizeResultFolding() }
        return value
    }()
    lazy var resultFolding: MergeFoldingController = {
        let value = makeFoldingController()
        value.expanded = { [weak self] range in
            guard let self else { return }
            let mapping = self.resultPresentation.foldAnchors.resultRows(in: self.result)
            for (source, resultRow) in mapping where range.contains(resultRow) { _ = self.folding.reveal(sourceRow: source) }
            self.synchronizeResultFolding()
        }
        return value
    }()
    private func makeFoldingController() -> MergeFoldingController {
        let value = MergeFoldingController(preferences: comparisonDefaults)
        value.geometryChanged = { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } }
        value.actionsAllowed = { [weak self] in self?.retired == false && self?.busy == false && self?.preparing == false && self?.confirmingQuit == false }
        return value
    }
    func setCollapsed(_ value: Bool) {
        guard !retired, !busy, !preparing, !confirmingQuit else { return }
        folding.setCollapsed(value); resultFolding.setCollapsed(value)
    }
    func updateFolding() {
        folding.update(unchanged: sourceComparison?.rows.map { ($0.mine.state == .normal || $0.mine.state == .filtered) && ($0.theirs.state == .normal || $0.theirs.state == .filtered) } ?? [])
        synchronizeResultFolding()
    }
    private func synchronizeResultFolding() {
        let states = resultStates
        let mapping = resultPresentation.foldAnchors.resultRows(in: result)
        var visibility = Array(repeating: MergeFolding.Visibility.shown, count: states.count)
        for (source, row) in mapping where folding.folding.visibility.indices.contains(source) && states.indices.contains(row) {
            if states[row] == .normal || states[row] == .filtered { visibility[row] = folding.folding.visibility[source] }
        }
        // If an edit invalidates the original marker anchor, retain an
        // expandable marker at the start of the surviving hidden result run.
        for row in visibility.indices where visibility[row] == .hidden && (row == 0 || visibility[row - 1] == .shown) { visibility[row] = .marker }
        resultFolding.install(visibility: visibility)
    }
    private(set) var sourceTargets: [Bool: SavedMergePane] = [:]
    func sourceTargetURL(mine: Bool) -> URL? { sourceTargets[mine]?.url }
    func sourceCaption(mine: Bool) -> String? {
        guard sourceTargets[mine] == nil, let titles = document?.conflictTitles else { return nil }
        return mine ? titles.mine.title : titles.theirs.title
    }
    @Published private(set) var exportingSource = false
    lazy var sourceExporter: MergeSourceExport = {
        let value = MergeSourceExport()
        value.stateChanged = { [weak self] in self?.exportingSource = $0 }
        value.failure = { [weak self] in self?.error = $0 }
        return value
    }()
    var sourceToolsAllowed: Bool { !retired && !busy && !preparing && !confirmingQuit && !exportingSource && window?.attachedSheet == nil && document != nil }
    func exportSource(mine: Bool) {
        guard sourceToolsAllowed, let window, let document, let sourceComparison else { return }
        do {
            let encoding = (mine ? document.mineEncoding : document.theirsEncoding) ?? document.encoding
            let bytes = try MergePaneSaveAs.sourceBytes(rows: sourceComparison.rows, mine: mine, encoding: encoding)
            let name = sourceTargets[mine]?.url.lastPathComponent ?? (mine ? "Mine-" : "Theirs-") + (path as NSString).lastPathComponent
            sourceExporter.save(bytes, name: name, owner: window) { [weak self] url, lease in
                guard let self, !self.retired else { return }
                let target = try SavedMergePane(url: url, writtenBytes: bytes, encoding: encoding)
                if let workingMerge = self.workingMerge { try await workingMerge.bindSource(mine: mine, target: target) }
                guard !self.retired else { return }
                self.sourceTargets[mine] = target; self.workingMergePermissions.append(lease)
                let output = self.workingMerge == nil ? self.repository.root.appendingPathComponent(self.path).standardizedFileURL : self.workingMergeOutput
                if output?.standardizedFileURL.path == target.url.path, let current = self.document {
                    self.document = try current.recordingOwnedWorkingWrite(target.content)
                    if self.workingMerge != nil { self.standaloneSavedResult = target.content.text; self.standaloneSavedEncoding = target.content.encoding }
                }
                self.objectWillChange.send()
            }
        } catch { self.error = error.localizedDescription }
    }
    func compareSourceWithBase(mine: Bool) {
        guard sourceToolsAllowed, let document else { return }
        do {
            let base = try (document.baseEncoding ?? document.encoding).encode(document.base)
            let side = try sourceTargets[mine]?.read().bytes ?? ((mine ? document.mineEncoding : document.theirsEncoding) ?? document.encoding).encode(mine ? document.mine : document.theirs)
            try MergeSourceComparisonWindows.open(base: base, side: side, name: path, sideName: mine ? "Mine" : "Theirs", preferences: comparisonDefaults)
        } catch { self.error = error.localizedDescription }
    }
    @Published private(set) var regexFilters = MergeRegexFilters.load()
    @Published private(set) var regexFilterName: String?
    var regexDefaults: UserDefaults = .standard
    var engineConfiguration: SubversionMergeConfiguration?
    @Published private(set) var comparisonOptions = MergeComparisonOptions.load()
    var comparisonDefaults: UserDefaults = .standard
    @Published private(set) var generalPreferences = MergeGeneralPreferences.load()
    @Published private(set) var showInlineDiff = true
    @Published private(set) var inlineWordDiff = false
    private struct InlineRow { let value: MergeInlineComparison? }
    private var inlineCache: [Int: InlineRow] = [:]
    private var inlineCacheWord = false, inlineCacheMaximum = -1
    func setInlineDiff(_ value: Bool) {
        guard !retired, !busy, !confirmingQuit else { return }
        showInlineDiff = value; MergeInlinePresentation.saveEnabled(value, to: comparisonDefaults)
    }
    func setInlineWordDiff(_ value: Bool) {
        guard !retired, !busy, !confirmingQuit, showInlineDiff else { return }
        inlineWordDiff = value; inlineCache = [:]
    }
    func inlineDifference(_ row: Int, mine: Bool) -> MergeInlineComparison? {
        guard !retired, !preparing, showInlineDiff, let rows = sourceComparison?.rows, rows.indices.contains(row) else { return nil }
        let maximum = generalPreferences.maximumInlineLength
        if inlineCacheWord != inlineWordDiff || inlineCacheMaximum != maximum {
            inlineCache = [:]; inlineCacheWord = inlineWordDiff; inlineCacheMaximum = maximum
        }
        let cell = mine ? rows[row].mine : rows[row].theirs, other = mine ? rows[row].theirs : rows[row].mine
        guard !cell.state.isUnchanged, cell.state != .empty, cell.state != .conflictEmpty,
              cell.displayText.utf16.count <= maximum else { return nil }
        if let cached = inlineCache[row] { return cached.value }
        let value = MergeInlinePresentation.comparison(cell: cell, other: other, left: !mine,
                                                       word: inlineWordDiff, maximumLength: maximum)
        inlineCache[row] = InlineRow(value: value); return value
    }

    @Published private(set) var wrapLines = UserDefaults.standard.bool(forKey: "TurtleGitMerge.WrapLines")
    let lineWrapping = MergeLineWrapping()
    func setWrapLines(_ value: Bool) {
        guard !retired, !busy, !confirmingQuit else { return }
        wrapLines = value; comparisonDefaults.set(value, forKey: "TurtleGitMerge.WrapLines")
    }
    @Published private(set) var whitespaceDisplay = MergeWhitespaceDisplayPreferences.load()
    func setWhitespaceDisplay(_ value: MergeWhitespaceDisplayPreferences) {
        guard !busy, !confirmingQuit, !retired else { return }
        whitespaceDisplay = value; value.save(to: comparisonDefaults)
    }
    @Published private(set) var locatorPreferences = MergeLocatorPreferences.load()
    @Published private(set) var locatorViewport = MergeLocatorViewport()
    private weak var locatorResultScroll: NSScrollView?
    @Published private(set) var locatorHighlights = [MergeLocatorHighlights(), .init(), .init()]
    private var locatorHighlightsScheduled = false
    func refreshLocatorHighlights() {
        guard !retired, !locatorHighlightsScheduled else { return }
        locatorHighlightsScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }; self.locatorHighlightsScheduled = false
            guard !self.retired else { return }
            let left = self.sourceScrolls.first { $0.key.hasPrefix("Theirs") }?.value.view
            let right = self.sourceScrolls.first { $0.key.hasPrefix("Mine") }?.value.view
            let next: [MergeLocatorHighlights] = [.read(left), .read(self.locatorResultScroll), .read(right)]
            if self.locatorHighlights != next { self.locatorHighlights = next }
        }
    }
    var locatorMap: MergeLocatorMap {
        let states = resultStates
        return MergeLocatorMap(columns: [sourceComparison?.rows.map { $0.theirs.state } ?? [], states, sourceComparison?.rows.map { $0.mine.state } ?? []])
    }
    func setLocatorPreferences(_ value: MergeLocatorPreferences) {
        guard !retired, !busy, !confirmingQuit else { return }
        locatorPreferences = value; value.save(to: comparisonDefaults)
    }
    func registerLocatorResult(_ scroll: NSScrollView) { locatorResultScroll = scroll }
    func refreshLocatorViewport() {
        let primary = sourceScrolls.first { $0.key.hasPrefix("Theirs") }?.value.view ?? locatorResultScroll
        let value = MergeLocatorScrolling.viewport(primary)
        if value != locatorViewport { locatorViewport = value }
    }
    func scrollLocator(to row: Int) {
        guard !retired, !busy, !confirmingQuit else { return }
        for reference in sourceScrolls.values { if let scroll = reference.view { MergeLocatorScrolling.scroll(scroll, to: row) } }
        if let locatorResultScroll { MergeLocatorScrolling.scroll(locatorResultScroll, to: row) }
        refreshLocatorViewport()
    }
    private var pendingComparisonOptions: MergeComparisonOptions?
    var commentProfileURL = MergeCommentProfileFile.url
    private var commentProfiles = MergeCommentProfiles.bundled()
    var supportsComments: Bool { commentProfiles.tokens(paths: [path]) != nil }
    func setComparisonOptions(_ value: MergeComparisonOptions) {
        guard !busy, !confirmingQuit, !retired else { return }
        pendingComparisonOptions = value; load()
    }
    enum ReloadDecision { case save, discard, cancel }
    var chooseReload: (() -> ReloadDecision)?
    private var loadGeneration = 0
    var navigationGeneration: Int { loadGeneration }
    private(set) var retired = false
    private var loadCancellation: OperationCancellation?
    private var regexList: MergeRegexFilterListController?
    func manageRegexFilters() {
        guard !busy, !confirmingQuit, !retired else { return }
        if let regexList { regexList.showWindow(nil); regexList.window?.makeKeyAndOrderFront(nil); return }
        let controller = MergeRegexFilterListController(defaults: regexDefaults)
        controller.executable = engineConfiguration?.regexExecutable
        controller.onClosed = { [weak self] in self?.regexList = nil; self?.refreshRegexFilters() }
        regexList = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func refreshRegexFilters() {
        guard !retired else { return }
        // Persist definitions without replacing manual edits. The active filter
        // is re-evaluated on the next explicit selection or Reload.
        regexFilters = MergeRegexFilters.load(defaults: regexDefaults)
    }
    func selectRegexFilter(_ name: String?) {
        guard !busy, !confirmingQuit, !retired, name == nil || regexFilters.contains(where: { $0.name == name }) else { return }
        load(filterName: name)
    }
    func retire() {
        sourceExporter.retire()
        folding.retire(); resultFolding.retire()
        lineWrapping.retire()
        retired = true; loadGeneration += 1; loadCancellation?.cancel(); loadCancellation = nil
        regexList?.retire(); regexList = nil
        editorConfigRequests = [:]
    }
    private var savedIgnoredConflicts: [IgnoredMergeConflict] = []
    @Published private(set) var resultPresentation = MergeResultPresentation(text: "", states: [])
    @Published var result = "" { didSet { if !resultPresentation.text.utf8.elementsEqual(result.utf8) { resultPresentation = resultPresentation.reconciling(result) } } }
    var resultStates: [MergeSourceState] { resultPresentation.states(conflicts: blocks.map(\.range)) }
    func updateResultPresentation(_ value: MergeResultPresentation) { resultPresentation = value }

    @Published var encoding: ComparisonTextEncoding = .utf8
    @Published var selectedConflict = 0
    @Published var caret = NSRange(location: 0, length: 0)
    @Published var selectionRequest: NSRange?
    @Published var busy = false
    @Published private(set) var preparing = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var nativeToolbarInstalled = false
    @Published var showBase = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var tabWidths: [String: Int] = [:]
    @Published var spacePanes: [String: Bool] = [:]
    @Published var smartTabPanes: [String: Bool] = [:]
    @Published var editorPreferences = MergeEditorPreferences.load()
    @Published var editorConfigEnabled: [String: Bool] = [:]
    @Published var editorConfigLoaded: [String: Bool] = [:]
    @Published var editorConfigLoading: Set<String> = []
    private var editorConfigRequests: [String: UUID] = [:]
    private let initialEditorConfigDefault = MergeEditorPreferences.load().enableEditorConfig
    func setEditorConfig(_ enabled: Bool, pane: String) {
        guard document != nil, !confirmingQuit else { return }
        let request = UUID(); editorConfigRequests[pane] = request
        editorConfigEnabled[pane] = enabled; editorConfigLoaded[pane] = false
        tabWidths[pane] = editorPreferences.tabWidth
        spacePanes[pane] = editorPreferences.useSpaces
        smartTabPanes[pane] = editorPreferences.smartTab
        editorConfigLoading.remove(pane)
        guard enabled else { return }
        editorConfigLoading.insert(pane)
        let file = repository.root.appendingPathComponent(path)
        Task {
            let resolved = await Task.detached { Result { try EditorConfigRuntime.resolve(file: file) } }.value
            guard editorConfigRequests[pane] == request else { return }
            editorConfigLoading.remove(pane)
            switch resolved {
            case .success(let values):
                editorConfigLoaded[pane] = values.loaded
                let settings = values.applying(to: editorPreferences)
                tabWidths[pane] = settings.tabWidth; spacePanes[pane] = settings.useSpaces
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    private func reloadEditorConfig() {
        guard let document else { return }
        let panes = ["Base", document.mineStage == 3 ? "Mine — Branch being rebased" : "Mine",
                     document.theirsStage == 2 ? "Theirs — Branch being rebased onto" : "Theirs", "Merged · \(path)"]
        for pane in panes {
            if editorConfigEnabled[pane] == nil { editorConfigEnabled[pane] = initialEditorConfigDefault }
            if editorConfigEnabled[pane] == true { setEditorConfig(true, pane: pane) }
        }
    }

    private var preferencesSubscription: AnyCancellable?
    var applyBlock: ((NSRange, String) -> Void)?
    var replaceEntireResult: ((String) -> Void)?
    var replaceEntireResolvedResult: ((String) -> Void)?
    var resetHistory: () -> Void = {}
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    private var sourceScrolls: [String: WeakMergeScroll] = [:]
    private var synchronizingScroll = false
    func registerSourceScroll(_ scroll: NSScrollView, label: String) { sourceScrolls[label] = WeakMergeScroll(scroll); refreshLocatorViewport() }
    func sourceDidScroll(_ scroll: NSScrollView) {
        defer { refreshLocatorViewport() }
        guard !synchronizingScroll else { return }
        synchronizingScroll = true; defer { synchronizingScroll = false }
        for reference in sourceScrolls.values {
            guard let peer = reference.view, peer !== scroll else { continue }
            let clip = peer.contentView
            let desired = NSRect(origin: NSPoint(x: clip.bounds.minX, y: scroll.contentView.bounds.minY), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(desired).origin); peer.reflectScrolledClipView(clip)
            peer.verticalRulerView?.needsDisplay = true
        }
    }
    var blocks: [MergeConflictBlock] { resultPresentation.conflicts(document: document) }
    var hasUnresolvedConflicts: Bool { !blocks.isEmpty || MergeText.hasMarkers(result) }
    var confirmUnresolvedSave: (String) -> Bool = { message in
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = message
        alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Save")
        return alert.runModal() == .alertSecondButtonReturn
    }
    var dirty: Bool {
        document.map { document in
            let previous: String
            if workingMerge == nil { previous = document.initialResult }
            else if workingMergeOutput != nil { previous = standaloneSavedResult ?? document.initialResult }
            else { previous = document.workingContents.flatMap { document.encoding.decode($0) } ?? "" }
            return !result.utf8.elementsEqual(previous.utf8) || resultPresentation.ignoredConflicts != savedIgnoredConflicts || encoding != (workingMergeOutput != nil ? standaloneSavedEncoding ?? document.encoding : document.encoding)
        } ?? false
    }
    private var formatPending = false
    var chooseFormat: (NSWindow, String, MergeFormatSelection) async -> MergeFormatSelection? = MergeFormatPrompt.choose
    func showFormatDialog() {
        guard !formatPending, !busy, !confirmingQuit, !retired, let document, let window, window.attachedSheet == nil else { return }
        let original = result, originalEncoding = encoding, generation = loadGeneration
        formatPending = true
        Task {
            defer { formatPending = false }
            guard let choice = await chooseFormat(window,"Merged",.initial(encoding:originalEncoding,text:original)),
                  generation == loadGeneration, !busy, !confirmingQuit, !retired, result.utf8.elementsEqual(original.utf8), encoding == originalEncoding, self.document?.entry == document.entry else { return }
            do {
                let converted = try choice.applying(to:original)
                if !converted.utf8.elementsEqual(original.utf8) {
                    if let replaceEntireResult { replaceEntireResult(converted) } else { result = converted }
                }
                encoding = choice.encoding
            } catch { self.error = error.localizedDescription }
        }
    }
    func changeEncoding(_ value: ComparisonTextEncoding) {
        guard !busy, !confirmingQuit, document != nil else { return }
        do { _ = try value.encode(result); encoding = value }
        catch { self.error = error.localizedDescription }
    }
    func changeLineEnding(_ value: MergeLineEnding) {
        guard !busy, !confirmingQuit, document != nil else { return }
        let converted = MergeLineEndings.converting(result, to: value)
        guard !converted.utf8.elementsEqual(result.utf8) else { return }
        if let replaceEntireResult { replaceEntireResult(converted) } else { result = converted }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        self.repository = repository; self.access = access; self.path = path
        preferencesSubscription = NotificationCenter.default.publisher(for: .mergeEditorPreferencesChanged).sink { [weak self] _ in
            guard let self else { return }
            let next = MergeEditorPreferences.load()
            self.locatorPreferences = .load(from: self.comparisonDefaults)
            self.wrapLines = self.comparisonDefaults.bool(forKey: "TurtleGitMerge.WrapLines")
            self.whitespaceDisplay = .load(from: self.comparisonDefaults)
            self.generalPreferences = .load(from: self.comparisonDefaults)
            self.showInlineDiff = MergeInlinePresentation.defaultEnabled(from: self.comparisonDefaults)
            if next.tabWidth != self.editorPreferences.tabWidth || next.useSpaces != self.editorPreferences.useSpaces || next.smartTab != self.editorPreferences.smartTab {
                self.tabWidths = [:]; self.spacePanes = [:]; self.smartTabPanes = [:]
                self.editorPreferences = next
                self.reloadEditorConfig()
            } else { self.editorPreferences = next }
        }
    }
    var initialLoadDeferred = false
    func beginTransferredDocument() { initialLoadDeferred = false; load() }
    func load() { guard !initialLoadDeferred else { return }; load(filterName: regexFilterName) }
    private func load(filterName: String?) {
        guard !busy, !confirmingQuit, !retired, window?.attachedSheet == nil else { return }
        if dirty {
            let decision: ReloadDecision
            if let chooseReload { decision = chooseReload() }
            else {
                let alert = NSAlert(); alert.messageText = "Save changes to “\(path)” before reloading?"
                alert.informativeText = "Reload regenerates the merged result from the current conflict stages."
                alert.addButton(withTitle: "Save and Reload"); alert.addButton(withTitle: "Reload Without Saving"); alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: decision = .save
                case .alertSecondButtonReturn: decision = .discard
                default: decision = .cancel
                }
            }
            switch decision {
            case .save: save(markResolved: false) { [weak self] saved in if saved { self?.load(filterName: filterName) } else { self?.pendingComparisonOptions = nil } }; return
            case .discard: break
            case .cancel: pendingComparisonOptions = nil; return
            }
        }
        busy = true; preparing = true
        loadGeneration += 1; let generation = loadGeneration, token = OperationCancellation()
        loadCancellation = token; MergeRegexOperations.activeRequests += 1
        Task {
            defer { busy = false; preparing = false; loadCancellation = nil; MergeRegexOperations.activeRequests -= 1 }
            do {
                try await reloadDocument(filterName: filterName, cancellation: token, generation: generation)
            } catch { if !retired, loadGeneration == generation { pendingComparisonOptions = nil; self.error = error.localizedDescription } }
        }
    }
    private func reloadDocument(filterName: String?, cancellation: OperationCancellation? = nil, generation: Int? = nil) async throws {
        let requested = filterName
        let filter = regexFilters.first { $0.name == requested }
        var engine = try engineConfiguration ?? SubversionMergeConfiguration.bundled(filter: filter)
        let changingOptions = pendingComparisonOptions != nil
        let options = pendingComparisonOptions ?? MergeComparisonOptions.load(from: comparisonDefaults)
        let profiles = try MergeCommentProfileFile.load(at: commentProfileURL)
        engine.filter = filter; engine.options = options; engine.commentTokens = profiles.tokens(paths: [path])
        var next: TextConflictDocument
        if let workingMerge {
            if GitRuntime.isAppStoreBuild {
                for url in [workingMerge.baseURL, workingMerge.theirsURL, workingMerge.mineURL] {
                    guard workingMergePermissions.contains(where: { $0.hasSecurityScope && $0.contains(url) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
            }
            next = try await workingMerge.read(engine: engine, mergePreferUTF8: ComparisonTextEncoding.preferUTF8(from: comparisonDefaults), cancellation: cancellation)
        }
        else { next = try await repository.textConflictDocument(path: path, engine: engine, mergePreferUTF8: ComparisonTextEncoding.preferUTF8(from: comparisonDefaults), identityOptions: ConflictIdentityOptions(defaults: comparisonDefaults), cancellation: cancellation) }
        if workingMerge == nil, !sourceTargets.isEmpty {
            next = try next.replacingSources(mine: sourceTargets[true]?.read(), theirs: sourceTargets[false]?.read(), engine: engine, cancellation: cancellation)
        }
        for (mine, target) in sourceTargets { sourceTargets[mine] = try target.recording(target.read()) }
        guard !retired, generation == nil || generation == loadGeneration else { return }
        guard let comparison = next.mergeSources else { throw SubversionMergeDiffFailure.invalidOutput }
        resetHistory()
        document = next; sourceComparison = comparison; resultPresentation = MergeResultPresentation(text: next.generatedResult, states: comparison.resultLocator?.states ?? [], foldAnchors: .init(offsets: comparison.resultAnchors), ignoredConflicts: comparison.ignoredConflicts, navigationMap: comparison.navigationMap).reconciling(next.initialResult); result = next.initialResult; encoding = next.encoding
        savedIgnoredConflicts = resultPresentation.ignoredConflicts
        commentProfiles = profiles
        comparisonOptions = options; if changingOptions { options.save(to: comparisonDefaults) }; pendingComparisonOptions = nil
        regexFilterName = filter?.name
        navigationOwnsChoice = false; navigationChoiceRange = nil
        selectedConflict = 0; caret = NSRange(location: 0, length: 0); selectionRequest = nil
        wrapLines = comparisonDefaults.bool(forKey: "TurtleGitMerge.WrapLines")
        generalPreferences = .load(from: comparisonDefaults)
        showInlineDiff = MergeInlinePresentation.defaultEnabled(from: comparisonDefaults)
        let ranges = MergeLineEndings.lineRanges(in: result)
        let firstChanged = comparison.resultLocator?.states.firstIndex { $0 != .normal && $0 != .filtered && $0 != .empty }
        let difference = firstChanged.flatMap { ranges.indices.contains($0) ? ranges[$0] : nil }
        selectionRequest = generalPreferences.initialTarget(difference: difference, conflict: blocks.first?.range)
        reloadEditorConfig()
    }
    private weak var lastNavigationView: MergeTextView?
    private(set) var selectingNavigationBlock = false
    private var navigationOwnsChoice = false
    private var navigationChoiceRange: NSRange?
    private var navigationViews: [MergeTextView] {
        var views = sourceScrolls.values.compactMap { $0.view?.documentView as? MergeTextView }.filter { $0.sourceSide != nil }
        if let result = locatorResultScroll?.documentView as? MergeTextView { views.append(result) }
        return views
    }
    func clearNavigationBlockSelection() {
        for view in navigationViews { view.blockSelection.clear(in:view) }
        navigationOwnsChoice = true; navigationChoiceRange = nil
    }
    private var activeNavigationView: MergeTextView? {
        if let view = window?.firstResponder as? MergeTextView {
            return view.mergeEditable || view.sourceSide != nil ? view : nil
        }
        return lastNavigationView ?? locatorResultScroll?.documentView as? MergeTextView
    }
    fileprivate func focusNavigation(_ view: MergeTextView) {
        guard view.mergeEditable || view.sourceSide != nil else { return }
        lastNavigationView = view; objectWillChange.send()
    }
    private func navigationStates(_ view: MergeTextView) -> [MergeSourceState] {
        if let side = view.sourceSide {
            return sourceComparison?.rows.map { side == .mine ? $0.mine.state : $0.theirs.state } ?? []
        }
        return view.mergeEditable ? resultStates : []
    }
    private func navigationRanges(_ view: MergeTextView) -> [NSRange] {
        if let cells = view.sourceCells {
            var offset = 0
            return cells.map { cell in
                defer { offset += cell.displayText.utf16.count + 1 }
                return NSRange(location:offset,length:cell.displayText.utf16.count)
            }
        }
        return MergeSourceComparison.navigationRanges(text:view.string)
    }
    private func navigationRow(_ view: MergeTextView, ranges: [NSRange]) -> Int {
        return ranges.lastIndex(where: { $0.location <= view.selectedRange().location }) ?? 0
    }
    private func navigationTarget(_ direction: Int, conflictsOnly: Bool) -> (MergeTextView, MergeBlockNavigation.Target)? {
        guard sourceToolsAllowed, let view = activeNavigationView else { return nil }
        let states = navigationStates(view), ranges = navigationRanges(view)
        guard ranges.count == states.count else { return nil }
        let projection = view.mergeEditable ? resultFolding.projection : folding.projection
        return MergeBlockNavigation.target(states:states,visibleRows:projection.rows.map(\.sourceRow),
            caret:navigationRow(view,ranges:ranges),direction:direction,conflictsOnly:conflictsOnly).map { (view,$0) }
    }
    func canNavigateBlock(_ direction: Int, conflictsOnly: Bool) -> Bool { navigationTarget(direction,conflictsOnly:conflictsOnly) != nil }
    private func navigationRange(rows: Range<Int>, in view: MergeTextView) -> NSRange? {
        let ranges = navigationRanges(view)
        guard ranges.indices.contains(rows.lowerBound), ranges.indices.contains(rows.upperBound - 1) else { return nil }
        return NSRange(location:ranges[rows.lowerBound].location,length:NSMaxRange(ranges[rows.upperBound - 1]) - ranges[rows.lowerBound].location)
    }
    fileprivate func navigationSelectionChanged(_ view: MergeTextView) {
        guard !retired, !selectingNavigationBlock, window?.firstResponder === view else { return }
        if view.mergeEditable { caret = view.selectedRange() }
        let selected = view.mergeSelectedBlockRange ?? view.selectedRange()
        if view.mergeSelectedBlockRange == nil {
            for peer in navigationViews { peer.blockSelection.clear(in:peer) }
        }
        let mapped: NSRange?
        if view.mergeEditable { mapped = selected }
        else if view.sourceSide != nil {
            let ranges = navigationRanges(view), selection = selected
            let start = ranges.lastIndex(where: { $0.location <= selection.location }) ?? 0
            let end = ranges.lastIndex(where: { $0.location <= NSMaxRange(selection) }) ?? start
            mapped = resultPresentation.navigationMap.resultRange(sourceRows:start..<(end + 1))
        } else { return }
        navigationOwnsChoice = true; navigationChoiceRange = mapped
        if let index = conflictIndex(in:mapped) { selectedConflict = index }
        objectWillChange.send()
    }
    private func conflictIndex(in range: NSRange?) -> Int? {
        guard let range else { return nil }
        return blocks.firstIndex { NSIntersectionRange($0.range,range).length > 0 || range.length == 0 && NSLocationInRange(range.location,$0.range) }
    }
    var canChooseConflict: Bool { !blocks.isEmpty && (!navigationOwnsChoice || conflictIndex(in:navigationChoiceRange) != nil) }
    func navigateBlock(_ direction: Int, conflictsOnly: Bool) {
        guard let (active,target) = navigationTarget(direction,conflictsOnly:conflictsOnly),
              let activeRange = navigationRange(rows:target.rows,in:active) else { return }
        selectionRequest = nil
        selectingNavigationBlock = true; defer { selectingNavigationBlock = false }
        let sourceRows = active.mergeEditable ? resultPresentation.navigationMap.sourceRows(resultRange:activeRange) : target.rows
        let resultRange = active.mergeEditable ? activeRange : resultPresentation.navigationMap.resultRange(sourceRows:target.rows)
        for view in navigationViews {
            let range: NSRange?
            if view === active { range = activeRange }
            else if view.mergeEditable { range = resultRange }
            else { range = sourceRows.flatMap { navigationRange(rows:$0,in:view) } }
            guard let range, NSMaxRange(range) <= view.string.utf16.count else {
                view.setSelectedRange(NSRange(location:min(view.selectedRange().location,view.string.utf16.count),length:0))
                view.blockSelection.clear(in:view); continue
            }
            let ranges = navigationRanges(view)
            let row = view === active ? target.caret : ranges.lastIndex(where: { $0.location <= range.location }) ?? 0
            if ranges.indices.contains(row) {
                view.installBlock(range,caret:ranges[row].location,trimFinalEnding:view.mergeEditable && view !== active)
                view.blockSelection.centerCaret(in:view)
            }
        }
        navigationOwnsChoice = true; navigationChoiceRange = resultRange
        if let index = conflictIndex(in:resultRange) { selectedConflict = index }
        if let view = locatorResultScroll?.documentView as? NSTextView { caret = view.selectedRange() }
        objectWillChange.send()
    }
    func continueResolving() {
        guard sourceToolsAllowed, let block = blocks.first else { return }
        selectConflict(0)
        if let view = locatorResultScroll?.documentView as? NSTextView {
            window?.makeFirstResponder(view)
            if let view = view as? MergeTextView, NSMaxRange(block.range) <= view.string.utf16.count {
                view.installBlock(block.range,caret:block.range.location,trimFinalEnding:true)
                view.blockSelection.centerCaret(in:view)
            }
        }
    }
    func selectConflict(_ index: Int) {
        let blocks = blocks; guard !retired, !blocks.isEmpty else { return }
        navigationOwnsChoice = false; navigationChoiceRange = nil
        selectedConflict = min(max(index, 0), blocks.count - 1); selectionRequest = blocks[selectedConflict].range
    }
    func choose(_ choice: MergeBlockChoice) {
        guard sourceToolsAllowed, canChooseConflict else { return }
        let index = navigationOwnsChoice ? conflictIndex(in:navigationChoiceRange)! : min(selectedConflict, blocks.count - 1)
        do {
            if let applyBlock { let block = blocks[index]; applyBlock(block.range, block.replacement(choice)) }
            else { let block = blocks[index], replacement = block.replacement(choice); if let presentation = resultPresentation.replacing(block.range, with: replacement, state: .resolved) { resultPresentation = presentation; result = presentation.text } }
            selectConflict(index)
        }
        catch { self.error = error.localizedDescription }
    }
    fileprivate func useFile(_ side: MergeSourceSide) {
        guard !busy, !confirmingQuit, let document else { return }
        let contents = side == .mine ? document.mine : document.theirs
        if let replaceEntireResolvedResult { replaceEntireResolvedResult(contents) }
        else { resultPresentation = MergeResultPresentation(text: contents, states: MergeLineEndings.lineRanges(in: contents).map { _ in .resolved }); result = contents }
        selectedConflict = 0
    }
    var chooseEmptyResult: ((String) async -> MergeEmptyResult)?
    weak var window: NSWindow?
    func saveForQuit(completion: @escaping (Bool) -> Void) {
        guard confirmingQuit else { completion(false); return }
        save(markResolved: false, quitApproved: true, completion: completion)
    }
    func save(markResolved: Bool, closeAfter: Bool = false, reloadAfter: Bool = false, chooseNewOutput: Bool = false, quitApproved: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !busy, (!confirmingQuit || quitApproved), !retired, !markResolved || workingMerge == nil && !hasUnresolvedConflicts, window?.attachedSheet == nil, let document else { completion?(false); return }
        if !markResolved && hasUnresolvedConflicts {
            let message = resultPresentation.ignoredConflicts.isEmpty ? "Save with unresolved conflict markers?" : "Save with unresolved conflicts ignored by comparison options?"
            let warningText = result
            busy = true; MergeRegexOperations.activeRequests += 1
            let accepted = confirmUnresolvedSave(message)
            busy = false; MergeRegexOperations.activeRequests -= 1
            guard accepted, !retired, result.utf8.elementsEqual(warningText.utf8) else { completion?(false); return }
        }
        let text = result, outputEncoding = encoding, ignoredResolved = resultPresentation.ignoredConflicts.isEmpty, ignoredSnapshot = resultPresentation.ignoredConflicts; busy = true
        loadCancellation = OperationCancellation(); MergeRegexOperations.activeRequests += 1
        Task {
            var saved = false
            defer { busy = false; loadCancellation = nil; MergeRegexOperations.activeRequests -= 1; completion?(saved) }
            do {
                let standaloneOutput: URL?
                if workingMerge != nil {
                    if let workingMergeOutput, !chooseNewOutput { standaloneOutput = workingMergeOutput }
                    else { standaloneOutput = await chooseMergeOutput() }
                    guard !retired, standaloneOutput != nil else { return }
                } else { standaloneOutput = nil }
                for target in sourceTargets.values { try target.validate() }
                if workingMerge == nil && GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let choice: MergeEmptyResult
                if text.isEmpty {
                    if let chooseEmptyResult { choice = await chooseEmptyResult(path) }
                    else { choice = await MergeEmptyResultPrompt.choose(window: window, path: path) }
                }
                else { choice = .keep }
                let options = MergeFileSaveOptions(backupOriginal: MergeFileSaveOptions.backupEnabled(from: comparisonDefaults), emptyResult: choice)
                if let workingMerge {
                    if GitRuntime.isAppStoreBuild {
                        let target = standaloneOutput!
                        guard workingMergePermissions.contains(where: { $0.hasSecurityScope && $0.contains(target) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    }
                    self.document = try await workingMerge.saveTo(standaloneOutput!, document: document, result: text, encoding: outputEncoding, options: options)
                    workingMergeOutput = standaloneOutput; standaloneSavedResult = text; standaloneSavedEncoding = outputEncoding
                    window?.title = standaloneOutput!.lastPathComponent + " – TurtleGitMerge"
                } else {
                    self.document = try await repository.saveTextConflict(document, result: text, markResolved: markResolved, encoding: outputEncoding, options: options, ignoredConflictsResolved: ignoredResolved)
                }
                savedIgnoredConflicts = ignoredSnapshot
                onChanged(markResolved ? "Resolved: " + path : "Saved merged result: " + (workingMergeOutput?.path ?? path))
                if markResolved || closeAfter { close() }
                else if reloadAfter { try await reloadDocument(filterName: regexFilterName, cancellation: loadCancellation) }
                saved = true
            } catch let failure as TextConflictSaveFailure {
                self.document = failure.savedDocument; self.error = failure.localizedDescription; onChanged(failure.localizedDescription)
            } catch { self.error = error.localizedDescription }
        }
    }
    func export() {
        guard sourceToolsAllowed, let window else { return }
        if workingMerge != nil { save(markResolved: false, chooseNewOutput: true); return }
        do { sourceExporter.save(try encoding.encode(result), name: (path as NSString).lastPathComponent, owner: window, warning: hasUnresolvedConflicts ? "Save with unresolved conflicts?" : nil) }
        catch { self.error = error.localizedDescription }
    }

}
@MainActor private final class WeakMergeScroll {
    weak var view: NSScrollView?
    init(_ view: NSScrollView) { self.view = view }
}
enum MergePalette {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock(); var value = MergeColorPreferences.load(); var revision = 0
        var applied = UserDefaults.standard.data(forKey:"TurtleGitMerge.Colors") != nil
        func snapshot() -> (MergeColorPreferences, Int, Bool) { lock.lock(); defer { lock.unlock() }; return (value, revision, applied) }
        func replace(_ value: MergeColorPreferences, applied: Bool) { lock.lock(); defer { lock.unlock() }; self.value = value; self.applied = applied; revision += 1 }
    }
    private static let storage = Storage()
    static var revision: Int { storage.snapshot().1 }
    static func reload(defaults: UserDefaults = .standard) { storage.replace(.load(from: defaults),applied:defaults.data(forKey:"TurtleGitMerge.Colors") != nil) }
    static func role(_ state: MergeSourceState) -> MergeColorRole {
        state.colorRole
    }
    static func roleColor(_ role: MergeColorRole, foreground: Bool = false) -> NSColor {
        let palette = storage.snapshot().0
        return NSColor(name: nil) { appearance in
            let color = palette.colors(role, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            let rgb = foreground ? color.foreground : color.background
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
    private static func stateColor(_ state: MergeSourceState, foreground: Bool) -> NSColor {
        let (palette,_,applied)=storage.snapshot()
        return NSColor(name:nil) { appearance in
            let color=palette.stateColors(state,dark:appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,applied:applied)
            let rgb=foreground ? color.foreground:color.background
            return NSColor(srgbRed:CGFloat((rgb >> 16) & 255)/255,green:CGFloat((rgb >> 8) & 255)/255,blue:CGFloat(rgb & 255)/255,alpha:1)
        }
    }
    static func color(_ state: MergeSourceState) -> NSColor {stateColor(state,foreground:false)}
    static func foreground(_ state: MergeSourceState) -> NSColor {stateColor(state,foreground:true)}
    static var inlineCommon: NSColor { roleColor(.modified) }
    static var inlineAdded: NSColor { roleColor(.inlineAdded) }
    static var inlineRemoved: NSColor { roleColor(.inlineRemoved) }
    static var whitespace: NSColor { roleColor(.whitespace, foreground: true) }
}

private struct TextConflictDialog: View {
    @ObservedObject var model: TextConflictWindowModel
    func pane(_ title: String, text: String, caption: String? = nil, editable: Bool = false, cells: [MergeSourceCell]? = nil, side: MergeSourceSide? = nil) -> some View {
        let displayed = cells.map { $0.map(\.displayText).joined(separator: "\n") + ($0.isEmpty ? "" : "\n") } ?? text
        let tabWidth = model.tabWidths[title] ?? model.editorPreferences.tabWidth
        let useSpaces = model.spacePanes[title] ?? model.editorPreferences.useSpaces
        let smartTab = model.smartTabPanes[title] ?? model.editorPreferences.smartTab
        let encoding = editable ? model.encoding : (side == .mine ? model.document?.mineEncoding : side == .theirs ? model.document?.theirsEncoding : model.document?.baseEncoding)
        return VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                if let caption { Text(caption).font(.caption).lineLimit(1).help(caption).textSelection(.enabled) }
                if let side, let url = model.sourceTargetURL(mine: side == .mine) { Text(url.lastPathComponent).font(.caption).lineLimit(1).help(url.path) }
                Spacer(); if editable { Text(model.dirty ? "Modified" : "").font(.caption).foregroundStyle(.secondary) } }.padding(7).background(Color(nsColor: .controlBackgroundColor))
            MergeEditor(model: model, text: displayed, label: title, editable: editable, sourceCells: cells, sourceSide: side, tabWidth: tabWidth, useSpaces: useSpaces, smartTab: smartTab).frame(minWidth: 220, minHeight: 120)
            let counts=MergeLineStatistics(states:cells?.map(\.state) ?? model.resultStates)
            if !counts.isEmpty {MergeLineStatisticsView(statistics:counts).padding(.horizontal,7).padding(.vertical,2)}
            HStack {
                MergeFormatControls(label: title, encoding: encoding, text: text, editable: editable && !model.busy && !model.confirmingQuit, changeEncoding: model.changeEncoding, changeEnding: model.changeLineEnding, showFormatDialog:model.showFormatDialog)
                Spacer()
                MergeTabControls(label: title, tabWidth: tabWidth, useSpaces: useSpaces, smartTab: smartTab, changeWidth: { model.tabWidths[title] = $0 }, changeSpaces: { model.spacePanes[title] = $0 }, changeSmart: { model.smartTabPanes[title] = $0 }, editorConfigEnabled: model.editorConfigEnabled[title] == true, editorConfigLoaded: model.editorConfigLoaded[title] == true, changeEditorConfig: { model.setEditorConfig($0, pane: title) }).disabled(model.busy || model.confirmingQuit || model.editorConfigLoading.contains(title))
            }.padding(.horizontal, 7).padding(.vertical, 3).background(Color(nsColor: .controlBackgroundColor))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if !model.nativeToolbarInstalled {
            HStack(spacing: 10) {
                Button { model.save(markResolved: false) } label: { CommandLabel(title: "Save", icon: .mergeSave) }.keyboardShortcut("s", modifiers: .command)
                Button { model.save(markResolved: true) } label: { CommandLabel(title: "Mark as resolved", icon: .mergeResolved) }.disabled(model.workingMerge != nil || model.document == nil || model.hasUnresolvedConflicts)
                Menu {
                    Button { model.exportSource(mine: false) } label: { CommandLabel(title: "Save left pane as…", icon: .mergeSaveAs) }
                    Button { model.exportSource(mine: true) } label: { CommandLabel(title: "Save right pane as…", icon: .mergeSaveAs) }
                    Button { model.export() } label: { CommandLabel(title: "Save merged result as…", icon: .mergeSaveAs) }
                    if !model.blocks.isEmpty { Button { model.continueResolving() } label: { CommandLabel(title: "Continue resolving conflicts", icon: .mergeNextConflict) } }
                } label: { CommandLabel(title: "Save As…", icon: .mergeSaveAs) }.disabled(!model.sourceToolsAllowed)
                Menu("Compare sources") {
                    Button { model.compareSourceWithBase(mine: false) } label: { CommandLabel(title: "Compare Theirs with Base", icon: .compare) }
                    Button { model.compareSourceWithBase(mine: true) } label: { CommandLabel(title: "Compare Mine with Base", icon: .compare) }
                }.disabled(!model.sourceToolsAllowed)
                Divider().frame(height: 20)
                Button { model.navigateBlock(-1,conflictsOnly:false) } label: { CommandLabel(title: "Previous difference", icon: .mergePreviousDifference) }.disabled(!model.canNavigateBlock(-1,conflictsOnly:false))
                Button { model.navigateBlock(1,conflictsOnly:false) } label: { CommandLabel(title: "Next difference", icon: .mergeNextDifference) }.disabled(!model.canNavigateBlock(1,conflictsOnly:false))
                Button { model.navigateBlock(-1,conflictsOnly:true) } label: { CommandLabel(title: "Previous conflict", icon: .mergePreviousConflict) }.disabled(!model.canNavigateBlock(-1,conflictsOnly:true))
                Button { model.navigateBlock(1,conflictsOnly:true) } label: { CommandLabel(title: "Next conflict", icon: .mergeNextConflict) }.disabled(!model.canNavigateBlock(1,conflictsOnly:true))
                Toggle("Show Base", isOn: $model.showBase).toggleStyle(.button)
                Button { model.load() } label: { CommandLabel(title: "Reload", icon: .mergeReload) }.help("Reload the current conflict stages; offer to save an edited result first.")

                Spacer()
                Button { TurtleGitHelp.show(.resolve) } label: { CommandLabel(title: "Help", icon: .help) }
            }.padding(9)
            }
            HStack {
                MergeViewControls(preferences: model.locatorPreferences, apply: model.setLocatorPreferences, whitespace: model.whitespaceDisplay, applyWhitespace: model.setWhitespaceDisplay, wrapLines: model.wrapLines, applyWrap: model.setWrapLines, collapsed: model.folding.collapsed, applyCollapsed: model.setCollapsed)
                MergeInlineControls(enabled: model.showInlineDiff, word: model.inlineWordDiff, applyEnabled: model.setInlineDiff, applyWord: model.setInlineWordDiff).disabled(model.busy || model.confirmingQuit || model.sourceComparison == nil)
                MergeComparisonControls(options: model.comparisonOptions, apply: model.setComparisonOptions, supportsComments: model.supportsComments)
                Menu("Regex Filter: " + (model.regexFilterName ?? "No Filter")) {
                    Button { model.selectRegexFilter(nil) } label: {
                        if model.regexFilterName == nil { Label("No Filter", systemImage: "checkmark") } else { Text("No Filter") }
                    }
                    ForEach(model.regexFilters) { filter in
                        Button { model.selectRegexFilter(filter.name) } label: {
                            if model.regexFilterName == filter.name { Label(filter.name, systemImage: "checkmark") } else { Text(filter.name) }
                        }
                    }
                    Divider(); Button("Edit Filters…") { model.manageRegexFilters() }
                }.fixedSize()
                Spacer()
            }.padding(.horizontal, 10).padding(.bottom, 6)
            if let document = model.document {
                HStack(spacing: 0) {
                    if model.locatorPreferences.visible {
                        MergeLocatorBar(map: model.locatorMap, viewport: model.locatorViewport, highlights: model.locatorHighlights, fishEye: model.locatorPreferences.fishEye,
                                        enabled: !model.busy && !model.confirmingQuit, navigate: model.scrollLocator)
                            .frame(width: 44).help("Theirs, merged result, and Mine overview; click or drag to scroll")
                    }
                    VSplitView {
                    HSplitView {
                        pane(document.theirsStage == 2 ? "Theirs — Branch being rebased onto" : "Theirs", text: document.theirs, caption: model.sourceCaption(mine: false), cells: model.sourceComparison?.rows.map(\.theirs), side: .theirs)
                        pane(document.mineStage == 3 ? "Mine — Branch being rebased" : "Mine", text: document.mine, caption: model.sourceCaption(mine: true), cells: model.sourceComparison?.rows.map(\.mine), side: .mine)
                        if model.showBase { pane("Base", text: document.base) }
                    }
                    pane("Merged · \(model.path)", text: model.result, editable: true)
                    }
                }
                HStack {
                    Text(model.blocks.isEmpty ? (MergeText.hasMarkers(model.result) ? "Incomplete conflict markers" : "No remaining conflicts") : "\(model.blocks[min(model.selectedConflict,model.blocks.count - 1)].isIgnored ? "Ignored conflict" : "Conflict") \(min(model.selectedConflict + 1, model.blocks.count)) of \(model.blocks.count)").foregroundStyle(model.blocks.isEmpty ? Color.secondary : .red)
                    Spacer()
                    Button { model.undo() } label: { CommandLabel(title: "Undo", icon: .mergeUndo) }.keyboardShortcut("z", modifiers: .command).disabled(!model.canUndo)
                    Button { model.redo() } label: { CommandLabel(title: "Redo", icon: .mergeRedo) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
                    Menu("Use text block") {
                        ForEach(MergeBlockChoice.allCases, id: \.self) { choice in Button { model.choose(choice) } label: { CommandLabel(title: choice.rawValue, icon: choice.icon) } }
                    }.disabled(!model.canChooseConflict)
                    Text("Line \(MergeLineEndings.lineNumber(in: model.result, utf16Offset: model.caret.location))").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.disabled(model.busy || model.confirmingQuit).onAppear { model.load() }
        .alert("Merge editor operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .mergeRegexFiltersChanged)) { _ in model.refreshRegexFilters() }
    }
}
private struct MergeEditor: NSViewRepresentable {
    @ObservedObject var model: TextConflictWindowModel
    let text: String
    let label: String
    let editable: Bool
    let sourceCells: [MergeSourceCell]?
    let sourceSide: MergeSourceSide?
    let tabWidth: Int
    let useSpaces: Bool
    let smartTab: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let view = MergeTextView(); view.isRichText = false; view.allowsUndo = editable
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false
        view.font = model.generalPreferences.nativeFont; view.textContainerInset = NSSize(width: 8, height: 8)
        view.setMergeTabWidth(tabWidth)
        view.mergeUseSpaces = useSpaces; view.mergeSmartTab = smartTab
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true; view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false; view.textContainer?.containerSize = view.maxSize
        view.setAccessibilityLabel(label); view.delegate = context.coordinator; view.model = model; view.mergeEditable = editable
        view.sourceSide = sourceSide
        if editable {
            model.undo = { [weak view] in view?.undoMergeEdit() }
            model.redo = { [weak view] in view?.redoMergeEdit() }
            model.resetHistory = { [weak view] in view?.resetMergeHistory() }
            model.replaceEntireResult = { [weak view] value in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
                view.replaceMergeBlock(NSRange(location: 0, length: (view.string as NSString).length), with: value, actionName: "Edit result")
            }
            model.replaceEntireResolvedResult = { [weak view] value in
                guard let view else { return }; view.window?.makeFirstResponder(view)
                view.replaceMergeBlock(NSRange(location: 0, length: (view.string as NSString).length), with: value, actionName: "Use whole file", state: .resolved)
            }
            model.applyBlock = { [weak view] range, value in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
                view.replaceMergeBlock(range, with: value, state: .resolved)
            }
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.findBarPosition = .belowContent; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        scroll.documentView = view
        if sourceCells != nil { context.coordinator.attachSourceScroll(scroll, label: label) }
        if editable {
            model.registerLocatorResult(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.locatorScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        scroll.hasVerticalRuler = true; scroll.rulersVisible = model.editorPreferences.showLineNumbers; scroll.verticalRulerView = MergeLineRuler(scrollView: scroll, orientation: .verticalRuler)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MergeTextView else { return }
        view.backgroundColor = MergePalette.color(MergeSourceState.normal)
        view.insertionPointColor = MergePalette.foreground(.normal)
        view.font = model.generalPreferences.nativeFont
        if !model.wrapLines { DispatchQueue.main.async { model.refreshLocatorViewport() } }
        scroll.rulersVisible = model.editorPreferences.showLineNumbers
        view.setMergeTabWidth(tabWidth)
        view.mergeUseSpaces = useSpaces; view.mergeSmartTab = smartTab
        if editable { (view.window as? TextConflictNSWindow)?.mergedText = view }
        view.isEditable = editable && !model.busy && !model.confirmingQuit; view.model = model
        view.mergeFindController?.updateGates()
        if view.blockGeneration != model.navigationGeneration {
            view.blockSelection.clear(in:view); view.blockGeneration = model.navigationGeneration
        }
        let range = view.selectedRange()
        if !view.string.utf8.elementsEqual(text.utf8) { view.string = text; view.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0)) }
        view.foldLayout.prepare(view)
        let entire = NSRange(location: 0, length: (text as NSString).length)
        view.textStorage?.addAttributes([.foregroundColor: MergePalette.foreground(.normal), .backgroundColor: MergePalette.color(MergeSourceState.normal), .font: model.generalPreferences.nativeFont, .paragraphStyle: view.defaultParagraphStyle ?? NSParagraphStyle.default], range: entire)
        if editable {
            view.inlineMissingOffsets = []
            let states = model.resultStates
            for (index, range) in MergeLineEndings.lineRanges(in: text).enumerated() where states.indices.contains(index) {
                view.textStorage?.addAttributes([.backgroundColor: MergePalette.color(states[index]), .foregroundColor: MergePalette.foreground(states[index])], range: range)
            }
            if let requested = model.selectionRequest, NSMaxRange(requested) <= entire.length {
                view.installBlock(requested,caret:requested.location,trimFinalEnding:true)
                view.blockSelection.centerCaret(in:view)
                DispatchQueue.main.async { if model.selectionRequest == requested { model.selectionRequest = nil } }
            }
        } else if let sourceCells {
            var offset = 0
            view.inlineMissingOffsets = []
            for (row, cell) in sourceCells.enumerated() {
                let length = (cell.displayText as NSString).length + 1
                view.textStorage?.addAttributes([.backgroundColor: MergePalette.color(cell.state), .foregroundColor: MergePalette.foreground(cell.state)], range: NSRange(location: offset, length: length))
                if let sourceSide, let diff = model.inlineDifference(row, mine: sourceSide == .mine) {
                    let left = sourceSide == .theirs
                    let removal = cell.state.isRemoval
                    view.textStorage?.addAttribute(.backgroundColor, value: MergePalette.inlineCommon, range: NSRange(location: offset, length: length))
                    for range in left ? diff.base : diff.destination {
                        view.textStorage?.addAttribute(.backgroundColor, value: removal ? MergePalette.inlineRemoved : MergePalette.inlineAdded, range: NSRange(location: offset + range.location, length: range.length))
                    }
                    view.inlineMissingOffsets += (left ? diff.baseMissing : diff.destinationMissing).map { offset + $0 }
                }
                offset += length
            }
        } else { view.inlineMissingOffsets = [] }
        model.updateFolding()
        view.foldLayout.apply(to: view, controller: editable ? model.resultFolding : model.folding)
        model.lineWrapping.geometryChanged = { [weak model] in model?.refreshLocatorViewport() }
        model.lineWrapping.update(scroll, key: label, aligned: sourceCells != nil, enabled: model.wrapLines)
        view.sourceCells = sourceCells
        let other = sourceSide.flatMap { side in model.sourceComparison?.rows.map { side == .mine ? $0.theirs : $0.mine } }
        view.whitespaceRenderer.update(text: text, cells: sourceCells, otherCells: other, preferences: model.whitespaceDisplay)
        view.whitespaceRenderer.removal = sourceSide == .theirs
        view.whitespaceRenderer.highlightEndings = model.showInlineDiff
        view.mergeFindHighlights.annotationsChanged = { [weak model] in model?.refreshLocatorHighlights() }
        view.mergeFindHighlights.refresh(in: view)
        model.refreshLocatorHighlights()
        view.needsDisplay = true
        (scroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers = sourceCells?.map(\.lineNumber)
        (scroll.verticalRulerView as? MergeLineRuler)?.updateMetrics(for: view)
        scroll.verticalRulerView?.needsDisplay = true
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model, editable: editable) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: TextConflictWindowModel
        let editable: Bool
        weak var sourceScroll: NSScrollView?
        init(model: TextConflictWindowModel, editable: Bool) { self.model = model; self.editable = editable }
        func attachSourceScroll(_ scroll: NSScrollView, label: String) {
            sourceScroll = scroll; model.registerSourceScroll(scroll, label: label)
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(sourceScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        @objc func locatorScrolled(_ notification: Notification) { model.refreshLocatorViewport() }
        @objc private func sourceScrolled(_ notification: Notification) { if let sourceScroll { model.sourceDidScroll(sourceScroll) } }
        deinit { NotificationCenter.default.removeObserver(self) }
        func textDidChange(_ notification: Notification) {
            if editable, let view = notification.object as? MergeTextView {
                model.result = view.string; view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
                model.selectedConflict = min(model.selectedConflict, max(model.blocks.count - 1, 0))
                DispatchQueue.main.async { view.updateUndoState() }
            }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard editable, let view = textView as? MergeTextView, let replacementString else { return true }
            guard view.isEditable, !model.busy, !model.confirmingQuit else { return false }
            view.replaceMergeBlock(affectedCharRange, with: replacementString, actionName: "Typing")
            view.setSelectedRange(NSRange(location: affectedCharRange.location + replacementString.utf16.count, length: 0))
            return false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? MergeTextView else { return }
            if !model.selectingNavigationBlock { view.foldLayout.reveal(selection: view.selectedRange(), in: view) }
            let range = view.selectedRange()
            DispatchQueue.main.async { [weak view] in
                guard let view, view.selectedRange() == range else { return }
                self.model.navigationSelectionChanged(view)
            }
        }
    }
}
@MainActor protocol MergeContextMenuProviding {
    func mergeContextMenu(defaults: UserDefaults, pasteboard: NSPasteboard) -> NSMenu
}
private final class MergeTextView: NSTextView, MergeContextMenuProviding, MergeLineNavigationProviding, MergeWhitespaceDisplaying, MergeFindProviding, MergeBlockSelecting {
    var chooseNavigationLine: (NSWindow, Int) async -> Int? = MergeLineNumberPrompt.choose
    var navigationPending = false
    @objc private func expandFoldedSection(_ sender: Any?) { _ = foldLayout.expandSelection(in: self) }
    var navigationCells: [MergeSourceCell]? { sourceCells }
    var navigationAllowed: Bool { model?.busy == false && model?.confirmingQuit == false }
    @objc func goToSourceLine(_ sender: Any?) { navigateToSourceLine() }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { model?.focusNavigation(self) }
        return accepted
    }
    @objc private func nextDifference(_ sender: Any?) { model?.navigateBlock(1,conflictsOnly:false) }
    @objc private func previousDifference(_ sender: Any?) { model?.navigateBlock(-1,conflictsOnly:false) }
    @objc private func nextConflict(_ sender: Any?) { model?.navigateBlock(1,conflictsOnly:true) }
    @objc private func previousConflict(_ sender: Any?) { model?.navigateBlock(-1,conflictsOnly:true) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .control, event.keyCode == 125 || event.keyCode == 126 {
            model?.navigateBlock(event.keyCode == 125 ? 1 : -1,conflictsOnly:false); return true
        }
        if (event.keyCode == 98 || event.keyCode == 103), modifiers.isEmpty || modifiers == .shift || event.keyCode == 103 && modifiers == .control {
            model?.navigateBlock(modifiers.isEmpty ? 1 : -1,conflictsOnly:false); return true
        }
        if event.keyCode == 100, modifiers.isEmpty || modifiers == .shift {
            model?.navigateBlock(modifiers == .shift ? -1 : 1,conflictsOnly:true); return true
        }
        if modifiers == .control, event.charactersIgnoringModifiers?.lowercased() == "g" {
            goToSourceLine(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    weak var model: TextConflictWindowModel?
    var mergeEditable = false
    var sourceSide: MergeSourceSide?
    var sourceCells: [MergeSourceCell]?
    let mergeFindHighlights = MergeFindHighlights()
    var mergeFindController: MergeFindWindowController?
    var mergeFindDefaults: UserDefaults { model?.comparisonDefaults ?? .standard }
    var mergeFindAllowed: Bool { window != nil && model?.retired == false && model?.busy == false && model?.preparing == false && model?.confirmingQuit == false && window?.attachedSheet == nil }
    var mergeFindWritable: Bool { mergeFindAllowed && mergeEditable && isEditable }
    var mergeFindLines: [MergeFindLine] {
        if let sourceCells { return MergeFindLine.displayCells(sourceCells) }
        return MergeFindLine.document(string, states: model?.resultStates ?? [])
    }
    func replaceFindMatches(_ ranges: [NSRange], with replacement: String) -> Bool {
        guard mergeFindWritable, !ranges.isEmpty else { return false }
        let value = NSMutableString(string: string)
        guard ranges.allSatisfy({ NSMaxRange($0) <= value.length }) else { return false }
        for range in ranges.reversed() { value.replaceCharacters(in: range, with: replacement) }
        let delta = ranges.dropLast().reduce(0) { $0 + (replacement as NSString).length - $1.length }
        replaceMergeBlock(NSRange(location: 0, length: (string as NSString).length), with: value as String, actionName: ranges.count == 1 ? "Replace" : "Replace All")
        setSelectedRange(NSRange(location: ranges.last!.location + delta + (replacement as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }
    var blockGeneration = -1
    let blockSelection = MergeBlockSelection()
    var mergeSelectedBlockRange: NSRange? { blockSelection.range(in:self) }
    var mergeBlockBoundaryRects: [NSRect] { blockSelection.boundaryRects(in:self) }
    func installBlock(_ range: NSRange, caret: Int, trimFinalEnding: Bool = false) {
        var payload = range
        if trimFinalEnding, NSMaxRange(range) <= string.utf16.count {
            payload.length = MergeSourceComparison.navigationRanges(text:(string as NSString).substring(with:range)).last.map(NSMaxRange) ?? 0
        }
        blockSelection.install(payload,caret:caret,in:self)
    }
    let foldLayout = MergeFoldTextLayout()
    override func scrollRangeToVisible(_ range: NSRange) {
        if model?.selectingNavigationBlock != true { foldLayout.reveal(selection: range, in: self, includeMarker: true) }
        super.scrollRangeToVisible(range)
    }
    override func mouseDown(with event: NSEvent) {
        model?.clearNavigationBlockSelection()
        if MergeMarkedWordInterface.mouse(event, in: self) { window?.makeFirstResponder(self); return }
        if model?.busy == false, model?.confirmingQuit == false, foldLayout.expand(at: event, in: self) { return }
        super.mouseDown(with: event)
    }
    let whitespaceRenderer = MergeWhitespaceRenderer()
    var inlineMissingOffsets: [Int] = []
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect); whitespaceRenderer.draw(in: self, dirtyRect: dirtyRect)
        MergeInlineTicks.draw(in: self, offsets: inlineMissingOffsets, dirtyRect: dirtyRect)
        foldLayout.draw(in: self, dirtyRect: dirtyRect)
        blockSelection.draw(in:self,dirtyRect:dirtyRect)
    }
    fileprivate var clipboardText: String? {
        guard window != nil, let model, !model.retired else { return nil }
        if let cells = sourceCells {
            return try? MergeClipboard.sourceText(selection: selectedRange(), cells: cells,
                blockRows: mergeSelectedBlockRange.flatMap { MergeBlockSelection.rows($0,cells:cells) }
                    ?? MergeClipboard.changedBlock(selection:selectedRange(),cells:cells))
        }
        if let block = mergeSelectedBlockRange {
            // Native blocks already exclude the final row's ending; a trailing
            // LF can instead represent a selected empty final row.
            return try? MergeClipboard.documentText(selection:block,document:string)
        }
        let block = sourceSide == nil && selectedRange().length == 0 ? model.blocks.first { NSLocationInRange(selectedRange().location, $0.range) }?.range : nil
        return try? MergeClipboard.documentText(selection:selectedRange(),document:string,block:block)
    }
    fileprivate var clipboardWritable: Bool {
        window != nil && model?.retired == false && mergeEditable && isEditable && model?.busy == false && model?.confirmingQuit == false && window?.attachedSheet == nil
    }
    @discardableResult fileprivate func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard let text = clipboardText, !text.isEmpty else { return false }
        pasteboard.clearContents(); return pasteboard.setString(text, forType: .string)
    }
    override func copy(_ sender: Any?) { copySelection(to: .general) }
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let text = clipboardText, !text.isEmpty else { return false }
        return pboard.setString(text, forType: .string)
    }
    fileprivate func cutSelection(to pasteboard: NSPasteboard) {
        guard clipboardWritable, copySelection(to: pasteboard) else { return }
        // Source RemoveSelectedText is a no-op for a block-only selection.
        if selectedRange().length > 0 { insertText("", replacementRange: selectedRange()) }
    }
    fileprivate func pasteSelection(from pasteboard: NSPasteboard) {
        guard clipboardWritable, let text = pasteboard.string(forType: .string) else { return }
        insertText(MergeClipboard.pastedText(text, document: string), replacementRange: selectedRange())
    }
    private var mergeTabWidth = 4
    var mergeUseSpaces = false
    var mergeSmartTab = false
    override func insertTab(_ sender: Any?) {
        guard mergeEditable else { super.insertTab(sender); return }
        guard isEditable, model?.busy == false else { return }
        let range = selectedRange()
        if let edit = MergeWhitespace.indentSelection(in: string, selection: range, tabWidth: mergeTabWidth, useSpaces: mergeUseSpaces, smart: mergeSmartTab) {
            if !(string as NSString).substring(with: edit.range).utf8.elementsEqual(edit.replacement.utf8) { replaceMergeBlock(edit.range, with: edit.replacement, actionName: "Indent lines") }
            return
        }
        let remaining = (string as NSString).replacingCharacters(in: range, with: "")
        let replacement = MergeWhitespace.tabInsertion(in: remaining, utf16Offset: range.location, tabWidth: mergeTabWidth, useSpaces: mergeUseSpaces, smart: mergeSmartTab)
        replaceMergeBlock(range, with: replacement, actionName: "Insert tab")
        setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
    }
    override func insertBacktab(_ sender: Any?) {
        guard mergeEditable else { super.insertBacktab(sender); return }
        guard isEditable, model?.busy == false, let edit = MergeWhitespace.indentSelection(in: string, selection: selectedRange(), tabWidth: mergeTabWidth, remove: true) else { return }
        if !(string as NSString).substring(with: edit.range).utf8.elementsEqual(edit.replacement.utf8) { replaceMergeBlock(edit.range, with: edit.replacement, actionName: "Unindent lines") }
    }
    func setMergeTabWidth(_ width: Int) {
        mergeTabWidth = width
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width * CGFloat(width)
        defaultParagraphStyle = paragraph
    }
    private let mergeUndoManager: UndoManager = { let value = UndoManager(); value.groupsByEvent = false; return value }()
    override var undoManager: UndoManager? { mergeEditable ? mergeUndoManager : super.undoManager }
    func updateUndoState() { model?.canUndo = mergeUndoManager.canUndo; model?.canRedo = mergeUndoManager.canRedo }
    func undoMergeEdit() { if mergeUndoManager.canUndo { mergeUndoManager.undo() }; updateUndoState() }
    func redoMergeEdit() { if mergeUndoManager.canRedo { mergeUndoManager.redo() }; updateUndoState() }
    func resetMergeHistory() { mergeUndoManager.removeAllActions(); updateUndoState() }
    func replaceMergeBlock(_ range: NSRange, with replacement: String, actionName: String = "Use text block", state: MergeSourceState = .edited) {
        guard isEditable, model?.busy == false, model?.confirmingQuit == false, NSMaxRange(range) <= (string as NSString).length else { return }
        let previous = string, selection = selectedRange(), presentation = model?.resultPresentation, block = mergeSelectedBlockRange
        mergeUndoManager.beginUndoGrouping(); defer { mergeUndoManager.endUndoGrouping() }
        mergeUndoManager.registerUndo(withTarget: self) { $0.restoreMergeText(previous, selection: selection, presentation: presentation, block:block) }
        if let next = model?.resultPresentation.replacing(range, with: replacement, state: state) { model?.updateResultPresentation(next) }
        mergeUndoManager.setActionName(actionName)
        textStorage?.replaceCharacters(in: range, with: replacement)
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
        didChangeText()
    }
    private func restoreMergeText(_ text: String, selection: NSRange, presentation: MergeResultPresentation? = nil, block: NSRange? = nil) {
        let previous = string, previousSelection = selectedRange(), previousPresentation = model?.resultPresentation, previousBlock = mergeSelectedBlockRange
        mergeUndoManager.registerUndo(withTarget: self) { $0.restoreMergeText(previous, selection: previousSelection, presentation: previousPresentation, block:previousBlock) }
        if let presentation { model?.updateResultPresentation(presentation) }
        textStorage?.replaceCharacters(in: NSRange(location: 0, length: (string as NSString).length), with: text)
        if let block { installBlock(block,caret:selection.location) }
        else { blockSelection.clear(in:self); setSelectedRange(selection) }
        didChangeText()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if mergeEditable { (window as? TextConflictNSWindow)?.mergedText = self }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if mergeEditable || sourceSide != nil, selectedRange().length == 0 { setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), length: 0)) }
        window?.makeFirstResponder(self); model?.navigationSelectionChanged(self)
        return mergeContextMenu(defaults: .standard, pasteboard: .general)
    }
    func mergeContextMenu(defaults: UserDefaults, pasteboard: NSPasteboard) -> NSMenu {
        let menu = MergeClipboardMenu()
        let clipboard = MergeClipboardCommands(view: self, pasteboard: pasteboard); menu.clipboard = clipboard; menu.autoenablesItems = false
        let writable = clipboardWritable
        func editingItem(_ title: String, _ action: Selector, _ image: NSImage?, _ enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.image = image; item.isEnabled = enabled; menu.addItem(item)
        }
        editingItem("Copy", #selector(MergeClipboardCommands.copySelection(_:)), MenuIcon.copy.contextImage(defaults: defaults), !(clipboardText ?? "").isEmpty)
        menu.items.last?.target = clipboard; menu.items.last?.representedObject = clipboard
        if mergeEditable {
            let cutImage = MenuPresentationSettings.applicationContextIcons(defaults: defaults) ? NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cut") : nil
            editingItem("Cut", #selector(MergeClipboardCommands.cutSelection(_:)), cutImage, writable && !(clipboardText ?? "").isEmpty)
            menu.items.last?.target = clipboard; menu.items.last?.representedObject = clipboard
            editingItem("Paste", #selector(MergeClipboardCommands.pasteSelection(_:)), MenuIcon.mergePaste.contextImage(defaults: defaults), writable && pasteboard.availableType(from: [.string]) != nil)
            menu.items.last?.target = clipboard; menu.items.last?.representedObject = clipboard
        }
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(showFind(_:)), keyEquivalent: "")
        find.target = self; find.image = MenuIcon.mergeFind.contextImage(defaults: defaults); menu.addItem(find)
        MergeFindInterface.appendSelectionCommands(to: menu, text: self, defaults: defaults)
        let navigationImage = MenuPresentationSettings.applicationContextIcons(defaults: defaults) ? NSImage(systemSymbolName: "number", accessibilityDescription: "Go to Line") : nil
        editingItem("Go to Line…", #selector(goToSourceLine(_:)), navigationImage, canNavigateToSourceLine)
        menu.items.last?.keyEquivalent = "g"; menu.items.last?.keyEquivalentModifierMask = .control
        if model?.folding.collapsed == true {
            editingItem("Expand unchanged section", #selector(expandFoldedSection(_:)), MenuPresentationSettings.applicationContextIcons(defaults: defaults) ? NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand") : nil, foldLayout.canExpandSelection(in: self))
        }
        menu.addItem(.separator())
        editingItem("Previous difference", #selector(previousDifference(_:)), MenuIcon.mergePreviousDifference.contextImage(defaults:defaults), model?.canNavigateBlock(-1,conflictsOnly:false) == true)
        editingItem("Next difference", #selector(nextDifference(_:)), MenuIcon.mergeNextDifference.contextImage(defaults:defaults), model?.canNavigateBlock(1,conflictsOnly:false) == true)
        editingItem("Previous conflict", #selector(previousConflict(_:)), MenuIcon.mergePreviousConflict.contextImage(defaults:defaults), model?.canNavigateBlock(-1,conflictsOnly:true) == true)
        editingItem("Next conflict", #selector(nextConflict(_:)), MenuIcon.mergeNextConflict.contextImage(defaults:defaults), model?.canNavigateBlock(1,conflictsOnly:true) == true)
        if let sourceSide {
            menu.addItem(.separator())
            for (index,choice) in MergeBlockChoice.allCases.enumerated() {
                editingItem(choice.rawValue,#selector(useSourceBlock(_:)),choice.icon.contextImage(defaults:defaults),model?.sourceToolsAllowed == true && sourceConflictAvailable)
                menu.items.last?.tag = index
            }
            let useFile = NSMenuItem(title: "Use this whole file", action: #selector(useSourceFile(_:)), keyEquivalent: "")
            editingItem("Save this pane as…", #selector(saveSourceAs(_:)), MenuIcon.mergeSaveAs.contextImage(defaults: defaults), model?.sourceToolsAllowed == true)
            editingItem("Compare with Base", #selector(compareSourceWithBase(_:)), MenuIcon.compare.contextImage(defaults: defaults), model?.sourceToolsAllowed == true)
            useFile.target = self; useFile.isEnabled = model?.document != nil && model?.busy == false && model?.confirmingQuit == false; useFile.image = sourceSide.icon.contextImage(defaults: defaults); menu.addItem(useFile)
        }
        guard mergeEditable, let model else { return menu }
        menu.addItem(.separator())
        for (index, choice) in MergeBlockChoice.allCases.enumerated() {
            let item = NSMenuItem(title: choice.rawValue, action: #selector(useBlock(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; item.image = choice.icon.contextImage(defaults: defaults)
            item.isEnabled = writable && model.blocks.contains { NSIntersectionRange($0.range, mergeSelectedBlockRange ?? selectedRange()).length > 0 || NSLocationInRange(selectedRange().location, $0.range) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (index, command) in MergeWhitespaceCommand.allCases.enumerated() {
            let item = NSMenuItem(title: command.rawValue, action: #selector(changeWhitespace(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.isEnabled = writable && MergeWhitespace.canApply(command, to: string, tabWidth: mergeTabWidth); menu.addItem(item)
        }
        let endingsItem = NSMenuItem(title: "Line endings", action: nil, keyEquivalent: "")
        let endingsMenu = NSMenu(title: "Line endings")
        let styles = MergeLineEndings.styles(in: string)
        for (index, ending) in MergeLineEnding.allCases.enumerated() {
            let item = NSMenuItem(title: ending.menuTitle, action: #selector(convertLineEndings(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.state = styles == [ending] ? .on : .off; item.isEnabled = writable
            endingsMenu.addItem(item)
        }
        endingsItem.submenu = endingsMenu; menu.addItem(endingsItem)
        let encodingsItem = NSMenuItem(title: "File Encoding", action: nil, keyEquivalent: "")
        let encodingsMenu = NSMenu(title: "File Encoding")
        for (index, encoding) in ComparisonTextEncoding.allCases.enumerated() {
            let item = NSMenuItem(title: encoding.rawValue, action: #selector(changeEncoding(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = model.encoding == encoding ? .on : .off; item.isEnabled = writable
            encodingsMenu.addItem(item)
        }
        encodingsItem.submenu = encodingsMenu; menu.addItem(encodingsItem)
        return menu
    }
    @objc private func copyFromContext(_ sender: Any?) { copy(sender) }
    @objc private func cutFromContext(_ sender: Any?) { cut(sender) }
    @objc private func pasteFromContext(_ sender: Any?) { paste(sender) }
    override func cut(_ sender: Any?) { cutSelection(to: .general) }
    override func paste(_ sender: Any?) { pasteSelection(from: .general) }
    @objc private func showFind(_ sender: Any?) {
        window?.makeFirstResponder(self)
        (window as? TextConflictNSWindow)?.find(.showFindInterface)
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(goToSourceLine(_:)) { return canNavigateToSourceLine }
        if menuItem.action == #selector(copyFromContext(_:)) || menuItem.action == NSSelectorFromString("copy:") { return !(clipboardText ?? "").isEmpty }
        if menuItem.action == #selector(cutFromContext(_:)) || menuItem.action == NSSelectorFromString("cut:") { return clipboardWritable && !(clipboardText ?? "").isEmpty }
        if menuItem.action == #selector(pasteFromContext(_:)) || menuItem.action == NSSelectorFromString("paste:") { return clipboardWritable && NSPasteboard.general.availableType(from: [.string]) != nil }
        if menuItem.action == #selector(changeEncoding(_:)) {
            return mergeEditable && isEditable && model?.busy == false && model?.confirmingQuit == false && ComparisonTextEncoding.allCases.indices.contains(menuItem.tag)
        }
        if menuItem.action == #selector(changeWhitespace(_:)) {
            guard mergeEditable, isEditable, model?.busy == false, model?.confirmingQuit == false, MergeWhitespaceCommand.allCases.indices.contains(menuItem.tag) else { return false }
            return MergeWhitespace.canApply(MergeWhitespaceCommand.allCases[menuItem.tag], to: string, tabWidth: mergeTabWidth)
        }
        if menuItem.action == #selector(convertLineEndings(_:)) {
            return mergeEditable && isEditable && model?.busy == false && model?.confirmingQuit == false && MergeLineEnding.allCases.indices.contains(menuItem.tag)
        }
        if menuItem.action == #selector(saveSourceAs(_:)) || menuItem.action == #selector(compareSourceWithBase(_:)) { return sourceSide != nil && model?.sourceToolsAllowed == true }
        if menuItem.action == #selector(useSourceFile(_:)) { return sourceSide != nil && model?.document != nil && model?.busy == false && model?.confirmingQuit == false }
        if menuItem.action == #selector(useBlock(_:)) {
            guard mergeEditable, isEditable, let model, !model.busy, !model.confirmingQuit,
                  MergeBlockChoice.allCases.indices.contains(menuItem.tag) else { return false }
            let selection = mergeSelectedBlockRange ?? selectedRange()
            return model.blocks.contains { NSIntersectionRange($0.range, selection).length > 0 || NSLocationInRange(selection.location, $0.range) }
        }
        return super.validateMenuItem(menuItem)
    }
    @objc private func saveSourceAs(_ sender: Any?) { guard let sourceSide else { return }; model?.exportSource(mine: sourceSide == .mine) }
    @objc private func compareSourceWithBase(_ sender: Any?) { guard let sourceSide else { return }; model?.compareSourceWithBase(mine: sourceSide == .mine) }
    @objc private func useSourceFile(_ sender: NSMenuItem) {
        guard let sourceSide else { return }
        model?.useFile(sourceSide)
    }
    @objc private func changeEncoding(_ sender: NSMenuItem) {
        guard mergeEditable, isEditable, ComparisonTextEncoding.allCases.indices.contains(sender.tag) else { return }
        model?.changeEncoding(ComparisonTextEncoding.allCases[sender.tag])
    }
    @objc private func convertLineEndings(_ sender: NSMenuItem) {
        guard mergeEditable, isEditable, model?.busy == false, model?.confirmingQuit == false, MergeLineEnding.allCases.indices.contains(sender.tag) else { return }
        let ending = MergeLineEnding.allCases[sender.tag]
        let converted = MergeLineEndings.converting(string, to: ending)
        guard !converted.utf8.elementsEqual(string.utf8) else { return }
        window?.makeFirstResponder(self)
        replaceMergeBlock(NSRange(location: 0, length: (string as NSString).length), with: converted, actionName: "Change line endings")
    }
    @objc private func changeWhitespace(_ sender: NSMenuItem) {
        guard mergeEditable, isEditable, model?.busy == false, model?.confirmingQuit == false, MergeWhitespaceCommand.allCases.indices.contains(sender.tag) else { return }
        let command = MergeWhitespaceCommand.allCases[sender.tag]
        let converted = MergeWhitespace.applying(command, to: string, tabWidth: mergeTabWidth)
        guard !converted.utf8.elementsEqual(string.utf8) else { return }
        window?.makeFirstResponder(self)
        replaceMergeBlock(NSRange(location: 0, length: (string as NSString).length), with: converted, actionName: command.rawValue)
    }
    private var sourceConflictAvailable: Bool {
        guard sourceSide != nil, let model, let cells = sourceCells else { return false }
        let lines = MergeFindLine.displayCells(cells), selection = mergeSelectedBlockRange ?? selectedRange()
        guard let start = lines.lastIndex(where: { $0.offset <= selection.location }) else { return false }
        let end = lines.lastIndex(where: { $0.offset <= NSMaxRange(selection) }) ?? start
        guard let range = model.resultPresentation.navigationMap.resultRange(sourceRows:start..<(end + 1)) else { return false }
        return model.blocks.contains { NSIntersectionRange($0.range,range).length > 0 || range.length == 0 && NSLocationInRange(range.location,$0.range) }
    }
    @objc private func useSourceBlock(_ sender: NSMenuItem) {
        guard sourceConflictAvailable, MergeBlockChoice.allCases.indices.contains(sender.tag) else { return }
        window?.makeFirstResponder(self); model?.navigationSelectionChanged(self)
        model?.choose(MergeBlockChoice.allCases[sender.tag])
    }
    @objc private func useBlock(_ sender: NSMenuItem) {
        guard mergeEditable, isEditable, MergeBlockChoice.allCases.indices.contains(sender.tag), let model, !model.busy, !model.confirmingQuit, let block = model.blocks.first(where: { NSIntersectionRange($0.range, mergeSelectedBlockRange ?? selectedRange()).length > 0 || NSLocationInRange(selectedRange().location, $0.range) }) else { return }
        let text = block.replacement(MergeBlockChoice.allCases[sender.tag])
        replaceMergeBlock(block.range, with: text, state: .resolved)
    }
}
final class MergeLineRuler: NSRulerView {
    var sourceNumbers: [Int?]?
    var markedRows = Set<Int>()
    func updateMetrics(for view: NSTextView) {
        let count = sourceNumbers?.compactMap { $0 }.max() ?? MergeLineEndings.lineRanges(in: view.string).count
        let font = NSFont.monospacedDigitSystemFont(ofSize: view.font?.pointSize ?? 10, weight: .regular)
        let width = (String(max(1, count)) as NSString).size(withAttributes: [.font: font]).width + 22
        let next = max(45, ceil(width))
        if ruleThickness != next { ruleThickness = next }
    }
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) { super.init(scrollView: scrollView, orientation: orientation); ruleThickness = 45 }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? NSTextView ?? scrollView?.documentView as? NSTextView, let manager = view.layoutManager, let container = view.textContainer else { return }
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        let text = view.string as NSString, visible = view.visibleRect
        let visibleInRuler = convert(visible, from: view)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: NSRect(x: bounds.minX, y: visibleInRuler.minY, width: bounds.width, height: visibleInRuler.height).intersection(bounds)).addClip()
        var location = 0, line = 1
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: view.font?.pointSize ?? 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let glyph = manager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            let frame = manager.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: view.textContainerInset.width, dy: view.textContainerInset.height)
            let folded = view.textStorage?.attribute(.mergeFoldHidden, at: location, effectiveRange: nil) != nil || view.textStorage?.attribute(.mergeFoldMarker, at: location, effectiveRange: nil) != nil
            if !folded && frame.maxY >= visible.minY && frame.minY <= visible.maxY {
                let number = sourceNumbers == nil ? line : (sourceNumbers!.indices.contains(line - 1) ? sourceNumbers![line - 1] : nil)
                let value = number.map(String.init) as NSString? ?? ""
                value.draw(at: NSPoint(x: ruleThickness - value.size(withAttributes: attrs).width - 6, y: convert(frame.origin, from: view).y), withAttributes: attrs)
                if markedRows.contains(line - 1) { MenuIcon.mergeMarked.image(size: 12)?.draw(in: NSRect(x: 2, y: convert(frame.origin, from: view).y, width: 12, height: 12)) }
            }
            if frame.minY > visible.maxY { break }
            location = NSMaxRange(range); line += 1
        }
    }
}

@MainActor private final class MergeClipboardMenu: NSMenu {
    var clipboard: MergeClipboardCommands?
}
@MainActor private final class MergeClipboardCommands: NSObject {
    private weak var view: MergeTextView?
    private let pasteboard: NSPasteboard
    init(view: MergeTextView, pasteboard: NSPasteboard) { self.view = view; self.pasteboard = pasteboard }
    @objc func copySelection(_ sender: Any?) { view?.copySelection(to: pasteboard) }
    @objc func cutSelection(_ sender: Any?) { view?.cutSelection(to: pasteboard) }
    @objc func pasteSelection(_ sender: Any?) { view?.pasteSelection(from: pasteboard) }
}
