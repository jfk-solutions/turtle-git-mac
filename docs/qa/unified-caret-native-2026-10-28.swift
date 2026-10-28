// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func caretQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;caretQAOrder(mode,relativeTo:number)}
}
@MainActor @main struct UnifiedCaretVerification {
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
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);try await UnifiedCaretVerification.wait {sheet.sheetParent==nil};sheet.close()}
            for owner in owners {owner.model.confirmingQuit=false;owner.model.busy=false;owner.close()}
            try await UnifiedCaretVerification.wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0}
            try UnifiedCaretVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Caret owners survived cleanup")
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
    static func navigation(_ c:Context,_ s:Surface)async throws {
        let original=Data("myHTTPParser42_name\r\n雪🙂 e\u{301}".utf8)
        try await load(s,original);select(s,0)
        let expected:[PatchCaretCommand]=[.toggleOvertype,.previousPart,.nextPart,.selectPreviousPart,.selectNextPart]
        let menu=s.text.makeCaretCommandMenu()
        try require(menu.items.filter{!$0.isSeparatorItem}.map(\.title)==expected.map(\.title),"Caret menu source command order changed")
        try require(menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Caret menu source artwork missing")
        for position in [2,6,12,14,19] {try dispatch(s,.nextPart);try require(s.text.selectedRange()==NSRange(location:position,length:0),"Forward identifier-part boundary wrong")}
        for position in [15,12,6,2,0] {try dispatch(s,.previousPart);try require(s.text.selectedRange()==NSRange(location:position,length:0),"Backward identifier-part boundary wrong")}
        s.text.keyDown(with:key(s,"\\",42,.control));try require(s.text.selectedRange()==NSRange(location:2,length:0),"Ctrl-backslash did not reach real native next-part handler")
        try require(s.text.performKeyEquivalent(with:key(s,"|",42,[.control,.shift])),"Shifted next-part equivalent not routed")
        try require(s.text.selectedRange()==NSRange(location:2,length:4),"Native word-part extension lost anchor")
        try dispatch(s,.selectPreviousPart);try require(s.text.selectedRange()==NSRange(location:2,length:0),"Reverse extension did not return to anchor")
        try require(s.text.performKeyEquivalent(with:key(s,"?",44,[.control,.shift])),"Shifted previous-part equivalent not routed")
        try require(s.text.selectedRange()==NSRange(location:0,length:2),"Reverse extension lost directional primary caret")
        let shown=s.text.string as NSString
        for location in [19,21,22,24,25] where location<=shown.length && (location==shown.length || shown.rangeOfComposedCharacterSequence(at:location).location==location) {
            select(s,location);try dispatch(s,.nextPart)
            let end=s.text.selectedRange().location
            try require(end==shown.length || shown.rangeOfComposedCharacterSequence(at:end).location==end,"Caret split grapheme or CRLF")
        }
        try bytes(s,original,"Word-part navigation modified document bytes")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true,"Caret-only commands created editing history")
        try await load(s,Data("myName\notherWord\n".utf8));select(s,0)
        let column=try unwrap(s.text.columnSelection,"Hosted selection controller missing")
        let rows:[PatchLineEditSelection]=[.init(id:10,anchor:0,caret:2),.init(id:20,anchor:7,caret:9)]
        try require(column.applySnapshot(.init(rows:rows,primarySelectionID:20,rectangular:true,rectangleIsThin:false)),"Rectangle caret fixture refused")
        try dispatch(s,.selectNextPart)
        try require(s.text.selectedRange()==NSRange(location:9,length:0) && !column.snapshot().rectangular,"First rectangle command did not switch to directional outer stream caret")
        try dispatch(s,.selectNextPart)
        try require(s.text.selectedRange()==NSRange(location:9,length:3),"Second rectangle command did not resume normal word-part extension")
        try require(column.applySnapshot(.init(rows:rows,primarySelectionID:20,rectangular:true,rectangleIsThin:false)),"Previous rectangle caret fixture refused")
        try dispatch(s,.previousPart);try require(s.text.selectedRange()==NSRange(location:0,length:0),"Previous rectangle command did not use outer lower limit")
        try require(column.applySnapshot(.init(rows:rows,primarySelectionID:20,rectangular:false,rectangleIsThin:false)),"Multiple primary selection fixture refused")
        try dispatch(s,.nextPart)
        try require(s.text.selectedRange()==NSRange(location:12,length:0) && column.snapshot().rows.count==1,"Word-part movement did not collapse nonrectangular additional selections to primary")
        try bytes(s,Data("myName\notherWord\n".utf8),"Rectangle/primary caret routing mutated text")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true,"Selection-shape transition created edit history")
        c.preferences.set(false,forKey:"ShowAppContextMenuIcons")
        try require(s.text.makeCaretCommandMenu().items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image==nil},"Caret icons ignored private preference")
        c.preferences.set(true,forKey:"ShowAppContextMenuIcons")
        try require(PatchCaretCommand.command(for:key(s,"",114,[]))==nil,"Mac Help key was stolen as Insert")
    }
    static func typing(_ c:Context,_ s:Surface)async throws {
        let original=Data("ab🙂\r\n雪x\n".utf8)
        try await load(s,original);select(s,1)
        try require(s.text.performKeyEquivalent(with:key(s,"o",31,[.command,.option])) && s.text.caretOvertype,"Mac overtype shortcut did not enable mode")
        try require(try item(s,.toggleOvertype).state == .on,"Overtype menu checked state missing")
        s.text.insertText("Z",replacementRange:.init(location:NSNotFound,length:0));try await ready(s)
        let changed=Data("aZ🙂\r\n雪x\n".utf8);try bytes(s,changed,"Overtype failed ordinary character replacement")
        try await undoRedo(s,original,changed)
        try await load(s,original);try require(!s.text.caretOvertype,"New document inherited old overtype mode")
        select(s,2);try dispatch(s,.toggleOvertype)
        s.text.insertText("X",replacementRange:.init(location:NSNotFound,length:0));try await ready(s)
        try bytes(s,Data("abX\r\n雪x\n".utf8),"Overtype split supplementary grapheme or consumed following EOL")
        try await load(s,original);select(s,4);try dispatch(s,.toggleOvertype)
        s.text.insertText("Q",replacementRange:.init(location:NSNotFound,length:0));try await ready(s)
        try bytes(s,Data("ab🙂Q\r\n雪x\n".utf8),"Overtype consumed an existing CRLF")
        try await load(s,Data("e\u{301}🙂".utf8));select(s,0);try dispatch(s,.toggleOvertype)
        s.text.insertText("Z",replacementRange:.init(location:NSNotFound,length:0));try await ready(s)
        try bytes(s,Data("Z🙂".utf8),"Overtype split a composed combining sequence")
        try await load(s,original);select(s,1,3);try dispatch(s,.toggleOvertype)
        s.text.insertText("P",replacementRange:.init(location:NSNotFound,length:0));try await ready(s)
        try bytes(s,Data("aP\r\n雪x\n".utf8),"Overtype ignored explicit selected text")
        try await load(s,original);select(s,1);try dispatch(s,.toggleOvertype)
        s.text.insertText("P",replacementRange:.init(location:1,length:0));try await ready(s)
        try bytes(s,Data("aPb🙂\r\n雪x\n".utf8),"Explicit native replacement unexpectedly overstruck adjacent text")
        try await load(s,original);select(s,1);try dispatch(s,.toggleOvertype)
        s.text.insertText("\n",replacementRange:.init(location:NSNotFound,length:0));try await ready(s)
        try bytes(s,Data("a\nb🙂\r\n雪x\n".utf8),"Newline insertion was treated as overtype")
        try await load(s,original);select(s,1);try dispatch(s,.toggleOvertype)
        try require(c.board.name != NSPasteboard.Name.general && s.text.linePasteboard() === c.board,"Ordinary paste lost named private board injection")
        c.board.clearContents();try require(c.board.setString("P",forType:.string),"Could not prepare private plain-text paste")
        let pasteChange=c.board.changeCount
        s.text.paste(nil);try await ready(s)
        try require(c.board.changeCount==pasteChange && c.board.string(forType:.string)=="P","Ordinary Paste changed its private source board")
        try bytes(s,Data("aPb🙂\r\n雪x\n".utf8),"Paste was treated as overtype")
        try await load(s,Data("ab".utf8));select(s,1);try dispatch(s,.toggleOvertype)
        s.text.setMarkedText("候",selectedRange:.init(location:0,length:1),replacementRange:.init(location:NSNotFound,length:0))
        try require(s.text.hasMarkedText() && !s.text.canPerformCaretCommand(.nextPart),"IME composition did not fence caret commands")
        s.text.insertText("確",replacementRange:.init(location:NSNotFound,length:0));try await ready(s)
        try require(!s.text.hasMarkedText(),"IME composition was not committed")
        try bytes(s,Data("a確b".utf8),"Marked-text commit overstruck an unrelated following grapheme")
    }
    static func packets(_ c:Context,_ s:Surface)async throws {
        let prefix=Data("a😀\r\n".utf8),regional=Data([0xff,0x42,10]),opaque=Data([0x98,0,0xff,13])
        let original=prefix+regional+opaque,changed=Data("aX\r\n".utf8)+regional+opaque
        try await load(s,original);select(s,1);try dispatch(s,.toggleOvertype)
        s.text.insertText("X",replacementRange:.init(location:NSNotFound,length:0));try await ready(s)
        try bytes(s,changed,"Overtype transcoded untouched regional/opaque fragments")
        let target=c.root.appendingPathComponent("private-caret-saved.patch")
        s.session.chooseSave={_,_,reply in reply(target)};s.session.saveDocument(as:true)
        try await wait {PatchDocumentSession.activeOperations==0 && !s.model.busy && FileManager.default.fileExists(atPath:target.path)}
        try require(try Data(contentsOf:target)==changed,"Overtype Save changed byte provenance")
        try await undoRedo(s,original,changed)
    }
    static func ownership(_ c:Context,_ s:Surface,_ repository:GitRepository)async throws {
        try await load(s,Data("myName\n".utf8));select(s,0)
        let held=try item(s,.toggleOvertype),original=try s.session.encodedBytes()
        for gate in ["busy","quit","sheet","error"] {
            var sheet:NSWindow?
            if gate=="busy" {s.model.busy=true}
            if gate=="quit" {s.model.confirmingQuit=true}
            if gate=="error" {s.model.error="Private owned error"}
            if gate=="sheet" {let value=NSWindow(contentRect:.init(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false);value.isReleasedWhenClosed=false;value.alphaValue=0;c.sheets.append(value);s.window.beginSheet(value,completionHandler:nil);sheet=value}
            try require(!s.text.canPerformCaretCommand(.toggleOvertype) && !s.text.performCaretCommand(.nextPart),"\(gate) did not fence caret commands")
            _=NSApp.sendAction(held.action!,to:held.target,from:held)
            try require(!s.text.caretOvertype,"Unavailable-owner retained menu toggled overtype")
            try bytes(s,original,"Unavailable-owner command changed bytes")
            s.model.busy=false;s.model.confirmingQuit=false;s.model.error=nil
            if let sheet {s.window.endSheet(sheet);try await wait {sheet.sheetParent==nil};sheet.close()}
        }
        try await load(s,original);select(s,0)
        _=NSApp.sendAction(held.action!,to:held.target,from:held);try require(!s.text.caretOvertype,"Old-document caret menu revived after same-byte replacement")
        let foreign=NSTextField(string:"private other responder");s.window.contentView?.addSubview(foreign);s.window.makeFirstResponder(foreign)
        try require(!s.text.performCaretCommand(.toggleOvertype),"Caret command acted on another responder")
        foreign.removeFromSuperview();s.window.makeFirstResponder(s.text)
        var keyWindow:NSWindow?=s.window
        let menu=PatchMenuContext(keyWindow:{keyWindow});try await ready(s)
        try await wait {menu.caretCommands.contains(.toggleOvertype)}
        menu.performCaretCommand(.toggleOvertype);try require(s.text.caretOvertype,"App Edit menu did not target native caret owner")
        keyWindow=nil;menu.performCaretCommand(.toggleOvertype)
        try require(menu.caretCommands.isEmpty && s.text.caretOvertype,"App Edit menu acted on a background document")
        let preview=try await surface(c,c.owner(repository:repository));preview.model.readOnly=true;preview.model.reload(paths:["file.txt"],staged:false)
        try await wait {!preview.model.busy && preview.model.canFind && !preview.model.document.files.isEmpty && preview.text.string==preview.model.document.text}
        select(preview,0)
        try require(!preview.text.canPerformCaretCommand(.toggleOvertype) && preview.text.performCaretCommand(.nextPart),"Read-only Git preview confused navigation and mutation availability")
        let retired=try await surface(c,c.owner());try await load(retired,Data("oneTwo\n".utf8));select(retired,0);let expired=try item(retired,.toggleOvertype)
        retired.owner.close();try await wait {retired.model.retired}
        _=NSApp.sendAction(expired.action!,to:expired.target,from:expired)
        try require(!retired.text.caretOvertype && !retired.text.performCaretCommand(.nextPart),"Retired caret target remained available")
    }
    static func main()async {
        let first=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,second=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.caretQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(first,second);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            let repository=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Caret QA"),("user.email","caret@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:file);try await repository.stage(["file.txt"]);_=try await repository.commit(message:"base");try Data("base\nnew\n".utf8).write(to:file)
            let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:c.root.appendingPathComponent(".git/config")),working=try Data(contentsOf:file)
            let s=try await surface(c,c.owner()),requested=Set(CommandLine.arguments.dropFirst(3)),scopes=requested.isEmpty ? Set(["navigation","typing","bytes","ownership"]):requested
            if scopes.contains("navigation"){try await navigation(c,s)}
            if scopes.contains("typing"){try await typing(c,s)}
            if scopes.contains("bytes"){try await packets(c,s)}
            if scopes.contains("ownership"){try await ownership(c,s,repository)}
            let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout
            try require(try finalHead==head && Data(contentsOf:file)==working && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:c.root.appendingPathComponent(".git/config"))==config,"Caret editor changed Git/worktree state")
            try await c.clean();print("PASS Unified Diff caret: "+scopes.sorted().joined(separator:",")+"; private bytes/Undo/ownership and closed windows")
        } catch {try? await c.clean();fputs("Unified Diff caret failed: \(error)\n",stderr);exit(1)}
    }
}
