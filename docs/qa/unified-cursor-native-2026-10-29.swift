// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func cursorQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;cursorQAOrder(mode,relativeTo:number)}
}
@MainActor @main struct UnifiedCursorVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"line \(line): \(message)")}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Cursor native state timeout at line \(line)")
    }
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let suite="TurtleGit.Cursor.QA."+UUID().uuidString
        let preferences:UserDefaults,board=NSPasteboard.withUniqueName()
        var owners:[PatchWindowController]=[],sheets:[NSWindow]=[]
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(1251,forKey:"TurtleGitMerge.LegacyCodePage");preferences.set(true,forKey:"ShowAppContextMenuIcons")}
        func owner(repository:GitRepository?=nil)->PatchWindowController {
            let owner=PatchWindowController(repository:repository,access:nil,preferences:preferences,documentDirectory:root)
            owners.append(owner);owner.documentSession.askChanges={_,reply in reply(.discard)}
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.showWindow(nil);return owner
        }
        func clean()async throws {
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);try await UnifiedCursorVerification.wait {sheet.sheetParent==nil};sheet.close()}
            for owner in owners {owner.model.confirmingQuit=false;owner.model.busy=false;owner.close()}
            try await UnifiedCursorVerification.wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0}
            try UnifiedCursorVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Cursor owners survived cleanup")
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
        s.owner.presentDocument(bytes,title:"Private cursor document",comparison:"cursor.patch",information:"Owned native verification")
        try await wait {s.model.canEditText && s.text.isEditable && s.text.string.utf16.elementsEqual(s.model.document.text.utf16) && !s.model.documentDirty && PatchDocumentSession.activeOperations==0}
        s.window.contentView?.layoutSubtreeIfNeeded();s.window.makeFirstResponder(s.text)
        try require(try s.session.encodedBytes()==bytes,"Cursor load changed original byte packets")
    }
    static func bytes(_ s:Surface,_ expected:Data,_ message:String)throws {try require(try s.session.encodedBytes()==expected,message+"; selection=\(s.text.selectedRange())")}
    static func key(_ s:Surface,_ text:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    static func item(_ s:Surface,_ command:PatchCursorCommand)throws->NSMenuItem {
        try unwrap(s.text.makeCursorCommandMenu().items.first{$0.title==command.title},"Cursor menu command missing: "+command.rawValue)
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    static func dispatch(_ s:Surface,_ command:PatchCursorCommand)throws {
        let entry=try item(s,command)
        try require(entry.isEnabled && entry.image != nil && entry.target != nil && entry.action != nil,"Cursor command lacks enabled native target/icon")
        try require(NSApp.sendAction(entry.action!,to:entry.target,from:entry),"Cursor menu dispatch refused")
    }
    static let body=Array(repeating:"\talpha beta\n\tgamma delta\n",count:80).joined()
    static let commands:[PatchCursorCommand]=[.previousCharacter,.nextCharacter,.selectPreviousCharacter,.selectNextCharacter,.previousLine,.nextLine,.selectPreviousLine,.selectNextLine]
    static func select(_ s:Surface,_ location:Int,_ length:Int=0) {s.window.makeFirstResponder(s.text);s.text.setSelectedRange(.init(location:location,length:length))}
    static func unchanged(_ s:Surface,_ original:Data)throws {
        try bytes(s,original,"Cursor navigation changed source bytes")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true && s.text.undoManager?.canRedo != true,"Cursor navigation changed dirty/Undo state")
    }
    static func ordinary(_ c:Context,_ s:Surface)async throws {
        let original=Data("A🙂e\u{301}\r\n雪Z".utf8);try await load(s,original);select(s,0)
        let menu=s.text.makeCursorCommandMenu()
        try require(menu.items.map(\.title)==commands.map(\.title) && menu.items.allSatisfy{$0.image != nil && $0.isEnabled && $0.target != nil && $0.action != nil},"Cursor menu lost eight native command targets/order/icons")
        try require(s.text.performKeyEquivalent(with:key(s,"\u{f703}",124,[])),"Right arrow key equivalent refused")
        try require(s.text.selectedRange()==NSRange(location:1,length:0),"Right arrow failed first literal character")
        for point in [3,5,7,8,9] {s.text.keyDown(with:key(s,"\u{f703}",124,[]));try require(s.text.selectedRange()==NSRange(location:point,length:0),"Right arrow split grapheme/CRLF or skipped character: \(point)")}
        for point in [8,7,5,3,1,0] {try dispatch(s,.previousCharacter);try require(s.text.selectedRange()==NSRange(location:point,length:0),"Left arrow split grapheme/CRLF: \(point)")}
        try dispatch(s,.previousCharacter);try require(s.text.selectedRange().location==0,"Left arrow crossed document start")
        select(s,1);try require(s.text.performKeyEquivalent(with:key(s,"\u{f703}",124,.shift)),"Shift-Right refused")
        try require(s.text.selectedRange()==NSRange(location:1,length:2),"Shift-Right split surrogate or lost anchor")
        s.text.keyDown(with:key(s,"\u{f702}",123,.shift));try require(s.text.selectedRange()==NSRange(location:1,length:0),"Reverse extension failed anchor collapse")
        select(s,1,4);s.text.moveRight(nil);try require(s.text.selectedRange()==NSRange(location:5,length:0),"Responder Right moved beyond selected limit")
        select(s,1,4);s.text.moveBackward(nil);try require(s.text.selectedRange()==NSRange(location:1,length:0),"Responder Backward failed selected-limit collapse")
        s.text.moveForward(nil);try require(s.text.selectedRange().location==3,"Responder Forward alias split emoji")
        try unchanged(s,original)
        let lines=Data("abcd\nefgh".utf8);try await load(s,lines);select(s,2)
        try require(s.text.performKeyEquivalent(with:key(s,"\u{f701}",125,.shift)),"Shift-Down key equivalent refused")
        try require(s.text.selectedRange()==NSRange(location:2,length:5),"Shift-Down lost stream anchor/column")
        s.text.keyDown(with:key(s,"\u{f700}",126,.shift));try require(s.text.selectedRange()==NSRange(location:2,length:0),"Shift-Up did not reverse to anchor")
        s.text.keyDown(with:key(s,"\u{f702}",123,[]));try require(s.text.selectedRange().location==1,"Left keyDown did not use cursor route")
        try unchanged(s,lines)
        for packet in [Data([0xff,0xfe])+Data("e\u{301}🙂\r\n".utf16.flatMap{[UInt8($0 & 255),UInt8($0 >> 8)]}),Data([0x61,0xff,0x0a,0x62])] {
            try await load(s,packet);select(s,0);try dispatch(s,.nextCharacter);try dispatch(s,.previousCharacter);try unchanged(s,packet)
        }
        try await load(s,Data());select(s,0)
        for command in commands {try require(s.text.performCursorCommand(command) && s.text.selectedRange()==NSRange(location:0,length:0),"Empty cursor command changed selection")}
        try unchanged(s,Data())
    }
    static func selectionShapes(_ c:Context,_ s:Surface)async throws {
        let original=Data("abcd\nefgh\nijkl".utf8);try await load(s,original)
        let column=try unwrap(s.text.columnSelection,"Missing cursor selection controller")
        func set(_ rectangular:Bool=true)throws {
            try require(column.applySnapshot(.init(rows:[.init(id:2,anchor:1,caret:3),.init(id:7,anchor:6,caret:8)],primarySelectionID:7,rectangular:rectangular,rectangleAnchor:1,rectangleCaret:8,rectangleRowsExplicit:rectangular)),"Cursor multirow setup refused")
        }
        for (command,expected) in [(PatchCursorCommand.previousCharacter,1),(.selectPreviousCharacter,1),(.nextCharacter,8),(.selectNextCharacter,8)] {
            try set();try dispatch(s,command)
            try require(!column.snapshot().rectangular && column.snapshot().rows.count==1 && s.text.selectedRange()==NSRange(location:expected,length:0),"Rectangle horizontal command did more than directional outer-limit collapse")
        }
        try set(false);try dispatch(s,.nextCharacter)
        try require(column.snapshot().rows.count==1 && s.text.selectedRange()==NSRange(location:8,length:0),"Stream multiple-selection did not collapse main selected limit")
        try set(false);try dispatch(s,.selectPreviousCharacter)
        try require(column.snapshot().rows.count==1 && column.snapshot().primary.anchor==6 && column.snapshot().primary.caret==7,"Stream Shift character lost primary anchor")
        try set();try dispatch(s,.previousLine)
        try require(!column.snapshot().rectangular && column.snapshot().rows.count==1 && s.text.selectedRange()==NSRange(location:3,length:0),"Rectangle Up did not use main caret's column/stream conversion")
        try set();try dispatch(s,.selectNextLine)
        try require(!column.snapshot().rectangular && column.snapshot().rows.count==1 && column.snapshot().primary.anchor==6 && column.snapshot().primary.caret==13,"Rectangle Shift-Down lost main-row anchor")
        try require(column.applySnapshot(.init(rows:[.init(id:4,anchor:8,caret:6)],primarySelectionID:4,rectangular:false)),"Reverse selection setup refused")
        s.text.moveLeftAndModifySelection(nil)
        try require(column.snapshot().primary.anchor==8 && column.snapshot().primary.caret==5,"Reverse Shift-Left responder lost anchor")
        try unchanged(s,original)
    }
    static func layout(_ s:Surface,wrapped:Bool)async throws->NSScrollView {
        let scroll=try unwrap(s.text.enclosingScrollView,"Missing cursor viewport")
        s.text.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        s.text.isHorizontallyResizable = !wrapped;s.text.textContainer?.widthTracksTextView=false
        let width=wrapped ? max(100,scroll.contentSize.width):1_000_000
        if wrapped {s.text.setFrameSize(NSSize(width:width,height:s.text.frame.height))}
        s.text.textContainer?.containerSize=NSSize(width:width,height:CGFloat.greatestFiniteMagnitude)
        try await wait{s.window.contentView?.layoutSubtreeIfNeeded();(scroll as? PatchScrollView)?.updateDocumentExtent();return s.text.bounds.height>scroll.contentView.bounds.height*2}
        return scroll
    }
    static func vertical(_ c:Context,_ s:Surface)async throws {
        let rows=(0..<180).map{$0==5 ? "x":String(format:"row%03d value",$0)},text=rows.joined(separator:"\n"),original=Data(text.utf8)
        try await load(s,original);let scroll=try await layout(s,wrapped:false)
        func offset(_ row:Int,_ col:Int)->Int {rows.prefix(row).reduce(0){$0+$1.utf16.count+1}+col}
        select(s,offset(4,12));s.text.scrollRangeToVisible(s.text.selectedRange())
        s.text.keyDown(with:key(s,"\u{f701}",125,[]));try require(s.text.selectedRange().location==offset(5,1),"Down did not clamp short line")
        s.text.moveDown(nil);try require(s.text.selectedRange().location==offset(6,12),"Repeated Down lost desired X across short row")
        s.text.moveUp(nil);try require(s.text.selectedRange().location==offset(5,1),"Up did not revisit short row")
        s.text.keyDown(with:key(s,"\u{f700}",126,[]));try require(s.text.selectedRange().location==offset(4,12),"Reverse vertical movement lost desired X")
        let manager=s.text.layoutManager!,height=manager.lineFragmentRect(forGlyphAt:0,effectiveRange:nil).height,step=max(1,Int(floor(scroll.contentView.bounds.height/height))-1)
        s.text.moveDown(nil);try require(s.text.performNavigationCommand(.pageDown),"Cross-family Page Down refused")
        try require(s.text.selectedRange().location==offset(5+step,12),"Arrow-to-Page did not share original desired column")
        scroll.contentView.scroll(to:NSPoint(x:0,y:CGFloat(5+step-10)*height));scroll.reflectScrolledClipView(scroll.contentView)
        try require(s.text.performCaretCommand(.scrollLineUp),"Cross-family line scroll refused")
        try require(s.text.selectedRange().location==offset(5+step,12),"Line scroll changed still-visible primary caret")
        s.text.moveDown(nil);try require(s.text.selectedRange().location==offset(6+step,12),"Arrow after line scroll lost shared desired column")
        // Explicit user caret movement must replace the old desired column.
        select(s,offset(4,2));s.text.moveDown(nil);s.text.moveDown(nil)
        try require(s.text.selectedRange().location==offset(6,2),"Actual caret movement failed to reset desired X")
        select(s,2);try dispatch(s,.previousLine);try require(s.text.selectedRange().location==0,"Up on first display line did not reach BOF")
        select(s,(text as NSString).length-2);try dispatch(s,.nextLine);try require(s.text.selectedRange().location==(text as NSString).length,"Down on last display line did not reach EOF")
        try unchanged(s,original)
        let wrapped=Data((String(repeating:"abcdefghij",count:2500)+"\nend").utf8);try await load(s,wrapped)
        let wrapScroll=try await layout(s,wrapped:true),lm=s.text.layoutManager!,container=s.text.textContainer!
        let h=lm.lineFragmentRect(forGlyphAt:0,effectiveRange:nil).height
        let firstGlyph=lm.glyphIndex(for:NSPoint(x:0,y:4*h+1),in:container),nextGlyph=lm.glyphIndex(for:NSPoint(x:0,y:5*h+1),in:container)
        let start=lm.characterIndexForGlyph(at:firstGlyph)+2,target=lm.characterIndexForGlyph(at:nextGlyph)+2
        select(s,start);wrapScroll.contentView.scroll(to:.zero);wrapScroll.reflectScrolledClipView(wrapScroll.contentView)
        try dispatch(s,.nextLine);try require(s.text.selectedRange().location==target,"Down skipped wrapped display fragment")
        try dispatch(s,.selectPreviousLine);let snap=try unwrap(s.text.columnSelection,"Missing wrapped selection").snapshot()
        try require(snap.primary.anchor==target && snap.primary.caret==start,"Shift-Up on wrapped fragment lost literal anchor")
        try unchanged(s,wrapped)
    }
    static func ownership(_ c:Context,_ s:Surface,_ repository:GitRepository)async throws {
        let original=Data("alpha\nbeta\n".utf8);try await load(s,original);select(s,0);let held=try item(s,.nextCharacter)
        for gate in ["busy","quit","error","sheet"] {
            var sheet:NSWindow?
            if gate=="busy" {s.model.busy=true};if gate=="quit" {s.model.confirmingQuit=true};if gate=="error" {s.model.error="Private owned error"}
            if gate=="sheet" {let value=NSWindow(contentRect:.init(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false);value.isReleasedWhenClosed=false;value.alphaValue=0;c.sheets.append(value);s.window.beginSheet(value,completionHandler:nil);sheet=value}
            try require(commands.allSatisfy{!s.text.canPerformCursorCommand($0) && !s.text.performCursorCommand($0)},"\(gate) admitted cursor command")
            _=NSApp.sendAction(held.action!,to:held.target,from:held);try require(s.text.selectedRange().location==0,"Held unavailable cursor menu acted")
            s.model.busy=false;s.model.confirmingQuit=false;s.model.error=nil
            if let sheet {s.window.endSheet(sheet);try await wait{sheet.sheetParent==nil};sheet.close()}
        }
        try await load(s,original);_=NSApp.sendAction(held.action!,to:held.target,from:held);try require(s.text.selectedRange().location==0,"Same-byte replacement revived cursor menu")
        let oldSelection=try item(s,.nextCharacter);select(s,2)
        _=NSApp.sendAction(oldSelection.action!,to:oldSelection.target,from:oldSelection);try require(s.text.selectedRange().location==2,"Selection-stale cursor menu acted")
        try await load(s,original)
        s.text.setMarkedText("候",selectedRange:.init(location:0,length:1),replacementRange:.init(location:NSNotFound,length:0))
        try require(s.text.hasMarkedText() && commands.allSatisfy{!s.text.canPerformCursorCommand($0)},"IME composition admitted cursor commands")
        s.text.unmarkText();try await load(s,original)
        var keyWindow:NSWindow?=s.window;let menu=PatchMenuContext(keyWindow:{keyWindow});try await ready(s)
        try await wait{menu.cursorCommands.contains(.nextCharacter)}
        menu.performCursorCommand(.nextCharacter);try require(s.text.selectedRange().location==1,"App Edit cursor menu failed active owner")
        keyWindow=nil;menu.performCursorCommand(.nextCharacter);try require(s.text.selectedRange().location==1,"Cursor menu targeted background owner")
        let preview=try await surface(c,c.owner(repository:repository));preview.model.readOnly=true;preview.model.reload(paths:["file.txt"],staged:false)
        try await wait{!preview.model.busy && preview.model.canFind && preview.text.string==preview.model.document.text && !preview.model.document.files.isEmpty}
        select(preview,0);try require(commands.allSatisfy{preview.text.canPerformCursorCommand($0)} && preview.text.performCursorCommand(.nextCharacter) && preview.text.selectedRange().location==1,"Readonly Git preview refused cursor navigation")
        let retired=try await surface(c,c.owner());try await load(retired,original);select(retired,0);let stale=try item(retired,.nextCharacter)
        retired.owner.close();try await wait{retired.model.retired}
        _=NSApp.sendAction(stale.action!,to:stale.target,from:stale);try require(!retired.text.performCursorCommand(.nextCharacter) && retired.text.selectedRange().location==0,"Retired cursor owner revived")
    }

    static func main()async {
        let first=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,second=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.cursorQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(first,second);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            let repository=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Cursor QA"),("user.email","cursor@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:file);try await repository.stage(["file.txt"]);_=try await repository.commit(message:"base");try Data("base\nnew\n".utf8).write(to:file)
            let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
            let s=try await surface(c,c.owner());try await ordinary(c,s);try await selectionShapes(c,s);try await vertical(c,s);try await ownership(c,s,repository)
            let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout
            try require(try finalHead==head && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==working,"Cursor changed HEAD/index/worktree")
            try await c.clean();print("PASS Unified Diff cursor: native arrows/Shift-arrows, glyph/rectangle/desired-X/ownership, exact bytes/Undo and closed windows")
        } catch {try? await c.clean();fputs("Unified Diff cursor failed: \(error)\n",stderr);exit(1)}
    }
}
