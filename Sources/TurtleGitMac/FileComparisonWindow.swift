import AppKit
import SwiftUI
import TurtleGitCore

@MainActor private final class FileComparisonNativeWindow: NSWindow {
    weak var model: FileComparisonWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", (firstResponder as? NSTextView)?.isFieldEditor != true {
            if flags.contains(.shift) { model?.redo() } else { model?.undo() }; return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "s" { model?.save(); return true }
        if flags == .command, event.charactersIgnoringModifiers == "f" { model?.find(.showFindInterface); return true }
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            model?.find(flags.contains(.shift) ? .previousMatch : .nextMatch); return true
        }
        if event.keyCode == 96 { model?.load(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class FileComparisonWindowController: NSWindowController, NSWindowDelegate {
    let model: FileComparisonWindowModel
    var onClosed: () -> Void = {}
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, path: String) {
        self.init(model: FileComparisonWindowModel(repository: repository, access: access, snapshot: snapshot, path: path))
    }
    convenience init(comparison: WorkingFileComparison, permissions: [RepositoryAccessLease]) {
        self.init(model: FileComparisonWindowModel(comparison: comparison, permissions: permissions))
    }
    convenience init(repository: GitRepository, access: RepositoryAccessLease?, comparison: HistoricalWorkingFileComparison, permission: RepositoryAccessLease) {
        self.init(model: FileComparisonWindowModel(repository: repository, access: access, comparison: comparison, permission: permission))
    }
    private init(model: FileComparisonWindowModel) {
        self.model = model
        let path = model.path
        let window = FileComparisonNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(path) – TurtleGitMerge"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: 440)
        window.contentViewController = NSHostingController(rootView: FileComparisonDialog(model: model))
        super.init(window: window); window.model = model; window.delegate = self; model.window = window
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.setFrameAutosaveName("TurtleGit.TwoFileDiff"); window.center()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil, !model.busy, !model.confirmingQuit else { return false }
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to “\(model.unsavedFilesDescription)” before closing?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.saveAll { [weak self] saved in if saved { self?.window?.performClose(nil) } }; return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) { model.resetHistory(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class FileComparisonWindowModel: ObservableObject {
    private let repository: GitRepository?
    private var historicalWorkingComparison: HistoricalWorkingFileComparison?
    private var workingComparison: WorkingFileComparison?
    private var workingPermissions: [RepositoryAccessLease] = []
    private let access: RepositoryAccessLease?
    let snapshot: RevisionComparisonSnapshot
    let path: String
    @Published var document: FileComparisonDocument?
    @Published var alignment: FileComparisonAlignment?
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var difference = -1
    @Published var showLineNumbers = MergeEditorPreferences.load().showLineNumbers
    @Published var showInlineDiff = true
    @Published var inlineWordDiff = false
    @Published var editorPreferences = MergeEditorPreferences.load()
    @Published var tabWidths: [Bool: Int] = [:]
    @Published var spacePanes: [Bool: Bool] = [:]
    @Published var smartTabPanes: [Bool: Bool] = [:]
    @Published var editorConfigEnabled: [Bool: Bool] = [:]
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
        get { drafts?.editingEnabled(base: activeBase) == true }
        set { drafts?.setEditing(newValue, base: activeBase) }
    }
    func canEdit(base: Bool) -> Bool { drafts?.canEdit(base: base) == true }
    func draftText(base: Bool) -> String { drafts?.text(base: base) ?? "" }
    func updateDraft(_ text: String, base: Bool) {
        do { try drafts?.update(text: text, base: base) } catch { self.error = error.localizedDescription }
    }
    func updateAnnotations(_ value: FileComparisonEditing.Annotations, base: Bool) { drafts?.update(annotations: value, base: base) }
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var selectedRows: Range<Int>?
    private(set) var alignmentGeneration = 0
    private struct InlineResult { let value: MergeInlineComparison? }
    private var inlineCache: [Int: InlineResult] = [:]
    private var inlineGeneration = -1
    private var cachedWordMode = false
    func inlineDifference(_ index: Int) -> MergeInlineComparison? {
        guard showInlineDiff, let alignment, alignment.rows.indices.contains(index), alignment.rows[index].changed else { return nil }
        if inlineGeneration != alignmentGeneration || cachedWordMode != inlineWordDiff {
            inlineCache = [:]; inlineGeneration = alignmentGeneration; cachedWordMode = inlineWordDiff
        }
        if let cached = inlineCache[index] { return cached.value }
        let row = alignment.rows[index]
        let value = row.base.lineNumber != nil && row.destination.lineNumber != nil ? MergeInlineComparison(base: row.base.displayText, destination: row.destination.displayText, word: inlineWordDiff) : nil
        inlineCache[index] = InlineResult(value: value); return value
    }
    weak var window: NSWindow?
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var canTransfer: Bool { canTransfer(toBase: activeBase) }
    func canTransfer(toBase base: Bool) -> Bool { drafts?.editingEnabled(base: base) == true && alignment != nil && !busy && !confirmingQuit }
    var transferRows: Range<Int>? { selectedRows ?? alignment.flatMap { $0.differences.indices.contains(difference) ? $0.differences[difference] : nil } }
    func useOtherBlock(_ choice: FileComparisonEditing.BlockChoice = .other, targetBase: Bool? = nil) {
        let base = targetBase ?? activeBase
        guard canTransfer(toBase: base), let alignment, let rows = transferRows else { return }
        do { let edit = try FileComparisonEditing.takingOtherRows(alignment, rows: rows, targetBase: base, choice: choice); editorActions[base]?.replace(edit.text, edit.caret, choice == .other ? rows : nil) }
        catch { self.error = error.localizedDescription }
    }
    func useOtherFile(targetBase: Bool? = nil) {
        let base = targetBase ?? activeBase
        guard canTransfer(toBase: base), let alignment else { return }
        if alignment.rows.isEmpty { editorActions[base]?.replace("", 0, nil); return }
        do { let edit = try FileComparisonEditing.takingOtherRows(alignment, rows: alignment.rows.indices, targetBase: base); editorActions[base]?.replace(edit.text, 0, alignment.rows.indices) }
        catch { self.error = error.localizedDescription }
    }
    func markBlock(_ marked: Bool, targetBase: Bool? = nil) {
        let base = targetBase ?? activeBase
        guard canTransfer(toBase: base), let rows = transferRows else { return }
        var value = annotations(base: base)
        if marked { value.marked.formUnion(rows) } else { value.marked.subtract(rows) }
        editorActions[base]?.annotate(value)
    }
    func leaveOnlyMarked(targetBase: Bool? = nil) {
        let base = targetBase ?? activeBase
        guard canTransfer(toBase: base), let alignment else { return }
        do { editorActions[base]?.keep(try FileComparisonEditing.leavingOnlyMarked(alignment, targetBase: base, annotations: annotations(base: base))) }
        catch { self.error = error.localizedDescription }
    }
    func encoding(base: Bool) -> ComparisonTextEncoding? { drafts?.encoding(base: base) }
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
        var cursor = 0, row = cells.count
        for (index, cell) in cells.enumerated() { cursor += (cell.displayText as NSString).length + 1; if range.location < cursor { row = index; break } }
        let index = alignment.differences.firstIndex { $0.contains(row) } ?? -1
        if difference != index { difference = index }
    }
    func export(base: Bool) {
        guard !busy, !confirmingQuit, let window, window.attachedSheet == nil, let document else { return }
        let content = base ? document.base : document.destination
        do {
            let bytes = try drafts?.exported(base: base) ?? content.bytes
            let panel = NSSavePanel(); panel.nameFieldStringValue = (content.path as NSString).lastPathComponent; panel.canCreateDirectories = true; panel.directoryURL = snapshot.root
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try bytes.write(to: url, options: .atomic) } catch { self?.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    var editableBase: Bool? { drafts?.canEdit(base: activeBase) == true ? activeBase : nil }
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
        guard !busy, !confirmingQuit, activeBase != base else { return }
        activeBase = base; selectedRows = nil; selectionRequest = nil; selectEditorActions()
    }
    func resetHistory() { for actions in editorActions.values { actions.reset() }; selectEditorActions() }
    var selectionRequest: Int?
    private var scrolls: [Bool: NSScrollView] = [:]
    private var synchronizing = false
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, path: String) {
        self.repository = repository; self.access = access; self.snapshot = snapshot; self.path = path
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
        guard !GitRuntime.isAppStoreBuild || [comparison.base, comparison.destination].allSatisfy({ file in
            workingPermissions.contains { $0.hasSecurityScope && $0.contains(file) }
        }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load() {
        guard !busy, !confirmingQuit else { return }
        if dirty {
            let alert = NSAlert(); alert.messageText = "Save changes to “\(unsavedFilesDescription)” before reloading?"
            alert.addButton(withTitle: "Save and Reload"); alert.addButton(withTitle: "Reload Without Saving"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: saveAll { [weak self] saved in if saved { self?.load() } }; return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let value: FileComparisonDocument
                if let historicalWorkingComparison, let repository {
                    try validateHistoricalWorkingAccess(historicalWorkingComparison)
                    value = try await repository.comparisonFile(historicalWorkingComparison)
                } else if let workingComparison {
                    try validateWorkingAccess(workingComparison)
                    value = try workingComparison.read()
                } else if let repository {
                    if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                    value = try await repository.comparisonFile(snapshot, path: path)
                } else { throw RevisionComparisonFailure.selection }
                document = value
                drafts = FileComparisonDrafts(value)
                activeBase = drafts?.preferredBase ?? false
                selectEditorActions()
                rebuildAlignment(); resetHistory(); selectionRequest = nil
                difference = -1
                reloadEditorConfig()
            } catch { self.error = error.localizedDescription }
        }
    }
    func rebuildAlignment() {
        guard let document else { return }
        alignmentGeneration += 1; selectedRows = nil
        let a = drafts?.text(base: true) ?? document.base.text
        let b = drafts?.text(base: false) ?? document.destination.text
        alignment = a.flatMap { old in b.map { FileComparisonAlignment(base: old, destination: $0) } }
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
    private func save(sides: [Bool], completion: ((Bool) -> Void)?) {
        guard !busy, document != nil else { completion?(false); return }
        busy = true
        Task {
            var saved = false
            defer { busy = false; completion?(saved) }
            do {
                for base in sides where drafts?.isDirty(base: base) == true {
                    guard let document, let text = drafts?.text(base: base) else { throw FileComparisonEditFailure.unsupported }
                    let result: FileComparisonDocument
                    if let historicalWorkingComparison {
                        try validateHistoricalWorkingAccess(historicalWorkingComparison)
                        guard base else { throw FileComparisonEditFailure.unsupported }
                        guard try authorizeWorkingReplacement(at: historicalWorkingComparison.workingFile) else { return }
                        result = try historicalWorkingComparison.saveBase(document, text: text, encoding: drafts?.encoding(base: base))
                    } else if let workingComparison {
                        try validateWorkingAccess(workingComparison)
                        guard try authorizeWorkingReplacement(at: base ? workingComparison.base : workingComparison.destination) else { return }
                        result = try workingComparison.save(document, base: base, text: text, encoding: drafts?.encoding(base: base))
                    } else if let repository {
                        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                        result = try await repository.saveComparisonFile(snapshot, document: document, base: base, text: text, encoding: drafts?.encoding(base: base))
                    } else { throw RevisionComparisonFailure.selection }
                    self.document = result
                    try drafts?.didSave(base ? result.base : result.destination, base: base)
                }
                rebuildAlignment(); saved = true
            } catch { self.error = error.localizedDescription }
        }
    }
    func remapOtherAnnotations(from old: FileComparisonAlignment, to new: FileComparisonAlignment, changedBase: Bool) {
        drafts?.remapAnnotations(from: old, to: new, base: !changedBase)
    }
    func register(_ scroll: NSScrollView, base: Bool) { scrolls[base] = scroll }
    func scrolled(_ source: NSScrollView) {
        guard !synchronizing else { return }; synchronizing = true; defer { synchronizing = false }
        for target in scrolls.values where target !== source {
            var point = target.contentView.bounds.origin; point.y = source.contentView.bounds.origin.y
            target.contentView.scroll(to: target.contentView.constrainBoundsRect(NSRect(origin: point, size: target.contentView.bounds.size)).origin)
            target.reflectScrolledClipView(target.contentView)
        }
    }
    func navigate(_ step: Int) {
        guard let alignment, !alignment.differences.isEmpty else { return }
        difference = min(alignment.differences.count - 1, max(0, difference + step))
        let row = alignment.differences[difference].lowerBound
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
            ?? (scrolls[false]?.documentView as? NSTextView)
        let item = NSMenuItem(); item.tag = action.rawValue; text?.performTextFinderAction(item)
    }
}
private struct FileComparisonDialog: View {
    @ObservedObject var model: FileComparisonWindowModel
    private func pane(base: Bool) -> some View {
        let content = base ? model.document?.base : model.document?.destination
        return VStack(alignment: .leading, spacing: 5) {
            Text(base ? "Base" : "Mine").font(.headline)
            Text((content?.path ?? model.path) + " : " + (content?.revision.label ?? (base ? model.snapshot.from.label : model.snapshot.to.label))).font(.system(.caption, design: .monospaced)).lineLimit(1).help(content?.revision.label ?? "")
            if let alignment = model.alignment {
                FileComparisonEditor(model: model, cells: alignment.rows.map { base ? $0.base : $0.destination }, base: base)
            } else if let content {
                if let text = content.text { FileComparisonEditor(model: model, cells: FileComparisonAlignment(base: text, destination: text).rows.map(\.base), base: base) }
                else if let image = NSImage(data: content.bytes) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ScrollView { Text("Binary or unsupported text encoding · \(content.bytes.count) bytes\n\n" + content.bytes.prefix(4096).enumerated().map { ($0.offset % 16 == 0 ? "\n" : " ") + String(format: "%02X", $0.element) }.joined()).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            } else { Color(nsColor: .textBackgroundColor) }
            HStack {
                MergeFormatControls(label: base ? "Base" : "Mine", encoding: model.encoding(base: base) ?? content?.encoding, text: content?.text == nil ? nil : model.draftText(base: base), editable: model.canTransfer(toBase: base), changeEncoding: { model.changeEncoding($0, base: base) }, changeEnding: { model.changeLineEnding($0, base: base) })
                Spacer()
                MergeTabControls(label: base ? "Base" : "Mine", tabWidth: model.tabWidth(base: base), useSpaces: model.useSpaces(base: base), smartTab: model.smartTab(base: base), changeWidth: { model.tabWidths[base] = $0 }, changeSpaces: { model.spacePanes[base] = $0 }, changeSmart: { model.smartTabPanes[base] = $0 }, editorConfigEnabled: model.editorConfigEnabled[base] == true, editorConfigLoaded: model.editorConfigLoaded[base] == true, changeEditorConfig: { model.setEditorConfig($0, base: base) }).disabled(model.busy || model.confirmingQuit || model.editorConfigLoading.contains(base))
                Text("\(content?.mode ?? "Absent") · \(content?.bytes.count ?? 0) saved bytes").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.save() } label: { CommandLabel(title: "Save", icon: .mergeSave) }.disabled(!model.activeDirty)
                Menu { Button("Save left pane as…") { model.export(base: true) }; Button("Save right pane as…") { model.export(base: false) } } label: { CommandLabel(title: "Save As", icon: .mergeSaveAs) }.disabled(model.document == nil)
                Button { model.undo() } label: { Image(nsImage: MenuIcon.mergeUndo.image() ?? NSImage()) }.help("Undo").accessibilityLabel("Undo").disabled(!model.canUndo)
                Button { model.redo() } label: { Image(nsImage: MenuIcon.mergeRedo.image() ?? NSImage()) }.help("Redo").accessibilityLabel("Redo").disabled(!model.canRedo)
                Button { model.load() } label: { CommandLabel(title: "Reload", icon: .mergeReload) }
                Button { model.navigate(-1) } label: { CommandLabel(title: "Previous difference", icon: .mergePreviousConflict) }.disabled(model.difference <= 0)
                Button { model.navigate(1) } label: { CommandLabel(title: "Next difference", icon: .mergeNextConflict) }.disabled(model.alignment?.differences.isEmpty != false || model.difference >= (model.alignment?.differences.count ?? 0) - 1)
                Button { model.find(.showFindInterface) } label: { CommandLabel(title: "Find", icon: .mergeFind) }.disabled(model.alignment == nil)
                Spacer()
            }.padding(10).disabled(model.busy || model.confirmingQuit)
            HStack {
                Toggle("Enable editing", isOn: $model.editingEnabled).disabled(model.editableBase == nil || model.busy || model.confirmingQuit)
                Spacer()
                Toggle("Inline diff", isOn: $model.showInlineDiff).disabled(model.alignment == nil)
                Toggle("Word diff", isOn: $model.inlineWordDiff).disabled(!model.showInlineDiff || model.alignment == nil)
                Toggle("Line numbers", isOn: $model.showLineNumbers)
            }.toggleStyle(.checkbox).padding(.horizontal, 10).padding(.bottom, 8)
            HStack {
                Menu {
                    Button { model.useOtherBlock() } label: { CommandLabel(title: "Use other block", icon: .mergeUseTheirs) }
                    Button { model.useOtherBlock(.currentThenOther) } label: { CommandLabel(title: "Use both blocks, this one first", icon: .mergeMineThenTheirs) }
                    Button { model.useOtherBlock(.otherThenCurrent) } label: { CommandLabel(title: "Use both blocks, this one last", icon: .mergeTheirsThenMine) }
                } label: { CommandLabel(title: "Use other block", icon: .mergeUseTheirs) }.disabled(!model.canTransfer || model.transferRows == nil)
                Button { model.useOtherFile() } label: { CommandLabel(title: "Use other file", icon: .mergeUseTheirs) }.disabled(!model.canTransfer)
                Spacer()
            }.padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            HSplitView { pane(base: true); pane(base: false) }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.alignment.map { "\($0.differences.count) difference(s)" } ?? "").font(.caption)
                Spacer(); Text(model.dirty ? "Modified · working file not saved" : model.editingEnabled && model.editableBase != nil ? "Editing working file" : "Read-only comparison").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.onAppear { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .mergeEditorPreferencesChanged)) { _ in model.refreshPreferences() }
        .alert("Comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
private struct FileComparisonEditor: NSViewRepresentable {
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
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
            keep: { [weak coordinator = context.coordinator] text in coordinator?.replace(text, caret: 0, clearMarks: true) }
        ))
        view.history = context.coordinator.history
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        model.register(scroll, base: base)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.cells = cells; context.coordinator.base = base
        (view as? FileComparisonTextView)?.sourceCells = cells
        view.isEditable = model.editingEnabled && model.editableBase == base && !model.busy && !model.confirmingQuit
        let value = Self.attributed(cells, font: view.font!, model: model, base: base)
        (view as? FileComparisonTextView)?.missingOffsets = Self.missingOffsets(cells, model: model, base: base)
        view.needsDisplay = true
        if !view.string.utf8.elementsEqual(value.string.utf8) { view.textStorage?.setAttributedString(value) }
        else { value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in view.textStorage?.setAttributes(attributes, range: range) } }
        scroll.rulersVisible = model.showLineNumbers
        (scroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers = cells.map(\.lineNumber)
        (scroll.verticalRulerView as? MergeLineRuler)?.markedRows = model.annotations(base: base).marked
        scroll.verticalRulerView?.needsDisplay = true
        if model.editableBase == base, let caret = model.selectionRequest {
            let offset = FileComparisonEditing.displayOffset(sourceOffset: caret, cells: cells)
            view.setSelectedRange(NSRange(location: min(offset, (view.string as NSString).length), length: 0))
            view.scrollRangeToVisible(view.selectedRange())
            DispatchQueue.main.async { if model.selectionRequest == caret { model.selectionRequest = nil } }
        }
    }
    static func inline(_ row: Int, model: FileComparisonWindowModel, base: Bool) -> MergeInlineComparison? {
        guard let alignment = model.alignment, alignment.rows.indices.contains(row), ((base ? alignment.rows[row].base : alignment.rows[row].destination).displayText as NSString).length <= 3000 else { return nil }
        return model.inlineDifference(row)
    }
    static func missingOffsets(_ cells: [MergeSourceCell], model: FileComparisonWindowModel, base: Bool) -> [Int] {
        var offset = 0, result: [Int] = []
        for (index, cell) in cells.enumerated() {
            if let diff = inline(index, model: model, base: base) { result += (base ? diff.baseMissing : diff.destinationMissing).map { offset + $0 } }
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
            value.append(NSAttributedString(string: cell.displayText + "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor, .backgroundColor: diff == nil ? MergePalette.color(cell.state) : MergePalette.inlineCommon, .paragraphStyle: paragraph]))
            if let diff {
                for range in base ? diff.base : diff.destination { value.addAttribute(.backgroundColor, value: base ? MergePalette.inlineRemoved : MergePalette.inlineAdded, range: NSRange(location: offset + range.location, length: range.length)) }
            }
        }
        return value
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: FileComparisonWindowModel
        weak var scroll: NSScrollView?
        var cells: [MergeSourceCell] = []
        var base = false
        let history = UndoManager()
        init(model: FileComparisonWindowModel) { self.model = model }
        @objc func scrolled(_ notification: Notification) { if let scroll { model.scrolled(scroll) } }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard model.editingEnabled, model.editableBase == base, !model.busy, !model.confirmingQuit else { return false }
            do {
                let edit = try FileComparisonEditing.applying(replacementString ?? "", range: affectedCharRange, cells: cells)
                replace(edit.text, caret: edit.caret, typing: true)
            } catch { model.error = error.localizedDescription }
            return false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange(), cells = cells, generation = model.alignmentGeneration
            DispatchQueue.main.async { if self.model.activeBase == self.base, self.model.alignmentGeneration == generation, view.selectedRange() == range { self.model.updateSelection(range, cells: cells) } }
        }
        func updateUndoState() { guard model.activeBase == base else { return }; model.canUndo = history.canUndo; model.canRedo = history.canRedo }
        func replace(_ text: String, caret: Int, restored: FileComparisonEditing.Annotations? = nil, cleared: Range<Int>? = nil, typing: Bool = false, clearMarks: Bool = false) {
            guard model.canEdit(base: base), !model.busy, !model.confirmingQuit else { return }
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
                cells = alignment.rows.map { base ? $0.base : $0.destination }
                (view as? FileComparisonTextView)?.sourceCells = cells
                view.textStorage?.setAttributedString(FileComparisonEditor.attributed(cells, font: view.font!, model: model, base: base))
                (view as? FileComparisonTextView)?.missingOffsets = FileComparisonEditor.missingOffsets(cells, model: model, base: base)
                if model.activeBase == base {
                    view.setSelectedRange(NSRange(location: min(FileComparisonEditing.displayOffset(sourceOffset: caret, cells: cells), (view.string as NSString).length), length: 0))
                }
            }
            DispatchQueue.main.async { self.updateUndoState() }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
private final class FileComparisonTextView: NSTextView, NSMenuDelegate {
    var history: UndoManager?
    weak var model: FileComparisonWindowModel?
    var baseSide = false
    var sourceCells: [MergeSourceCell] = []
    var missingOffsets: [Int] = []
    func menuDidClose(_ menu: NSMenu) {
        guard let model, model.activeBase == baseSide, !model.busy, !model.confirmingQuit,
              let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(self)
        setAccessibilityFocused(true)
    }
    override func mouseDown(with event: NSEvent) {
        model?.activatePane(base: baseSide)
        super.mouseDown(with: event)
    }
    @objc(undo:) func undoComparison(_ sender: Any?) { model?.undo() }
    @objc(redo:) func redoComparison(_ sender: Any?) { model?.redo() }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == NSSelectorFromString("undo:") { return model?.canUndo == true && model?.busy == false && model?.confirmingQuit == false }
        if item.action == NSSelectorFromString("redo:") { return model?.canRedo == true && model?.busy == false && model?.confirmingQuit == false }
        return super.validateMenuItem(item)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { model?.activatePane(base: baseSide) }
        return accepted
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        MergePalette.inlineRemoved.setFill()
        for offset in missingOffsets where offset < (string as NSString).length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
            let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
            let marker = NSRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height)
            if marker.intersects(dirtyRect) { marker.fill() }
        }
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
    override func copy(_ sender: Any?) {
        guard let text = try? FileComparisonEditing.selectedText(selectedRange(), cells: sourceCells), !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return super.menu(for: event) }
        model.updateSelection(selectedRange(), cells: sourceCells)
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        func add(_ title: String, _ action: Selector, _ icon: NSImage?, _ enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.image = icon; item.isEnabled = enabled; menu.addItem(item)
        }
        let block = model.canTransfer(toBase: false) && model.transferRows != nil
        add(baseSide ? "Use this block" : "Use other block", #selector(useBlock), MenuIcon.mergeUseTheirs.image(), block)
        add("Use both blocks, this one first", #selector(useThisFirst), MenuIcon.mergeMineThenTheirs.image(), block)
        add("Use both blocks, this one last", #selector(useThisLast), MenuIcon.mergeTheirsThenMine.image(), block)
        if model.canTransfer(toBase: true) {
            menu.addItem(.separator())
            let leftBlock = model.transferRows != nil
            add(baseSide ? "Prepend right block" : "Prepend this block to left", #selector(prependRight), MenuIcon.mergeTheirsThenMine.image(), leftBlock)
            add(baseSide ? "Use right block" : "Use this block on left", #selector(replaceByRight), MenuIcon.mergeUseTheirs.image(), leftBlock)
            add(baseSide ? "Append right block" : "Append this block to left", #selector(appendRight), MenuIcon.mergeMineThenTheirs.image(), leftBlock)
        }
        if !baseSide {
            menu.addItem(.separator())
            if let rows = model.transferRows {
                let marks = model.annotations(base: false).marked
                if rows.count > 1 || !marks.contains(rows.lowerBound) { add("Mark block", #selector(markBlock), MenuIcon.mergeMarked.image(), block) }
                if rows.count > 1 || marks.contains(rows.lowerBound) { add("Unmark block", #selector(unmarkBlock), MenuIcon.mergeMarked.image(), block) }
            }
            add("Leave only marked blocks", #selector(leaveOnlyMarked), MenuIcon.mergeMarked.image(), model.canTransfer(toBase: false))
        }
        add(baseSide ? "Use this whole file" : "Use other file", #selector(useFile), MenuIcon.mergeUseTheirs.image(), model.canTransfer(toBase: false))
        if model.canTransfer(toBase: true) {
            add(baseSide ? "Use other file" : "Use this whole file", #selector(useRightFile), MenuIcon.mergeUseTheirs.image(), true)
        }
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
            for (index, encoding) in ComparisonTextEncoding.allCases.enumerated() {
                let choice = NSMenuItem(title: encoding.rawValue, action: #selector(changeEncoding(_:)), keyEquivalent: "")
                choice.target = self; choice.tag = index; choice.state = model.encoding(base: baseSide) == encoding ? .on : .off
                encodings.addItem(choice)
            }
            let encodingItem = NSMenuItem(title: "File Encoding", action: nil, keyEquivalent: "")
            encodingItem.submenu = encodings; menu.addItem(encodingItem)

        }
        menu.addItem(.separator())
        add("Save As…", #selector(exportPane), MenuIcon.mergeSaveAs.image(), !model.busy && !model.confirmingQuit)
        add("Undo", #selector(undoEdit), MenuIcon.mergeUndo.image(), model.canUndo && !model.busy && !model.confirmingQuit)
        add("Redo", #selector(redoEdit), MenuIcon.mergeRedo.image(), model.canRedo && !model.busy && !model.confirmingQuit)
        menu.addItem(.separator())
        add("Copy", #selector(copy(_:)), MenuIcon.copy.image(), selectedRange().length > 0)
        add("Cut", #selector(cutSelection), NSImage(systemSymbolName: "scissors", accessibilityDescription: nil), isEditable && selectedRange().length > 0)
        add("Paste", #selector(paste(_:)), NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil), isEditable && NSPasteboard.general.string(forType: .string) != nil)
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
        guard ComparisonTextEncoding.allCases.indices.contains(sender.tag) else { return }
        model?.changeEncoding(ComparisonTextEncoding.allCases[sender.tag], base: baseSide)
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
    @objc private func exportPane() { model?.export(base: baseSide) }
    @objc private func undoEdit() { model?.undo() }
    @objc private func redoEdit() { model?.redo() }
    @objc private func cutSelection() { copy(nil); insertText("", replacementRange: selectedRange()) }
}
