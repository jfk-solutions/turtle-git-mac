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
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, path: String) {
        model = FileComparisonWindowModel(repository: repository, access: access, snapshot: snapshot, path: path)
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
        let alert = NSAlert(); alert.messageText = "Save changes to “\(model.path)” before closing?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.save { [weak self] saved in if saved { self?.window?.performClose(nil) } }; return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) { model.resetHistory(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class FileComparisonWindowModel: ObservableObject {
    private let repository: GitRepository
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
    @Published var editingEnabled = false
    @Published var editedText = ""
    @Published var canUndo = false
    @Published var canRedo = false
    weak var window: NSWindow?
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var replaceText: (String, Int) -> Void = { _, _ in }
    var canTransfer: Bool { editingEnabled && editableBase != nil && alignment != nil && !busy && !confirmingQuit }
    func useOtherBlock(_ choice: FileComparisonEditing.BlockChoice = .other) {
        guard canTransfer, let alignment, let base = editableBase else { return }
        do { let edit = try FileComparisonEditing.takingOtherBlock(alignment, difference: difference, targetBase: base, choice: choice); replaceText(edit.text, edit.caret) }
        catch { self.error = error.localizedDescription }
    }
    func useOtherFile() {
        guard canTransfer, let document, let base = editableBase, let text = base ? document.destination.text : document.base.text else { return }
        replaceText(text, 0)
    }
    func export(base: Bool) {
        guard !busy, !confirmingQuit, let window, window.attachedSheet == nil, let document else { return }
        let content = base ? document.base : document.destination
        do {
            let bytes = try FileComparisonEditing.exported(content, editedText: editableBase == base ? editedText : nil)
            let panel = NSSavePanel(); panel.nameFieldStringValue = (content.path as NSString).lastPathComponent; panel.canCreateDirectories = true; panel.directoryURL = repository.root
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do { try bytes.write(to: url, options: .atomic) } catch { self?.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    var editableBase: Bool? {
        guard let document else { return nil }
        for (base, content) in [(true, document.base), (false, document.destination)] where content.revision == .workingTree && ["100644", "100755"].contains(content.mode ?? "") && content.text != nil { return base }
        return nil
    }
    var dirty: Bool { guard let document, let base = editableBase else { return false }; return !editedText.utf8.elementsEqual((base ? document.base.text! : document.destination.text!).utf8) }
    var resetHistory: () -> Void = {}
    var selectionRequest: Int?
    private var scrolls: [Bool: NSScrollView] = [:]
    private var synchronizing = false
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, path: String) {
        self.repository = repository; self.access = access; self.snapshot = snapshot; self.path = path
    }
    func load() {
        guard !busy, !confirmingQuit else { return }
        if dirty {
            let alert = NSAlert(); alert.messageText = "Save changes to “\(path)” before reloading?"
            alert.addButton(withTitle: "Save and Reload"); alert.addButton(withTitle: "Reload Without Saving"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: save { [weak self] saved in if saved { self?.load() } }; return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let value = try await repository.comparisonFile(snapshot, path: path)
                document = value
                editedText = (editableBase == true ? value.base.text : value.destination.text) ?? ""
                rebuildAlignment(); resetHistory(); selectionRequest = nil
                difference = -1
            } catch { self.error = error.localizedDescription }
        }
    }
    func rebuildAlignment() {
        guard let document else { return }
        let a = editableBase == true ? editedText : document.base.text
        let b = editableBase == false ? editedText : document.destination.text
        alignment = a.flatMap { old in b.map { FileComparisonAlignment(base: old, destination: $0) } }
    }
    func save(completion: ((Bool) -> Void)? = nil) {
        guard !busy, let document, let base = editableBase else { completion?(false); return }
        let text = editedText; busy = true
        Task {
            var saved = false
            defer { busy = false; completion?(saved) }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                self.document = try await repository.saveComparisonFile(snapshot, document: document, base: base, text: text)
                rebuildAlignment(); saved = true
            } catch { self.error = error.localizedDescription }
        }
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
            Text(base ? "Base" : "Theirs").font(.headline)
            Text((content?.path ?? model.path) + " : " + (content?.revision.label ?? (base ? model.snapshot.from.label : model.snapshot.to.label))).font(.system(.caption, design: .monospaced)).lineLimit(1).help(content?.revision.label ?? "")
            if let alignment = model.alignment {
                FileComparisonEditor(model: model, cells: alignment.rows.map { base ? $0.base : $0.destination }, base: base)
            } else if let content {
                if let text = content.text { FileComparisonEditor(model: model, cells: FileComparisonAlignment(base: text, destination: text).rows.map(\.base), base: base) }
                else if let image = NSImage(data: content.bytes) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ScrollView { Text("Binary or unsupported text encoding · \(content.bytes.count) bytes\n\n" + content.bytes.prefix(4096).enumerated().map { ($0.offset % 16 == 0 ? "\n" : " ") + String(format: "%02X", $0.element) }.joined()).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            } else { Color(nsColor: .textBackgroundColor) }
            Text("\(content?.mode ?? "Absent") · \(content?.bytes.count ?? 0) bytes").font(.caption).foregroundStyle(.secondary)
        }.padding(8).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.save() } label: { CommandLabel(title: "Save", icon: .mergeSave) }.disabled(!model.dirty)
                Menu { Button("Save left pane as…") { model.export(base: true) }; Button("Save right pane as…") { model.export(base: false) } } label: { CommandLabel(title: "Save As", icon: .mergeSaveAs) }.disabled(model.document == nil)
                Button { model.undo() } label: { Image(nsImage: MenuIcon.mergeUndo.image() ?? NSImage()) }.help("Undo").accessibilityLabel("Undo").disabled(!model.canUndo)
                Button { model.redo() } label: { Image(nsImage: MenuIcon.mergeRedo.image() ?? NSImage()) }.help("Redo").accessibilityLabel("Redo").disabled(!model.canRedo)
                Button { model.load() } label: { CommandLabel(title: "Reload", icon: .mergeReload) }
                Button { model.navigate(-1) } label: { CommandLabel(title: "Previous difference", icon: .mergePreviousConflict) }.disabled(model.difference <= 0)
                Button { model.navigate(1) } label: { CommandLabel(title: "Next difference", icon: .mergeNextConflict) }.disabled(model.alignment?.differences.isEmpty != false || model.difference >= (model.alignment?.differences.count ?? 0) - 1)
                Button { model.find(.showFindInterface) } label: { CommandLabel(title: "Find", icon: .mergeFind) }.disabled(model.alignment == nil)
                Spacer()
            }.padding(10).disabled(model.busy || model.confirmingQuit)
            HStack { Toggle("Enable editing", isOn: $model.editingEnabled).disabled(model.editableBase == nil || model.busy || model.confirmingQuit); Spacer(); Toggle("Line numbers", isOn: $model.showLineNumbers) }.toggleStyle(.checkbox).padding(.horizontal, 10).padding(.bottom, 8)
            HStack {
                Menu {
                    Button { model.useOtherBlock() } label: { CommandLabel(title: "Use other block", icon: .mergeUseTheirs) }
                    Button { model.useOtherBlock(.currentThenOther) } label: { CommandLabel(title: "Use both blocks, this one first", icon: .mergeMineThenTheirs) }
                    Button { model.useOtherBlock(.otherThenCurrent) } label: { CommandLabel(title: "Use both blocks, this one last", icon: .mergeTheirsThenMine) }
                } label: { CommandLabel(title: "Use other block", icon: .mergeUseTheirs) }.disabled(!model.canTransfer || model.alignment?.differences.indices.contains(model.difference) != true)
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
        .onReceive(NotificationCenter.default.publisher(for: .mergeEditorPreferencesChanged)) { _ in model.showLineNumbers = MergeEditorPreferences.load().showLineNumbers }
        .alert("Comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
private struct FileComparisonEditor: NSViewRepresentable {
    @ObservedObject var model: FileComparisonWindowModel
    let cells: [MergeSourceCell]
    let base: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let view = FileComparisonTextView(); view.isEditable = false; view.isRichText = false
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
        if model.editableBase == base {
            model.resetHistory = { [weak coordinator = context.coordinator] in coordinator?.history.removeAllActions(); coordinator?.updateUndoState() }
            model.undo = { [weak coordinator = context.coordinator] in guard let coordinator, !coordinator.model.busy, !coordinator.model.confirmingQuit else { return }; coordinator.history.undo(); coordinator.updateUndoState() }
            model.redo = { [weak coordinator = context.coordinator] in guard let coordinator, !coordinator.model.busy, !coordinator.model.confirmingQuit else { return }; coordinator.history.redo(); coordinator.updateUndoState() }
            model.replaceText = { [weak coordinator = context.coordinator] text, caret in coordinator?.replace(text, caret: caret) }
            view.history = context.coordinator.history
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        model.register(scroll, base: base)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.cells = cells; context.coordinator.base = base
        view.isEditable = model.editingEnabled && model.editableBase == base && !model.busy && !model.confirmingQuit
        let value = Self.attributed(cells, font: view.font!)
        if !view.string.utf8.elementsEqual(value.string.utf8) { view.textStorage?.setAttributedString(value) }
        else { value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in view.textStorage?.setAttributes(attributes, range: range) } }
        scroll.rulersVisible = model.showLineNumbers
        (scroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers = cells.map(\.lineNumber)
        scroll.verticalRulerView?.needsDisplay = true
        if model.editableBase == base, let caret = model.selectionRequest {
            let offset = FileComparisonEditing.displayOffset(sourceOffset: caret, cells: cells)
            view.setSelectedRange(NSRange(location: min(offset, (view.string as NSString).length), length: 0))
            view.scrollRangeToVisible(view.selectedRange())
            DispatchQueue.main.async { if model.selectionRequest == caret { model.selectionRequest = nil } }
        }
    }
    static func attributed(_ cells: [MergeSourceCell], font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        paragraph.defaultTabInterval = CGFloat(MergeEditorPreferences.load().tabWidth) * (" " as NSString).size(withAttributes: [.font: font]).width
        let value = NSMutableAttributedString(string: "")
        for cell in cells { value.append(NSAttributedString(string: cell.displayText + "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor, .backgroundColor: MergePalette.color(cell.state), .paragraphStyle: paragraph])) }
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
                replace(edit.text, caret: edit.caret)
            } catch { model.error = error.localizedDescription }
            return false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, let alignment = model.alignment else { return }
            let offset = min(view.selectedRange().location, (view.string as NSString).length)
            let row = (view.string as NSString).substring(to: offset).components(separatedBy: "\n").count - 1
            let selected = alignment.differences.firstIndex { $0.contains(row) } ?? -1
            DispatchQueue.main.async { if self.model.difference != selected { self.model.difference = selected } }
        }
        func updateUndoState() { model.canUndo = history.canUndo; model.canRedo = history.canRedo }
        func replace(_ text: String, caret: Int) {
            guard !model.busy, !model.confirmingQuit else { return }
            let old = model.editedText
            guard !old.utf8.elementsEqual(text.utf8) else { return }
            history.registerUndo(withTarget: self) { target in target.replace(old, caret: min(caret, (old as NSString).length)) }
            history.setActionName("Edit comparison")
            model.editedText = text; model.selectionRequest = caret; model.rebuildAlignment()
            if let alignment = model.alignment, let view = scroll?.documentView as? NSTextView {
                cells = alignment.rows.map { base ? $0.base : $0.destination }
                view.textStorage?.setAttributedString(FileComparisonEditor.attributed(cells, font: view.font!))
                view.setSelectedRange(NSRange(location: min(FileComparisonEditing.displayOffset(sourceOffset: caret, cells: cells), (view.string as NSString).length), length: 0))
            }
            DispatchQueue.main.async { self.updateUndoState() }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
private final class FileComparisonTextView: NSTextView {
    var history: UndoManager?
    override var undoManager: UndoManager? { history ?? super.undoManager }
}
