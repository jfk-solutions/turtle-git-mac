// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

enum PatchCursorCommand:String,CaseIterable,Identifiable,Hashable {
    case previousCharacter,nextCharacter,selectPreviousCharacter,selectNextCharacter
    case previousLine,nextLine,selectPreviousLine,selectNextLine
    var id:String {rawValue}
    var title:String {
        switch self {
        case .previousCharacter:return "Previous Character";case .nextCharacter:return "Next Character"
        case .selectPreviousCharacter:return "Select Previous Character";case .selectNextCharacter:return "Select Next Character"
        case .previousLine:return "Previous Display Line";case .nextLine:return "Next Display Line"
        case .selectPreviousLine:return "Select Previous Display Line";case .selectNextLine:return "Select Next Display Line"
        }
    }
    var extending:Bool {rawValue.hasPrefix("select")}
    var vertical:Bool {self == .previousLine || self == .nextLine || self == .selectPreviousLine || self == .selectNextLine}
    var backwards:Bool {self == .previousCharacter || self == .selectPreviousCharacter || self == .previousLine || self == .selectPreviousLine}
    var key:Character {vertical ? (backwards ? "\u{f700}":"\u{f701}"):(backwards ? "\u{f702}":"\u{f703}")}
    var modifiers:NSEvent.ModifierFlags {extending ? .shift:[]}
    var swiftModifiers:EventModifiers {extending ? .shift:[]}
    var icon:MenuIcon {backwards ? .mergePreviousInline:.mergeNextInline}
    static func command(for event:NSEvent)->Self? {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        guard flags.isEmpty || flags == .shift else{return nil}
        let extending=flags == .shift
        switch event.charactersIgnoringModifiers {
        case "\u{f702}":return extending ? .selectPreviousCharacter:.previousCharacter
        case "\u{f703}":return extending ? .selectNextCharacter:.nextCharacter
        case "\u{f700}":return extending ? .selectPreviousLine:.previousLine
        case "\u{f701}":return extending ? .selectNextLine:.nextLine
        default:return nil
        }
    }
}
@MainActor private final class PatchCursorReceipt:NSObject {
    let command:PatchCursorCommand,owner:PatchLineOwnerReceipt,selection:PatchTextSelectionSnapshot
    init(_ command:PatchCursorCommand,_ owner:PatchLineOwnerReceipt,_ selection:PatchTextSelectionSnapshot) {self.command=command;self.owner=owner;self.selection=selection}
}
@MainActor extension PatchTextView.PatchText {
    func canPerformCursorCommand(_ command:PatchCursorCommand)->Bool {lineOwner != nil}
    @discardableResult func performCursorCommand(_ command:PatchCursorCommand)->Bool {
        guard let owner=lineOwner else{return false}
        let state=lineSelectionSnapshot,primary=state.primary
        if command.vertical {return moveCursorVertically(command,owner:owner,state:state)}
        let target:Int
        if state.rectangular {
            // HorizontalMove first changes rectangle to stream at its outer
            // directional limit, including ordinary Shift-arrow commands.
            target=command.backwards ? state.rows.map{$0.range.location}.min()!:state.rows.map{NSMaxRange($0.range)}.max()!
        } else if !command.extending,primary.anchor != primary.caret {
            // CharLeft/Right collapse a nonempty stream without an extra step.
            target=command.backwards ? primary.range.location:NSMaxRange(primary.range)
        } else {
            guard let position=PatchCharacterNavigation.position(text:string,caret:primary.caret,backwards:command.backwards) else{return false}
            target=position
        }
        guard lineOwnerCurrent(owner) else{return false}
        let anchor=command.extending && !state.rectangular ? primary.anchor:target
        applyLineSelection(.init(rows:[.init(id:primary.id,anchor:anchor,caret:target)],primarySelectionID:primary.id,rectangular:false))
        scrollRangeToVisible(.init(location:target,length:0))
        // SetLastXChosen follows all horizontal source movements. Preserve its
        // actual insertion X for later arrows, pages and caret-aware scrolling.
        rememberCursorColumn(at:target,owner:owner)
        return true
    }
    private func rememberCursorColumn(at caret:Int,owner:PatchLineOwnerReceipt) {
        guard let rect=navigationCaretRect(at:caret),let container=textContainer else{resetViewportNavigation();return}
        viewportDesiredX=rect.minX;viewportRevision=owner.revision;viewportDocumentRevision=owner.documentRevision
        viewportLayoutSize=container.containerSize;viewportFont=font
    }
    private func moveCursorVertically(_ command:PatchCursorCommand,owner:PatchLineOwnerReceipt,state:PatchTextSelectionSnapshot)->Bool {
        let primary=state.primary
        guard PatchBoundaryNavigation.position(text:string,caret:primary.caret,boundary:.documentStart) != nil,
              let container=textContainer,let rect=navigationCaretRect(at:primary.caret) else{return false}
        if viewportDesiredX==nil || viewportRevision != owner.revision || viewportDocumentRevision != owner.documentRevision || viewportLayoutSize != container.containerSize || viewportFont != font {
            rememberCursorColumn(at:primary.caret,owner:owner)
        }
        let y=rect.midY+(command.backwards ? -1:1)*max(1,rect.height)
        var target=navigationSafeOffset(characterIndexForInsertion(at:.init(x:viewportDesiredX ?? rect.minX,y:y)),backwards:command.backwards)
        // PositionUpOrDown backtracks an ambiguous wrapped insertion until it
        // actually leaves the current display row (up) or stops overshooting
        // the requested row (down). It reaches 0/EOF at document boundaries.
        while target>0,let result=navigationCaretRect(at:target),
              command.backwards ? abs(result.minY-rect.minY)<0.5:(target<(string as NSString).length && target>primary.caret && result.midY>y+0.5) {
            guard let previous=PatchCharacterNavigation.position(text:string,caret:target,backwards:true),previous<target else{break}
            target=previous
        }
        guard lineOwnerCurrent(owner) else{return false}
        // CursorUpOrDown's ordinary stream loop starts at the main range's
        // caret even when dropping a rectangle; extension retains that anchor.
        applyingViewportSelection=true
        defer {applyingViewportSelection=false}
        applyLineSelection(.init(rows:[.init(id:primary.id,anchor:command.extending ? primary.anchor:target,caret:target)],primarySelectionID:primary.id,rectangular:false))
        scrollRangeToVisible(.init(location:target,length:0))
        return true
    }
    func makeCursorCommandMenu()->NSMenu {
        let menu=NSMenu(title:NSLocalizedString("Cursor",comment:"Unified Diff basic cursor menu"));menu.autoenablesItems=false
        guard let owner=lineOwner else{return menu}
        let selection=lineSelectionSnapshot,defaults=coordinator?.model.appearancePreferences ?? .standard
        for command in PatchCursorCommand.allCases {
            let item=NSMenuItem(title:NSLocalizedString(command.title,comment:"Unified Diff cursor movement"),action:#selector(dispatchCursorCommand(_:)),keyEquivalent:String(command.key))
            item.target=self;item.image=command.icon.contextImage(defaults:defaults);item.keyEquivalentModifierMask=command.modifiers
            item.representedObject=PatchCursorReceipt(command,owner,selection);item.isEnabled=canPerformCursorCommand(command);menu.addItem(item)
        }
        return menu
    }
    @objc func dispatchCursorCommand(_ sender:NSMenuItem) {
        guard let receipt=sender.representedObject as? PatchCursorReceipt,lineOwnerCurrent(receipt.owner),lineSelectionSnapshot==receipt.selection else{return}
        _ = performCursorCommand(receipt.command)
    }
}
