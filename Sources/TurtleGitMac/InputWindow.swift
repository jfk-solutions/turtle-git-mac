// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

// Shared CInputDlg adaptation for branch descriptions and notes. See NOTICE.
final class InputMessageTextView: ProjectMessageTextView {
    var accept: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.intersection([.control, .command]).isEmpty, event.keyCode == 36 || event.keyCode == 76 { accept(); return }
        super.keyDown(with: event)
    }
}
@MainActor class InputWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static private(set) var activeSaves = 0
    let editor: NSTextView
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var minimumLength: Int
    private var readyForInput = true
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var busy = false
    private(set) var saved = false
    private var closed = false
    private var token: OperationCancellation?
    private var fontObserver: NSObjectProtocol?
    private let preferences: UserDefaults
    private var issueProperties: IssueTrackerProperties
    private let write: (String, Bool, OperationCancellation) async throws -> Void
    var onClosed: () -> Void = {}
    var onTextChanged: (String) -> Void = { _ in }
    init(title: String = "Input", hint: String = "Enter log message:", text: String, checkboxTitle: String? = nil, checked: Bool = false, minimumLength: Int = 0, projectSettings: ProjectDialogSettings = ProjectDialogSettings(), issueProperties: IssueTrackerProperties = IssueTrackerProperties(), preferences: UserDefaults, write: @escaping (String, Bool, OperationCancellation) async throws -> Void) {
        self.preferences = preferences; self.issueProperties = issueProperties; self.write = write; self.minimumLength = max(0, minimumLength)
        let input = InputMessageTextView(frame: .zero); editor = input
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 510, height: 255), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 360, height: 210)
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let hint = NSTextField(labelWithString: hint)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = input
        input.isRichText = false; input.allowsUndo = true; input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        input.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.textContainerInset = .init(width: 5, height: 5); input.string = text
        input.setAccessibilityLabel(title); input.undoManager?.removeAllActions(); input.delegate = self
        input.spellingPreferences = preferences; input.applyProjectSettings(projectSettings)
        checkbox.title = checkboxTitle ?? ""; checkbox.isHidden = checkboxTitle?.isEmpty != false; checkbox.state = checked ? .on : .off
        errorLabel.textColor = .systemRed
        ok.bezelStyle = .rounded; cancelButton.bezelStyle = .rounded
        ok.target = self; ok.action = #selector(save); cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"; input.accept = { [weak self] in self?.save() }
        for view in [hint, scroll, errorLabel, checkbox, ok, cancelButton] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: hint.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -5),
            errorLabel.leadingAnchor.constraint(equalTo: hint.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), errorLabel.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -6),
            cancelButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10), cancelButton.widthAnchor.constraint(equalToConstant: 80),
            checkbox.leadingAnchor.constraint(equalTo: hint.leadingAnchor), checkbox.centerYAnchor.constraint(equalTo: ok.centerYAnchor), checkbox.trailingAnchor.constraint(lessThanOrEqualTo: ok.leadingAnchor, constant: -8),
            ok.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8), ok.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor), ok.widthAnchor.constraint(equalToConstant: 80)
        ])
        updateFont(); updateAcceptance(); window.center(); DialogGeometry.attach(window, identifier: "InputDlg", legacyName: "InputDlg")
        fontObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateFont() } }
    }
    private func updateFont() {
        guard !closed else { return }
        let font = MessageEditorFont.resolve(name: preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName, size: preferences.object(forKey: "LogFontSize") as? Int ?? MessageEditorFont.defaultSize)
        (editor as? InputMessageTextView)?.configureSourceStyling(properties: issueProperties, preferences: preferences, font: font)
    }
    func focusEditor() { guard !closed, !busy, let window else { return }; window.makeFirstResponder(editor); editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0)) }
    var canAccept: Bool { readyForInput && !closed && !busy && editor.string.utf16.count >= minimumLength && !editor.string.contains("\0") }
    func textDidChange(_ notification: Notification) { onTextChanged(editor.string); updateAcceptance() }
    func setInputState(ready: Bool, message: String? = nil) {
        guard !closed else { return }
        readyForInput = ready; editor.isEditable = ready && !busy
        errorLabel.stringValue = message ?? ""; updateAcceptance()
    }
    func configure(text: String, minimumLength: Int, settings: ProjectDialogSettings, issueProperties: IssueTrackerProperties = IssueTrackerProperties()) {
        guard !closed, !busy else { return }
        self.minimumLength = max(0, minimumLength); self.issueProperties = issueProperties; editor.string = text
        editor.undoManager?.removeAllActions()
        (editor as? InputMessageTextView)?.applyProjectSettings(settings)
        updateFont(); setInputState(ready: true); focusEditor()
    }
    private func updateAcceptance() { ok.isEnabled = canAccept }
    private func dismiss() { if let window { window.sheetParent?.endSheet(window); window.close() } }
    @objc func save() {
        guard canAccept else { return }
        busy = true; checkbox.isEnabled = false; editor.isEditable = false; ok.isEnabled = false; cancelButton.isEnabled = false; errorLabel.stringValue = ""
        let request = OperationCancellation(); token = request; let text = editor.string, checked = checkbox.state == .on
        InputWindowController.activeSaves += 1
        Task {
            defer { InputWindowController.activeSaves -= 1 }
            do {
                try await write(text, checked, request)
                guard !closed, token === request else { return }
                saved = true; dismiss()
            } catch {
                guard !closed, token === request else { return }
                token = nil; busy = false; editor.isEditable = readyForInput; checkbox.isEnabled = true; updateAcceptance(); cancelButton.isEnabled = true
                errorLabel.stringValue = error.localizedDescription; window?.makeFirstResponder(editor)
            }
        }
    }
    @objc func cancel() { guard !busy, !closed else { return }; dismiss() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; token?.cancel(); token = nil
        (editor as? InputMessageTextView)?.retireSourceStyling()
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }; fontObserver = nil
        if let window { window.sheetParent?.endSheet(window) }; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ReferenceDescriptionWindowController: InputWindowController {
    init(text: String, preferences: UserDefaults, write: @escaping (String, OperationCancellation) async throws -> Void) {
        var settings = ProjectDialogSettings(); settings.language = .init(value: "-1", inherit: false)
        super.init(title: "Edit description", hint: "Edit description", text: text, projectSettings: settings, preferences: preferences) { text, _, token in try await write(text, token) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Shared owned Input sheet for Log and Rebase's selected revision menus.
@MainActor final class CommitNotePresenter {
    private weak var parent: NSWindow?
    private let model: LogWindowModel
    private let preferences: UserDefaults
    private(set) var editor: InputWindowController?
    init(parent: NSWindow, model: LogWindowModel, preferences: UserDefaults) {
        self.parent = parent; self.model = model; self.preferences = preferences
        model.onShowNote = { [weak self] note, settings in self?.show(note, settings: settings) }
    }
    private func show(_ note: CommitNoteSnapshot, settings: ProjectDialogSettings) {
        guard editor == nil, !model.isInvalidated, let parent, parent.attachedSheet == nil else { model.cancelNote(); return }
        let child = InputWindowController(title: "Edit Notes", hint: "Edit Notes", text: note.text, minimumLength: note.minimumLength, projectSettings: settings, issueProperties: model.noteIssueProperties, preferences: preferences) { [model] text, _, token in
            if token.isCancelled { throw CancellationError() }
            try await model.saveNoteText(note, text: text)
        }
        editor = child
        child.onClosed = { [weak self, weak child] in
            guard let self, self.editor === child else { return }
            self.editor = nil; self.model.cancelNote()
        }
        guard let sheet = child.window else { editor = nil; model.cancelNote(); return }
        parent.beginSheet(sheet); child.focusEditor()
    }
    func close() { editor?.close(); editor = nil }
}
