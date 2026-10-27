// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func messageCommandsPrivateOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;messageCommandsPrivateOrder(mode,relativeTo:number)
    }
}
@MainActor @main struct MessageEditorCommandsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {
        if !condition {throw Failure(description:"line \(line): \(message)")}
    }
    static func phase(_ value:String){print("Message commands: "+value);fflush(stdout)}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        print("Message readiness diagnostics: injectedFocus=\(String(describing:focusedWindow.map{$0.windowNumber})) active=\(NSApp.isActive) key=\(String(describing:NSApp.keyWindow.map{$0.windowNumber})) main=\(String(describing:NSApp.mainWindow.map{$0.windowNumber}))")
        for window in NSApp.windows {print("Message owned window number=\(window.windowNumber) key=\(window.isKeyWindow) canKey=\(window.canBecomeKey) visible=\(window.isVisible) alpha=\(window.alphaValue) responder=\(String(describing:window.firstResponder.map{String(describing:type(of:$0))}))")}
        fflush(stdout)
        throw Failure(description:"Native readiness timeout at line \(line)")
    }
    static func drained()->Bool {
        MessageEditorStylingSession.activeOperations==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeCommitPreflights==0 && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && RebaseWindowModel.activeReplayOperations==0 && HistoryNotesWindowModel.activeReads==0 && HistoryNotesWindowModel.activeMutations==0 && InputWindowController.activeSaves==0
    }
    // Focus is injected only at the supported owner boundary: an inactive,
    // invisible receiver cannot acquire NSApp.keyWindow without desktop activation.
    // Native window/responder identities, controls, events and actions remain real.
    static weak var focusedWindow:NSWindow?
    static func focus(_ window:NSWindow,_ responder:NSResponder?=nil) {
        focusedWindow=window;window.alphaValue=0
        if let responder {window.makeFirstResponder(responder)}
    }
    static func injectFocus(_ editor:ProjectMessageTextView) {
        editor.messageCommandKeyWindow={focusedWindow}
    }
    static func turn()async {await withCheckedContinuation{(reply:CheckedContinuation<Void,Never>) in DispatchQueue.main.async{reply.resume()}}}
    static func views(_ view:NSView?)->[ProjectMessageTextView] {
        guard let view else{return []}
        return (view as? ProjectMessageTextView).map{[$0]} ?? view.subviews.flatMap{views($0)}
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let suite="TurtleGit.MessageCommands.QA."+UUID().uuidString
        let prefs:UserDefaults
        let board=NSPasteboard.withUniqueName()
        let repo:GitRepository
        var owners:[NSWindowController]=[]
        var windows:[NSWindow]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
            for key in ["UseLibgit2","EnableLogCache","EnableGravatar","Autocompletion","Spellchecker","ConfirmKillProcess"] {prefs.set(false,forKey:key)}
            prefs.set("Menlo",forKey:"LogFontName");prefs.set(14,forKey:"LogFontSize")
            prefs.set(true,forKey:"StyleCommitMessages");prefs.set(false,forKey:"Spellchecker");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        }
        func own<T:NSWindowController>(_ owner:T)->T {
            owners.append(owner);owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.showWindow(nil);return owner
        }
        func host(_ view:NSView)->NSWindow {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:240),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.alphaValue=0;window.contentView=view;windows.append(window);window.orderFront(nil);return window
        }
        func clean()async throws {
            MessageEditorCommandsVerification.focusedWindow=nil
            for owner in owners {owner.window?.makeFirstResponder(nil);owner.window?.endEditing(for:nil);owner.close()}
            for window in windows {window.makeFirstResponder(nil);window.endEditing(for:nil);window.close()}
            try await MessageEditorCommandsVerification.wait {MessageEditorCommandsVerification.drained() && !self.owners.contains{$0.window?.isVisible==true || $0.window?.attachedSheet != nil} && !self.windows.contains{$0.isVisible || $0.attachedSheet != nil}}
            board.releaseGlobally();prefs.removePersistentDomain(forName:suite)
            MessageEditorCommandsVerification.phase("owned windows closed; styling workers drained; private board/preferences removed")
        }
    }
    struct Host {
        let name:String,editor:ProjectMessageTextView,window:NSWindow
        let install:(String)->Void,current:()->String
        let busy:((Bool)->Void)?,quitting:((Bool)->Void)?
    }
    static func prepare(_ host:Host,_ text:String)async throws {
        host.install(text)
        try await wait {host.editor.string.utf16.elementsEqual(text.utf16) && host.editor.messageLayoutAvailable}
        host.window.contentView?.layoutSubtreeIfNeeded();focus(host.window,host.editor)
        try await wait{focusedWindow === host.window && host.window.firstResponder === host.editor}
        host.editor.breakUndoCoalescing();host.editor.undoManager?.removeAllActions()
        await turn()
    }
    static func menu(_ host:Host)throws->NSMenu {
        let event=NSEvent.mouseEvent(with:.rightMouseDown,location:host.editor.convert(NSPoint(x:12,y:12),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:host.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        guard let menu=host.editor.menu(for:event) else{throw Failure(description:"No native message context menu")}
        return menu
    }
    static func items(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap{[$0]+($0.submenu.map(items) ?? [])}}
    static func item(_ host:Host,_ title:String)throws->NSMenuItem {
        guard let item=try items(menu(host)).first(where:{$0.title==title}) else{throw Failure(description:"\(host.name): missing native command \(title)")}
        return item
    }
    static func diagnostic(_ host:Host,_ phase:String) {
        print("Message diagnostic \(host.name) \(phase): editor=\(host.editor.string.debugDescription) model=\(host.current().debugDescription) ranges=\(host.editor.selectedRanges.map{NSStringFromRange($0.rangeValue)}) affinity=\(host.editor.selectionAffinity.rawValue) session=\(host.editor.messagePresentationSessionID) commandContext=\(String(describing:host.editor.messageCommandContext)) sourceAvailable=\(host.editor.sourceLinkAvailable()) layoutAvailable=\(host.editor.messageLayoutAvailable) editable=\(host.editor.isEditable) marked=\(host.editor.hasMarkedText()) firstResponder=\(host.window.firstResponder === host.editor) focusOracle=\(focusedWindow === host.window) duplicateAvailable=\(host.editor.canPerformMessageLineCommand(.duplicate))")
        fflush(stdout)
    }
    static func dispatch(_ host:Host,_ title:String)throws {
        let command=try item(host,title)
        try require(command.isEnabled && command.image != nil && command.action != nil && command.target != nil,"Missing native current action/icon: "+title)
        try require(NSApp.sendAction(command.action!,to:command.target,from:command),"Native dispatch rejected "+title)
        diagnostic(host,"after "+title)
    }
    static func key(_ host:Host,_ characters:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:host.window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }
    static func undoDiagnostic(_ host:Host,_ phase:String) {
        let manager=host.editor.undoManager
        print("Message Undo \(host.name) \(phase): grouping=\(manager?.groupingLevel ?? -1) canUndo=\(manager?.canUndo ?? false) canRedo=\(manager?.canRedo ?? false) undoing=\(manager?.isUndoing ?? false) redoing=\(manager?.isRedoing ?? false) registration=\(manager?.isUndoRegistrationEnabled ?? false)")
        fflush(stdout)
    }
    static func undoRoundTrip(_ host:Host,before:String,after:String,selection:NSRange,affinity:NSSelectionAffinity)async throws {
        undoDiagnostic(host,"before post-command wait")
        do {try await wait {host.current().utf16.elementsEqual(after.utf16) && host.editor.string.utf16.elementsEqual(after.utf16)}}
        catch {diagnostic(host,"post-command expected "+after.debugDescription);throw error}
        undoDiagnostic(host,"after post-command wait; before main turn")
        await turn()
        undoDiagnostic(host,"after main turn; before breakUndoCoalescing")
        host.editor.breakUndoCoalescing()
        undoDiagnostic(host,"after breakUndoCoalescing")
        try require(host.editor.undoManager?.canUndo==true,"Command failed to register native Undo")
        undoDiagnostic(host,"before native undo")
        host.editor.undoManager?.undo()
        undoDiagnostic(host,"after native undo; before original-text wait")
        try await wait {host.editor.string.utf16.elementsEqual(before.utf16) && host.current().utf16.elementsEqual(before.utf16)}
        undoDiagnostic(host,"after original-text wait")
        try require(host.editor.selectedRange()==selection && host.editor.selectionAffinity==affinity,"Undo lost source selection direction: actual=\(NSStringFromRange(host.editor.selectedRange())) affinity=\(host.editor.selectionAffinity.rawValue), expected=\(NSStringFromRange(selection)) affinity=\(affinity.rawValue)")
        try require(host.editor.undoManager?.canRedo==true && host.editor.undoManager?.canUndo==false,"One Undo did not restore single command")
        undoDiagnostic(host,"before native redo")
        host.editor.undoManager?.redo()
        undoDiagnostic(host,"after native redo; before result wait")
        try await wait {host.current().utf16.elementsEqual(after.utf16)}
        undoDiagnostic(host,"after result wait; completed")
    }
    static func commands(_ host:Host,_ c:Context)async throws {
        phase(host.name+": native commands and Undo")
        let before="first 🧪\r\nsecond cafe\u{301}\nlast"
        try await prepare(host,before)
        let second=(before as NSString).range(of:"second cafe\u{301}")
        host.editor.setSelectedRange(NSRange(location:second.location+2,length:0),affinity:.upstream,stillSelecting:false)
        try dispatch(host,"Duplicate Selection or Line")
        let duplicated="first 🧪\r\nsecond cafe\u{301}\nsecond cafe\u{301}\nlast"
        try await undoRoundTrip(host,before:before,after:duplicated,selection:NSRange(location:second.location+2,length:0),affinity:.upstream)
        try await prepare(host,"alpha\nbeta\n")
        host.editor.setSelectedRange(NSRange(location:2,length:0),affinity:.downstream,stillSelecting:false)
        try dispatch(host,"Delete Line")
        try await undoRoundTrip(host,before:"alpha\nbeta\n",after:"beta\n",selection:NSRange(location:2,length:0),affinity:.downstream)
        try await prepare(host,"ab😀cd\r\n")
        host.editor.setSelectedRange(NSRange(location:2,length:2),affinity:.upstream,stillSelecting:false)
        host.editor.keyDown(with:key(host,"d",2,[.command,.option]))
        try await undoRoundTrip(host,before:"ab😀cd\r\n",after:"ab😀😀cd\r\n",selection:NSRange(location:2,length:2),affinity:.upstream)
        try await prepare(host,"last")
        host.editor.setSelectedRange(NSRange(location:4,length:0),affinity:.upstream,stillSelecting:false)
        try dispatch(host,"Duplicate Selection or Line")
        try await undoRoundTrip(host,before:"last",after:"last\nlast",selection:NSRange(location:4,length:0),affinity:.upstream)
        try await prepare(host,"first\nsecond\n")
        host.editor.setSelectedRange(NSRange(location:7,length:0),affinity:.downstream,stillSelecting:false)
        try dispatch(host,"Transpose Lines")
        try await undoRoundTrip(host,before:"first\nsecond\n",after:"second\nfirst\n",selection:NSRange(location:7,length:0),affinity:.downstream)
    }
    static func fences(_ host:Host)async throws {
        phase(host.name+": ownership/IME/sheet fences")
        try await prepare(host,"guard\nsecond\n")
        host.editor.setSelectedRange(NSRange(location:2,length:0),affinity:.downstream,stillSelecting:false);let captured=try item(host,"Delete Line"),original=host.editor.string
        if let busy=host.busy {busy(true);await turn();if let action=captured.action{_ = NSApp.sendAction(action,to:captured.target,from:captured)};try require(host.editor.string==original,"Busy captured action mutated editor");busy(false);try await wait{host.editor.messageLayoutAvailable}}
        if let quitting=host.quitting {quitting(true);await turn();if let action=captured.action{_ = NSApp.sendAction(action,to:captured.target,from:captured)};try require(host.editor.string==original,"Quit captured action mutated editor");quitting(false);try await wait{host.editor.messageLayoutAvailable}}
        host.editor.setMarkedText("仮",selectedRange:NSRange(location:1,length:0),replacementRange:host.editor.selectedRange())
        try require(host.editor.hasMarkedText(),"Native IME composition not installed")
        let composed=host.editor.string
        if let action=captured.action{_ = NSApp.sendAction(action,to:captured.target,from:captured)}
        try require(host.editor.string==composed && host.editor.hasMarkedText() && !host.editor.canPerformMessageLineCommand(.duplicate) && !host.editor.canPerformMessageZoom(.zoomIn),"Line command/zoom changed marked IME text or remained available")
        host.editor.unmarkText()
        let sheetCommand=try item(host,"Delete Line"),sheetZoom=try item(host,"Zoom In")
        let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:140,height:80),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        host.window.beginSheet(sheet,completionHandler:nil);await turn()
        defer{if sheet.sheetParent != nil {host.window.endSheet(sheet)};sheet.close()}
        let guarded=host.editor.string,zoomOffset=host.editor.messageZoomOffset
        if let action=sheetCommand.action{_ = NSApp.sendAction(action,to:sheetCommand.target,from:sheetCommand)}
        if let action=sheetZoom.action{_ = NSApp.sendAction(action,to:sheetZoom.target,from:sheetZoom)}
        try require(host.editor.string==guarded && host.editor.messageZoomOffset==zoomOffset,"Captured line/zoom action mutated behind sheet")
        host.window.endSheet(sheet);try await wait{sheet.sheetParent==nil};sheet.close()
    }
    static func zoom(_ host:Host,_ c:Context)async throws {
        phase(host.name+": transient zoom and attributed styling")
        let text="*bold* ^italic^ _underlined_ https://example.invalid/message\nsecond line"
        try await prepare(host,text)
        let selection=NSRange(location:1,length:4)
        host.editor.setSelectedRange(selection,affinity:.upstream,stillSelecting:false)
        let preferenceBefore=c.prefs.persistentDomain(forName:c.suite) ?? [:]
        let undoBefore=host.editor.undoManager?.canUndo,base=host.editor.font?.pointSize ?? 0
        try require(base>0,"Native base font missing")
        try dispatch(host,"Zoom In")
        try await wait {(host.editor.font?.pointSize ?? 0) > base}
        let enlarged=host.editor.font!.pointSize
        try await wait {MessageEditorStylingSession.activeOperations==0}
        await turn()
        try require(host.editor.font!.pointSize==enlarged && host.editor.selectedRange()==selection && host.editor.selectionAffinity == .upstream && host.editor.string==text && host.editor.undoManager?.canUndo==undoBefore,"Zoom/restyling changed text/selection/Undo or lost enlarged font")
        try require(NSDictionary(dictionary:c.prefs.persistentDomain(forName:c.suite) ?? [:]).isEqual(to:preferenceBefore),"Transient zoom wrote preferences")
        try dispatch(host,"Actual Size")
        try await wait {host.editor.font?.pointSize==base}
        host.editor.keyDown(with:key(host,"+",24,[.command]))
        try await wait {(host.editor.font?.pointSize ?? 0) > base}
        try dispatch(host,"Actual Size");try await wait {host.editor.font?.pointSize==base}
        let bold=(text as NSString).range(of:"bold")
        try await wait {
            guard let font=host.editor.textStorage?.attribute(.font,at:bold.location,effectiveRange:nil) as? NSFont else{return false}
            return NSFontManager.shared.traits(of:font).contains(.boldFontMask)
        }
        try dispatch(host,"Zoom In")
        let zoomedBase=host.editor.font!.pointSize
        c.prefs.set(17,forKey:"LogFontSize");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.prefs)
        try await wait {(host.editor.font?.pointSize ?? 0) > zoomedBase}
        try dispatch(host,"Actual Size");try await wait{host.editor.font?.pointSize==17}
        c.prefs.set(14,forKey:"LogFontSize");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.prefs)
        try await wait {host.editor.font?.pointSize==14}
    }
    static func clipboard(_ host:Host,_ c:Context)async throws {
        phase("private Unicode Copy/Cut")
        try await prepare(host,"alpha\r\nbeta\n")
        host.editor.setSelectedRange(NSRange(location:2,length:0),affinity:.downstream,stillSelecting:false);c.board.clearContents()
        try dispatch(host,"Copy Lines")
        try require(c.board.string(forType:.string)=="alpha\r\n" && host.editor.string=="alpha\r\nbeta\n" && host.editor.undoManager?.canUndo==false,"Copy Lines changed editor or Unicode line payload")
        try dispatch(host,"Cut Lines")
        try require(c.board.string(forType:.string)=="alpha\r\n","Cut Lines lost Unicode clipboard")
        try await undoRoundTrip(host,before:"alpha\r\nbeta\n",after:"beta\n",selection:NSRange(location:2,length:0),affinity:.downstream)
    }
    static func extendedNative(_ host:Host,_ c:Context)async throws {
        phase("multiple native ranges, inherited Cocoa bindings and zoom bounds")
        try await prepare(host,"ab\ncd")
        let ranges=[NSValue(range:NSRange(location:0,length:1)),NSValue(range:NSRange(location:3,length:1))]
        host.editor.setSelectedRanges(ranges,affinity:.upstream,stillSelecting:false)
        try dispatch(host,"Duplicate Selection or Line")
        try await wait{host.current()=="aab\nccd"}
        host.editor.undoManager?.undo();try await wait{host.current()=="ab\ncd"}
        try require(host.editor.selectedRanges==ranges && host.editor.selectionAffinity == .upstream,"Multi-range Undo lost native selections/direction")
        host.editor.undoManager?.redo();try await wait{host.current()=="aab\nccd"}
        try await prepare(host,"abcd")
        host.editor.setSelectedRange(NSRange(location:2,length:0),affinity:.downstream,stillSelecting:false)
        host.editor.keyDown(with:key(host,"t",17,[.control]))
        try await wait{host.current()=="acbd"}
        try await prepare(host,"abcd")
        host.editor.setSelectedRange(NSRange(location:1,length:0),affinity:.downstream,stillSelecting:false)
        host.editor.keyDown(with:key(host,"d",2,[.control]))
        try await wait{host.current()=="acd"}
        let prefs=c.prefs.persistentDomain(forName:c.suite) ?? [:]
        for _ in 0..<80 {_ = host.editor.performMessageZoom(.zoomIn)}
        try require(host.editor.messageZoomOffset==60 && !host.editor.canPerformMessageZoom(.zoomIn),"Zoom upper source bound missing")
        for _ in 0..<100 {_ = host.editor.performMessageZoom(.zoomOut)}
        try require(host.editor.messageZoomOffset == -10 && !host.editor.canPerformMessageZoom(.zoomOut),"Zoom lower source bound missing")
        _=host.editor.performMessageZoom(.actualSize)
        try require(host.editor.messageZoomOffset==0 && NSDictionary(dictionary:c.prefs.persistentDomain(forName:c.suite) ?? [:]).isEqual(to:prefs),"Zoom bound/reset changed preferences")
    }
    actor StyleGate {
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        func hold(_ token:OperationCancellation)async {self.token=token;await withCheckedContinuation{reply=$0}}
        func started()->Bool {reply != nil}
        func release(){reply?.resume();reply=nil}
        func cancelled()->Bool {token?.isCancelled==true}
    }
    static func delayedStyle(_ c:Context)async throws {
        phase("actual delayed styling reply retains transient zoom; retired query drains")
        let editor=ProjectMessageTextView(frame:NSRect(x:0,y:0,width:600,height:180))
        editor.isRichText=false;editor.allowsUndo=true;editor.string="*bold* late result"
        let scroll=NSScrollView(frame:editor.frame);scroll.documentView=editor
        let window=c.host(scroll);injectFocus(editor);focus(window,editor)
        try await wait{focusedWindow === window && window.firstResponder === editor}
        editor.spellingPreferences=c.prefs
        let gate=StyleGate()
        let worker=MessageEditorStylingSession(editor:editor,query:{properties,text,formatting,token in
            await gate.hold(token);return try properties.messageStyles(in:text,formattingEnabled:formatting)
        })
        defer{worker.retire();Task{await gate.release()}}
        worker.configure(properties:IssueTrackerProperties(),preferences:c.prefs,font:.monospacedSystemFont(ofSize:14,weight:.regular))
        for _ in 0..<1500 {if await gate.started(){break};try await Task.sleep(nanoseconds:10_000_000)}
        let started=await gate.started();try require(started,"Delayed style query did not start")
        try require(editor.performMessageZoom(.zoomIn),"Zoom unavailable during pending style query")
        let offset=editor.messageZoomOffset,enlarged=editor.font!.pointSize
        await gate.release();try await wait{MessageEditorStylingSession.activeOperations==0}
        let bold=(editor.string as NSString).range(of:"bold")
        try await wait{(editor.textStorage?.attribute(.font,at:bold.location,effectiveRange:nil) as? NSFont).map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)}==true}
        try require(editor.messageZoomOffset==offset && editor.font?.pointSize==enlarged && editor.string=="*bold* late result" && editor.undoManager?.canUndo==false,"Late style reply replaced zoom or edited text/Undo")
        worker.retire()
        let retiringGate=StyleGate()
        let retiring=MessageEditorStylingSession(editor:editor,query:{properties,text,formatting,token in
            await retiringGate.hold(token);return try properties.messageStyles(in:text,formattingEnabled:formatting)
        })
        defer{retiring.retire();Task{await retiringGate.release()}}
        retiring.configure(properties:IssueTrackerProperties(),preferences:c.prefs,font:.monospacedSystemFont(ofSize:14,weight:.regular))
        for _ in 0..<1500 {if await retiringGate.started(){break};try await Task.sleep(nanoseconds:10_000_000)}
        let didStart=await retiringGate.started();try require(didStart,"Retirement query did not start")
        retiring.retire();let cancelled=await retiringGate.cancelled();try require(cancelled,"Retirement did not cancel style token")
        editor.retireSourceStyling();let retiredSize=editor.font?.pointSize
        await retiringGate.release();try await wait{MessageEditorStylingSession.activeOperations==0}
        try require(editor.font?.pointSize==retiredSize && !editor.canPerformMessageZoom(.zoomIn),"Retired style/zoom mutated editor")
        window.close()
    }
    static func main()async throws {
        guard let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.messageCommandsPrivateOrder(_:relativeTo:))) else{throw Failure(description:"Private ordering unavailable")}
        method_exchangeImplementations(order,hidden);defer{method_exchangeImplementations(order,hidden)}
        NSApplication.shared.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            _=try await c.repo.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Message command QA"),("user.email","message-commands@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.projectlanguage","-1"),("tgit.logwidthmarker","0")] {_=try await c.repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:c.root.appendingPathComponent("file"));try await c.repo.stage(["file"]);_=try await c.repo.commit(message:"base")
            _=try await c.repo.run(["commit","--allow-empty","-m","second"])
            _=try await c.repo.run(["notes","add","-m","untouched note"])
            let head=try await c.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:c.root.appendingPathComponent(".git/config"))
            let work=try Data(contentsOf:c.root.appendingPathComponent("file")),note=try await c.repo.run(["notes","show","HEAD"]).stdout
            let commit=c.own(CommitWindowController(repository:c.repo,access:nil,defaults:c.prefs));commit.model.reload(paths:["."])
            try await wait{!commit.model.busy && views(commit.window?.contentView).contains{$0 is CommitMessageTextView && $0.messageLayoutAvailable}}
            let ce=views(commit.window?.contentView).first{$0 is CommitMessageTextView}!
            let ch=Host(name:"Commit",editor:ce,window:commit.window!,install:{commit.model.message=$0},current:{commit.model.message},busy:{commit.model.busy=$0},quitting:{commit.model.confirmingQuit=$0})
            let merge=c.own(MergeWindowController(repository:c.repo,access:nil,preferences:c.prefs));merge.model.load()
            try await wait{!merge.model.busy && views(merge.window?.contentView).contains{$0 is MergeMessageTextView && $0.messageLayoutAvailable}}
            let me=views(merge.window?.contentView).first{$0 is MergeMessageTextView}!
            let mh=Host(name:"Merge",editor:me,window:merge.window!,install:{merge.model.message=$0},current:{merge.model.message},busy:{merge.model.busy=$0},quitting:nil)
            let rebase=c.own(RebaseWindowController(repository:c.repo,access:nil,preferences:c.prefs));rebase.model.load(upstream:"HEAD~1")
            try await wait{!rebase.model.busy}
            final class Box {var text="";var available=true;var session=UUID();var commandContext=UUID()}
            let box=Box()
            let project=NSHostingView(rootView:ProjectMessageEditor(text:Binding(get:{box.text},set:{box.text=$0}),settings:rebase.model.projectSettings,label:"Rebase message",preferences:c.prefs,issueProperties:rebase.model.issueProperties,sourceAvailable:{box.available},sourceSession:AnyHashable(box.session),sourceCommandContext:AnyHashable(box.commandContext)))
            let rw=c.host(project);project.layoutSubtreeIfNeeded()
            try await wait{views(project).contains{$0.messageLayoutAvailable}}
            let pe=views(project).first!
            let ph=Host(name:"Rebase shared ProjectMessageEditor",editor:pe,window:rw,install:{box.text=$0;pe.string=$0;pe.configureSourceStyling(properties:rebase.model.issueProperties,preferences:c.prefs,font:MessageEditorFont.resolve(name:"Menlo",size:14))},current:{box.text},busy:nil,quitting:nil)
            let notes=c.own(HistoryNotesWindowController(repository:c.repo,access:nil,revision:"HEAD",preferences:c.prefs));notes.model.load()
            try await wait{!notes.model.loading && notes.model.snapshot != nil && (notes.editor as? ProjectMessageTextView)?.messageLayoutAvailable==true}
            let ne=notes.editor as! ProjectMessageTextView
            let nh=Host(name:"Notes Input",editor:ne,window:notes.window!,install:{notes.configure(text:$0,minimumLength:0,settings:ProjectDialogSettings())},current:{notes.editor.string},busy:{notes.setInputState(ready:!$0)},quitting:nil)
            let description=c.own(ReferenceDescriptionWindowController(text:"",preferences:c.prefs){_,_ in throw Failure(description:"Unexpected description Save")})
            let de=description.editor as! ProjectMessageTextView
            let dh=Host(name:"Branch description Input",editor:de,window:description.window!,install:{description.configure(text:$0,minimumLength:0,settings:ProjectDialogSettings())},current:{description.editor.string},busy:{description.setInputState(ready:!$0)},quitting:nil)
            let hosts=[("commit",ch),("merge",mh),("project",ph),("notes",nh),("description",dh)]
            let requested=Set((ProcessInfo.processInfo.environment["TURTLEGIT_MESSAGE_COMMAND_CASES"] ?? "commit,merge,project,notes,description,integration").split(separator:",").map(String.init))
            for (name,host) in hosts {injectFocus(host.editor);host.editor.messageLinePasteboard={c.board};if requested.contains(name){try await commands(host,c);try await zoom(host,c);try await fences(host)}}
            if requested.contains("integration") {
            try await clipboard(ch,c)
            try await extendedNative(ch,c)
            phase("hard wrapping is part of one whole-line transaction")
            commit.model.projectSettings.messageWidthMarker.value="18"
            let distant="distant long unchanged cafe\u{301} 🧪 original text that must remain without inserted wraps\r\n"
            let prefix="top\n"+String(repeating:"short\n",count:80)
            try await prepare(ch,prefix+distant)
            try await wait{ch.editor.messageBorderWidth>0}
            ch.editor.setSelectedRange(NSRange(location:1,length:0),affinity:.downstream,stillSelecting:false)
            try dispatch(ch,"Duplicate Selection or Line")
            let localExpected="top\n"+prefix+distant
            try await wait{ch.editor.string.utf16.elementsEqual(localExpected.utf16)}
            try await undoRoundTrip(ch,before:prefix+distant,after:localExpected,selection:NSRange(location:1,length:0),affinity:.downstream)
            phase("repeated long-line duplicate keeps distant source scope unwrapped")
            let repeatedLine="identical long cafe\u{301} 🧪 record with words beyond the source border\n"
            let repeated=String(repeating:repeatedLine,count:80)
            try await prepare(ch,repeated)
            print("Repeated-line viewport: visible=\(ch.editor.visibleRect) clip=\(String(describing:ch.editor.enclosingScrollView?.contentView.bounds)) font=\(String(describing:ch.editor.font?.pointSize))");fflush(stdout)
            ch.editor.setSelectedRange(NSRange(location:2,length:0),affinity:.downstream,stillSelecting:false)
            try dispatch(ch,"Duplicate Selection or Line")
            let repeatedAfter=ch.editor.string
            try require(repeatedAfter.hasSuffix(String(repeating:repeatedLine,count:40)),"Duplicate of identical repeated lines wrapped unrelated distant/trailing source records")
            try require(repeatedAfter.replacingOccurrences(of:"\n",with:"").utf16.elementsEqual(String(repeating:repeatedLine,count:81).replacingOccurrences(of:"\n",with:"").utf16),"Repeated-line duplicate changed source content")
            try require(repeatedAfter.components(separatedBy:"\n").count>82,"Touched duplicated long line did not follow configured hard wrapping")
            try await undoRoundTrip(ch,before:repeated,after:repeatedAfter,selection:NSRange(location:2,length:0),affinity:.downstream)
            let long="one two three four five six seven eight cafe\u{301} 🧪"
            try await prepare(ch,long)
            try await wait{ch.editor.messageBorderWidth>0}
            ch.editor.setSelectedRange(NSRange(location:0,length:long.utf16.count),affinity:.upstream,stillSelecting:false)
            try dispatch(ch,"Duplicate Selection or Line")
            let wrapped=ch.editor.string
            try require(wrapped.components(separatedBy:"\n").count>1 && wrapped.replacingOccurrences(of:"\n",with:"").utf16.elementsEqual((long+long).utf16),"Whole-line command skipped normal hard wrapping or changed Unicode/whitespace")
            try require(ch.editor.selectionAffinity == .upstream,"Hard wrapping lost reverse post-command selection affinity")
            try await undoRoundTrip(ch,before:long,after:wrapped,selection:NSRange(location:0,length:long.utf16.count),affinity:.upstream)
            await turn()
            try require(ch.editor.selectionAffinity == .upstream,"Hard-wrapped Redo lost reverse selection affinity")
            commit.model.projectSettings.messageWidthMarker.value="0"
            try await delayedStyle(c)
            phase("focused application-menu owner routing with private focus oracle")
            try await prepare(ch,"commit\nsecond\n")
            try await prepare(dh,"description\nsecond\n")
            dh.editor.setSelectedRange(NSRange(location:1,length:0),affinity:.downstream,stillSelecting:false)
            let application=MessageEditorMenuContext(keyWindow:{focusedWindow});application.refresh()
            try require(application.present && application.lineCommands.contains(.duplicate) && application.zoomActions.contains(.zoomIn),"Focused native message missing application menu commands")
            application.perform(.duplicate)
            try await wait{dh.editor.string=="description\ndescription\nsecond\n"}
            try require(ch.editor.string=="commit\nsecond\n","Application menu edited background Commit")
            application.zoom(.zoomIn)
            try require(dh.editor.messageZoomOffset==1 && ch.editor.messageZoomOffset==0,"Application zoom affected wrong owner")
            description.window?.makeFirstResponder(nil);application.refresh()
            let inactive=dh.editor.string
            application.perform(.deleteLine);application.zoom(.zoomIn)
            try require(!application.present && dh.editor.string==inactive && dh.editor.messageZoomOffset==1,"Application menu acted without owned message responder")
            phase("Input configure replaces identical-message session")
            try await prepare(dh,"identical\ntext\n")
            dh.editor.setSelectedRange(NSRange(location:1,length:0),affinity:.downstream,stillSelecting:false)
            let oldInput=try item(dh,"Delete Line"),oldInputZoom=try item(dh,"Zoom In"),oldSession=dh.editor.messagePresentationSessionID
            description.configure(text:"identical\ntext\n",minimumLength:0,settings:ProjectDialogSettings())
            if let action=oldInput.action{_ = NSApp.sendAction(action,to:oldInput.target,from:oldInput)}
            if let action=oldInputZoom.action{_ = NSApp.sendAction(action,to:oldInputZoom.target,from:oldInputZoom)}
            try require(dh.editor.messagePresentationSessionID != oldSession && dh.editor.string=="identical\ntext\n" && dh.editor.messageZoomOffset==0,"Input configure retained stale action/zoom session")
            phase("Rebase command-context refresh preserves current document Undo and zoom")
            try await prepare(ph,"context\ntext\n")
            ph.editor.setSelectedRange(NSRange(location:1,length:0),affinity:.downstream,stillSelecting:false)
            try dispatch(ph,"Duplicate Selection or Line")
            try await wait{ph.editor.string=="context\ncontext\ntext\n" && ph.editor.undoManager?.canUndo==true}
            _=ph.editor.performMessageZoom(.zoomIn)
            let contextLine=try item(ph,"Delete Line"),contextZoom=try item(ph,"Zoom In")
            let documentID=ph.editor.messagePresentationSessionID,previousContext=box.commandContext
            let currentText=ph.editor.string,currentZoom=ph.editor.messageZoomOffset
            box.commandContext=UUID()
            project.rootView=ProjectMessageEditor(text:Binding(get:{box.text},set:{box.text=$0}),settings:rebase.model.projectSettings,label:"Rebase message",preferences:c.prefs,issueProperties:rebase.model.issueProperties,sourceAvailable:{box.available},sourceSession:AnyHashable(box.session),sourceCommandContext:AnyHashable(box.commandContext))
            project.layoutSubtreeIfNeeded()
            try await wait{ph.editor.messageCommandContext==AnyHashable(box.commandContext)}
            focus(rw,ph.editor)
            if let action=contextLine.action{_ = NSApp.sendAction(action,to:contextLine.target,from:contextLine)}
            if let action=contextZoom.action{_ = NSApp.sendAction(action,to:contextZoom.target,from:contextZoom)}
            try require(box.commandContext != previousContext && ph.editor.messagePresentationSessionID==documentID && ph.editor.string==currentText && ph.editor.messageZoomOffset==currentZoom && ph.editor.undoManager?.canUndo==true,"Command-context refresh accepted stale menu or erased current document presentation/history")
            ph.editor.undoManager?.undo()
            try await wait{ph.editor.string=="context\ntext\n" && box.text=="context\ntext\n"}
            try require(ph.editor.messageZoomOffset==currentZoom,"Current-document Undo reset transient zoom after command-context refresh")
            phase("identical Rebase ProjectMessageEditor source-session replacement")
            try await prepare(ph,"same\ntext\n")
            ph.editor.setSelectedRange(NSRange(location:1,length:0),affinity:.downstream,stillSelecting:false)
            let oldProject=try item(ph,"Delete Line"),oldProjectZoom=try item(ph,"Zoom In"),projectSession=ph.editor.messagePresentationSessionID
            _=ph.editor.performMessageZoom(.zoomIn)
            box.session=UUID()
            project.rootView=ProjectMessageEditor(text:Binding(get:{box.text},set:{box.text=$0}),settings:rebase.model.projectSettings,label:"Rebase message",preferences:c.prefs,issueProperties:rebase.model.issueProperties,sourceAvailable:{box.available},sourceSession:AnyHashable(box.session),sourceCommandContext:AnyHashable(box.commandContext))
            project.layoutSubtreeIfNeeded()
            try await wait{ph.editor.messagePresentationSessionID != projectSession}
            focus(rw,ph.editor)
            if let action=oldProject.action{_ = NSApp.sendAction(action,to:oldProject.target,from:oldProject)}
            if let action=oldProjectZoom.action{_ = NSApp.sendAction(action,to:oldProjectZoom.target,from:oldProjectZoom)}
            try require(ph.editor.string=="same\ntext\n" && ph.editor.messageZoomOffset==0 && ph.editor.undoManager?.canUndo==false,"Rebase identical-message replacement retained old actions/zoom/history")
            phase("captured menu session/focus/retirement")
            try await prepare(ph,"same\ntext\n");ph.editor.setSelectedRange(NSRange(location:1,length:0),affinity:.downstream,stillSelecting:false)
            let stale=try item(ph,"Delete Line")
            ph.editor.resetMessagePresentationSession()
            if let action=stale.action{_ = NSApp.sendAction(action,to:stale.target,from:stale)}
            try require(ph.editor.string=="same\ntext\n","Captured command survived presentation session reset")
            let fresh=try item(ph,"Delete Line")
            focus(description.window!,de)
            try await wait{focusedWindow === description.window}
            if let action=fresh.action{_ = NSApp.sendAction(action,to:fresh.target,from:fresh)}
            try require(ph.editor.string=="same\ntext\n","Background editor accepted captured command")
            focus(rw);rw.makeFirstResponder(nil)
            if let action=fresh.action{_ = NSApp.sendAction(action,to:fresh.target,from:fresh)}
            try require(ph.editor.string=="same\ntext\n","Unfocused captured command mutated editor")
            focus(rw,ph.editor);box.available=false
            if let action=fresh.action{_ = NSApp.sendAction(action,to:fresh.target,from:fresh)}
            try require(ph.editor.string=="same\ntext\n","Captured unavailable source command mutated")
            box.available=true;ph.editor.retireSourceStyling()
            if let action=fresh.action{_ = NSApp.sendAction(action,to:fresh.target,from:fresh)}
            try require(ph.editor.string=="same\ntext\n","Retired editor accepted captured command")
            }
            try require(try await c.repo.run(["rev-parse","HEAD"]).stdout==head,"Message checks changed HEAD")
            try require(try Data(contentsOf:c.root.appendingPathComponent(".git/index"))==index && Data(contentsOf:c.root.appendingPathComponent(".git/config"))==config && Data(contentsOf:c.root.appendingPathComponent("file"))==work,"Message checks changed index/config/worktree")
            try require(try await c.repo.run(["notes","show","HEAD"]).stdout==note,"Unsaved message edits changed Note")
            try await c.clean()
            print("PASS: shared message editor commands and zoom; completed cases \(requested.sorted()); injected owner focus (no NSApp key-window/desktop activation claim); unchanged repository and owned cleanup")
        } catch {try? await c.clean();throw error}
    }
}
