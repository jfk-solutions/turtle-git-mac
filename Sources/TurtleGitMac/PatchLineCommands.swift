// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Editor-local adaptations of the active Scintilla line commands. Control-T
/// and Control-D remain native character transpose/delete bindings on macOS.
enum PatchLineCommand: String, CaseIterable, Identifiable, Hashable {
    case copyLines, cutLines, deleteLine, duplicate, transpose, indent, dedent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .copyLines: return "Copy Lines"
        case .cutLines: return "Cut Lines"
        case .deleteLine: return "Delete Line"
        case .duplicate: return "Duplicate Selection or Line"
        case .transpose: return "Transpose Lines"
        case .indent: return "Indent Lines"
        case .dedent: return "Dedent Lines"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .copyLines, .duplicate: return .copy
        case .cutLines, .deleteLine: return .remove
        case .transpose: return .mergeSwitch
        case .indent: return .mergeNextInline
        case .dedent: return .mergePreviousInline
        }
    }
    var key: Character {
        switch self {
        case .copyLines: return "c"; case .cutLines: return "x"; case .deleteLine: return "k"
        case .duplicate: return "d"; case .transpose: return "t"
        case .indent: return "]"; case .dedent: return "["
        }
    }
    var modifiers: NSEvent.ModifierFlags { self == .indent || self == .dedent ? .command : [.command, .option] }
    var swiftModifiers: EventModifiers { self == .indent || self == .dedent ? .command : [.command, .option] }
    var core: PatchLineEditCommand { PatchLineEditCommand(rawValue: rawValue)! }
    static func command(for event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection([.command, .control, .shift, .option])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        return allCases.first { flags == $0.modifiers && key == String($0.key) }
    }
}

@MainActor private struct PatchLineOwnerReceipt {
    let identity: UUID, revision: UUID
    let documentRevision: Int
    let model: ObjectIdentifier
}
@MainActor private final class PatchLineMenuReceipt: NSObject {
    let command: PatchLineCommand, owner: PatchLineOwnerReceipt
    init(command: PatchLineCommand, owner: PatchLineOwnerReceipt) { self.command = command; self.owner = owner }
}
@MainActor private struct PatchLineUndoState {
    let buffer: UnifiedDiffEditBuffer
    let selection: NSRange
    let affinity: NSSelectionAffinity
}

@MainActor extension PatchTextView.PatchText {
    private var lineOwner: PatchLineOwnerReceipt? {
        guard let coordinator, let window, window.firstResponder === self,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !hasMarkedText(), selectedRanges.count == 1, coordinator.model.canFind, coordinator.model.error == nil,
              coordinator.model.sourceOwnerID == coordinator.identity,
              coordinator.model.sourceAttached() else { return nil }
        let model = coordinator.model
        return .init(identity: coordinator.identity, revision: model.sourceCallbackRevision,
                     documentRevision: model.documentResetRevision, model: ObjectIdentifier(model))
    }
    private func lineOwnerCurrent(_ receipt: PatchLineOwnerReceipt) -> Bool {
        guard let current = lineOwner else { return false }
        return current.identity == receipt.identity && current.revision == receipt.revision &&
            current.documentRevision == receipt.documentRevision && current.model == receipt.model
    }
    func canPerformLineCommand(_ command: PatchLineCommand) -> Bool {
        guard lineOwner != nil else { return false }
        if command == .copyLines { return !string.isEmpty }
        guard coordinator?.model.canEditText == true else { return false }
        if command == .cutLines || command == .deleteLine { return !string.isEmpty }
        if command == .transpose {
            let selected = selectedRange()
            let caret = selectionAffinity == .upstream ? selected.location : NSMaxRange(selected)
            return ((enclosingScrollView as? PatchScrollView)?.lineNumberGutter?.lineIndex.lineIndex(atUTF16Offset: caret) ?? 0) > 0
        }
        return true
    }
    @discardableResult func performLineCommand(_ command: PatchLineCommand) -> Bool {
        guard canPerformLineCommand(command), let owner = lineOwner else { return false }
        return performLineEdit(command.core, title: command.title, owner: owner)
    }
    @discardableResult func performLineTab(backwards: Bool) -> Bool {
        guard coordinator?.model.canEditText == true, let owner = lineOwner else { return false }
        return performLineEdit(backwards ? .backTab : .tab, title: backwards ? "Dedent Lines" : "Indent Lines", owner: owner)
    }
    private func performLineEdit(_ command: PatchLineEditCommand, title: String, owner: PatchLineOwnerReceipt) -> Bool {
        guard lineOwnerCurrent(owner), let model = coordinator?.model else { return false }
        let selected = selectedRange()
        let anchor = selectionAffinity == .upstream ? NSMaxRange(selected) : selected.location
        let caret = selectionAffinity == .upstream ? selected.location : NSMaxRange(selected)
        let tab = UnifiedDiffAppearance.load(from: model.appearancePreferences).tabSize
        guard let plan = PatchLineEditing.plan(text: string, anchor: anchor, caret: caret,
                                               command: command, tabWidth: tab, useTabs: true, lineEnding: "\n") else { return false }
        if let copied = plan.clipboardText {
            guard !copied.isEmpty else { return false }
            // Scintilla's ordinary line clipboard is Unicode text, not a patch
            // file. Retained document byte fragments remain in its edit buffer.
            let item = NSPasteboardItem()
            guard item.setString(copied, forType: .string), lineOwnerCurrent(owner) else { return false }
            let board = linePasteboard(); board.clearContents()
            guard board.writeObjects([item]) else { return false }
        }
        if command == .copyLines { return true }
        guard model.canEditText, lineOwnerCurrent(owner) else { return false }
        do {
            let previous = try model.lineEditingBufferSnapshot()
            var next = previous
            let changed = try next.apply(plan)
            if !changed {
                setSelectedRange(plan.selectionRange, affinity: plan.selectionCaret < plan.selectionAnchor ? .upstream : .downstream, stillSelecting: false)
                scrollRangeToVisible(plan.selectionRange)
                return true
            }
            let before = PatchLineUndoState(buffer: previous, selection: selected, affinity: selectionAffinity)
            let after = PatchLineUndoState(buffer: next, selection: plan.selectionRange,
                                           affinity: plan.selectionCaret < plan.selectionAnchor ? .upstream : .downstream)
            breakUndoCoalescing()
            let history = undoManager
            history?.beginUndoGrouping()
            guard installLineState(after, owner: owner) else { history?.endUndoGrouping(); return false }
            registerLineUndo(before, owner: owner, title: title)
            history?.endUndoGrouping()
            breakUndoCoalescing()
            return true
        } catch { model.error = error.localizedDescription; return false }
    }
    /// Suppress only native auto-registration for our own single transaction;
    /// reciprocal undo stores exact provenance, including visually equal bytes.
    private func installLineState(_ state: PatchLineUndoState, owner: PatchLineOwnerReceipt) -> Bool {
        guard lineOwnerCurrent(owner), let model = coordinator?.model, model.canEditText,
              let storage = textStorage else { return false }
        let history = undoManager
        history?.disableUndoRegistration()
        defer { history?.enableUndoRegistration() }
        let range = NSRange(location: 0, length: string.utf16.count)
        guard shouldChangeText(in: range, replacementString: state.buffer.text), lineOwnerCurrent(owner) else { return false }
        model.installLineEditingBuffer(state.buffer)
        storage.replaceCharacters(in: range, with: state.buffer.text)
        didChangeText()
        setSelectedRange(state.selection, affinity: state.affinity, stillSelecting: false)
        scrollRangeToVisible(state.selection)
        return true
    }
    private func registerLineUndo(_ state: PatchLineUndoState, owner: PatchLineOwnerReceipt, title: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            guard target.lineOwnerCurrent(owner), let model = target.coordinator?.model,
                  model.canEditText, let buffer = try? model.lineEditingBufferSnapshot() else { return }
            let inverse = PatchLineUndoState(buffer: buffer, selection: target.selectedRange(), affinity: target.selectionAffinity)
            guard target.installLineState(state, owner: owner) else { return }
            target.registerLineUndo(inverse, owner: owner, title: title)
        }
        undoManager?.setActionName(NSLocalizedString(title, comment: "Unified Diff undo action"))
    }
    func makeLineCommandMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Lines", comment: "Unified Diff editing menu"))
        guard let owner = lineOwner else { return menu }
        let defaults = coordinator?.model.appearancePreferences ?? .standard
        for command in PatchLineCommand.allCases {
            let item = NSMenuItem(title: NSLocalizedString(command.title, comment: "Unified Diff line action"),
                                  action: #selector(dispatchLineCommand(_:)), keyEquivalent: String(command.key))
            item.keyEquivalentModifierMask = command.modifiers
            item.image = command.icon.contextImage(defaults: defaults)
            item.target = self; item.representedObject = PatchLineMenuReceipt(command: command, owner: owner)
            item.isEnabled = canPerformLineCommand(command)
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }
    @objc func dispatchLineCommand(_ sender: NSMenuItem) {
        guard let receipt = sender.representedObject as? PatchLineMenuReceipt, lineOwnerCurrent(receipt.owner) else { return }
        _ = performLineCommand(receipt.command)
    }
}

struct PatchLineEditingCommands: Commands {
    @ObservedObject var context: PatchMenuContext
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Menu("Lines") {
                ForEach(PatchLineCommand.allCases) { command in
                    Button { context.performLineCommand(command) } label: { CommandLabel(title: command.title, icon: command.icon) }
                        .keyboardShortcut(KeyEquivalent(command.key), modifiers: command.swiftModifiers)
                        .disabled(!context.lineCommands.contains(command))
                }
            }
        }
    }
}
