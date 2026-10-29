// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

enum PatchZoomCommand:String,CaseIterable,Identifiable,Hashable {
    case zoomIn,zoomOut,reset
    var id:String {rawValue}
    var title:String {switch self {case .zoomIn:return "Zoom In";case .zoomOut:return "Zoom Out";case .reset:return "Actual Size"}}
    var key:Character {switch self {case .zoomIn:return "+";case .zoomOut:return "-";case .reset:return "0"}}
    var swiftModifiers:EventModifiers {.command}
    var icon:MenuIcon {switch self {case .zoomIn:return .imageZoomIn;case .zoomOut:return .imageZoomOut;case .reset:return .imageOriginal}}
    var core:UnifiedDiffZoomCommand {UnifiedDiffZoomCommand(rawValue:rawValue)!}
    static func command(for event:NSEvent)->Self? {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if flags == .control {return [69:Self.zoomIn,78:.zoomOut,75:.reset][Int(event.keyCode)]}
        let key=event.charactersIgnoringModifiers
        if flags == .command || flags == [.command,.shift] {
            if key=="+" || key=="=" {return .zoomIn}
            if flags == .command,key=="-" {return .zoomOut}
            if flags == .command,key=="0" {return .reset}
        }
        return nil
    }
}
struct PatchZoomViewportAnchor {
    let character:Int,fraction:CGFloat,horizontal:CGFloat
}
@MainActor private final class PatchZoomMenuReceipt:NSObject {
    let command:PatchZoomCommand,owner:PatchLineOwnerReceipt
    init(_ command:PatchZoomCommand,_ owner:PatchLineOwnerReceipt) {self.command=command;self.owner=owner}
}
@MainActor extension PatchTextView {
    static func font(settings:UnifiedDiffAppearance,pointSize:Int)->NSFont {
        let size=CGFloat(pointSize)
        return NSFont(name:settings.fontName,size:size) ?? NSFontManager.shared.font(withFamily:settings.fontName,traits:[],weight:5,size:size) ?? .monospacedSystemFont(ofSize:size,weight:.regular)
    }
}
@MainActor extension PatchTextView.PatchText {
    private func zoomOwner(requiringFocus:Bool)->PatchLineOwnerReceipt? {
        guard let coordinator,let window,window.attachedSheet==nil,NSApp.modalWindow==nil,
              !hasMarkedText(),coordinator.model.canFind,coordinator.model.error==nil,
              coordinator.model.sourceOwnerID==coordinator.identity,coordinator.model.sourceAttached(),
              !requiringFocus || window.firstResponder === self else{return nil}
        return .init(identity:coordinator.identity,revision:coordinator.model.sourceCallbackRevision,documentRevision:coordinator.model.documentResetRevision,model:ObjectIdentifier(coordinator.model))
    }
    private func zoomOwnerCurrent(_ a:PatchLineOwnerReceipt,_ b:PatchLineOwnerReceipt)->Bool {
        a.identity==b.identity && a.revision==b.revision && a.documentRevision==b.documentRevision && a.model==b.model
    }
    func canPerformZoomCommand(_ command:PatchZoomCommand)->Bool {zoomOwner(requiringFocus:true) != nil && coordinator?.model.zoomState.canPerform(command.core)==true}
    @discardableResult func performZoomCommand(_ command:PatchZoomCommand)->Bool {
        guard canPerformZoomCommand(command) else{return false}
        invalidateZoomWheelInput()
        return coordinator?.model.applyZoom(command.core)==true
    }
    func invalidateZoomWheelInput() {
        zoomWheel.reset();zoomWheelOwner=nil;zoomWheelInputRevision=nil;zoomWheelPhased=false
    }
    func installZoomWheelObservers() {
        let names:[Notification.Name]=[NSWindow.willBeginSheetNotification,NSWindow.didEndSheetNotification,
            NSWindow.willMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification]
        if let old=zoomObservedWindow {for name in names {NotificationCenter.default.removeObserver(self,name:name,object:old)}}
        invalidateZoomWheelInput();zoomObservedWindow=window
        if let window {for name in names {NotificationCenter.default.addObserver(self,selector:#selector(zoomWindowInterrupted(_:)),name:name,object:window)}}
    }
    @objc private func zoomWindowInterrupted(_ notification:Notification) {
        guard let owner=notification.object as? NSWindow,owner === zoomObservedWindow else{return}
        invalidateZoomWheelInput()
    }
    /// Hover admission follows the source window-rectangle test, without moving
    /// keyboard focus. Windowless NSEvents carry screen coordinates in AppKit.
    func handleZoomWheel(with event:NSEvent)->Bool {
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        guard event.type == .scrollWheel,flags == .control || flags == .command else{invalidateZoomWheelInput();return false}
        guard let window,event.window==nil || event.window === window else{invalidateZoomWheelInput();return false}
        let basePoint=event.window==nil ? window.convertPoint(fromScreen:event.locationInWindow):event.locationInWindow
        guard visibleRect.contains(convert(basePoint,from:nil)) else{invalidateZoomWheelInput();return false}
        let dx=event.scrollingDeltaX,dy=event.scrollingDeltaY
        guard abs(dy)>=abs(dx),dy != 0 || dx==0 else{invalidateZoomWheelInput();return false}
        // Scintilla's wheel has no inertial continuation. Refusing Cocoa
        // momentum prevents an old gesture zooming a replacement document.
        guard event.momentumPhase.isEmpty else{invalidateZoomWheelInput();return true}
        let finished=event.phase.contains(.ended) || event.phase.contains(.cancelled)
        defer {if finished {invalidateZoomWheelInput()}}
        guard let owner=zoomOwner(requiringFocus:false),window.isVisible,!window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor,let model=coordinator?.model else{invalidateZoomWheelInput();return true}
        let current=zoomWheelOwner.map({zoomOwnerCurrent($0,owner)})==true && zoomWheelInputRevision==model.zoomInputRevision
        if !current {invalidateZoomWheelInput()}
        if event.phase.contains(.began) {
            invalidateZoomWheelInput();zoomWheelPhased=true
        } else if !event.phase.isEmpty {
            guard current,zoomWheelPhased else{return true}
        } else {
            // Unphased mouse events remain usable after any interruption.
            zoomWheelPhased=false
        }
        zoomWheelOwner=owner;zoomWheelInputRevision=model.zoomInputRevision
        let units=event.hasPreciseScrollingDeltas ? Double(dy)*12:(dy>0 ? 120:dy<0 ? -120:0)
        if let command=zoomWheel.command(sourceDelta:units) {_ = coordinator?.model.applyZoom(command)}
        return true
    }
    func makeZoomCommandMenu()->NSMenu {
        let menu=NSMenu(title:NSLocalizedString("Zoom",comment:"Unified Diff zoom menu"));menu.autoenablesItems=false
        guard let owner=zoomOwner(requiringFocus:true) else{return menu}
        let defaults=coordinator?.model.appearancePreferences ?? .standard
        for command in PatchZoomCommand.allCases {
            let item=NSMenuItem(title:NSLocalizedString(command.title,comment:"Unified Diff zoom action"),action:#selector(dispatchZoomCommand(_:)),keyEquivalent:String(command.key))
            item.target=self;item.image=command.icon.contextImage(defaults:defaults);item.keyEquivalentModifierMask = .command
            item.representedObject=PatchZoomMenuReceipt(command,owner);item.isEnabled=canPerformZoomCommand(command);menu.addItem(item)
        }
        return menu
    }
    @objc func dispatchZoomCommand(_ sender:NSMenuItem) {
        guard let receipt=sender.representedObject as? PatchZoomMenuReceipt,let owner=zoomOwner(requiringFocus:true),zoomOwnerCurrent(receipt.owner,owner) else{return}
        _ = performZoomCommand(receipt.command)
    }
    func zoomViewportAnchor()->PatchZoomViewportAnchor? {
        guard let scroll=enclosingScrollView,let layout=layoutManager,let container=textContainer else{return nil}
        layout.ensureLayout(for:container)
        guard layout.numberOfGlyphs>0 else{return nil}
        let point=scroll.contentView.bounds.origin,origin=textContainerOrigin
        let glyph=layout.glyphIndex(for:.init(x:0,y:max(0,point.y-origin.y)),in:container)
        guard glyph<layout.numberOfGlyphs else{return nil}
        var range=NSRange();let rect=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:&range)
        return .init(character:layout.characterIndexForGlyph(at:range.location),fraction:(point.y-origin.y-rect.minY)/max(1,rect.height),horizontal:point.x)
    }
    func restoreZoomViewport(_ anchor:PatchZoomViewportAnchor) {
        guard let scroll=enclosingScrollView as? PatchScrollView,let layout=layoutManager,let container=textContainer else{return}
        layout.ensureLayout(for:container)
        guard anchor.character<(string as NSString).length,layout.numberOfGlyphs>0 else{scroll.restoreDocumentOrigin(.zero);return}
        let glyph=layout.glyphIndexForCharacter(at:anchor.character)
        let rect=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        scroll.restoreDocumentOrigin(.init(x:anchor.horizontal,y:rect.minY+textContainerOrigin.y+anchor.fraction*rect.height))
    }
    /// Print magnification defaults to zero in the source; screen zoom never
    /// changes the immutable printer snapshot or the persisted base setting.
    func printSnapshot()->NSAttributedString {
        let original=NSAttributedString(attributedString:attributedString())
        let result=NSMutableAttributedString(attributedString:original)
        let settings=UnifiedDiffAppearance.load(from:coordinator?.model.appearancePreferences ?? .standard)
        let base=PatchTextView.font(settings:settings,pointSize:settings.fontSize)
        let interval=max(1,(" " as NSString).size(withAttributes:[.font:base]).width*CGFloat(settings.tabSize))
        original.enumerateAttributes(in:NSRange(location:0,length:original.length)) {attributes,range,_ in
            if let font=attributes[.font] as? NSFont {result.addAttribute(.font,value:NSFontManager.shared.convert(font,toSize:CGFloat(settings.fontSize)),range:range)}
            let paragraph=(attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.tabStops=[];paragraph.defaultTabInterval=interval
            result.addAttribute(.paragraphStyle,value:paragraph,range:range)
        }
        return NSAttributedString(attributedString:result)
    }
}
