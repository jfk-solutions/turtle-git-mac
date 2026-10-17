// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// One-level filesystem completion. It never interprets shell quoting/globs or
/// searches a repository index. Typed spelling is retained until a choice is made.
// Query state and retained scope containment are immutable during the worker.
struct PathEntryQuery: @unchecked Sendable {
    let text: String
    let base: URL
    let permissions: [RepositoryAccessLease]
    let requiresScopes: Bool
    func results(cancellation: OperationCancellation) throws -> [String] {
        try cancellation.check()
        guard !text.isEmpty, !text.contains("\0"), !text.contains("://") else { return [] }
        let slash = text.lastIndex(of: "/")
        let prefix = slash.map { String(text[...$0]) } ?? ""
        let leaf = slash.map { String(text[text.index(after: $0)...]) } ?? text
        let expanded = ((prefix.isEmpty ? "." : prefix) as NSString).expandingTildeInPath
        let parent = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true) : base.appendingPathComponent(expanded, isDirectory: true)).standardizedFileURL
        guard !requiresScopes || permissions.contains(where: { $0.permits(parent) }) else { return [] }
        // A selected file grant does not authorize enumerating its siblings.
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else { return [] }
        try cancellation.check()
        guard let iterator = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in false }) else { return [] }
        var values: [String] = []
        for case let child as URL in iterator {
            try cancellation.check()
            let name = child.lastPathComponent
            if name.hasPrefix(".") && !leaf.hasPrefix(".") { continue }
            guard name.range(of: leaf, options: [.anchored, .caseInsensitive]) != nil || leaf.isEmpty else { continue }
            let properties = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let suffix = properties?.isDirectory == true && properties?.isSymbolicLink != true ? "/" : ""
            // Expanded tilde choices must be valid for existing absolute-path
            // consumers. Other relative prefixes (including ../) stay literal.
            let start = prefix.hasPrefix("~") ? parent.path + "/" : prefix
            values.append(start + name + suffix)
        }
        try cancellation.check()
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct PathEntryField: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var permissions: [RepositoryAccessLease] = []
    var focus = false
    var preferences: UserDefaults = .standard
    var mayEdit: () -> Bool = { true }
    @Environment(\.isEnabled) private var enabled
    init(text: Binding<String>, label: String, base: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true), permissions: [RepositoryAccessLease] = [], focus: Bool = false, preferences: UserDefaults = .standard, mayEdit: @escaping () -> Bool = { true }) {
        self._text = text; self.label = label; self.base = base; self.permissions = permissions; self.focus = focus; self.preferences = preferences; self.mayEdit = mayEdit
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Field {
        let field = Field(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        field.cell = Cell(textCell: ""); field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.isEditable = true; field.isSelectable = true; field.drawsBackground = true; field.backgroundColor = .textBackgroundColor
        field.cell?.usesSingleLineMode = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize); field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.coordinator = context.coordinator; field.delegate = context.coordinator
        updateNSView(field, context: context); return field
    }
    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        let identities = permissions.map(ObjectIdentifier.init)
        if coordinator.base != base || coordinator.permissionIDs != identities || field.stringValue != text || !enabled { coordinator.cancel() }
        coordinator.field = field; coordinator.base = base; coordinator.permissions = permissions; coordinator.permissionIDs = identities
        coordinator.changed = { text = $0 }; coordinator.currentText = { text }; coordinator.mayEdit = mayEdit; coordinator.preferences = preferences
        field.isEnabled = enabled; field.placeholderString = label; field.setAccessibilityLabel(label)
        if field.stringValue != text { field.stringValue = text }
        if focus && !coordinator.focused {
            DispatchQueue.main.async { [weak coordinator, weak field] in
                guard let coordinator, !coordinator.retired, !coordinator.focused, coordinator.acceptsInput, let field, field.isEnabled, let window = field.window, window.attachedSheet == nil else { return }
                coordinator.focused = true
                // A deferred initial-focus request must not reset an editor's
                // selection or take focus back from another user-chosen control.
                if field.currentEditor() != nil { return }
                guard window.firstResponder == nil || window.firstResponder === window else { return }
                window.makeFirstResponder(field)
            }
        }
    }
    static func dismantleNSView(_ field: Field, coordinator: Coordinator) { coordinator.retire(); field.delegate = nil }
    @MainActor final class Field: NSTextField {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(window) }
    }
    @MainActor final class Cell: NSTextFieldCell {
        private let editor = Editor(frame: .zero)
        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            editor.owner = (controlView as? Field)?.coordinator
            editor.isFieldEditor = true; editor.isRichText = false; editor.allowsUndo = true; editor.configureLiteralInput()
            return editor
        }
    }
    @MainActor final class Editor: NSTextView {
        weak var owner: Coordinator?
        private weak var observedUndoManager: UndoManager?
        private var undoObservations: [NSObjectProtocol] = []
        deinit { for observation in undoObservations { NotificationCenter.default.removeObserver(observation) } }
        func observeUndo() {
            guard let manager = undoManager, observedUndoManager !== manager else { return }
            for observation in undoObservations { NotificationCenter.default.removeObserver(observation) }
            observedUndoManager = manager
            undoObservations = [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange].map { name in
                NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { guard let self else { return }; self.owner?.editorTextDidChange(self) }
                }
            }
        }
        func configureLiteralInput() {
            isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
            isAutomaticTextReplacementEnabled = false; isAutomaticSpellingCorrectionEnabled = false
            isAutomaticTextCompletionEnabled = false; isAutomaticLinkDetectionEnabled = false
            isContinuousSpellCheckingEnabled = false; isGrammarCheckingEnabled = false; smartInsertDeleteEnabled = false
        }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder(); configureLiteralInput(); observeUndo(); return accepted
        }
        override func didChangeText() {
            super.didChangeText()
            owner?.editorTextDidChange(self)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event) ?? NSMenu()
            menu.insertItem(.separator(), at: 0); menu.insertItem(completionItem(), at: 0)
            return menu
        }
        func completionItem() -> NSMenuItem {
            let action = CompletionAction(editor: self)
            let item = NSMenuItem(title: "Complete Path", action: #selector(CompletionAction.invoke(_:)), keyEquivalent: "")
            item.target = action; item.representedObject = action
            item.image = MenuIcon.explore.contextImage(defaults: owner?.preferences ?? .standard)
            item.isEnabled = owner?.acceptsInput == true && !hasMarkedText()
            return item
        }
        override func complete(_ sender: Any?) {
            guard let owner, owner.acceptsInput else { return }
            if Data(owner.queryText.utf8) == Data(string.utf8), !owner.choices.isEmpty { showReadyCompletions() }
            else { owner.request(explicit: true) }
        }
        func showReadyCompletions() {
            guard let window, window.isKeyWindow, !window.isMiniaturized, owner?.acceptsInput == true, !hasMarkedText() else { return }
            super.complete(nil)
        }
        override var rangeForUserCompletion: NSRange { NSRange(location: 0, length: string.utf16.count) }
        override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
            guard let owner, owner.acceptsInput, Data(owner.queryText.utf8) == Data(string.utf8) else { return nil }
            index.pointee = -1; return owner.choices
        }
        override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
            guard let owner, owner.acceptsInput else { return }
            let binding = Data(owner.currentText().utf8), current = Data(string.utf8)
            let preview = binding == Data(owner.queryText.utf8) && owner.choices.contains { Data($0.utf8) == current }
            guard binding == current || preview,
                  Data(word.utf8) == Data(owner.queryText.utf8) || owner.choices.contains(where: { Data($0.utf8) == Data(word.utf8) }) else { return }
            owner.inserting = true
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
            owner.inserting = false
            if flag && Data(owner.currentText().utf8) != Data(string.utf8) { owner.changed(string) }
            if flag && word.hasSuffix("/") { owner.request() }
        }
    }
    @MainActor final class CompletionAction: NSObject {
        private weak var editor: Editor?
        private let generation: UUID?
        private let text: Data
        private let selection: NSRange
        private var consumed = false
        init(editor: Editor) {
            self.editor = editor; generation = editor.owner?.requestIdentity
            text = Data(editor.string.utf8); selection = editor.selectedRange()
        }
        @objc func invoke(_ sender: Any?) {
            guard !consumed, let editor, let owner = editor.owner, owner.acceptsInput,
                  owner.field?.currentEditor() === editor, owner.requestIdentity == generation,
                  Data(editor.string.utf8) == text, Data(owner.currentText().utf8) == text,
                  editor.selectedRange() == selection, !editor.hasMarkedText() else { return }
            consumed = true; editor.complete(sender)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        static private(set) var activeReads = 0
        weak var field: Field?
        var base = URL(fileURLWithPath: "/", isDirectory: true), permissions: [RepositoryAccessLease] = []
        var permissionIDs: [ObjectIdentifier] = []
        var changed: (String) -> Void = { _ in }
        var currentText: () -> String = { "" }, mayEdit: () -> Bool = { true }
        var preferences: UserDefaults = .standard
        let wordCommands=GitInputWordCommands()
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
            guard acceptsInput else{return false}
            wordCommands.policy=GitInputWordBreak(defaults:preferences)
            return wordCommands.handle(control,text:textView,selector:commandSelector,combo:false,owner:self)
        }
        var focused = false, inserting = false
        private(set) var retired = false, choices: [String] = [], queryText = ""
        private var token: OperationCancellation?
        private var generation = UUID()
        var requestIdentity: UUID { generation }
        private var observation: NSObjectProtocol?
        var read: (PathEntryQuery, OperationCancellation) async throws -> [String] = { query, token in try await Task.detached { try query.results(cancellation: token) }.value }
        var present: (Editor) -> Void = { $0.showReadyCompletions() }
        var acceptsInput: Bool { !retired && mayEdit() && field?.isEnabled == true && field?.window != nil && field?.window?.attachedSheet == nil }
        func attach(_ window: NSWindow?) {
            if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil
            guard !retired else { return }
            if let window {
                observation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.retire() } }
            } else { cancel() }
        }
        func cancel() { generation = UUID(); token?.cancel(); token = nil; choices = []; queryText = "" }
        func retire() { retired = true; cancel(); if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
        func controlTextDidEndEditing(_ obj: Notification) { cancel() }
        func controlTextDidChange(_ obj: Notification) {
            guard let editor = field?.currentEditor() as? Editor else { return }
            editorTextDidChange(editor)
        }
        func editorTextDidChange(_ editor: Editor) {
            // Undo/Redo can update TextKit before NSTextField's cached value or
            // without another control delegate notification. Publish the editor's
            // authoritative text once; completion previews stay uncommitted.
            guard acceptsInput, !inserting, field?.currentEditor() === editor,
                  Data(currentText().utf8) != Data(editor.string.utf8) else { return }
            changed(editor.string); request()
        }
        func request(explicit: Bool = false) {
            cancel()
            guard acceptsInput, let editor = field?.currentEditor() as? Editor, !editor.hasMarkedText(), explicit || editor.selectedRange().length == 0 && editor.selectedRange().location == editor.string.utf16.count else { return }
            let text = editor.string, selection = editor.selectedRange(), request = generation, token = OperationCancellation()
            let query = PathEntryQuery(text: text, base: base, permissions: permissions, requiresScopes: GitRuntime.isAppStoreBuild)
            self.token = token; Self.activeReads += 1
            Task {
                defer { Self.activeReads -= 1; withExtendedLifetime(query.permissions) {}; if self.token === token { self.token = nil } }
                do {
                    try await Task.sleep(nanoseconds: 150_000_000); try token.check()
                    let result = try await read(query, token)
                    guard !token.isCancelled, generation == request, acceptsInput, field?.currentEditor() === editor, Data(editor.string.utf8) == Data(text.utf8), Data(currentText().utf8) == Data(text.utf8), editor.selectedRange() == selection, !editor.hasMarkedText() else { return }
                    choices = result; queryText = text
                    if !result.isEmpty { present(editor) }
                } catch { /* Completion failure never replaces the user's draft or reports a Git error. */ }
            }
        }
    }
}

/// Owned by each field coordinator, never by a global key monitor. Native text
/// insertion keeps field bindings, edit validation and Undo on AppKit's path.
@MainActor final class GitInputWordCommands {
    var policy=GitInputWordBreak()
    private weak var editor:NSTextView?
    private var anchor:Int?,caret:Int?
    private var expected:NSRange?
    private var content:Data?
    func handle(_ control:NSControl,text:NSTextView,selector:Selector,combo:Bool,owner:NSObject)->Bool {
        guard policy.enabled(combo:combo),control.isEnabled,let field=control as? NSTextField,
              field.delegate as AnyObject? === owner,field.window?.isVisible == true,field.window?.isMiniaturized == false,field.window?.attachedSheet == nil,
              field.currentEditor() === text,text.isSelectable,!text.hasMarkedText() else { reset();return false }
        let command=NSStringFromSelector(selector)
        let backwards=["moveWordBackward:","moveWordLeft:","moveWordBackwardAndModifySelection:","moveWordLeftAndModifySelection:","deleteWordBackward:"]
        let forwards=["moveWordForward:","moveWordRight:","moveWordForwardAndModifySelection:","moveWordRightAndModifySelection:","deleteWordForward:"]
        guard backwards.contains(command) || forwards.contains(command) else {reset();return false}
        let forward=forwards.contains(command),selection=text.selectedRange(),length=text.string.utf16.count
        guard selection.location<=length,selection.length<=length-selection.location else {reset();return false}
        let bytes=Data(text.string.utf8)
        if editor !== text || expected != selection || content != bytes {anchor=nil;caret=nil};editor=text;content=bytes
        let deleting=command.hasPrefix("delete"),extending=command.contains("AndModifySelection")
        if deleting {
            guard field.isEditable,text.isEditable else {return false}
            let range:NSRange
            if selection.length>0 {range=selection}
            else {
                let next=GitInputWordBreak.boundary(text.string,from:selection.location,forward:forward)
                range=NSRange(location:min(next,selection.location),length:abs(next-selection.location))
            }
            reset();if range.length>0 {text.insertText("",replacementRange:range)}
            return true
        }
        let start:Int
        if extending {
            if anchor == nil {anchor=forward ? selection.location:NSMaxRange(selection);caret=forward ? NSMaxRange(selection):selection.location}
            start=caret ?? selection.location
        } else {anchor=nil;caret=nil;start=forward ? NSMaxRange(selection):selection.location}
        let next=GitInputWordBreak.boundary(text.string,from:start,forward:forward)
        let range:NSRange
        if extending {caret=next;let fixed=anchor ?? start;range=NSRange(location:min(fixed,next),length:abs(next-fixed))}
        else {range=NSRange(location:next,length:0)}
        text.setSelectedRange(range);text.scrollRangeToVisible(range);expected=range
        return true
    }
    func reset() {editor=nil;anchor=nil;caret=nil;expected=nil;content=nil}
}
