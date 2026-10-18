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
    var legacyEncoding = ComparisonTextEncoding.windows1252
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
                    ForEach(MergeFormatSelection.encodingChoices(legacy:encoding?.legacyCodePage != nil ? encoding! : legacyEncoding), id: \.rawValue) { value in
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
    var writable = true
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
                Toggle("EditorConfig", isOn: Binding(get: { editorConfigEnabled }, set: changeEditorConfig)).disabled(!editorConfigLoaded)
            }
        }.disabled(!writable).fixedSize().accessibilityLabel("\(label) tab settings: \(settingsTitle)")
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
    var activeEditorText: NSTextView? { activeText }
    private var activeText: NSTextView? { (firstResponder as? MergeTextView) ?? findText ?? mergedText }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let owner = delegate as? TextConflictWindowController,owner.editorCommandMenu?.performKeyEquivalent(event) == true { return true }
        if let patchModel {
            if let owner = delegate as? WorkingTreePatchWindowController,owner.editorCommandMenu?.performKeyEquivalent(event) == true {return true}
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            #if DEBUG
            if flags == [.command, .option, .shift], event.charactersIgnoringModifiers?.lowercased() == "s", Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") == true { DocumentationCapture.saveWindow(); return true }
            #endif
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "o" { openMergeDocument(); return true }
            if flags == .command, event.charactersIgnoringModifiers == "s" { patchModel.saveDraft(); return true }
            if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", (firstResponder as? NSTextView)?.isFieldEditor != true {
                if flags.contains(.shift) { patchModel.redoPreview() } else { patchModel.undoPreview() }; return true
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
            guard (mergedText as? MergeTextView)?.historyAllowed == true else { return true }
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
    func windowDidBecomeKey(_ notification: Notification) { editorFileMenu.remove();editorCommandMenu?.install() }
    func windowDidResignKey(_ notification: Notification) { editorCommandMenu?.remove();editorFileMenu.remove() }
    func detachForReplacement() { editorCommandMenu?.retire();editorToolbar?.retire(); editorFileMenu.remove(); model.retire(); model.window = nil }
    @objc func reloadEditor(_ sender: Any?) { guard !preparingReplacement, !model.exportingSource, !model.formatPending, editorOpenWorkflow == nil, window?.attachedSheet == nil else { return }; model.load() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { (item.action == #selector(openMergeDocument(_:)) || item.action == #selector(reloadEditor(_:))) && !preparingReplacement && editorOpenWorkflow == nil && !model.busy && !model.preparing && !model.formatPending && !model.confirmingQuit && !model.retired && !model.exportingSource && window?.attachedSheet == nil }
    private(set) var editorToolbar: MergeEditorToolbar?
    private(set) var editorCommandMenu: MergeEditorCommandMenu?
    var showEditorHelp: () -> Void = { TurtleGitHelp.show(.resolve) }
    let model: TextConflictWindowModel
    var onClosed: () -> Void = {}
    var editorOpenWorkflow: MergeEditorOpenWorkflow?
    var makeEditorOpenWorkflow: (NSWindow, [RepositoryAccessLease], UserDefaults) -> MergeEditorOpenWorkflow = { MergeEditorOpenWorkflow(window: $0, permissions: $1, preferences: $2) }
    var replacementOwner: MergeEditorReplacementOwner?
    weak var sharedReplacementOwner: MergeEditorReplacementOwner?
    var preparingReplacement: Bool { (sharedReplacementOwner ?? replacementOwner)?.preparingPatch == true }
    @objc func openMergeDocument(_ sender: Any?) {
        guard !preparingReplacement, !model.exportingSource, !model.formatPending, editorOpenWorkflow == nil, let window, !model.busy, !model.preparing, !model.confirmingQuit, !model.retired, window.attachedSheet == nil else { return }
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
        model.comparisonDefaults = preferences; model.initialLoadDeferred = deferInitialLoad; model.requiresNativeEditor = true
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
        guard !preparingReplacement, !model.exportingSource, !model.formatPending, editorOpenWorkflow == nil else { return false }
        guard sender.attachedSheet == nil else { return false }
        if model.preparing { return true }
        guard !model.busy, !model.confirmingQuit, !model.formatPending else { return false }
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to “\(model.path)”?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.save(markResolved: false, closeAfter: true); return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) { guard let closing = notification.object as? NSWindow, closing === window else { return }; MergeLineRuler.retire(in:window?.contentView); editorCommandMenu?.retire();editorToolbar?.retire(); editorFileMenu.remove(); editorOpenWorkflow?.retire(); editorOpenWorkflow = nil; model.retire(); onClosed() }
    func installEditorToolbar() {
        editorCommandMenu?.retire();editorToolbar?.retire();editorToolbar = MergeEditorToolbar.conflict(self)
        editorCommandMenu = MergeEditorCommandMenu.conflict(self)
        if window?.isKeyWindow == true { editorCommandMenu?.install() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class TextConflictWindowModel: ObservableObject {
    let repository: GitRepository
    private(set) var mergeToolInvocation: MergeToolInvocation?
    private var mergeToolAcceptedSave = false
    var mergeToolSaved: Bool { mergeToolAcceptedSave && !dirty }
    private var mergeToolRequiredSave = false
    var mergeToolRequiresSave: Bool { mergeToolRequiredSave }
    private var mergeToolInitialLoad = false
    private var mergeToolInitialLine: Int?
    private var ownedFormatChoices = 0
    private var ownedEditorConfigReads = 0
    var mergeToolHasPendingWork: Bool { busy || preparing || sourceExporter.hasPendingWork || formatPending || ownedFormatChoices > 0 || ownedEditorConfigReads > 0 }
    private var explicitMergeToolReadOnly = false
    private var replacementReflectedNames: [String: String] = [:]
    private var hasMergeToolReplacementPolicy = false
    private var replacementBlame = false
    var mergeToolBlame: Bool { mergeToolInvocation?.blame ?? replacementBlame }
    var mergeToolReadOnly: Bool { explicitMergeToolReadOnly || (mergeToolInvocation.map { $0.readOnly || $0.blame } ?? false) }
    func configureMergeToolReadOnly(_ enabled: Bool) {
        guard document == nil, !busy, !retired else { return }
        explicitMergeToolReadOnly = enabled
    }
    /// File/Open clears descriptive names, output and required-save state while
    /// the frame's reflected names and immutable comparison policy survive.
    func configureMergeToolReplacement(readOnly: Bool, blame: Bool = false,
                                       reflectedBase: String? = nil, reflectedTheirs: String? = nil,
                                       reflectedMine: String? = nil, reflectedMerged: String? = nil) {
        guard document == nil, !busy, !retired, mergeToolInvocation == nil else { return }
        configureMergeToolReadOnly(readOnly || blame)
        replacementBlame = blame; hasMergeToolReplacementPolicy = true
        for (role, name) in [("base", reflectedBase), ("theirs", reflectedTheirs), ("mine", reflectedMine), ("merged", reflectedMerged)] {
            if let name { replacementReflectedNames[role] = name }
        }
    }
    func configureMergeTool(_ invocation: MergeToolInvocation) throws {
        guard document == nil, !busy, !retired, mergeToolInvocation == nil, let workingMerge else { throw RevisionComparisonFailure.selection }
        mergeToolInvocation = invocation; configureMergeToolReadOnly(invocation.readOnly || invocation.blame); mergeToolRequiredSave = invocation.saveRequired
        mergeToolInitialLoad = true; mergeToolInitialLine = invocation.line
        workingMergeOutput = workingMerge.outputURL
        window?.title = (invocation.mergedName.flatMap { $0.isEmpty ? nil : $0 } ?? workingMerge.outputURL.lastPathComponent) + " – TurtleGitMerge"
    }
    func mergeToolPaneTitle(_ fallback: String, mine: Bool? = nil, result: Bool = false) -> String {
        guard let invocation = mergeToolInvocation else { return fallback }
        let name = result ? invocation.mergedName : mine.map { $0 ? invocation.mineName : invocation.theirsName } ?? invocation.baseName
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
    func mergeToolReflectedName(mine: Bool? = nil, result: Bool = false) -> String? {
        if result { return mergeToolInvocation?.mergedReflectedName ?? replacementReflectedNames["merged"] }
        if let mine { return mine ? mergeToolInvocation?.mineReflectedName ?? replacementReflectedNames["mine"] : mergeToolInvocation?.theirsReflectedName ?? replacementReflectedNames["theirs"] }
        return mergeToolInvocation?.baseReflectedName ?? replacementReflectedNames["base"]
    }
    func mergeToolPaneLocation(mine: Bool? = nil, result: Bool = false) -> String? {
        guard mergeToolInvocation != nil || hasMergeToolReplacementPolicy else { return nil }
        if let reflected = mergeToolReflectedName(mine: mine, result: result) { return reflected }
        if result { return workingMergeOutput?.path }
        if let mine { return mine ? workingMerge?.mineURL.path : workingMerge?.theirsURL.path }
        return workingMerge?.baseURL.path
    }
    fileprivate func applyMergeToolInitialLine(_ view: MergeTextView) {
        guard !retired, !busy, !preparing, let line = mergeToolInitialLine,
              view.sourceSide == .mine, view.mergeSourceRowsReady,
              view.window === window, let cells = view.sourceCells else { return }
        let numbered = cells.indices.filter { cells[$0].lineNumber != nil }
        guard let row = numbered.first(where: { cells[$0].lineNumber! >= line }) ?? numbered.last else { return }
        mergeToolInitialLine = nil; selectionRequest = nil
        for peer in navigationViews {
            let ranges = navigationRanges(peer)
            guard ranges.indices.contains(row) else { continue }
            let range = NSRange(location: ranges[row].location, length: 0)
            peer.foldLayout.reveal(selection: range, in: peer)
            peer.setSelectedRange(range); peer.scrollRangeToVisible(range)
        }
        window?.makeFirstResponder(view); focusNavigation(view)
    }
    var patchComparison:WorkingTreePatchFileComparison?
    var patchResultSaver:((String,ComparisonTextEncoding,OperationCancellation?) async throws -> TextConflictDocument)?
    @Published var patchResultCompleted = false
    var repositoryResolutionAllowed:Bool {!mergeToolReadOnly && workingMerge == nil && patchComparison == nil && mergedResultTarget == nil}
    func cancelPatchOperation() {if patchComparison != nil {cancelSaveOperation()}}
    func cancelSaveOperation() {loadCancellation?.cancel();saveChoices.cancel();saveFolderAccess.cancel()}
    let saveFolderAccess=MergeSaveFolderAccess()
    private let saveChoices=MergeSaveChoices()
    private(set) var mergedResultTarget:SavedMergePane?
    var resultPath:String {mergedResultTarget?.url.path ?? workingMergeOutput?.path ?? path}
    var workingMerge: WorkingTextMerge?
    var workingMergePermissions: [RepositoryAccessLease] = []
    var openPermissions: [RepositoryAccessLease] { workingMergePermissions + [access].compactMap { $0 } }
    private(set) var workingMergeOutput: URL?
    private var standaloneSavedResult: String?
    private var standaloneSavedEncoding: ComparisonTextEncoding?
    var chooseStandaloneOutput: ((NSWindow?, String) async -> URL?)?
    private func chooseMergeOutput() async -> URL? {
        let url:URL?
        if let chooseStandaloneOutput {url=await chooseStandaloneOutput(window,resultPath)}
        else {url=await saveChoices.output(window:window,name:"merged-" + (resultPath as NSString).lastPathComponent,directory:repository.root)}
        guard !retired,let url else {return nil}
        let lease=RepositoryAccessLease(url:url)
        workingMergePermissions.append(lease);return url
    }
    let path: String
    private let access: RepositoryAccessLease?
    @Published var document: TextConflictDocument?
    private(set) var sourceLayoutRevision = 0
    @Published var sourceComparison: MergeSourceComparison? { didSet { inlineCache = [:]; alignedResultCache = nil; sourceLayoutRevision &+= 1 } }
    lazy var folding: MergeFoldingController = {
        let value = makeFoldingController()
        value.expanded = { [weak self] _ in self?.synchronizeResultFolding() }
        return value
    }()
    lazy var resultFolding: MergeFoldingController = {
        let value = makeFoldingController()
        value.expanded = { [weak self] ranges in
            guard let self else { return }
            let resultRows = Set(ranges.flatMap { Array($0) })
            let sourceRows: [Int]
            if self.alignedResultProjection != nil {
                // Aligned display rows already share source coordinates. Engine
                // anchors describe serialized result rows, including fewer gaps.
                sourceRows = Array(resultRows)
            } else {
                let mapping = self.resultPresentation.foldAnchors.resultRows(in: self.result)
                sourceRows = mapping.compactMap { resultRows.contains($0.value) ? $0.key : nil }
            }
            if !self.folding.reveal(sourceRows: sourceRows) { self.synchronizeResultFolding() }
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
        let result = alignedResultProjection?.cells
        folding.update(unchanged: sourceComparison?.rows.enumerated().map { row,source in
            source.mine.state.isUnchanged && source.theirs.state.isUnchanged && (result == nil || result!.indices.contains(row) && result![row].state.isUnchanged)
        } ?? [])
        synchronizeResultFolding()
    }
    private func synchronizeResultFolding() {
        if let projection = alignedResultProjection {
            resultFolding.install(visibility:projection.cells.indices.map { row in
                let unchanged = projection.cells[row].state.isUnchanged
                return unchanged && folding.folding.visibility.indices.contains(row) ? folding.folding.visibility[row] : .shown
            })
            return
        }
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
        if patchComparison != nil,sourceTargets[mine] == nil {return mine ? "Current working file" : "Patched recorded base"}
        guard sourceTargets[mine] == nil, let titles = document?.conflictTitles else { return nil }
        return mine ? titles.mine.title : titles.theirs.title
    }
    @Published private(set) var exportingSource = false
    lazy var sourceExporter: MergeSourceExport = {
        let value = MergeSourceExport()
        value.stateChanged = { [weak self] in self?.exportingSource = $0 }
        value.permissions = { [weak self] in self?.openPermissions ?? [] }
        value.failure = { [weak self] in self?.error = $0 }
        return value
    }()
    // Native commands must never fall through to the model-only mutation path
    // before their result view has attached and installed its history handlers.
    var requiresNativeEditor = false
    private struct NativeEditorStamp: Equatable {
        let view: ObjectIdentifier
        let generation: Int
        let layout: Int
        let presentation: Int
    }
    private var lastNativeEditorStamp: NativeEditorStamp?
    var nativeEditorReady: Bool {
        guard let view = locatorResultScroll?.documentView as? MergeTextView else { return false }
        return view.window != nil && view.window === window && view.model === self && view.mergeEditable && view.mergeSourceRowsReady && applyAlignedSourceBlock != nil && applyBlock != nil
    }
    fileprivate func nativeEditorDidUpdate(_ view: MergeTextView) {
        let stamp = nativeEditorReady ? NativeEditorStamp(view:ObjectIdentifier(view),generation:loadGeneration,layout:sourceLayoutRevision,presentation:resultPresentationRevision) : nil
        guard lastNativeEditorStamp != stamp else { return }; lastNativeEditorStamp = stamp
        // AppKit updates during a SwiftUI render cannot publish synchronously.
        DispatchQueue.main.async { [weak self] in guard let self, !self.retired else { return }; self.objectWillChange.send() }
    }
    var sourceOperationsAllowed: Bool { !patchResultCompleted && !retired && !busy && !preparing && !formatPending && !confirmingQuit && !exportingSource && window?.attachedSheet == nil && document != nil }
    var sourceToolsAllowed: Bool { sourceOperationsAllowed && (!requiresNativeEditor || nativeEditorReady) }
    var sourceMutationsAllowed: Bool { !mergeToolReadOnly && sourceToolsAllowed }
    func exportSource(mine: Bool) {
        guard sourceMutationsAllowed, let window, let document, let sourceComparison else { return }
        do {
            let encoding = (mine ? document.mineEncoding : document.theirsEncoding) ?? document.encoding
            let bytes = try MergePaneSaveAs.sourceBytes(rows: sourceComparison.rows, mine: mine, encoding: encoding)
            let generation=loadGeneration
            let name = sourceTargets[mine]?.url.lastPathComponent ?? (mine ? "Mine-" : "Theirs-") + (path as NSString).lastPathComponent
            sourceExporter.save(bytes, name: name, owner: window) { [weak self] url, lease in
                let target=try await Task.detached {try SavedMergePane(url:url,writtenBytes:bytes,encoding:encoding)}.value
                guard let self,!self.retired,self.loadGeneration==generation else{return}
                if let workingMerge = self.workingMerge { try await workingMerge.bindSource(mine: mine, target: target) }
                guard !self.retired,self.loadGeneration==generation else {return}
                self.patchComparison=self.patchComparison?.recordingOwnedWrite(target)
                self.sourceTargets[mine] = target; self.workingMergePermissions.append(lease)
                let output = self.mergedResultTarget?.url ?? (self.workingMerge == nil ? self.repository.root.appendingPathComponent(self.path).standardizedFileURL : self.workingMergeOutput)
                if let output,GitReferenceName.equal(output.standardizedFileURL.path,target.url.path),let current=self.document {
                    self.document = try current.recordingOwnedWorkingWrite(target.content)
                    self.resultCopySavepoint=nil
                    if self.mergedResultTarget != nil {self.mergedResultTarget=target}
                    if self.workingMerge != nil { self.standaloneSavedResult = target.content.text; self.standaloneSavedEncoding = target.content.encoding }
                }
                self.reloadEditorConfig()
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
    var comparisonDefaults: UserDefaults = .standard {
        didSet { if document == nil {
            showToolbar = MergeEditorChrome.visible("Toolbar",defaults:comparisonDefaults)
            showStatusBar = MergeEditorChrome.visible("StatusBar",defaults:comparisonDefaults)
            editorPreferences = .load(from:comparisonDefaults)
            initialEditorConfigDefault = editorPreferences.enableEditorConfig
        } }
    }
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
            var result = MergeLocatorHighlights.read(self.locatorResultScroll)
            if (self.locatorResultScroll?.documentView as? MergeTextView)?.sourceCells == nil, let projection = self.alignedResultProjection {
                result.search = projection.sourceRows(serializedRows:result.search,text:self.result)
                result.marked = projection.sourceRows(serializedRows:result.marked,text:self.result)
            }
            let next: [MergeLocatorHighlights] = [.read(left), result, .read(right)]
            if self.locatorHighlights != next { self.locatorHighlights = next }
        }
    }
    var locatorMap: MergeLocatorMap {
        let states = alignedResultStates
        return MergeLocatorMap(columns: [sourceComparison?.rows.map { $0.theirs.state } ?? [], states, sourceComparison?.rows.map { $0.mine.state } ?? []])
    }
    func setLocatorPreferences(_ value: MergeLocatorPreferences) {
        guard !retired, !busy, !confirmingQuit else { return }
        locatorPreferences = value; value.save(to: comparisonDefaults)
    }
    func registerLocatorResult(_ scroll: NSScrollView) { locatorResultScroll = scroll }
    func invalidateLineRulers() {
        for reference in sourceScrolls.values { reference.view?.verticalRulerView?.needsDisplay = true }
        locatorResultScroll?.verticalRulerView?.needsDisplay = true
    }
    func refreshLocatorViewport(from scroll: NSScrollView? = nil) {
        guard !retired, !lineWrapping.isGeometryPending else { return }
        let primary = scroll ?? sourceScrolls.first { $0.key.hasPrefix("Theirs") }?.value.view ?? locatorResultScroll
        var value = MergeLocatorScrolling.viewport(primary)
        if primary === locatorResultScroll, (primary?.documentView as? MergeTextView)?.sourceCells == nil, let projection = alignedResultProjection {
            let rows = projection.sourceRows(serializedRows:Set(value.rows),text:result)
            if let first = rows.min(), let last = rows.max() { value = .init(rows:first..<(last + 1)) }
        }
        if value != locatorViewport { locatorViewport = value }
    }
    func scrollLocator(to row: Int) {
        guard !retired, !busy, !confirmingQuit else { return }
        lineWrapping.prepareForInput()
        for reference in sourceScrolls.values { if let scroll = reference.view { MergeLocatorScrolling.scroll(scroll, to: row) } }
        if let locatorResultScroll {
            let rawRow: Int
            if (locatorResultScroll.documentView as? MergeTextView)?.sourceCells == nil, let projection = alignedResultProjection, projection.serializedRanges.indices.contains(row) {
                rawRow = max(0,MergeLineEndings.lineNumber(in:result,utf16Offset:projection.serializedRanges[row].location) - 1)
            } else { rawRow = row }
            MergeLocatorScrolling.scroll(locatorResultScroll, to:rawRow)
        }
        lineWrapping.recordViewportIntent(); refreshLocatorViewport()
    }
    private var pendingComparisonOptions: MergeComparisonOptions?
    var commentProfileURL = MergeCommentProfileFile.url
    private var commentProfiles = MergeCommentProfiles.bundled()
    var supportsComments: Bool { commentProfiles.tokens(paths: [path]) != nil }
    func setComparisonOptions(_ value: MergeComparisonOptions) {
        guard !busy, !confirmingQuit, !retired, !formatPending else { return }
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
        guard !busy, !confirmingQuit, !retired, !formatPending, name == nil || regexFilters.contains(where: { MergeRegexFilters.sameName($0.name,name) }) else { return }
        load(filterName: name)
    }
    func retire() {
        retireFormatChoice()
        saveChoices.cancel();saveFolderAccess.cancel()
        sourceExporter.retire()
        folding.retire(); resultFolding.retire()
        lineWrapping.retire()
        retired = true; loadGeneration += 1; loadCancellation?.cancel(); loadCancellation = nil
        regexList?.retire(); regexList = nil
        cancelEditorConfigReads(); editorConfigAccess.retire()
    }
    private struct ResultCopySavepoint {let text:String;let encoding:ComparisonTextEncoding}
    private var resultCopySavepoint:ResultCopySavepoint?
    private var savedIgnoredConflicts: [IgnoredMergeConflict] = []
    private var savedSourceChoiceRevision: UInt64 = 0
    private(set) var resultPresentationRevision = 0
    @Published private(set) var resultPresentation = MergeResultPresentation(text: "", states: []) { didSet { resultPresentationRevision &+= 1 } }
    @Published var result = "" { didSet { if !resultPresentation.text.utf8.elementsEqual(result.utf8) { resultPresentation = resultPresentation.reconciling(result) } } }
    var resultStates: [MergeSourceState] { resultPresentation.states(conflicts: blocks.map(\.range)) }
    private var alignedResultCache: (generation: Int, presentation: MergeResultPresentation, projection: MergeAlignedResultProjection?)?
    var alignedResultProjection: MergeAlignedResultProjection? {
        guard let comparison = sourceComparison else { return nil }
        if let cached = alignedResultCache, cached.generation == loadGeneration, cached.presentation == resultPresentation { return cached.projection }
        let value = MergeAlignedResultProjection(comparison:comparison,presentation:resultPresentation)
        alignedResultCache = (loadGeneration,resultPresentation,value)
        return value
    }
    var resultDisplayText: String { alignedResultProjection?.displayText ?? result }
    var alignedResultStates: [MergeSourceState] { alignedResultProjection?.cells.map(\.state) ?? resultStates }
    var resultLineNumber: Int {
        if let projection = alignedResultProjection, let view = locatorResultScroll?.documentView as? MergeTextView, view.sourceCells != nil,
           let row = projection.displayRanges.lastIndex(where: { $0.location <= view.selectedRange().location }) { return projection.cells[row].lineNumber ?? 1 }
        return MergeLineEndings.lineNumber(in:result,utf16Offset:caret.location)
    }
    func updateResultPresentation(_ value: MergeResultPresentation) { resultPresentation = value }

    @Published var encoding: ComparisonTextEncoding = .utf8
    @Published var resultLineEnding:MergeLineEnding = .lf
    private var savedResultLineEnding:MergeLineEnding = .lf
    var resultFormatText:String { alignedResultProjection?.cells.filter { !$0.state.isViewEmpty }.map(\.text).joined() ?? result }
    var applyResultFormat:((MergeResultPresentation,MergeSourceComparison?,ComparisonTextEncoding,MergeLineEnding,String)->Void)?
    @Published var selectedConflict = 0
    @Published var caret = NSRange(location: 0, length: 0)
    @Published var selectionRequest: NSRange?
    @Published var busy = false { didSet { if oldValue != busy { paneTabEpoch = UUID() } } }
    @Published private(set) var preparing = false
    @Published var confirmingQuit = false
    @Published var error: String?
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
    @Published var overwriteMode = false
    private var initialEditorConfigDefault = MergeEditorPreferences.load().enableEditorConfig
    private enum EditorConfigPane: CaseIterable, Hashable { case base, mine, theirs, result }
    private var lastEditorConfigPaneNames: [EditorConfigPane: String] = [:]
    private var editorConfigPaneNames: [EditorConfigPane: String] {
        guard let document else { return [:] }
        return [.base: "Base", .mine: document.mineStage == 3 ? "Mine — Branch being rebased" : "Mine",
                .theirs: document.theirsStage == 2 ? "Theirs — Branch being rebased onto" : "Theirs", .result: "Merged · \(resultPath)"]
    }
    func editorConfigURL(pane: String) throws -> URL {
        guard let role = editorConfigPaneNames.first(where: { $0.value == pane })?.key else { throw EditorConfigFailure.invalidPath }
        let actual: String, reflected: String?
        switch role {
        case .base:
            actual = workingMerge?.baseURL.path ?? patchComparison?.recoveryBase?.path ?? path
            reflected = mergeToolReflectedName()
        case .mine:
            actual = sourceTargets[true]?.url.path ?? workingMerge?.mineURL.path ?? path
            reflected = mergeToolReflectedName(mine: true)
        case .theirs:
            actual = sourceTargets[false]?.url.path ?? workingMerge?.theirsURL.path ?? path
            reflected = mergeToolReflectedName(mine: false)
        case .result:
            actual = resultPath; reflected = mergeToolReflectedName(result: true)
        }
        return try MergeEditorConfigPath.fileURL(actualPath: actual, reflectedName: reflected, root: repository.root)
    }
    func setEditorConfig(_ enabled: Bool, pane: String, readGroup: UUID = UUID()) {
        guard document != nil, !retired, !confirmingQuit, editorConfigPaneNames.values.contains(pane) else { return }
        editorConfigReads.removeValue(forKey:pane)?.cancel()
        let request = UUID(); editorConfigRequests[pane] = request; paneTabEpoch = UUID()
        editorConfigEnabled[pane] = enabled
        if enabled { editorConfigLoaded[pane] = false }
        tabWidths[pane] = editorPreferences.tabWidth
        spacePanes[pane] = editorPreferences.useSpaces
        smartTabPanes[pane] = editorPreferences.smartTab
        editorConfigLoading.remove(pane)
        guard enabled else { return }
        let read = makeEditorConfigRead(); editorConfigReads[pane] = read
        editorConfigLoading.insert(pane)
        let file = Result { try editorConfigURL(pane: pane) }
        let permissions = openPermissions
        ownedEditorConfigReads += 1
        Task {
            defer { ownedEditorConfigReads -= 1 }
            let resolved: Result<MergeEditorConfigProperties?,Error>
            do { resolved = .success(try await editorConfigAccess.read(read, file: file.get(), permissions: permissions, window: window, group: readGroup)) }
            catch { resolved = .failure(error) }
            guard !retired, editorConfigRequests[pane] == request else { return }
            editorConfigLoading.remove(pane); editorConfigReads.removeValue(forKey:pane); paneTabEpoch = UUID()
            switch resolved {
            case .success(let values):
                guard let values else { return }
                editorConfigLoaded[pane] = values.loaded
                let settings = values.applying(to: editorPreferences)
                tabWidths[pane] = settings.tabWidth; spacePanes[pane] = settings.useSpaces
            case .failure(let failure): if !read.cancellation.isCancelled { error = failure.localizedDescription }
            }
        }
    }
    private var paneTabEpoch = UUID()
    private var editorConfigReads: [String:MergeEditorConfigRead] = [:]
    private let editorConfigAccess = MergeEditorConfigAccess()
    var makeEditorConfigRead: () -> MergeEditorConfigRead = { MergeEditorConfigRead() }
    func captureTabCommand(pane:String) -> MergePaneTabCommand {
        .init(epoch:paneTabEpoch,writable:sourceMutationsAllowed && pane == "Merged · \(resultPath)" && !editorConfigLoading.contains(pane),editorConfigLoaded:editorConfigLoaded[pane] == true)
    }
    func applyTabCommand(_ command:MergePaneTabCommand,pane:String,action:MergePaneTabCommand.Action) {
        guard command.epoch == paneTabEpoch, command.writable, captureTabCommand(pane:pane).writable else { return }
        switch action {
        case .width(let width): guard [1,2,4,8].contains(width) else { return }; tabWidths[pane] = width
        case .spaces(let value): spacePanes[pane] = value
        case .smart(let value): smartTabPanes[pane] = value
        case .editorConfig(let value): guard command.editorConfigLoaded,editorConfigLoaded[pane] == true else { return }; setEditorConfig(value,pane:pane)
        }
        paneTabEpoch = UUID()
    }
    private func cancelEditorConfigReads() {
        paneTabEpoch = UUID(); editorConfigRequests = [:]
        for read in editorConfigReads.values { read.cancel() }
        editorConfigReads.removeAll(); editorConfigLoading.removeAll()
    }
    private func reloadEditorConfig() {
        let names = editorConfigPaneNames
        // A result Save As (or rebase-side caption change) changes its display
        // key, not the pane's session toggle. Retire old requests before moving
        // that pane's settings; late replies cannot recreate the obsolete key.
        for role in EditorConfigPane.allCases {
            guard let next = names[role], let previous = lastEditorConfigPaneNames[role], previous != next else { continue }
            editorConfigReads.removeValue(forKey: previous)?.cancel()
            editorConfigRequests.removeValue(forKey: previous); editorConfigLoading.remove(previous)
            editorConfigEnabled[next] = editorConfigEnabled.removeValue(forKey: previous)
            editorConfigLoaded[next] = editorConfigLoaded.removeValue(forKey: previous)
            tabWidths[next] = tabWidths.removeValue(forKey: previous)
            spacePanes[next] = spacePanes.removeValue(forKey: previous)
            smartTabPanes[next] = smartTabPanes.removeValue(forKey: previous)
            paneTabEpoch = UUID()
        }
        lastEditorConfigPaneNames = names
        let group = UUID()
        for role in EditorConfigPane.allCases {
            guard let pane = names[role] else { continue }
            if editorConfigEnabled[pane] == nil { editorConfigEnabled[pane] = initialEditorConfigDefault }
            if editorConfigEnabled[pane] == true { setEditorConfig(true, pane: pane, readGroup: group) }
        }
    }

    private var preferencesSubscription: AnyCancellable?
    var applyBlock: ((NSRange, String) -> Void)?
    var applySourceBlock: ((MergeSourceBlockEdit) -> Void)?
    var applyAlignedSourceBlock: ((MergeAlignedSourceBlockEdit) -> Void)?
    private let sourceCommandOwner = UUID()
    struct SourceBlockCommand {
        fileprivate let owner: UUID
        fileprivate let generation: Int
        fileprivate let layoutRevision: Int
        fileprivate let expected: MergeResultPresentation
        fileprivate let conflict: MergeConflictBlock?
        fileprivate let edit: MergeSourceBlockEdit?
        fileprivate let choice: MergeBlockChoice
        fileprivate var aligned: MergeAlignedSourceBlockEdit? = nil
        fileprivate var lineEnding: MergeLineEnding? = nil
    }
    func sourceBlockCommand(rows: Range<Int>, choice: MergeBlockChoice) -> SourceBlockCommand? {
        guard sourceMutationsAllowed, let comparison = sourceComparison,
              let mapped = resultPresentation.navigationMap.resultRange(sourceRows:rows) else { return nil }
        if alignedResultProjection != nil, let edit = try? MergeAlignedSourceBlockEdit(comparison:comparison,presentation:resultPresentation,rows:rows,choice:choice,lineEnding:resultLineEnding) {
            return SourceBlockCommand(owner:sourceCommandOwner,generation:loadGeneration,layoutRevision:sourceLayoutRevision,expected:resultPresentation,conflict:nil,edit:nil,choice:choice,aligned:edit,lineEnding:resultLineEnding)
        }
        // Unknown serialized mappings retain the existing atomic conflict path.
        if let conflict = blocks.first(where: { NSIntersectionRange($0.range,mapped).length > 0 || mapped.length == 0 && NSLocationInRange(mapped.location,$0.range) }) {
            if !conflict.isIgnored, let whole = resultPresentation.navigationMap.sourceRows(resultRange:conflict.range),
               let edit = MergeSourceBlockEdit(comparison:comparison,presentation:resultPresentation,rows:whole,choice:choice), edit.range == conflict.range {
                return SourceBlockCommand(owner:sourceCommandOwner,generation:loadGeneration,layoutRevision:sourceLayoutRevision,expected:resultPresentation,conflict:nil,edit:edit,choice:choice,lineEnding:resultLineEnding)
            }
            return SourceBlockCommand(owner:sourceCommandOwner,generation:loadGeneration,layoutRevision:sourceLayoutRevision,expected:resultPresentation,conflict:conflict,edit:nil,choice:choice,lineEnding:resultLineEnding)
        }
        guard let edit = MergeSourceBlockEdit(comparison:comparison,presentation:resultPresentation,rows:rows,choice:choice) else { return nil }
        return SourceBlockCommand(owner:sourceCommandOwner,generation:loadGeneration,layoutRevision:sourceLayoutRevision,expected:resultPresentation,conflict:nil,edit:edit,choice:choice,lineEnding:resultLineEnding)
    }
    fileprivate func wholeSourceFileCommand(side: MergeSourceSide) -> SourceBlockCommand? {
        guard sourceMutationsAllowed, let comparison = sourceComparison else { return nil }
        let edit = MergeAlignedSourceBlockEdit(wholeFileFrom: comparison, presentation: resultPresentation, mine: side == .mine, lineEnding: resultLineEnding)
        return SourceBlockCommand(owner: sourceCommandOwner, generation: loadGeneration, layoutRevision: sourceLayoutRevision, expected: resultPresentation, conflict: nil, edit: nil, choice: side == .mine ? .mine : .theirs, aligned: edit, lineEnding: resultLineEnding)
    }
    func performSourceBlock(_ command: SourceBlockCommand) {
        guard canPerformSourceBlock(command) else { return }
        if let aligned = command.aligned {
            if let applyAlignedSourceBlock { applyAlignedSourceBlock(aligned) }
            else { sourceComparison = aligned.comparison; resultPresentation = aligned.presentation; result = aligned.presentation.text }
        } else if let conflict = command.conflict {
            if let applyBlock { applyBlock(conflict.range,conflict.replacement(command.choice)) }
            else if let next = resultPresentation.replacing(conflict.range,with:conflict.replacement(command.choice),state:.resolved) { resultPresentation = next; result = next.text }
        } else if let edit = command.edit {
            if let applySourceBlock { applySourceBlock(edit) }
            else if let next = resultPresentation.applyingSourceBlock(edit) { resultPresentation = next; result = next.text }
        }
    }
    func canPerformSourceBlock(_ command: SourceBlockCommand) -> Bool {
        sourceMutationsAllowed && command.owner == sourceCommandOwner && command.generation == loadGeneration && command.layoutRevision == sourceLayoutRevision && command.expected == resultPresentation && (command.lineEnding == nil || command.lineEnding == resultLineEnding)
    }
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
        defer { refreshLocatorViewport(from:scroll) }
        guard !synchronizingScroll else { return }
        synchronizingScroll = true; defer { synchronizingScroll = false }
        var peers = sourceScrolls.values.compactMap { $0.view }
        if (locatorResultScroll?.documentView as? MergeTextView)?.sourceCells != nil, let result = locatorResultScroll { peers.append(result) }
        for peer in peers {
            guard peer !== scroll else { continue }
            let clip = peer.contentView
            let desired = NSRect(origin: NSPoint(x: clip.bounds.minX, y: scroll.contentView.bounds.minY), size: clip.bounds.size)
            let target = clip.constrainBoundsRect(desired).origin
            if target != clip.bounds.origin { clip.scroll(to: target); peer.reflectScrolledClipView(clip) }
            peer.verticalRulerView?.needsDisplay = true
        }
    }
    var blocks: [MergeConflictBlock] { resultPresentation.conflicts(document: document) }
    var hasUnresolvedConflicts: Bool { !blocks.isEmpty || MergeText.hasMarkers(result) }
    var mergeToolHasConflicts: Bool { hasUnresolvedConflicts }
    var confirmUnresolvedSave: ((String) -> Bool)?
    var dirty: Bool {
        guard !mergeToolReadOnly else { return false }
        if mergeToolRequiredSave && document != nil { return true }
        return document.map { document in
            let previous:String,previousEncoding:ComparisonTextEncoding
            if workingMerge == nil,mergedResultTarget == nil,let copy=resultCopySavepoint {previous=copy.text;previousEncoding=copy.encoding}
            else if workingMerge == nil {previous=document.initialResult;previousEncoding=document.encoding}
            else if workingMergeOutput != nil {previous=standaloneSavedResult ?? document.initialResult;previousEncoding=standaloneSavedEncoding ?? document.encoding}
            else {previous=document.workingContents.flatMap{document.encoding.decode($0)} ?? "";previousEncoding=document.encoding}
            return resultLineEnding != savedResultLineEnding || !result.utf8.elementsEqual(previous.utf8) || resultPresentation.ignoredConflicts != savedIgnoredConflicts || resultPresentation.sourceChoiceRevision != savedSourceChoiceRevision || encoding != previousEncoding
        } ?? false
    }
    @Published private(set) var formatPending = false
    var chooseFormat:((NSWindow,String,MergeFormatSelection) async -> MergeFormatSelection?)?
    private var formatToken:UUID?
    private var formatTask:Task<Void,Never>?
    private var formatPrompt:MergeFormatPrompt?
    private func finishFormatChoice(_ token:UUID) {
        guard formatToken == token else { return }
        formatToken = nil; formatPending = false; formatTask = nil; formatPrompt = nil
    }
    private func retireFormatChoice() {
        guard let token = formatToken else { return }
        formatPrompt?.cancel()
        formatTask?.cancel(); finishFormatChoice(token)
    }
    var legacyEncoding:ComparisonTextEncoding { .legacyEncoding(from:comparisonDefaults) }
    func showFormatDialog() {
        guard sourceMutationsAllowed, let window else { return }
        let original = resultPresentation, originalEncoding = encoding, originalEnding = resultLineEnding
        let generation = loadGeneration, layout = sourceLayoutRevision, token = UUID()
        formatToken = token; formatPending = true; ownedFormatChoices += 1; MergeRegexOperations.activeRequests += 1
        formatTask = Task { [weak self] in
            defer { MergeRegexOperations.activeRequests -= 1 }
            guard let self else { return }
            defer { self.finishFormatChoice(token); self.ownedFormatChoices -= 1 }
            guard !retired, formatToken == token, !Task.isCancelled, self.window === window else { return }
            let initial = MergeFormatSelection(encoding:originalEncoding,ending:originalEnding)
            let choice:MergeFormatSelection?
            if let chooseFormat { choice = await chooseFormat(window,"Merged",initial) }
            else {
                let prompt = MergeFormatPrompt(pane:"Merged",selection:initial,legacyEncoding:legacyEncoding); formatPrompt = prompt
                choice = await prompt.choose(window:window)
            }
            guard formatToken == token, !Task.isCancelled, let choice,
                  generation == loadGeneration, layout == sourceLayoutRevision, !busy, !confirmingQuit, !retired,
                  self.window === window, resultPresentation == original, encoding == originalEncoding, resultLineEnding == originalEnding else { return }
            finishFormatChoice(token)
            applyFormatChoice(choice,actionName:"Change file format")
        }
    }
    func applyFormatChoice(_ choice:MergeFormatSelection,actionName:String = "Change file format",validateEncoding:Bool = true) {
        guard sourceMutationsAllowed else { return }
        do {
            var next = resultPresentation, comparison = sourceComparison
            if let ending = choice.ending {
                if let current = comparison, alignedResultProjection != nil {
                    let transform = try MergeAlignedResultTransform(comparison:current,presentation:next,operation:.lineEndings(ending))
                    next = transform.presentation; comparison = transform.comparison
                } else { next = next.reconciling(MergeLineEndings.converting(next.text,to:ending)) }
            }
            if validateEncoding { _ = try choice.encoding.encode(next.text) }
            let ending = choice.ending ?? resultLineEnding
            guard next != resultPresentation || encoding != choice.encoding || ending != resultLineEnding else { return }
            if let applyResultFormat { applyResultFormat(next,comparison,choice.encoding,ending,actionName) }
            else { sourceComparison = comparison; resultPresentation = next; result = next.text; encoding = choice.encoding; resultLineEnding = ending }
        } catch { self.error = error.localizedDescription }
    }
    func changeEncoding(_ value:ComparisonTextEncoding) { applyFormatChoice(.init(encoding:value),actionName:"Change encoding") }
    func changeLineEnding(_ value:MergeLineEnding) { applyFormatChoice(.init(encoding:encoding,ending:value),actionName:"Change line endings",validateEncoding:false) }
    func canChangeWhitespace(_ command:MergeWhitespaceCommand,tabWidth:Int) -> Bool {
        guard sourceMutationsAllowed else { return false }
        if let projection = alignedResultProjection {
            return projection.cells.contains { !$0.state.isViewEmpty && MergeWhitespace.canApply(command,to:$0.text,tabWidth:tabWidth) }
        }
        return MergeWhitespace.canApply(command,to:result,tabWidth:tabWidth)
    }
    func changeWhitespace(_ command:MergeWhitespaceCommand,tabWidth:Int) {
        guard canChangeWhitespace(command,tabWidth:tabWidth) else { return }
        do {
            var next = resultPresentation, comparison = sourceComparison
            if let current = comparison, alignedResultProjection != nil {
                let transform = try MergeAlignedResultTransform(comparison:current,presentation:next,operation:.whitespace(command,tabWidth:tabWidth))
                next = transform.presentation; comparison = transform.comparison
            } else { next = next.reconciling(MergeWhitespace.applying(command,to:next.text,tabWidth:tabWidth)) }
            if let applyResultFormat { applyResultFormat(next,comparison,encoding,resultLineEnding,command.rawValue) }
            else { sourceComparison = comparison; resultPresentation = next; result = next.text }
        } catch { self.error = error.localizedDescription }
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        self.repository = repository; self.access = access; self.path = path
        preferencesSubscription = NotificationCenter.default.publisher(for: .mergeEditorPreferencesChanged).sink { [weak self] _ in
            guard let self else { return }
            self.paneTabEpoch = UUID()
            let next = MergeEditorPreferences.load(from:self.comparisonDefaults)
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
        guard !busy, !confirmingQuit, !retired, !formatPending, window?.attachedSheet == nil else { return }
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
        cancelEditorConfigReads()
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
        let filter = regexFilters.first { MergeRegexFilters.sameName($0.name,requested) }
        var engine = try engineConfiguration ?? SubversionMergeConfiguration.bundled(filter: filter)
        let changingOptions = pendingComparisonOptions != nil
        let options = pendingComparisonOptions ?? MergeComparisonOptions.load(from: comparisonDefaults)
        let profiles = try MergeCommentProfileFile.load(at: commentProfileURL)
        engine.filter = filter; engine.options = options; engine.commentTokens = profiles.tokens(paths: [path]); engine.blame = mergeToolBlame
        var next: TextConflictDocument
        if mergedResultTarget != nil,workingMerge==nil,let current=document {
            // Once Save As owns the result, the captured source panes remain
            // usable even after the original repository conflict is resolved.
            next=try current.replacingSources(mine:sourceTargets[true]?.read(),theirs:sourceTargets[false]?.read(),engine:engine,cancellation:cancellation)
        } else if let patchComparison {
            let prefer = ComparisonTextEncoding.preferUTF8(from:comparisonDefaults),legacy = legacyEncoding
            next = try await Task.detached {try patchComparison.patchMergeDocument(engine:engine,preferUTF8:prefer,legacyEncoding:legacy,cancellation:cancellation)}.value
        } else if let workingMerge {
            if saveFolderAccess.requireScope {
                for url in [workingMerge.baseURL, workingMerge.theirsURL, workingMerge.mineURL] {
                    guard workingMergePermissions.contains(where: { $0.permits(url) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                }
            }
            next = try await workingMerge.read(engine: engine, mergePreferUTF8: ComparisonTextEncoding.preferUTF8(from: comparisonDefaults),mergeLegacyEncoding:legacyEncoding, cancellation: cancellation)
        }
        else { next = try await repository.textConflictDocument(path: path, engine: engine, mergePreferUTF8: ComparisonTextEncoding.preferUTF8(from: comparisonDefaults),mergeLegacyEncoding:legacyEncoding, identityOptions: ConflictIdentityOptions(defaults: comparisonDefaults), cancellation: cancellation) }
        if workingMerge == nil, mergedResultTarget == nil, !sourceTargets.isEmpty {
            next = try next.replacingSources(mine: sourceTargets[true]?.read(), theirs: sourceTargets[false]?.read(), engine: engine, cancellation: cancellation)
        }
        for (mine, target) in sourceTargets { sourceTargets[mine] = try target.recording(target.read()) }
        if let target=mergedResultTarget {
            let content=try target.read();next=try next.recordingOwnedWorkingWrite(content)
            mergedResultTarget=try target.recording(content)
        }
        guard !retired, generation == nil || generation == loadGeneration else { return }
        guard let comparison = next.mergeSources else { throw SubversionMergeDiffFailure.invalidOutput }
        resetHistory(); canUndo = false; canRedo = false;resultCopySavepoint=nil
        if let invocation = mergeToolInvocation {
            standaloneSavedResult = next.workingContents.flatMap { next.encoding.decode($0) } ?? ""
            standaloneSavedEncoding = next.encoding
            if mergeToolInitialLoad {
                if MergeText.hasMarkers(next.generatedResult) && !invocation.saveRequiredOnConflicts { mergeToolRequiredSave = false }
                mergeToolInitialLoad = false
            }
        }
        document = next; sourceComparison = comparison; resultPresentation = MergeResultPresentation(text: next.generatedResult, states: comparison.resultLocator?.states ?? [], foldAnchors: .init(offsets: comparison.resultAnchors), ignoredConflicts: comparison.ignoredConflicts, navigationMap: comparison.navigationMap).reconciling(next.initialResult); result = next.initialResult; encoding = next.encoding
        savedIgnoredConflicts = resultPresentation.ignoredConflicts
        savedSourceChoiceRevision = resultPresentation.sourceChoiceRevision
        resultLineEnding = MergeLineEndings.predominantStyle(in:next.mine); savedResultLineEnding = resultLineEnding
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
    func clearNavigationBlockSelection(clearTextSelections: Bool = false) {
        for view in navigationViews {
            view.blockSelection.clear(in:view)
            if clearTextSelections { view.setSelectedRange(NSRange(location:view.selectedRange().location,length:0)) }
        }
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
        if lastNavigationView !== view { lastNavigationView = view; objectWillChange.send() }
    }
    private func navigationStates(_ view: MergeTextView) -> [MergeSourceState] {
        guard view.sourceCells == nil || view.sourceLayoutRevision == sourceLayoutRevision else { return [] }
        if let side = view.sourceSide {
            return sourceComparison?.rows.map { side == .mine ? $0.mine.state : $0.theirs.state } ?? []
        }
        return view.mergeEditable ? (view.sourceCells?.map(\.state) ?? resultStates) : []
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
        guard !retired, !selectingNavigationBlock, window?.firstResponder === view,
              view.sourceCells == nil || view.sourceLayoutRevision == sourceLayoutRevision else { return }
        if view.mergeEditable {
            let nextCaret = view.serializedSelection(view.selectedRange()) ?? view.selectedRange()
            if caret != nextCaret { caret = nextCaret }
        }
        let selected = view.mergeSelectedBlockRange ?? view.selectedRange()
        if view.mergeSelectedBlockRange == nil {
            for peer in navigationViews { peer.blockSelection.clear(in:peer) }
        }
        let mapped: NSRange?
        if view.mergeEditable { mapped = view.serializedSelection(selected) }
        else if view.sourceSide != nil {
            let ranges = navigationRanges(view), selection = selected
            let start = ranges.lastIndex(where: { $0.location <= selection.location }) ?? 0
            let end = ranges.lastIndex(where: { $0.location <= NSMaxRange(selection) }) ?? start
            mapped = resultPresentation.navigationMap.resultRange(sourceRows:start..<(end + 1))
        } else { return }
        let changed = !navigationOwnsChoice || navigationChoiceRange != mapped
        navigationOwnsChoice = true; navigationChoiceRange = mapped
        if let index = conflictIndex(in:mapped), index != selectedConflict { selectedConflict = index }
        if changed { objectWillChange.send() }
    }
    private func conflictIndex(in range: NSRange?) -> Int? {
        guard let range else { return nil }
        return blocks.firstIndex { NSIntersectionRange($0.range,range).length > 0 || range.length == 0 && NSLocationInRange(range.location,$0.range) }
    }
    var canChooseConflict: Bool { sourceMutationsAllowed && !blocks.isEmpty && (!navigationOwnsChoice || conflictIndex(in:navigationChoiceRange) != nil) }
    fileprivate func selectMargin(in active: MergeTextView, rows:Range<Int>, selection:NSRange, caret:Int) {
        guard sourceToolsAllowed, active.mergeSourceRowsReady, let activeBlock = navigationRange(rows:rows,in:active), NSMaxRange(selection) <= active.string.utf16.count else { return }
        selectingNavigationBlock = true
        defer { selectingNavigationBlock = false; lineWrapping.recordViewportIntent() }
        selectionRequest = nil
        let sourceRows = active.sourceCells != nil ? rows:resultPresentation.navigationMap.sourceRows(resultRange:activeBlock)
        let mapped = active.mergeEditable ? active.serializedSelection(activeBlock):resultPresentation.navigationMap.resultRange(sourceRows:rows)
        for view in navigationViews {
            let block = view === active ? activeBlock:view.mergeEditable && view.sourceCells == nil ? mapped:sourceRows.flatMap { navigationRange(rows:$0,in:view) }
            if let block, NSMaxRange(block) <= view.string.utf16.count {
                view.blockSelection.install(block,caret:view === active ? caret:block.location,selection:view === active ? selection:nil,in:view)
            } else { view.blockSelection.clear(in:view) }
        }
        navigationOwnsChoice = true; navigationChoiceRange = mapped
        if let index = conflictIndex(in:mapped) { selectedConflict = index }
        if active.mergeEditable { self.caret = active.serializedSelection(selection) ?? selection }
        objectWillChange.send()
    }
    func navigateBlock(_ direction: Int, conflictsOnly: Bool) {
        activeNavigationView?.beginUserNavigation()
        guard let (active,target) = navigationTarget(direction,conflictsOnly:conflictsOnly) else { return }
        selectNavigationBlock(in:active,target:target,reverseEntry:direction < 0)
    }
    fileprivate func selectContextBlock(at offset: Int, in view: MergeTextView) {
        guard sourceToolsAllowed else { return }
        let ranges = navigationRanges(view)
        guard let row = ranges.lastIndex(where: { $0.location <= offset }),
              let block = MergeBlockNavigation.block(states:navigationStates(view),containing:row) else { return }
        clearNavigationBlockSelection(clearTextSelections:true)
        selectNavigationBlock(in:view,target:block,contextOffset:offset)
    }
    private func selectNavigationBlock(in active: MergeTextView, target: MergeBlockNavigation.Target, reverseEntry: Bool = false, contextOffset: Int? = nil) {
        guard let activeRange = navigationRange(rows:target.rows,in:active) else { return }
        lineWrapping.prepareForInput()
        selectionRequest = nil
        selectingNavigationBlock = true; defer { selectingNavigationBlock = false; lineWrapping.recordViewportIntent() }
        let sourceRows = active.sourceCells != nil ? target.rows : resultPresentation.navigationMap.sourceRows(resultRange:activeRange)
        let resultRange = active.mergeEditable ? active.serializedSelection(activeRange) : resultPresentation.navigationMap.resultRange(sourceRows:target.rows)
        let activeRanges = navigationRanges(active)
        let clickedSubline = contextOffset.flatMap { offset -> Int? in
            guard activeRanges.indices.contains(target.caret) else { return nil }
            return MergeWrappedCaret.subline(in:MergeWrappedCaret.starts(in:active,row:activeRanges[target.caret]),containing:offset)
        }
        for view in navigationViews {
            let range: NSRange?
            if view === active { range = activeRange }
            else if view.mergeEditable { range = view.sourceCells != nil ? sourceRows.flatMap { navigationRange(rows:$0,in:view) } : resultRange }
            else { range = sourceRows.flatMap { navigationRange(rows:$0,in:view) } }
            guard let range, NSMaxRange(range) <= view.string.utf16.count else {
                view.setSelectedRange(NSRange(location:min(view.selectedRange().location,view.string.utf16.count),length:0))
                view.blockSelection.clear(in:view); continue
            }
            let ranges = navigationRanges(view)
            let peerEdge = reverseEntry ? max(range.location,NSMaxRange(range) - 1) : range.location
            let row = view === active ? target.caret : ranges.lastIndex(where: { $0.location <= peerEdge }) ?? 0
            if ranges.indices.contains(row) {
                let offset = MergeWrappedCaret.offset(in:view,row:ranges[row],reverse:reverseEntry,subline:clickedSubline)
                view.installBlock(range,caret:offset,trimFinalEnding:view.mergeEditable && view.sourceCells == nil && view !== active)
            }
        }
        active.blockSelection.centerCaret(in:active)
        navigationOwnsChoice = true; navigationChoiceRange = resultRange
        if let index = conflictIndex(in:resultRange) { selectedConflict = index }
        if let view = locatorResultScroll?.documentView as? NSTextView { caret = (view as? MergeTextView)?.serializedSelection(view.selectedRange()) ?? view.selectedRange() }
        objectWillChange.send()
    }
    func continueResolving() {
        guard sourceToolsAllowed, let block = blocks.first else { return }
        selectConflict(0)
        if let view = locatorResultScroll?.documentView as? NSTextView {
            window?.makeFirstResponder(view)
            if let view = view as? MergeTextView, let range = view.displaySelection(block.range), NSMaxRange(range) <= view.string.utf16.count {
                view.installBlock(range,caret:range.location,trimFinalEnding:view.sourceCells == nil)
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
        guard sourceMutationsAllowed, canChooseConflict else { return }
        let index = navigationOwnsChoice ? conflictIndex(in:navigationChoiceRange)! : min(selectedConflict, blocks.count - 1)
        do {
            let block = blocks[index]
            let alignedRows = alignedResultProjection?.sourceRows(intersecting:block.range)
            let rows = alignedRows.flatMap { rows in rows.min().flatMap { first in rows.max().map { first..<($0 + 1) } } } ?? resultPresentation.navigationMap.sourceRows(resultRange:block.range)
            if let rows, let command = sourceBlockCommand(rows:rows,choice:choice) { performSourceBlock(command) }
            else if let applyBlock { applyBlock(block.range, block.replacement(choice)) }
            else { let block = blocks[index], replacement = block.replacement(choice); if let presentation = resultPresentation.replacing(block.range, with: replacement, state: .resolved) { resultPresentation = presentation; result = presentation.text } }
            selectConflict(index)
        }
        catch { self.error = error.localizedDescription }
    }
    fileprivate func useFile(_ side: MergeSourceSide) {
        guard let command = wholeSourceFileCommand(side: side) else { return }
        performSourceBlock(command); selectedConflict = 0
    }
    var chooseEmptyResult: ((String) async -> MergeEmptyResult)?
    weak var window: NSWindow?
    func saveForQuit(completion: @escaping (Bool) -> Void) {
        guard confirmingQuit else { completion(false); return }
        save(markResolved: false, quitApproved: true, completion: completion)
    }
    private func ensureSave(_ token:OperationCancellation) throws {
        guard !retired,loadCancellation === token else {throw OperationCancellationFailure.cancelled}
        try token.check()
    }
    func save(markResolved: Bool, closeAfter: Bool = false, reloadAfter: Bool = false, chooseNewOutput: Bool = false, quitApproved: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !mergeToolReadOnly,!patchResultCompleted,!busy,!preparing,!formatPending,!exportingSource,(!confirmingQuit || quitApproved),!retired,!markResolved || repositoryResolutionAllowed && !hasUnresolvedConflicts,window?.attachedSheet==nil,let document else {completion?(false);return}
        let text=result,outputEncoding=encoding,ignoredResolved=resultPresentation.ignoredConflicts.isEmpty,ignoredSnapshot=resultPresentation.ignoredConflicts,choiceSnapshot=resultPresentation.sourceChoiceRevision,endingSnapshot=resultLineEnding
        let unresolved=hasUnresolvedConflicts,permissions=openPermissions,token=OperationCancellation()
        let resultPaneBeforeSave = "Merged · \(resultPath)"
        busy=true;error=nil;loadCancellation=token;saveChoices.reset();MergeRegexOperations.activeRequests += 1
        Task { [self] in
            var saved=false
            defer {busy=false;if loadCancellation === token {loadCancellation=nil};MergeRegexOperations.activeRequests -= 1;withExtendedLifetime(permissions) {};completion?(saved)}
            do {
                try ensureSave(token)
                if !markResolved,unresolved {
                    let message=ignoredResolved ? "Save with unresolved conflict markers?" : "Save with unresolved conflicts ignored by comparison options?"
                    let accepted:Bool
                    if let confirmUnresolvedSave {accepted=confirmUnresolvedSave(message)}
                    else {accepted=await saveChoices.unresolved(window:window,message:message)}
                    try ensureSave(token)
                    guard accepted,result.utf8.elementsEqual(text.utf8),encoding==outputEncoding else {return}
                }
                let existingOutput=mergedResultTarget?.url ?? workingMergeOutput ?? (workingMerge==nil ? repository.root.appendingPathComponent(path) : nil)
                let outputPermissions=mergedResultTarget?.content.permissions ?? document.permissions
                let absent=mergedResultTarget?.content.isDeleted ?? (document.workingContents==nil)
                let readOnly=patchComparison==nil && existingOutput.map {MergePaneSaveAs.requiresSaveAs(at:$0,permissions:outputPermissions,absent:absent)} == true
                let needsNewOutput=chooseNewOutput || readOnly || workingMerge != nil && workingMergeOutput==nil
                let chosenOutput:URL?
                if needsNewOutput {chosenOutput=await chooseMergeOutput();try ensureSave(token);guard chosenOutput != nil else {return}}
                else {chosenOutput=existingOutput}
                for target in sourceTargets.values {try target.validate()}
                let choosingRepositoryCopy=workingMerge==nil && patchComparison==nil && (needsNewOutput || mergedResultTarget != nil)
                if !choosingRepositoryCopy,workingMerge==nil,GitRuntime.isAppStoreBuild,(access?.hasSecurityScope != true || access?.contains(repository.root) != true) {throw RepositoryAccessFailure.securityScopeUnavailable}
                if patchComparison==nil,let chosenOutput {
                    guard let acquired=try await saveFolderAccess.authorize(file:chosenOutput,permissions:openPermissions,window:window,cancellation:token) else {return}
                    try ensureSave(token);workingMergePermissions.append(contentsOf:acquired)
                }
                let choice:MergeEmptyResult
                // Save As saves the selected zero-byte file; ordinary FileSave
                // asks Delete/Keep. Automatic PatchSave retains zero-line delete.
                if text.isEmpty,patchComparison != nil {choice = .delete}
                else if text.isEmpty,!needsNewOutput {
                    if let chooseEmptyResult {choice=await chooseEmptyResult(resultPath)}
                    else {guard let answer=await saveChoices.empty(window:window,path:resultPath) else {return};choice=answer}
                } else {choice = .keep}
                try ensureSave(token)
                guard result.utf8.elementsEqual(text.utf8),encoding==outputEncoding else {throw FileComparisonEditFailure.changed}
                let options=MergeFileSaveOptions(backupOriginal:!needsNewOutput && MergeFileSaveOptions.backupEnabled(from:comparisonDefaults),emptyResult:choice)
                if let patchResultSaver {
                    let next=try await patchResultSaver(text,outputEncoding,token);try ensureSave(token);self.document=next
                } else if let workingMerge {
                    guard let chosenOutput else {return}
                    if saveFolderAccess.requireScope,!workingMergePermissions.contains(where:{$0.permits(chosenOutput)}) {throw RepositoryAccessFailure.securityScopeUnavailable}
                    let next=try await workingMerge.saveTo(chosenOutput,document:document,result:text,encoding:outputEncoding,options:options,cancellation:token)
                    try ensureSave(token);self.document=next
                    workingMergeOutput=chosenOutput;standaloneSavedResult=text;standaloneSavedEncoding=outputEncoding
                    window?.title=mergeToolPaneTitle(chosenOutput.lastPathComponent,result:true) + " – TurtleGitMerge"
                } else if choosingRepositoryCopy,let chosenOutput {
                    if saveFolderAccess.requireScope,!workingMergePermissions.contains(where:{$0.permits(chosenOutput)}) {throw RepositoryAccessFailure.securityScopeUnavailable}
                    let content:ComparisonFileContent
                    if !needsNewOutput,let target=mergedResultTarget {
                        content=try FileComparisonEditing.saveWorkingContent(at:target.url,original:target.content,text:text,encoding:outputEncoding,options:options)
                        mergedResultTarget=try target.recording(content)
                    } else {
                        let bytes=try outputEncoding.encode(text);try MergePaneSaveAs.write(bytes,to:chosenOutput)
                        let target=try SavedMergePane(url:chosenOutput,writtenBytes:bytes,encoding:outputEncoding)
                        mergedResultTarget=target;content=target.content
                    }
                    self.document=try document.recordingOwnedWorkingWrite(content)
                    window?.title=mergeToolPaneTitle(chosenOutput.lastPathComponent,result:true) + " – TurtleGitMerge"
                } else {
                    let next=try await repository.saveTextConflict(document,result:text,markResolved:markResolved,encoding:outputEncoding,options:options,ignoredConflictsResolved:ignoredResolved,cancellation:token)
                    try ensureSave(token);self.document=next
                }
                if mergeToolInvocation != nil { mergeToolRequiredSave = false; mergeToolAcceptedSave = true }
                if resultPaneBeforeSave != "Merged · \(resultPath)" { reloadEditorConfig() }
                resultCopySavepoint=nil
                savedIgnoredConflicts=ignoredSnapshot;savedSourceChoiceRevision=choiceSnapshot;savedResultLineEnding=endingSnapshot
                onChanged(markResolved && !choosingRepositoryCopy ? "Resolved: " + path : "Saved merged result: " + resultPath)
                if markResolved && !choosingRepositoryCopy || closeAfter {close()}
                else if reloadAfter {try await reloadDocument(filterName:regexFilterName,cancellation:token)}
                saved=true
            } catch let failure as TextConflictSaveFailure {
                if !retired,!token.isCancelled {self.document=failure.savedDocument;resultCopySavepoint=nil;savedIgnoredConflicts=ignoredSnapshot;savedSourceChoiceRevision=choiceSnapshot;savedResultLineEnding=endingSnapshot;self.error=failure.localizedDescription;onChanged(failure.localizedDescription)}
            } catch {if !retired,!token.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func export() {
        guard sourceMutationsAllowed, let window else { return }
        if workingMerge != nil || mergedResultTarget != nil { save(markResolved: false, chooseNewOutput: true); return }
        let text=result,outputEncoding=encoding,ignored=resultPresentation.ignoredConflicts,choice=resultPresentation.sourceChoiceRevision,ending=resultLineEnding,generation=loadGeneration
        do {
            let bytes=try outputEncoding.encode(text)
            sourceExporter.save(bytes,name:(path as NSString).lastPathComponent,owner:window,warning:hasUnresolvedConflicts ? "Save with unresolved conflicts?":nil) { [weak self] url,_ in
                let written=try await Task.detached {try SavedMergePane(url:url,writtenBytes:bytes,encoding:outputEncoding)}.value
                guard let self,!self.retired,self.loadGeneration==generation else{return}
                // FileSaveAs writes a copy and marks the current result clean;
                // it does not change the repository/patch's normal-save target.
                let original=self.repository.root.appendingPathComponent(self.path).standardizedFileURL
                self.patchComparison=self.patchComparison?.recordingOwnedWrite(written)
                if GitReferenceName.equal(written.url.path,original.path),let document=self.document {
                    self.document=try document.recordingOwnedWorkingWrite(written.content)
                    self.resultCopySavepoint=nil
                    self.onChanged("Saved merged result: "+self.resultPath)
                } else {self.resultCopySavepoint=ResultCopySavepoint(text:text,encoding:outputEncoding)}
                for (side,target) in self.sourceTargets where GitReferenceName.equal(target.url.path,written.url.path) {
                    self.sourceTargets[side]=try target.recording(written.content)
                }
                self.savedIgnoredConflicts=ignored;self.savedSourceChoiceRevision=choice;self.savedResultLineEnding=ending
                self.objectWillChange.send()
            }
        } catch { self.error = error.localizedDescription }
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
        private var colors: [String: NSColor] = [:]
        func snapshot() -> (MergeColorPreferences, Int, Bool) { lock.lock(); defer { lock.unlock() }; return (value, revision, applied) }
        func replace(_ value: MergeColorPreferences, applied: Bool) { lock.lock(); defer { lock.unlock() }; self.value = value; self.applied = applied; revision += 1; colors = [:] }
        func color(_ key: String, make: (MergeColorPreferences, Bool) -> NSColor) -> NSColor {
            lock.lock(); defer { lock.unlock() }
            if let color = colors[key] { return color }
            let color = make(value, applied); colors[key] = color; return color
        }
    }
    private static let storage = Storage()
    static var revision: Int { storage.snapshot().1 }
    static func reload(defaults: UserDefaults = .standard) { storage.replace(.load(from: defaults),applied:defaults.data(forKey:"TurtleGitMerge.Colors") != nil) }
    static func role(_ state: MergeSourceState) -> MergeColorRole {
        state.colorRole
    }
    static func roleColor(_ role: MergeColorRole, foreground: Bool = false) -> NSColor {
        storage.color("role:\(role.rawValue):\(foreground)") { palette, _ in NSColor(name: nil) { appearance in
            let color = palette.colors(role, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            let rgb = foreground ? color.foreground : color.background
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        } }
    }
    private static func stateColor(_ state: MergeSourceState, foreground: Bool) -> NSColor {
        storage.color("state:\(state):\(foreground)") { palette, applied in NSColor(name:nil) { appearance in
            let color=palette.stateColors(state,dark:appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,applied:applied)
            let rgb=foreground ? color.foreground:color.background
            return NSColor(srgbRed:CGFloat((rgb >> 16) & 255)/255,green:CGFloat((rgb >> 8) & 255)/255,blue:CGFloat(rgb & 255)/255,alpha:1)
        } }
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
        let cells = editable ? model.alignedResultProjection?.cells : cells
        let displayed = cells.map { $0.map(\.displayText).joined(separator: "\n") + ($0.isEmpty ? "" : "\n") } ?? text
        let tabWidth = model.tabWidths[title] ?? model.editorPreferences.tabWidth
        let useSpaces = model.spacePanes[title] ?? model.editorPreferences.useSpaces
        let smartTab = model.smartTabPanes[title] ?? model.editorPreferences.smartTab
        let encoding = editable ? model.encoding : (side == .mine ? model.document?.mineEncoding : side == .theirs ? model.document?.theirsEncoding : model.document?.baseEncoding)
        let tabCommand = model.captureTabCommand(pane:title)
        return VStack(spacing: 0) {
            HStack {
                Text(model.mergeToolPaneTitle(title,mine:side.map { $0 == .mine },result:editable)).font(.headline).textSelection(.enabled).help(model.mergeToolPaneLocation(mine:side.map { $0 == .mine },result:editable) ?? title)
                if let caption = model.mergeToolPaneLocation(mine:side.map { $0 == .mine },result:editable) ?? caption { Text(caption).font(.caption).lineLimit(1).help(caption).textSelection(.enabled) }
                if let side, let url = model.sourceTargetURL(mine: side == .mine) { Text(url.lastPathComponent).font(.caption).lineLimit(1).help(url.path) }
                Spacer(); if editable { Text(model.mergeToolReadOnly ? "Read-only" : model.dirty ? "Modified" : "").font(.caption).foregroundStyle(.secondary) } }.padding(7).background(Color(nsColor: .controlBackgroundColor))
            MergeEditor(model: model, text: displayed, label: title, editable: editable, sourceCells: cells, sourceSide: side, tabWidth: tabWidth, useSpaces: useSpaces, smartTab: smartTab).frame(minWidth: 220, minHeight: 120)
            let counts=MergeLineStatistics(states:cells?.map(\.state) ?? (editable ? model.alignedResultStates : []))
            if !counts.isEmpty {MergeLineStatisticsView(statistics:counts).padding(.horizontal,7).padding(.vertical,2)}
            HStack {
                MergeFormatControls(label: title, encoding: encoding, text: editable ? model.resultFormatText : text, editable: editable && model.sourceMutationsAllowed && !model.confirmingQuit, changeEncoding: model.changeEncoding, changeEnding: model.changeLineEnding, legacyEncoding:model.legacyEncoding, showFormatDialog:model.showFormatDialog)
                Spacer()
                MergeTabControls(label: title, tabWidth: tabWidth, useSpaces: useSpaces, smartTab: smartTab, changeWidth: { model.applyTabCommand(tabCommand,pane:title,action:.width($0)) }, changeSpaces: { model.applyTabCommand(tabCommand,pane:title,action:.spaces($0)) }, changeSmart: { model.applyTabCommand(tabCommand,pane:title,action:.smart($0)) }, writable: tabCommand.writable, editorConfigEnabled: model.editorConfigEnabled[title] == true, editorConfigLoaded: tabCommand.editorConfigLoaded, changeEditorConfig: { model.applyTabCommand(tabCommand,pane:title,action:.editorConfig($0)) }).disabled(model.busy || model.confirmingQuit || model.editorConfigLoading.contains(title))
            }.padding(.horizontal, 7).padding(.vertical, 3).background(Color(nsColor: .controlBackgroundColor))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if !model.nativeToolbarInstalled {
            HStack(spacing: 10) {
                Button { model.save(markResolved: false) } label: { CommandLabel(title: "Save", icon: .mergeSave) }.keyboardShortcut("s", modifiers: .command).disabled(model.patchResultCompleted || model.mergeToolReadOnly)
                Button { model.save(markResolved: true) } label: { CommandLabel(title: "Mark as resolved", icon: .mergeResolved) }.disabled(!model.repositoryResolutionAllowed || model.document == nil || model.hasUnresolvedConflicts)
                Menu {
                    Button { model.exportSource(mine: false) } label: { CommandLabel(title: "Save left pane as…", icon: .mergeSaveAs) }
                    Button { model.exportSource(mine: true) } label: { CommandLabel(title: "Save right pane as…", icon: .mergeSaveAs) }
                    Button { model.export() } label: { CommandLabel(title: "Save merged result as…", icon: .mergeSaveAs) }
                    if !model.blocks.isEmpty { Button { model.continueResolving() } label: { CommandLabel(title: "Continue resolving conflicts", icon: .mergeNextConflict) } }
                } label: { CommandLabel(title: "Save As…", icon: .mergeSaveAs) }.disabled(!model.sourceMutationsAllowed)
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
                MergeViewControls(preferences: model.locatorPreferences, apply: model.setLocatorPreferences, whitespace: model.whitespaceDisplay, applyWhitespace: model.setWhitespaceDisplay, wrapLines: model.wrapLines, applyWrap: model.setWrapLines, collapsed: model.folding.collapsed, applyCollapsed: model.setCollapsed, toolbarVisible:model.showToolbar, applyToolbar:model.setToolbarVisible, statusBarVisible:model.showStatusBar, applyStatusBar:model.setStatusBarVisible)
                MergeInlineControls(enabled: model.showInlineDiff, word: model.inlineWordDiff, applyEnabled: model.setInlineDiff, applyWord: model.setInlineWordDiff).disabled(model.busy || model.confirmingQuit || model.sourceComparison == nil)
                MergeComparisonControls(options: model.comparisonOptions, apply: model.setComparisonOptions, supportsComments: model.supportsComments)
                Menu("Regex Filter: " + (model.regexFilterName ?? "No Filter")) {
                    Button { model.selectRegexFilter(nil) } label: {
                        if model.regexFilterName == nil { Label("No Filter", systemImage: "checkmark") } else { Text("No Filter") }
                    }
                    ForEach(model.regexFilters) { filter in
                        Button { model.selectRegexFilter(filter.name) } label: {
                            if MergeRegexFilters.sameName(model.regexFilterName,filter.name) { Label(filter.name, systemImage: "checkmark") } else { Text(filter.name) }
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
                    pane("Merged · \(model.resultPath)", text: model.result, editable: true)
                    }
                }
                if model.showStatusBar {
                HStack {
                    Text(model.blocks.isEmpty ? (MergeText.hasMarkers(model.result) ? "Incomplete conflict markers" : "No remaining conflicts") : "\(model.blocks[min(model.selectedConflict,model.blocks.count - 1)].isIgnored ? "Ignored conflict" : "Conflict") \(min(model.selectedConflict + 1, model.blocks.count)) of \(model.blocks.count)").foregroundStyle(model.blocks.isEmpty ? Color.secondary : .red)
                    Spacer()
                    Button { model.undo() } label: { CommandLabel(title: "Undo", icon: .mergeUndo) }.keyboardShortcut("z", modifiers: .command).disabled(!model.sourceMutationsAllowed || !model.canUndo)
                    Button { model.redo() } label: { CommandLabel(title: "Redo", icon: .mergeRedo) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.sourceMutationsAllowed || !model.canRedo)
                    Menu("Use text block") {
                        ForEach(MergeBlockChoice.allCases, id: \.self) { choice in Button { model.choose(choice) } label: { CommandLabel(title: choice.rawValue, icon: choice.icon) } }
                    }.disabled(!model.canChooseConflict)
                    MergeTypingModeControl(overwrite:model.overwriteMode,enabled:model.sourceMutationsAllowed,toggle:{model.overwriteMode.toggle()})
                    Text("Line \(model.resultLineNumber)").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.disabled(model.busy || model.confirmingQuit || model.formatPending).onAppear { model.load() }
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
        view.setAccessibilityLabel(model.mergeToolPaneTitle(label,mine:sourceSide.map { $0 == .mine },result:editable)); view.delegate = context.coordinator; view.model = model; view.mergeEditable = editable
        view.sourceSide = sourceSide
        if editable {
            model.undo = { [weak view] in view?.undoMergeEdit() }
            model.redo = { [weak view] in view?.redoMergeEdit() }
            model.resetHistory = { [weak view] in view?.resetMergeHistory() }
            model.replaceEntireResult = { [weak view] value in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
                view.replaceMergeBlock(NSRange(location: 0, length: view.model?.result.utf16.count ?? view.string.utf16.count), with: value, actionName: "Edit result")
            }
            model.replaceEntireResolvedResult = { [weak view] value in
                guard let view else { return }; view.window?.makeFirstResponder(view)
                view.replaceMergeBlock(NSRange(location: 0, length: view.model?.result.utf16.count ?? view.string.utf16.count), with: value, actionName: "Use whole file", state: .resolved)
            }
            model.applyBlock = { [weak view] range, value in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
                view.replaceMergeBlock(range, with: value, state: .resolved)
            }
            model.applyResultFormat = { [weak view] presentation,comparison,encoding,ending,name in
                view?.applyFormat(presentation:presentation,comparison:comparison,encoding:encoding,ending:ending,actionName:name)
            }
            model.applyAlignedSourceBlock = { [weak view] edit in
                guard let view else { return }; view.window?.makeFirstResponder(view)
                view.applyAlignedSourceBlock(edit)
            }
            model.applySourceBlock = { [weak view] edit in
                guard let view else { return }; view.window?.makeFirstResponder(view)
                view.replaceMergeBlock(edit.range,with:edit.replacement,state:.resolved,sourceEdit:edit)
            }
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.findBarPosition = .belowContent; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        scroll.documentView = view
        if sourceCells != nil && !editable { context.coordinator.attachSourceScroll(scroll, label: label) }
        if editable {
            model.registerLocatorResult(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.locatorScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true; scroll.verticalRulerView = MergeLineRuler(scrollView: scroll, orientation: .verticalRuler)
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MergeTextView else { return }
        // Use a single current model generation rather than a queued View value
        // paired with newer source maps after rapid edits or Undo/Redo.
        let sourceCells = editable ? model.alignedResultProjection?.cells : sourceSide.flatMap { side in model.sourceComparison?.rows.map { side == .mine ? $0.mine : $0.theirs } } ?? self.sourceCells
        let text = editable ? model.resultDisplayText : sourceCells.map { $0.map(\.displayText).joined(separator:"\n") + ($0.isEmpty ? "" : "\n") } ?? self.text
        let background = MergePalette.color(MergeSourceState.normal), foreground = MergePalette.foreground(.normal)
        if view.backgroundColor != background { view.backgroundColor = background }
        if view.insertionPointColor != foreground { view.insertionPointColor = foreground }
        if !model.wrapLines { DispatchQueue.main.async { model.refreshLocatorViewport() } }
        if !scroll.rulersVisible { scroll.rulersVisible = true }
        view.mergeUseSpaces = useSpaces; view.mergeSmartTab = smartTab
        if editable { (view.window as? TextConflictNSWindow)?.mergedText = view }
        let writable = editable && !model.mergeToolReadOnly && model.sourceOperationsAllowed
        if view.isEditable != writable { view.isEditable = writable }; view.model = model
        view.setAccessibilityLabel(model.mergeToolPaneTitle(label,mine:sourceSide.map { $0 == .mine },result:editable))
        view.mergeFindController?.updateGates()
        if view.blockGeneration != model.navigationGeneration {
            view.blockSelection.clear(in:view); view.invalidateNavigationRevision(); view.blockGeneration = model.navigationGeneration
        }
        let range = view.selectedRange(), replaced = !view.string.utf8.elementsEqual(text.utf8)
        // A source/result presentation includes its final fold map. Native
        // observers must not measure the restored, unstyled or half-hidden map.
        let font = model.generalPreferences.nativeFont
        view.setMergeTabWidth(tabWidth, font: font)
        let other = sourceSide.flatMap { side in model.sourceComparison?.rows.map { side == .mine ? $0.theirs : $0.mine } }
        let states = sourceCells?.map(\.state) ?? model.resultStates
        let style = MergeEditorPresentationCache.Style(font: font, tabWidth: tabWidth, inline: model.showInlineDiff && !model.preparing, word: model.inlineWordDiff, maximumInlineLength: model.generalPreferences.maximumInlineLength, palette: MergePalette.revision, mode: editable ? 3 : sourceSide == .mine ? 4 : 5)
        let rendered = view.presentationCache.value(text: text, cells: sourceCells, peers: other, states: states, style: style) {
            var missingOffsets: [Int] = []
            let value = NSMutableAttributedString(string: text)
            let entire = NSRange(location: 0, length: (text as NSString).length)
            value.addAttributes([.foregroundColor: MergePalette.foreground(.normal), .backgroundColor: MergePalette.color(MergeSourceState.normal), .font: model.generalPreferences.nativeFont, .paragraphStyle: view.defaultParagraphStyle ?? NSParagraphStyle.default], range: entire)
            if editable {
                missingOffsets = []
                let states = sourceCells?.map(\.state) ?? model.resultStates
                for (index, range) in MergeLineEndings.lineRanges(in: text).enumerated() where states.indices.contains(index) {
                    value.addAttributes([.backgroundColor: MergePalette.color(states[index]), .foregroundColor: MergePalette.foreground(states[index])], range: range)
                }
            } else if let sourceCells {
                var offset = 0
                missingOffsets = []
                for (row, cell) in sourceCells.enumerated() {
                    let length = (cell.displayText as NSString).length + 1
                    value.addAttributes([.backgroundColor: MergePalette.color(cell.state), .foregroundColor: MergePalette.foreground(cell.state)], range: NSRange(location: offset, length: length))
                    if let sourceSide, let diff = model.inlineDifference(row, mine: sourceSide == .mine) {
                        let left = sourceSide == .theirs
                        let removal = cell.state.isRemoval
                        value.addAttribute(.backgroundColor, value: MergePalette.inlineCommon, range: NSRange(location: offset, length: length))
                        for range in left ? diff.base : diff.destination {
                            value.addAttribute(.backgroundColor, value: removal ? MergePalette.inlineRemoved : MergePalette.inlineAdded, range: NSRange(location: offset + range.location, length: range.length))
                        }
                        missingOffsets += (left ? diff.baseMissing : diff.destinationMissing).map { offset + $0 }
                    }
                    offset += length
                }
            } else { missingOffsets = [] }
            return .init(text: value, missingOffsets: missingOffsets)
        }
        let value = rendered.text
        view.inlineMissingOffsets = rendered.missingOffsets
        let entire = NSRange(location: 0, length: (text as NSString).length)
        model.updateFolding()
        view.presentationDepth += 1
        let presentationChanged = view.foldLayout.installPresentation(value, font: font, in: view, controller: editable ? model.resultFolding : model.folding)
        view.presentationDepth -= 1
        // Caret visibility and centering query TextKit geometry. They run only
        // after the complete attributed presentation has committed.
        if replaced { view.setSelectedRange(NSRange(location:min(range.location,(text as NSString).length),length:0)) }
        if editable {
            if let rawRequest = model.selectionRequest, let requested = model.alignedResultProjection?.displayRange(serializedRange:rawRequest) ?? (sourceCells == nil ? rawRequest : nil), NSMaxRange(requested) <= entire.length {
                view.installBlock(requested,caret:requested.location,trimFinalEnding:sourceCells == nil)
                view.blockSelection.centerCaret(in:view)
                DispatchQueue.main.async { if model.selectionRequest == rawRequest { model.selectionRequest = nil } }
            }
        }
        model.lineWrapping.geometryChanged = { [weak model] in model?.refreshLocatorViewport(); model?.invalidateLineRulers() }
        model.lineWrapping.update(scroll, key: label, aligned: sourceCells != nil, enabled: model.wrapLines)
        view.sourceCells = sourceCells; view.sourceLayoutRevision = model.sourceLayoutRevision; view.resultPresentationRevision = model.resultPresentationRevision
        if view.whitespaceRenderer.preferences != model.whitespaceDisplay || view.whitespaceRenderer.removal != (sourceSide == .theirs) || view.whitespaceRenderer.highlightEndings != model.showInlineDiff { view.needsDisplay = true }
        view.whitespaceRenderer.update(text: text, cells: sourceCells, otherCells: other, preferences: model.whitespaceDisplay)
        view.whitespaceRenderer.removal = sourceSide == .theirs
        view.whitespaceRenderer.highlightEndings = model.showInlineDiff
        view.mergeFindHighlights.annotationsChanged = { [weak model] in model?.refreshLocatorHighlights() }
        view.mergeFindHighlights.refresh(in: view)
        model.refreshLocatorHighlights()
        if presentationChanged { view.needsDisplay = true }
        (scroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers = sourceCells?.map(\.lineNumber)
        if let ruler = scroll.verticalRulerView as? MergeLineRuler {
            ruler.showNumbers = model.editorPreferences.showLineNumbers
            let records = sourceCells ?? zip(MergeRegexFilters.lines(text), model.resultStates).enumerated().map {
                MergeSourceCell(text:$0.element.0,lineNumber:$0.offset + 1,state:$0.element.1)
            }
            ruler.updateRecords(records, peers: other)
        }
        (scroll.verticalRulerView as? MergeLineRuler)?.updateMetrics(for: view)
        if presentationChanged { scroll.verticalRulerView?.needsDisplay = true }
        if editable { model.nativeEditorDidUpdate(view) }
        if sourceSide == .mine { DispatchQueue.main.async { [weak view, weak model] in guard let view, let model else { return }; model.applyMergeToolInitialLine(view) } }
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
        @objc func locatorScrolled(_ notification: Notification) {
            guard let scroll = (notification.object as? NSClipView)?.enclosingScrollView else { return }
            if (scroll.documentView as? MergeTextView)?.sourceCells != nil { model.sourceDidScroll(scroll) }
            else { model.refreshLocatorViewport(from:scroll) }
        }
        @objc private func sourceScrolled(_ notification: Notification) { if let sourceScroll { model.sourceDidScroll(sourceScroll) } }
        deinit { NotificationCenter.default.removeObserver(self) }
        func textDidChange(_ notification: Notification) {
            if editable, let view = notification.object as? MergeTextView {
                if view.sourceCells == nil { model.result = view.string }; view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
                model.selectedConflict = min(model.selectedConflict, max(model.blocks.count - 1, 0))
                DispatchQueue.main.async { view.updateUndoState() }
            }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard editable, let view = textView as? MergeTextView, let replacementString else { return true }
            guard view.historyAllowed else { return false }
            if view.sourceCells != nil { view.replaceAlignedRange(affectedCharRange,with:replacementString,actionName:"Typing") }
            else {
                view.replaceMergeBlock(affectedCharRange, with: replacementString, actionName: "Typing")
                view.setSelectedRange(NSRange(location: affectedCharRange.location + replacementString.utf16.count, length: 0))
            }
            return false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? MergeTextView, view.presentationDepth == 0 else { return }
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
    var mergeSourceRowsReady:Bool { get }
    func mergeContextMenu(defaults: UserDefaults, pasteboard: NSPasteboard) -> NSMenu
}
private final class MergeTextView: NSTextView, MergeEditorPresentationProviding, MergeContextMenuProviding, MergeLineNavigationProviding, MergeWhitespaceDisplaying, MergeFindProviding, MergeBlockSelecting, MergeTypingProviding, MergeMarginSelecting {
    let presentationCache = MergeEditorPresentationCache()
    var presentationDepth = 0
    var marginSelectionAllowed: Bool { navigationAllowed && window?.attachedSheet == nil }
    var marginSelectionStamp: MergeMarginStamp { .init(values:[model?.navigationGeneration ?? -1,model?.sourceLayoutRevision ?? -1,model?.folding.revision ?? -1,model?.resultFolding.revision ?? -1,navigationIntentRevision],text:model?.result ?? string) }
    func beginMarginSelection() { beginUserNavigation();model?.focusNavigation(self) }
    func selectMargin(rows:Range<Int>,selection:NSRange,caret:Int) { model?.selectMargin(in:self,rows:rows,selection:selection,caret:caret) }
    func expandMarginFold(row:Int) -> Bool {
        guard marginSelectionAllowed,let controller = foldLayout.controller,let screen = controller.projection.screenRow(containing:row) else { return false }
        return controller.expand(screenRow:screen)
    }
    var chooseNavigationLine: (NSWindow, Int) async -> Int? = MergeLineNumberPrompt.choose
    var navigationPending = false
    @objc private func expandFoldedSection(_ sender: Any?) { _ = foldLayout.expandSelection(in: self) }
    var navigationCells: [MergeSourceCell]? { sourceCells }
    var mergeSourceRowsReady:Bool { (sourceCells == nil || sourceLayoutRevision == model?.sourceLayoutRevision) && (!mergeEditable || resultPresentationRevision == model?.resultPresentationRevision) }
    var navigationAllowed: Bool { model?.sourceToolsAllowed == true && mergeSourceRowsReady }
    private(set) var navigationIntentRevision = 0
    func invalidateNavigationRevision() { navigationIntentRevision &+= 1 }
    func beginUserNavigation() { model?.lineWrapping.prepareForInput(); invalidateNavigationRevision(); model?.selectionRequest = nil }
    override func scrollWheel(with event: NSEvent) { beginUserNavigation(); model?.lineWrapping.beginViewportInput(); defer { model?.lineWrapping.endViewportInput() }; super.scrollWheel(with:event) }
    func didNavigateViewport() { model?.lineWrapping.recordViewportIntent() }
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
        if modifiers == .option, event.keyCode == 125 || event.keyCode == 126 {
            model?.navigateBlock(event.keyCode == 125 ? 1 : -1,conflictsOnly:false); return true
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
    var sourceLayoutRevision = -1
    var resultPresentationRevision = -1
    let mergeFindHighlights = MergeFindHighlights()
    var mergeFindController: MergeFindWindowController?
    var mergeFindDefaults: UserDefaults { model?.comparisonDefaults ?? .standard }
    var mergeFindPaneID: Int { mergeEditable ? 3 : sourceSide == .theirs ? 1 : 2 }
    var mergeFindAllowed: Bool { window != nil && !navigationPending && mergeSourceRowsReady && model?.retired == false && model?.busy == false && model?.preparing == false && model?.confirmingQuit == false && window?.attachedSheet == nil }
    var mergeFindWritable: Bool { mergeFindAllowed && mergeEditable && isEditable && mergeSourceRowsReady }
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
        var finalCaret = ranges.last!.location + delta + replacement.utf16.count
        if sourceCells != nil {
            mergeUndoManager.beginUndoGrouping()
            var caret:Int?
            for range in ranges.reversed() {
                let previousLength = string.utf16.count
                replaceAlignedRange(range,with:replacement,actionName:ranges.count == 1 ? "Replace" : "Replace All")
                // Edits can preserve old source rows as gaps, and CRLF input
                // has only one displayed ending. Use the actual view delta.
                caret = caret.map { $0 + string.utf16.count - previousLength } ?? selectedRange().location
            }
            mergeUndoManager.endUndoGrouping(); updateUndoState()
            finalCaret = caret ?? finalCaret
        } else { replaceMergeBlock(NSRange(location:0,length:string.utf16.count),with:value as String,actionName:ranges.count == 1 ? "Replace" : "Replace All") }
        setSelectedRange(NSRange(location:min(finalCaret,string.utf16.count),length:0))
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
    var mergeOverwrite:Bool { model?.overwriteMode == true }
    var mergeTypingAllowed:Bool { mergeEditable && isEditable && historyAllowed && model?.sourceToolsAllowed == true }
    func toggleMergeOverwrite() { guard mergeTypingAllowed else {return};model?.overwriteMode.toggle();needsDisplay = true }
    var canCycleCurrentEnding:Bool {
        guard mergeTypingAllowed,let row = MergeTyping.displayRow(in:string,offset:selectedRange().location) else {return false}
        if let cells = sourceCells {return cells.indices.contains(row) && !cells[row].state.isViewEmpty && MergeTyping.cycledLine(cells[row].text) != nil}
        let lines = MergeRegexFilters.lines(string)
        return lines.indices.contains(row) && MergeTyping.cycledLine(lines[row]) != nil
    }
    func cycleCurrentEnding() {
        guard canCycleCurrentEnding,let model,let row = MergeTyping.displayRow(in:string,offset:selectedRange().location) else {return}
        do {
            if let comparison = model.sourceComparison,sourceCells != nil {
                let edit = try MergeAlignedResultTransform(comparison:comparison,presentation:model.resultPresentation,operation:.cycleLineEnding(row:row))
                guard !edit.changedRows.isEmpty else {return}
                applyFormat(presentation:edit.presentation,comparison:edit.comparison,encoding:model.encoding,ending:model.resultLineEnding,actionName:"Cycle line ending")
            } else {
                let lines = MergeRegexFilters.lines(string),line = lines[row]
                let start = lines.prefix(row).reduce(0) {$0 + $1.utf16.count}
                guard let ending = MergeLineEndings.boundaries(in:line).last,let next = MergeTyping.cycledLine(line) else {return}
                let replacement = (next as NSString).substring(from:ending.range.location)
                let caret = selectedRange().location
                replaceMergeBlock(NSRange(location:start + ending.range.location,length:ending.range.length),with:replacement,actionName:"Cycle line ending")
                setSelectedRange(NSRange(location:min(caret,string.utf16.count),length:0))
            }
        } catch {model.error = error.localizedDescription}
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
    override func keyDown(with event: NSEvent) { beginUserNavigation(); model?.lineWrapping.beginViewportInput(); defer { model?.lineWrapping.endViewportInput() }; model?.clearNavigationBlockSelection(); super.keyDown(with:event) }
    override func mouseDown(with event: NSEvent) {
        beginUserNavigation(); model?.lineWrapping.beginViewportInput(); defer { model?.lineWrapping.endViewportInput() }
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
                blockRows:mergeSelectedBlockRange.flatMap { MergeBlockSelection.rows($0,cells:cells) })
        }
        if let block = mergeSelectedBlockRange {
            if selectedRange().length > 0 { return try? MergeClipboard.documentText(selection:selectedRange(),document:string) }
            // Native blocks already exclude the final row's ending; a trailing
            // LF can instead represent a selected empty final row.
            return try? MergeClipboard.documentText(selection:block,document:string)
        }
        return try? MergeClipboard.documentText(selection:selectedRange(),document:string)
    }
    fileprivate var clipboardWritable: Bool {
        window != nil && historyAllowed
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
    func replaceDisplayRange(_ range:NSRange,with replacement:String,actionName:String) {
        if sourceCells != nil { replaceAlignedRange(range,with:replacement,actionName:actionName) }
        else { replaceMergeBlock(range,with:replacement,actionName:actionName) }
    }
    private var mergeTabWidth = 4
    var mergeUseSpaces = false
    var mergeSmartTab = false
    override func insertTab(_ sender: Any?) {
        guard mergeEditable else { super.insertTab(sender); return }
        guard isEditable, model?.busy == false else { return }
        let range = selectedRange()
        if let edit = MergeWhitespace.indentSelection(in: string, selection: range, tabWidth: mergeTabWidth, useSpaces: mergeUseSpaces, smart: mergeSmartTab) {
            if !(string as NSString).substring(with: edit.range).utf8.elementsEqual(edit.replacement.utf8) { replaceDisplayRange(edit.range, with: edit.replacement, actionName: "Indent lines") }
            return
        }
        let remaining = (string as NSString).replacingCharacters(in: range, with: "")
        let replacement = MergeWhitespace.tabInsertion(in: remaining, utf16Offset: range.location, tabWidth: mergeTabWidth, useSpaces: mergeUseSpaces, smart: mergeSmartTab)
        replaceDisplayRange(range, with: replacement, actionName: "Insert tab")
        setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
    }
    override func insertBacktab(_ sender: Any?) {
        guard mergeEditable else { super.insertBacktab(sender); return }
        guard isEditable, model?.busy == false, let edit = MergeWhitespace.indentSelection(in: string, selection: selectedRange(), tabWidth: mergeTabWidth, remove: true) else { return }
        if !(string as NSString).substring(with: edit.range).utf8.elementsEqual(edit.replacement.utf8) { replaceDisplayRange(edit.range, with: edit.replacement, actionName: "Unindent lines") }
    }
    func setMergeTabWidth(_ width: Int, font: NSFont? = nil) {
        mergeTabWidth = width
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font ?? self.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width * CGFloat(width)
        if defaultParagraphStyle != paragraph { defaultParagraphStyle = paragraph }
    }
    private let mergeUndoManager: UndoManager = { let value = UndoManager(); value.groupsByEvent = false; return value }()
    override var undoManager: UndoManager? { mergeEditable ? mergeUndoManager : super.undoManager }
    func updateUndoState() {
        guard let model else { return }
        if model.canUndo != mergeUndoManager.canUndo { model.canUndo = mergeUndoManager.canUndo }
        if model.canRedo != mergeUndoManager.canRedo { model.canRedo = mergeUndoManager.canRedo }
    }
    var historyAllowed:Bool { isEditable && mergeEditable && mergeSourceRowsReady && model?.sourceMutationsAllowed == true }
    func undoMergeEdit() { guard historyAllowed else { return }; if mergeUndoManager.canUndo { beginUserNavigation(); mergeUndoManager.undo() }; updateUndoState() }
    func redoMergeEdit() { guard historyAllowed else { return }; if mergeUndoManager.canRedo { beginUserNavigation(); mergeUndoManager.redo() }; updateUndoState() }
    func resetMergeHistory() { mergeUndoManager.removeAllActions(); updateUndoState() }
    func serializedSelection(_ range:NSRange) -> NSRange? {
        guard mergeEditable, sourceCells != nil else { return range }
        return model?.alignedResultProjection?.serializedRange(displayRange:range)
    }
    func displaySelection(_ range:NSRange) -> NSRange? {
        guard mergeEditable, sourceCells != nil else { return range }
        return model?.alignedResultProjection?.displayRange(serializedRange:range)
    }
    /// Install synchronously so edits, menus and Undo see the same row geometry
    /// before the next SwiftUI refresh.
    func installResultView() {
        guard let model else { return }
        let projection = model.alignedResultProjection
        isEditable = mergeEditable && !model.mergeToolReadOnly && model.sourceOperationsAllowed
        presentationDepth += 1
        textStorage?.beginEditing()
        foldLayout.prepare(self)
        sourceCells = projection?.cells; sourceLayoutRevision = model.sourceLayoutRevision; resultPresentationRevision = model.resultPresentationRevision
        string = projection?.displayText ?? model.result
        let entire = NSRange(location:0,length:string.utf16.count)
        textStorage?.addAttributes([.foregroundColor:MergePalette.foreground(.normal), .backgroundColor:MergePalette.color(.normal), .font:model.generalPreferences.nativeFont, .paragraphStyle:defaultParagraphStyle ?? NSParagraphStyle.default],range:entire)
        let states = sourceCells?.map(\.state) ?? model.resultStates
        for (index,range) in MergeLineEndings.lineRanges(in:string).enumerated() where states.indices.contains(index) {
            textStorage?.addAttributes([.foregroundColor:MergePalette.foreground(states[index]), .backgroundColor:MergePalette.color(states[index])],range:range)
        }
        model.updateFolding(); foldLayout.apply(to:self,controller:model.resultFolding)
        textStorage?.endEditing()
        presentationDepth -= 1
        whitespaceRenderer.update(text:string,cells:sourceCells,otherCells:nil,preferences:model.whitespaceDisplay)
        whitespaceRenderer.highlightEndings = model.showInlineDiff
        if let scroll = enclosingScrollView {
            model.lineWrapping.update(scroll,key:accessibilityLabel() ?? "Merged",aligned:sourceCells != nil,enabled:model.wrapLines)
            if let ruler = scroll.verticalRulerView as? MergeLineRuler {
                ruler.sourceNumbers = sourceCells?.map(\.lineNumber)
                let records = sourceCells ?? zip(MergeRegexFilters.lines(string),model.resultStates).enumerated().map { MergeSourceCell(text:$0.element.0,lineNumber:$0.offset + 1,state:$0.element.1) }
                ruler.updateRecords(records,peers:nil); ruler.updateMetrics(for:self); ruler.needsDisplay = true
            }
        }
        model.nativeEditorDidUpdate(self); needsDisplay = true
    }
    func replaceAlignedRange(_ range:NSRange,with replacement:String,actionName:String) {
        guard isEditable, let model, model.sourceMutationsAllowed, let comparison = model.sourceComparison else { return }
        do {
            let edit = try MergeAlignedResultEdit(comparison:comparison,presentation:model.resultPresentation,range:range,replacement:replacement,lineEnding:model.resultLineEnding)
            beginUserNavigation()
            let previous = model.resultPresentation, oldComparison = comparison, selection = NSRange(location:selectedRange().location,length:0), format = MergeFormatSelection(encoding:model.encoding,ending:model.resultLineEnding)
            mergeUndoManager.beginUndoGrouping(); defer { mergeUndoManager.endUndoGrouping(); updateUndoState() }
            mergeUndoManager.registerUndo(withTarget:self) { $0.restoreMergeText(previous.text,selection:selection,presentation:previous,comparison:oldComparison,format:format) }
            mergeUndoManager.setActionName(actionName)
            model.clearNavigationBlockSelection(clearTextSelections:true)
            model.sourceComparison = edit.comparison; model.updateResultPresentation(edit.presentation); model.result = edit.presentation.text
            installResultView(); setSelectedRange(NSRange(location:min(edit.displayCaret,string.utf16.count),length:0)); didChangeText()
        } catch { model.error = error.localizedDescription }
    }
    func applyAlignedSourceBlock(_ edit:MergeAlignedSourceBlockEdit) {
        guard isEditable, let model, model.sourceMutationsAllowed else { return }
        beginUserNavigation()
        let previous = model.resultPresentation, comparison = model.sourceComparison, selection = NSRange(location:selectedRange().location,length:0), format = MergeFormatSelection(encoding:model.encoding,ending:model.resultLineEnding)
        mergeUndoManager.beginUndoGrouping(); defer { mergeUndoManager.endUndoGrouping(); updateUndoState() }
        mergeUndoManager.registerUndo(withTarget:self) { $0.restoreMergeText(previous.text,selection:selection,presentation:previous,comparison:comparison,format:format) }
        mergeUndoManager.setActionName("Use text block")
        model.clearNavigationBlockSelection(clearTextSelections:true)
        model.sourceComparison = edit.comparison; model.updateResultPresentation(edit.presentation); model.result = edit.presentation.text
        installResultView()
        if let projection = model.alignedResultProjection, !edit.selectedRows.isEmpty {
            let ranges = projection.displayRanges, first = edit.selectedRows.lowerBound, last = edit.selectedRows.upperBound - 1
            if ranges.indices.contains(first), ranges.indices.contains(last) {
                installBlock(NSRange(location:ranges[first].location,length:NSMaxRange(ranges[last]) - ranges[first].location - 1),caret:ranges[first].location)
            }
        }
        didChangeText()
    }
    func applyFormat(presentation:MergeResultPresentation,comparison:MergeSourceComparison?,encoding:ComparisonTextEncoding,ending:MergeLineEnding,actionName:String) {
        guard mergeEditable, mergeSourceRowsReady, let model, model.sourceMutationsAllowed else { return }
        let previous = model.resultPresentation, previousComparison = model.sourceComparison
        let selection = NSRange(location:selectedRange().location,length:0), format = MergeFormatSelection(encoding:model.encoding,ending:model.resultLineEnding)
        mergeUndoManager.beginUndoGrouping(); defer { mergeUndoManager.endUndoGrouping(); updateUndoState() }
        mergeUndoManager.registerUndo(withTarget:self) { $0.restoreMergeText(previous.text,selection:selection,presentation:previous,comparison:previousComparison,format:format) }
        mergeUndoManager.setActionName(actionName)
        beginUserNavigation(); model.clearNavigationBlockSelection(clearTextSelections:true)
        model.sourceComparison = comparison; model.updateResultPresentation(presentation); model.result = presentation.text
        model.encoding = encoding; model.resultLineEnding = ending
        installResultView(); setSelectedRange(NSRange(location:min(selection.location,string.utf16.count),length:0)); didChangeText()
    }
    func replaceMergeBlock(_ range: NSRange, with replacement: String, actionName: String = "Use text block", state: MergeSourceState = .edited, sourceEdit: MergeSourceBlockEdit? = nil) {
        guard isEditable, let model, model.sourceMutationsAllowed, NSMaxRange(range) <= model.result.utf16.count else { return }
        let next = sourceEdit.flatMap { model.resultPresentation.applyingSourceBlock($0) } ?? (sourceEdit == nil ? model.resultPresentation.replacing(range,with:replacement,state:state) : nil)
        guard let next else { return }
        beginUserNavigation()
        let previous = model.resultPresentation, selection = NSRange(location:selectedRange().location,length:0), comparison = model.sourceComparison, format = MergeFormatSelection(encoding:model.encoding,ending:model.resultLineEnding)
        mergeUndoManager.beginUndoGrouping(); defer { mergeUndoManager.endUndoGrouping(); updateUndoState() }
        mergeUndoManager.registerUndo(withTarget:self) { $0.restoreMergeText(previous.text,selection:selection,presentation:previous,comparison:comparison,format:format) }
        model.updateResultPresentation(next); model.result = next.text
        mergeUndoManager.setActionName(actionName)
        installResultView()
        setSelectedRange(displaySelection(NSRange(location:range.location,length:replacement.utf16.count)) ?? NSRange(location:min(range.location,string.utf16.count),length:0))
        didChangeText()
    }
    private func restoreMergeText(_ text: String, selection: NSRange, presentation: MergeResultPresentation? = nil, comparison:MergeSourceComparison? = nil,format:MergeFormatSelection? = nil) {
        guard let model else { return }
        let previous = model.resultPresentation, previousSelection = NSRange(location:selectedRange().location,length:0), previousComparison = model.sourceComparison, previousFormat = MergeFormatSelection(encoding:model.encoding,ending:model.resultLineEnding)
        mergeUndoManager.registerUndo(withTarget:self) { $0.restoreMergeText(previous.text,selection:previousSelection,presentation:previous,comparison:previousComparison,format:previousFormat) }
        model.selectionRequest = nil
        model.sourceComparison = comparison
        if let presentation { model.updateResultPresentation(presentation) }
        model.result = text
        if let format { model.encoding = format.encoding; model.resultLineEnding = format.ending ?? model.resultLineEnding }
        installResultView()
        model.clearNavigationBlockSelection(clearTextSelections:true)
        setSelectedRange(NSRange(location:min(selection.location,string.utf16.count),length:0))
        scrollRangeToVisible(selectedRange()); didChangeText()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if mergeEditable { (window as? TextConflictNSWindow)?.mergedText = self; model?.nativeEditorDidUpdate(self) }
    }
    func selectContextBlock(at displayOffset: Int) {
        beginUserNavigation()
        window?.makeFirstResponder(self); model?.navigationSelectionChanged(self)
        let selected = selectedRange()
        if selected.length > 0, NSLocationInRange(displayOffset,selected) { return }
        if let block = mergeSelectedBlockRange, displayOffset >= block.location, displayOffset <= NSMaxRange(block) { return }
        model?.selectContextBlock(at:displayOffset,in:self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        selectContextBlock(at:characterIndexForInsertion(at:convert(event.locationInWindow,from:nil)))
        return mergeContextMenu(defaults:.standard,pasteboard:.general)
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
                let command = selectedSourceRows.flatMap { model?.sourceBlockCommand(rows:$0,choice:choice) }
                editingItem(choice.rawValue,#selector(useSourceBlock(_:)),choice.icon.contextImage(defaults:defaults),command != nil)
                menu.items.last?.tag = index; menu.items.last?.representedObject = command
            }
            let useFile = NSMenuItem(title: "Use this whole file", action: #selector(useSourceFile(_:)), keyEquivalent: "")
            editingItem("Save this pane as…", #selector(saveSourceAs(_:)), MenuIcon.mergeSaveAs.contextImage(defaults: defaults), model?.sourceMutationsAllowed == true)
            editingItem("Compare with Base", #selector(compareSourceWithBase(_:)), MenuIcon.compare.contextImage(defaults: defaults), model?.sourceToolsAllowed == true)
            let wholeCommand = model?.wholeSourceFileCommand(side: sourceSide)
            useFile.target = self; useFile.representedObject = wholeCommand; useFile.isEnabled = wholeCommand != nil; useFile.image = sourceSide.icon.contextImage(defaults: defaults); menu.addItem(useFile)
        }
        guard mergeEditable, let model else { return menu }
        menu.addItem(.separator())
        for (index, choice) in MergeBlockChoice.allCases.enumerated() {
            let item = NSMenuItem(title: choice.rawValue, action: #selector(useBlock(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; item.image = choice.icon.contextImage(defaults: defaults)
            let rows = selectedSourceRows ?? serializedSelection(mergeSelectedBlockRange ?? selectedRange()).flatMap { model.resultPresentation.navigationMap.sourceRows(resultRange:$0) }
            let command = rows.flatMap { model.sourceBlockCommand(rows:$0,choice:choice) }
            item.representedObject = command; item.isEnabled = writable && command != nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (index, command) in MergeWhitespaceCommand.allCases.enumerated() {
            let item = NSMenuItem(title: command.rawValue, action: #selector(changeWhitespace(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.isEnabled = writable && model.canChangeWhitespace(command,tabWidth:mergeTabWidth); menu.addItem(item)
        }
        let endingsItem = NSMenuItem(title: "Line endings", action: nil, keyEquivalent: "")
        let endingsMenu = NSMenu(title: "Line endings")
        let styles = MergeLineEndings.styles(in:model.resultFormatText)
        for (index, ending) in MergeLineEnding.allCases.enumerated() {
            let item = NSMenuItem(title: ending.menuTitle, action: #selector(convertLineEndings(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.state = styles == [ending] ? .on : .off; item.isEnabled = writable
            endingsMenu.addItem(item)
        }
        endingsItem.submenu = endingsMenu; menu.addItem(endingsItem)
        let encodingsItem = NSMenuItem(title: "File Encoding", action: nil, keyEquivalent: "")
        let encodingsMenu = NSMenu(title: "File Encoding")
        for (index, encoding) in MergeFormatSelection.encodingChoices(legacy:model.encoding.legacyCodePage != nil ? model.encoding : model.legacyEncoding).enumerated() {
            let item = NSMenuItem(title: encoding.rawValue, action: #selector(changeEncoding(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.representedObject = encoding.rawValue; item.state = model.encoding == encoding ? .on : .off; item.isEnabled = writable
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
        if menuItem.action == NSSelectorFromString("undo:") { return historyAllowed && mergeUndoManager.canUndo }
        if menuItem.action == NSSelectorFromString("redo:") { return historyAllowed && mergeUndoManager.canRedo }
        if menuItem.action == #selector(goToSourceLine(_:)) { return canNavigateToSourceLine }
        if menuItem.action == #selector(copyFromContext(_:)) || menuItem.action == NSSelectorFromString("copy:") { return !(clipboardText ?? "").isEmpty }
        if menuItem.action == #selector(cutFromContext(_:)) || menuItem.action == NSSelectorFromString("cut:") { return clipboardWritable && !(clipboardText ?? "").isEmpty }
        if menuItem.action == #selector(pasteFromContext(_:)) || menuItem.action == NSSelectorFromString("paste:") { return clipboardWritable && NSPasteboard.general.availableType(from: [.string]) != nil }
        if menuItem.action == #selector(changeEncoding(_:)) {
            return mergeEditable && isEditable && model?.busy == false && model?.confirmingQuit == false && (menuItem.representedObject as? String).flatMap(ComparisonTextEncoding.init(rawValue:)) != nil
        }
        if menuItem.action == #selector(changeWhitespace(_:)) {
            guard mergeEditable, isEditable, model?.busy == false, model?.confirmingQuit == false, MergeWhitespaceCommand.allCases.indices.contains(menuItem.tag) else { return false }
            return model?.canChangeWhitespace(MergeWhitespaceCommand.allCases[menuItem.tag],tabWidth:mergeTabWidth) == true
        }
        if menuItem.action == #selector(convertLineEndings(_:)) {
            return mergeEditable && isEditable && model?.busy == false && model?.confirmingQuit == false && MergeLineEnding.allCases.indices.contains(menuItem.tag)
        }
        if menuItem.action == #selector(saveSourceAs(_:)) { return sourceSide != nil && model?.sourceMutationsAllowed == true }
        if menuItem.action == #selector(compareSourceWithBase(_:)) { return sourceSide != nil && model?.sourceToolsAllowed == true }
        if menuItem.action == #selector(useSourceFile(_:)) {
            guard sourceSide != nil, let command = menuItem.representedObject as? TextConflictWindowModel.SourceBlockCommand else { return false }
            return model?.canPerformSourceBlock(command) == true
        }
        if menuItem.action == #selector(useBlock(_:)) {
            guard mergeEditable, isEditable, let command = menuItem.representedObject as? TextConflictWindowModel.SourceBlockCommand else { return false }
            return model?.canPerformSourceBlock(command) == true
        }
        return super.validateMenuItem(menuItem)
    }
    @objc private func saveSourceAs(_ sender: Any?) { guard let sourceSide else { return }; model?.exportSource(mine: sourceSide == .mine) }
    @objc private func compareSourceWithBase(_ sender: Any?) { guard let sourceSide else { return }; model?.compareSourceWithBase(mine: sourceSide == .mine) }
    @objc private func useSourceFile(_ sender: NSMenuItem) {
        guard sourceSide != nil, let command = sender.representedObject as? TextConflictWindowModel.SourceBlockCommand else { return }
        model?.performSourceBlock(command)
    }
    @objc private func changeEncoding(_ sender: NSMenuItem) {
        guard mergeEditable,isEditable,let raw = sender.representedObject as? String,let encoding = ComparisonTextEncoding(rawValue:raw) else {return}
        model?.changeEncoding(encoding)
    }
    @objc private func convertLineEndings(_ sender:NSMenuItem) {
        guard historyAllowed, MergeLineEnding.allCases.indices.contains(sender.tag) else { return }
        model?.changeLineEnding(MergeLineEnding.allCases[sender.tag])
    }
    @objc private func changeWhitespace(_ sender:NSMenuItem) {
        guard historyAllowed, MergeWhitespaceCommand.allCases.indices.contains(sender.tag) else { return }
        model?.changeWhitespace(MergeWhitespaceCommand.allCases[sender.tag],tabWidth:mergeTabWidth)
    }
    private var selectedSourceRows: Range<Int>? {
        guard let cells = sourceCells, mergeSourceRowsReady else { return nil }
        let selection = mergeSelectedBlockRange ?? selectedRange()
        if let block = mergeSelectedBlockRange { return MergeBlockSelection.rows(block,cells:cells) }
        let lines = MergeFindLine.displayCells(cells)
        guard let start = lines.lastIndex(where: { $0.offset <= selection.location }) else { return nil }
        let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let end = lines.lastIndex(where: { $0.offset <= last }) ?? start
        return start..<(end + 1)
    }
    @objc private func useSourceBlock(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? TextConflictWindowModel.SourceBlockCommand else { return }
        model?.performSourceBlock(command)
    }
    @objc private func useBlock(_ sender: NSMenuItem) {
        guard mergeEditable, isEditable, let command = sender.representedObject as? TextConflictWindowModel.SourceBlockCommand else { return }
        model?.performSourceBlock(command)
    }
}
final class MergeLineRuler: NSRulerView {
    var sourceNumbers: [Int?]? { didSet { if sourceNumbers != oldValue { needsDisplay = true } } }
    var markedRows = Set<Int>() { didSet { if markedRows != oldValue { needsDisplay = true } } }
    var showNumbers = true { didSet { if showNumbers != oldValue { needsDisplay = true } } }
    var movedRows: [Int:String] = [:] { didSet { if movedRows != oldValue { needsDisplay = true } } }
    var followMovedRow: (Int) -> Void = { _ in }
    private var visibleMovedRows: [(NSRect,Int)] = []
    private var visibleSymbols: [(NSRect,Int)] = []
    private var records: [MergeSourceCell] = [], peers: [MergeSourceCell]?
    private(set) var presentation = MergeMarginPresentation(cells: [])
    private struct Anchor {
        let stamp: MergeMarginStamp
        let offset: Int, row: Int
    }
    private struct Gesture {
        let anchor: Anchor
        let text: String
        let size: NSSize
        let font: NSFont?
        var event: NSEvent
    }
    private var anchor: Anchor?, gesture: Gesture?, dragTimer: Timer?
    var marginDragging: Bool { gesture != nil }
    var marginAutoScrolling: Bool { dragTimer != nil }
    static func retire(in root: NSView?) {
        guard let root else { return }
        if let ruler = root as? MergeLineRuler { ruler.stopDragging();ruler.anchor = nil }
        root.subviews.forEach { retire(in:$0) }
    }
    private var editor: NSTextView? { clientView as? NSTextView ?? scrollView?.documentView as? NSTextView }
    private func hit(_ event: NSEvent, clamp: Bool = false) -> (row:Int,offset:Int,marker:Bool)? {
        guard let view = editor, let layout = view.layoutManager, let container = view.textContainer else { return nil }
        layout.ensureLayout(for:container)
        let point = view.convert(event.locationInWindow,from:nil), origin = view.textContainerOrigin
        let ranges = MergeLineEndings.lineRanges(in:view.string)
        var nearest: (Int,Int,Bool)?, distance = CGFloat.greatestFiniteMagnitude
        for (row,range) in ranges.enumerated() where range.length > 0 {
            if view.textStorage?.attribute(.mergeFoldHidden,at:range.location,effectiveRange:nil) != nil { continue }
            let glyphs = layout.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
            let frame = layout.boundingRect(forGlyphRange:glyphs,in:container).offsetBy(dx:origin.x,dy:origin.y)
            let marker = view.textStorage?.attribute(.mergeFoldMarker,at:range.location,effectiveRange:nil) != nil
            let y = min(max(point.y,frame.minY),max(frame.minY,frame.maxY - 0.01))
            let offset = layout.characterIndex(for:NSPoint(x:0,y:y - origin.y),in:container,fractionOfDistanceBetweenInsertionPoints:nil)
            let value = (row,min(max(offset,range.location),NSMaxRange(range) - 1),marker)
            if point.y >= frame.minY && point.y < frame.maxY { return value }
            let delta = abs(point.y - y)
            if clamp, delta < distance { nearest = value; distance = delta }
        }
        return nearest
    }
    private func stopDragging() { dragTimer?.invalidate();dragTimer = nil;gesture = nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopDragging();anchor = nil }
        super.viewWillMove(toWindow:newWindow)
    }
    deinit { dragTimer?.invalidate() }
    func updateRecords(_ next: [MergeSourceCell], peers nextPeers: [MergeSourceCell]?) {
        func same(_ a: [MergeSourceCell], _ b: [MergeSourceCell]) -> Bool {
            a.count == b.count && zip(a,b).allSatisfy { $0.state == $1.state && $0.text.utf8.elementsEqual($1.text.utf8) }
        }
        guard !same(records,next) || (peers == nil) != (nextPeers == nil) || !same(peers ?? [],nextPeers ?? []) else { return }
        stopDragging();anchor = nil;records = next; peers = nextPeers
        presentation = MergeMarginPresentation(cells:next,peers:nextPeers); needsDisplay = true
    }
    func symbol(at row: Int) -> MergeMarginSymbol? { presentation.symbol(at:row,moved:movedRows[row] != nil,marked:markedRows.contains(row)) }
    private static let artwork: [MergeMarginSymbol:NSImage] = {
        let icons: [MergeMarginSymbol:MenuIcon] = [.added:.mergeLineAdded,.removed:.mergeLineRemoved,.conflict:.mergeLineConflict,.ignoredConflict:.mergeLineIgnored,.edited:.mergeLineEdited,.equal:.mergeLineEqual,.whitespace:.mergeLineWhitespace,.moved:.mergeMoved,.marked:.mergeMarked]
        return icons.compactMapValues { $0.image(size:16) }
    }()
    override func mouseDown(with event: NSEvent) {
        stopDragging()
        guard event.window === window, let view = editor, let target = view as? MergeMarginSelecting,
              target.marginSelectionAllowed, let hit = hit(event) else { return }
        let previous = anchor?.stamp == target.marginSelectionStamp ? anchor:nil
        let ranges = MergeSourceComparison.navigationRanges(text:view.string)
        guard ranges.indices.contains(hit.row) else { return }
        let oldCaret = min(view.selectionAffinity == .upstream ? NSMaxRange(view.selectedRange()):view.selectedRange().location,view.string.utf16.count)
        let oldRow = ranges.lastIndex(where: { $0.location <= oldCaret }) ?? hit.row
        target.beginMarginSelection();view.window?.makeFirstResponder(view)
        if event.clickCount == 2 {
            if movedRows[hit.row] != nil { anchor = nil;followMovedRow(hit.row);return }
            if hit.marker, target.expandMarginFold(row:hit.row) { anchor = nil;return }
        }
        let extending = event.modifierFlags.contains(.shift)
        let start = extending ? (previous.map { ($0.offset,$0.row) } ?? (oldCaret,oldRow)):(hit.offset,hit.row)
        anchor = Anchor(stamp:target.marginSelectionStamp,offset:start.0,row:start.1)
        guard let anchor else { return }
        let selection = extending ? NSRange(location:min(start.0,hit.offset),length:abs(hit.offset - start.0)):ranges[hit.row]
        target.selectMargin(rows:min(start.1,hit.row)..<(max(start.1,hit.row) + 1),selection:selection,caret:hit.offset)
        gesture = Gesture(anchor:anchor,text:view.string,size:scrollView?.contentSize ?? .zero,font:view.font,event:event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard event.window === window, var gesture else { return }
        gesture.event = event;self.gesture = gesture;updateDrag()
    }
    private func updateDrag() {
        guard let gesture, let view = editor, let target = view as? MergeMarginSelecting,
              window?.isVisible == true, target.marginSelectionAllowed, target.marginSelectionStamp == gesture.anchor.stamp,
              gesture.text.utf8.elementsEqual(view.string.utf8),gesture.size == scrollView?.contentSize,gesture.font == view.font else { stopDragging();anchor = nil;return }
        let point = view.convert(gesture.event.locationInWindow,from:nil)
        let outside = point.y < view.visibleRect.minY || point.y >= view.visibleRect.maxY
        if outside {
            _ = view.autoscroll(with:gesture.event)
            if dragTimer == nil {
                let timer = Timer(timeInterval:0.05,repeats:true) { [weak self] _ in Task { @MainActor in self?.updateDrag() } }
                dragTimer = timer;RunLoop.main.add(timer,forMode:.common)
            }
        } else { dragTimer?.invalidate();dragTimer = nil }
        guard let hit = hit(gesture.event,clamp:true) else { return }
        let start = gesture.anchor
        target.selectMargin(rows:min(start.row,hit.row)..<(max(start.row,hit.row) + 1),selection:NSRange(location:min(start.offset,hit.offset),length:abs(hit.offset - start.offset)),caret:hit.offset)
    }
    override func mouseUp(with event: NSEvent) { stopDragging() }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let row = visibleSymbols.first(where:{$0.0.contains(point)})?.1 else { return "" }
        return symbol(at:row) == .moved ? movedRows[row] ?? "Moved block" : symbol(at:row)?.title ?? ""
    }
    func updateMetrics(for view: NSTextView) {
        let count = sourceNumbers?.compactMap { $0 }.max() ?? MergeLineEndings.lineRanges(in: view.string).count
        let font = NSFont.monospacedDigitSystemFont(ofSize: view.font?.pointSize ?? 10, weight: .regular)
        let width = (String(max(1, count)) as NSString).size(withAttributes: [.font: font]).width + 22
        let next = showNumbers ? max(45, ceil(width)) : 20
        if ruleThickness != next { ruleThickness = next }
    }
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) { super.init(scrollView: scrollView, orientation: orientation); ruleThickness = 45; setAccessibilityLabel("Line changes and line numbers") }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? NSTextView ?? scrollView?.documentView as? NSTextView, let manager = view.layoutManager, let container = view.textContainer else { return }
        removeAllToolTips();visibleMovedRows = [];visibleSymbols = []
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
            if !folded, symbol(at:line - 1) != nil {
                let paragraph = manager.boundingRect(forGlyphRange:manager.glyphRange(forCharacterRange:range,actualCharacterRange:nil),in:container).offsetBy(dx:view.textContainerOrigin.x,dy:view.textContainerOrigin.y)
                let area = NSRect(x:bounds.minX,y:convert(paragraph.origin,from:view).y,width:ruleThickness,height:max(14,paragraph.height)).intersection(bounds)
                if !area.isEmpty {
                    visibleSymbols.append((area,line - 1));addToolTip(area,owner:self,userData:nil)
                    if movedRows[line - 1] != nil { visibleMovedRows.append((area,line - 1)) }
                }
            }
            if !folded && frame.maxY >= visible.minY && frame.minY <= visible.maxY {
                let number = sourceNumbers == nil ? line : (sourceNumbers!.indices.contains(line - 1) ? sourceNumbers![line - 1] : nil)
                let value = number.map(String.init) as NSString? ?? ""
                if showNumbers { value.draw(at: NSPoint(x: ruleThickness - value.size(withAttributes: attrs).width - 6, y: convert(frame.origin, from: view).y), withAttributes: attrs) }
                if let symbol = symbol(at:line - 1) {
                    Self.artwork[symbol]?.draw(in:NSRect(x:2,y:convert(frame.origin,from:view).y,width:16,height:16))
                }
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


/// Reuses the native three-pane editor inside the patch viewer's file panel.
struct PatchMergeEditor:View {
    @ObservedObject var model:TextConflictWindowModel
    var body:some View {TextConflictDialog(model:model)}
}
