// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func selectionQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;selectionQAOrder(mode,relativeTo:number)}
}
@MainActor @main struct UnifiedSelectionEditVerification {
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
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);try await UnifiedSelectionEditVerification.wait {sheet.sheetParent==nil};sheet.close()}
            for owner in owners {owner.model.confirmingQuit=false;owner.model.busy=false;owner.close()}
            try await UnifiedSelectionEditVerification.wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0}
            try UnifiedSelectionEditVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Caret owners survived cleanup")
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
    static func bytes(_ s:Surface,_ expected:Data,_ message:String)throws {let actual=try s.session.encodedBytes();try require(actual==expected,message+"; selection=\(s.text.selectedRange()); actual=\(actual.map{String(format:"%02x",$0)}.joined()); expected=\(expected.map{String(format:"%02x",$0)}.joined()); error=\(String(describing:s.model.error)); text=\(s.text.string.debugDescription)")}
    static func key(_ s:Surface,_ text:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    static func item(_ s:Surface,_ command:PatchSelectionCommand)throws->NSMenuItem {
        try unwrap(s.text.makeSelectionCommandMenu().items.first{$0.title==command.title},"Caret menu command missing: "+command.rawValue)
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    static func dispatch(_ s:Surface,_ command:PatchSelectionCommand)throws {
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
        try await boundary(s);try require(s.text.undoManager?.canUndo==true,"Selection edit did not create one native Undo transaction")
        s.text.undoPatch(nil);try await ready(s);try bytes(s,before,"Undo changed untouched bytes or failed to restore overtype")
        try require(s.text.undoManager?.canUndo != true,"Selection edit Undo left an extra partial transaction")
        s.text.redoPatch(nil);try await ready(s);try bytes(s,after,"Redo failed exact overtype restoration")
        try require(s.text.undoManager?.canRedo != true,"Selection edit Redo left an extra partial transaction")
    }
    static let commands:[PatchSelectionCommand]=[.lowerCase,.upperCase,.deleteWordLeft,.deleteWordRight,.deleteLineLeft,.deleteLineRight]
    static func unchanged(_ s:Surface,_ original:Data)throws {
        try bytes(s,original,"No-op or rejected selection command changed bytes")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true,"No-op or rejected command created Undo/dirty state")
    }
    static func caseEdits(_ c:Context,_ s:Surface)async throws {
        let original=Data("Straße e\u{301}\r\nOTHER\n".utf8),expected=Data("STRASSE E\u{301}\r\nOTHER\n".utf8)
        try await load(s,original)
        select(s,0,("Straße e\u{301}" as NSString).length)
        try require(s.text.performKeyEquivalent(with:key(s,"U",32,[.command,.option,.shift])),"Cmd-Option-Shift-U did not reach actual uppercase editor handler")
        try await ready(s);try bytes(s,expected,"Case expansion or combining sequence was normalized/lost")
        try await undoRedo(s,original,expected)
        try await load(s,Data("ABC\r\n".utf8));select(s,0,3)
        s.text.keyDown(with:key(s,"u",32,[.command,.option]));try await ready(s)
        try bytes(s,Data("abc\r\n".utf8),"Cmd-Option-U did not reach real lowercase keyDown handler")
        try await load(s,original);select(s,0)
        _=s.text.performSelectionCommand(.upperCase);try unchanged(s,original)
        select(s,("Straße e\u{301}\r\n" as NSString).length,5)
        _=s.text.performSelectionCommand(.upperCase);try unchanged(s,original)
        try require(PatchSelectionCommand.command(for:key(s,"u",32,.control))==nil,"Selection editing stole macOS Control-U")
        let column=try unwrap(s.text.columnSelection,"Missing native selection controller")
        let length=("Straße e\u{301}" as NSString).length
        try require(column.applySnapshot(.init(rows:[.init(id:7,anchor:length,caret:0)],primarySelectionID:7,rectangular:false)),"Reversed case selection refused")
        try dispatch(s,.upperCase);try await ready(s)
        try bytes(s,expected,"Reverse selection conversion changed wrong content")
        try require(column.snapshot().primary.isReversed && column.snapshot().primary.range.length==length+1,"Expanding uppercase lost reversed selection/direction")
        try await undoRedo(s,original,expected)
        let multi=Data("ab cd\nef gh\n".utf8),multiExpected=Data("AB cd\nef GH\n".utf8)
        try await load(s,multi)
        try require(column.applySnapshot(.init(rows:[.init(id:1,anchor:0,caret:2),.init(id:2,anchor:9,caret:11)],primarySelectionID:2,rectangular:false)),"Multiple case ranges refused")
        try dispatch(s,.upperCase);try await ready(s);try bytes(s,multiExpected,"Case conversion failed independent selected ranges")
        try require(column.snapshot().rows.count==2,"Case conversion dropped additional ranges")
        try await undoRedo(s,multi,multiExpected)
        let rectangular=Data("ab\ncd\n".utf8),rectExpected=Data("AB\nCD\n".utf8)
        try await load(s,rectangular)
        try require(column.applySnapshot(.init(rows:[.init(id:1,anchor:0,caret:2),.init(id:2,anchor:3,caret:5)],primarySelectionID:2,rectangular:true,rectangleAnchor:0,rectangleCaret:5,rectangleIsThin:false)),"Rectangular case ranges refused")
        try dispatch(s,.upperCase);try await ready(s);try bytes(s,rectExpected,"Rectangle case conversion failed per-row source ranges")
        try require(column.snapshot().rectangular,"Case conversion unexpectedly collapsed rectangular selection")
        try await undoRedo(s,rectangular,rectExpected)
        let uneven=Data("ß\nX\n".utf8),unevenUpper=Data("SS\nX\n".utf8)
        try await load(s,uneven)
        try require(column.applySnapshot(.init(rows:[.init(id:1,anchor:0,caret:1),.init(id:2,anchor:2,caret:3)],primarySelectionID:2,rectangular:true,rectangleAnchor:0,rectangleCaret:3,rectangleIsThin:false)),"Uneven-expansion rectangle setup refused")
        try dispatch(s,.upperCase);try await ready(s);try bytes(s,unevenUpper,"Rectangle Unicode expansion lost unchanged row")
        @MainActor func explicitRanges()->[NSRange] {column.snapshot().rows.map(\.range).sorted{$0.location<$1.location}}
        try require(column.snapshot().rectangular && explicitRanges()==[NSRange(location:0,length:2),NSRange(location:3,length:1)],"Case expansion geometrically reflowed explicit rectangle row ranges")
        try await boundary(s);s.text.undoPatch(nil);try await ready(s);try bytes(s,uneven,"Uneven rectangle Undo lost original bytes")
        try require(column.snapshot().rectangular && explicitRanges()==[NSRange(location:0,length:1),NSRange(location:2,length:1)],"Uneven rectangle Undo failed original per-row ranges")
        s.text.redoPatch(nil);try await ready(s);try bytes(s,unevenUpper,"Uneven rectangle Redo lost expanded bytes")
        try require(column.snapshot().rectangular && explicitRanges()==[NSRange(location:0,length:2),NSRange(location:3,length:1)],"Uneven rectangle Redo reflowed explicit ranges")
        try await load(s,Data("ABC".utf8));select(s,0,3)
        var keyWindow:NSWindow?=s.window
        let context=PatchMenuContext(keyWindow:{keyWindow});try await ready(s)
        try await wait{context.selectionCommands.contains(.lowerCase)}
        context.performSelectionCommand(.lowerCase);try await ready(s);try bytes(s,Data("abc".utf8),"App Edit selection menu failed active owner")
        keyWindow=nil;context.performSelectionCommand(.upperCase);try bytes(s,Data("abc".utf8),"App menu acted on background owner")
    }
    static func deletions(_ c:Context,_ s:Surface)async throws {
        let original=Data("one  two_three+four\r\nnext\rfinal\n".utf8)
        let cases:[(PatchSelectionCommand,Int,Data)]=[
            (.deleteWordLeft,8,Data("one  _three+four\r\nnext\rfinal\n".utf8)),
            (.deleteWordRight,5,Data("one  +four\r\nnext\rfinal\n".utf8)),
            (.deleteLineLeft,8,Data("_three+four\r\nnext\rfinal\n".utf8)),
            (.deleteLineRight,8,Data("one  two\r\nnext\rfinal\n".utf8))]
        for (command,caret,expected) in cases {
            try await load(s,original);select(s,caret)
            let backwards=command == .deleteWordLeft || command == .deleteLineLeft
            let modifiers:NSEvent.ModifierFlags=(command == .deleteWordLeft || command == .deleteWordRight) ? .option:.command
            let event=key(s,backwards ? "\u{8}":"\u{f728}",backwards ? 51:117,modifiers)
            if command == .deleteWordLeft || command == .deleteWordRight {try require(s.text.performKeyEquivalent(with:event),"Deletion equivalent refused: "+command.rawValue)}
            else {s.text.keyDown(with:event)}
            try await ready(s);try bytes(s,expected,"Word/line deletion boundary or mixed EOL changed: "+command.rawValue)
            try await undoRedo(s,original,expected)
        }
        try await load(s,original)
        let column=try unwrap(s.text.columnSelection,"Missing deletion selection controller")
        // A wide selected range is not itself deleted: source commands start
        // from the primary caret. Extra ranges are dropped for typing-defaults.
        let next=("one  two_three+four\r\nnext\rfinal\n" as NSString).range(of:"next")
        try require(column.applySnapshot(.init(rows:[.init(id:1,anchor:next.location,caret:NSMaxRange(next)),.init(id:2,anchor:0,caret:8)],primarySelectionID:2,rectangular:false)),"Primary-caret deletion setup refused")
        try dispatch(s,.deleteWordLeft);try await ready(s)
        let deleted=Data("one  _three+four\r\nnext\rfinal\n".utf8)
        try bytes(s,deleted,"Deletion used selected range instead of source main caret")
        try require(column.snapshot().rows.count==1,"Deletion retained extra typing ranges")
        try await undoRedo(s,original,deleted)
        try await load(s,original);select(s,19)
        _=s.text.performSelectionCommand(.deleteLineRight);try unchanged(s,original)
        let rectangleBytes=Data("alpha beta\nnext word\n".utf8),rectangleDeleted=Data("alpha beta\nword\n".utf8)
        try await load(s,rectangleBytes)
        try require(column.applySnapshot(.init(rows:[.init(id:1,anchor:0,caret:5),.init(id:2,anchor:11,caret:16)],primarySelectionID:2,rectangular:true,rectangleAnchor:0,rectangleCaret:16,rectangleIsThin:false)),"Rectangle deletion setup refused")
        try dispatch(s,.deleteWordLeft);try await ready(s);try bytes(s,rectangleDeleted,"Rectangle deletion did not use only main caret")
        try require(column.snapshot().rectangular && column.snapshot().rows.count==1,"Rectangle deletion lost mode or rehydrated dropped rows")
        try await boundary(s);s.text.undoPatch(nil);try await ready(s);try bytes(s,rectangleBytes,"Rectangle delete Undo lost source bytes")
        try require(column.snapshot().rectangular && column.snapshot().rows.count==2,"Rectangle delete Undo failed to restore all original rows")
        s.text.redoPatch(nil);try await ready(s);try bytes(s,rectangleDeleted,"Rectangle delete Redo changed bytes")
        try require(column.snapshot().rectangular && column.snapshot().rows.count==1,"Rectangle delete Redo rehydrated dropped rows")

    }
    static func packetsAndSave(_ c:Context,_ s:Surface)async throws {
        let opaque=Data([0x98,0,0xff,13]),suffix=Data("\r\nKEEP".utf8)+opaque
        let original=Data("Straße".utf8)+suffix,expected=Data("STRASSE".utf8)+suffix
        try await load(s,original);select(s,0,("Straße" as NSString).length)
        try dispatch(s,.upperCase);try await ready(s);try bytes(s,expected,"Case expansion transcoded untouched opaque/legacy fragments")
        let target=c.root.appendingPathComponent("selection-edit-saved.patch")
        s.session.chooseSave={_,_,reply in reply(target)};s.session.saveDocument(as:true)
        try await wait{PatchDocumentSession.activeOperations==0 && !s.model.busy && FileManager.default.fileExists(atPath:target.path)}
        try require(try Data(contentsOf:target)==expected,"Save lost selection edit byte provenance")
        try await undoRedo(s,original,expected)
        // A valid UTF-16LE BOM remains its original encoding through changed
        // selected text; untouched CRLF and supplementary scalars round-trip.
        let unicode=Data([0xff,0xfe])+"abc\r\n🙂".data(using:.utf16LittleEndian)!
        let upper=Data([0xff,0xfe])+"ABC\r\n🙂".data(using:.utf16LittleEndian)!
        try await load(s,unicode);select(s,0,3);try dispatch(s,.upperCase);try await ready(s)
        try bytes(s,upper,"Unicode encoded edit changed BOM/EOL or supplementary text")
        try await undoRedo(s,unicode,upper)
        let legacy=Data([0xe0,0xe1,13,10,0x98,0xff]),legacyUpper=Data([0xc0,0xc1,13,10,0x98,0xff])
        try await load(s,legacy);select(s,0,2);try dispatch(s,.upperCase);try await ready(s)
        try bytes(s,legacyUpper,"CP1251 case edit transcoded unselected legacy/opaque packets")
        try await undoRedo(s,legacy,legacyUpper)

    }
    static func ownership(_ c:Context,_ s:Surface,_ repository:GitRepository)async throws {
        let original=Data("UPPER word\n".utf8);try await load(s,original);select(s,0,5)
        let changedSelection=try item(s,.lowerCase)
        select(s,6,4);_=NSApp.sendAction(changedSelection.action!,to:changedSelection.target,from:changedSelection);try unchanged(s,original)
        select(s,0,5)
        let held=try item(s,.lowerCase)
        for gate in ["busy","quit","error","sheet"] {
            var sheet:NSWindow?
            if gate=="busy" {s.model.busy=true};if gate=="quit" {s.model.confirmingQuit=true};if gate=="error" {s.model.error="Private owned error"}
            if gate=="sheet" {let value=NSWindow(contentRect:.init(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false);value.isReleasedWhenClosed=false;value.alphaValue=0;c.sheets.append(value);s.window.beginSheet(value,completionHandler:nil);sheet=value}
            try require(commands.allSatisfy{!s.text.canPerformSelectionCommand($0) && !s.text.performSelectionCommand($0)},"\(gate) accepted mutation command")
            _=NSApp.sendAction(held.action!,to:held.target,from:held);try bytes(s,original,"Held unavailable mutation acted")
            s.model.busy=false;s.model.confirmingQuit=false;s.model.error=nil
            if let sheet {s.window.endSheet(sheet);try await wait{sheet.sheetParent==nil};sheet.close()}
        }
        try await load(s,original);select(s,0,5)
        _=NSApp.sendAction(held.action!,to:held.target,from:held);try unchanged(s,original)
        s.text.setMarkedText("候",selectedRange:.init(location:0,length:1),replacementRange:.init(location:NSNotFound,length:0))
        try require(s.text.hasMarkedText() && commands.allSatisfy{!s.text.canPerformSelectionCommand($0)},"Marked text did not fence case/delete commands")
        s.text.unmarkText();try await load(s,original)
        let preview=try await surface(c,c.owner(repository:repository));preview.model.readOnly=true;preview.model.reload(paths:["file.txt"],staged:false)
        try await wait{!preview.model.busy && preview.model.canFind && preview.text.string==preview.model.document.text && !preview.model.document.files.isEmpty}
        select(preview,0,1)
        try require(commands.allSatisfy{!preview.text.canPerformSelectionCommand($0) && !preview.text.performSelectionCommand($0)},"Readonly preview accepted text mutation")
        let retired=try await surface(c,c.owner());try await load(retired,original);select(retired,0,5);let stale=try item(retired,.lowerCase)
        retired.owner.close();try await wait{retired.model.retired}
        _=NSApp.sendAction(stale.action!,to:stale.target,from:stale);try require(!retired.text.performSelectionCommand(.lowerCase),"Retired mutation remained available")
        try bytes(retired,original,"Retired mutation changed retained bytes")
    }
    static func main()async {
        let first=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,second=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.selectionQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(first,second);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            let repository=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Selection QA"),("user.email","selection@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:file);try await repository.stage(["file.txt"]);_=try await repository.commit(message:"base");try Data("base\nnew\n".utf8).write(to:file)
            let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
            let s=try await surface(c,c.owner());try await caseEdits(c,s);try await deletions(c,s);try await packetsAndSave(c,s);try await ownership(c,s,repository)
            let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout
            try require(try finalHead==head && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==working,"Selection edits changed unrelated Git/worktree state")
            try await c.clean();print("PASS Unified Diff selection edits: native keys/menu/case/delete/bytes/Undo/Save/ownership and closed windows")
        } catch {try? await c.clean();fputs("Unified Diff selection edits failed: \(error)\n",stderr);exit(1)}
    }
}
