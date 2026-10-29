// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func blockQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;blockQAOrder(mode,relativeTo:number)}
}
@MainActor @main struct UnifiedBlockNavigationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"line \(line): \(message)")}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Caret native state timeout at line \(line)")
    }
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let suite="TurtleGit.Caret.QA."+UUID().uuidString
        let preferences:UserDefaults,board=NSPasteboard.withUniqueName()
        var owners:[PatchWindowController]=[],sheets:[NSWindow]=[]
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(1251,forKey:"TurtleGitMerge.LegacyCodePage");preferences.set(true,forKey:"ShowAppContextMenuIcons")}
        func owner(repository:GitRepository?=nil)->PatchWindowController {
            let owner=PatchWindowController(repository:repository,access:nil,preferences:preferences,documentDirectory:root)
            owners.append(owner);owner.documentSession.askChanges={_,reply in reply(.discard)}
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.showWindow(nil);return owner
        }
        func clean()async throws {
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);try await UnifiedBlockNavigationVerification.wait {sheet.sheetParent==nil};sheet.close()}
            for owner in owners {owner.model.confirmingQuit=false;owner.model.busy=false;owner.close()}
            try await UnifiedBlockNavigationVerification.wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0}
            try UnifiedBlockNavigationVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Caret owners survived cleanup")
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
        s.owner.presentDocument(bytes,title:"Private caret document",comparison:"caret.patch",information:"Owned native verification")
        try await wait {s.model.canEditText && s.text.isEditable && s.text.string.utf16.elementsEqual(s.model.document.text.utf16) && !s.model.documentDirty && PatchDocumentSession.activeOperations==0}
        s.window.contentView?.layoutSubtreeIfNeeded();s.window.makeFirstResponder(s.text)
        try require(try s.session.encodedBytes()==bytes,"Caret load changed original byte packets")
    }
    static func select(_ s:Surface,_ location:Int,_ length:Int=0) {s.window.makeFirstResponder(s.text);s.text.setSelectedRange(.init(location:location,length:length))}
    static func bytes(_ s:Surface,_ expected:Data,_ message:String)throws {try require(try s.session.encodedBytes()==expected,message+"; selection=\(s.text.selectedRange())")}
    static func key(_ s:Surface,_ text:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    static func item(_ s:Surface,_ command:PatchCaretCommand)throws->NSMenuItem {
        try unwrap(s.text.makeCaretCommandMenu().items.first{$0.title==command.title},"Caret menu command missing: "+command.rawValue)
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    static func dispatch(_ s:Surface,_ command:PatchCaretCommand)throws {
        let entry=try item(s,command)
        try require(entry.isEnabled && entry.image != nil && entry.target != nil && entry.action != nil,"Caret command lacks enabled native target/icon")
        try require(NSApp.sendAction(entry.action!,to:entry.target,from:entry),"Caret menu dispatch refused")
    }
    static func boundary(_ s:Surface)async throws {
        s.text.breakUndoCoalescing()
        NSApp.postEvent(NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,subtype:0,data1:0x43415245,data2:0)!,atStart:false)
        try await wait {s.text.undoManager?.groupingLevel==0}
    }
    static func undoRedo(_ s:Surface,_ before:Data,_ after:Data)async throws {
        try await boundary(s);try require(s.text.undoManager?.canUndo==true,"Overtype did not create one native Undo transaction")
        s.text.undoPatch(nil);try await ready(s);try bytes(s,before,"Undo changed untouched bytes or failed to restore overtype")
        try require(s.text.undoManager?.canUndo != true,"Overtype Undo left an extra partial transaction")
        s.text.redoPatch(nil);try await ready(s);try bytes(s,after,"Redo failed exact overtype restoration")
        try require(s.text.undoManager?.canRedo != true,"Overtype Redo left an extra partial transaction")
    }
    static let commands:[PatchCaretCommand]=[.previousBlock,.nextBlock,.selectPreviousBlock,.selectNextBlock,.scrollLineUp,.scrollLineDown]
    static let body="A🙂\r\nB\r\n \t\r\nC\rD\n\nE"
    static func location(_ needle:String)->Int {(body as NSString).range(of:needle).location}
    static func invariant(_ s:Surface,_ original:Data)throws {
        try bytes(s,original,"Navigation changed encoded byte packets")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true && s.text.undoManager?.canRedo != true,"Navigation changed dirty/Undo/Redo state")
    }
    static func blocks(_ c:Context,_ s:Surface)async throws {
        let original=Data(body.utf8),third=location("C"),last=location("E"),length=(body as NSString).length
        try await load(s,original);select(s,0)
        let menu=s.text.makeCaretCommandMenu()
        try require(commands.allSatisfy{command in menu.items.contains{$0.title==command.title && $0.isEnabled && $0.image != nil && $0.target != nil}},"Native Caret menu omitted block/scroll targets or source icons")
        try require(s.text.performKeyEquivalent(with:key(s,"]",30,.control)),"Ctrl-] keyEquivalent refused")
        try require(s.text.selectedRange()==NSRange(location:third,length:0),"Next block did not skip text and ASCII-white separator")
        s.text.keyDown(with:key(s,"]",30,.control));try require(s.text.selectedRange()==NSRange(location:last,length:0),"Ctrl-] keyDown did not skip mixed CR/LF block")
        try dispatch(s,.nextBlock);try require(s.text.selectedRange()==NSRange(location:length,length:0),"Final block did not stop at document end")
        for expected in [last,third,0] {try dispatch(s,.previousBlock);try require(s.text.selectedRange()==NSRange(location:expected,length:0),"Previous block start wrong: \(expected)")}
        select(s,0)
        try require(s.text.performKeyEquivalent(with:key(s,"}",30,[.control,.shift])),"Ctrl-Shift-] shifted equivalent refused")
        try require(s.text.selectedRange()==NSRange(location:0,length:third),"Extending block lost initial anchor")
        s.text.keyDown(with:key(s,"{",33,[.control,.shift]));try require(s.text.selectedRange()==NSRange(location:0,length:0),"Reverse block extension did not collapse at original anchor")
        select(s,last);try dispatch(s,.selectPreviousBlock)
        try require(s.text.selectedRange()==NSRange(location:third,length:last-third),"Reverse block selection incorrect")
        try dispatch(s,.selectNextBlock);try require(s.text.selectedRange()==NSRange(location:last,length:0),"Forward extension lost reverse anchor")
        select(s,location("B")+1);try dispatch(s,.previousBlock);try require(s.text.selectedRange()==NSRange(location:0,length:0),"Previous block from inside line did not reach its block start")
        let column=try unwrap(s.text.columnSelection,"Missing native selection-shape owner")
        let rows:[PatchLineEditSelection]=[.init(id:10,anchor:0,caret:1),.init(id:20,anchor:third,caret:third+1)]
        let rectangular=PatchTextSelectionSnapshot(rows:rows,primarySelectionID:20,rectangular:true,rectangleAnchor:1,rectangleCaret:third+1,rectangleIsThin:false)
        try require(column.applySnapshot(rectangular),"Rectangle setup refused")
        let mainRowAnchor=column.snapshot().primary.anchor
        try dispatch(s,.selectNextBlock)
        let stream=column.snapshot()
        try require(!stream.rectangular && stream.rows.count==1 && stream.primary.anchor==mainRowAnchor && stream.primary.caret==last,"Block rectangle extension did not use main-row anchor/rectangle caret")
        try require(column.applySnapshot(rectangular),"Second rectangle setup refused")
        try dispatch(s,.previousBlock);try require(s.text.selectedRange()==NSRange(location:third,length:0) && !column.snapshot().rectangular,"Rectangle block move did not immediately compute main-caret target")
        try require(column.applySnapshot(.init(rows:rows,primarySelectionID:20,rectangular:false,rectangleIsThin:false)),"Multiple selection setup refused")
        try dispatch(s,.nextBlock);try require(column.snapshot().rows.count==1 && s.text.selectedRange()==NSRange(location:last,length:0),"Block navigation did not collapse extra selections to main target")
        try invariant(s,original)
        var keyWindow:NSWindow?=s.window
        let context=PatchMenuContext(keyWindow:{keyWindow});try await ready(s)
        try await wait{context.caretCommands.contains(.nextBlock)}
        select(s,0);context.performCaretCommand(.nextBlock);try require(s.text.selectedRange().location==third,"App Edit Caret menu did not target active block owner")
        keyWindow=nil;context.performCaretCommand(.nextBlock);try require(s.text.selectedRange().location==third,"App menu moved background caret")
        try invariant(s,original)
    }
    static func caretRect(_ s:Surface)throws->NSRect {
        let manager=try unwrap(s.text.layoutManager,"Missing layout manager"),container=try unwrap(s.text.textContainer,"Missing text container")
        manager.ensureLayout(for:container)
        let count=(s.text.string as NSString).length,position=min(s.text.selectedRange().location,max(0,count-1))
        let glyph=manager.glyphIndexForCharacter(at:position)
        return manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).offsetBy(dx:s.text.textContainerOrigin.x,dy:s.text.textContainerOrigin.y)
    }
    static func viewport(_ c:Context,_ s:Surface)async throws {
        for wrapped in [false,true] {
            let text=wrapped ? String(repeating:"word 雪🙂 ",count:1600)+"\nend":(0..<160).map{"line \($0) value"}.joined(separator:"\n")
            let original=Data(text.utf8);try await load(s,original)
            let scroll=try unwrap(s.text.enclosingScrollView,"Missing actual editor scroll")
            if wrapped {
                // This preview has no Wrap setting: install a fixed-width native
                // layout for the viewport adapter check. Tracking the existing
                // wide frame would immediately undo the chosen wrap width.
                s.text.isHorizontallyResizable=false;s.text.textContainer?.widthTracksTextView=false
                s.text.setFrameSize(NSSize(width:scroll.contentSize.width,height:scroll.contentSize.height))
                s.text.textContainer?.containerSize=NSSize(width:max(100,scroll.contentSize.width),height:CGFloat.greatestFiniteMagnitude)
            }
            s.text.layoutManager?.ensureLayout(for:s.text.textContainer!)
            // NSTextView.sizeToFit may shrink back to the clip's minimum while
            // the host has no pending AppKit layout. Use the actual production
            // document-extent reconciliation after SwiftUI's layout settles.
            do {
                try await wait {
                    s.window.contentView?.layoutSubtreeIfNeeded()
                    (scroll as? PatchScrollView)?.updateDocumentExtent()
                    return s.text.bounds.height>scroll.contentView.bounds.height*2
                }
            } catch {
                let used=s.text.layoutManager.map{$0.usedRect(for:s.text.textContainer!)}
                print("Viewport setup diagnostic: wrapped=\(wrapped) chars=\(s.text.string.utf16.count) nativeFrame=\(s.text.frame) nativeBounds=\(s.text.bounds) viewport=\(scroll.contentView.bounds) container=\(String(describing:s.text.textContainer?.containerSize)) used=\(String(describing:used)) content=\(String(describing:s.window.contentView?.bounds))")
                throw error
            }
            let middle=wrapped ? 600:(text as NSString).range(of:"line 15 value").location
            select(s,middle);s.text.scrollRangeToVisible(s.text.selectedRange())
            let r=try caretRect(s),top=max(0,r.minY-80)
            scroll.contentView.scroll(to:NSPoint(x:0,y:top));scroll.reflectScrolledClipView(scroll.contentView)
            let before=scroll.contentView.bounds.origin,selection=s.text.selectedRange()
            try require(r.minY>=s.text.visibleRect.minY && r.maxY<=s.text.visibleRect.maxY,"Visible-caret viewport setup failed")
            try require(s.text.performKeyEquivalent(with:key(s,"\u{f701}",125,.control)),"Ctrl-Down viewport equivalent refused")
            let down=scroll.contentView.bounds.origin
            try require(down.y>before.y && s.text.selectedRange()==selection,"Viewport scroll failed or moved still-visible caret")
            s.text.keyDown(with:key(s,"\u{f700}",126,.control))
            try require(abs(scroll.contentView.bounds.origin.y-before.y)<1 && s.text.selectedRange()==selection,"Ctrl-Up did not reverse one display-fragment scroll")
            select(s,0);scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)
            try dispatch(s,.scrollLineDown)
            let clamped=try caretRect(s)
            try require(scroll.contentView.bounds.origin.y>0 && s.text.selectedRange().location>0 && clamped.maxY>s.text.visibleRect.minY && clamped.minY<s.text.visibleRect.maxY,"Line scroll stranded caret above viewport instead of source clamp")
            try invariant(s,original)
        }
    }
    static func desiredColumn(_ c:Context,_ s:Surface)async throws {
        let long="abcdefghijklmnopqrst",lines=[long,"x",long,"x",long]+Array(repeating:long,count:100)
        let text=lines.joined(separator:"\n"),original=Data(text.utf8)
        try await load(s,original)
        let scroll=try unwrap(s.text.enclosingScrollView,"Missing desired-column viewport")
        s.text.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        s.text.isHorizontallyResizable=true;s.text.textContainer?.widthTracksTextView=false
        s.text.textContainer?.containerSize=NSSize(width:1_000_000,height:CGFloat.greatestFiniteMagnitude)
        s.text.layoutManager?.ensureLayout(for:s.text.textContainer!)
        s.window.contentView?.layoutSubtreeIfNeeded();(scroll as? PatchScrollView)?.updateDocumentExtent()
        select(s,12);scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)
        func through(_ start:Int)throws {
            for _ in 0..<5 {
                if s.text.selectedRange().location>=start {return}
                try dispatch(s,.scrollLineDown)
            }
            throw Failure(description:"Repeated one-line scroll failed to bring next row into view")
        }
        // Row0 column12 → short row1 clamps at its end → long row2 must
        // recover column12, rather than adopting short row1's column1.
        try through(21)
        try require(s.text.selectedRange()==NSRange(location:22,length:0),"Short-row clamp did not stop at row end")
        try through(23)
        try require(s.text.selectedRange()==NSRange(location:35,length:0),"Repeated scroll lost original desired column after short-row clamp")
        // A real native caret selection is a new user intent and resets X.
        select(s,26)
        try through(44)
        try require(s.text.selectedRange()==NSRange(location:45,length:0),"Second short-row clamp did not stop at row end")
        try through(46)
        try require(s.text.selectedRange()==NSRange(location:49,length:0),"Actual caret move did not reset persistent desired column")
        try invariant(s,original)
    }
    static func ownership(_ c:Context,_ s:Surface,_ repository:GitRepository)async throws {
        let original=Data(body.utf8);try await load(s,original);select(s,0)
        let held=try item(s,.nextBlock)
        for gate in ["busy","quit","error","sheet"] {
            var sheet:NSWindow?
            if gate=="busy" {s.model.busy=true};if gate=="quit" {s.model.confirmingQuit=true};if gate=="error" {s.model.error="Private owned error"}
            if gate=="sheet" {let value=NSWindow(contentRect:.init(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false);value.isReleasedWhenClosed=false;value.alphaValue=0;c.sheets.append(value);s.window.beginSheet(value,completionHandler:nil);sheet=value}
            try require(commands.allSatisfy{!s.text.canPerformCaretCommand($0) && !s.text.performCaretCommand($0)},"\(gate) accepted navigation/viewport command")
            _=NSApp.sendAction(held.action!,to:held.target,from:held);try require(s.text.selectedRange().location==0,"Held unavailable command moved caret")
            s.model.busy=false;s.model.confirmingQuit=false;s.model.error=nil
            if let sheet {s.window.endSheet(sheet);try await wait{sheet.sheetParent==nil};sheet.close()}
        }
        try await load(s,original);select(s,0)
        _=NSApp.sendAction(held.action!,to:held.target,from:held);try require(s.text.selectedRange().location==0,"Old same-byte-reset menu revived")
        s.text.setMarkedText("候",selectedRange:.init(location:0,length:1),replacementRange:.init(location:NSNotFound,length:0))
        try require(s.text.hasMarkedText() && commands.allSatisfy{!s.text.canPerformCaretCommand($0)},"Marked text did not fence block/viewport commands")
        s.text.unmarkText();try await load(s,original);try invariant(s,original)
        let preview=try await surface(c,c.owner(repository:repository));preview.model.readOnly=true;preview.model.reload(paths:["file.txt"],staged:false)
        try await wait{!preview.model.busy && preview.model.canFind && preview.text.string==preview.model.document.text && !preview.model.document.files.isEmpty}
        select(preview,0)
        try require(commands.allSatisfy{preview.text.canPerformCaretCommand($0)} && preview.text.performCaretCommand(.nextBlock),"Read-only preview blocked inspection navigation")
        let retired=try await surface(c,c.owner());try await load(retired,original);select(retired,0);let stale=try item(retired,.nextBlock)
        retired.owner.close();try await wait{retired.model.retired}
        _=NSApp.sendAction(stale.action!,to:stale.target,from:stale)
        try require(!retired.text.performCaretCommand(.nextBlock) && retired.text.selectedRange().location==0,"Retired menu/caret target remained active")
    }
    static func main()async {
        let first=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,second=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.blockQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(first,second);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            let repository=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Block QA"),("user.email","block@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:file);try await repository.stage(["file.txt"]);_=try await repository.commit(message:"base");try Data("base\nnew\n".utf8).write(to:file)
            let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
            let s=try await surface(c,c.owner())
            try await blocks(c,s);try await viewport(c,s);try await desiredColumn(c,s);try await ownership(c,s,repository)
            let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout
            try require(try finalHead==head && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==working,"Block/viewport navigation changed Git or working bytes")
            try await c.clean();print("PASS Unified Diff block navigation: native keys/menu/selection/viewport/ownership; exact bytes/Undo and retired windows")
        } catch {try? await c.clean();fputs("Unified Diff block navigation failed: \(error)\n",stderr);exit(1)}
    }
}
