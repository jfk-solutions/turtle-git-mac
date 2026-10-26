// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func columnEditPrivateOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;columnEditPrivateOrder(mode,relativeTo:number)
    }
}
@MainActor
@main struct UnifiedColumnEditVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"line \(line): \(message)")}}
    static func packet(_ pieces:[Data])->Data {var bytes=Data();for piece in pieces {bytes.append(piece)};return bytes}
    static func phase(_ text:String){print("UDiff column edit: "+text);fflush(stdout)}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Native state timeout at line \(line)")
    }
    static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let suite="TurtleGit.ColumnEdit.QA."+UUID().uuidString
        let preferences:UserDefaults
        let board=NSPasteboard.withUniqueName()
        var owners:[PatchWindowController]=[],sheets:[NSWindow]=[]
        var pending:[(URL?)->Void]=[]
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(1251,forKey:"TurtleGitMerge.LegacyCodePage");preferences.set(true,forKey:"ShowAppContextMenuIcons")}
        func owner(repository:GitRepository?=nil)->PatchWindowController {
            let owner=PatchWindowController(repository:repository,access:nil,preferences:preferences,documentDirectory:root)
            owners.append(owner);owner.documentSession.askChanges={_,reply in reply(.discard)}
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.showWindow(nil);return owner
        }
        func clean()async throws {
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);try await UnifiedColumnEditVerification.wait {sheet.sheetParent==nil};sheet.close()}
            for owner in owners {owner.model.confirmingQuit=false;owner.close()}
            let replies=pending;pending.removeAll();replies.forEach{$0(nil)}
            try await UnifiedColumnEditVerification.wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0}
            try UnifiedColumnEditVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil} && sheets.allSatisfy{!$0.isVisible && $0.sheetParent==nil},"Owned windows/sheets survived cleanup")
            preferences.removePersistentDomain(forName:suite);board.releaseGlobally()
            UnifiedColumnEditVerification.phase("owned windows closed; sessions/Git workers drained; private pasteboard released")
        }
    }
    @MainActor struct Surface {
        let owner:PatchWindowController,text:PatchTextView.PatchText
        var window:NSWindow {owner.window!}
        var model:PatchWindowModel {owner.model}
        var session:PatchDocumentSession {owner.documentSession}
    }
    static func surface(_ c:Context,_ owner:PatchWindowController)async throws->Surface {
        try await wait {owner.window?.contentView.map{descendants($0).contains{$0 is PatchTextView.PatchText}} == true}
        let text=descendants(owner.window!.contentView!).compactMap{$0 as? PatchTextView.PatchText}.first!
        text.linePasteboard={c.board}
        owner.window?.makeFirstResponder(text)
        return Surface(owner:owner,text:text)
    }
    static func load(_ s:Surface,_ bytes:Data)async throws {
        s.owner.presentDocument(bytes,title:"Private column selection",comparison:"column-edit.patch",information:"Private native verification")
        try await wait {s.model.canEditText && s.text.isEditable && s.text.string.utf16.elementsEqual(s.model.document.text.utf16) && s.model.savedDocumentBytes==bytes && !s.model.documentDirty && PatchDocumentSession.activeOperations==0}
        s.window.contentView?.layoutSubtreeIfNeeded();s.window.makeFirstResponder(s.text)
        try require(try s.session.encodedBytes()==bytes,"Load changed original byte packets")
    }
    static func select(_ s:Surface,_ range:NSRange,_ affinity:NSSelectionAffinity = .downstream) {
        s.window.makeFirstResponder(s.text);s.text.setSelectedRange(range,affinity:affinity,stillSelecting:false)
    }
    static func key(_ s:Surface,_ characters:String,_ keyCode:UInt16,_ modifiers:NSEvent.ModifierFlags)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:keyCode)!
    }
    static func ready(_ s:Surface)async throws {
        await withCheckedContinuation { (reply:CheckedContinuation<Void,Never>) in DispatchQueue.main.async {reply.resume()} }
        s.window.contentView?.layoutSubtreeIfNeeded()
        try await wait {s.text.string.utf16.elementsEqual(s.model.document.text.utf16) && !s.model.busy}
    }
    static func bytes(_ s:Surface,_ expected:Data,_ message:String)throws {
        let actual=try s.session.encodedBytes()
        try require(actual==expected,message+"; actualHex="+actual.map{String(format:"%02x",$0)}.joined()+" expectedHex="+expected.map{String(format:"%02x",$0)}.joined()+" selection=\(s.text.selectedRange()) affinity=\(s.text.selectionAffinity.rawValue)")
    }
    static func column(_ s:Surface)throws->PatchColumnSelectionController {
        guard let value=s.text.columnSelection else {throw Failure(description:"Hosted column controller missing")};return value
    }
    static func snapshot(_ s:Surface)throws->PatchTextSelectionSnapshot {try column(s).snapshot()}
    static func apply(_ s:Surface,_ rows:[PatchLineEditSelection],primary:Int,rectangle:Bool) throws {
        s.window.makeFirstResponder(s.text)
        try require(try column(s).applySnapshot(.init(rows:rows,primarySelectionID:primary,rectangular:rectangle,rectangleIsThin:rectangle && rows.allSatisfy{$0.range.length==0})),"Native selection snapshot refused")
    }
    static func caretPoint(_ s:Surface,_ offset:Int)throws->NSPoint {
        var actual=NSRange(location:NSNotFound,length:0)
        let screen=s.text.firstRect(forCharacterRange:NSRange(location:offset,length:0),actualRange:&actual)
        try require(screen.height>0 && screen.minX.isFinite,"Native insertion rectangle unavailable at \(offset)")
        return s.text.convert(s.window.convertPoint(fromScreen:NSPoint(x:screen.minX,y:screen.midY)),from:nil)
    }
    static func mouse(_ s:Surface,_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {
        NSEvent.mouseEvent(with:type,location:s.text.convert(point,to:nil),modifierFlags:.option,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    }
    static func drag(_ s:Surface,_ start:Int,_ end:Int)throws {
        try dragPoints(s,caretPoint(s,start),caretPoint(s,end))
    }
    static func dragPoints(_ s:Surface,_ a:NSPoint,_ b:NSPoint)throws {
        NSApp.postEvent(mouse(s,.leftMouseUp,b),atStart:true);NSApp.postEvent(mouse(s,.leftMouseDragged,b),atStart:true)
        s.text.mouseDown(with:mouse(s,.leftMouseDown,a))
        try require(try !column(s).isSelecting,"Owned Option-drag did not finish")
    }
    static func lineItem(_ s:Surface,_ command:PatchLineCommand)throws->NSMenuItem {
        let before=try snapshot(s)
        let event=mouse(s,.rightMouseDown,try caretPoint(s,before.primary.caret))
        let menu=s.text.menu(for:event)
        try require(try snapshot(s)==before,"Context menu opening discarded additional/empty primary ranges")
        guard let item=menu?.items.first(where:{$0.title=="Lines"})?.submenu?.items.first(where:{$0.title==command.title}) else {throw Failure(description:"Native Lines command missing")}
        return item
    }
    static func dispatch(_ s:Surface,_ command:PatchLineCommand)throws {
        let item=try lineItem(s,command)
        try require(item.isEnabled && item.image != nil && item.action != nil && item.target != nil,"Multi-range line action disabled/missing icon or target")
        try require(NSApp.sendAction(item.action!,to:item.target,from:item),"Multi-range native action refused dispatch")
    }
    static func ordinary(_ s:Surface,_ action:Selector)throws {try require(NSApp.sendAction(action,to:s.text,from:nil),"Native ordinary column action refused")}
    static func boundary(_ s:Surface)async throws {
        s.text.breakUndoCoalescing()
        let event=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,subtype:0,data1:0x434f4c4d,data2:0)!
        NSApp.postEvent(event,atStart:false);try await wait {s.text.undoManager?.groupingLevel==0}
    }
    static func undoRedo(_ s:Surface,_ before:Data,_ after:Data,_ state:PatchTextSelectionSnapshot)async throws {
        let changed=try snapshot(s);try await boundary(s)
        try require(s.text.undoManager?.canUndo==true,"Column transaction not undoable")
        s.text.undoPatch(nil);try await ready(s);try bytes(s,before,"One Undo lost original byte packets")
        try require(try snapshot(s)==state,"One Undo lost row IDs/direction/primary/rectangle metadata")
        s.text.redoPatch(nil);try await ready(s);try bytes(s,after,"One Redo lost edited byte packets")
        try require(try snapshot(s)==changed,"One Redo lost complete selection snapshot")
    }
    static func save(_ c:Context,_ s:Surface,_ expected:Data,_ name:String)async throws {
        let target=c.root.appendingPathComponent(name);s.session.chooseSave={_,_,reply in reply(target)}
        try require(s.window.performKeyEquivalent(with:key(s,"s",1,.command)),"Native CmdS did not route column save")
        try await wait {PatchDocumentSession.activeOperations==0 && !s.model.busy && !s.model.documentDirty && FileManager.default.fileExists(atPath:target.path)}
        try require(try Data(contentsOf:target)==expected && s.model.savedDocumentBytes==expected,"Column Save changed original encoding/bytes/endings")
    }
    static func selection(_ c:Context,_ s:Surface)async throws {
        phase("real Option-drag, tab/Unicode/short-row geometry, native extension, scroll and rendering continuation")
        try await load(s,Data("abcd\nab\n\nabcdef\n".utf8))
        select(s,NSRange(location:0,length:0));let menu=s.text.makeColumnSelectionMenu()
        try require(menu.items.map(\.title)==PatchColumnDirection.allCases.map(\.title) && menu.items.allSatisfy{$0.isEnabled && $0.image != nil && $0.target === s.text && $0.action != nil},"Column Selection native commands missing source order/icons/owner/enabled state")
        let right=menu.items.first{$0.title==PatchColumnDirection.right.title}!
        try require(NSApp.sendAction(right.action!,to:right.target,from:right),"Native Column Selection menu refused real dispatch")
        try require(try snapshot(s).rectangular && snapshot(s).primary.range==NSRange(location:0,length:1),"Native column menu dispatched wrong direction")
        try drag(s,1,12)
        var state=try snapshot(s)
        try require(state.rectangular && state.rows.map(\.range)==[NSRange(location:1,length:2),NSRange(location:6,length:1),NSRange(location:8,length:0),NSRange(location:10,length:2)],"Option-drag rectangle did not clamp short/empty logical rows")
        try require(state.primarySelectionID==state.rows.last?.id && state.primary.caret==12,"Native sorting lost dragged primary row")
        try bytes(s,Data("abcd\nab\n\nabcdef\n".utf8),"Column selection edited bytes")
        try await load(s,Data("abcd\n".utf8))
        let p0=try caretPoint(s,0),p1=try caretPoint(s,1),cell=p1.x-p0.x
        try require(cell>0,"ASCII insertion points have no advance")
        try dragPoints(s,NSPoint(x:p0.x+cell*0.25,y:p0.y),NSPoint(x:p1.x+cell*0.75,y:p1.y))
        try require(try snapshot(s).primary.range==NSRange(location:0,length:2),"Fractional glyph hit test did not round at insertion midpoint")
        try dragPoints(s,NSPoint(x:p0.x+cell*0.75,y:p0.y),NSPoint(x:p1.x+cell*0.25,y:p1.y))
        try require(try snapshot(s).primary.range==NSRange(location:1,length:0),"Opposite fractional-cell sides did not snap to nearest legal caret")
        try await load(s,Data("abcd\nab\n\nabcdef\n".utf8));try drag(s,1,12);state=try snapshot(s)
        let before=state
        try require(try column(s).beginRectangle(at:caretPoint(s,0)),"Cancellation gesture refused")
        _=try column(s).continueRectangle(at:caretPoint(s,6));try column(s).cancelRectangle()
        try require(try snapshot(s)==before,"Cancel failed all-range rectangle restoration")
        try await load(s,Data("abcd\n\tZ\n\nabcdef\n".utf8));try drag(s,0,13)
        state=try snapshot(s)
        try require(state.rows.count==4 && state.rows[0].range==NSRange(location:0,length:4) && state.rows[1].range==NSRange(location:5,length:1) && state.rows[2].range.length==0,"Rectangle did not use actual tab-expanded geometry/no virtual space")
        try await load(s,Data("a😀b\nxy\n".utf8));try drag(s,1,3)
        try require(try snapshot(s).primary.range==NSRange(location:1,length:2),"Rectangle split a surrogate-pair glyph")
        try await load(s,Data("ae\u{301}b\nxy\n".utf8));select(s,NSRange(location:1,length:0))
        let flags:NSEvent.ModifierFlags=[.command,.option,.shift]
        try require(s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!),124,flags)),"Owned keyboard column extension not routed")
        try require(try snapshot(s).primary.range==NSRange(location:1,length:2),"Keyboard column extension split composed text")
        try require(s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!),125,flags)),"Keyboard column down not routed")
        state=try snapshot(s);try require(state.rectangular && state.rows.count==2 && state.primarySelectionID==state.rows.last?.id,"Keyboard extension lost primary/logical rows")
        try require(PatchColumnDirection.direction(for:key(s,String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!),124,[.option,.shift]))==nil && PatchColumnDirection.direction(for:key(s,String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!),124,[.control,.option,.shift]))==nil,"Column shortcuts consumed native word selection/VoiceOver modifiers")
        try await load(s,Data("abcdef\nx\nabcdef\n".utf8));select(s,NSRange(location:4,length:0))
        try require(s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!),125,flags)),"First short-row keyboard extension refused")
        try require(try snapshot(s).primary.caret==8,"Short row did not clamp keyboard caret")
        try require(s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!),125,flags)),"Second long-row keyboard extension refused")
        state=try snapshot(s)
        try require(state.primary.caret==13 && state.rows.map(\.range)==[NSRange(location:4,length:0),NSRange(location:8,length:0),NSRange(location:13,length:0)],"Vertical rectangle lost remembered X through a short row")
        try await load(s,Data("\t  abcdef\n".utf8));select(s,NSRange(location:7,length:0))
        for (function,keyCode,expected) in [(NSHomeFunctionKey,UInt16(115),3),(NSHomeFunctionKey,UInt16(115),0),(NSEndFunctionKey,UInt16(119),9)] {
            try require(s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(function))!),keyCode,flags)),"Home/End column key not routed")
            try require(try snapshot(s).primary.caret==expected,"Source Home indentation toggle/End logical EOL mismatch")
        }
        try await load(s,Data("abcdef\nx\nabcdef\n".utf8));select(s,NSRange(location:4,length:0))
        _=s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!),125,flags))
        _=s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!),125,flags));state=try snapshot(s)
        var settings=UnifiedDiffAppearance.load(from:c.preferences);settings.fontName="Menlo";settings.fontSize=19;settings.save(to:c.preferences)
        NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.preferences);try await ready(s)
        try require(try snapshot(s).rows==state.rows && snapshot(s).primarySelectionID==state.primarySelectionID,"Restyling collapsed selected ranges or primary identity")
        let anchor=state.rows.first!.anchor
        _=try column(s).extendRectangle(direction:.right)
        try require(try snapshot(s).rows.first?.anchor==anchor,"Font change retained stale rectangle anchor pixels")
        settings.fontSize=10;settings.save(to:c.preferences);NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.preferences);try await ready(s)
        let lines=(0..<160).map{String(repeating:"x",count:180)+" \($0)"}.joined(separator:"\n")
        try await load(s,Data(lines.utf8));let index=PatchLineIndex(text:s.text.string),start=index.lineStarts[30]+12
        select(s,NSRange(location:index.lineStarts[50]+12,length:0));s.text.scrollRangeToVisible(s.text.selectedRange())
        let viewport=s.text.visibleRect.height,lineHeight=s.text.layoutManager!.defaultLineHeight(for:s.text.font!),page=max(1,Int(viewport/max(1,lineHeight))-1)
        try require(s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(NSPageDownFunctionKey))!),121,flags)),"PageDown column key not routed")
        var pageState=try snapshot(s),pageLine=index.lineIndex(atUTF16Offset:pageState.primary.caret)!
        try require(pageLine==min(159,50+page) && pageState.primary.caret-index.lineStarts[pageLine]==12,"PageDown did not use native viewport logical rows/remembered X")
        let reversePage=max(1,Int(s.text.visibleRect.height/max(1,lineHeight))-1)
        try require(s.text.performKeyEquivalent(with:key(s,String(UnicodeScalar(UInt32(NSPageUpFunctionKey))!),116,flags)),"PageUp column key not routed")
        pageState=try snapshot(s);let upLine=index.lineIndex(atUTF16Offset:pageState.primary.caret)!
        try require(upLine==max(0,pageLine-reversePage) && pageState.primary.caret-index.lineStarts[upLine]==12,"PageUp lost native viewport/column geometry")
        s.text.scrollRangeToVisible(NSRange(location:start,length:1));let point=try caretPoint(s,start)
        let scroll=s.text.enclosingScrollView!;scroll.contentView.scroll(to:NSPoint(x:40,y:scroll.contentView.bounds.minY));scroll.reflectScrolledClipView(scroll.contentView)
        try require(try column(s).beginRectangle(at:point),"Autoscroll start refused")
        let origin=scroll.contentView.bounds.origin
        let outside=s.text.convert(NSPoint(x:scroll.contentView.bounds.midX,y:scroll.contentView.bounds.maxY+60),from:scroll.contentView)
        _=try column(s).continueRectangle(at:outside);try column(s).autoscrollRectangle()
        try require(scroll.contentView.bounds.minY>origin.y && abs(scroll.contentView.bounds.minX-origin.x)<0.5,"Column autoscroll lost window-pointer/horizontal geometry")
        try column(s).cancelRectangle()
        // Upstream UDiff is unwrapped. Force wrapping only to verify bounded
        // logical-row and scalar safety, without claiming wrapped-source parity.
        try await load(s,Data((String(repeating:"wrap ",count:40)+"\nnext\n").utf8))
        s.text.isHorizontallyResizable=false;s.text.textContainer?.widthTracksTextView=true;s.text.setFrameSize(NSSize(width:220,height:2000));s.text.textContainer?.containerSize=NSSize(width:200,height:CGFloat.greatestFiniteMagnitude)
        try drag(s,1,30);state=try snapshot(s)
        try require(state.rows.count<=PatchLineIndex(text:s.text.string).lineCount && state.rows.allSatisfy{$0.anchor>=0 && $0.caret<=s.text.string.utf16.count},"Wrapped continuation created spurious logical rows/out-of-bounds selection")
        s.text.isHorizontallyResizable=true;s.text.textContainer?.widthTracksTextView=false;s.text.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
    }
    static func commands(_ c:Context,_ s:Surface)async throws {
        phase("source primary-only versus every-range commands, ordinary typing/delete, exact full-range Undo/Redo")
        let data=Data("abc\nxyz".utf8),rows:[PatchLineEditSelection]=[.init(id:10,anchor:1,caret:2),.init(id:20,anchor:5,caret:6)]
        try await load(s,data);try apply(s,rows,primary:20,rectangle:true)
        let state=try snapshot(s);try dispatch(s,.copyLines)
        try require(c.board.string(forType:.string)=="xyz" && !PatchColumnClipboard.isRectangular(c.board) && snapshot(s)==state,"Copy Lines did not use only primary whole line")
        try dispatch(s,.duplicate);try await ready(s);let duplicated=Data("abbc\nxyyz".utf8)
        try bytes(s,duplicated,"Rectangle duplicate did not process every range")
        try require(try snapshot(s).rectangular && snapshot(s).primary.range==NSRange(location:6,length:1) && snapshot(s).rows.map(\.range)==[NSRange(location:1,length:1),NSRange(location:6,length:1)],"Duplicate did not rebuild source rectangle corners on duplicated text")
        try await undoRedo(s,data,duplicated,state)
        try await load(s,data);try apply(s,rows,primary:20,rectangle:true);let cutState=try snapshot(s)
        try dispatch(s,.cutLines);try await ready(s);let cut=Data("ac\nxz".utf8)
        try bytes(s,cut,"Rectangle Cut Lines used primary whole-line behavior")
        try require(c.board.string(forType:.string)=="b\ny\n" && PatchColumnClipboard.isRectangular(c.board) && snapshot(s).rows.allSatisfy{$0.range.length==0},"Rectangle cut lost trailing-LF clipboard/thin rows")
        try await undoRedo(s,data,cut,cutState)
        try await load(s,data);try apply(s,rows,primary:20,rectangle:false);let streamState=try snapshot(s)
        try dispatch(s,.cutLines);try await ready(s);try bytes(s,Data("abc\n".utf8),"Multi-stream Cut Lines did not restrict to primary whole line")
        try require(try snapshot(s).rows.count==1 && snapshot(s).primarySelectionID==20,"Primary-only Cut Lines retained discarded ranges")
        try await undoRedo(s,data,Data("abc\n".utf8),streamState)
        try await load(s,data);try apply(s,rows,primary:20,rectangle:true);let indentState=try snapshot(s)
        try dispatch(s,.indent);try await ready(s);let indented=Data("\tabc\n\txyz".utf8)
        try bytes(s,indented,"Rectangle indent failed every selected row")
        try require(try snapshot(s).rows.allSatisfy{$0.range.length==0} && snapshot(s).rectangular,"Rectangle indent did not finish thin")
        try await undoRedo(s,data,indented,indentState)
        try await load(s,data);try apply(s,rows,primary:20,rectangle:true);let typingState=try snapshot(s)
        s.text.insertText("Q",replacementRange:NSRange(location:NSNotFound,length:0));try await ready(s)
        try bytes(s,Data("abc\nxQz".utf8),"Ordinary typing replicated across secondary ranges instead of primary source selection")
        try require(try snapshot(s).rows.count==1 && !snapshot(s).rectangular,"Primary typing failed stream collapse")
        try await undoRedo(s,data,Data("abc\nxQz".utf8),typingState)
        try await load(s,data);try apply(s,rows,primary:20,rectangle:false);let deletedState=try snapshot(s)
        try dispatch(s,.deleteLine);try await ready(s);try bytes(s,Data("abc\n".utf8),"Delete Line did not restrict deletion to primary caret line")
        try require(try snapshot(s).rows.count==2 && snapshot(s).rows.first?.range==rows.first?.range,"Delete Line discarded surviving secondary selection")
        try await undoRedo(s,data,Data("abc\n".utf8),deletedState)
        try await load(s,data);try apply(s,rows,primary:20,rectangle:false);let transposeState=try snapshot(s)
        try dispatch(s,.transpose);try await ready(s);try bytes(s,Data("xyz\nabc".utf8),"Transpose did not use primary current line")
        try require(try snapshot(s).rows.count==1 && !snapshot(s).rectangular,"Transpose did not collapse secondary source selections")
        try await undoRedo(s,data,Data("xyz\nabc".utf8),transposeState)
        try await load(s,data);try apply(s,rows,primary:20,rectangle:true);let tabState=try snapshot(s)
        s.text.keyDown(with:key(s,"\t",48,[]));try await ready(s)
        try bytes(s,Data("a\tc\nx\tz".utf8),"Actual Tab failed per-range source replacement")
        try require(try snapshot(s).rectangular && snapshot(s).rows.allSatisfy{$0.range.length==0},"Tab did not keep thin rectangle")
        try await undoRedo(s,data,Data("a\tc\nx\tz".utf8),tabState)
        try await load(s,Data("😀x\r\ny\n".utf8));let thin=[PatchLineEditSelection(id:10,anchor:2,caret:2),.init(id:20,anchor:6,caret:6)];try apply(s,thin,primary:20,rectangle:true);let before=try snapshot(s)
        try ordinary(s,#selector(NSResponder.deleteBackward(_:)));try await ready(s)
        try bytes(s,Data("x\r\n\n".utf8),"Thin rectangle Backspace split surrogate/crossed ending")
        try await undoRedo(s,Data("😀x\r\ny\n".utf8),Data("x\r\n\n".utf8),before)
    }
    static func rawAndClipboard(_ c:Context,_ s:Surface,skipStream:Bool=false,skipPastePreamble:Bool=false,skipMarkedReverse:Bool=false)async throws {
        phase("mixed-codec/opaque byte multiple ranges, Save and complete-range Undo/Redo; rectangular clipboard and proportional paste")
        let first=Data("a😀\r\n".utf8),regional=Data([0xff,0x42,10]),opaque=Data([0x98,0,0xff,13])
        let original=packet([first,regional,opaque])
        let rows:[PatchLineEditSelection]=[.init(id:10,anchor:1,caret:0),.init(id:20,anchor:6,caret:5),.init(id:30,anchor:9,caret:8)]
        var before:PatchTextSelectionSnapshot
        let pasteInput=Data("abc\nxyz\n".utf8)
        if !skipStream && !skipPastePreamble {
        try await load(s,original);try apply(s,rows,primary:20,rectangle:false);before=try snapshot(s)
        try dispatch(s,.duplicate);try await ready(s)
        let duplicated=packet([Data("aa😀\r\n".utf8),Data([0xff,0xff,0x42,10]),Data([0x98,0x98,0,0xff,13])])
        try bytes(s,duplicated,"Multi-range duplicate transcoded regional/opaque packets")
        try require(try snapshot(s).rows.allSatisfy(\.isReversed) && snapshot(s).primarySelectionID==20,"Stream duplicate lost reversed ranges/explicit primary")
        try await save(c,s,duplicated,"multi-duplicate.patch");try await undoRedo(s,original,duplicated,before)
        try await load(s,original);try apply(s,rows,primary:20,rectangle:false);before=try snapshot(s)
        try dispatch(s,.indent);try await ready(s)
        let indented=packet([Data([9]),first,Data([9]),regional,Data([9]),opaque])
        try bytes(s,indented,"Multi-range indentation lost original mixed bytes/line terminators")
        try await save(c,s,indented,"multi-indent.patch");try await undoRedo(s,original,indented,before)
        }
        if !skipPastePreamble {
        // A byte-carrier glyph has no source guarantee of an ASCII cell's
        // advance. Native geometry selects visible c; opaque/NUL bytes remain
        // outside that rectangle and must survive Cut/Save/Undo exactly.
        let cutOriginal=packet([first,regional,Data([0x63]),opaque])
        try await load(s,cutOriginal);try drag(s,0,9);before=try snapshot(s)
        let points=try [0,1,5,6,8,9].map{offset in "\(offset):\(try caretPoint(s,offset))"}.joined(separator:";")
        phase("mixed rectangle diagnostic rows=\(before.rows) primary=\(before.primarySelectionID) scalars=\(s.text.string.unicodeScalars.map{String($0.value,radix:16)}.joined(separator:",")) nativepoints=\(points) font=\(String(describing:s.text.font))")
        try require(before.rows.map(\.range)==[NSRange(location:0,length:1),NSRange(location:5,length:1),NSRange(location:8,length:1)],"Native mixed-codec rectangle did not select one actual glyph per row")
        try ordinary(s,#selector(NSText.cut(_:)));try await ready(s)
        let cut=packet([Data("😀\r\n".utf8),Data([0x42,10]),opaque])
        try bytes(s,cut,"Ordinary rectangle Cut transcoded retained emoji/NUL/regional packets")
        try require(PatchColumnClipboard.isRectangular(c.board) && c.board.data(forType:PatchColumnClipboard.rectangularType)==PatchColumnClipboard.rectangularMarker,"Native Cut did not publish source rectangular clipboard marker")
        try await save(c,s,cut,"rectangle-cut.patch");try await undoRedo(s,cutOriginal,cut,before)
        // Real ordinary Copy, including an empty intermediate row and final LF.
        try await load(s,Data("A\n\nC\nD\n".utf8));try drag(s,0,6)
        try ordinary(s,#selector(NSText.copy(_:)))
        try require(c.board.string(forType:.string)=="A\n\nC\nD\n" && PatchColumnClipboard.isRectangular(c.board),"Ordinary rectangular Copy lost empty row/trailing LF/marker")
        for (font,value,offset) in [("Menlo","abcde\r\nx\n\tz",4),("Helvetica","WWxx\r\nx\n\tz",2)] {
            var settings=UnifiedDiffAppearance.load(from:c.preferences);settings.fontName=font;settings.fontSize=13;settings.save(to:c.preferences)
            NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.preferences)
            let input=Data(value.utf8);try await load(s,input);select(s,NSRange(location:offset,length:0));before=try snapshot(s)
            let expectedX=try caretPoint(s,offset).x
            try ordinary(s,#selector(NSText.paste(_:)));try await ready(s)
            let output=try s.session.encodedBytes(),shown=s.text.string as NSString
            try require(s.text.string.hasPrefix(font=="Menlo" ? "abcdAe\r\n":"WWAxx\r\n"),"Rectangle paste did not insert first row at original source caret")
            try require(s.text.string.contains("\r\n") && s.text.string.contains("\t") && s.text.string.contains("z"),"Rectangle paste rewrote old mixed EOL/tab contents")
            for letter in ["C","D"] {
                let location=shown.range(of:letter).location
                try require(location != NSNotFound,"Rectangular paste omitted clipboard row \(letter)")
                let x=try caretPoint(s,location).x
                let space=(" " as NSString).size(withAttributes:[.font:s.text.font ?? NSFont.systemFont(ofSize:13)]).width
                try require(abs(x-expectedX)<=space+0.75,"\(font) rectangle paste used character count instead of native proportional/tab X: \(x) versus \(expectedX)")
            }
            try require(try snapshot(s).rows.count==1 && !snapshot(s).rectangular && snapshot(s).primary.caret==offset,"Rectangle paste did not return source caret/collapse selection")
            try await save(c,s,output,"paste-\(font).patch");try await undoRedo(s,input,output,before)
        }
        // Paste over downward geometry must begin at top/left after deletion,
        // not the primary bottom row. No dimensions or space padding involved.
        _=PatchColumnClipboard.write(text:"1\n2\n",rectangular:true,to:c.board)
        try await load(s,pasteInput);try drag(s,1,6);before=try snapshot(s)
        try ordinary(s,#selector(NSText.paste(_:)));try await ready(s)
        let pasteOutput=Data("a1c\nx2z\n".utf8);try bytes(s,pasteOutput,"Paste over downward rectangle started at bottom primary row")
        try await undoRedo(s,pasteInput,pasteOutput,before)
        }
        // Reverse-vertical source ThinRectangularRange reprojects bottom
        // anchor X after tab deletion onto the short top row. The resulting
        // source start is column zero, not the old top row's end offset one.
        var reverseSettings=UnifiedDiffAppearance.load(from:c.preferences);reverseSettings.fontName="Helvetica";reverseSettings.fontSize=13;reverseSettings.tabSize=8;reverseSettings.save(to:c.preferences)
        NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.preferences)
        let reverseInput=Data("W\n\tzz\n".utf8)
        for (value,rectangular,result) in [("1\n2\n",true,"1W\n2zz\n"),("Q",false,"QW\nzz\n"),("\r\n",true,"W\nzz\n")] {
            if skipMarkedReverse && value=="1\n2\n" {continue}
            try await load(s,reverseInput);let nativeStartX=try caretPoint(s,0).x
            let tabEnd=try caretPoint(s,3).x,topEnd=try caretPoint(s,1).x,tabStart=try caretPoint(s,2).x
            try require(tabEnd-tabStart>2*(topEnd-nativeStartX),"Reverse paste subject lacks tab-midpoint separation: tabStart=\(tabStart), tabEnd=\(tabEnd), topStart=\(nativeStartX), topEnd=\(topEnd)")
            try drag(s,3,1);before=try snapshot(s)
            try require(before.rows.map(\.range)==[NSRange(location:2,length:1),NSRange(location:1,length:0)],"Reverse-vertical native rectangle setup selected wrong source spans: rows=\(before.rows), tabStart=\(tabStart), tabEnd=\(tabEnd), topStart=\(nativeStartX), topEnd=\(topEnd)")
            _=PatchColumnClipboard.write(text:value,rectangular:rectangular,to:c.board)
            try ordinary(s,#selector(NSText.paste(_:)));try await ready(s)
            let expected=Data(result.utf8);try bytes(s,expected,"Reverse tab/proportional cleared-thin paste used stale minimum row offsets")
            let pastedState=try snapshot(s),expectedCaret=rectangular ? 0:value.utf16.count
            try require(pastedState.primary.caret==expectedCaret && pastedState.rows.count==1,"Reverse cleared-thin Paste caret mismatch: value=\(value.debugDescription), rectangular=\(rectangular), expected=\(expectedCaret), state=\(pastedState)")
            if !value.hasPrefix("\r") {try require(abs(try caretPoint(s,0).x-nativeStartX)<0.5,"Reverse paste insertion X differs from actual native source column zero")}
            try await undoRedo(s,reverseInput,expected,before)
        }
        // A marker-only clipboard still performs the selection deletion.
        _=PatchColumnClipboard.write(text:"\r\n\n",rectangular:true,to:c.board)
        try await load(s,pasteInput);try drag(s,1,6);before=try snapshot(s)
        try ordinary(s,#selector(NSText.paste(_:)));try await ready(s)
        let cleared=Data("ac\nxz\n".utf8);try bytes(s,cleared,"Empty rectangular clipboard discarded source deletion")
        try require(try snapshot(s).rows.count==1 && !snapshot(s).rectangular && snapshot(s).primary.caret==1,"Empty rectangular Paste did not finish at cleared top-left caret")
        try await undoRedo(s,pasteInput,cleared,before)
    }
    static func ownership(_ c:Context,_ s:Surface,_ repo:GitRepository)async throws {
        phase("read-only preview, partial-hunk selection, marked text, modal/busy/Quit, stale gesture/replacement/Save-close cleanup")
        let preview=try await surface(c,c.owner(repository:repo));preview.model.readOnly=true;preview.model.reload(paths:["file.txt"],staged:false)
        try await wait {!preview.model.busy && !preview.model.document.files.isEmpty && preview.text.string==preview.model.document.text}
        let changed=preview.model.document.lines.firstIndex(of:"+new")!,index=PatchLineIndex(text:preview.text.string)
        let begin=index.lineStarts[changed]
        try drag(preview,begin,begin+2);let previewBytes=try preview.session.encodedBytes()
        try ordinary(preview,#selector(NSText.copy(_:)))
        try require(PatchColumnClipboard.isRectangular(c.board) && c.board.string(forType:.string)=="+n\n","Read-only native column Copy unavailable")
        for command in [PatchLineCommand.cutLines,.deleteLine,.duplicate,.transpose,.indent,.dedent] {
            try require(!preview.text.canPerformLineCommand(command) && !preview.text.performLineCommand(command),"Read-only native multiple-range mutation enabled")
        }
        try ordinary(preview,#selector(NSText.cut(_:)));try ordinary(preview,#selector(NSText.paste(_:)))
        try bytes(preview,previewBytes,"Read-only clipboard mutation changed Git preview")
        try require(preview.model.selectedLines.contains(changed),"Native column selection did not propagate partial-hunk model rows")
        let original=Data("one\ntwo\n".utf8);try await load(s,original);try drag(s,1,6)
        let held=try lineItem(s,.duplicate),live=try column(s),saved=try snapshot(s)
        for gate in ["busy","quit","sheet"] {
            var sheet:NSWindow?
            if gate=="busy" {s.model.busy=true};if gate=="quit" {s.model.confirmingQuit=true}
            if gate=="sheet" {let value=NSWindow(contentRect:NSRect(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false);value.isReleasedWhenClosed=false;value.alphaValue=0;c.sheets.append(value);s.window.beginSheet(value,completionHandler:nil);sheet=value}
            try require(!live.available && !live.beginRectangle(at:caretPoint(s,0)) && !s.text.performLineCommand(.duplicate),"\(gate) accepted column gesture/mutation")
            _=NSApp.sendAction(held.action!,to:held.target,from:held);try bytes(s,original,"\(gate) retained menu changed bytes")
            try require(try snapshot(s)==saved,"Denied \(gate) changed selected ranges")
            s.model.busy=false;s.model.confirmingQuit=false
            if let sheet {s.window.endSheet(sheet);try await wait{sheet.sheetParent==nil};sheet.close()}
        }
        try require(!live.beginRectangle(at:NSPoint(x:CGFloat.nan,y:0)),"Nonfinite native gesture accepted")
        select(s,NSRange(location:1,length:0));s.text.setMarkedText("候補",selectedRange:NSRange(location:0,length:2),replacementRange:NSRange(location:NSNotFound,length:0))
        let draft=s.text.string
        try require(s.text.hasMarkedText() && !live.available && !live.beginRectangle(at:caretPoint(s,0)) && !s.text.performLineCommand(.duplicate),"IME composition accepted column/line edit")
        try require(s.text.string.utf16.elementsEqual(draft.utf16),"Declined IME command changed marked draft")
        s.text.unmarkText();try await ready(s);try await load(s,original)
        try require(live.beginRectangle(at:caretPoint(s,0)),"Current gesture refused before replacement")
        _=live.continueRectangle(at:try caretPoint(s,5))
        try await load(s,original)
        try require(!live.continueRectangle(at:caretPoint(s,6)),"Same-text replacement revived stale drag")
        _=NSApp.sendAction(held.action!,to:held.target,from:held);try bytes(s,original,"Same-text replacement revived retained menu")
        try drag(s,1,6);try dispatch(s,.duplicate);try await ready(s)
        try require(s.model.documentDirty,"Fresh replacement rectangle action unavailable")
        var release:((URL?)->Void)?
        s.session.chooseSave={_,_,reply in release=reply;c.pending.append(reply)};s.session.saveDocument(as:true)
        try await wait{release != nil && s.model.busy}
        try require(!live.available && !s.text.performLineCommand(.deleteLine),"Held Save accepted column mutation")
        s.owner.close();let unwanted=c.root.appendingPathComponent("retired-column-save.patch")
        release?(unwanted);release=nil;c.pending.removeAll();try await wait{PatchDocumentSession.activeOperations==0}
        try require(s.model.retired && !s.window.isVisible && !live.available && !live.beginRectangle(at:.zero),"Closed source retained live column controller")
        try require(!FileManager.default.fileExists(atPath:unwanted.path),"Retired Save wrote private captured packet")
    }
    static func main()async {
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.columnEditPrivateOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,replacement);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            let repo=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Column edit QA"),("user.email","column@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"baseline");try Data("base\nnew\n".utf8).write(to:file)
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:c.root.appendingPathComponent(".git/config")),working=try Data(contentsOf:file)
            let s=try await surface(c,c.owner()),requested=Set(CommandLine.arguments.dropFirst(3))
            let scopes=requested.isEmpty ? Set(["selection","commands","bytes","ownership"]):requested
            if scopes.contains("selection"){try await selection(c,s)}
            if scopes.contains("commands"){try await commands(c,s)}
            if scopes.contains("bytes") || scopes.contains("bytes-after-stream") || scopes.contains("bytes-paste-tail") || scopes.contains("bytes-reverse-stream-tail"){try await rawAndClipboard(c,s,skipStream:scopes.contains("bytes-after-stream"),skipPastePreamble:scopes.contains("bytes-paste-tail") || scopes.contains("bytes-reverse-stream-tail"),skipMarkedReverse:scopes.contains("bytes-reverse-stream-tail"))}
            if scopes.contains("ownership"){try await ownership(c,s,repo)}
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(finalHead==head && Data(contentsOf:file)==working && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:c.root.appendingPathComponent(".git/config"))==config,"Column editor changed Git HEAD/index/config/worktree")
            try await c.clean();phase("PASS Unified Diff column edit: scope="+scopes.sorted().joined(separator:",")+"; exact Git state preserved; all owned windows closed")
        }catch{try? await c.clean();fputs("Unified Diff column edit failed: \(error)\n",stderr);fflush(stderr);exit(1)}
    }
}
