// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func lineEditPrivateOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;lineEditPrivateOrder(mode,relativeTo:number)
    }
}
@MainActor
@main struct UnifiedLineEditVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"line \(line): \(message)")}}
    static func packet(_ pieces:[Data])->Data {var bytes=Data();for piece in pieces {bytes.append(piece)};return bytes}
    static func phase(_ text:String){print("UDiff line edit: "+text);fflush(stdout)}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Native state timeout at line \(line)")
    }
    static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let suite="TurtleGit.LineEdit.QA."+UUID().uuidString
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
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);try await UnifiedLineEditVerification.wait {sheet.sheetParent==nil};sheet.close()}
            for owner in owners {owner.model.confirmingQuit=false;owner.close()}
            let replies=pending;pending.removeAll();replies.forEach{$0(nil)}
            try await UnifiedLineEditVerification.wait {PatchDocumentSession.activeOperations==0 && PatchWindowModel.activeOperations==0}
            try UnifiedLineEditVerification.require(owners.allSatisfy{$0.model.retired && $0.window?.isVisible != true && $0.window?.attachedSheet==nil} && sheets.allSatisfy{!$0.isVisible && $0.sheetParent==nil},"Owned windows/sheets survived cleanup")
            preferences.removePersistentDomain(forName:suite);board.releaseGlobally()
            UnifiedLineEditVerification.phase("owned windows closed; sessions/Git workers drained; private pasteboard released")
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
        s.owner.presentDocument(bytes,title:"Private whole-line commands",comparison:"line-edit.patch",information:"Private native verification")
        try await wait {s.model.canEditText && s.text.isEditable && s.text.string.utf16.elementsEqual(s.model.document.text.utf16) && s.model.savedDocumentBytes==bytes && !s.model.documentDirty && PatchDocumentSession.activeOperations==0}
        s.window.contentView?.layoutSubtreeIfNeeded();s.window.makeFirstResponder(s.text)
        try require(try s.session.encodedBytes()==bytes,"Load changed original byte packets")
    }
    static func select(_ s:Surface,_ range:NSRange,_ affinity:NSSelectionAffinity = .downstream) {
        s.window.makeFirstResponder(s.text);s.text.setSelectedRange(range,affinity:affinity,stillSelecting:false)
    }
    static func title(_ command:PatchLineCommand)->String {
        switch command {
        case .copyLines:return "Copy Lines"
        case .cutLines:return "Cut Lines"
        case .deleteLine:return "Delete Line"
        case .duplicate:return "Duplicate Selection or Line"
        case .transpose:return "Transpose Lines"
        case .indent:return "Indent Lines"
        case .dedent:return "Dedent Lines"
        }
    }
    static func lineMenu(_ s:Surface)throws->NSMenu {
        let range=s.text.selectedRange(),affinity=s.text.selectionAffinity
        // Preserve the prepared selection while invoking the actual context-menu
        // builder; a normal zero-length right click intentionally moves a caret.
        if range.length==0 && range.location<(s.text.string as NSString).length {s.text.setSelectedRange(NSRange(location:range.location,length:1),affinity:affinity,stillSelecting:false)}
        let event=NSEvent.mouseEvent(with:.rightMouseDown,location:s.text.convert(NSPoint(x:10,y:10),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        let menu=s.text.menu(for:event)
        s.text.setSelectedRange(range,affinity:affinity,stillSelecting:false)
        guard let lines=menu?.items.first(where:{$0.title=="Lines"})?.submenu else {throw Failure(description:"Actual context Lines submenu missing")}
        return lines
    }
    static func item(_ s:Surface,_ command:PatchLineCommand)throws->NSMenuItem {
        guard let value=try lineMenu(s).items.first(where:{$0.title==title(command)}) else {throw Failure(description:"Missing line command "+title(command))}
        return value
    }
    static func dispatch(_ s:Surface,_ command:PatchLineCommand)throws {
        let value=try item(s,command)
        try require(value.isEnabled && value.image != nil && value.action != nil && value.target != nil,"Current command missing enabled native target/icon: "+title(command))
        try require(NSApp.sendAction(value.action!,to:value.target,from:value),"Native action dispatch failed: "+title(command))
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
    static func undoRedo(_ s:Surface,before:Data,after:Data,range:NSRange,affinity:NSSelectionAffinity = .downstream)async throws {
        try require(s.text.undoManager?.canUndo==true,"Whole-line transaction not undoable")
        s.text.undoPatch(nil);try await ready(s)
        try bytes(s,before,"One Undo failed exact packet restoration")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true,"One Undo left a partial edit/extra undo group")
        try require(s.text.selectedRange()==range && s.text.selectionAffinity==affinity,"Undo failed directional selection restoration")
        try require(s.text.undoManager?.canRedo==true,"Whole-line transaction not redoable")
        s.text.redoPatch(nil);try await ready(s);try bytes(s,after,"One Redo failed exact packet restoration")
        try require(s.model.documentDirty && s.text.undoManager?.canRedo != true,"One Redo left a partial edit/extra redo group")
    }
    static func menusAndCommands(_ c:Context,_ s:Surface)async throws {
        phase("actual Lines menu/icons, clipboard, current-line and selection commands")
        let original=Data("one\ntwo\nthree\nfour".utf8)
        try await load(s,original);select(s,NSRange(location:1,length:7),.upstream)
        let menu=try lineMenu(s),commands:[PatchLineCommand]=[.copyLines,.cutLines,.deleteLine,.duplicate,.transpose,.indent,.dedent]
        try require(menu.items.count==commands.count+2 && Array(menu.items.prefix(commands.count)).map(\.title)==commands.map(title),"Source seven-command order/captions differ")
        try require(menu.items[commands.count].isSeparatorItem,"Column group lost its separating boundary after seven line commands")
        let columns=menu.items[commands.count+1]
        let groupTitle=NSLocalizedString("Column Selection",comment:"Unified Diff selection menu")
        let groupState="title=\(columns.title) expected=\(groupTitle) action=\(String(describing:columns.action)) target=\(String(describing:columns.target)) hasSubmenu=\(columns.hasSubmenu) linkedParent=\(columns.submenu?.supermenu === menu) receipt=\(String(describing:columns.representedObject))"
        // NSMenu owns the submenu parent's dispatch after attachment. Its
        // target/action are not the leaf command receipt constructed below.
        try require(columns.title==groupTitle && columns.hasSubmenu && columns.submenu?.title==groupTitle && columns.submenu?.supermenu === menu && columns.menu === menu && columns.representedObject==nil,"Lines menu lost separate Column Selection group; "+groupState)
        phase("integrated Column Selection native parent: "+groupState)
        try require(menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Lines menu lost source/group icons")
        let columnItems=columns.submenu!.items
        try require(columnItems.map(\.title)==PatchColumnDirection.allCases.map(\.title) && columnItems.allSatisfy{!$0.isSeparatorItem && $0.submenu==nil && $0.image != nil && $0.isEnabled && $0.target === s.text && $0.action != nil},"Column group lost exact direction order/icons/enabled native ownership")
        try dispatch(s,.copyLines)
        try require(c.board.string(forType:.string)=="one\ntwo\nthree\n" && s.text.selectedRange()==NSRange(location:1,length:7),"Copy Lines lost endpoint-line inclusion/selection")
        try bytes(s,original,"Copy Lines mutated bytes")
        try require(!s.text.canPerformLineCommand(.transpose) && !(try item(s,.transpose)).isEnabled,"First-line transpose incorrectly enabled")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true,"Copy Lines created an undo/edit transaction")
        select(s,NSRange(location:0,length:0))
        let right=columnItems.first{$0.title==PatchColumnDirection.right.title}!
        try require(NSApp.sendAction(right.action!,to:right.target,from:right),"Integrated Column Selection action refused dispatch")
        try require(s.text.lineSelectionSnapshot.rectangular && s.text.lineSelectionSnapshot.primary.range==NSRange(location:0,length:1),"Integrated Column Selection group routed wrong direction")
        try bytes(s,original,"Integrated column extension edited document bytes")
        try require(!s.model.documentDirty && s.text.undoManager?.canUndo != true,"Column extension created an edit/undo transaction")
        try await load(s,original);select(s,NSRange(location:1,length:7),.upstream)
        c.preferences.set(false,forKey:"ShowAppContextMenuIcons")
        let noIcons=try lineMenu(s)
        try require(noIcons.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image==nil} && noIcons.items.last?.submenu?.items.allSatisfy{$0.image==nil}==true,"Lines/Column Selection icons ignored private context-menu preference")
        c.preferences.set(true,forKey:"ShowAppContextMenuIcons")
        try dispatch(s,.cutLines);try await ready(s)
        try bytes(s,Data("four".utf8),"Cut Lines did not include boundary endpoint's whole line")
        try await undoRedo(s,before:original,after:Data("four".utf8),range:NSRange(location:1,length:7),affinity:.upstream)
        try await load(s,original);select(s,NSRange(location:1,length:7),.upstream)
        try dispatch(s,.deleteLine);try await ready(s)
        try bytes(s,Data("two\nthree\nfour".utf8),"Delete Line deleted selection instead of directional caret line")
        try await undoRedo(s,before:original,after:Data("two\nthree\nfour".utf8),range:NSRange(location:1,length:7),affinity:.upstream)
        try await load(s,Data("abcdef\n".utf8));select(s,NSRange(location:1,length:3))
        try dispatch(s,.duplicate);try await ready(s);try bytes(s,Data("abcdbcdef\n".utf8),"Duplicate Selection used whole line")
        try await undoRedo(s,before:Data("abcdef\n".utf8),after:Data("abcdbcdef\n".utf8),range:NSRange(location:1,length:3))
        try await load(s,Data("one\nlast".utf8));select(s,NSRange(location:5,length:0))
        try dispatch(s,.duplicate);try await ready(s);try bytes(s,Data("one\nlast\nlast".utf8),"Empty selection did not duplicate unterminated current line")
        try await undoRedo(s,before:Data("one\nlast".utf8),after:Data("one\nlast\nlast".utf8),range:NSRange(location:5,length:0))
        // The app Edit menu uses its observed key-owner context, independently
        // of a retained context menu's receipt.
        try await load(s,Data("one\ntwo\n".utf8));select(s,NSRange(location:5,length:0))
        var focus:NSWindow?=s.window
        let appMenu=PatchMenuContext(keyWindow:{focus})
        try await wait {appMenu.lineCommands.contains(.duplicate)}
        appMenu.performLineCommand(.duplicate);try await ready(s)
        try bytes(s,Data("one\ntwo\ntwo\n".utf8),"App Edit menu failed current-owner dispatch")
        let held=try s.session.encodedBytes();focus=nil;appMenu.performLineCommand(.deleteLine)
        try require(appMenu.lineCommands.isEmpty,"App menu kept commands without a key owner")
        try bytes(s,held,"App menu mutated background source")
        focus=s.window
        try require(s.window.makeFirstResponder(nil) && s.window.firstResponder !== s.text,"Could not establish non-source app-menu responder")
        appMenu.performLineCommand(.duplicate)
        try require(appMenu.lineCommands.isEmpty,"App menu bypassed native first-responder ownership")
        try bytes(s,held,"App menu edited when source was not first responder")
        s.window.makeFirstResponder(s.text)
    }
    static func keyboard(_ c:Context,_ s:Surface)async throws {
        phase("native editor shortcuts, Tab/ShiftTab and directional multi-line indent")
        let backTab=String(UnicodeScalar(UInt32(NSBackTabCharacter))!)
        try await load(s,Data("alpha\nbeta\ngamma".utf8));select(s,NSRange(location:2,length:0))
        try require(s.text.performKeyEquivalent(with:key(s,"]",30,.command)),"Cmd] did not route source LineIndent")
        try await ready(s);try bytes(s,Data("\talpha\nbeta\ngamma".utf8),"LineIndent inserted Tab at caret instead of line start")
        try require(s.text.performKeyEquivalent(with:key(s,"[",33,.command)),"Cmd[ did not route source LineDedent")
        try await ready(s);try bytes(s,Data("alpha\nbeta\ngamma".utf8),"LineDedent failed current line")
        try await load(s,Data("alpha\n".utf8));select(s,NSRange(location:2,length:0))
        s.text.keyDown(with:key(s,"\t",48,[]));try await ready(s)
        try bytes(s,Data("al\tpha\n".utf8),"Actual keyboard Tab did not insert at body caret")
        try await undoRedo(s,before:Data("alpha\n".utf8),after:Data("al\tpha\n".utf8),range:NSRange(location:2,length:0))
        let held=try s.session.encodedBytes();select(s,NSRange(location:3,length:0))
        s.text.keyDown(with:key(s,backTab,48,.shift));try await ready(s)
        try bytes(s,held,"BackTab outside indentation mutated text")
        try require(s.text.selectedRange()==NSRange(location:0,length:0),"BackTab outside indentation failed previous visual tab stop")
        let multiline=Data("aa\nbb\ncc\n".utf8);try await load(s,multiline)
        select(s,NSRange(location:0,length:6),.upstream)
        s.text.keyDown(with:key(s,"\t",48,[]));try await ready(s)
        let indented=Data("\taa\n\tbb\ncc\n".utf8);try bytes(s,indented,"Multi-line Tab included endpoint-only next line")
        try require(s.text.selectionAffinity == .upstream && s.text.selectedRange()==NSRange(location:0,length:8),"Indent lost reverse whole-line selection")
        try await undoRedo(s,before:multiline,after:indented,range:NSRange(location:0,length:6),affinity:.upstream)
        s.text.keyDown(with:key(s,backTab,48,.shift));try await ready(s);try bytes(s,multiline,"Multi-line BackTab failed inverse dedent")
        // All editor-local source shortcuts reach the same live action family.
        for (characters,code,command) in [("c",UInt16(8),PatchLineCommand.copyLines),("x",7,.cutLines),("k",40,.deleteLine),("d",2,.duplicate),("t",17,.transpose)] {
            try await load(s,Data("one\ntwo\n".utf8));select(s,NSRange(location:5,length:0))
            try require(s.text.canPerformLineCommand(command),"Prepared source shortcut unavailable")
            try require(s.text.performKeyEquivalent(with:key(s,characters,code,[.command,.option])),"CmdOption\(characters) did not dispatch source command")
            try await ready(s)
            if command == .copyLines {try require(c.board.string(forType:.string)=="two\n","Shortcut copied wrong line")}
            else {try require(s.model.documentDirty,"Mutation shortcut did not create edit transaction")}
        }
    }
    static func save(_ c:Context,_ s:Surface,_ expected:Data,_ name:String)async throws {
        let target=c.root.appendingPathComponent(name)
        s.session.chooseSave={_,_,reply in reply(target)}
        try require(s.window.performKeyEquivalent(with:key(s,"s",1,.command)),"Native CmdS did not route owned save")
        try await wait {PatchDocumentSession.activeOperations==0 && !s.model.busy && !s.model.documentDirty && FileManager.default.fileExists(atPath:target.path)}
        try require(try Data(contentsOf:target)==expected && s.model.savedDocumentBytes==expected,"Owned Save changed raw packet/encoding/terminators")
    }
    static func rawPackets(_ c:Context,_ s:Surface)async throws {
        phase("mixed UTF8/regional/opaque packets, content transpose and exact Save/Undo/Redo")
        let a=Data("+日本語\r\n".utf8),b=try ComparisonTextEncoding.windows1251.encode("-исходный\n"),opaque=Data(" opaque: ".utf8)+Data([0x98,0,0xff]),tail=Data("tail".utf8)
        let original=packet([a,b,opaque,Data([13]),tail])
        try await load(s,original)
        try require(s.text.string.unicodeScalars.contains{$0.value==0},"Native source lost embedded NUL")
        let target=(s.text.string as NSString).range(of:"исходный");try require(target.location != NSNotFound,"Regional text not decoded")
        let caret=NSRange(location:target.location+1,length:0);select(s,caret)
        try dispatch(s,.transpose);try await ready(s)
        let transposed=packet([Data(b.dropLast()),Data([13,10]),Data(a.dropLast(2)),Data([10]),opaque,Data([13]),tail])
        try bytes(s,transposed,"Transpose regenerated moved UTF8/regional/opaque packets or EOL slots")
        try await undoRedo(s,before:original,after:transposed,range:caret)
        try await save(c,s,transposed,"transpose.patch")
        try await load(s,original)
        let opaqueRange=(s.text.string as NSString).range(of:" opaque:");select(s,NSRange(location:opaqueRange.location+2,length:0))
        try dispatch(s,.duplicate);try await ready(s)
        let duplicated=packet([a,b,opaque,Data([10]),opaque,Data([13]),tail])
        try bytes(s,duplicated,"Duplicate lost opaque byte provenance or native LF/newline policy")
        try await undoRedo(s,before:original,after:duplicated,range:NSRange(location:opaqueRange.location+2,length:0))
        try await save(c,s,duplicated,"duplicate.patch")
        try await load(s,original);select(s,NSRange(location:opaqueRange.location+2,length:0))
        try dispatch(s,.cutLines);try await ready(s)
        let cut=a+b+tail;try bytes(s,cut,"Cut changed retained legacy/mixed-EOL packets")
        try await undoRedo(s,before:original,after:cut,range:NSRange(location:opaqueRange.location+2,length:0))
        try await save(c,s,cut,"cut.patch")
        // Same displayed scalars, different original byte encodings. A real
        // transpose is still dirty/undoable and Save must write the byte move.
        let first=Data("я\n".utf8),second=Data([0xff,10]),same=first+second,swapped=second+first
        try await load(s,same);let shown=s.text.string;select(s,NSRange(location:2,length:0))
        try dispatch(s,.transpose);try await ready(s)
        try require(s.text.string.utf16.elementsEqual(shown.utf16) && s.model.documentDirty,"Byte-only transpose lost dirty provenance")
        try bytes(s,swapped,"Visually equal transpose was discarded or transcoded")
        try await undoRedo(s,before:same,after:swapped,range:NSRange(location:2,length:0))
        try await save(c,s,swapped,"byte-only.patch")
    }
    static func unencodableDraft(_ c:Context,_ s:Surface)async throws {
        phase("regional unencodable draft stays editable; whole-line removal/Save/Undo/Redo")
        let original=try ComparisonTextEncoding.windows1251.encode("исходный\n")
        func refusesSnapshot()throws {
            do {_ = try s.session.encodedBytes();throw Failure(description:"Unrepresentable draft silently encoded")}
            catch PatchDocumentSession.Failure.encoding {}
        }
        let requested=CommandLine.arguments.first(where:{$0.hasPrefix("draft-command=")}).map{String($0.dropFirst("draft-command=".count))}
        for command in [PatchLineCommand.deleteLine,.cutLines] where requested==nil || requested==command.rawValue {
            phase("regional draft "+command.rawValue+": typed draft, snapshot refusal, remove, Save, Undo/Redo")
            try await load(s,original)
            let end=(s.text.string as NSString).length
            s.text.insertText("🐢\n",replacementRange:NSRange(location:end,length:0));try await ready(s)
            // Typing and a later menu/key command are distinct native input
            // events. Let AppKit close its own automatic event group; never
            // force-end an unknown group or change the Undo manager policy.
            s.text.breakUndoCoalescing()
            guard let boundary=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:s.window.windowNumber,context:nil,subtype:0,data1:0x55444946,data2:0) else {throw Failure(description:"Private native event boundary allocation failed")}
            NSApp.postEvent(boundary,atStart:false)
            phase("regional draft queued private NSApp applicationDefined event for window \(s.window.windowNumber)")
            phase("regional draft typing boundary: groupingLevel=\(s.text.undoManager?.groupingLevel ?? -1), action=\(s.text.undoManager?.undoActionName ?? "missing")")
            try await wait {s.text.undoManager?.groupingLevel==0}
            phase("regional draft input event completed: groupingLevel=\(s.text.undoManager?.groupingLevel ?? -1)")
            let draft=s.text.string
            try require(s.model.documentDirty && s.model.error==nil && s.model.canEditText && s.text.isEditable,"Unrepresentable typing disabled ordinary editing or published an eager codec error")
            try refusesSnapshot()
            try require(s.model.error==nil,"Explicit byte snapshot published an editing-blocking error")
            let bad=(s.text.string as NSString).range(of:"🐢");select(s,NSRange(location:bad.location,length:0))
            try require(s.text.canPerformLineCommand(command),"Unencodable packet blocked its own removal")
            try dispatch(s,command);try await ready(s)
            try bytes(s,original,"Whole-line removal failed to recover original regional bytes")
            if command == .cutLines {try require(c.board.string(forType:.string)=="🐢\n","Cut failed Unicode clipboard for removed unencodable line")}
            try await save(c,s,original,command == .cutLines ? "recovered-cut.patch":"recovered-delete.patch")
            phase("regional draft before Undo: nativeEditable=\(s.text.isEditable), modelEditable=\(s.model.canEditText), dirty=\(s.model.documentDirty), undo=\(s.text.undoManager?.canUndo == true), firstResponder=\(s.window.firstResponder === s.text), error=\(String(describing:s.model.error))")
            s.text.undoPatch(nil);try await ready(s)
            phase("regional draft after Undo: matchesDraft=\(s.text.string.utf16.elementsEqual(draft.utf16)), nativeEditable=\(s.text.isEditable), modelEditable=\(s.model.canEditText), dirty=\(s.model.documentDirty), undo=\(s.text.undoManager?.canUndo == true), redo=\(s.text.undoManager?.canRedo == true), error=\(String(describing:s.model.error)), scalars=\(s.text.string.unicodeScalars.map{String($0.value,radix:16)}.joined(separator:","))")
            try require(s.text.string.utf16.elementsEqual(draft.utf16) && s.model.documentDirty && s.model.error==nil && s.model.canEditText,"One Undo after Save did not restore editable unrepresentable draft")
            try refusesSnapshot()
            s.text.redoPatch(nil);try await ready(s)
            try bytes(s,original,"One Redo failed regional recovery")
            try require(!s.model.documentDirty && s.model.error==nil,"Redo did not return to valid saved byte point")
        }
    }
    static func fences(_ c:Context,_ s:Surface,_ repo:GitRepository)async throws {
        phase("readonly copy, real preview, stale menus, busy/sheet/Quit/retired ownership")
        let preview=try await surface(c,c.owner(repository:repo));preview.model.readOnly=true;preview.model.reload(paths:["file.txt"],staged:false)
        try await wait {!preview.model.busy && !preview.model.document.files.isEmpty && preview.text.string==preview.model.document.text}
        let changed=preview.model.document.lines.firstIndex(of:"+new")!
        let range=PatchLineIndex(text:preview.text.string).range(forLine:changed)!;select(preview,range)
        try dispatch(preview,.copyLines)
        try require(c.board.string(forType:.string)?.contains("+new")==true,"Read-only Git preview could not copy lines")
        for command in [PatchLineCommand.cutLines,.deleteLine,.duplicate,.transpose,.indent,.dedent] {
            try require(!preview.text.canPerformLineCommand(command) && !preview.text.performLineCommand(command) && !(try item(preview,command)).isEnabled,"Read-only preview accepted/enabled line mutation")
        }
        try await load(s,Data("one\ntwo\n".utf8));select(s,NSRange(location:5,length:0))
        let held=try item(s,.duplicate),original=try s.session.encodedBytes()
        guard let heldColumn=try lineMenu(s).items.last?.submenu?.items.first(where:{$0.title==PatchColumnDirection.right.title}) else{throw Failure(description:"Integrated retained Column Selection action missing")}
        for gate in ["busy","quit","sheet"] {
            var sheet:NSWindow?
            if gate=="busy" {s.model.busy=true}
            if gate=="quit" {s.model.confirmingQuit=true}
            if gate=="sheet" {
                let value=NSWindow(contentRect:NSRect(x:0,y:0,width:120,height:70),styleMask:.borderless,backing:.buffered,defer:false)
                value.isReleasedWhenClosed=false;value.alphaValue=0;c.sheets.append(value);s.window.beginSheet(value,completionHandler:nil);sheet=value
            }
            try require(!s.text.canPerformLineCommand(.duplicate) && !s.text.performLineCommand(.duplicate),"\(gate) failed command fence")
            let columnSelection=s.text.lineSelectionSnapshot
            _=NSApp.sendAction(held.action!,to:held.target,from:held);try bytes(s,original,"\(gate) retained menu mutated source")
            _=NSApp.sendAction(heldColumn.action!,to:heldColumn.target,from:heldColumn)
            try require(s.text.lineSelectionSnapshot==columnSelection,"\(gate) retained column menu changed selection")
            s.model.busy=false;s.model.confirmingQuit=false
            if let sheet {s.window.endSheet(sheet);try await wait {sheet.sheetParent==nil};sheet.close()}
        }
        // Leave any prior rectangle through the native controller before
        // installing explicit ordinary stream selections. Source Duplicate
        // deliberately visits every live selection; ordinary typing is distinct.
        s.text.columnSelection?.collapseToPrimary()
        select(s,NSRange(location:1,length:0))
        s.text.setSelectedRanges([NSValue(range:NSRange(location:1,length:1)),NSValue(range:NSRange(location:5,length:1))],affinity:.downstream,stillSelecting:false)
        let multiple=s.text.selectedRanges,beforeMultiple=s.text.lineSelectionSnapshot
        try require(multiple.count==2 && beforeMultiple.rows.count==2 && !beforeMultiple.rectangular,"Native ordinary stream setup lost secondary selection or retained rectangle mode")
        try bytes(s,original,"Ordinary stream selection setup changed bytes")
        try require(s.text.canPerformLineCommand(.duplicate),"Explicit Duplicate unavailable for two native stream selections")
        // The ordinary single-range context helper intentionally restores one
        // caret/range. Build this real native command menu without that helper
        // so both accepted stream selections reach its captured action intact.
        guard let multipleDuplicate=s.text.makeLineCommandMenu().items.first(where:{$0.title==title(.duplicate)}) else{throw Failure(description:"Multiple-stream native Duplicate item missing")}
        try require(s.text.lineSelectionSnapshot==beforeMultiple && multipleDuplicate.isEnabled && multipleDuplicate.image != nil && multipleDuplicate.target === s.text && multipleDuplicate.action != nil,"Multiple-stream command menu changed selections or lost native ownership")
        try require(NSApp.sendAction(multipleDuplicate.action!,to:multipleDuplicate.target,from:multipleDuplicate),"Native multiple-stream Duplicate dispatch failed");try await ready(s)
        try bytes(s,Data("onne\ntwwo\n".utf8),"Explicit Duplicate failed to visit both live stream selections")
        try require(s.text.selectedRanges.count==2 && s.text.lineSelectionSnapshot.rows.count==2 && !s.text.lineSelectionSnapshot.rectangular,"Explicit Duplicate discarded secondary selection or changed mode")
        s.text.undoPatch(nil);try await ready(s);try bytes(s,original,"One Undo failed both stream-selection packet restoration")
        try require(s.text.selectedRanges==multiple && s.text.lineSelectionSnapshot==beforeMultiple && !s.model.documentDirty && s.text.undoManager?.canUndo != true,"One Undo failed exact two-selection/direction/mode restoration")
        s.text.redoPatch(nil);try await ready(s);try bytes(s,Data("onne\ntwwo\n".utf8),"One Redo failed both stream-selection duplicates")
        try require(s.text.selectedRanges.count==2 && !s.text.lineSelectionSnapshot.rectangular,"Redo discarded secondary stream selection")
        s.text.undoPatch(nil);try await ready(s);try bytes(s,original,"Stream-selection cohort did not reset exact original bytes")
        try require(s.text.lineSelectionSnapshot==beforeMultiple,"Stream-selection cohort did not restore exact selection state")
        s.text.columnSelection?.collapseToPrimary()
        // Same contents still constitute a replacement; the captured receipt
        // must not become live merely because visible text compares equal.
        try await load(s,original);select(s,NSRange(location:5,length:0))
        try require(s.text.canPerformLineCommand(.duplicate),"Current replacement commands unavailable")
        _=NSApp.sendAction(held.action!,to:held.target,from:held);try bytes(s,original,"Retained menu acted on replacement document")
        let replacedSelection=s.text.lineSelectionSnapshot
        _=NSApp.sendAction(heldColumn.action!,to:heldColumn.target,from:heldColumn)
        try require(s.text.lineSelectionSnapshot==replacedSelection,"Retained column receipt acted on equal-byte replacement")
        try dispatch(s,.duplicate);try await ready(s);try require(s.model.documentDirty,"Fresh replacement receipt failed")
        var release:((URL?)->Void)?
        s.session.chooseSave={_,_,reply in release=reply;c.pending.append(reply)}
        s.session.saveDocument(as:true);try await wait {release != nil && s.model.busy}
        try require(!s.text.performLineCommand(.deleteLine),"Held native Save accepted edits")
        s.owner.close();try require(!s.text.performLineCommand(.duplicate),"Retired owner accepted whole-line mutation")
        let unwanted=c.root.appendingPathComponent("retired-save.patch");release?(unwanted);release=nil;c.pending.removeAll()
        try await wait {PatchDocumentSession.activeOperations==0}
        try require(!FileManager.default.fileExists(atPath:unwanted.path),"Retired save wrote captured edited packets")
        _=NSApp.sendAction(held.action!,to:held.target,from:held)
        let retiredSelection=s.text.lineSelectionSnapshot
        _=NSApp.sendAction(heldColumn.action!,to:heldColumn.target,from:heldColumn)
        try require(s.text.lineSelectionSnapshot==retiredSelection,"Retired column receipt changed selection")
        try require(s.model.retired && s.window.isVisible==false,"Closed owner escaped retirement")
    }
    static func main()async {
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.lineEditPrivateOrder(_:relativeTo:)))!
        method_exchangeImplementations(order,replacement);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            let repo=GitRepository(root:c.root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            _=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Line edit QA"),("user.email","line@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            let file=c.root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"baseline")
            try Data("base\nnew\n".utf8).write(to:file)
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:c.root.appendingPathComponent(".git/config")),working=try Data(contentsOf:file)
            let s=try await surface(c,c.owner())
            let requested=Set(CommandLine.arguments.dropFirst(3).filter{!$0.hasPrefix("draft-command=")})
            let scopes=requested.isEmpty ? Set(["commands","keyboard","bytes","drafts","ownership"]):requested
            if scopes.contains("commands") {try await menusAndCommands(c,s)}
            if scopes.contains("keyboard") {try await keyboard(c,s)}
            if scopes.contains("bytes") {try await rawPackets(c,s)}
            if scopes.contains("drafts") {try await unencodableDraft(c,s)}
            if scopes.contains("ownership") {try await fences(c,s,repo)}
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(finalHead==head && Data(contentsOf:file)==working && Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:c.root.appendingPathComponent(".git/config"))==config,"Whole-line editor changed Git HEAD/index/config/worktree")
            try await c.clean();phase("PASS Unified Diff line edit: scope="+scopes.sorted().joined(separator:",")+"; exact Git state preserved; all owned windows closed")
        } catch {try? await c.clean();fputs("Unified Diff line edit failed: \(error)\n",stderr);fflush(stderr);exit(1)}
    }
}
