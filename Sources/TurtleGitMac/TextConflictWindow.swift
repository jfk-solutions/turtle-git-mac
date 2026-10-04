import AppKit
import SwiftUI
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
private enum MergeSourceSide {
    case mine, theirs
    var icon: MenuIcon { self == .mine ? .mergeUseMine : .mergeUseTheirs }
}

@MainActor private final class TextConflictNSWindow: NSWindow {
    weak var mergedText: NSTextView?
    private weak var findText: NSTextView?
    private var activeText: NSTextView? { (firstResponder as? MergeTextView) ?? findText ?? mergedText }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command || modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", let undo = mergedText?.undoManager {
            if let field = firstResponder as? NSTextView, field.isFieldEditor {
                if modifiers.contains(.shift) { if field.undoManager?.canRedo == true { field.undoManager?.redo() } }
                else if field.undoManager?.canUndo == true { field.undoManager?.undo() }
                return true
            }
            if modifiers.contains(.shift) { if undo.canRedo { undo.redo() } }
            else if undo.canUndo { undo.undo() }
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers == "f" {
            find(.showFindInterface); return true
        }
        if modifiers == .command || modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            find(modifiers.contains(.shift) ? .previousMatch : .nextMatch); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    func find(_ action: NSTextFinder.Action) {
        guard let text = activeText else { return }
        findText = text
        if action == .showFindInterface, text.selectedRange().length > 0 {
            let selection = NSMenuItem(); selection.tag = NSTextFinder.Action.setSearchString.rawValue
            text.performTextFinderAction(selection)
        }
        let sender = NSMenuItem(); sender.tag = action.rawValue
        text.performTextFinderAction(sender)
    }
    override func cancelOperation(_ sender: Any?) {
        if let text = findText ?? activeText, text.enclosingScrollView?.isFindBarVisible == true {
            find(.hideFindInterface); makeFirstResponder(text)
        } else { performClose(sender) }
    }
}

@MainActor final class TextConflictWindowController: NSWindowController, NSWindowDelegate {
    let model: TextConflictWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        model = TextConflictWindowModel(repository: repository, access: access, path: path)
        let window = TextConflictNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(path) – TurtleGitMerge"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 860, height: 540)
        let hosting = NSHostingController(rootView: TextConflictDialog(model: model))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1120, height: 780))
        super.init(window: window); window.delegate = self; window.center(); window.setFrameAutosaveName("TurtleGit.TextConflict")
        model.close = { [weak window] in window?.close() }

    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.busy else { return false }
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to “\(model.path)”?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.save(markResolved: false, closeAfter: true); return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class TextConflictWindowModel: ObservableObject {
    let repository: GitRepository
    let path: String
    private let access: RepositoryAccessLease?
    @Published var document: TextConflictDocument?
    @Published var sourceComparison: MergeSourceComparison?
    @Published var result = ""
    @Published var selectedConflict = 0
    @Published var caret = NSRange(location: 0, length: 0)
    @Published var selectionRequest: NSRange?
    @Published var busy = false
    @Published var error: String?
    @Published var showBase = false
    @Published var canUndo = false
    @Published var canRedo = false
    var applyBlock: ((NSRange, String) -> Void)?
    var replaceEntireResult: ((String) -> Void)?
    var resetHistory: () -> Void = {}
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    private var sourceScrolls: [String: WeakMergeScroll] = [:]
    private var synchronizingScroll = false
    func registerSourceScroll(_ scroll: NSScrollView, label: String) { sourceScrolls[label] = WeakMergeScroll(scroll) }
    func sourceDidScroll(_ scroll: NSScrollView) {
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
    var blocks: [MergeConflictBlock] { MergeText.conflicts(in: result) }
    var dirty: Bool { document.map { !result.utf8.elementsEqual($0.initialResult.utf8) } ?? false }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String) { self.repository = repository; self.access = access; self.path = path }
    func load() {
        guard !busy else { return }
        if dirty {
            let alert = NSAlert(); alert.messageText = "Save changes to “\(path)” before reloading?"
            alert.informativeText = "Reload regenerates the merged result from the current conflict stages."
            alert.addButton(withTitle: "Save and Reload"); alert.addButton(withTitle: "Reload Without Saving"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: save(markResolved: false, reloadAfter: true); return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await reloadDocument()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func reloadDocument() async throws {
        let next = try await repository.textConflictDocument(path: path)
        let comparison = await Task.detached { MergeSourceComparison(base: next.base, mine: next.mine, theirs: next.theirs) }.value
        resetHistory()
        document = next; sourceComparison = comparison; result = next.initialResult
        selectedConflict = 0; caret = NSRange(location: 0, length: 0); selectionRequest = nil
        selectConflict(0)
    }
    func selectConflict(_ index: Int) {
        let blocks = blocks; guard !blocks.isEmpty else { return }
        selectedConflict = min(max(index, 0), blocks.count - 1); selectionRequest = blocks[selectedConflict].range
    }
    func choose(_ choice: MergeBlockChoice) {
        guard !busy, !blocks.isEmpty else { return }
        let index = min(selectedConflict, blocks.count - 1)
        do {
            if let applyBlock { let block = blocks[index]; applyBlock(block.range, block.replacement(choice)) }
            else { result = try MergeText.applying(choice, block: index, to: result) }
            selectConflict(index)
        }
        catch { self.error = error.localizedDescription }
    }
    fileprivate func useFile(_ side: MergeSourceSide) {
        guard !busy, let document else { return }
        let contents = side == .mine ? document.mine : document.theirs
        if let replaceEntireResult { replaceEntireResult(contents) }
        else { result = contents }
        selectedConflict = 0
    }
    func save(markResolved: Bool, closeAfter: Bool = false, reloadAfter: Bool = false) {
        guard !busy, let document else { return }
        if !markResolved && MergeText.hasMarkers(result) {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Save with unresolved conflict markers?"
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Save")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let text = result; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                self.document = try await repository.saveTextConflict(document, result: text, markResolved: markResolved)
                onChanged(markResolved ? "Resolved: " + path : "Saved merged result: " + path)
                if markResolved || closeAfter { close() }
                else if reloadAfter { try await reloadDocument() }
            } catch let failure as TextConflictSaveFailure {
                self.document = failure.savedDocument; self.error = failure.localizedDescription; onChanged(failure.localizedDescription)
            } catch { self.error = error.localizedDescription }
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.allowedContentTypes = [.plainText]; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(result.utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
}
@MainActor private final class WeakMergeScroll {
    weak var view: NSScrollView?
    init(_ view: NSScrollView) { self.view = view }
}
private enum MergePalette {
    static func color(_ state: MergeSourceState) -> NSColor {
        if state == .normal { return .textBackgroundColor }
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb: (Int, Int, Int)
            switch state {
            case .removed: rgb = dark ? (83, 66, 33) : (255, 200, 100)
            case .added: rgb = dark ? (83, 83, 0) : (255, 255, 0)
            case .conflicted: rgb = dark ? (83, 33, 33) : (255, 100, 100)
            case .empty: rgb = dark ? (66, 66, 66) : (200, 200, 200)
            case .normal: return .textBackgroundColor
            }
            return NSColor(calibratedRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        }
    }
}
private struct TextConflictDialog: View {
    @ObservedObject var model: TextConflictWindowModel
    func pane(_ title: String, text: String, editable: Bool = false, cells: [MergeSourceCell]? = nil, side: MergeSourceSide? = nil) -> some View {
        let displayed = cells.map { $0.map(\.displayText).joined(separator: "\n") + ($0.isEmpty ? "" : "\n") } ?? text
        return VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); if editable { Text(model.dirty ? "Modified" : "").font(.caption).foregroundStyle(.secondary) } }.padding(7).background(Color(nsColor: .controlBackgroundColor))
            MergeEditor(model: model, text: displayed, label: title, editable: editable, sourceCells: cells, sourceSide: side).frame(minWidth: 220, minHeight: 120)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.save(markResolved: false) } label: { CommandLabel(title: "Save", icon: .mergeSave) }.keyboardShortcut("s", modifiers: .command)
                Button { model.save(markResolved: true) } label: { CommandLabel(title: "Mark as resolved", icon: .mergeResolved) }.disabled(model.document == nil || MergeText.hasMarkers(model.result))
                Button { model.export() } label: { CommandLabel(title: "Save As…", icon: .mergeSaveAs) }
                Divider().frame(height: 20)
                Button { model.selectConflict(model.selectedConflict - 1) } label: { CommandLabel(title: "Previous conflict", icon: .mergePreviousConflict) }.disabled(model.blocks.isEmpty || model.selectedConflict == 0)
                Button { model.selectConflict(model.selectedConflict + 1) } label: { CommandLabel(title: "Next conflict", icon: .mergeNextConflict) }.disabled(model.blocks.isEmpty || model.selectedConflict >= model.blocks.count - 1)
                Toggle("Show Base", isOn: $model.showBase).toggleStyle(.button)
                Button { model.load() } label: { CommandLabel(title: "Reload", icon: .mergeReload) }.help("Reload the current conflict stages; offer to save an edited result first.")
                Spacer()
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegitmerge/tmerge-dug-conflicts.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }.padding(9)
            if let document = model.document {
                VSplitView {
                    HSplitView {
                        pane(document.theirsStage == 2 ? "Theirs — Branch being rebased onto" : "Theirs", text: document.theirs, cells: model.sourceComparison?.rows.map(\.theirs), side: .theirs)
                        pane(document.mineStage == 3 ? "Mine — Branch being rebased" : "Mine", text: document.mine, cells: model.sourceComparison?.rows.map(\.mine), side: .mine)
                        if model.showBase { pane("Base", text: document.base) }
                    }
                    pane("Merged · \(model.path)", text: model.result, editable: true)
                }
                HStack {
                    Text(model.blocks.isEmpty ? (MergeText.hasMarkers(model.result) ? "Incomplete conflict markers" : "No remaining conflicts") : "Conflict \(min(model.selectedConflict + 1, model.blocks.count)) of \(model.blocks.count)").foregroundStyle(model.blocks.isEmpty ? Color.secondary : .red)
                    Spacer()
                    Button { model.undo() } label: { CommandLabel(title: "Undo", icon: .mergeUndo) }.keyboardShortcut("z", modifiers: .command).disabled(!model.canUndo)
                    Button { model.redo() } label: { CommandLabel(title: "Redo", icon: .mergeRedo) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
                    Menu("Use text block") {
                        ForEach(MergeBlockChoice.allCases, id: \.self) { choice in Button { model.choose(choice) } label: { CommandLabel(title: choice.rawValue, icon: choice.icon) } }
                    }.disabled(model.blocks.isEmpty)
                    Text("Line \((model.result as NSString).substring(to: min(model.caret.location, (model.result as NSString).length)).filter { $0 == "\n" }.count + 1)").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.disabled(model.busy).onAppear { model.load() }
        .alert("Merge editor operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
private struct MergeEditor: NSViewRepresentable {
    @ObservedObject var model: TextConflictWindowModel
    let text: String
    let label: String
    let editable: Bool
    let sourceCells: [MergeSourceCell]?
    let sourceSide: MergeSourceSide?
    func makeNSView(context: Context) -> NSScrollView {
        let view = MergeTextView(); view.isRichText = false; view.allowsUndo = editable
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textContainerInset = NSSize(width: 8, height: 8)
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
                view.replaceMergeBlock(NSRange(location: 0, length: (view.string as NSString).length), with: value, actionName: "Use whole file")
            }
            model.applyBlock = { [weak view] range, value in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
                view.replaceMergeBlock(range, with: value)
            }
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.findBarPosition = .belowContent; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        scroll.documentView = view
        if sourceCells != nil { context.coordinator.attachSourceScroll(scroll, label: label) }
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true; scroll.verticalRulerView = MergeLineRuler(scrollView: scroll, orientation: .verticalRuler)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MergeTextView else { return }
        if editable { (view.window as? TextConflictNSWindow)?.mergedText = view }
        view.isEditable = editable && !model.busy; view.model = model
        let range = view.selectedRange()
        if !view.string.utf8.elementsEqual(text.utf8) { view.string = text; view.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0)) }
        let entire = NSRange(location: 0, length: (text as NSString).length)
        view.textStorage?.addAttributes([.foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.textBackgroundColor, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)], range: entire)
        if editable {
            for block in MergeText.conflicts(in: text) { view.textStorage?.addAttribute(.backgroundColor, value: MergePalette.color(.conflicted), range: block.range) }
            if let requested = model.selectionRequest, NSMaxRange(requested) <= entire.length {
                view.setSelectedRange(requested); view.scrollRangeToVisible(requested)
                DispatchQueue.main.async { if model.selectionRequest == requested { model.selectionRequest = nil } }
            }
        } else if let sourceCells {
            var offset = 0
            for cell in sourceCells {
                let length = (cell.displayText as NSString).length + 1
                view.textStorage?.addAttribute(.backgroundColor, value: MergePalette.color(cell.state), range: NSRange(location: offset, length: length))
                offset += length
            }
        }
        (scroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers = sourceCells?.map(\.lineNumber)
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
        @objc private func sourceScrolled(_ notification: Notification) { if let sourceScroll { model.sourceDidScroll(sourceScroll) } }
        deinit { NotificationCenter.default.removeObserver(self) }
        func textDidChange(_ notification: Notification) {
            if editable, let view = notification.object as? MergeTextView {
                model.result = view.string; view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
                model.selectedConflict = min(model.selectedConflict, max(model.blocks.count - 1, 0))
                DispatchQueue.main.async { view.updateUndoState() }
            }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard editable, let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            DispatchQueue.main.async {
                if self.model.caret != range { self.model.caret = range }
                let block = self.model.blocks.first(where: { NSIntersectionRange($0.range, range).length > 0 || NSLocationInRange(range.location, $0.range) })
                if let block, self.model.selectedConflict != block.id { self.model.selectedConflict = block.id }
            }
        }
    }
}
private final class MergeTextView: NSTextView {
    weak var model: TextConflictWindowModel?
    var mergeEditable = false
    var sourceSide: MergeSourceSide?
    private let mergeUndoManager = UndoManager()
    override var undoManager: UndoManager? { mergeEditable ? mergeUndoManager : super.undoManager }
    func updateUndoState() { model?.canUndo = mergeUndoManager.canUndo; model?.canRedo = mergeUndoManager.canRedo }
    func undoMergeEdit() { if mergeUndoManager.canUndo { mergeUndoManager.undo() }; updateUndoState() }
    func redoMergeEdit() { if mergeUndoManager.canRedo { mergeUndoManager.redo() }; updateUndoState() }
    func resetMergeHistory() { mergeUndoManager.removeAllActions(); updateUndoState() }
    func replaceMergeBlock(_ range: NSRange, with replacement: String, actionName: String = "Use text block") {
        guard isEditable, NSMaxRange(range) <= (string as NSString).length else { return }
        let previous = string, selection = selectedRange()
        mergeUndoManager.registerUndo(withTarget: self) { $0.restoreMergeText(previous, selection: selection) }
        mergeUndoManager.setActionName(actionName)
        textStorage?.replaceCharacters(in: range, with: replacement)
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
        didChangeText()
    }
    private func restoreMergeText(_ text: String, selection: NSRange) {
        let previous = string, previousSelection = selectedRange()
        mergeUndoManager.registerUndo(withTarget: self) { $0.restoreMergeText(previous, selection: previousSelection) }
        textStorage?.replaceCharacters(in: NSRange(location: 0, length: (string as NSString).length), with: text)
        setSelectedRange(selection); didChangeText()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if mergeEditable { (window as? TextConflictNSWindow)?.mergedText = self }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(showFind(_:)), keyEquivalent: "")
        find.target = self; find.image = MenuIcon.mergeFind.image(); menu.addItem(find)
        if let sourceSide {
            menu.addItem(.separator())
            let useFile = NSMenuItem(title: "Use this whole file", action: #selector(useSourceFile(_:)), keyEquivalent: "")
            useFile.target = self; useFile.image = sourceSide.icon.image(); menu.addItem(useFile)
        }
        guard mergeEditable, let model else { return menu }
        if selectedRange().length == 0 { setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), length: 0)) }
        menu.addItem(.separator())
        for (index, choice) in MergeBlockChoice.allCases.enumerated() {
            let item = NSMenuItem(title: choice.rawValue, action: #selector(useBlock(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; item.image = choice.icon.image()
            item.isEnabled = !model.busy && model.blocks.contains { NSIntersectionRange($0.range, selectedRange()).length > 0 || NSLocationInRange(selectedRange().location, $0.range) }
            menu.addItem(item)
        }
        return menu
    }
    @objc private func showFind(_ sender: Any?) {
        window?.makeFirstResponder(self)
        (window as? TextConflictNSWindow)?.find(.showFindInterface)
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(useSourceFile(_:)) { return sourceSide != nil && model?.document != nil && model?.busy == false }
        if menuItem.action == #selector(useBlock(_:)) {
            guard mergeEditable, isEditable, let model, !model.busy,
                  MergeBlockChoice.allCases.indices.contains(menuItem.tag) else { return false }
            let selection = selectedRange()
            return model.blocks.contains { NSIntersectionRange($0.range, selection).length > 0 || NSLocationInRange(selection.location, $0.range) }
        }
        return super.validateMenuItem(menuItem)
    }
    @objc private func useSourceFile(_ sender: NSMenuItem) {
        guard let sourceSide else { return }
        model?.useFile(sourceSide)
    }
    @objc private func useBlock(_ sender: NSMenuItem) {
        guard mergeEditable, isEditable, MergeBlockChoice.allCases.indices.contains(sender.tag), let model, !model.busy, let block = model.blocks.first(where: { NSIntersectionRange($0.range, selectedRange()).length > 0 || NSLocationInRange(selectedRange().location, $0.range) }) else { return }
        let text = block.replacement(MergeBlockChoice.allCases[sender.tag])
        replaceMergeBlock(block.range, with: text)
    }
}
private final class MergeLineRuler: NSRulerView {
    var sourceNumbers: [Int?]?
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
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let glyph = manager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            let frame = manager.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: view.textContainerInset.width, dy: view.textContainerInset.height)
            if frame.maxY >= visible.minY && frame.minY <= visible.maxY {
                let number = sourceNumbers == nil ? line : (sourceNumbers!.indices.contains(line - 1) ? sourceNumbers![line - 1] : nil)
                let value = number.map(String.init) as NSString? ?? ""
                value.draw(at: NSPoint(x: ruleThickness - value.size(withAttributes: attrs).width - 6, y: convert(frame.origin, from: view).y), withAttributes: attrs)
            }
            if frame.minY > visible.maxY { break }
            location = NSMaxRange(range); line += 1
        }
    }
}
