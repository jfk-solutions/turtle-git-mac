// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func navigationQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;navigationQAOrder(mode,relativeTo:number)}
}
@MainActor @main struct UnifiedNavigationVerification {
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
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);try await UnifiedNavigationVerification.wait {sheet.sheetParent==nil};sheet.close()}
            for owner in owners {owner.model.confirmingQuit=false;owner.model.busy=false;owner.close()}
            try await UnifiedNavigationVerification.wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0}
            try UnifiedNavigationVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Caret owners survived cleanup")
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
    static func leaves(_ menu:NSMenu)->[NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu=item.submenu {return leaves(submenu)}
            return item.isSeparatorItem ? []:[item]
        }
    }
    static func item(_ s:Surface,_ command:PatchNavigationCommand)throws->NSMenuItem {
        try unwrap(leaves(s.text.makeNavigationCommandMenu()).first{$0.title==command.title},"Navigation menu command missing: "+command.rawValue)
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    static func dispatch(_ s:Surface,_ command:PatchNavigationCommand)throws {
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
    static let commands:[PatchNavigationCommand]=[.previousWord,.nextWord,.selectPreviousWord,.selectNextWord,.smartLineStart,.lineEnd,.selectSmartLineStart,.selectLineEnd,.documentStart,.documentEnd,.selectDocumentStart,.selectDocumentEnd,.displayStart,.displayEnd,.pageUp,.pageDown,.selectPageUp,.selectPageDown]
    static func unchanged(_ s:Surface,_ original:Data)throws {
        try bytes(s,original,"Navigation changed source bytes")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true && s.text.undoManager?.canRedo != true,"Navigation changed Undo/Redo or dirty state")
    }
    static func ordinary(_ c:Context,_ s:Surface)async throws {
        let value="alpha  beta+gamma_delta\r\n雪🙂",original=Data(value.utf8)
        try await load(s,original);select(s,0)
        let menu=s.text.makeNavigationCommandMenu()
        try require(menu.items.map(\.title)==["Words","Lines and Document","Pages"] && menu.items.allSatisfy{$0.submenu != nil && $0.image != nil},"Navigation menu lost compact group order/icons")
        try require(leaves(menu).map(\.title)==commands.map(\.title),"Navigation menu lost source command order")
        try require(leaves(menu).allSatisfy{$0.image != nil && $0.isEnabled && $0.target != nil && $0.action != nil},"Navigation menu lacks source artwork/targets")
        try require(s.text.performKeyEquivalent(with:key(s,"\u{f703}",124,.option)),"Option-Right native equivalent refused")
        try require(s.text.selectedRange()==NSRange(location:7,length:0),"Next-word boundary failed whitespace skip")
        s.text.keyDown(with:key(s,"\u{f703}",124,.option));try require(s.text.selectedRange()==NSRange(location:11,length:0),"Native word-right keyDown crossed punctuation class")
        // Newline is a separate source class, not trailing ASCII space.
        let newline=(value as NSString).range(of:"\r\n").location,nextLine=(value as NSString).range(of:"雪").location
        for point in [12,newline,nextLine] {try dispatch(s,.nextWord);try require(s.text.selectedRange()==NSRange(location:point,length:0),"Next-word class/CRLF boundary wrong: expected \(point), actual \(s.text.selectedRange())")}
        select(s,7)
        try require(s.text.performKeyEquivalent(with:key(s,"\u{f703}",124,[.option,.shift])),"Shift-Option-Right equivalent refused")
        try require(s.text.selectedRange()==NSRange(location:7,length:4),"Word extension lost anchor")
        s.text.keyDown(with:key(s,"\u{f702}",123,[.option,.shift]));try require(s.text.selectedRange()==NSRange(location:7,length:0),"Reverse word extension did not return to anchor")
        try unchanged(s,original)
        let indented=Data(" \talpha beta\r\ntail".utf8)
        try await load(s,indented);select(s,6)
        try require(s.text.performKeyEquivalent(with:key(s,"\u{f702}",123,.command)),"Command-Left smart line start refused")
        try require(s.text.selectedRange()==NSRange(location:2,length:0),"Smart Home did not reach first nonwhite")
        s.text.keyDown(with:key(s,"\u{f729}",115,[]));try require(s.text.selectedRange().location==0,"Physical Home alias did not toggle smart start")
        try dispatch(s,.smartLineStart);try require(s.text.selectedRange().location==2,"Repeated smart Home did not toggle indentation")
        s.text.keyDown(with:key(s,"\u{f72b}",119,[]));try require(s.text.selectedRange().location==12,"Physical End included CRLF")
        select(s,6);try dispatch(s,.selectSmartLineStart);try require(s.text.selectedRange()==NSRange(location:2,length:4),"Smart Home extension lost reverse anchor")
        try dispatch(s,.selectLineEnd);try require(s.text.selectedRange()==NSRange(location:6,length:6),"Line End extension lost original anchor")
        select(s,0);try require(s.text.performKeyEquivalent(with:key(s,"\u{f701}",125,.command)),"Command-Down document End refused")
        let end=(s.text.string as NSString).length
        try require(s.text.selectedRange().location==end,"Document End did not reach actual UTF16 end")
        s.text.keyDown(with:key(s,"\u{f729}",115,.control));try require(s.text.selectedRange().location==0,"Source Control-Home alias refused")
        try require(s.text.performKeyEquivalent(with:key(s,"\u{f701}",125,[.command,.shift])),"Document extension equivalent refused")
        try require(s.text.selectedRange()==NSRange(location:0,length:end),"Document End extension failed")
        s.text.keyDown(with:key(s,"\u{f700}",126,[.command,.shift]));try require(s.text.selectedRange()==NSRange(location:0,length:0),"Reverse document extension lost anchor")
        try unchanged(s,indented)
        let text=Data("one two\nthree four\n".utf8);try await load(s,text)
        let column=try unwrap(s.text.columnSelection,"Missing native selection controller")
        let rows:[PatchLineEditSelection]=[.init(id:1,anchor:0,caret:3),.init(id:2,anchor:8,caret:11)]
        func rectangle()->PatchTextSelectionSnapshot {.init(rows:rows,primarySelectionID:2,rectangular:true,rectangleAnchor:0,rectangleCaret:11,rectangleIsThin:false)}
        try require(column.applySnapshot(rectangle()),"Rectangle word movement setup refused")
        try dispatch(s,.nextWord);try require(!column.snapshot().rectangular && s.text.selectedRange()==NSRange(location:11,length:0),"Rectangle horizontal move did not first collapse at directional outer limit")
        try dispatch(s,.nextWord);try require(s.text.selectedRange().location==14,"Collapsed stream did not resume ordinary word navigation")
        try require(column.applySnapshot(rectangle()),"Rectangle line End setup refused")
        try dispatch(s,.lineEnd);try require(s.text.selectedRange()==NSRange(location:18,length:0),"Rectangle End failed outer-limit line-end adjustment")
        try require(column.applySnapshot(rectangle()),"Rectangle document extension setup refused")
        let rowAnchor=column.snapshot().primary.anchor
        try dispatch(s,.selectDocumentEnd);try require(!column.snapshot().rectangular && column.snapshot().rows.count==1 && column.snapshot().primary.anchor==rowAnchor && column.snapshot().primary.caret==19,"Document extension failed main-row anchor/stream conversion")
        try require(column.applySnapshot(.init(rows:rows,primarySelectionID:2,rectangular:false)),"Multiselection setup refused")
        try dispatch(s,.previousWord);try require(column.snapshot().rows.count==1 && s.text.selectedRange().location==8,"Word navigation failed main-caret collapse")
        try unchanged(s,text)
    }
    static func layout(_ s:Surface,wrapped:Bool)async throws->NSScrollView {
        let scroll=try unwrap(s.text.enclosingScrollView,"Missing navigation viewport")
        s.text.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        s.text.isHorizontallyResizable = !wrapped;s.text.textContainer?.widthTracksTextView=false
        let width=wrapped ? max(100,scroll.contentSize.width):1_000_000
        if wrapped {s.text.setFrameSize(NSSize(width:width,height:s.text.frame.height))}
        s.text.textContainer?.containerSize=NSSize(width:width,height:CGFloat.greatestFiniteMagnitude)
        try await wait {
            s.window.contentView?.layoutSubtreeIfNeeded();(scroll as? PatchScrollView)?.updateDocumentExtent()
            return s.text.bounds.height>scroll.contentView.bounds.height*2
        }
        return scroll
    }
    static func pages(_ c:Context,_ s:Surface)async throws {
        for wrapped in [false,true] {
            let text=wrapped ? String(repeating:"abcdefghij",count:2500)+"\nend":(0..<180).map{String(format:"row%03d value",$0)}.joined(separator:"\n")
            let original=Data(text.utf8);try await load(s,original)
            let scroll=try await layout(s,wrapped:wrapped),manager=s.text.layoutManager!,container=s.text.textContainer!
            let first=manager.lineFragmentRect(forGlyphAt:0,effectiveRange:nil),height=first.height
            try require(height>0,"Native display fragment has no height")
            let visible=max(1,Int(floor(scroll.contentView.bounds.height/height))),step=max(1,visible-1)
            // Start at an interior display fragment with a real visible caret.
            let startLine=4
            let startGlyph=manager.glyphIndex(for:NSPoint(x:0,y:CGFloat(startLine)*height+1),in:container)
            let start=manager.characterIndexForGlyph(at:startGlyph)+2
            select(s,start);scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)
            let before=scroll.contentView.bounds.origin,anchor=s.text.selectedRange().location
            try require(s.text.performKeyEquivalent(with:key(s,"\u{f72d}",121,[])),"Page Down equivalent refused")
            let down=s.text.selectedRange(),after=scroll.contentView.bounds.origin
            try require(after.y>before.y && down.location>anchor && abs((after.y-before.y)-CGFloat(step)*height)<1.5,"Page Down failed equal caret+viewport display-line step")
            let expectedGlyph=manager.glyphIndex(for:NSPoint(x:0,y:CGFloat(startLine+step)*height+1),in:container)
            let expected=manager.characterIndexForGlyph(at:expectedGlyph)+2
            try require(down==NSRange(location:expected,length:0),"Page Down failed visible-lines-minus-one source step")
            s.text.keyDown(with:key(s,"\u{f72c}",116,[]));try require(s.text.selectedRange()==NSRange(location:anchor,length:0) && abs(scroll.contentView.bounds.origin.y-before.y)<1,"Page Up failed reverse caret+viewport step")
            try require(s.text.performKeyEquivalent(with:key(s,"\u{f72d}",121,.shift)),"Shift Page Down equivalent refused")
            try require(s.text.selectedRange()==NSRange(location:anchor,length:expected-anchor),"Page extension lost primary anchor")
            s.text.keyDown(with:key(s,"\u{f72c}",116,.shift));try require(s.text.selectedRange()==NSRange(location:anchor,length:0),"Reverse Page extension lost anchor")
            if !wrapped {
                select(s,anchor)
                scroll.contentView.scroll(to:NSPoint(x:0,y:20*height));scroll.reflectScrolledClipView(scroll.contentView)
                let oldGlyph=manager.glyphIndexForCharacter(at:anchor)
                let oldRect=manager.lineFragmentRect(forGlyphAt:oldGlyph,effectiveRange:nil).offsetBy(dx:s.text.textContainerOrigin.x,dy:s.text.textContainerOrigin.y)
                try require(oldRect.maxY<scroll.contentView.bounds.minY,"Manual-scroll setup did not hide old caret")
                s.text.keyDown(with:key(s,"\u{f72d}",121,[]))
                try require(s.text.selectedRange()==NSRange(location:expected,length:0),"Page Down after manual scrolling lost old caret's authored target/column")
                let targetGlyph=manager.glyphIndexForCharacter(at:expected)
                let targetRect=manager.lineFragmentRect(forGlyphAt:targetGlyph,effectiveRange:nil).offsetBy(dx:s.text.textContainerOrigin.x,dy:s.text.textContainerOrigin.y)
                try require(targetRect.minY>=s.text.visibleRect.minY && targetRect.maxY<=s.text.visibleRect.maxY,"Page Down left target outside manually shifted viewport")
            }
            let column=try unwrap(s.text.columnSelection,"Missing page selection controller")
            try require(column.applySnapshot(.init(rows:[.init(id:1,anchor:0,caret:2),.init(id:2,anchor:anchor-2,caret:anchor)],primarySelectionID:2,rectangular:true,rectangleAnchor:0,rectangleCaret:anchor,rectangleIsThin:false)),"Page rectangle setup refused")
            let mainAnchor=column.snapshot().primary.anchor
            // Source SetRectangularRange iterates logical document lines;
            // EditView::SPositionFromLineX selects subline0 of each. A rectangle
            // inside this single wrapped logical line therefore normalizes to
            // its FIRST display fragment before PageMove starts from MainCaret.
            if wrapped {try require(column.snapshot().rows.count==1 && column.snapshot().primary.caret==2,"Wrapped logical-row rectangle did not normalize to source first-subline caret")}
            let rectangleTargetGlyph=manager.glyphIndex(for:NSPoint(x:0,y:CGFloat(step)*height+1),in:container)
            let rectangleExpected=wrapped ? manager.characterIndexForGlyph(at:rectangleTargetGlyph)+2:expected
            scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)
            try dispatch(s,.selectPageDown)
            try require(!column.snapshot().rectangular && column.snapshot().rows.count==1 && column.snapshot().primary.anchor==mainAnchor && column.snapshot().primary.caret==rectangleExpected,"Page extension failed main-row anchor/stream conversion: wrapped=\(wrapped), mainAnchor=\(mainAnchor), expectedCaret=\(rectangleExpected), actual=\(column.snapshot()), desiredX=\(String(describing:s.text.viewportDesiredX)), view=\(scroll.contentView.bounds)")
            try dispatch(s,.documentEnd);try dispatch(s,.pageDown)
            try require(s.text.selectedRange().location==(s.text.string as NSString).length,"Page Down did not clamp at document end")
            try dispatch(s,.documentStart);try dispatch(s,.pageUp)
            try require(s.text.selectedRange().location==0,"Page Up did not clamp at document start")
            if wrapped {
                select(s,start)
                try require(s.text.performKeyEquivalent(with:key(s,"\u{f729}",115,.option)),"Option-Home display start refused")
                let beginning=manager.characterIndexForGlyph(at:startGlyph)
                try require(s.text.selectedRange().location==beginning,"Display start used document-line start")
                s.text.keyDown(with:key(s,"\u{f72b}",119,.option))
                var range=NSRange();_=manager.lineFragmentRect(forGlyphAt:startGlyph,effectiveRange:&range)
                let end=NSMaxRange(manager.characterRange(forGlyphRange:range,actualGlyphRange:nil))
                try require(s.text.selectedRange().location==end,"Display End did not use current wrapped fragment")
            }
            if !wrapped {
                // Each authored row is exactly12 ASCII columns plus one LF.
                // EOF must seed the insertion column12, never the last glyph's
                // start column11, for the shared scroll→page desired-X state.
                try dispatch(s,.documentEnd)
                s.text.scrollRangeToVisible(s.text.selectedRange())
                try await ready(s)
                try require(s.text.selectedRange().location==180*13-1,"EOF setup did not reach last row end")
                let eofGeometry=s.text.navigationCaretRect(at:s.text.selectedRange().location),eofViewport=scroll.contentView.bounds
                try require(s.text.performKeyEquivalent(with:key(s,"\u{f700}",126,.control)),"Shared Ctrl-Up line-scroll route refused at EOF")
                try require(s.text.selectedRange()==NSRange(location:178*13+12,length:0),"EOF line-scroll clamp lost actual insertion end column: actual=\(s.text.selectedRange()), desiredX=\(String(describing:s.text.viewportDesiredX)), before=\(String(describing:eofGeometry)), viewportBefore=\(eofViewport), after=\(scroll.contentView.bounds), current=\(String(describing:s.text.navigationCaretRect(at:s.text.selectedRange().location)))")
                s.text.keyDown(with:key(s,"\u{f72c}",116,[]))
                let expectedEOFPage=max(0,178-step)*13+12
                try require(s.text.selectedRange()==NSRange(location:expectedEOFPage,length:0),"Page Up after EOF line-scroll lost shared desired column12")
            }
            try unchanged(s,original)
        }
    }
    static func ownership(_ c:Context,_ s:Surface,_ repository:GitRepository)async throws {
        let original=Data("alpha beta\nnext line\n".utf8);try await load(s,original);select(s,0)
        let held=try item(s,.nextWord)
        for gate in ["busy","quit","error","sheet"] {
            var sheet:NSWindow?
            if gate=="busy" {s.model.busy=true};if gate=="quit" {s.model.confirmingQuit=true};if gate=="error" {s.model.error="Private owned error"}
            if gate=="sheet" {let value=NSWindow(contentRect:.init(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false);value.isReleasedWhenClosed=false;value.alphaValue=0;c.sheets.append(value);s.window.beginSheet(value,completionHandler:nil);sheet=value}
            try require(commands.allSatisfy{!s.text.canPerformNavigationCommand($0) && !s.text.performNavigationCommand($0)},"\(gate) accepted navigation command")
            _=NSApp.sendAction(held.action!,to:held.target,from:held);try require(s.text.selectedRange().location==0,"Held unavailable navigation moved caret")
            s.model.busy=false;s.model.confirmingQuit=false;s.model.error=nil
            if let sheet {s.window.endSheet(sheet);try await wait{sheet.sheetParent==nil};sheet.close()}
        }
        try await load(s,original);select(s,0)
        _=NSApp.sendAction(held.action!,to:held.target,from:held);try require(s.text.selectedRange().location==0,"Old reset navigation receipt revived")
        s.text.setMarkedText("候",selectedRange:.init(location:0,length:1),replacementRange:.init(location:NSNotFound,length:0))
        try require(s.text.hasMarkedText() && commands.allSatisfy{!s.text.canPerformNavigationCommand($0)},"IME composition did not fence navigation")
        s.text.unmarkText();try await load(s,original);try unchanged(s,original)
        var keyWindow:NSWindow?=s.window
        let menu=PatchMenuContext(keyWindow:{keyWindow});try await ready(s)
        try await wait{menu.navigationCommands.contains(.nextWord)}
        menu.performNavigationCommand(.nextWord);try require(s.text.selectedRange().location==6,"App Edit navigation menu failed active owner")
        keyWindow=nil;menu.performNavigationCommand(.nextWord);try require(s.text.selectedRange().location==6,"App navigation targeted background owner")
        let preview=try await surface(c,c.owner(repository:repository));preview.model.readOnly=true;preview.model.reload(paths:["file.txt"],staged:false)
        try await wait{!preview.model.busy && preview.model.canFind && preview.text.string==preview.model.document.text && !preview.model.document.files.isEmpty}
        select(preview,0);try require(commands.allSatisfy{preview.text.canPerformNavigationCommand($0)} && preview.text.performNavigationCommand(.documentEnd),"Readonly Git preview blocked inspection navigation")
        let retired=try await surface(c,c.owner());try await load(retired,original);select(retired,0);let stale=try item(retired,.nextWord)
        retired.owner.close();try await wait{retired.model.retired}
        _=NSApp.sendAction(stale.action!,to:stale.target,from:stale);try require(!retired.text.performNavigationCommand(.nextWord) && retired.text.selectedRange().location==0,"Retired navigation target revived")
    }
    static func main()async {
        let first=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,second=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.navigationQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(first,second);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            let repository=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Navigation QA"),("user.email","navigation@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:file);try await repository.stage(["file.txt"]);_=try await repository.commit(message:"base");try Data("base\nnew\n".utf8).write(to:file)
            let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
            let s=try await surface(c,c.owner());try await ordinary(c,s);try await pages(c,s);try await ownership(c,s,repository)
            let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout
            try require(try finalHead==head && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==working,"Navigation changed HEAD/index/worktree")
            try await c.clean();print("PASS Unified Diff complete navigation: native word/Home/End/document/display/page keys, selection/viewport/ownership, exact bytes/Undo and closed windows")
        } catch {try? await c.clean();fputs("Unified Diff navigation failed: \(error)\n",stderr);exit(1)}
    }
}
