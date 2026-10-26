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
@MainActor private final class PatchColumnMenuReceipt: NSObject {
    let direction: PatchColumnDirection, owner: PatchLineOwnerReceipt
    init(direction: PatchColumnDirection, owner: PatchLineOwnerReceipt) { self.direction = direction; self.owner = owner }
}
@MainActor private struct PatchLineUndoState {
    let buffer: UnifiedDiffEditBuffer
    let selection: PatchTextSelectionSnapshot
}

@MainActor extension PatchTextView.PatchText {
    private var lineOwner: PatchLineOwnerReceipt? {
        guard let coordinator, let window, window.firstResponder === self,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !hasMarkedText(), coordinator.model.canFind, coordinator.model.error == nil,
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
            let caret = lineSelectionSnapshot.primary.caret
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
        let selected = lineSelectionSnapshot
        let tab = UnifiedDiffAppearance.load(from: model.appearancePreferences).tabSize
        guard let plan = PatchLineEditing.plan(text: string, selections: selected.rows, primarySelectionID: selected.primarySelectionID,
                                               rectangular: selected.rectangular, command: command, tabWidth: tab, useTabs: true, lineEnding: "\n", rectangleIsThin: selected.rectangleIsThin) else { return false }
        return performLinePlan(plan, title: title, owner: owner)
    }
    private var lineSelectionSnapshot: PatchTextSelectionSnapshot {
        if let columnSelection { return columnSelection.snapshot() }
        let range = selectedRange(), reverse = selectionAffinity == .upstream
        return .init(rows: [.init(id: 0, anchor: reverse ? NSMaxRange(range) : range.location,
                                 caret: reverse ? range.location : NSMaxRange(range))], primarySelectionID: 0, rectangular: false)
    }
    private func selection(for plan: PatchLineEditPlan) -> PatchTextSelectionSnapshot {
        .init(rows: plan.selections, primarySelectionID: plan.primarySelectionID, rectangular: plan.rectangular,
              rectangleAnchor: plan.rectangleAnchor, rectangleCaret: plan.rectangleCaret, rectangleIsThin: plan.rectangleIsThin)
    }
    private func applyLineSelection(_ selection: PatchTextSelectionSnapshot) {
        if let columnSelection { _ = columnSelection.applySnapshot(selection) }
        else { setSelectedRange(selection.primary.range, affinity: selection.primary.isReversed ? .upstream : .downstream, stillSelecting: false) }
        scrollRangeToVisible(selection.primary.range)
    }
    private func performLinePlan(_ plan: PatchLineEditPlan, title: String, owner: PatchLineOwnerReceipt) -> Bool {
        guard lineOwnerCurrent(owner), let model = coordinator?.model else { return false }
        if let copied = plan.clipboardText {
            guard !copied.isEmpty else { return false }
            // Scintilla's ordinary line clipboard is Unicode text, not a patch
            // file. Retained document byte fragments remain in its edit buffer.
            guard lineOwnerCurrent(owner), PatchColumnClipboard.write(text: copied, rectangular: plan.clipboardRectangular, to: linePasteboard()) else { return false }
        }
        if !plan.hasReplacement { applyLineSelection(selection(for: plan)); return true }
        guard model.canEditText, lineOwnerCurrent(owner) else { return false }
        do {
            let previous = try model.lineEditingBufferSnapshot()
            var next = previous
            let changed = try next.apply(plan)
            if !changed {
                applyLineSelection(selection(for: plan))
                return true
            }
            return commitLineBuffer(previous: previous, next: next, selection: selection(for: plan), title: title, owner: owner)
        } catch { model.error = error.localizedDescription; return false }
    }
    private func commitLineBuffer(previous: UnifiedDiffEditBuffer, next: UnifiedDiffEditBuffer,
                                  selection: PatchTextSelectionSnapshot, title: String, owner: PatchLineOwnerReceipt) -> Bool {
        guard lineOwnerCurrent(owner) else { return false }
        let before = PatchLineUndoState(buffer: previous, selection: lineSelectionSnapshot)
        let after = PatchLineUndoState(buffer: next, selection: selection)
        breakUndoCoalescing()
        let history = undoManager
        history?.beginUndoGrouping()
        guard installLineState(after, owner: owner) else { history?.endUndoGrouping(); return false }
        registerLineUndo(before, owner: owner, title: title)
        history?.endUndoGrouping()
        breakUndoCoalescing()
        return true
    }
    var hasColumnSelection: Bool { let state = lineSelectionSnapshot; return state.rectangular || state.rows.count > 1 }
    func handleColumnCopy(cutting: Bool) -> Bool {
        guard hasColumnSelection else { return false }
        guard let owner = lineOwner, let model = coordinator?.model else { return true }
        let state = lineSelectionSnapshot
        if cutting {
            guard model.canEditText,
                  let plan = PatchLineEditing.cutSelections(text: string, selections: state.rows, primarySelectionID: state.primarySelectionID,
                                                           rectangular: state.rectangular, rectangleIsThin: state.rectangleIsThin) else { return true }
            _ = performLinePlan(plan, title: "Cut", owner: owner)
        } else if let clipboard = PatchLineEditing.selectionClipboard(text: string, selections: state.rows,
                            primarySelectionID: state.primarySelectionID, rectangular: state.rectangular) {
            _ = PatchColumnClipboard.write(text: clipboard.text, rectangular: clipboard.rectangular, to: linePasteboard())
        }
        return true
    }
    func handleColumnTyping(_ replacement: String) -> Bool {
        guard hasColumnSelection else { return false }
        guard let owner = lineOwner, coordinator?.model.canEditText == true else { return true }
        let state = lineSelectionSnapshot
        if let plan = PatchLineEditing.replacePrimarySelection(text: string, selections: state.rows, primarySelectionID: state.primarySelectionID, replacement: replacement) {
            _ = performLinePlan(plan, title: "Typing", owner: owner)
        }
        return true
    }
    func handleColumnDelete(backwards: Bool) -> Bool {
        guard hasColumnSelection else { return false }
        guard let owner = lineOwner, coordinator?.model.canEditText == true else { return true }
        let state = lineSelectionSnapshot
        if let plan = PatchLineEditing.deleteSelections(text: string, selections: state.rows, primarySelectionID: state.primarySelectionID,
                            rectangular: state.rectangular, backwards: backwards, rectangleIsThin: state.rectangleIsThin) {
            _ = performLinePlan(plan, title: "Delete", owner: owner)
        }
        return true
    }
    func handleColumnPaste() -> Bool {
        // Explicit Paste is the only path that reads the private/general board.
        let board = linePasteboard(), rectangular = PatchColumnClipboard.isRectangular(board)
        guard hasColumnSelection || rectangular else { return false }
        guard let owner = lineOwner, let model = coordinator?.model, model.canEditText,
              let value = board.string(forType: .string) else { return true }
        let state = lineSelectionSnapshot
        guard let cleared = PatchLineEditing.cutSelections(text: string, selections: state.rows, primarySelectionID: state.primarySelectionID,
                          rectangular: state.rectangular, includeClipboard: false, rectangleIsThin: state.rectangleIsThin) else { return true }
        do {
            let previous = try model.lineEditingBufferSnapshot()
            var next = previous
            let didClear = try next.apply(cleared)
            let plan: PatchLineEditPlan
            if rectangular, PatchLineEditing.rectanglePasteRows(value).isEmpty {
                guard let caret = PatchRectanglePasteGeometry.insertionPoint(source: self, cleared: cleared) else { return true }
                guard let empty = PatchLineEditing.replacePrimarySelection(text: cleared.resultText,
                    selections: [.init(id: state.primarySelectionID, anchor: caret, caret: caret)], primarySelectionID: state.primarySelectionID, replacement: "") else { return true }
                plan = empty
            } else if rectangular {
                guard let geometry = PatchRectanglePasteGeometry.measure(source: self, cleared: cleared, clipboard: value),
                      let measured = PatchLineEditing.planRectanglePaste(text: cleared.resultText, insertions: geometry.insertions,
                                                               primarySelectionID: state.primarySelectionID, caret: geometry.caret) else { return true }
                plan = measured
            } else {
                guard let caret = PatchRectanglePasteGeometry.insertionPoint(source: self, cleared: cleared) else { return true }
                let text = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                guard let inserted = PatchLineEditing.replacePrimarySelection(text: cleared.resultText,
                    selections: [.init(id: state.primarySelectionID, anchor: caret, caret: caret)], primarySelectionID: state.primarySelectionID, replacement: text) else { return true }
                plan = inserted
            }
            let didInsert = try next.apply(plan)
            if didClear || didInsert { _ = commitLineBuffer(previous: previous, next: next, selection: selection(for: plan), title: "Paste", owner: owner) }
            else { applyLineSelection(selection(for: plan)) }
        } catch { model.error = error.localizedDescription }
        return true
    }
    func canCopyColumnSelection(cutting: Bool) -> Bool {
        guard lineOwner != nil, !cutting || coordinator?.model.canEditText == true else { return false }
        return lineSelectionSnapshot.rows.contains { $0.range.length > 0 }
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
        applyLineSelection(state.selection)
        return true
    }
    private func registerLineUndo(_ state: PatchLineUndoState, owner: PatchLineOwnerReceipt, title: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            guard target.lineOwnerCurrent(owner), let model = target.coordinator?.model,
                  model.canEditText, let buffer = try? model.lineEditingBufferSnapshot() else { return }
            let inverse = PatchLineUndoState(buffer: buffer, selection: target.lineSelectionSnapshot)
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
        menu.addItem(.separator())
        let columns = NSMenuItem(title: NSLocalizedString("Column Selection", comment: "Unified Diff selection menu"), action: nil, keyEquivalent: "")
        columns.image = MenuIcon.mergeMarked.contextImage(defaults: defaults)
        columns.submenu = makeColumnSelectionMenu(); menu.addItem(columns)
        menu.autoenablesItems = false
        return menu
    }
    func makeColumnSelectionMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Column Selection", comment: "Unified Diff selection menu"))
        guard let owner = lineOwner else { return menu }
        let defaults = coordinator?.model.appearancePreferences ?? .standard
        for direction in PatchColumnDirection.allCases {
            let item = NSMenuItem(title: NSLocalizedString(direction.title, comment: "Column selection direction"), action: #selector(dispatchColumnSelection(_:)), keyEquivalent: "")
            item.image = direction.icon.contextImage(defaults: defaults)
            item.target = self; item.representedObject = PatchColumnMenuReceipt(direction: direction, owner: owner)
            item.isEnabled = columnSelection?.available == true
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }
    @objc func dispatchColumnSelection(_ sender: NSMenuItem) {
        guard let receipt = sender.representedObject as? PatchColumnMenuReceipt, lineOwnerCurrent(receipt.owner) else { return }
        _ = columnSelection?.extendRectangle(direction: receipt.direction)
    }
    @objc func dispatchLineCommand(_ sender: NSMenuItem) {
        guard let receipt = sender.representedObject as? PatchLineMenuReceipt, lineOwnerCurrent(receipt.owner) else { return }
        _ = performLineCommand(receipt.command)
    }
}

struct PatchLineEditingCommands: Commands {
    @ObservedObject var context: PatchMenuContext
    private func columnKey(_ direction: PatchColumnDirection) -> KeyEquivalent {
        switch direction { case .left: return .leftArrow; case .right: return .rightArrow; case .up: return .upArrow; case .down: return .downArrow; case .home: return .home; case .end: return .end; case .pageUp: return .pageUp; case .pageDown: return .pageDown }
    }
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Menu("Lines") {
                ForEach(PatchLineCommand.allCases) { command in
                    Button { context.performLineCommand(command) } label: { CommandLabel(title: command.title, icon: command.icon) }
                        .keyboardShortcut(KeyEquivalent(command.key), modifiers: command.swiftModifiers)
                        .disabled(!context.lineCommands.contains(command))
                }
            }
            Menu("Column Selection") {
                ForEach(PatchColumnDirection.allCases, id: \.rawValue) { direction in
                    Button { context.extendColumnSelection(direction) } label: { CommandLabel(title: direction.title, icon: direction.icon) }
                        .keyboardShortcut(columnKey(direction), modifiers: [.command, .option, .shift])
                        .disabled(!context.columnSelectionAvailable)
                }
            }
        }
    }
}
