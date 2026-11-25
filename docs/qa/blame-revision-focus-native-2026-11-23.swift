// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

@main struct BlameRevisionFocusEntry {
    @MainActor static func main()async {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try await BlameRevisionFocusVerification.verify(base:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        } catch {fputs("Blame revision focus failed: \(error)\n",stderr);exit(1)}
    }
}

@MainActor enum BlameRevisionFocusVerification {
    typealias Prior=BlameSourceMenuVerification
    static func require(_ value:Bool,_ message:String)throws {try Prior.require(value,"Blame revision focus: "+message)}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Prior.Failure(description:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {try await Prior.wait(line:line,ready)}
    static func views(_ owner:NSWindowController)->[NSView] {Prior.views(owner.window?.contentView)}
    static func mouse(_ table:NSTableView,row:Int,column:Int,flags:NSEvent.ModifierFlags=[],line:Int = #line)async throws {
        guard let window=table.window else{throw Prior.Failure(description:"Detached pointer owner")}
        func diagnostic()->String {
            let columns=table.tableColumns.map{"\($0.identifier.rawValue):hidden=\($0.isHidden),width=\($0.width)"}
            let cell=table.tableColumns.indices.contains(column) && (0..<table.numberOfRows).contains(row) ? table.frameOfCell(atColumn:column,row:row):NSRect.zero
            return "caller=\(line) table=\(type(of:table)) row=\(row)/\(table.numberOfRows) column=\(column) columns=\(columns) selected=\(table.selectedRowIndexes) windowVisible=\(window.isVisible) enabled=\(table.isEnabled) hidden=\(table.isHiddenOrHasHiddenAncestor) window=\(window.frame) tableFrame=\(table.frame) bounds=\(table.bounds) visible=\(table.visibleRect) clip=\(String(describing:table.enclosingScrollView?.contentView.bounds)) super=\(String(describing:table.superview?.frame)) cell=\(cell)"
        }
        guard (0..<table.numberOfRows).contains(row),table.tableColumns.indices.contains(column),!table.tableColumns[column].isHidden else {
            throw Prior.Failure(description:"Pointer admission: "+diagnostic())
        }
        var rect=NSRect.zero
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            table.scrollRowToVisible(row);table.scrollColumnToVisible(column);table.layoutSubtreeIfNeeded()
            rect=table.frameOfCell(atColumn:column,row:row).intersection(table.visibleRect)
            if !rect.isEmpty {break}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        try require(!rect.isEmpty && table.window === window && window.isVisible && table.isEnabled && !table.isHiddenOrHasHiddenAncestor,"Pointer target clipped/refused: "+diagnostic())
        if let native=table as? BlameHistoryNativeTable,let coordinator=native.dataSource as? BlameHistoryTable.Coordinator {
            try await wait {window.contentView?.layoutSubtreeIfNeeded();return coordinator.available && table.numberOfRows==coordinator.model.historyEntries.count}
        }
        let point=table.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil),stamp=ProcessInfo.processInfo.systemUptime
        let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:flags,timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:41,clickCount:1,pressure:1)!
        let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:flags,timestamp:stamp+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:42,clickCount:1,pressure:0)!
        let selector=#selector(getter:NSWindow.isKeyWindow),method=class_getInstanceMethod(NSWindow.self,#selector(getter:NSWindow.isKeyWindow))!
        let original=method_getImplementation(method)
        let block:@convention(block)(NSWindow)->Bool={candidate in
            if candidate === window{return true}
            typealias Getter=@convention(c)(NSWindow,Selector)->Bool
            return unsafeBitCast(original,to:Getter.self)(candidate,selector)
        }
        let injected=imp_implementationWithBlock(block)
        class_replaceMethod(NSWindow.self,selector,injected,method_getTypeEncoding(method))
        defer{class_replaceMethod(NSWindow.self,selector,original,method_getTypeEncoding(method));imp_removeBlock(injected)}
        window.makeFirstResponder(table);NSApp.postEvent(up,atStart:true);table.mouseDown(with:down)
    }
    static func key(_ window:NSWindow,code:UInt16,flags:NSEvent.ModifierFlags=[])->NSEvent {
        let scalar:UInt32=[123:0xF702,124:0xF703,125:0xF701,126:0xF700,115:0xF729,119:0xF72B,109:0xF70D][code] ?? 0
        let text=scalar==0 ? "":String(UnicodeScalar(scalar)!)
        return NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    static func verify(base:URL,git:URL)async throws {
        NSApp.setActivationPolicy(.prohibited)
        let base=base.standardizedFileURL,root=base.appendingPathComponent("repository",isDirectory:true),suite="TurtleGit.BlameRevisionFocus."+UUID().uuidString
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Blame.EnableLexer");prefs.set(true,forKey:"Blame.ShowLog")
        let repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false)),path="revision-focus 雪.cpp"
        var owner:BlameWindowController?
        @MainActor func cleanup()async throws {
            owner?.close()
            try await wait {BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameWindowController.activeNavigationOperations==0 && owner?.window?.isVisible != true && owner?.window?.attachedSheet==nil}
            clipboard.releaseGlobally();prefs.removePersistentDomain(forName:suite)
        }
        do {
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Blame focus QA"),("user.email","blame-focus@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            var source=(0..<180).map{"line \($0) stable Unicode 雪🦎"}
            for revision in 0..<13 {
                if revision>0 {source[revision*10]="line \(revision*10) changed in \(revision)"}
                try Data((source.joined(separator:"\n")+"\n").utf8).write(to:root.appendingPathComponent(path))
                try await repo.stage([path]);_=try await repo.commit(message:"Focus revision \(revision)")
            }
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,bytes=try Data(contentsOf:root.appendingPathComponent(path))
            let controller=BlameWindowController(repository:repo,access:nil,path:path,revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
            owner=controller;controller.window?.alphaValue=0;controller.window?.setFrameOrigin(.init(x:-24000,y:-24000));controller.showWindow(nil)
            let model=controller.model,window=controller.window!
            controller.commandKeyWindow={window};model.writeClipboard={text in clipboard.clearContents();clipboard.setString(text,forType:.string)}
            try await wait {window.contentView?.layoutSubtreeIfNeeded();return model.canFind && model.lines.count==180 && model.historyEntries.count==13 && views(controller).contains{$0 is BlameHistoryNativeTable}}
            let history=try unwrap(views(controller).compactMap{$0 as? BlameHistoryNativeTable}.first,"Native history absent")
            let editor=try unwrap(views(controller).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()=="Blame source text"},"Native source absent")
            let gutter=try unwrap(views(controller).compactMap{$0 as? NSTableView}.first{$0.accessibilityIdentifier()=="BlameAttributionTable"},"Native attribution absent")
            let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),entries=model.historyEntries
            let first=entries[0].hash,later=entries[9].hash
            history.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            try await wait {model.selectedLogHashes==[first]}
            editor.setSelectedRange(NSRange(location:3,length:8))
            try await mouse(history,row:9,column:history.column(withIdentifier:.init("message")),flags:.command)
            let line=try unwrap(model.lines.first{$0.hash==later},"Later revision lacks source lines")
            do {try await wait {model.selectedLogHashes==[first,later] && model.focusedHistoryHash==later && model.selection==line.number}}
            catch {
                fputs("Blame pointer selection: selected=\(model.selectedLogHashes),expected=\([first,later]),focused=\(String(reflecting:model.focusedHistoryHash)),expectedFocus=\(later),line=\(model.selection),expectedLine=\(line.number),nativeSelection=\(history.selectedRowIndexes),inputEpoch=\(history.inputEpoch),eventEpoch=\(String(reflecting:history.selectionEventEpoch)),sourceVersion=\(model.sourceVersion),editorRange=\(editor.selectedRange())\n",stderr)
                throw error
            }
            var offset=0
            for text in source.prefix(line.number-1) {offset += (text as NSString).length+1}
            try require(editor.selectedRange()==NSRange(location:offset,length:(source[line.number-1] as NSString).length),"New focused multi-selection did not select its first source line")
            try require(window.firstResponder === history,"History revision selection stole keyboard focus")
            // Deselecting an item still collapses existing text selection but
            // does not navigate to a remaining/lowest selected revision.
            editor.setSelectedRange(NSRange(location:12,length:7))
            try await mouse(history,row:9,column:history.column(withIdentifier:.init("message")),flags:.command)
            try await wait {model.selectedLogHashes==[first]}
            try require(editor.selectedRange().length==0 && editor.selectedRange().location==19,"History deselection did not collapse at the native active caret")
            window.makeFirstResponder(editor);editor.setSelectedRange(NSRange(location:20,length:0))
            editor.keyDown(with:key(window,code:123,flags:.shift))
            try require(editor.selectedRange()==NSRange(location:19,length:1),"Native reversed selection fixture did not move")
            try await mouse(history,row:0,column:history.column(withIdentifier:.init("message")),flags:.command)
            try await wait {model.selectedLogHashes.isEmpty}
            try require(editor.selectedRange()==NSRange(location:19,length:0),"History collapse lost the reversed native active caret")
            history.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            try await wait {model.selectedLogHashes==[first]}
            // Source additive selection must reveal the clicked revision, not
            // its first/earliest still-selected companion. Preserve horizontal
            // position while revealing vertically, including toggle-off.
            let oldHash=entries.last!.hash,oldLine=try unwrap(model.lines.firstIndex{$0.hash==oldHash},"Oldest revision lacks source")
            let scroll=history.enclosingScrollView!
            var point=scroll.contentView.bounds.origin;point.x=40;point.y=0;scroll.contentView.scroll(to:point);scroll.reflectScrolledClipView(scroll.contentView)
            let horizontal=scroll.contentView.bounds.minX
            try await mouse(gutter,row:oldLine,column:gutter.column(withIdentifier:.init("author")),flags:.command)
            try await wait {window.contentView?.layoutSubtreeIfNeeded();return model.selectedLogHashes==[first,oldHash] && model.pendingHistoryReveal==nil}
            try require(NSLocationInRange(12,history.rows(in:history.visibleRect)) && scroll.contentView.bounds.minX==horizontal,"Additive source click revealed lowest selection or lost horizontal origin")
            try await mouse(gutter,row:oldLine,column:gutter.column(withIdentifier:.init("author")),flags:.command)
            try await wait {window.contentView?.layoutSubtreeIfNeeded();return model.selectedLogHashes==[first] && model.pendingHistoryReveal==nil}
            try require(NSLocationInRange(12,history.rows(in:history.visibleRect)),"Source toggle-off did not reveal its clicked revision")
            // Keyboard range extension uses the actual endpoint, while the
            // keyboard/AX context menu retains the whole highlighted set.
            history.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);window.makeFirstResponder(history)
            history.keyDown(with:key(window,code:125,flags:.shift))
            try await wait {model.selectedLogHashes==Set(entries.prefix(2).map(\.hash)) && model.focusedHistoryHash==entries[1].hash && history.selectedRowIndexes==IndexSet([0,1])}
            struct MenuAnchor {
                let point:NSPoint,visible:NSRect,focusedRect:NSRect,lowestRect:NSRect
                let view:ObjectIdentifier,viewType:String,focusedHash:String?,focusedRow:Int?,lowestRow:Int,nativeSelectedRow:Int
                let selectedRows:[Int]
                let selected:Set<String>
            }
            let menuSelection=model.selectedLogHashes
            var anchor:MenuAnchor?,menuCount=0
            model.presentHistoryMenu={_,point,view in
                menuCount += 1
                let lowest=history.selectedRowIndexes.first ?? -1
                anchor=MenuAnchor(point:point,visible:history.visibleRect,
                    focusedRect:history.rect(ofRow:1).intersection(history.visibleRect),lowestRect:lowest>=0 ? history.rect(ofRow:lowest):.zero,
                    view:ObjectIdentifier(view),viewType:String(describing:type(of:view)),focusedHash:model.focusedHistoryHash,
                    focusedRow:history.focusedRevisionRow(),lowestRow:lowest,nativeSelectedRow:history.selectedRow,selectedRows:Array(history.selectedRowIndexes),selected:model.selectedLogHashes)
            }
            try require(history.accessibilityPerformShowMenu(),"Focused history AX menu refused")
            try await wait {menuCount==1}
            let acceptedAnchor=try unwrap(anchor,"AX callback anchor receipt absent")
            let anchorDiagnostic="focusedHash=\(String(describing:acceptedAnchor.focusedHash)) nativeFocusedRow=\(String(describing:acceptedAnchor.focusedRow)) lowestSelectedRow=\(acceptedAnchor.lowestRow) selectedRowProperty=\(acceptedAnchor.nativeSelectedRow) selectedIndexes=\(acceptedAnchor.selectedRows) before=\(menuSelection.sorted()) inside=\(acceptedAnchor.selected.sorted()) after=\(model.selectedLogHashes.sorted()) callbackView=\(acceptedAnchor.viewType)/\(acceptedAnchor.view) history=\(ObjectIdentifier(history)) point=\(acceptedAnchor.point) visible=\(acceptedAnchor.visible) focusedRect=\(acceptedAnchor.focusedRect) lowestRect=\(acceptedAnchor.lowestRect) rowAtBoundary=\(history.row(at:acceptedAnchor.point))"
            print("Blame focused AX receipt: "+anchorDiagnostic)
            try require(acceptedAnchor.selected==menuSelection && model.selectedLogHashes==menuSelection && menuSelection.count==2 && acceptedAnchor.selectedRows==[0,1] && acceptedAnchor.lowestRow==0,"AX changed highlighted set/native projection: "+anchorDiagnostic)
            // Popup coordinates intentionally use the bottom edge of the
            // focused row. row(at:) classifies that edge as the next row or
            // intercell gap, so verify the real callback coordinate contract.
            try require(acceptedAnchor.view==ObjectIdentifier(history) && acceptedAnchor.focusedRow==1 && acceptedAnchor.focusedHash==entries[1].hash && !acceptedAnchor.focusedRect.isEmpty && abs(acceptedAnchor.point.y-acceptedAnchor.focusedRect.maxY)<0.5 && acceptedAnchor.point.x>=acceptedAnchor.visible.minX && acceptedAnchor.point.x<=acceptedAnchor.visible.maxX && abs(acceptedAnchor.point.y-acceptedAnchor.lowestRect.maxY)>0.5,"AX did not anchor focused selected row: "+anchorDiagnostic)
            let selected=model.selectedLogHashes,caret=editor.selectedRange()
            let foreign=NSWindow(contentRect:.init(x:-26000,y:-26000,width:160,height:100),styleMask:[.titled],backing:.buffered,defer:false)
            foreign.isReleasedWhenClosed=false;foreign.alphaValue=0;defer{foreign.close()}
            history.keyDown(with:key(foreign,code:125,flags:.shift))
            try require(model.selectedLogHashes==selected,"Foreign window moved focused revision")
            let field=NSTextField(frame:.init(x:4,y:4,width:120,height:22));window.contentView?.addSubview(field);window.makeFirstResponder(field)
            history.keyDown(with:key(window,code:125,flags:.shift))
            try require(model.selectedLogHashes==selected,"Field editor focus let history navigation run")
            field.removeFromSuperview();window.makeFirstResponder(history)
            history.isHidden=true;history.keyDown(with:key(window,code:125,flags:.shift));try require(!history.accessibilityPerformShowMenu() && model.selectedLogHashes==selected,"Hidden report accepted focus/menu")
            history.isHidden=false
            model.busy=true;history.keyDown(with:key(window,code:125,flags:.shift));model.focusHistory([oldHash],focus:oldHash);model.highlight(oldLine,additive:false)
            try require(model.selectedLogHashes==selected && editor.selectedRange()==caret,"Busy source accepted a stale focus action")
            model.busy=false
            // A snapshot replacement revokes an unconsumed reverse-reveal
            // receipt, without requiring a new Git process or mutating data.
            model.requestHistoryReveal(oldHash)
            try require(model.pendingHistoryReveal != nil,"Owned reveal receipt absent")
            let acceptedSnapshot=model.snapshot;model.snapshot=acceptedSnapshot
            try require(model.pendingHistoryReveal==nil,"Replacement retained an old document reveal")
            controller.close();history.keyDown(with:key(window,code:126));model.focusHistory([oldHash],focus:oldHash)
            try require(model.retired && model.selectedLogHashes==selected,"Retired native focus action changed its document")
            try await cleanup()
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(path))==bytes,"Focus changed Git/source bytes")
        } catch {try? await cleanup();throw error}
        print("PASS: Blame native focused multi-revision history/source synchronization, active-caret collapse, clicked reveal, horizontal retention, keyboard/AX selected-set ownership and close drainage")
    }
}
