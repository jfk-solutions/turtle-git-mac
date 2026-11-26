// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func reloadPositionHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));reloadPositionHiddenOrder(place,relativeTo:number)
    }
    @objc func reloadPositionHiddenSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-24000,y:-24000));reloadPositionHiddenSheet(sheet,completionHandler:completionHandler)
    }
}
@MainActor @main enum CompareReloadPositionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func phase(_ name:String){print("Compare Reload: "+name);fflush(stdout)}
    static func wait(line:Int = #line,diagnostic:()->String = {""},_ predicate:()->Bool)async throws {
        for _ in 0..<3000 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Compare Reload timeout at \(line): "+diagnostic())
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func editor(_ owner:FileComparisonWindowController,base:Bool=false)throws->NSTextView {
        try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()==(base ? "Base file":"Destination file") && $0.window === owner.window},"Actual owned native editor missing")
    }
    static func ready(_ owner:FileComparisonWindowController)async throws {
        try await wait(diagnostic:{viewportWitness(owner)}) {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            let m=owner.model
            guard let window=owner.window,m.window === window,window.attachedSheet==nil,NSApp.modalWindow==nil,
                  !m.busy,!m.filtering,!m.hasPendingEditorChoice,!m.confirmingQuit,!m.initialNavigationPending,!m.reloadPositionPending,!m.lineWrapping.isGeometryPending,
                  let view=try? editor(owner),let scroll=view.enclosingScrollView,m.ownsViewport(scroll,base:false),m.ownsEditor(scroll,base:false),scroll.contentSize.height>32 else{return false}
            let cells=m.displayCells(base:false),expected=cells.map(\.displayText).joined(separator:"\n")+(cells.isEmpty ? "":"\n")
            return view.string.utf8.elementsEqual(expected.utf8)
        }
        try require(owner.model.error==nil,"Load failed: "+(owner.model.error ?? "nil"))
        // Native layout and queued coordinate requests drain before measuring.
        await Task.yield();owner.window?.contentView?.layoutSubtreeIfNeeded()
    }
    static func acknowledgeError(_ owner:FileComparisonWindowController)async throws {
        let message=try unwrap(owner.model.error,"Expected comparison error missing")
        var captured:NSWindow?,button:NSButton?
        try await wait(diagnostic:{"Expected native error: "+message+"; "+viewportWitness(owner)}) {
            guard let sheet=owner.window?.attachedSheet,let content=sheet.contentView else{return false}
            let labels=views(content).compactMap{$0 as? NSTextField}.map(\.stringValue)
            guard labels.contains(where:{$0.contains("Comparison failed") || $0.contains(message)}),
                  let ok=views(content).compactMap({$0 as? NSButton}).first(where:{$0.title=="OK" && $0.isEnabled}) else{return false}
            captured=sheet;button=ok;return true
        }
        button?.performClick(nil)
        try await wait(diagnostic:{"Native error acknowledgment: "+viewportWitness(owner)}) {
            owner.model.error==nil && captured?.sheetParent==nil && owner.window?.attachedSheet==nil
        }
    }
    static func ranges(_ view:NSTextView)->[NSRange] {MergeLineEndings.lineRanges(in:view.string)}
    static func place(_ owner:FileComparisonWindowController,line:Int=90,column:Int=18,top:Int=60)throws {
        let view=try editor(owner),scroll=try unwrap(view.enclosingScrollView,"Missing native viewport"),lines=ranges(view)
        try require(lines.indices.contains(line) && lines.indices.contains(top),"Position fixture too short")
        owner.model.cancelDeferredNavigation();owner.model.activatePane(base:false)
        view.setSelectedRange(.init(location:lines[line].location+column,length:0));owner.window?.makeFirstResponder(view)
        let layout=try unwrap(view.layoutManager,"Missing layout"),container=try unwrap(view.textContainer,"Missing container")
        layout.ensureLayout(for:container)
        let rect=layout.lineFragmentRect(forGlyphAt:layout.glyphIndexForCharacter(at:lines[top].location),effectiveRange:nil)
        let proposed=NSRect(x:35,y:rect.minY+view.textContainerOrigin.y,width:scroll.contentView.bounds.width,height:scroll.contentView.bounds.height)
        scroll.contentView.scroll(to:scroll.contentView.constrainBoundsRect(proposed).origin);scroll.reflectScrolledClipView(scroll.contentView)
    }
    static func assertPosition(_ owner:FileComparisonWindowController,line:Int=90,column:Int=18,top:Int=60,horizontal:CGFloat=0)throws {
        let view=try editor(owner),scroll=try unwrap(view.enclosingScrollView,"Missing viewport"),lines=ranges(view)
        let selected=view.selectedRange(),row=max(0,MergeLineEndings.lineNumber(in:view.string,utf16Offset:selected.location)-1)
        let viewport=MergeLocatorScrolling.viewport(scroll).rows.lowerBound
        try require(row==line && selected.location-lines[row].location==column && selected.length==0,
                    "Reload lost logical caret: row=\(row) offset=\(selected) expected=\(line):\(column)")
        try require(abs(viewport-top)<=1 && abs((scroll.contentView.bounds.minX+(horizontal==0 ? scroll.contentView.contentInsets.left:0))-horizontal)<0.5,
                    "Reload lost top line / horizontal reset: top=\(viewport) expected=\(top), bounds=\(scroll.contentView.bounds)")
        if horizontal==0 {try assertLinked(owner)}
    }
    static func viewportWitness(_ owner:FileComparisonWindowController)->String {
        let model=owner.model
        let panes=[true,false].map { side -> String in
            guard let view=try? editor(owner,base:side),let scroll=view.enclosingScrollView else{return "\(side):missing"}
            let clip=scroll.contentView,bounds=clip.bounds
            let proposed=NSRect(x:0,y:bounds.minY,width:bounds.width,height:bounds.height)
            return "base=\(side),owned=\(model.ownsViewport(scroll,base:side)),editor=\(model.ownsEditor(scroll,base:side)),bounds=\(bounds),insets=\(clip.contentInsets),documentFrame=\(String(describing:scroll.documentView?.frame)),textOrigin=\(view.textContainerOrigin),selected=\(view.selectedRange()),cells=\(model.displayCells(base:side).count),viewUTF16=\(view.string.utf16.count),currentText=\(view.string.utf8.elementsEqual((model.displayCells(base:side).map(\.displayText).joined(separator:"\n")+(model.displayCells(base:side).isEmpty ? "":"\n")).utf8)),constrainedZero=\(clip.constrainBoundsRect(proposed)),characterOffset=\(bounds.minX+clip.contentInsets.left),constrainedLeading=\(clip.constrainBoundsRect(NSRect(x:-clip.contentInsets.left,y:bounds.minY,width:bounds.width,height:bounds.height))),hScroller=\(String(describing:scroll.horizontalScroller?.doubleValue))"
        }
        return "document=\(model.document != nil),ownerPresent=\(owner.window != nil),modelOwnerCurrent=\(owner.window != nil && model.window === owner.window),ownerVisible=\(owner.window?.isVisible == true),ownerSheet=\(owner.window?.attachedSheet != nil),initialNavigation=\(model.initialNavigationPending),choices=\(model.hasPendingEditorChoice),confirmingQuit=\(model.confirmingQuit),error=\(String(reflecting:model.error)),pending=\(model.reloadPositionPending),geometry=\(model.lineWrapping.isGeometryPending),busy=\(model.busy),filtering=\(model.filtering),mode=\(model.onePaneActive),alignment=\(model.alignmentGeneration),paths=\(String(reflecting:model.document?.base.path))/\(String(reflecting:model.document?.destination.path)),bytes=\(model.document?.base.bytes.count ?? -1)/\(model.document?.destination.bytes.count ?? -1),panes=[\(panes.joined(separator:"; "))]"
    }
    static func assertLinked(_ owner:FileComparisonWindowController)throws {
        let left=try unwrap(editor(owner,base:true).enclosingScrollView,"Missing left viewport")
        let right=try unwrap(editor(owner).enclosingScrollView,"Missing right viewport")
        try require(abs(left.contentView.bounds.minY-right.contentView.bounds.minY)<0.5 && abs(left.contentView.bounds.minX+left.contentView.contentInsets.left)<0.5 && abs(right.contentView.bounds.minX+right.contentView.contentInsets.left)<0.5,
                    "Reload desynchronized aligned panes: left=\(left.contentView.bounds), right=\(right.contentView.bounds)")
    }
    static func f5Event(_ owner:FileComparisonWindowController,flags:NSEvent.ModifierFlags = .function)throws->NSEvent {
        let window=try unwrap(owner.window,"Missing native window")
        return try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{f708}",charactersIgnoringModifiers:"\u{f708}",isARepeat:false,keyCode:96),"F5 event missing")
    }
    static func f5(_ owner:FileComparisonWindowController)throws {
        let window=try unwrap(owner.window,"Missing native window")
        let event=try f5Event(owner)
        let handled=window.performKeyEquivalent(with:event)
        try require(handled,"Actual F5 was not handled: type=\(event.type),key=\(event.keyCode),flags=\(event.modifierFlags.rawValue),eventWindow=\(String(describing:event.window)),eventWindowCurrent=\(event.window === window),number=\(window.windowNumber),delegateCurrent=\((window.delegate as? FileComparisonWindowController) === owner),nativeModelCurrent=\((window as? FileComparisonNativeWindow)?.model === owner.model),menuKeyCurrent=\(owner.editorCommandMenu?.keyWindow() === window),NSAppKeyCurrent=\(NSApp.keyWindow === window),fieldEditor=\((window.firstResponder as? NSTextView)?.isFieldEditor == true),modal=\(NSApp.modalWindow != nil),replacement=\(owner.preparingReplacement),openWorkflow=\(owner.editorOpenWorkflow != nil),context=\(owner.model.contextCommandsAllowed),state="+viewportWitness(owner))
    }
    static func menuReload(_ owner:FileComparisonWindowController)throws {
        let item=try unwrap(owner.window?.toolbar?.items.first{$0.itemIdentifier==MergeToolbarCommand.reload.identifier}?.menuFormRepresentation,"Actual Reload menu representation missing")
        let action=try unwrap(item.action,"Reload menu has no action")
        try require(item.image != nil && NSApp.sendAction(action,to:item.target,from:item),"Actual Reload menu dispatch failed")
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ReloadPosition."+UUID().uuidString,prefs:UserDefaults
        var owners:[FileComparisonWindowController]=[]
        var index=Data(),head=Data(),expectedRight=Data()
        var left:URL {repo.root.appendingPathComponent("left.txt")};var right:URL {repo.root.appendingPathComponent("right.txt")}
        var repo:GitRepository {GitRepository(root:root.appendingPathComponent("repository"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        var original:String {(0..<160).map{"row \($0) café 雪 🐢 "+String(repeating:"wide ",count:50)}.joined(separator:"\n")+"\n"}
        var mine:String {original.replacingOccurrences(of:"row 4 café",with:"edit 4 café")}
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"TurtleGitMerge.WrapLines");prefs.set(false,forKey:"TurtleGitMerge.OnePane");MergeComparisonOptions.exact.save(to:prefs);MergeGeneralPreferences(firstDifference:true,firstConflict:true).save(to:prefs)}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true)
            _=try await repo.run(["init","-b","main"])
            for(k,v)in[("user.name","Reload QA"),("user.email","reload@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",k,v])}
            try Data("untouched\n".utf8).write(to:repo.root.appendingPathComponent("tracked.txt"))
            try Data(original.utf8).write(to:left);expectedRight=Data(mine.utf8);try expectedRight.write(to:right)
            try await repo.stage(["tracked.txt","left.txt","right.txt"]);_=try await repo.commit(message:"fixture")
            index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"));head=try await repo.run(["rev-parse","HEAD"]).stdout
        }
        func make()async throws->FileComparisonWindowController {
            let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:prefs)
            owners.append(owner)
            // A prohibited, invisible receiver has no real AppKit key window.
            // Supply this actual owned menu/window identity for nil-window
            // synthetic events; foreign event and model-owner fences stay real.
            owner.editorCommandMenu?.keyWindow={ [weak owner] in owner?.window }
            owner.model.commentProfileURL=root.appendingPathComponent("no-profiles");owner.model.saveFolderAccess.requireScope=false
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.window?.orderFront(nil)
            owner.model.load();try await ready(owner);return owner
        }
        func unchanged()async throws {
            try require(try Data(contentsOf:left)==Data(original.utf8) && Data(contentsOf:right)==expectedRight,"Reload changed source bytes")
            let current=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(current==head && Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Reload changed HEAD/index")
        }
        func clean()async throws {
            for owner in owners {owner.close()}
            for window in NSApp.windows {if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)};window.orderOut(nil);window.close()}
            try await wait{FileListComparisonSession.activeOperations==0 && MergeRegexOperations.activeRequests==0 && MergeExternalReloadCoordinator.activeRequests==0 && FileComparisonWindowModel.activeProjectionChoices==0 && owners.allSatisfy{!$0.model.mergeToolHasPendingWork} && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil}}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func verify(_ c:Context)async throws {
        phase("first read failure and F5 recovery use fresh navigation")
        let parkedInitial=c.root.appendingPathComponent("initial-right.txt")
        try FileManager.default.moveItem(at:c.right,to:parkedInitial);try FileManager.default.createDirectory(at:c.right,withIntermediateDirectories:false)
        let failed=FileComparisonWindowController(comparison:try WorkingFileComparison(base:c.left,destination:c.right),permissions:[],preferences:c.prefs)
        c.owners.append(failed);failed.editorCommandMenu?.keyWindow={ [weak failed] in failed?.window };failed.model.commentProfileURL=c.root.appendingPathComponent("no-profiles")
        failed.window?.orderFront(nil);failed.model.load()
        try await wait{!failed.model.busy && failed.model.error != nil}
        try require(failed.model.document==nil,"First-read failure adopted a document")
        try await acknowledgeError(failed)
        try FileManager.default.removeItem(at:c.right);try FileManager.default.moveItem(at:parkedInitial,to:c.right)
        let failedWindow=try unwrap(failed.window,"Failed-read owner missing")
        try require(!failedWindow.performKeyEquivalent(with:try f5Event(failed,flags:[.function,.shift])) && !failed.model.busy && failed.model.document==nil,"Modified F5 incorrectly dispatched fresh Retry")
        failed.model.window=nil
        let detachedHandled=failedWindow.performKeyEquivalent(with:try f5Event(failed))
        failed.model.window=failedWindow
        try require(!detachedHandled && !failed.model.busy && failed.model.document==nil,"Detached model accepted windowless F5 Retry")
        try f5(failed);try await ready(failed)
        try require(MergeLineEndings.lineNumber(in:try editor(failed).string,utf16Offset:try editor(failed).selectedRange().location)==5,"F5 first-success recovery suppressed fresh navigation")
        failed.close()
        phase("fresh initial navigation")
        let owner=try await c.make(),m=owner.model
        try require(MergeLineEndings.lineNumber(in:try editor(owner).string,utf16Offset:try editor(owner).selectedRange().location)==5,"Fresh Open ignored first-difference preference")
        phase("actual F5 and Reload menu retain Unicode caret and viewport")
        try place(owner);try f5(owner);try await ready(owner);try assertPosition(owner)
        try place(owner,line:100,column:12,top:70);try menuReload(owner);try await ready(owner);try assertPosition(owner,line:100,column:12,top:70)
        phase("accepted external question retains position after real sheet detachment")
        let watch=try unwrap(owner.externalReload,"External coordinator missing")
        watch.isActive={_ in true};watch.delayNanoseconds=1
        var external:NSAlert?,externalReply:((NSApplication.ModalResponse)->Void)?
        watch.presentQuestion={alert,parent,reply in external=alert;externalReply=reply;parent.beginSheet(alert.window)}
        try place(owner)
        c.expectedRight=Data(c.mine.replacingOccurrences(of:"row 20 café",with:"outside 20 café").utf8);try c.expectedRight.write(to:c.right)
        watch.activate();try await wait{external?.window.sheetParent === owner.window}
        externalReply?(.alertFirstButtonReturn);try await ready(owner);try await wait{external?.window.sheetParent==nil && !watch.hasPendingWork};try assertPosition(owner)
        phase("failed external read keeps presentation, accepted retry restores position")
        external=nil;try place(owner)
        c.expectedRight=Data(c.mine.replacingOccurrences(of:"row 21 café",with:"retry 21 café").utf8);try c.expectedRight.write(to:c.right)
        watch.activate();try await wait{external?.window.sheetParent === owner.window}
        let parked=c.root.appendingPathComponent("parked-right.txt")
        try FileManager.default.moveItem(at:c.right,to:parked);try FileManager.default.createDirectory(at:c.right,withIntermediateDirectories:false)
        let oldDocument=m.document?.destination.bytes
        externalReply?(.alertFirstButtonReturn)
        try await wait{!m.busy && !watch.hasPendingWork && m.error != nil && external?.window.sheetParent==nil}
        try require(m.document?.destination.bytes==oldDocument,"Failed external read replaced accepted document")
        try await acknowledgeError(owner)
        try assertPosition(owner,horizontal:35)
        try FileManager.default.removeItem(at:c.right);try FileManager.default.moveItem(at:parked,to:c.right)
        m.error=nil;external=nil;watch.activate();try await wait{external?.window.sheetParent === owner.window}
        externalReply?(.alertFirstButtonReturn);try await ready(owner);try await wait{!watch.hasPendingWork};try assertPosition(owner)
        watch.isActive={_ in false};watch.reset()
        phase("fresh input reinterpretation uses configured initial navigation")
        m.reloadInputEncoding(.utf8,base:false);try await ready(owner)
        try require(MergeLineEndings.lineNumber(in:try editor(owner).string,utf16Offset:try editor(owner).selectedRange().location)==5,"Input decoder incorrectly retained Reload position")
        phase("Reload restores active difference and transfer command metadata")
        try place(owner,line:4,column:2,top:0);try f5(owner);try await ready(owner);try assertPosition(owner,line:4,column:2,top:0)
        try require(m.difference==0 && m.transferRows==nil,"Reload left current difference or stale transfer selection detached from collapsed native caret")
        phase("one-pane Added/Removed origin and common-row transitions")
        let beforeOnePane=c.expectedRight
        m.switchPaneMode(true);try await ready(owner)
        func selectCombined(base:Bool?)throws {
            let combined=try unwrap(m.combined,"Combined projection missing")
            let row=try unwrap(combined.rows.indices.first { index in
                let value=combined.rows[index]
                guard let pair=m.alignment?.rows[value.alignmentRow] else{return false}
                if let base {return value.base==base && !value.cell.state.isUnchanged && (base ? pair.base.lineNumber:pair.destination.lineNumber)==5}
                return value.cell.state.isUnchanged && pair.destination.lineNumber==5
            },"Required one-pane source row missing")
            try place(owner,line:row,column:2,top:0)
        }
        func assertCombined(base:Bool?)throws {
            let view=try editor(owner),row=MergeLineEndings.lineNumber(in:view.string,utf16Offset:view.selectedRange().location)-1
            let combined=try unwrap(m.combined,"Combined projection missing after Reload")
            try require(combined.rows.indices.contains(row),"Reload selected outside combined rows")
            let value=combined.rows[row],pair=try unwrap(m.alignment?.rows[value.alignmentRow],"Selected pair missing")
            if let base {try require(value.base==base && !value.cell.state.isUnchanged && (base ? pair.base.lineNumber:pair.destination.lineNumber)==5,"One-pane Reload aliased Added/Removed source origin")}
            else {try require(value.cell.state.isUnchanged && pair.base.lineNumber==5 && pair.destination.lineNumber==5,"Removed→common Reload jumped to another removed block")}
        }
        for origin in [false,true] {try selectCombined(base:origin);try f5(owner);try await ready(owner);try assertCombined(base:origin)}
        try selectCombined(base:true);c.expectedRight=Data(c.original.utf8);try c.expectedRight.write(to:c.right)
        try f5(owner);try await ready(owner);try assertCombined(base:nil)
        c.expectedRight=Data(c.mine.utf8);try c.expectedRight.write(to:c.right)
        try f5(owner);try await ready(owner);try assertCombined(base:false)
        c.expectedRight=beforeOnePane;try c.expectedRight.write(to:c.right);try f5(owner);try await ready(owner)
        m.switchPaneMode(false);try await ready(owner)
        phase("dirty Cancel, denied Save, Discard and successful Save")
        m.activatePane(base:false);m.editingEnabled=true;try await wait{m.canTransfer(toBase:false)}
        var question:NSAlert?,reply:((NSApplication.ModalResponse)->Void)?
        m.presentProjectionQuestion={alert,parent,answer in question=alert;reply=answer;parent.beginSheet(alert.window)}
        func answer(_ title:String,expectSaveFailure:Bool=false)async throws {
            let captured=try unwrap(question,"Missing actual dirty question "+title)
            let index=try unwrap(captured.buttons.firstIndex{$0.title==title},"Missing dirty choice "+title)
            reply?(.init(rawValue:NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+index))
            // Published choice completion can precede AppKit's sheet release.
            // Retain this exact question until both ownership links detach.
            try await wait(diagnostic:{"Dirty answer "+title+" parent=\(String(describing:captured.window.sheetParent)); "+viewportWitness(owner)}) {
                captured.window.sheetParent==nil && NSApp.modalWindow==nil &&
                    (owner.window?.attachedSheet==nil || expectSaveFailure && m.error != nil && owner.window?.attachedSheet !== captured.window)
            }
        }
        try editor(owner).insertText("draft",replacementRange:.init(location:0,length:0));try await ready(owner);try place(owner)
        let draft=m.draftText(base:false),generation=m.alignmentGeneration
        try f5(owner);try await wait{question?.window.sheetParent === owner.window};try await answer("Cancel");try await ready(owner)
        try require(m.draftText(base:false)==draft && m.alignmentGeneration==generation && m.dirty,"Cancel lost draft or history");try assertPosition(owner,horizontal:35)
        question=nil
        c.expectedRight=Data(c.mine.replacingOccurrences(of:"row 30 café",with:"save denied 30 café").utf8);try c.expectedRight.write(to:c.right)
        try f5(owner);try await wait{question?.window.sheetParent === owner.window};try await answer("Save",expectSaveFailure:true)
        try await wait(diagnostic:{viewportWitness(owner)}){!m.hasPendingEditorChoice && !m.confirmingQuit && !m.busy && m.error != nil && question?.window.sheetParent==nil}
        try await acknowledgeError(owner)
        try require(m.draftText(base:false)==draft && m.alignmentGeneration==generation && m.dirty,"Failed save adopted a reload");try assertPosition(owner,horizontal:35)
        m.error=nil;question=nil;try f5(owner);try await wait{question?.window.sheetParent === owner.window};try await answer("Don’t Save");try await ready(owner);try assertPosition(owner)
        try require(!m.dirty,"Discard kept draft")
        m.activatePane(base:false);m.editingEnabled=true;try await wait{m.canTransfer(toBase:false)}
        try editor(owner).insertText("saved",replacementRange:.init(location:0,length:0));try await ready(owner);try place(owner)
        let saved=m.draftText(base:false),encoding=try unwrap(m.document?.destination.encoding,"Encoding missing")
        question=nil;try f5(owner);try await wait{question?.window.sheetParent === owner.window};try await answer("Save");try await ready(owner)
        c.expectedRight=try encoding.encode(saved);try require(!m.dirty,"Save/reload left a draft");try assertPosition(owner)
        phase("removed lines clamp current caret and old top line")
        try place(owner,line:140,column:80,top:110)
        c.expectedRight=Data((0..<45).map{"short \($0) 雪"}.joined(separator:"\n").utf8);try c.expectedRight.write(to:c.right)
        try f5(owner);try await ready(owner)
        let view=try editor(owner),row=MergeLineEndings.lineNumber(in:view.string,utf16Offset:view.selectedRange().location)-1,cells=m.displayCells(base:false)
        try require(cells.indices.contains(row) && cells[row].lineNumber==45 && view.selectedRange().length==0,"Removed source lines did not clamp caret to final real source row")
        try require(abs(view.enclosingScrollView!.contentView.bounds.minX+view.enclosingScrollView!.contentView.contentInsets.left)<0.5,"Clamped reload retained horizontal offset: "+viewportWitness(owner));try assertLinked(owner)
        phase("retired dirty reload refuses late affirmative callback")
        m.activatePane(base:false);m.editingEnabled=true;try await wait{m.canTransfer(toBase:false)}
        view.insertText("late",replacementRange:.init(location:0,length:0));try await ready(owner)
        question=nil;try f5(owner);try await wait{question?.window.sheetParent === owner.window}
        let accepted=m.document,late=reply;owner.close();late?(.alertFirstButtonReturn);late?(.alertSecondButtonReturn)
        try await wait{!m.mergeToolHasPendingWork && question?.window.sheetParent==nil}
        try require(m.document?.destination.bytes==accepted?.destination.bytes,"Retired reload adopted late response")
        let replacement=try await c.make();try require(MergeLineEndings.lineNumber(in:try editor(replacement).string,utf16Offset:try editor(replacement).selectedRange().location)==1,"New document inherited retired position")
        try await c.unchanged()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.reloadPositionHiddenOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,hiddenSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.reloadPositionHiddenSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,hidden);method_exchangeImplementations(sheet,hiddenSheet)
        defer{method_exchangeImplementations(sheet,hiddenSheet);method_exchangeImplementations(order,hidden)}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {try await c.seed();try await verify(c);try await c.clean();print("PASS editor Reload compare")}
        catch {do{try await c.clean()}catch{fputs("Reload cleanup failed: \(error)\n",stderr)};throw error}
    }
}
