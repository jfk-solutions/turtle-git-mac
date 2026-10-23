// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func messageWrapFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func messageWrapOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));messageWrapOrder(mode,relativeTo:number)}
}
@MainActor @main enum MessageWrapVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Message wrap \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Message wrap timeout \(line)")}
    static func drained()->Bool {
        MessageEditorStylingSession.activeOperations==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeCommitPreflights==0 && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && RebaseWindowModel.activeReplayOperations==0
    }
    static func cleanupReady()->Bool {drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}}
    static func cleanupDiagnostic(_ phase:String) {
        print("Message cleanup \(phase): styles=\(MessageEditorStylingSession.activeOperations) commitReload=\(CommitWindowModel.activeReloads) metadata=\(CommitWindowModel.activeMetadataOperations) prefs=\(CommitWindowModel.activePreferenceOperations) files=\(CommitWindowModel.activeFileOperations) preflights=\(CommitWindowModel.activeCommitPreflights) replayPreparation=\(RebaseWindowModel.activePreparationReads) replayColumns=\(RebaseWindowModel.activeColumnReads) replayOperations=\(RebaseWindowModel.activeReplayOperations)")
        for window in NSApp.windows where window.isVisible || window.attachedSheet != nil || window.sheetParent != nil {
            print("Message cleanup window class=\(String(describing:type(of:window))) title=\(window.title.debugDescription) number=\(window.windowNumber) visible=\(window.isVisible) alpha=\(window.alphaValue) frame=\(window.frame) sheet=\(String(describing:window.attachedSheet.map{String(describing:type(of:$0))+":"+$0.title})) sheetParent=\(String(describing:window.sheetParent.map{String(describing:type(of:$0))+":"+$0.title}))")
        }
        fflush(stdout)
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.MessageWrap."+UUID().uuidString,prefs:UserDefaults
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!
        var owners:[NSWindowController]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;for key in ["UseLibgit2","EnableLogCache","EnableGravatar","Autocompletion","Spellchecker","ConfirmKillProcess"]{prefs.set(false,forKey:key)};prefs.set("Menlo",forKey:"LogFontName");prefs.set(12,forKey:"LogFontSize")}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Message wrap QA"),("user.email","wrap@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.logwidthmarker","18"),("tgit.projectlanguage","-1")] {_=try await repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        }
        func own<T:NSWindowController>(_ owner:T)->T{owners.append(owner);owner.showWindow(nil);owner.window?.orderFront(nil);return owner}
        func clean()async {
            for owner in owners {
                if let window=owner.window {window.makeFirstResponder(nil);window.endEditing(for:nil);if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()}}
                owner.close()
            }
            owners=[]
            if !cleanupReady(){cleanupDiagnostic("before native close/worker drain")}
            // End-sheet/order-out and editor styling completions run on later
            // main-actor turns. Counter zero alone does not prove native teardown.
            for _ in 0..<3000{if cleanupReady(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            if !cleanupReady(){cleanupDiagnostic("after bounded native close/worker drain")}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    struct EditorOwner {
        let controller:NSWindowController
        let editor:ProjectMessageTextView
        let install:(String)->Void
        let current:()->String
        let width:(Int)->Void
        let busy:(Bool)->Void
        let quitting:(Bool)->Void
        let retired:()->Bool
    }
    static let loaded="Loaded cafe\u{301} 🧪 雪 message with several words beyond the source border.\r\nSecond preserved line.\n"
    static func install(_ text:String,_ owner:EditorOwner)async throws {
        owner.install(text)
        try await wait(owner.controller.window){owner.editor.string.utf8.elementsEqual(text.utf8) && owner.editor.messageLayoutAvailable}
        owner.editor.breakUndoCoalescing();owner.editor.undoManager?.removeAllActions()
    }
    static func modes(_ owner:EditorOwner)async throws {
        let editor=owner.editor
        try await install(loaded,owner)
        owner.width(18)
        try await wait(owner.controller.window){editor.enclosingScrollView?.hasHorizontalScroller==true && editor.textContainer?.widthTracksTextView==false && editor.messageBorderWidth>0}
        let before=Data(editor.string.utf8),selection=editor.selectedRange()
        editor.updateMessageWidthMode();editor.layoutManager?.ensureLayout(for:editor.textContainer!)
        try require(Data(editor.string.utf8)==before && owner.current().utf8.elementsEqual(loaded.utf8),"Installing nonzero width rewrote loaded bytes")
        owner.width(0)
        try await wait(owner.controller.window){editor.enclosingScrollView?.hasHorizontalScroller==false && editor.textContainer?.widthTracksTextView==true && editor.messageBorderWidth==0}
        try require(Data(editor.string.utf8)==before && editor.selectedRange()==selection,"Changing width mode edited text/caret")
        // With border0 native soft-wrap never inserts hard line separators.
        editor.setSelectedRange(.init(location:(editor.string as NSString).length,length:0));editor.insertText(" more words without a source border",replacementRange:editor.selectedRange())
        let noBorder=loaded+" more words without a source border"
        try await wait{owner.current().utf8.elementsEqual(noBorder.utf8)}
        try require(editor.string.utf8.elementsEqual(noBorder.utf8),"Zero border inserted hard wraps")
        owner.width(18)
        try await wait(owner.controller.window){editor.messageBorderWidth>0 && editor.isHorizontallyResizable}
    }
    static func joinFacts(_ editor:ProjectMessageTextView)throws {
        let font=editor.font ?? NSFont.monospacedSystemFont(ofSize:12,weight:.regular)
        for (before,expected) in [("a\n\nb","a b"),("a \n\nb","a b"),("a\t\nb","a\t b"),("a\r\nb","a b"),("a\u{0085}b\u{2028}c\u{2029}d","a\u{0085}b\u{2028}c\u{2029}d")] {
            let edits=MessageEditorLineLayout.edits(text:before,range:.init(location:0,length:(before as NSString).length),width:editor.messageBorderWidth,font:font,join:true)
            let value=NSMutableString(string:before)
            for edit in edits.reversed(){value.replaceCharacters(in:edit.range,with:edit.text)}
            try require((value as String).utf8.elementsEqual(expected.utf8),"Source join changed blank-line/ASCII-space/tab/CRLF semantics")
        }
    }
    static func edits(_ owner:EditorOwner)async throws {
        let editor=owner.editor
        try joinFacts(editor)
        try await install(loaded,owner)
        editor.setSelectedRange(.init(location:(editor.string as NSString).length,length:0));editor.insertText(" extra 雪 🧪",replacementRange:editor.selectedRange());editor.breakUndoCoalescing()
        let wrapped=editor.string
        try await wait{owner.current().utf8.elementsEqual(wrapped.utf8)}
        try require(wrapped.components(separatedBy:"\n").count>loaded.components(separatedBy:"\n").count,"Actual edit did not hard-wrap visible/touched long lines")
        try require(wrapped.replacingOccurrences(of:"\n",with:"").utf8.elementsEqual((loaded+" extra 雪 🧪").replacingOccurrences(of:"\n",with:"").utf8),"Hard-wrap dropped whitespace, Unicode or original CR")
        try require(editor.undoManager?.canUndo==true,"Hard-wrap edit omitted Undo")
        editor.undoManager?.undo();try await wait{editor.string.utf8.elementsEqual(loaded.utf8) && owner.current().utf8.elementsEqual(loaded.utf8)}
        editor.undoManager?.redo();try await wait{editor.string.utf8.elementsEqual(wrapped.utf8) && owner.current().utf8.elementsEqual(wrapped.utf8)}
        let paragraph="alpha beta\ngamma delta 雪 🧪\nunchanged tail"
        try await install(paragraph,owner)
        let length=("alpha beta\ngamma delta 雪 🧪" as NSString).length
        editor.setSelectedRange(.init(location:0,length:length))
        editor.splitMessageLines(nil)
        let reflow=editor.string
        try await wait{owner.current().utf8.elementsEqual(reflow.utf8)}
        try require(reflow != paragraph,"Selected Split lines did not join/reflow")
        try require(reflow.hasSuffix("\nunchanged tail"),"Selected reflow changed unrelated trailing line")
        let flowed=String(reflow.dropLast("\nunchanged tail".count)).replacingOccurrences(of:"\n",with:"")
        try require(flowed.utf8.elementsEqual("alpha beta gamma delta 雪 🧪".utf8),"Selected reflow changed spaces/Unicode instead of source line join")
        editor.undoManager?.undo();try await wait{editor.string.utf8.elementsEqual(paragraph.utf8) && owner.current().utf8.elementsEqual(paragraph.utf8)}
        editor.undoManager?.redo();try await wait{editor.string.utf8.elementsEqual(reflow.utf8) && owner.current().utf8.elementsEqual(reflow.utf8)}
    }
    static func imeAndFences(_ owner:EditorOwner)async throws {
        let editor=owner.editor
        try await install("prefix ",owner)
        editor.setSelectedRange(.init(location:(editor.string as NSString).length,length:0))
        let composed="composition cafe\u{301} 雪 🧪 with a long marked clause"
        editor.setMarkedText(composed,selectedRange:.init(location:0,length:(composed as NSString).length),replacementRange:editor.selectedRange())
        try require(editor.hasMarkedText(),"Actual editor did not enter IME marked state")
        let marked=editor.string
        editor.splitMessageLines(nil)
        try require(editor.string.utf8.elementsEqual(marked.utf8) && !editor.string.contains("\n"),"Marked composition was joined or split before commit")
        editor.unmarkText()
        try await wait{!editor.hasMarkedText() && owner.current().utf8.elementsEqual(editor.string.utf8)}
        try require(editor.string.contains("\n"),"Committed composition did not apply deferred hard wrapping")
        try require(editor.string.replacingOccurrences(of:"\n",with:"").utf8.elementsEqual(("prefix "+composed).utf8),"Committing composition lost literal Unicode/whitespace")
        let guarded="first line\nsecond line\nthird line"
        try await install(guarded,owner)
        editor.setSelectedRange(.init(location:0,length:(guarded as NSString).length))
        editor.isEditable=false;editor.splitMessageLines(nil);editor.insertText("blocked",replacementRange:editor.selectedRange());try require(editor.string==guarded,"Read-only message accepted Split lines");editor.isEditable=true
        owner.busy(true);editor.splitMessageLines(nil);editor.insertText("blocked",replacementRange:editor.selectedRange());try require(editor.string==guarded,"Busy owner accepted stale Split lines");owner.busy(false)
        owner.quitting(true);editor.splitMessageLines(nil);try require(editor.string==guarded,"Quit owner accepted stale Split lines");owner.quitting(false)
        let window=try unwrap(owner.controller.window,"Missing message owner"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;defer{if sheet.sheetParent != nil{window.endSheet(sheet,returnCode:.abort)};sheet.close()}
        window.beginSheet(sheet,completionHandler:{_ in});try await wait{window.attachedSheet === sheet}
        editor.splitMessageLines(nil);try require(editor.string==guarded,"Attached owner sheet accepted Split lines")
        window.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}
        window.makeFirstResponder(nil);window.endEditing(for:nil)
        owner.controller.close();try await wait{owner.retired() && drained()}
        editor.splitMessageLines(nil);editor.insertText("blocked",replacementRange:editor.selectedRange());try require(editor.string==guarded && !editor.messageLayoutAvailable,"Retired editor accepted Split lines")
    }
    static func commit(_ c:Context)async throws {
        try Data("working\n".utf8).write(to:c.root.appendingPathComponent("file"))
        let controller=c.own(CommitWindowController(repository:c.repo,access:nil,defaults:c.prefs)),model=controller.model
        model.reload(paths:["."])
        try await wait(controller.window){model.entries.contains{$0.path=="file"} && !model.busy && drained()}
        var editor:CommitMessageTextView?
        try await wait(controller.window){editor=views(controller.window?.contentView).compactMap{$0 as? CommitMessageTextView}.first;return editor?.messageLayoutAvailable==true}
        let actual=try unwrap(editor,"Missing actual Commit message editor")
        let owner=EditorOwner(controller:controller,editor:actual,install:{model.message=$0},current:{model.message},width:{model.projectSettings.messageWidthMarker.value=String($0)},busy:{model.busy=$0},quitting:{model.confirmingQuit=$0},retired:{!model.messageFocusAvailable})
        let head=try await c.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        try await modes(owner);try await edits(owner);try await imeAndFences(owner)
        let finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==index,"Commit editor operations changed repository/index")
    }
    static func rebase(_ c:Context)async throws {
        _=try await c.repo.run(["switch","-c","upstream"])
        try Data("upstream\n".utf8).write(to:c.root.appendingPathComponent("upstream"));try await c.repo.stage(["upstream"]);_=try await c.repo.commit(message:"upstream")
        _=try await c.repo.run(["switch","-c","topic","main"])
        try Data("topic\n".utf8).write(to:c.root.appendingPathComponent("topic"));try await c.repo.stage(["topic"]);_=try await c.repo.commit(message:"An original message with a long untouched line beyond its source border")
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream"
        var plan=try await c.repo.rebasePlan(options);for index in plan.entries.indices{plan.entries[index].action = .edit}
        let helper=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        let paused=try await c.repo.startRebase(plan,editorExecutable:helper);try require(paused.state.isEditPause,"Private replay did not pause for actual message edit")
        let controller=c.own(RebaseWindowController(repository:c.repo,access:nil,preferences:c.prefs)),model=controller.model
        model.editorExecutable=helper;model.load()
        try await wait(controller.window){!model.busy && model.state?.isEditPause==true && model.canEditMessage && drained()}
        model.tab=1
        var editor:ProjectMessageTextView?
        try await wait(controller.window){editor=views(controller.window?.contentView).compactMap{$0 as? ProjectMessageTextView}.first;return editor?.messageLayoutAvailable==true}
        let actual=try unwrap(editor,"Missing actual replay message editor")
        try require(actual.string.utf8.elementsEqual(model.amendMessage.utf8) && actual.string.contains("long untouched line beyond its source border"),"Replay initial width rewrote loaded commit bytes")
        let owner=EditorOwner(controller:controller,editor:actual,install:{model.messageBinding(model.formContext).wrappedValue=$0},current:{model.amendMessage},width:{model.projectSettings.messageWidthMarker.value=String($0)},busy:{model.busy=$0},quitting:{model.revisionMenuLog.confirmingQuit=$0},retired:{model.retired})
        let head=try await c.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        try await modes(owner);try await edits(owner);try await imeAndFences(owner)
        let finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==index,"Replay editor operations advanced replay/index")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.messageWrapFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.messageWrapOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();let kind=CommandLine.arguments[3];switch kind{case "commit":try await commit(c);case "rebase":try await rebase(c);default:throw Failure(description:"Unknown message wrap case")};await c.clean();try require(cleanupReady(),"Message editor windows/work survived cleanup");print("PASS: message wrap "+kind);fflush(stdout)}catch{await c.clean();fputs("Message wrap failed: \(error)\n",stderr);exit(1)}
    }
}
