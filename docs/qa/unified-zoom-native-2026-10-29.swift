// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func zoomQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;zoomQAOrder(mode,relativeTo:number)}
}
@MainActor @main struct UnifiedZoomVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"line \(line): \(message)")}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Zoom native state timeout at line \(line)")
    }
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let suite="TurtleGit.Zoom.QA."+UUID().uuidString
        let preferences:UserDefaults,board=NSPasteboard.withUniqueName()
        var owners:[PatchWindowController]=[],sheets:[NSWindow]=[]
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(1251,forKey:"TurtleGitMerge.LegacyCodePage");preferences.set(true,forKey:"ShowAppContextMenuIcons")}
        func owner(repository:GitRepository?=nil)->PatchWindowController {
            let owner=PatchWindowController(repository:repository,access:nil,preferences:preferences,documentDirectory:root)
            owners.append(owner);owner.documentSession.askChanges={_,reply in reply(.discard)}
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.showWindow(nil);return owner
        }
        func clean()async throws {
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);try await UnifiedZoomVerification.wait {sheet.sheetParent==nil};sheet.close()}
            for owner in owners {owner.model.confirmingQuit=false;owner.model.busy=false;owner.close()}
            try await UnifiedZoomVerification.wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0}
            try UnifiedZoomVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Zoom owners survived cleanup")
            preferences.removePersistentDomain(forName:suite);board.releaseGlobally()
        }
    }
    @MainActor struct Surface {
        let owner:PatchWindowController,text:PatchTextView.PatchText
        var model:PatchWindowModel {owner.model}
        var window:NSWindow {owner.window!}
        var session:PatchDocumentSession {owner.documentSession}
    }
    static func surface(_ c:Context,_ owner:PatchWindowController)async throws->Surface {
        try await wait {owner.window?.contentView.map{views($0).contains{$0 is PatchTextView.PatchText}} == true}
        let text=views(owner.window!.contentView!).compactMap{$0 as? PatchTextView.PatchText}.first!
        text.linePasteboard={c.board};owner.window?.makeFirstResponder(text);return Surface(owner:owner,text:text)
    }
    static func ready(_ s:Surface)async throws {
        await withCheckedContinuation {(reply:CheckedContinuation<Void,Never>) in DispatchQueue.main.async {reply.resume()}}
        s.window.contentView?.layoutSubtreeIfNeeded()
        try await wait {s.text.string.utf16.elementsEqual(s.model.document.text.utf16) && !s.model.busy}
    }
    static func load(_ s:Surface,_ bytes:Data)async throws {
        s.owner.presentDocument(bytes,title:"Private zoom document",comparison:"zoom.patch",information:"Owned native verification")
        try await wait {s.model.canEditText && s.text.isEditable && s.text.string.utf16.elementsEqual(s.model.document.text.utf16) && !s.model.documentDirty && PatchDocumentSession.activeOperations==0}
        s.window.contentView?.layoutSubtreeIfNeeded();s.window.makeFirstResponder(s.text)
        try require(try s.session.encodedBytes()==bytes,"Zoom load changed original byte packets")
    }
    static func bytes(_ s:Surface,_ expected:Data,_ message:String)throws {try require(try s.session.encodedBytes()==expected,message+"; selection=\(s.text.selectedRange())")}
    static func key(_ s:Surface,_ text:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    static func item(_ s:Surface,_ command:PatchZoomCommand)throws->NSMenuItem {
        try unwrap(s.text.makeZoomCommandMenu().items.first{$0.title==command.title},"Zoom menu command missing: "+command.rawValue)
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    static func dispatch(_ s:Surface,_ command:PatchZoomCommand)throws {
        let entry=try item(s,command)
        try require(entry.isEnabled && entry.image != nil && entry.target != nil && entry.action != nil,"Zoom command lacks enabled native target/icon")
        try require(NSApp.sendAction(entry.action!,to:entry.target,from:entry),"Zoom menu dispatch refused")
    }
    static let body=Array(repeating:"\talpha beta\n\tgamma delta\n",count:80).joined()
    static func font(_ snapshot:NSAttributedString)throws->NSFont {try unwrap(snapshot.attribute(.font,at:0,effectiveRange:nil) as? NSFont,"Missing actual font attribute")}
    static func tab(_ snapshot:NSAttributedString)throws->CGFloat {try unwrap(snapshot.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle,"Missing actual paragraph attributes").defaultTabInterval}
    static func screen(_ s:Surface)->NSAttributedString {NSAttributedString(attributedString:s.text.attributedString())}
    static func unchanged(_ s:Surface,_ original:Data)throws {
        try bytes(s,original,"Zoom changed source bytes")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true && s.text.undoManager?.canRedo != true,"Zoom changed Undo/Redo or dirty state")
    }
    static func wheel(_ s:Surface,y:Int32,x:Int32=0,precise:Bool=false,flags:CGEventFlags = .maskCommand,phase:NSEvent.Phase=[],momentum:NSEvent.Phase=[],inside:Bool=true)throws->NSEvent {
        guard let cg=CGEvent(scrollWheelEvent2Source:nil,units:precise ? .pixel:.line,wheelCount:2,wheel1:y,wheel2:x,wheel3:0) else {throw Failure(description:"Private native wheel unavailable")}
        let visible=s.text.visibleRect,point=inside ? NSPoint(x:visible.minX+40,y:visible.minY+40):NSPoint(x:visible.minX-100,y:visible.minY-100)
        let base=s.text.convert(point,to:nil),screen=s.window.convertPoint(toScreen:base)
        cg.location=CGPoint(x:screen.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-screen.y);cg.flags=flags
        // CoreGraphics scroll phases use different bit positions from NSEvent.Phase.
        let scrollPhases:[(NSEvent.Phase,Int64)]=[(.began,1),(.changed,2),(.ended,4),(.cancelled,8),(.mayBegin,128)]
        let nativePhase=scrollPhases.reduce(Int64(0)){$0 | (phase.contains($1.0) ? $1.1:0)}
        let nativeMomentum:Int64=momentum == .began ? 1:momentum == .changed ? 2:momentum == .ended ? 3:0
        cg.setIntegerValueField(.scrollWheelEventScrollPhase,value:nativePhase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase,value:nativeMomentum)
        guard let event=NSEvent(cgEvent:cg) else {throw Failure(description:"Private wheel NSEvent unavailable")}
        try require(event.type == .scrollWheel && event.hasPreciseScrollingDeltas==precise && event.phase==phase && event.momentumPhase==momentum,"Native wheel mapping differs: input precise=\(precise) phase=\(phase.rawValue) momentum=\(momentum.rawValue); CG phase=\(nativePhase) momentum=\(nativeMomentum); NSEvent type=\(event.type.rawValue) precise=\(event.hasPreciseScrollingDeltas) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)")
        return event
    }
    static func keyboardAndLayout(_ c:Context,_ s:Surface)async throws {
        let original=Data(body.utf8);try await load(s,original)
        let column=try unwrap(s.text.columnSelection,"Missing native rectangle owner")
        try require(column.applySnapshot(.init(rows:[.init(id:3,anchor:1,caret:3),.init(id:9,anchor:13,caret:15)],primarySelectionID:9,rectangular:true,rectangleAnchor:1,rectangleCaret:15,rectangleIsThin:false)),"Zoom rectangle setup refused")
        let selected=column.snapshot(),baseScreen=screen(s),baseFont=try font(baseScreen).pointSize,baseTab=try tab(baseScreen),basePrint=s.text.printSnapshot()
        let printFont=try font(basePrint).pointSize,printTab=try tab(basePrint)
        let scroll=try unwrap(s.text.enclosingScrollView as? PatchScrollView,"Missing actual Patch scroll")
        let gutter=try unwrap(scroll.lineNumberGutter,"Missing actual line-number gutter"),gutterWidth=gutter.ruleThickness
        let contentHeight=s.text.bounds.height
        let menu=s.text.makeZoomCommandMenu()
        try require(menu.items.filter{!$0.isSeparatorItem}.map(\.title)==[PatchZoomCommand.zoomIn,.zoomOut,.reset].map(\.title) && menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil && $0.target != nil},"Zoom native menu order/icons/targets changed")
        try require(s.model.zoomLevel==0,"New editor inherited temporary zoom")
        try require(s.text.performKeyEquivalent(with:key(s,"+",69,.control)),"Source Control-keypad-plus alias refused")
        try await wait{(try? font(screen(s)).pointSize)==baseFont+1}
        try require(s.model.zoomLevel==1,"Native source zoom-in key lost one-step semantics")
        s.text.keyDown(with:key(s,"-",78,.control));try await wait{(try? font(screen(s)).pointSize)==baseFont}
        try require(s.model.zoomLevel==0,"Source keypad-minus keyDown failed")
        try require(s.text.performKeyEquivalent(with:key(s,"+",24,.command)),"Mac Command-plus equivalent refused")
        try dispatch(s,.zoomIn);try await wait{(try? font(screen(s)).pointSize)==baseFont+2}
        s.window.contentView?.layoutSubtreeIfNeeded();scroll.updateDocumentExtent()
        try require(s.model.zoomLevel==2 && (try tab(screen(s)))>baseTab && gutter.ruleThickness>gutterWidth && s.text.bounds.height>contentHeight,"Zoom failed actual font/tab/gutter/document reflow")
        let zoomSelection=column.snapshot()
        try require(zoomSelection.rows==selected.rows && zoomSelection.primarySelectionID==selected.primarySelectionID && zoomSelection.rectangular==selected.rectangular,"Zoom changed rectangle rows/IDs/direction")
        let zoomPrint=s.text.printSnapshot()
        try require(try font(zoomPrint).pointSize==printFont && tab(zoomPrint)==printTab,"Printing inherited temporary screen zoom")
        try require(basePrint.string.utf16.elementsEqual(zoomPrint.string.utf16) && (try font(basePrint).pointSize)==printFont,"Print snapshot mutated or lost source text")
        try unchanged(s,original)
        var keyWindow:NSWindow?=s.window
        let context=PatchMenuContext(keyWindow:{keyWindow});try await ready(s)
        try await wait{context.zoomCommands.contains(.zoomOut)}
        context.performZoomCommand(.zoomOut);try require(s.model.zoomLevel==1,"App Edit zoom menu failed active source owner")
        context.performZoomCommand(.zoomIn);try require(s.model.zoomLevel==2,"App Edit zoom menu failed reverse step")
        keyWindow=nil;context.performZoomCommand(.zoomIn);try require(s.model.zoomLevel==2,"App Edit zoom menu acted on background owner")
        try await load(s,Data((body+"reopened").utf8));try await wait{(try? font(screen(s)).pointSize)==baseFont+2}
        try require(s.model.zoomLevel==2,"Same-window document open reset temporary zoom")
        let other=try await surface(c,c.owner());try await load(other,Data("private fresh editor".utf8));try require(other.model.zoomLevel==0,"New window inherited another window's temporary zoom")
        s.window.makeFirstResponder(s.text)
        try require(s.text.performKeyEquivalent(with:key(s,"/",75,.control)),"Source Control-keypad-divide reset refused")
        try await wait{s.model.zoomLevel==0 && (try? font(screen(s)).pointSize)==baseFont}
        try dispatch(s,.zoomIn)
        try require(s.text.performKeyEquivalent(with:key(s,"0",29,.command)) && s.model.zoomLevel==0,"Mac Command-zero reset alias refused")
    }
    static func explicitRectangleReflow(_ c:Context,_ s:Surface)async throws {
        let original=Data("SS\nX\n".utf8);try await load(s,original)
        let column=try unwrap(s.text.columnSelection,"Missing explicit rectangle owner")
        let initial=PatchTextSelectionSnapshot(rows:[.init(id:3,anchor:0,caret:2),.init(id:9,anchor:3,caret:4)],primarySelectionID:9,rectangular:true,rectangleAnchor:0,rectangleCaret:4,rectangleIsThin:false,rectangleRowsExplicit:true)
        try require(column.applySnapshot(initial),"Jagged explicit rectangle setup refused")
        try require(column.snapshot().rectangleRowsExplicit && column.snapshot().rows.map(\.range)==[NSRange(location:0,length:2),NSRange(location:3,length:1)],"Explicit rectangle was reflowed before zoom")
        let base=try font(screen(s)).pointSize
        try dispatch(s,.zoomIn)
        try await wait{(try? font(screen(s)).pointSize)==base+1 && !column.snapshot().rectangleRowsExplicit}
        let reflowed=column.snapshot()
        try require(reflowed.rectangular && reflowed.primarySelectionID==9 && reflowed.rows.map(\.id)==[3,9] && reflowed.rows.map(\.range)==[NSRange(location:0,length:1),NSRange(location:3,length:1)],"Zoom did not recompute explicit rectangle from source corners/new font metrics")
        try unchanged(s,original);try dispatch(s,.reset)
    }
    static func interruptedGestures(_ c:Context,_ s:Surface)async throws {
        let original=Data(body.utf8);try await load(s,original);s.window.makeFirstResponder(s.text)
        for gate in ["busy","quit","sheet"] {
            try require(s.text.handleZoomWheel(with:wheel(s,y:6,precise:true,phase:.began)) && s.model.zoomLevel==0,"Fresh partial zoom gesture setup failed")
            if gate=="busy" {s.model.busy=true;s.model.busy=false}
            if gate=="quit" {s.model.confirmingQuit=true;s.model.confirmingQuit=false}
            if gate=="sheet" {
                let sheet=NSWindow(contentRect:.init(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false)
                sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;c.sheets.append(sheet)
                s.window.beginSheet(sheet,completionHandler:nil)
                try await wait{sheet.sheetParent === s.window}
                s.window.endSheet(sheet);try await wait{sheet.sheetParent==nil};sheet.close()
                s.window.makeFirstResponder(s.text)
            }
            // No wheel was delivered during the unavailable interval. Neither
            // the old changed event nor momentum may revive its partial tick.
            _=s.text.handleZoomWheel(with:try wheel(s,y:4,precise:true,phase:.changed))
            _=s.text.handleZoomWheel(with:try wheel(s,y:10,precise:true,momentum:.changed))
            try require(s.model.zoomLevel==0,"\(gate) begin/end without a wheel revived stale changed/momentum")
            try require(s.text.handleZoomWheel(with:wheel(s,y:10,precise:true,phase:.began)) && s.model.zoomLevel==1,"New gesture did not recover after \(gate)")
            try dispatch(s,.reset)
        }
        _=s.text.handleZoomWheel(with:try wheel(s,y:6,precise:true,phase:.began))
        let replacement=Data(("replacement\n"+body).utf8);try await load(s,replacement)
        _=s.text.handleZoomWheel(with:try wheel(s,y:4,precise:true,phase:.changed))
        _=s.text.handleZoomWheel(with:try wheel(s,y:10,precise:true,momentum:.changed))
        try require(s.model.zoomLevel==0,"Replacement document admitted old changed/momentum gesture")
        try require(s.text.handleZoomWheel(with:wheel(s,y:10,precise:true,phase:.began)) && s.model.zoomLevel==1,"Replacement refused fresh zoom gesture")
        try unchanged(s,replacement);try dispatch(s,.reset);try await load(s,original)
    }
    static func pointerAndLifetime(_ c:Context,_ s:Surface)async throws {
        let original=Data(body.utf8);try await load(s,original);s.window.makeFirstResponder(s.text)
        let initialPreferences=c.preferences.persistentDomain(forName:c.suite) ?? [:]
        try require(s.text.handleZoomWheel(with:wheel(s,y:99)),"Command wheel gesture not consumed")
        try require(s.model.zoomLevel==1,"Discrete wheel magnitude produced multiple zoom steps")
        try require(s.text.handleZoomWheel(with:wheel(s,y:-40,flags:.maskControl)),"Control wheel gesture not consumed")
        try require(s.model.zoomLevel==0,"Control wheel failed one opposite step")
        try require(s.text.handleZoomWheel(with:wheel(s,y:6,precise:true)) && s.model.zoomLevel==0,"Precise wheel partial tick zoomed prematurely")
        try require(s.text.handleZoomWheel(with:wheel(s,y:4,precise:true)) && s.model.zoomLevel==1,"Ten-point precise wheel accumulation failed")
        try dispatch(s,.reset)
        _=s.text.handleZoomWheel(with:try wheel(s,y:6,precise:true))
        try await load(s,original)
        _=s.text.handleZoomWheel(with:try wheel(s,y:4,precise:true));try require(s.model.zoomLevel==0,"Old document partial wheel leaked across reset")
        _=s.text.handleZoomWheel(with:try wheel(s,y:6,precise:true));try require(s.model.zoomLevel==1,"New document precise wheel failed fresh accumulation")
        try dispatch(s,.reset)
        _=s.text.handleZoomWheel(with:try wheel(s,y:6,precise:true))
        s.model.busy=true
        try require(s.text.handleZoomWheel(with:wheel(s,y:30,precise:true)) && s.model.zoomLevel==0,"Busy recognized wheel fell through or changed zoom")
        s.model.busy=false
        _=s.text.handleZoomWheel(with:try wheel(s,y:4,precise:true));try require(s.model.zoomLevel==0,"Busy interval revived partial wheel accumulation")
        _=s.text.handleZoomWheel(with:try wheel(s,y:0,precise:true,phase:.ended))
        _=s.text.handleZoomWheel(with:try wheel(s,y:6,precise:true))
        _=s.text.handleZoomWheel(with:try wheel(s,y:0,precise:true,phase:.ended))
        _=s.text.handleZoomWheel(with:try wheel(s,y:4,precise:true));try require(s.model.zoomLevel==0,"Ended wheel gesture retained partial remainder")
        try require(!s.text.handleZoomWheel(with:wheel(s,y:1,flags:[.maskCommand,.maskShift])) && !s.text.handleZoomWheel(with:wheel(s,y:1,x:30)) && !s.text.handleZoomWheel(with:wheel(s,y:1,flags:[])) && !s.text.handleZoomWheel(with:wheel(s,y:1,inside:false)),"Nonzoom/outside wheel was stolen")
        s.model.showFind()
        // SwiftUI attaches its AX identifier to an accessibility wrapper, not
        // the underlying AppKitTextField. Resolve this owner's actual Find
        // editor by its unique source placeholder and active field editor.
        try await wait{s.model.findVisible && views(s.window.contentView!).compactMap{$0 as? NSTextField}.filter{$0.placeholderString=="Find"}.count==1}
        let field=try unwrap(views(s.window.contentView!).compactMap{$0 as? NSTextField}.first{$0.placeholderString=="Find"},"Missing actual native Find editor")
        s.window.makeFirstResponder(field);let responder=s.window.firstResponder
        try require(field.currentEditor() === responder,"Actual Find field did not own its native field editor")
        try require(responder !== s.text && !s.text.canPerformZoomCommand(.zoomIn),"Find focus did not fence keyboard zoom")
        _=s.text.performKeyEquivalent(with:key(s,"+",24,.command));try require(s.model.zoomLevel==0,"Keyboard zoom targeted unfocused document")
        try require(s.text.handleZoomWheel(with:wheel(s,y:1)) && s.model.zoomLevel==1 && s.window.firstResponder === responder,"Hover wheel stole Find focus or failed owned zoom")
        s.model.hideFind();try await ready(s);s.window.makeFirstResponder(s.text);try dispatch(s,.reset)
        try require(NSDictionary(dictionary:c.preferences.persistentDomain(forName:c.suite) ?? [:]).isEqual(to:initialPreferences),"Temporary zoom wrote persistent preferences")
        try unchanged(s,original)
    }
    static func ownership(_ c:Context,_ s:Surface,_ repository:GitRepository)async throws {
        let original=Data(body.utf8);try await load(s,original);s.window.makeFirstResponder(s.text)
        let held=try item(s,.zoomIn)
        for gate in ["busy","quit","error","sheet"] {
            var sheet:NSWindow?
            if gate=="busy" {s.model.busy=true};if gate=="quit" {s.model.confirmingQuit=true};if gate=="error" {s.model.error="Private owned error"}
            if gate=="sheet" {let value=NSWindow(contentRect:.init(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false);value.isReleasedWhenClosed=false;value.alphaValue=0;c.sheets.append(value);s.window.beginSheet(value,completionHandler:nil);sheet=value}
            try require(!s.text.canPerformZoomCommand(.zoomIn) && !s.text.performZoomCommand(.zoomIn),"\(gate) accepted zoom command")
            _=NSApp.sendAction(held.action!,to:held.target,from:held);try require(s.model.zoomLevel==0,"Held unavailable zoom acted")
            s.model.busy=false;s.model.confirmingQuit=false;s.model.error=nil
            if let sheet {s.window.endSheet(sheet);try await wait{sheet.sheetParent==nil};sheet.close()}
        }
        try await load(s,original);_=NSApp.sendAction(held.action!,to:held.target,from:held);try require(s.model.zoomLevel==0,"Old-document zoom menu revived")
        _=s.text.handleZoomWheel(with:try wheel(s,y:6,precise:true,phase:.began))
        s.text.setMarkedText("候",selectedRange:.init(location:0,length:1),replacementRange:.init(location:NSNotFound,length:0))
        try require(s.text.hasMarkedText() && !s.text.canPerformZoomCommand(.zoomIn) && !s.text.performZoomCommand(.zoomIn),"Marked text did not fence keyboard zoom")
        s.text.unmarkText()
        _=s.text.handleZoomWheel(with:try wheel(s,y:4,precise:true,phase:.changed))
        _=s.text.handleZoomWheel(with:try wheel(s,y:10,precise:true,momentum:.changed))
        try require(s.model.zoomLevel==0,"Composition begin/end without a wheel revived stale zoom input")
        try await load(s,original)

        let preview=try await surface(c,c.owner(repository:repository));preview.model.readOnly=true;preview.model.reload(paths:["file.txt"],staged:false)
        try await wait{!preview.model.busy && preview.model.canFind && preview.text.string==preview.model.document.text && !preview.model.document.files.isEmpty}
        preview.window.makeFirstResponder(preview.text)
        try require(preview.text.canPerformZoomCommand(.zoomIn) && preview.text.performZoomCommand(.zoomIn) && preview.model.zoomLevel==1,"Readonly preview blocked presentation zoom")
        let retired=try await surface(c,c.owner());try await load(retired,original);let stale=try item(retired,.zoomIn)
        retired.owner.close();try await wait{retired.model.retired}
        _=NSApp.sendAction(stale.action!,to:stale.target,from:stale)
        try require(!retired.text.performZoomCommand(.zoomIn) && retired.model.zoomLevel==0,"Retired zoom target remained live")
    }
    static func main()async {
        let first=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,second=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.zoomQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(first,second);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            let repository=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Zoom QA"),("user.email","zoom@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:file);try await repository.stage(["file.txt"]);_=try await repository.commit(message:"base");try Data("base\nnew\n".utf8).write(to:file)
            let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
            let s=try await surface(c,c.owner());try await keyboardAndLayout(c,s);try await explicitRectangleReflow(c,s);try await pointerAndLifetime(c,s);try await interruptedGestures(c,s);try await ownership(c,s,repository)
            let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout
            try require(try finalHead==head && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==working,"Zoom changed HEAD/index/worktree")
            try await c.clean();print("PASS Unified Diff zoom: native commands/wheel/font/gutter/tab/print snapshot/ownership, exact bytes/Undo and closed windows")
        } catch {try? await c.clean();fputs("Unified Diff zoom failed: \(error)\n",stderr);exit(1)}
    }
}
