import AppKit
import SwiftUI
import TurtleGitCore

struct CommitMessageEditor: NSViewRepresentable {
    @ObservedObject var model: CommitWindowModel
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let editor = CommitMessageTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticLinkDetectionEnabled = false
        editor.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Commit message")
        editor.delegate = context.coordinator; editor.model = model
        editor.onAttachmentChange = { [weak editor, weak coordinator = context.coordinator] in
            guard let editor, let coordinator else { return }
            coordinator.updateFocus(editor)
        }
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? CommitMessageTextView,model.messageFocusAvailable,!context.coordinator.invalidated else {return}
        context.coordinator.updateModel(model)
        editor.isEditable = enabled && !model.loadingAmendMessage; editor.model = model
        editor.sourceLinkAvailable = { [weak model] in model?.messageFocusAvailable == true && model?.inputsBlocked == false && model?.confirmingQuit == false }
        model.prepareMessageCompletions()
        if !editor.string.utf8.elementsEqual(model.message.utf8) {
            let range = editor.selectedRange()
            editor.string = model.message
            editor.setSelectedRange(NSRange(location: min(range.location, (model.message as NSString).length), length: 0))
        }
        context.coordinator.updateMessageSession(editor)
        editor.spellingPreferences = model.messageEditorPreferences
        editor.applyProjectPresentation()
        editor.applyIssueStyles(model.issueMessageStyles, base: MessageEditorFont.resolve(name: fontName, size: fontSize))
        editor.setSpellingCandidates(model.messageCompletionCatalog.candidates)
        context.coordinator.updatePosition(editor)
        context.coordinator.updateFocus(editor)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
        if let editor = scroll.documentView as? CommitMessageTextView {
            editor.dismissSpellingSuggestions(); editor.retireSourceStyling(); editor.delegate = nil; editor.model = nil; editor.onAttachmentChange = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        private(set) var model: CommitWindowModel
        private var selectionCaret = MessageSelectionCaret()
        private var messageSession:UUID
        private var positionGeneration = 0
        private var focusQueued = false
        private(set) var invalidated = false
        private weak var observedWindow: NSWindow?
        private var sheetObserver: NSObjectProtocol?
        @MainActor init(_ model: CommitWindowModel) { self.model = model;messageSession=model.messageEditorSession }
        @MainActor func updateMessageSession(_ editor:CommitMessageTextView) {
            guard !invalidated,model.messageFocusAvailable,editor.model === model,messageSession != model.messageEditorSession else{return}
            messageSession=model.messageEditorSession
            editor.resetMessageSession()
        }
        deinit { if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) } }
        func updateModel(_ value: CommitWindowModel) {
            guard model !== value else { return }
            stopObservingSheet(); positionGeneration += 1
            selectionCaret = MessageSelectionCaret(); model = value
        }
        func invalidate() { invalidated = true; positionGeneration += 1; stopObservingSheet() }
        private func stopObservingSheet() {
            if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
            sheetObserver = nil; observedWindow = nil
        }
        @MainActor func updateFocus(_ editor: NSTextView) {
            guard !invalidated, model.messageFocusAvailable, model.messageFocusRequest > 0,
                  model.messageFocusRequest != model.appliedMessageFocusRequest else { stopObservingSheet(); return }
            guard let owner = editor.window else { stopObservingSheet(); return }
            if observedWindow !== owner {
                stopObservingSheet(); observedWindow = owner
                sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: owner, queue: nil) { [weak self, weak editor] _ in
                    MainActor.assumeIsolated { if let self, let editor { self.updateFocus(editor) } }
                }
            }
            guard !focusQueued else { return }; focusQueued = true
            // Focus only after the representable update and asynchronous Git
            // defaults/refresh finish. Use the latest request, once per toggle.
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self else { return }; self.focusQueued = false
                guard let editor, !self.invalidated, self.model.messageFocusAvailable,
                      self.model.messageFocusRequest > 0,
                      self.model.messageFocusRequest != self.model.appliedMessageFocusRequest,
                      (editor as? CommitMessageTextView)?.model === self.model,
                      let owner = editor.window, owner.attachedSheet == nil,
                      editor.isEditable, !self.model.busy, !self.model.confirmingQuit,
                      self.model.error == nil,
                      !self.model.loadingAuthorIdentity, !self.model.loadingAuthorDate,
                      !self.model.loadingAmendMessage else { return }
                let request = self.model.messageFocusRequest
                if owner.makeFirstResponder(editor) {
                    self.model.acknowledgeMessageFocus(request)
                    self.stopObservingSheet()
                }
            }
        }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? CommitMessageTextView, editor.messageLayoutAvailable { model.message = editor.string; updatePosition(editor) }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { updatePosition(editor) }
        }
        func updatePosition(_ editor: NSTextView) {
            let caret = selectionCaret.observe(editor.selectedRange())
            let value = MessageCaretPosition.at(editor.string, utf16Offset: caret)
            positionGeneration += 1; let request = positionGeneration
            // AppKit also notifies during representable/style updates. Coalesce
            // these notifications outside SwiftUI's view update transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.invalidated, request == self.positionGeneration, self.model.messageCaretPosition != value else { return }
                self.model.messageCaretPosition = value
            }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            (textView as? ProjectMessageTextView)?.followSourceLink(link,at:charIndex)
            return true
        }
    }
}

final class CommitMessageTextView: ProjectMessageTextView {
    private let messageUndoManager=UndoManager()
    override var undoManager:UndoManager? {messageUndoManager}
    func resetMessageSession() {
        guard model?.messageFocusAvailable==true else{return}
        breakUndoCoalescing();messageUndoManager.removeAllActions()
        completionPopup.close();dismissSpellingSuggestions()
        setSelectedRange(NSRange(location:0,length:0))
    }
    weak var model: CommitWindowModel?
    var onAttachmentChange: (@MainActor () -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyProjectPresentation(); onAttachmentChange?() }
    private weak var iconWindow: NSWindow?
    private var iconPath: String?
    func applyProjectPresentation() {
        guard let model else { return }
        applyProjectSettings(model.projectSettings)
        if let window, window !== iconWindow || iconPath != model.projectSettings.icon.value {
            iconWindow = window; iconPath = model.projectSettings.icon.value
            window.representedURL = model.repository.root
            window.standardWindowButton(.documentIconButton)?.image = ProjectDialogIcons.image(model.projectSettings.icon.value, repository: model.repository.root, access: model.projectIconAccess) ?? NSWorkspace.shared.icon(forFile: model.repository.root.path)
        }
    }
    private let completionPopup = CommitCompletionPopup()
    private var completionRange: NSRange?
    private var processingTypedKey = false
    private var insertedTypedText = false
    override func keyDown(with event: NSEvent) {
        if handleSpellingKey(event) { completionPopup.close(); return }
        if completionPopup.isShown {
            if event.keyCode == 53 { completionPopup.close(); return }
            if event.keyCode == 125 || event.keyCode == 126 { completionPopup.move(event.keyCode == 125 ? 1 : -1); return }
            if event.keyCode == 36 || event.keyCode == 48 { completionPopup.choose(); return }
        }
        let modifiers = event.modifierFlags.intersection([.control, .option, .command])
        if modifiers == .control && event.keyCode == 49 { showCompletions(minimum: 1); return }
        if modifiers == .option && event.keyCode == 53 { showCompletions(minimum: 1); return }
        completionPopup.close()
        if event.keyCode == 48 && !modifiers.contains(.control) && !modifiers.contains(.command) {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        processingTypedKey = modifiers.isEmpty
        insertedTypedText = false
        super.keyDown(with: event)
        processingTypedKey = false
        if insertedTypedText { showCompletions(minimum: model?.messageEditorPreferences.object(forKey: "AutoCompleteMinChars") as? Int ?? 3) }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        if processingTypedKey && !text.isEmpty { insertedTypedText = true }
    }
    override func complete(_ sender: Any?) { showCompletions(minimum: 1) }
    private func showCompletions(minimum: Int) {
        guard isEditable, let model else { return }
        guard model.messageEditorPreferences.object(forKey: "Autocompletion") as? Bool ?? true else { completionPopup.close(); return }
        let snippets = model.messageSnippets
        let catalog = model.messageCompletionCatalog
        let candidates = catalog.candidates
        guard let request = MessageCompletion.request(message: string, selection: selectedRange(), candidates: candidates, minimum: minimum, styling: model.formattingEnabled) else { completionPopup.close(); return }
        completionRange = request.range
        completionPopup.accept = { [weak self] value in
            guard let self, let prefixRange = self.completionRange, prefixRange.location <= (self.string as NSString).length, prefixRange.length <= (self.string as NSString).length - prefixRange.location else { return }
            self.breakUndoCoalescing()
            let expansion = snippets.expansion(for: value)
            let range = expansion == nil ? prefixRange : MessageCompletion.wordRange(message: self.string, selection: self.selectedRange(), styling: model.formattingEnabled) ?? prefixRange
            self.insertText(expansion ?? value, replacementRange: range)
            self.breakUndoCoalescing()
            self.window?.makeFirstResponder(self)
        }
        completionPopup.show(request.candidates, catalog: catalog, in: self)
    }
    override func resignFirstResponder() -> Bool { completionPopup.close(); return super.resignFirstResponder() }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event), isEditable else { return super.menu(for: event) }
        menu.addItem(.separator())
        for (title, action) in [("Pick commit hash…", #selector(pickHash)), ("Pick commit message…", #selector(pickMessage))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.image = MenuIcon.log.contextImage(defaults:spellingPreferences); menu.addItem(item)
        }
        let fileList = NSMenuItem(title: "Paste file list", action: #selector(pasteFileList), keyEquivalent: "")
        fileList.target = self; fileList.image = MenuIcon.copy.contextImage(defaults:spellingPreferences); menu.addItem(fileList)
        if model?.messageHistory?.entries.isEmpty == false {
            for (title, action) in [("Paste last message", #selector(pasteLastMessage)), ("Recent messages…", #selector(recentMessages))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.image = (title == "Paste last message" ? MenuIcon.copy : MenuIcon.log).contextImage(defaults:spellingPreferences); menu.addItem(item)
            }
        }
        return menu
    }
    private func pick(_ message: Bool) {
        model?.pickRevision(message) { [weak self] text in
            guard let self else { return }
            self.insertText(text, replacementRange: self.selectedRange())
            self.window?.makeFirstResponder(self)
        }
    }
    func performCommitMenuCommand(_ command:CommitCommandMenu.Command) {
        guard let model,model.messageFocusAvailable,!model.inputsBlocked,window?.attachedSheet==nil else {return}
        window?.makeFirstResponder(self)
        switch command {
        case .history:recentMessages()
        case .hash:pick(false)
        case .message:pick(true)
        case .pasteFiles:pasteFileList()
        default:break
        }
    }
    @objc private func pickHash() { pick(false) }
    @objc private func pickMessage() { pick(true) }
    @objc private func pasteFileList() { if let model { insertText(model.checkedFileList, replacementRange: selectedRange()) } }
    @objc private func pasteLastMessage() {
        if let text = model?.messageHistory?.entries.first { insertText(text, replacementRange: selectedRange()) }
    }
    @objc private func recentMessages() {
        model?.showMessageHistory { [weak self] message in
            guard let self, let model = self.model else { return }
            if !self.string.utf16.starts(with: message.utf16) {
                if GitReferenceName.equal(self.string,model.messageTemplate) {
                    self.insertText(message, replacementRange: NSRange(location: 0, length: (self.string as NSString).length))
                } else { self.insertText(message + (self.string.isEmpty ? "" : "\n"), replacementRange: self.selectedRange()) }
                model.updateIssueFromHistory(message, insertedInto: self.string)
            }
            self.window?.makeFirstResponder(self)
        }
    }
}

struct CommitEditorSettings: View {
    private let editorOnly: Bool
    private let preferences: UserDefaults
    private static let editorKeys = Set(["StyleCommitMessages", "AutoCompleteMinChars", "AutocompleteRemovesExtensions"])
    @State private var stripComments: Bool
    @State private var selectFiles: Bool
    @State private var noMissing: Bool
    @State private var historyLimit: Int
    @State private var parseTimeout: Int
    @State private var styleMessages: Bool
    @State private var completionMinimum: Int
    @State private var autocompletion: Bool
    @State private var removeExtensions: Bool
    @Environment(\.settingsTransaction) private var transaction
    @State private var original: [String: SettingsScalar] = [:]
    private var preferenceValues: [String: SettingsScalar] { let values: [String: SettingsScalar] = [
        "StripCommentedLines": .boolean(stripComments),
        "SelectFilesForCommit": .boolean(selectFiles),
        "AutoselectMissingFiles": .boolean(noMissing),
        "Commit.MaxHistoryItems": .integer(historyLimit),
        "AutocompleteParseTimeout": .integer(parseTimeout),
        "StyleCommitMessages": .boolean(styleMessages),
        "AutoCompleteMinChars": .integer(completionMinimum),
        "Autocompletion": .boolean(autocompletion),
        "AutocompleteRemovesExtensions": .boolean(removeExtensions)
    ]; return editorOnly ? values.filter { Self.editorKeys.contains($0.key) } : values }
    init(editorOnly: Bool = false, preferences: UserDefaults = .standard) {
        self.editorOnly = editorOnly; self.preferences = preferences
        _stripComments = State(initialValue: (preferences.object(forKey: "StripCommentedLines") as? NSNumber)?.boolValue ?? false)
        _selectFiles = State(initialValue: (preferences.object(forKey: "SelectFilesForCommit") as? NSNumber)?.boolValue ?? true)
        _noMissing = State(initialValue: (preferences.object(forKey: "AutoselectMissingFiles") as? NSNumber)?.boolValue ?? false)
        _historyLimit = State(initialValue: (preferences.object(forKey: "Commit.MaxHistoryItems") as? NSNumber)?.intValue ?? 25)
        _parseTimeout = State(initialValue: (preferences.object(forKey: "AutocompleteParseTimeout") as? NSNumber)?.intValue ?? 5)
        _styleMessages = State(initialValue: (preferences.object(forKey: "StyleCommitMessages") as? NSNumber)?.boolValue ?? true)
        _completionMinimum = State(initialValue: (preferences.object(forKey: "AutoCompleteMinChars") as? NSNumber)?.intValue ?? 3)
        _autocompletion = State(initialValue: (preferences.object(forKey: "Autocompletion") as? NSNumber)?.boolValue ?? true)
        _removeExtensions = State(initialValue: (preferences.object(forKey: "AutocompleteRemovesExtensions") as? NSNumber)?.boolValue ?? false)
        let initial: [String: SettingsScalar] = [
            "StripCommentedLines": .boolean((preferences.object(forKey: "StripCommentedLines") as? NSNumber)?.boolValue ?? false),
            "SelectFilesForCommit": .boolean((preferences.object(forKey: "SelectFilesForCommit") as? NSNumber)?.boolValue ?? true),
            "AutoselectMissingFiles": .boolean((preferences.object(forKey: "AutoselectMissingFiles") as? NSNumber)?.boolValue ?? false),
            "Commit.MaxHistoryItems": .integer((preferences.object(forKey: "Commit.MaxHistoryItems") as? NSNumber)?.intValue ?? 25),
            "AutocompleteParseTimeout": .integer((preferences.object(forKey: "AutocompleteParseTimeout") as? NSNumber)?.intValue ?? 5),
            "StyleCommitMessages": .boolean((preferences.object(forKey: "StyleCommitMessages") as? NSNumber)?.boolValue ?? true),
            "AutoCompleteMinChars": .integer((preferences.object(forKey: "AutoCompleteMinChars") as? NSNumber)?.intValue ?? 3),
            "Autocompletion": .boolean((preferences.object(forKey: "Autocompletion") as? NSNumber)?.boolValue ?? true),
            "AutocompleteRemovesExtensions": .boolean((preferences.object(forKey: "AutocompleteRemovesExtensions") as? NSNumber)?.boolValue ?? false)
        ]
        _original = State(initialValue: editorOnly ? initial.filter { Self.editorKeys.contains($0.key) } : initial)
    }
    private func applyDraft() { preferenceValues.forEach { $0.value.save($0.key, defaults:preferences) }; original = preferenceValues }
    private func cancelDraft() {
        if case .boolean(let value) = original["StripCommentedLines"] { stripComments = value }
        if case .boolean(let value) = original["SelectFilesForCommit"] { selectFiles = value }
        if case .boolean(let value) = original["AutoselectMissingFiles"] { noMissing = value }
        if case .integer(let value) = original["Commit.MaxHistoryItems"] { historyLimit = value }
        if case .integer(let value) = original["AutocompleteParseTimeout"] { parseTimeout = value }
        if case .boolean(let value) = original["StyleCommitMessages"] { styleMessages = value }
        if case .integer(let value) = original["AutoCompleteMinChars"] { completionMinimum = value }
        if case .boolean(let value) = original["Autocompletion"] { autocompletion = value }
        if case .boolean(let value) = original["AutocompleteRemovesExtensions"] { removeExtensions = value }
    }
    var body: some View {
        Form {
            LogPreferenceCheckbox(title: "Style commit messages", value: $styleMessages)
            Text(verbatim: "Use *bold*, ^italic^ and _underlined_ text. Markers remain in the commit message. Issue and URL links stay enabled.")
                .font(.caption).foregroundStyle(.secondary)
            if !editorOnly {
            Toggle("Use auto-completion of file paths and keywords", isOn: $autocompletion)
            Stepper("Timeout in seconds to stop the auto-completion parsing: \(parseTimeout)", value: $parseTimeout, in: 1...100).disabled(!autocompletion && !editorOnly)
            Stepper("Max. items to keep in the log message history: \(historyLimit)", value: $historyLimit, in: 1...100)
            Toggle("Strip lines starting with \"#\" in commit message", isOn: $stripComments)
            Toggle("Select items automatically", isOn: $selectFiles)
            Toggle("Do not auto-select \"missing\" files (deleted, but unstaged)", isOn: $noMissing)
            }
            Stepper("Complete after \(completionMinimum) characters", value: $completionMinimum, in: 1...100).disabled(!autocompletion && !editorOnly)
            Toggle("Include file names without extensions", isOn: $removeExtensions).disabled(!autocompletion && !editorOnly)
            Text("File and code completions come from the displayed changes. Press Ctrl-Space or Option-Escape to request them after one character.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .onChange(of: preferenceValues) { _ in if transaction == nil { applyDraft() } }
        .settingsParticipant("commit", page: .commit, value: preferenceValues,
            modified: { preferenceValues != original }, apply: { applyDraft(); return true }, cancel: cancelDraft)
    }
}

@MainActor final class MessageHistoryPickerModel: ObservableObject {
    private let history: any MessageHistory
    private let owner = UUID()
    private var revision = UUID()
    private(set) var retired = false
    var onChange: (() -> Void)?
    @Published private(set) var entries: [String]
    @Published var selection = IndexSet() { didSet { if oldValue != selection { revision = UUID(); onChange?() } } }
    struct Context {
        fileprivate let owner: UUID, revision: UUID
        let selection: IndexSet
    }
    init(history: any MessageHistory) { self.history = history; entries = history.entries }
    var selectedMessage: String {
        entries.indices.filter { selection.contains($0) }.map { entries[$0] }.joined(separator: "\n\n")
    }
    func capture() -> Context { .init(owner:owner,revision:revision,selection:selection) }
    func accepts(_ context:Context) -> Bool {
        !retired && context.owner == owner && context.revision == revision && context.selection == selection
    }
    func retire() { retired = true; revision = UUID(); onChange = nil }
    func deleteRow(_ index: Int) {
        guard !retired, entries.indices.contains(index) else { return }
        history.removeExact([entries[index]]); entries = history.entries; revision = UUID()
        selection = entries.isEmpty ? [] : [min(index, entries.count - 1)]
        onChange?()
    }
}

/// Compatibility host for existing embedded consumers; the complete dialog,
/// including buttons, is native AppKit in every host.
struct CommitMessageHistoryDialog: View {
    @StateObject private var model: MessageHistoryPickerModel
    let finish: (String?) -> Void
    init(history:any MessageHistory,finish:@escaping (String?)->Void) {
        self.init(model:MessageHistoryPickerModel(history:history),finish:finish)
    }
    init(model:MessageHistoryPickerModel,finish:@escaping (String?)->Void) {
        _model = StateObject(wrappedValue:model); self.finish = finish
    }
    var body:some View { CommitHistoryNativeHost(model:model,finish:finish).frame(minWidth:400,minHeight:230) }
}
private struct CommitHistoryNativeHost:NSViewRepresentable {
    let model:MessageHistoryPickerModel
    let finish:(String?)->Void
    func makeNSView(context:Context)->MessageHistoryPickerView { .init(model:model,finish:finish) }
    func updateNSView(_ view:MessageHistoryPickerView,context:Context) { view.refresh() }
    static func dismantleNSView(_ view:MessageHistoryPickerView,coordinator:()) { view.retire() }
}

@MainActor final class MessageHistoryPickerView:NSView,NSTableViewDataSource,NSTableViewDelegate {
    let model:MessageHistoryPickerModel
    let table = MessageHistoryNativeTable()
    let scroll = NSScrollView()
    let ok = NSButton(title:"OK",target:nil,action:nil)
    let cancel = NSButton(title:"Cancel",target:nil,action:nil)
    private let finish:(String?)->Void
    private var rendered:[String] = []
    private var updating = false, scheduled = false, completed = false
    private var closeObserver:NSObjectProtocol?
    private weak var attachedWindow:NSWindow?
    private var focused = false
    convenience init(history:any MessageHistory,finish:@escaping (String?)->Void) {
        self.init(model:MessageHistoryPickerModel(history:history),finish:finish)
    }
    init(model:MessageHistoryPickerModel,finish:@escaping (String?)->Void) {
        self.model = model; self.finish = finish
        super.init(frame:.init(x:0,y:0,width:600,height:320))
        table.headerView = nil; table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.rowHeight = 22
        table.addTableColumn(NSTableColumn(identifier:.init("message")))
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(acceptClicked(_:))
        table.setAccessibilityLabel("Recent messages")
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        ok.bezelStyle = .rounded; ok.keyEquivalent = "\r"; ok.action = #selector(ActionTarget.invoke(_:))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"; cancel.action = #selector(ActionTarget.invoke(_:))
        for view in [scroll,ok,cancel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),scroll.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-12),scroll.topAnchor.constraint(equalTo:topAnchor,constant:12),scroll.bottomAnchor.constraint(equalTo:ok.topAnchor,constant:-10),
            cancel.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-12),cancel.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-12),cancel.widthAnchor.constraint(equalToConstant:80),
            ok.trailingAnchor.constraint(equalTo:cancel.leadingAnchor,constant:-8),ok.bottomAnchor.constraint(equalTo:cancel.bottomAnchor),ok.widthAnchor.constraint(equalToConstant:80)
        ])
        model.onChange = { [weak self] in self?.scheduleRefresh() }
        refresh()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    override var isOpaque:Bool { true }
    override func draw(_ dirtyRect:NSRect) { NSColor.windowBackgroundColor.setFill();dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay = true}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { if attachedWindow != nil { retire() }; return }
        guard attachedWindow !== window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        attachedWindow = window
        closeObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.retire()}
        }
        refreshCommands()
        if !focused { focused = true; window.makeFirstResponder(table) }
    }
    func retire() { completed = true; model.retire(); table.onDelete = {};table.onReturn = {};table.onCancel = {} }
    private var canAct:Bool {
        guard !completed,!model.retired,let window,window === attachedWindow,window.attachedSheet == nil else { return false }
        if let parent = window.sheetParent,parent.attachedSheet !== window {return false}
        return rendered.count == model.entries.count && zip(rendered,model.entries).allSatisfy { GitReferenceName.equal($0,$1) }
    }
    private func scheduleRefresh() {
        guard !scheduled,!completed else {return};scheduled = true
        DispatchQueue.main.async { [weak self] in guard let self else {return};self.scheduled = false;self.refresh() }
    }
    func refresh() {
        guard !completed else {return};updating = true;defer {updating = false}
        let entries = model.entries
        if rendered.count != entries.count || !zip(rendered,entries).allSatisfy({GitReferenceName.equal($0,$1)}) {rendered = entries;table.reloadData()}
        table.selectRowIndexes(model.selection.intersection(IndexSet(rendered.indices)),byExtendingSelection:false)
        resizeColumn();refreshCommands()
    }
    override func layout() {super.layout();resizeColumn()}
    private func resizeColumn() {
        let font = NSFont.systemFont(ofSize:NSFont.systemFontSize)
        let measured = rendered.map { (Self.flatten($0) as NSString).size(withAttributes:[.font:font]).width }.max() ?? 0
        let width = max(380,max(scroll.contentSize.width,measured+15))
        if table.tableColumns.first?.width != width {table.tableColumns.first?.maxWidth = .greatestFiniteMagnitude;table.tableColumns.first?.width = width}
        let size = NSSize(width:width,height:max(22,CGFloat(rendered.count)*table.rowHeight))
        if table.frame.size != size {table.setFrameSize(size)}
    }
    static func flatten(_ value:String)->String {value.replacingOccurrences(of:"\r",with:"").replacingOccurrences(of:"\n",with:" ")}
    func numberOfRows(in tableView:NSTableView)->Int {rendered.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard rendered.indices.contains(row) else {return nil}
        let text = NSTextField(labelWithString:Self.flatten(rendered[row]));text.font = .systemFont(ofSize:NSFont.systemFontSize)
        text.lineBreakMode = .byClipping;text.cell?.usesSingleLineMode = true;text.toolTip = rendered[row]
        text.setAccessibilityLabel(rendered[row]);return text
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !updating,canAct else {return};model.selection = table.selectedRowIndexes.intersection(IndexSet(rendered.indices));refreshCommands()
    }
    enum Action {case accept,cancel,delete}
    @MainActor final class ActionTarget:NSObject {
        weak var view:MessageHistoryPickerView?
        let context:MessageHistoryPickerModel.Context,action:Action
        private var used = false
        init(view:MessageHistoryPickerView,context:MessageHistoryPickerModel.Context,action:Action) {self.view=view;self.context=context;self.action=action}
        @objc func invoke(_ sender:Any?) {guard !used else {return};used=true;view?.invoke(action,context:context)}
    }
    private var actionTargets:[ActionTarget] = []
    private func refreshCommands() {
        let context = model.capture()
        let accept = ActionTarget(view:self,context:context,action:.accept),cancel = ActionTarget(view:self,context:context,action:.cancel)
        actionTargets = [accept,cancel];ok.target=accept;self.cancel.target=cancel
        table.onDelete = { [weak self] in self?.invoke(.delete,context:context) }
        table.onReturn = { [weak self] in self?.invoke(.accept,context:context) }
        table.onCancel = { [weak self] in self?.invoke(.cancel,context:context) }
    }
    func invoke(_ action:Action,context:MessageHistoryPickerModel.Context) {
        guard canAct,model.accepts(context) else {return}
        switch action {
        case .accept:complete(model.selectedMessage)
        case .cancel:complete(nil)
        case .delete:deleteCurrent()
        }
    }
    func acceptSelection() {invoke(.accept,context:model.capture())}
    private func complete(_ message:String?) {
        guard canAct else {return};completed = true;model.retire();finish(message)
    }
    private func deleteCurrent() {
        guard canAct,table.selectedRow >= 0 else {return}
        model.deleteRow(table.selectedRow);refresh()
    }
    @objc private func acceptClicked(_ sender:NSTableView) {
        guard sender === table,canAct,rendered.indices.contains(table.clickedRow) else {return};complete(rendered[table.clickedRow])
    }
}
@MainActor final class MessageHistoryNativeTable:NSTableView {
    var onDelete:()->Void = {},onReturn:()->Void = {},onCancel:()->Void = {}
    override func keyDown(with event:NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if modifiers.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {onDelete()}
        else if modifiers.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {onReturn()}
        else if modifiers.isEmpty && event.keyCode == 53 {onCancel()}
        else {super.keyDown(with:event)}
    }
}

struct CommitMessagePositionIndicator: NSViewRepresentable {
    @ObservedObject var model: CommitWindowModel
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: model.messageCaretPosition.text)
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor; field.alignment = .right; field.toolTip = "Line/column"
        field.setAccessibilityLabel("Message line and column")
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = model.messageCaretPosition.text
        field.setAccessibilityValue(model.messageCaretPosition.text)
    }
}
