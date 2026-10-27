// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

/// Active Scintilla KeyMap.cxx line operations shared by SciEdit consumers.
/// Editor-local Command-Option adaptations preserve Cocoa Control-T/Control-D
/// and the existing Tab focus, completion and spelling bindings.
enum MessageEditorLineCommand: String, CaseIterable, Identifiable, Hashable {
    case copyLines, cutLines, deleteLine, duplicate, transpose
    var id: String { rawValue }
    var title: String {
        switch self {
        case .copyLines: return "Copy Lines"
        case .cutLines: return "Cut Lines"
        case .deleteLine: return "Delete Line"
        case .duplicate: return "Duplicate Selection or Line"
        case .transpose: return "Transpose Lines"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .copyLines, .duplicate: return .copy
        case .cutLines, .deleteLine: return .remove
        case .transpose: return .mergeSwitch
        }
    }
    var key: Character {
        switch self {
        case .copyLines: return "c"; case .cutLines: return "x"
        case .deleteLine: return "k"; case .duplicate: return "d"; case .transpose: return "t"
        }
    }
    var modifiers: NSEvent.ModifierFlags { [.command, .option] }
    var core: PatchLineEditCommand { PatchLineEditCommand(rawValue: rawValue)! }
    static func command(for event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection([.command, .control, .shift, .option])
        guard flags == [.command, .option], let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        return allCases.first { String($0.key) == key }
    }
}

@MainActor private final class MessageLineClipboard: NSObject {
    var board: () -> NSPasteboard = { .general }
    static var key: UInt8 = 0
}
@MainActor private struct MessageLineOwner {
    let session: UUID
    let window: ObjectIdentifier
}
@MainActor private struct MessageLineSnapshot {
    let text: String
    let ranges: [NSRange]
    let affinity: NSSelectionAffinity
}
@MainActor private final class MessageLineMenuReceipt: NSObject {
    let owner: MessageLineOwner
    let source: MessageLineSnapshot
    let command: MessageEditorLineCommand
    let context: AnyHashable?
    init(owner: MessageLineOwner, source: MessageLineSnapshot, command: MessageEditorLineCommand, context: AnyHashable?) {
        self.owner = owner; self.source = source; self.command = command
        self.context = context
    }
}

@MainActor extension ProjectMessageTextView {
    /// Native checks inject a unique private board. No implicit clipboard reads
    /// occur during validation, styling or ordinary editor initialization.
    var messageLinePasteboard: () -> NSPasteboard {
        get { messageLineClipboard.board }
        set { messageLineClipboard.board = newValue }
    }
    private var messageLineClipboard: MessageLineClipboard {
        if let value = objc_getAssociatedObject(self, &MessageLineClipboard.key) as? MessageLineClipboard { return value }
        let value = MessageLineClipboard()
        objc_setAssociatedObject(self, &MessageLineClipboard.key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
    private var messageLineOwner: MessageLineOwner? {
        guard messageLayoutAvailable, !hasMarkedText(), let window,
              messageCommandKeyWindow() === window, window.firstResponder === self, window.attachedSheet == nil,
              NSApp.modalWindow == nil, sourceLinkAvailable(), !selectedRanges.isEmpty,
              messageLineRangesValid else { return nil }
        return .init(session: messagePresentationSessionID, window: ObjectIdentifier(window))
    }
    private var messageLineRangesValid: Bool {
        let value = string as NSString, count = value.length
        func boundary(_ offset: Int) -> Bool {
            guard offset >= 0, offset <= count else { return false }
            if offset > 0, offset < count,
               (0xdc00...0xdfff).contains(value.character(at: offset)),
               (0xd800...0xdbff).contains(value.character(at: offset - 1)) { return false }
            return true
        }
        return selectedRanges.allSatisfy {
            let range = $0.rangeValue
            return range.location != NSNotFound && range.location >= 0 && range.location <= count &&
                range.length >= 0 && range.length <= count - range.location &&
                boundary(range.location) && boundary(range.location + range.length)
        }
    }
    private func messageLineOwnerCurrent(_ receipt: MessageLineOwner) -> Bool {
        guard let current = messageLineOwner else { return false }
        return current.session == receipt.session && current.window == receipt.window
    }
    private var messageLineSnapshot: MessageLineSnapshot {
        .init(text: string, ranges: selectedRanges.map(\.rangeValue), affinity: selectionAffinity)
    }
    private func matchesMessageLineSnapshot(_ source: MessageLineSnapshot) -> Bool {
        string.utf16.elementsEqual(source.text.utf16) && selectedRanges.map(\.rangeValue) == source.ranges && selectionAffinity == source.affinity
    }
    func canPerformMessageLineCommand(_ command: MessageEditorLineCommand) -> Bool {
        guard messageLineOwner != nil else { return false }
        switch command {
        case .copyLines, .cutLines, .deleteLine: return !string.isEmpty
        case .duplicate: return true
        case .transpose:
            let selected = selectedRange(), caret = selectionAffinity == .upstream ? selected.location : NSMaxRange(selected)
            return (PatchLineIndex(text: string).lineIndex(atUTF16Offset: caret) ?? 0) > 0
        }
    }
    @discardableResult func performMessageLineCommand(_ command: MessageEditorLineCommand) -> Bool {
        guard canPerformMessageLineCommand(command), let owner = messageLineOwner else { return false }
        messagePresentationWillChange()
        let before = messageLineSnapshot
        let reversed = before.affinity == .upstream
        let selections = before.ranges.enumerated().map {
            PatchLineEditSelection(id: $0.offset, anchor: reversed ? NSMaxRange($0.element) : $0.element.location,
                                   caret: reversed ? $0.element.location : NSMaxRange($0.element))
        }
        guard let plan = PatchLineEditing.plan(text: before.text, selections: selections, primarySelectionID: 0,
                                              rectangular: false, command: command.core, lineEnding: "\n"),
              messageLineOwnerCurrent(owner), matchesMessageLineSnapshot(before) else { return false }
        if let copied = plan.clipboardText {
            let board = messageLinePasteboard()
            board.clearContents()
            guard board.setString(copied, forType: .string), messageLineOwnerCurrent(owner), matchesMessageLineSnapshot(before) else { return false }
        }
        if command == .copyLines { return true }
        let ranges = plan.selections.map(\.range)
        let affinity: NSSelectionAffinity = plan.selectionAnchor > plan.selectionCaret ? .upstream : .downstream
        let intended = MessageLineSnapshot(text: plan.resultText, ranges: ranges, affinity: affinity)
        if !plan.changesText {
            setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: affinity, stillSelecting: false)
            return true
        }
        breakUndoCoalescing()
        let history = undoManager
        history?.beginUndoGrouping()
        defer { history?.endUndoGrouping(); breakUndoCoalescing() }
        guard installMessageLineSnapshot(intended, owner: owner, expected: before, modified: messageLineModifiedScope(plan)) else { return false }
        let after = messageLineSnapshot
        // didChangeText performs the editor's normal configured hard wrapping.
        // Capture its actual text and mapped selection, rather than reapplying
        // stale source-plan offsets or introducing a second wrapping algorithm.
        if !after.text.utf16.elementsEqual(before.text.utf16) {
            registerMessageLineUndo(before, owner: owner, title: command.title)
        }
        return true
    }
    private func installMessageLineSnapshot(_ value: MessageLineSnapshot, owner: MessageLineOwner,
                                            expected: MessageLineSnapshot, modified: NSRange? = nil) -> Bool {
        guard messageLineOwnerCurrent(owner), matchesMessageLineSnapshot(expected), let storage = textStorage else { return false }
        let change = messageLineReplacement(from: expected.text, to: value.text)
        let history = undoManager, registration = history?.isUndoRegistrationEnabled == true
        if registration { history?.disableUndoRegistration() }
        defer { if registration { history?.enableUndoRegistration() } }
        // shouldChangeText itself registers Cocoa's replacement undo. This
        // source transaction owns an exact reciprocal snapshot, so suppress
        // native registration before validation as well as storage mutation.
        guard shouldChangeText(in: change.range, replacementString: change.text),
              messageLineOwnerCurrent(owner), matchesMessageLineSnapshot(expected) else { return false }
        storage.replaceCharacters(in: change.range, with: change.text)
        setSelectedRanges(value.ranges.map { NSValue(range: $0) }, affinity: value.affinity, stillSelecting: false)
        if let modified { didChangeMessageLines(in: modified) }
        else { didChangeText() }
        return messageLineOwnerCurrent(owner)
    }
    /// Equal repeated text makes a minimal string diff ambiguous. The source
    /// segments retain where the command actually inserted, removed or moved
    /// text, so automatic wrapping must use that semantic edit footprint.
    private func messageLineModifiedScope(_ plan: PatchLineEditPlan) -> NSRange? {
        var source = 0, result = 0, modified: NSRange?
        func include(_ range: NSRange) { modified = modified.map { NSUnionRange($0, range) } ?? range }
        for segment in plan.segments {
            switch segment {
            case .inserted(let text):
                let count = text.utf16.count
                include(NSRange(location: result, length: count)); result += count
            case .source(let range):
                if range.location > source { include(NSRange(location: result, length: 0)) }
                else if range.location < source { include(NSRange(location: result, length: range.length)) }
                source = NSMaxRange(range); result += range.length
            }
        }
        if source < plan.originalText.utf16.count { include(NSRange(location: result, length: 0)) }
        return modified
    }
    /// A source command edits its changed lines plus the visible lines during
    /// the existing hard-wrap pass. Reporting an entire-document replacement
    /// here would incorrectly wrap unrelated offscreen lines as edited text.
    private func messageLineReplacement(from original: String, to replacement: String) -> (range: NSRange, text: String) {
        let a = original as NSString, b = replacement as NSString
        var prefix = 0
        while prefix < min(a.length, b.length), a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        func boundary(_ value: NSString, _ offset: Int) -> Bool {
            !(offset > 0 && offset < value.length &&
              (0xd800...0xdbff).contains(value.character(at: offset - 1)) &&
              (0xdc00...0xdfff).contains(value.character(at: offset)))
        }
        while prefix > 0, !boundary(a, prefix) || !boundary(b, prefix) { prefix -= 1 }
        var suffix = 0
        while suffix < a.length - prefix, suffix < b.length - prefix,
              a.character(at: a.length - suffix - 1) == b.character(at: b.length - suffix - 1) { suffix += 1 }
        while suffix > 0, !boundary(a, a.length - suffix) || !boundary(b, b.length - suffix) { suffix -= 1 }
        return (NSRange(location: prefix, length: a.length - prefix - suffix),
                b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix)))
    }
    private func registerMessageLineUndo(_ value: MessageLineSnapshot, owner: MessageLineOwner, title: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            guard target.messageLineOwnerCurrent(owner) else { return }
            let inverse = target.messageLineSnapshot
            guard target.installMessageLineSnapshot(value, owner: owner, expected: inverse) else { return }
            target.registerMessageLineUndo(inverse, owner: owner, title: title)
        }
        undoManager?.setActionName(NSLocalizedString(title, comment: "Shared message editor undo action"))
    }
    @discardableResult func handleMessageLineCommandKey(_ event: NSEvent) -> Bool {
        guard messageCommandKeyWindow() === window, window?.firstResponder === self, event.window === window else { return false }
        guard let command = MessageEditorLineCommand.command(for: event) else { return false }
        _ = performMessageLineCommand(command)
        return true
    }
    func appendMessageLineCommands(to menu: NSMenu) {
        let submenu = NSMenu(title: NSLocalizedString("Lines", comment: "Shared message editor line actions"))
        submenu.autoenablesItems = false
        let owner = messageLineOwner, source = messageLineSnapshot
        for command in MessageEditorLineCommand.allCases {
            let item = NSMenuItem(title: NSLocalizedString(command.title, comment: "Shared message editor line action"),
                                  action: #selector(dispatchMessageLineCommand(_:)), keyEquivalent: String(command.key))
            item.keyEquivalentModifierMask = command.modifiers
            item.target = self; item.image = command.icon.contextImage(defaults: spellingPreferences)
            item.isEnabled = canPerformMessageLineCommand(command)
            if let owner { item.representedObject = MessageLineMenuReceipt(owner: owner, source: source, command: command, context: messageCommandContext) }
            submenu.addItem(item)
        }
        menu.addItem(.separator())
        let root = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        root.image = MenuIcon.copy.contextImage(defaults: spellingPreferences); root.submenu = submenu
        menu.addItem(root)
    }
    func validateMessageLineCommandItem(_ item: NSMenuItem) -> Bool? {
        guard item.action == #selector(dispatchMessageLineCommand(_:)) else { return nil }
        guard let receipt = item.representedObject as? MessageLineMenuReceipt else { return false }
        return receipt.context == messageCommandContext && messageLineOwnerCurrent(receipt.owner) && matchesMessageLineSnapshot(receipt.source) && canPerformMessageLineCommand(receipt.command)
    }
    @objc func dispatchMessageLineCommand(_ sender: NSMenuItem) {
        guard validateMessageLineCommandItem(sender) == true,
              let receipt = sender.representedObject as? MessageLineMenuReceipt else { return }
        _ = performMessageLineCommand(receipt.command)
    }
}
