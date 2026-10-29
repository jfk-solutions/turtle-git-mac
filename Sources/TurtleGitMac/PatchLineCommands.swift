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

/// Source Ctrl-/ and Ctrl-\ remain editor-local. Overtype also has a Mac
/// shortcut because many Apple keyboards have no Insert key.
enum PatchCaretCommand:String,CaseIterable,Identifiable,Hashable {
    case toggleOvertype,previousPart,nextPart,selectPreviousPart,selectNextPart
    case previousBlock,nextBlock,selectPreviousBlock,selectNextBlock,scrollLineUp,scrollLineDown
    var id:String {rawValue}
    var title:String {
        switch self {case .toggleOvertype:return "Overtype";case .previousPart:return "Previous Word Part";case .nextPart:return "Next Word Part";case .selectPreviousPart:return "Select Previous Word Part";case .selectNextPart:return "Select Next Word Part";case .previousBlock:return "Previous Text Block";case .nextBlock:return "Next Text Block";case .selectPreviousBlock:return "Select Previous Text Block";case .selectNextBlock:return "Select Next Text Block";case .scrollLineUp:return "Scroll One Line Up";case .scrollLineDown:return "Scroll One Line Down"}
    }
    var backwards:Bool {self == .previousPart || self == .selectPreviousPart || self == .previousBlock || self == .selectPreviousBlock || self == .scrollLineUp}
    var block:Bool {self == .previousBlock || self == .nextBlock || self == .selectPreviousBlock || self == .selectNextBlock}
    var scrolling:Bool {self == .scrollLineUp || self == .scrollLineDown}
    var extending:Bool {self == .selectPreviousPart || self == .selectNextPart || self == .selectPreviousBlock || self == .selectNextBlock}
    var key:Character {
        if scrolling {return backwards ? "\u{f700}":"\u{f701}"}
        if block {return backwards ? "[":"]"}
        return self == .toggleOvertype ? "o":backwards ? "/":"\\"
    }
    var modifiers:NSEvent.ModifierFlags {self == .toggleOvertype ? [.command,.option]:extending ? [.control,.shift]:.control}
    var swiftModifiers:EventModifiers {self == .toggleOvertype ? [.command,.option]:extending ? [.control,.shift]:.control}
    var icon:MenuIcon {self == .toggleOvertype ? .mergeLineEdited:backwards ? .mergePreviousInline:.mergeNextInline}
    static func command(for event:NSEvent)->Self? {
        let flags=event.modifierFlags.intersection([.command,.control,.shift,.option])
        // macOS calls the Insert key Help; ordinary Help/F1 stay with Mac Help.
        if event.keyCode==114 && flags.isEmpty {return nil}
        let key=event.charactersIgnoringModifiers?.lowercased()
        return allCases.first{command in
            guard flags==command.modifiers else{return false}
            return key==String(command.key) || command.extending && key==(command.block ? (command.backwards ? "{":"}"):(command.backwards ? "?":"|"))
        }
    }
}
/// Source editing operations with Mac editor shortcuts. Control-U keeps its
/// native text-field meaning; case conversion uses Command-Option-U instead.
enum PatchSelectionCommand:String,CaseIterable,Identifiable,Hashable {
    case lowerCase,upperCase,deleteWordLeft,deleteWordRight,deleteLineLeft,deleteLineRight
    var id:String {rawValue}
    var converting:Bool {self == .lowerCase || self == .upperCase}
    var backwards:Bool {self == .deleteWordLeft || self == .deleteLineLeft}
    var title:String {
        switch self {
        case .lowerCase:return "Lowercase Selection"
        case .upperCase:return "Uppercase Selection"
        case .deleteWordLeft:return "Delete to Previous Word"
        case .deleteWordRight:return "Delete to Next Word"
        case .deleteLineLeft:return "Delete to Line Start"
        case .deleteLineRight:return "Delete to Line End"
        }
    }
    var icon:MenuIcon {converting ? .mergeLineEdited:.remove}
    var key:Character {converting ? "u":backwards ? "\u{8}":"\u{f728}"}
    var modifiers:NSEvent.ModifierFlags {
        if converting {return self == .upperCase ? [.command,.option,.shift]:[.command,.option]}
        return self == .deleteWordLeft || self == .deleteWordRight ? .option:.command
    }
    var swiftModifiers:EventModifiers {
        if converting {return self == .upperCase ? [.command,.option,.shift]:[.command,.option]}
        return self == .deleteWordLeft || self == .deleteWordRight ? .option:.command
    }
    var core:PatchSelectionEditCommand {PatchSelectionEditCommand(rawValue:rawValue)!}
    static func command(for event:NSEvent)->Self? {
        let flags=event.modifierFlags.intersection([.command,.control,.shift,.option])
        let key=event.charactersIgnoringModifiers?.lowercased()
        return allCases.first {command in
            guard flags==command.modifiers else{return false}
            if command.converting {return key=="u"}
            return command.backwards ? event.keyCode==51 && (key=="\u{7f}" || key=="\u{8}") : event.keyCode==117 && key=="\u{f728}"
        }
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
@MainActor private final class PatchCaretMenuReceipt:NSObject {
    let command:PatchCaretCommand,owner:PatchLineOwnerReceipt
    init(command:PatchCaretCommand,owner:PatchLineOwnerReceipt){self.command=command;self.owner=owner}
}
@MainActor private final class PatchSelectionMenuReceipt:NSObject {
    let command:PatchSelectionCommand,owner:PatchLineOwnerReceipt,selection:PatchTextSelectionSnapshot
    init(command:PatchSelectionCommand,owner:PatchLineOwnerReceipt,selection:PatchTextSelectionSnapshot) {self.command=command;self.owner=owner;self.selection=selection}
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
    var caretOvertype:Bool {overtypeRevision==coordinator?.model.documentResetRevision && overtypeEnabled}
    func canPerformCaretCommand(_ command:PatchCaretCommand)->Bool {
        guard lineOwner != nil else{return false}
        return command != .toggleOvertype || coordinator?.model.canEditText==true
    }
    @discardableResult func performCaretCommand(_ command:PatchCaretCommand)->Bool {
        guard canPerformCaretCommand(command),let owner=lineOwner else{return false}
        if command == .toggleOvertype {
            let enabled = !caretOvertype
            overtypeRevision=coordinator?.model.documentResetRevision;overtypeEnabled=enabled
            needsDisplay=true
            NotificationCenter.default.post(name:NSTextView.didChangeSelectionNotification,object:self)
            return true
        }
        if command.scrolling {return scrollCaretViewport(backwards:command.backwards,owner:owner)}
        let snapshot=lineSelectionSnapshot,selection=snapshot.primary
        if command.block {
            let caret=snapshot.rectangular ? (snapshot.rectangleCaret ?? selection.caret):selection.caret
            guard let target=PatchParagraphNavigation.position(text:string,caret:caret,backwards:command.backwards),lineOwnerCurrent(owner) else{return false}
            // ParaUpOrDown moves the main caret. The source's default single-
            // selection policy drops additional rectangle rows before extending
            // the stream from the main row's existing anchor.
            let originalAnchor=selection.anchor
            applyLineSelection(.init(rows:[.init(id:selection.id,anchor:command.extending ? originalAnchor:target,caret:target)],primarySelectionID:selection.id,rectangular:false))
            scrollRangeToVisible(NSRange(location:target,length:0))
            return true
        }
        // Editor::HorizontalMove switches a rectangle to a stream at its
        // directional outer limit before any non-rectangular word-part move.
        if snapshot.rectangular {
            let limit=command.backwards ? snapshot.rows.map{ $0.range.location }.min()!:snapshot.rows.map{NSMaxRange($0.range)}.max()!
            applyLineSelection(.init(rows:[.init(id:selection.id,anchor:limit,caret:limit)],primarySelectionID:selection.id,rectangular:false))
            return true
        }
        guard let target=PatchCaretEditing.wordPart(text:string,caret:selection.caret,backwards:command.backwards),lineOwnerCurrent(owner) else{return false}
        let anchor=command.extending ? selection.anchor:target
        applyLineSelection(.init(rows:[.init(id:selection.id,anchor:anchor,caret:target)],primarySelectionID:selection.id,rectangular:false))
        return true
    }
    /// Editor::LineScrollUp/Down scrolls one display line, retaining the caret
    /// and selection while visible. MoveCaretInsideView collapses to the closest
    /// visible line only when that scroll would strand the main caret offscreen.
    private func scrollCaretViewport(backwards:Bool,owner:PatchLineOwnerReceipt)->Bool {
        guard let scroll=enclosingScrollView,let manager=layoutManager,let container=textContainer else{return false}
        manager.ensureLayout(for:container)
        let before=visibleRect,origin=textContainerOrigin
        let local=NSPoint(x:max(0,before.minX-origin.x),y:max(0,before.minY-origin.y-(backwards ? 0.5:0)))
        let glyph=manager.glyphIndex(for:local,in:container)
        let fallback=manager.defaultLineHeight(for:font ?? .monospacedSystemFont(ofSize:12,weight:.regular))
        let height=glyph<manager.numberOfGlyphs ? manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).height:fallback
        guard height>0,lineOwnerCurrent(owner) else{return false}
        let point=scroll.contentView.constrainBoundsRect(NSRect(origin:.init(x:before.minX,y:before.minY+(backwards ? -height:height)),size:before.size)).origin
        scroll.contentView.scroll(to:point);scroll.reflectScrolledClipView(scroll.contentView)
        let state=lineSelectionSnapshot,caret=state.rectangular ? (state.rectangleCaret ?? state.primary.caret):state.primary.caret
        let count=(string as NSString).length
        guard caret>=0,caret<=count else{return true}
        let caretRect:NSRect
        if caret==count,manager.extraLineFragmentTextContainer != nil {
            caretRect=manager.extraLineFragmentRect.offsetBy(dx:origin.x,dy:origin.y)
        } else if manager.numberOfGlyphs>0 {
            let g=manager.glyphIndexForCharacter(at:min(caret,max(0,count-1)))
            var r=manager.lineFragmentRect(forGlyphAt:g,effectiveRange:nil)
            r.origin.x += manager.location(forGlyphAt:g).x
            caretRect=r.offsetBy(dx:origin.x,dy:origin.y)
        } else {return true}
        if viewportDesiredX==nil || viewportRevision != owner.revision || viewportDocumentRevision != owner.documentRevision || viewportLayoutSize != container.containerSize || viewportFont != font {
            viewportDesiredX=caretRect.minX;viewportRevision=owner.revision;viewportDocumentRevision=owner.documentRevision
            viewportLayoutSize=container.containerSize;viewportFont=font
        }
        let shown=visibleRect
        guard caretRect.minY<shown.minY || caretRect.maxY>shown.maxY else{return true}
        let y=caretRect.minY<shown.minY ? shown.minY+0.5:max(shown.minY+0.5,shown.maxY-max(1,caretRect.height)+0.5)
        var target=characterIndexForInsertion(at:.init(x:viewportDesiredX ?? caretRect.minX,y:y))
        let text=string as NSString
        target=min(count,max(0,target))
        if target<count {target=text.rangeOfComposedCharacterSequence(at:target).location}
        guard lineOwnerCurrent(owner) else{return false}
        let collapsed=PatchTextSelectionSnapshot(rows:[.init(id:state.primarySelectionID,anchor:target,caret:target)],primarySelectionID:state.primarySelectionID,rectangular:false)
        applyingViewportSelection=true
        if let columnSelection {_ = columnSelection.applySnapshot(collapsed)}
        else {setSelectedRange(.init(location:target,length:0))}
        applyingViewportSelection=false
        // Selection updates must not undo the explicitly requested viewport.
        scroll.contentView.scroll(to:point);scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }
    func canPerformSelectionCommand(_ command:PatchSelectionCommand)->Bool {
        lineOwner != nil && coordinator?.model.canEditText==true
    }
    @discardableResult func performSelectionCommand(_ command:PatchSelectionCommand)->Bool {
        guard canPerformSelectionCommand(command),let owner=lineOwner else{return false}
        let selected=lineSelectionSnapshot
        guard let plan=PatchSelectionEditing.plan(text:string,selections:selected.rows,primarySelectionID:selected.primarySelectionID,rectangular:selected.rectangular,command:command.core,rectangleAnchor:selected.rectangleAnchor,rectangleCaret:selected.rectangleCaret,rectangleIsThin:selected.rectangleIsThin,rectangleRowsExplicit:selected.rectangleRowsExplicit),lineOwnerCurrent(owner) else{return false}
        return performLinePlan(plan,title:command.title,owner:owner)
    }
    func makeSelectionCommandMenu()->NSMenu {
        let menu=NSMenu(title:NSLocalizedString("Selection Editing",comment:"Unified Diff selection editing menu"));menu.autoenablesItems=false
        guard let owner=lineOwner else{return menu}
        let selected=lineSelectionSnapshot,defaults=coordinator?.model.appearancePreferences ?? .standard
        for command in PatchSelectionCommand.allCases {
            let item=NSMenuItem(title:NSLocalizedString(command.title,comment:"Unified Diff selection edit action"),action:#selector(dispatchSelectionCommand(_:)),keyEquivalent:String(command.key))
            item.keyEquivalentModifierMask=command.modifiers;item.image=command.icon.contextImage(defaults:defaults);item.target=self
            item.representedObject=PatchSelectionMenuReceipt(command:command,owner:owner,selection:selected);item.isEnabled=canPerformSelectionCommand(command)
            menu.addItem(item)
        }
        return menu
    }
    @objc func dispatchSelectionCommand(_ sender:NSMenuItem) {
        guard let receipt=sender.representedObject as? PatchSelectionMenuReceipt,lineOwnerCurrent(receipt.owner),receipt.selection==lineSelectionSnapshot else{return}
        _ = performSelectionCommand(receipt.command)
    }
    func handleCaretTyping(_ replacement:String)->Bool {
        guard caretOvertype,!suppressOvertype,!hasMarkedText(),!replacement.contains("\n"),!replacement.contains("\r") else{return false}
        guard let owner=lineOwner,coordinator?.model.canEditText==true else{return true}
        let state=lineSelectionSnapshot
        guard let plan=PatchCaretEditing.overtype(text:string,selections:state.rows,primarySelectionID:state.primarySelectionID,replacement:replacement) else{return true}
        _ = performLinePlan(plan,title:"Typing",owner:owner)
        return true
    }
    func makeCaretCommandMenu()->NSMenu {
        let menu=NSMenu(title:NSLocalizedString("Caret",comment:"Unified Diff caret menu"));menu.autoenablesItems=false
        guard let owner=lineOwner else{return menu}
        let defaults=coordinator?.model.appearancePreferences ?? .standard
        for command in PatchCaretCommand.allCases {
            let item=NSMenuItem(title:NSLocalizedString(command.title,comment:"Unified Diff caret action"),action:#selector(dispatchCaretCommand(_:)),keyEquivalent:String(command.key))
            item.keyEquivalentModifierMask=command.modifiers;item.target=self;item.image=command.icon.contextImage(defaults:defaults)
            item.representedObject=PatchCaretMenuReceipt(command:command,owner:owner);item.isEnabled=canPerformCaretCommand(command)
            if command == .toggleOvertype {item.state=caretOvertype ? .on:.off}
            menu.addItem(item)
        }
        return menu
    }
    @objc func dispatchCaretCommand(_ sender:NSMenuItem) {
        guard let receipt=sender.representedObject as? PatchCaretMenuReceipt,lineOwnerCurrent(receipt.owner) else{return}
        _ = performCaretCommand(receipt.command)
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
              rectangleAnchor: plan.rectangleAnchor, rectangleCaret: plan.rectangleCaret, rectangleIsThin: plan.rectangleIsThin, rectangleRowsExplicit:plan.rectangleRowsExplicit)
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
            Menu("Selection Editing") {
                ForEach(PatchSelectionCommand.allCases) {command in
                    Button {context.performSelectionCommand(command)} label:{CommandLabel(title:command.title,icon:command.icon)}
                        .keyboardShortcut(KeyEquivalent(command.key),modifiers:command.swiftModifiers)
                        .disabled(!context.selectionCommands.contains(command))
                }
            }
            Menu("Caret") {
                ForEach(PatchCaretCommand.allCases) { command in
                    if command == .toggleOvertype {
                        Toggle(isOn:Binding(get:{context.caretOvertype},set:{_ in context.performCaretCommand(command)})) {CommandLabel(title:command.title,icon:command.icon)}
                            .keyboardShortcut(KeyEquivalent(command.key),modifiers:command.swiftModifiers).disabled(!context.caretCommands.contains(command))
                    } else {
                        Button {context.performCaretCommand(command)} label:{CommandLabel(title:command.title,icon:command.icon)}
                            .keyboardShortcut(KeyEquivalent(command.key),modifiers:command.swiftModifiers).disabled(!context.caretCommands.contains(command))
                    }
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
