// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

enum PatchNavigationGroup:String,CaseIterable,Hashable {
    case words,boundaries,pages
    var title:String {switch self {case .words:return "Words";case .boundaries:return "Lines and Document";case .pages:return "Pages"}}
    var commands:[PatchNavigationCommand] {PatchNavigationCommand.allCases.filter{$0.group==self}}
}
enum PatchNavigationCommand:String,CaseIterable,Identifiable,Hashable {
    case previousWord,nextWord,selectPreviousWord,selectNextWord
    case smartLineStart,lineEnd,selectSmartLineStart,selectLineEnd
    case documentStart,documentEnd,selectDocumentStart,selectDocumentEnd
    case displayStart,displayEnd,pageUp,pageDown,selectPageUp,selectPageDown
    var id:String {rawValue}
    var title:String {
        switch self {
        case .previousWord:return "Previous Word";case .nextWord:return "Next Word"
        case .selectPreviousWord:return "Select Previous Word";case .selectNextWord:return "Select Next Word"
        case .smartLineStart:return "Smart Line Start";case .lineEnd:return "Line End"
        case .selectSmartLineStart:return "Select to Smart Line Start";case .selectLineEnd:return "Select to Line End"
        case .documentStart:return "Document Start";case .documentEnd:return "Document End"
        case .selectDocumentStart:return "Select to Document Start";case .selectDocumentEnd:return "Select to Document End"
        case .displayStart:return "Display Line Start";case .displayEnd:return "Display Line End"
        case .pageUp:return "Previous Page";case .pageDown:return "Next Page"
        case .selectPageUp:return "Select Previous Page";case .selectPageDown:return "Select Next Page"
        }
    }
    var extending:Bool {rawValue.hasPrefix("select")}
    var backwards:Bool {switch self {case .previousWord,.selectPreviousWord,.smartLineStart,.selectSmartLineStart,.documentStart,.selectDocumentStart,.displayStart,.pageUp,.selectPageUp:return true;default:return false}}
    var group:PatchNavigationGroup {switch self {case .previousWord,.nextWord,.selectPreviousWord,.selectNextWord:return .words;case .pageUp,.pageDown,.selectPageUp,.selectPageDown:return .pages;default:return .boundaries}}
    var document:Bool {self == .documentStart || self == .documentEnd || self == .selectDocumentStart || self == .selectDocumentEnd}
    var display:Bool {self == .displayStart || self == .displayEnd}
    var page:Bool {group == .pages}
    var boundary:PatchBoundary? {
        if group == .words {return backwards ? .previousWord:.nextWord}
        if document {return backwards ? .documentStart:.documentEnd}
        if page || display {return nil}
        return backwards ? .smartLineStart:.lineEnd
    }
    var icon:MenuIcon {backwards ? .mergePreviousInline:.mergeNextInline}
    var key:Character {
        if page {return backwards ? "\u{f72c}":"\u{f72d}"}
        if display {return backwards ? "\u{f729}":"\u{f72b}"}
        if document {return backwards ? "\u{f700}":"\u{f701}"}
        return backwards ? "\u{f702}":"\u{f703}"
    }
    var modifiers:NSEvent.ModifierFlags {
        var flags:NSEvent.ModifierFlags=page ? []:group == .words || display ? .option:.command
        if extending {flags.insert(.shift)};return flags
    }
    var swiftModifiers:EventModifiers {
        var flags:EventModifiers=page ? []:group == .words || display ? .option:.command
        if extending {flags.insert(.shift)};return flags
    }
    static func command(for event:NSEvent)->Self? {
        let flags=event.modifierFlags.intersection([.command,.option,.control,.shift])
        let extending=flags.contains(.shift),base=flags.subtracting(.shift)
        let key=event.charactersIgnoringModifiers
        if base == .option,key == "\u{f702}" || key == "\u{f703}" {
            return key == "\u{f702}" ? (extending ? .selectPreviousWord:.previousWord):(extending ? .selectNextWord:.nextWord)
        }
        if base == .command,key == "\u{f702}" || key == "\u{f703}" {
            return key == "\u{f702}" ? (extending ? .selectSmartLineStart:.smartLineStart):(extending ? .selectLineEnd:.lineEnd)
        }
        if base == .command,key == "\u{f700}" || key == "\u{f701}" {
            return key == "\u{f700}" ? (extending ? .selectDocumentStart:.documentStart):(extending ? .selectDocumentEnd:.documentEnd)
        }
        if key == "\u{f729}" || key == "\u{f72b}" {
            let start=key == "\u{f729}"
            if base == .control || base == .command {return start ? (extending ? .selectDocumentStart:.documentStart):(extending ? .selectDocumentEnd:.documentEnd)}
            if base.isEmpty {return start ? (extending ? .selectSmartLineStart:.smartLineStart):(extending ? .selectLineEnd:.lineEnd)}
            if base == .option,!extending {return start ? .displayStart:.displayEnd}
        }
        if base.isEmpty,key == "\u{f72c}" || key == "\u{f72d}" {return key == "\u{f72c}" ? (extending ? .selectPageUp:.pageUp):(extending ? .selectPageDown:.pageDown)}
        return nil
    }
}

@MainActor private final class PatchNavigationReceipt:NSObject {
    let command:PatchNavigationCommand,owner:PatchLineOwnerReceipt,selection:PatchTextSelectionSnapshot
    init(_ command:PatchNavigationCommand,_ owner:PatchLineOwnerReceipt,_ selection:PatchTextSelectionSnapshot) {self.command=command;self.owner=owner;self.selection=selection}
}

@MainActor extension PatchTextView.PatchText {
    func canPerformNavigationCommand(_ command:PatchNavigationCommand)->Bool {lineOwner != nil}
    @discardableResult func performNavigationCommand(_ command:PatchNavigationCommand)->Bool {
        guard let owner=lineOwner else{return false}
        let state=lineSelectionSnapshot,primary=state.primary
        if command.page {return navigatePage(command,owner:owner,state:state)}
        if state.rectangular,!command.document {
            // HorizontalMove uses directional outer limits; ordinary VCHome
            // and LineEnd then apply their logical boundary. Other horizontal
            // commands, including extensions, only collapse on this press.
            var target=command.backwards ? state.rows.map{$0.range.location}.min()!:state.rows.map{NSMaxRange($0.range)}.max()!
            if command == .smartLineStart || command == .lineEnd {
                guard let boundary=command.boundary,let moved=PatchBoundaryNavigation.position(text:string,caret:target,boundary:boundary) else{return false};target=moved
            }
            guard lineOwnerCurrent(owner) else{return false}
            applyNavigationSelection(target:target,anchor:target,id:primary.id)
            return true
        }
        let target:Int
        if let boundary=command.boundary {
            guard let moved=PatchBoundaryNavigation.position(text:string,caret:primary.caret,boundary:boundary) else{return false};target=moved
        } else {
            guard let moved=navigationDisplayBoundary(at:primary.caret,start:command.backwards) else{return false};target=moved
        }
        guard lineOwnerCurrent(owner) else{return false}
        applyNavigationSelection(target:target,anchor:command.extending ? primary.anchor:target,id:primary.id)
        return true
    }
    private func applyNavigationSelection(target:Int,anchor:Int,id:Int) {
        applyLineSelection(.init(rows:[.init(id:id,anchor:anchor,caret:target)],primarySelectionID:id,rectangular:false))
        scrollRangeToVisible(.init(location:target,length:0))
    }
    private func navigationSafeOffset(_ position:Int,backwards:Bool)->Int {
        let text=string as NSString;var p=min(text.length,max(0,position))
        if p>0,p<text.length,text.character(at:p-1)==13,text.character(at:p)==10 {p += backwards ? -1:1}
        if p<text.length {let r=text.rangeOfComposedCharacterSequence(at:p);if p != r.location {p=backwards ? r.location:NSMaxRange(r)}}
        return p
    }
    private func navigationDisplayBoundary(at caret:Int,start:Bool)->Int? {
        guard PatchBoundaryNavigation.position(text:string,caret:caret,boundary:.documentStart) != nil,let manager=layoutManager,let container=textContainer else{return nil}
        manager.ensureLayout(for:container)
        let text=string as NSString
        if text.length==0 || caret==text.length && manager.extraLineFragmentTextContainer != nil {return text.length}
        let glyph=manager.glyphIndexForCharacter(at:min(caret,text.length-1))
        var fragment=NSRange();_ = manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:&fragment)
        let chars=manager.characterRange(forGlyphRange:fragment,actualGlyphRange:nil)
        var target=start ? chars.location:NSMaxRange(chars)
        if !start {
            if target>chars.location,text.character(at:target-1)==10 {target-=1;if target>chars.location,text.character(at:target-1)==13 {target-=1}}
            else if target>chars.location,text.character(at:target-1)==13 {target-=1}
        }
        return navigationSafeOffset(target,backwards:start)
    }
    func navigationCaretRect(at caret:Int)->NSRect? {
        guard let manager=layoutManager,let container=textContainer else{return nil}
        manager.ensureLayout(for:container)
        let length=(string as NSString).length,origin=textContainerOrigin
        guard caret>=0,caret<=length else{return nil}
        if length==0 || caret==length && manager.extraLineFragmentTextContainer != nil {
            let rect=manager.extraLineFragmentRect,used=manager.extraLineFragmentUsedRect
            return NSRect(x:used.minX+origin.x,y:rect.minY+origin.y,width:0,height:rect.height)
        }
        let character=min(caret,length-1),glyph=manager.glyphIndexForCharacter(at:character)
        guard glyph<manager.numberOfGlyphs else{return nil}
        let rect=manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        // Unlike NSTextInputClient.firstRect, insertion-point geometry is valid
        // outside the visible clip. It includes positions within ligatures and
        // the exact EOF advance, not merely the last glyph's ink/start position.
        let count=manager.getLineFragmentInsertionPoints(forCharacterAt:character,alternatePositions:false,inDisplayOrder:false,positions:nil,characterIndexes:nil)
        guard count>0 else{return nil}
        var positions=[CGFloat](repeating:0,count:count),indexes=[Int](repeating:0,count:count)
        let written=positions.withUnsafeMutableBufferPointer {points in
            indexes.withUnsafeMutableBufferPointer {characters in
                manager.getLineFragmentInsertionPoints(forCharacterAt:character,alternatePositions:false,inDisplayOrder:false,positions:points.baseAddress,characterIndexes:characters.baseAddress)
            }
        }
        guard let index=indexes.prefix(written).firstIndex(of:caret) else{return nil}
        return NSRect(x:rect.minX+positions[index]+origin.x,y:rect.minY+origin.y,width:0,height:rect.height)
    }
    private func navigatePage(_ command:PatchNavigationCommand,owner:PatchLineOwnerReceipt,state:PatchTextSelectionSnapshot)->Bool {
        let primary=state.primary
        guard PatchBoundaryNavigation.position(text:string,caret:primary.caret,boundary:.documentStart) != nil,
              let scroll=enclosingScrollView,let container=textContainer,let rect=navigationCaretRect(at:primary.caret) else{return false}
        let before=visibleRect,height=max(1,rect.height)
        if viewportDesiredX==nil || viewportRevision != owner.revision || viewportDocumentRevision != owner.documentRevision || viewportLayoutSize != container.containerSize || viewportFont != font {
            viewportDesiredX=rect.minX;viewportRevision=owner.revision;viewportDocumentRevision=owner.documentRevision;viewportLayoutSize=container.containerSize;viewportFont=font
        }
        let delta=CGFloat(max(1,Int(floor(before.height/height))-1))*height*(command.backwards ? -1:1)
        let raw=characterIndexForInsertion(at:.init(x:viewportDesiredX ?? rect.minX,y:rect.midY+delta))
        let target=navigationSafeOffset(raw,backwards:command.backwards)
        let point=scroll.contentView.constrainBoundsRect(NSRect(origin:.init(x:before.minX,y:before.minY+delta),size:before.size)).origin
        guard lineOwnerCurrent(owner) else{return false}
        applyingViewportSelection=true
        if let columnSelection {_ = columnSelection.applySnapshot(.init(rows:[.init(id:primary.id,anchor:command.extending ? primary.anchor:target,caret:target)],primarySelectionID:primary.id,rectangular:false))}
        else {setSelectedRange(.init(location:min(target,command.extending ? primary.anchor:target),length:command.extending ? abs(target-primary.anchor):0),affinity:command.extending && target<primary.anchor ? .upstream:.downstream,stillSelecting:false)}
        applyingViewportSelection=false
        scroll.contentView.scroll(to:point);scroll.reflectScrolledClipView(scroll.contentView)
        // PageMove also calls MovePositionTo with ensureVisible. A user may
        // have manually scrolled the old caret out of view before this key.
        if let caretRect=navigationCaretRect(at:target),caretRect.minY<visibleRect.minY || caretRect.maxY>visibleRect.maxY {
            scrollRangeToVisible(.init(location:target,length:0))
        }
        return true
    }
    func makeNavigationCommandMenu()->NSMenu {
        let menu=NSMenu(title:NSLocalizedString("Navigation",comment:"Unified Diff navigation menu"));menu.autoenablesItems=false
        guard let owner=lineOwner else{return menu}
        let selection=lineSelectionSnapshot,defaults=coordinator?.model.appearancePreferences ?? .standard
        for group in PatchNavigationGroup.allCases {
            let submenu=NSMenu(title:NSLocalizedString(group.title,comment:"Unified Diff navigation group"));submenu.autoenablesItems=false
            let parent=NSMenuItem(title:submenu.title,action:nil,keyEquivalent:"");parent.image=MenuIcon.mergeNextInline.contextImage(defaults:defaults);parent.submenu=submenu
            for command in group.commands {
                let item=NSMenuItem(title:NSLocalizedString(command.title,comment:"Unified Diff navigation action"),action:#selector(dispatchNavigationCommand(_:)),keyEquivalent:String(command.key))
                item.target=self;item.image=command.icon.contextImage(defaults:defaults);item.keyEquivalentModifierMask=command.modifiers
                item.representedObject=PatchNavigationReceipt(command,owner,selection);item.isEnabled=canPerformNavigationCommand(command);submenu.addItem(item)
            }
            menu.addItem(parent)
        }
        return menu
    }
    @objc func dispatchNavigationCommand(_ sender:NSMenuItem) {
        guard let receipt=sender.representedObject as? PatchNavigationReceipt,lineOwnerCurrent(receipt.owner),lineSelectionSnapshot==receipt.selection else{return}
        _ = performNavigationCommand(receipt.command)
    }
}
