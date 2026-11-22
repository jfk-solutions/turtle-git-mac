// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

/// Real native report/menu controls over a private two-parent Git history and
/// working index. External launch, deletion and LFS server operations are not run.
@MainActor enum LogFileContextVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"Log file report \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func wait(_ message:String,window:NSWindow?=nil,_ condition:()->Bool)async throws {
        for _ in 0..<3000 {window?.contentView?.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Log file report timeout: "+message)
    }
    static func find(_ menu:NSMenu,_ title:String)->NSMenuItem? {
        for item in menu.items {if item.title==title{return item};if let child=item.submenu,let result=find(child,title){return result}}
        return nil
    }
    static func bold(_ item:NSMenuItem?)->Bool {
        guard let title=item?.attributedTitle,title.length>0,let font=title.attribute(.font,at:0,effectiveRange:nil) as? NSFont else{return false}
        return NSFontManager.shared.traits(of:font).contains(.boldFontMask)
    }
    static func icons(_ menu:NSMenu)throws {
        for item in menu.items where !item.isSeparatorItem {try require(item.image != nil,"Source context icon missing: "+item.title);if let child=item.submenu {try icons(child)}}
    }
    static func send(_ item:NSMenuItem)throws {
        let action=try unwrap(item.action,"Missing menu action: "+item.title)
        try require(NSApp.sendAction(action,to:item.target,from:item),"Action not dispatched: "+item.title)
    }
    static func key(_ table:NSTableView,_ code:UInt16,flags:NSEvent.ModifierFlags=[],characters:String="",window:NSWindow?=nil)->NSEvent {
        let nativeCharacters=characters.isEmpty ? ([UInt16(125):"\u{f701}",126:"\u{f700}",115:"\u{f729}",119:"\u{f72b}"][code] ?? characters):characters
        return NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:(window ?? table.window)!.windowNumber,context:nil,characters:nativeCharacters,charactersIgnoringModifiers:nativeCharacters,isARepeat:false,keyCode:code)!
    }
    static func header(_ table:NSTableView)throws->NSMenu {
        let menu=try unwrap(table.headerView?.menu,"Native header menu missing");menu.delegate?.menuNeedsUpdate?(menu);return menu
    }
    static func pointerMenu(_ table:LogChangedFileNativeTable,row:Int,column:StatusListColumn)throws->NSMenu {
        let index=try unwrap(table.tableColumns.firstIndex{$0.identifier.rawValue==column.rawValue && !$0.isHidden},"Pointed column not visible")
        let location=table.convert(NSPoint(x:table.rect(ofColumn:index).midX,y:table.rect(ofRow:row).midY),to:nil)
        let event=NSEvent.mouseEvent(with:.rightMouseDown,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:table.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        let menu=try unwrap(table.menu(for:event),"Native pointed menu missing");menu.delegate?.menuNeedsUpdate?(menu);return menu
    }
    static func answer(_ owner:NSWindow,_ title:String)throws {
        let sheet=try unwrap(owner.attachedSheet,"Column reset sheet missing")
        let button=try unwrap(views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title==title},"Column reset response missing")
        button.performClick(nil)
    }
    /// A prohibited, offscreen receiver cannot become the desktop key window.
    /// As in the retained Browser native activation fixture, inject only this
    /// owned window's public key-state getter around the actual table mouse
    /// tracker. Invisible SwiftUI host/window delivery is outside this boundary.
    /// Other windows keep their original getter; this proves native routing,
    /// not physical focus/desktop acceptance.
    static func sendOwnedDoubleClick(_ table:LogChangedFileNativeTable,down:NSEvent,up:NSEvent,foreign:NSWindow)throws {
        let window=try unwrap(table.window,"Double-click target detached")
        try require(window.canBecomeKey && table.acceptsFirstResponder && window.firstResponder===table,"Target window/table cannot own native key input")
        try require(down.window===window && up.window===window && down.clickCount==2 && up.clickCount==2,"Double-click event ownership differs")
        let selector=#selector(getter:NSWindow.isKeyWindow)
        let method=try unwrap(class_getInstanceMethod(NSWindow.self,selector),"Missing native key-window getter")
        let original=method_getImplementation(method),foreignBefore=foreign.isKeyWindow
        let injected:@convention(block)(NSWindow)->Bool={source in
            if source === window{return true}
            typealias Getter=@convention(c)(NSWindow,Selector)->Bool
            return unsafeBitCast(original,to:Getter.self)(source,selector)
        }
        let implementation=imp_implementationWithBlock(injected)
        class_replaceMethod(NSWindow.self,selector,implementation,method_getTypeEncoding(method))
        defer{class_replaceMethod(NSWindow.self,selector,original,method_getTypeEncoding(method));imp_removeBlock(implementation)}
        try require(window.isKeyWindow && foreign.isKeyWindow==foreignBefore,"Owned key-state injection affected another window")
        NSApp.postEvent(up,atStart:true)
        ComparisonToolInvocation.$alternate.withValue(true){table.mouseDown(with:down)}
    }
    /// Observe the real AppKit double-action and forward its exact original
    /// target/selector. No replacement row or model action is injected.
    @MainActor final class DoubleActionObserver:NSObject {
        weak var table:LogChangedFileNativeTable?
        weak var model:LogWindowModel?
        let originalTarget:AnyObject?
        let originalAction:Selector?
        var receipts:[String]=[]
        init(table:LogChangedFileNativeTable,model:LogWindowModel) {self.table=table;self.model=model;originalTarget=table.target;originalAction=table.doubleAction}
        func state()->String {
            guard let table,let model else{return "missing table/model"}
            let event=NSApp.currentEvent
            return "clicked=\(table.clickedRow)/\(table.clickedColumn) selectedRows=\(table.selectedRowIndexes) modelIDs=\(Array(model.selectedFiles).map{String(reflecting:$0)}) mark=\(String(reflecting:model.focusedChangedFile)) ownerAvailable=\(table.ownerAvailable()) inspect=\(model.canInspectHistory) enabled=\(table.isEnabled) visible=\(table.window?.isVisible ?? false) key=\(table.window?.isKeyWindow ?? false) responder=\(String(describing:table.window?.firstResponder)) event=\(String(describing:event?.type)) clicks=\(event?.clickCount ?? -1) flags=\(event?.modifierFlags.rawValue ?? 0) alternate=\(ComparisonToolInvocation.capture) target=\(String(describing:originalTarget)) action=\(String(describing:originalAction))"
        }
        @objc func observe(_ sender:Any?) {
            receipts.append("before "+state())
            guard let originalAction else{receipts.append("missing original doubleAction");return}
            let forwarded=NSApp.sendAction(originalAction,to:originalTarget,from:sender)
            receipts.append("forwarded=\(forwarded) after "+state())
        }
    }
    static func verify(base:URL,git:URL)async throws {
        let base=base.standardizedFileURL,root=base.appendingPathComponent("repository"),suite="TurtleGit.LogFileContext."+UUID().uuidString
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let preferences=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        for key in ["UseLibgit2","EnableLogCache","EnableGravatar"] {preferences.set(false,forKey:key)}
        preferences.set(true,forKey:"LogIncludeWorkingTreeChanges");preferences.set(false,forKey:"ConfirmKillProcess")
        let repository=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        var owner:LogWindowController?,producerOwner:LogWindowModel?,otherWindows:[NSWindow]=[]
        func cleanup()async throws {
            producerOwner?.invalidate();owner?.close();for window in otherWindows {window.close()}
            try await wait("owned Log question/read drainage") {LogWindowModel.activeChangedFileColumnQuestions==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeActionReads==0 && owner?.model.changedFileColumnWorkPending != true}
            try require(owner?.window?.attachedSheet==nil && owner?.window?.isVisible != true,"Owned Log window/sheet survived")
            clipboard.releaseGlobally();preferences.removePersistentDomain(forName:suite)
        }
        do {
            _=try await repository.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Log Report QA"),("user.email","report@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
            let paths=["first2.swift","second10.txt","line\nname.md"]
            func write(_ text:String) throws {for path in paths {try Data(text.utf8).write(to:root.appendingPathComponent(path))}}
            try write("base\n");try await repository.stage(paths);_=try await repository.commit(message:"Base")
            _=try await repository.run(["checkout","-b","side"]);try write("side\n");try await repository.stage(paths);_=try await repository.commit(message:"Side")
            let side=try await repository.rebaseCommit("HEAD").hash
            _=try await repository.run(["checkout","main"]);try write("main\n");try await repository.stage(paths);_=try await repository.commit(message:"Main")
            let main=try await repository.rebaseCommit("HEAD").hash
            try write("merged\nextra\n");try await repository.stage(paths)
            let tree=String(decoding:try await repository.run(["write-tree"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
            let merge=String(decoding:try await repository.run(["commit-tree",tree,"-p",main,"-p",side,"-m","Report merge"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
            _=try await repository.run(["reset","--hard",merge])
            let entry=try await repository.rebaseCommit(merge),groups=try await repository.logFileGroups(in:entry)
            try require(groups.count==2 && groups.allSatisfy{$0.files.count==paths.count},"Real parent-group history fixture differs")
            // Prove the actual admitted producer read uses its accepted backend,
            // even while preferences select an executable sentinel backend.
            let helper=base.appendingPathComponent("unexpected-libgit2-helper"),entered=base.appendingPathComponent("unexpected-libgit2-entered")
            let quoted="'"+entered.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
            try ("#!/bin/sh\n: > "+quoted+"\nexit 71\n").write(to:helper,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            let producerRepository=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:true,mask:UInt32.max,helperURL:helper))
            let producer=LogWindowModel(repository:producerRepository,access:nil,labelDefaults:preferences);producerOwner=producer
            preferences.set(true,forKey:"UseLibgit2");preferences.set(NSNumber(value:UInt32.max),forKey:"UseLibgit2_mask")
            try require(producer.canAdmitHistoryReload && producer.reload(acceptedBackend:.init(enabled:false,helperURL:helper)),"Idle producer read was refused")
            try await wait("accepted producer actual history read"){!producer.busy && producer.pendingHistoryLoads==0}
            try require(producer.error==nil && producer.entries.contains{$0.hash==merge} && !FileManager.default.fileExists(atPath:entered.path),"Actual admitted producer read recaptured preference backend")
            let generation=producer.contextMenuGeneration
            producer.referencePickerBlocked=true
            try require(!producer.canAdmitHistoryReload && !producer.reload(acceptedBackend:.init(enabled:false)),"Blocked producer was silently admitted")
            producer.referencePickerBlocked=false
            for _ in 0..<8 {try await Task.sleep(nanoseconds:10_000_000)}
            try require(producer.contextMenuGeneration==generation,"Refused incoming producer became a later generic reload")
            producer.referencePickerBlocked=true;producer.reload()
            try require(producer.contextMenuGeneration==generation,"Generic blocked Refresh ran immediately")
            preferences.set(false,forKey:"UseLibgit2");producer.referencePickerBlocked=false
            try await wait("coalesced generic Refresh"){producer.contextMenuGeneration>generation && !producer.busy && producer.pendingHistoryLoads==0}
            try require(producer.error==nil,"Generic Refresh no longer uses admitted current form")
            producer.invalidate()
            let selectionRole=LogWindowModel(repository:repository,access:nil,selecting:true,labelDefaults:preferences)
            try require(!selectionRole.canReuseForPresentation,"Selection-role Log became ordinary cache owner");selectionRole.invalidate()
            let controller=LogWindowController(repository:repository,access:nil,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)
            owner=controller;let model=controller.model,window=try unwrap(controller.window,"Log window missing")
            model.clipboard=clipboard;model.bare=false;model.entries=[entry];model.selected=[merge];model.fileGroups=groups;model.files=groups.flatMap{group in group.files.map{$0.inParentGroup(group.id)}}
            var comparisons:[([String],Bool)]=[]
            model.onFileComparisons={requests in comparisons.append((requests.flatMap{$0.2},ComparisonToolInvocation.capture))}
            model.onFileCompare={_,_,paths in comparisons.append((paths,ComparisonToolInvocation.capture))}
            model.onFileLog={_,_ in};model.onBlame={_,_ in}
            window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000));controller.showWindow(nil)
            (window as? LogHistoryWindow)?.commandKeyWindow={window}
            try await wait("native file report",window:window){views(window.contentView).contains{$0 is LogChangedFileNativeTable}}
            let table=try unwrap(views(window.contentView).compactMap{$0 as? LogChangedFileNativeTable}.first,"Native file table missing")
            var presented:NSMenu?
            table.presentSelectionMenu={menu,_,_ in presented=menu}
            try await wait("actual parent rows",window:window){table.numberOfRows==8}
            let rows=model.fileTableRows,headerRows=rows.indices.filter{rows[$0].file==nil},fileRows=rows.indices.filter{rows[$0].file != nil}
            try require(table.tableColumns.count==5 && Set(table.tableColumns.map{$0.identifier.rawValue})==Set(StatusListColumn.defaultColumns.map(\.rawValue)),"Log admitted unsupported optional columns")
            try require(!table.floatsGroupRows && headerRows.count==2,"Parent groups became sticky or disappeared")
            for row in headerRows {
                try require(table.delegate?.tableView?(table,isGroupRow:row)==true && table.delegate?.tableView?(table,shouldSelectRow:row)==false,"Parent header became a selectable file")
                let cell=try unwrap(table.delegate?.tableView?(table,viewFor:nil,row:row) as? NSTextField,"Spanning native group cell missing")
                try require(cell.stringValue==rows[row].header && cell.accessibilityRole() == .group,"Native parent header lost text/AX group semantics")
            }
            table.sortDescriptors=[NSSortDescriptor(key:StatusListColumn.path.rawValue,ascending:false)]
            try await wait("native header sort",window:window){model.changedFileSort.first?.order == .reverse}
            try require(model.fileTableRows.filter{$0.header != nil}.map(\.rawID)==rows.filter{$0.header != nil}.map(\.rawID),"Sorting moved/collapsed parent groups")
            table.sortDescriptors=[NSSortDescriptor(key:StatusListColumn.path.rawValue,ascending:true)]
            try await wait("restore native path sort",window:window){model.changedFileSort.first?.order == .forward}
            let samePath=rows.compactMap(\.file).filter{GitReferenceName.equal($0.path,paths[0])}
            try require(samePath.count==2 && GitPathSet(samePath.map(\.id)).count==2,"Parent occurrence identity collapsed")
            table.selectRowIndexes(IndexSet(fileRows.prefix(2)),byExtendingSelection:false);window.makeFirstResponder(table)
            try await wait("selected native IDs",window:window){model.selectedFiles.count==2}
            let columns=table.tableColumns.map(ObjectIdentifier.init),nativeHeader=table.headerView
            for index in fileRows.prefix(3) {table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);model.error="Transient feedback";model.error=nil;model.objectWillChange.send();window.contentView?.layoutSubtreeIfNeeded();try require(table.tableColumns.map(ObjectIdentifier.init)==columns && table.headerView===nativeHeader,"Observed selection/feedback rebuilt native headers")}
            table.selectRowIndexes(IndexSet(fileRows.prefix(2)),byExtendingSelection:false)
            try await wait("multi-row selection",window:window){model.selectedFiles.count==2}
            let pointed=try pointerMenu(table,row:fileRows[0],column:.fileExtension)
            let copyColumn=try unwrap(find(pointed,"Copy \"Extension\" to clipboard"),"Pointed-column Copy missing")
            try require(find(pointed,"Extensions")?.image != nil && bold(find(pointed,"Compare with base")),"Extensions icon/default bold compare missing")
            try send(copyColumn)
            let expected=rows.compactMap(\.file).filter{model.selectedFiles.contains($0.id)}.map{model.changedFileText($0,column:.fileExtension)}.joined(separator:"\r\n")
            try require(clipboard.string(forType:.string)==expected,"Pointed column did not preserve displayed occurrence order")
            clipboard.clearContents();clipboard.setString("one-use",forType:.string);try send(copyColumn);try require(clipboard.string(forType:.string)=="one-use","Consumed menu action ran twice")
            let extensionMenu=try pointerMenu(table,row:fileRows[0],column:.path);try send(try unwrap(find(extensionMenu,"Extensions"),"Extensions command missing"))
            let chosen=model.fileTableRows.compactMap(\.file).filter{model.selectedFiles.contains($0.id)}
            try require(clipboard.string(forType:.string)==chosen.map{StatusListClipboard.fileExtension($0.path,isDirectory:$0.isSubmodule)}.joined(separator:"\n")+"\n","Extensions clipboard differs")
            let staleSelection=try unwrap(find(try pointerMenu(table,row:fileRows[0],column:.path),"Relative paths"),"Selection snapshot missing")
            model.selectedFiles=[rows[fileRows[2]].rawID];clipboard.clearContents();clipboard.setString("stale-selection",forType:.string);try send(staleSelection)
            try require(clipboard.string(forType:.string)=="stale-selection","Changed selection accepted old file receipt")
            table.selectRowIndexes(IndexSet(fileRows.prefix(2)),byExtendingSelection:false);model.selectedFiles=GitPathSet(fileRows.prefix(2).map{rows[$0].rawID})
            let blockedHeader=try unwrap(find(try header(table),"Extension"),"Header visibility action missing")
            let blockedColumns=model.changedFileColumns;model.findBlocked=true;try send(blockedHeader)
            let blockedMenu=try header(table)
            try require(model.changedFileColumns==blockedColumns && blockedMenu.items.isEmpty,"Owned Find did not fence header callbacks/build")
            model.findBlocked=false
            model.changedFileColumns=StatusListColumnSettings(visible:[.path,.status],order:[.status,.path,.removed,.fileExtension,.added],widths:[.path:390])
            try await wait("visible column layout",window:window){table.tableColumns.filter{!$0.isHidden}.map{$0.identifier.rawValue}==["Status","Path"]}
            let allMenu=try pointerMenu(table,row:fileRows[0],column:.path);try send(try unwrap(find(allMenu,"Copy all information to clipboard"),"Copy all missing"))
            let visible:[StatusListColumn]=[.status,.path]
            let allExpected=StatusListClipboard.heading(copy:.all,columns:visible,label:FileListLabels.caption)+chosen.map{file in visible.map{model.changedFileText(file,column:$0)}.joined(separator:"\t")}.joined(separator:"\n")+"\n"
            try require(clipboard.string(forType:.string)==allExpected,"Copy all ignored visible order")
            model.changedFileColumns.save(to:preferences,key:LogWindowModel.changedFileColumnsKey)
            try require(StatusListColumnSettings.load(from:preferences,key:LogWindowModel.changedFileColumnsKey)==model.changedFileColumns,"Changed-file layout was not persisted")
            let stale=try unwrap(find(try pointerMenu(table,row:fileRows[0],column:.path),"Copy all information to clipboard"),"Stale menu missing")
            model.setChangedFileColumn(.added,visible:true);clipboard.clearContents();clipboard.setString("stale-layout",forType:.string);try send(stale);try require(clipboard.string(forType:.string)=="stale-layout","Replaced column epoch accepted old menu")
            window.makeFirstResponder(table);try require(table.accessibilityPerformShowMenu(),"AX Show Menu absent")
            try require(presented != nil && find(presented!,"Copy \"Path\" to clipboard")==nil,"AX reused mouse-pointed subitem")
            presented=nil;try require(table.performKeyEquivalent(with:key(table,109,flags:.shift)),"Shift-F10 absent");try require(presented != nil,"Shift-F10 did not reach native selection menu")
            let text=try unwrap(views(window.contentView).compactMap{$0 as? NSTextView}.first,"Native Log message editor missing")
            window.makeFirstResponder(text);try require(!table.performKeyEquivalent(with:key(table,8,flags:.command,characters:"c")),"File list stole message Cmd-C")
            let search=try unwrap(views(window.contentView).compactMap{$0 as? NSSearchField}.first,"Native Log search field missing")
            search.selectText(nil);try require(!table.performKeyEquivalent(with:key(table,8,flags:.command,characters:"c")),"File list stole search editor Cmd-C")
            let foreign=NSWindow(contentRect:.zero,styleMask:.titled,backing:.buffered,defer:false);foreign.isReleasedWhenClosed=false;otherWindows.append(foreign)
            window.makeFirstResponder(table);(window as? LogHistoryWindow)?.commandKeyWindow={foreign}
            try require(!table.performKeyEquivalent(with:key(table,8,flags:.command,characters:"c")),"Foreign key owner copied Log files")
            (window as? LogHistoryWindow)?.commandKeyWindow={window}
            try require(!table.performKeyEquivalent(with:key(table,8,flags:.command,characters:"c",window:foreign)),"Foreign event window copied Log files")
            table.isHidden=true;try require(!table.accessibilityPerformShowMenu(),"Hidden report exposed AX menu");table.isHidden=false
            // Return visits every selected occurrence, independently of the mark.
            table.selectRowIndexes(IndexSet(fileRows.prefix(2)),byExtendingSelection:false);window.makeFirstResponder(table);comparisons=[]
            ComparisonToolInvocation.$alternate.withValue(true){table.keyDown(with:key(table,36))}
            try require(comparisons.flatMap{$0.0}.count==2 && comparisons.allSatisfy{$0.1},"Return did not compare complete highlighted selection/captured Shift")
            // Actual AppKit double-action dispatch must use clickedRow only.
            let clicked=fileRows[0],clickedColumn=table.column(withIdentifier:.init(StatusListColumn.path.rawValue))
            try require(clickedColumn>=0 && !table.tableColumns[clickedColumn].isHidden,"Double-click Path column is not visible")
            table.scrollRowToVisible(clicked);table.scrollColumnToVisible(clickedColumn);window.contentView?.layoutSubtreeIfNeeded()
            let cellRect=table.frameOfCell(atColumn:clickedColumn,row:clicked),visibleCell=cellRect.intersection(table.visibleRect)
            try require(!visibleCell.isEmpty,"Double-click cell was clipped outside the native viewport")
            let nativePoint=NSPoint(x:visibleCell.midX,y:visibleCell.midY),point=table.convert(nativePoint,to:nil)
            try require(table.row(at:nativePoint)==clicked && table.column(at:nativePoint)==clickedColumn,"Double-click native point does not identify its intended visible row/column")
            let content=try unwrap(window.contentView,"Double-click window content missing")
            let contentParentPoint=content.superview?.convert(point,from:nil) ?? content.convert(point,from:nil)
            let nativeParentPoint=table.superview?.convert(point,from:nil) ?? nativePoint
            let hitDiagnostic="cell=\(cellRect) visibleCell=\(visibleCell) viewport=\(table.visibleRect) tableFrame=\(table.frame) tableBounds=\(table.bounds) nativePoint=\(nativePoint) tableHit=\(String(describing:table.hitTest(nativeParentPoint))) contentHit=\(String(describing:content.hitTest(contentParentPoint))) contentFrame=\(content.frame) contentPoint=\(contentParentPoint) alpha=\(window.alphaValue) ignoresMouse=\(window.ignoresMouseEvents) keyCapable=\(window.canBecomeKey)"
            let stamp=ProcessInfo.processInfo.systemUptime
            let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:.shift,timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:2,pressure:1)!
            let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:.shift,timestamp:stamp+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:3,clickCount:2,pressure:0)!
            let actionObserver=DoubleActionObserver(table:table,model:model)
            comparisons=[]
            do {
                let originalTarget=table.target,originalAction=table.doubleAction
                table.target=actionObserver;table.doubleAction=#selector(DoubleActionObserver.observe(_:))
                defer{table.target=originalTarget;table.doubleAction=originalAction}
                try sendOwnedDoubleClick(table,down:down,up:up,foreign:foreign)
            }
            let doubleDiagnostic="boundary=owned-native-table-mouse-tracker requested=\(clicked)/\(clickedColumn) point=\(point) hit=\(hitDiagnostic) downWindow=\(String(describing:down.window)) eventRow=\(table.row(at:table.convert(down.locationInWindow,from:nil))) eventColumn=\(table.column(at:table.convert(down.locationInWindow,from:nil))) receipts=\(actionObserver.receipts) state=\(actionObserver.state()) comparisons=\(comparisons)"
            fputs("Log native double-action diagnostic: "+String(reflecting:doubleDiagnostic)+"\n",stderr)
            try require(comparisons.flatMap{$0.0}.count==1 && comparisons.allSatisfy{$0.1},"Double-click compared highlights rather than clicked occurrence; "+doubleDiagnostic)
            // Move over the actual nonselectable parent header.
            let lastBefore=headerRows[1]-1,nextAfter=headerRows[1]+1
            table.selectRowIndexes(IndexSet(integer:lastBefore),byExtendingSelection:false);model.focusedChangedFile=model.fileTableRows[lastBefore].rawID;window.makeFirstResponder(table)
            table.keyDown(with:key(table,125));try require(table.selectedRowIndexes==IndexSet(integer:nextAfter) && model.focusedChangedFile==model.fileTableRows[nextAfter].rawID,"Native Down failed to skip group header/retain mark")
            preferences.set(true,forKey:"LogFontForFileListCtrl");preferences.set(30,forKey:"LogFontSize")
            try await wait("native configured font",window:window){(table.view(atColumn:table.column(withIdentifier:.init("Path")),row:fileRows[0],makeIfNecessary:true) as? NSTableCellView)?.textField?.font?.pointSize==30}
            let pathIndex=table.column(withIdentifier:.init("Path")),fit=table.delegate?.tableView?(table,sizeToFitWidthOfColumn:pathIndex) ?? 0
            let sample=model.fileTableRows.compactMap(\.file).map{(model.changedFileText($0,column:.path) as NSString).size(withAttributes:[.font:MessageEditorFont.resolve(name:MessageEditorFont.defaultName,size:30)]).width}.max() ?? 0
            try require(fit>=sample,"Column autosize measured a different font")
            let fitHeader=try unwrap(table.headerView as? LogChangedFileHeader,"Owned native divider handler missing")
            try require(fitHeader.fitDivider(atNativeIndex:pathIndex,useDefault:false) && model.changedFileColumns.widths[.path] != nil,"Native content divider fit was not persisted")
            try require(fitHeader.fitDivider(atNativeIndex:pathIndex,useDefault:true) && model.changedFileColumns.widths[.path]==nil && abs(table.tableColumns[pathIndex].width-460)<0.5,"Native Shift divider did not restore default width/unset persisted override")
            let savedFit=model.changedFileColumns
            let foreignFit=NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:foreign.windowNumber,context:nil,eventNumber:8,clickCount:2,pressure:1)!
            fitHeader.mouseDown(with:foreignFit);try require(model.changedFileColumns==savedFit,"Foreign window divider event changed Log layout")
            table.isHidden=true;try require(!fitHeader.fitDivider(atNativeIndex:pathIndex,useDefault:false),"Hidden report admitted divider fit");table.isHidden=false
            preferences.set(false,forKey:"LogFontForFileListCtrl")
            // Actual reset No and Yes own a sheet and the model work counter.
            let beforeReset=model.changedFileColumns
            try send(try unwrap(find(try header(table),"Reset columns"),"Reset missing"))
            try await wait("Reset No sheet",window:window){window.attachedSheet != nil && model.changedFileColumnWorkPending}
            try require(LogWindowModel.activeChangedFileColumnQuestions==1 && !controller.windowShouldClose(window),"Reset question did not retain close/Quit ownership")
            try answer(window,"No");try await wait("Reset No drain",window:window){!model.changedFileColumnWorkPending && window.attachedSheet==nil}
            try require(model.changedFileColumns==beforeReset && LogWindowModel.activeChangedFileColumnQuestions==0,"Reset No changed columns or leaked worker")
            try send(try unwrap(find(try header(table),"Reset columns"),"Reset Yes missing"));try await wait("Reset Yes sheet",window:window){window.attachedSheet != nil};try answer(window,"Yes")
            try await wait("Reset Yes drain",window:window){!model.changedFileColumnWorkPending && window.attachedSheet==nil}
            try require(model.changedFileColumns==StatusListColumnSettings(),"Reset Yes did not restore five-column defaults")
            let historicalFiles=model.files,historicalGroups=model.fileGroups
            let raw=try RepositoryBrowserGitPath(rawData:Data([0xff,0x2e,0x74,0x78,0x74]))
            let opaque=CommitFile(path:raw.key,oldPath:nil,action:"M",added:1,removed:1,hasStatistics:true,isSubmodule:false)
            model.fileGroups=[];model.files=[opaque];model.selectedFiles=[opaque.id];model.focusedChangedFile=opaque.id
            let rawMenu=LogChangedFileMenus.make(model:model,ids:[opaque.id],column:.path,shift:false)
            try require(find(rawMenu,"Copy displayed names (escaped)") != nil && find(rawMenu,"Reveal in Finder")==nil && find(rawMenu,"Delete")==nil,"Raw historical name bypassed native path restriction")
            let gitlink=CommitFile(path:paths[0],oldPath:nil,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:true)
            model.files=[gitlink];model.selectedFiles=[gitlink.id];model.focusedChangedFile=gitlink.id
            let linkMenu=LogChangedFileMenus.make(model:model,ids:[gitlink.id],column:nil,shift:false)
            try require(find(linkMenu,"Show submodule log") != nil && find(linkMenu,"Blame")==nil && find(linkMenu,"Save revision to…")==nil,"Historical gitlink mask was replaced by ordinary file commands")
            model.files=historicalFiles;model.fileGroups=historicalGroups
            // Working rows come from the actual private index, never fabricated
            // ordinary rows in place of unmerged stages.
            func blob(_ value:String)async throws->String {String(decoding:try await repository.run(["hash-object","-w","--stdin"],input:Data(value.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)}
            let a=try await blob("base\n"),b=try await blob("mine\n"),c=try await blob("theirs\n")
            _=try await repository.run(["update-index","--index-info"],input:Data(("0 "+String(repeating:"0",count:40)+"\t"+paths[0]+"\n100644 "+a+" 1\t"+paths[0]+"\n100644 "+b+" 2\t"+paths[0]+"\n100644 "+c+" 3\t"+paths[0]+"\n").utf8))
            try Data("ordinary change\n".utf8).write(to:root.appendingPathComponent(paths[1]));try Data("untracked\n".utf8).write(to:root.appendingPathComponent("new.txt"))
            try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
            model.reload();try await wait("working history snapshot",window:window){!model.busy && model.pendingHistoryLoads==0 && model.entries.contains{$0.hash.isEmpty}}
            model.select([""]);try await wait("working file details",window:window){!model.busy && model.selectedWorkingTree && model.files.contains{$0.action=="U"} && model.files.contains{$0.path=="new.txt"}}
            let conflict=try unwrap(model.files.first{$0.action=="U"},"Real unmerged row absent"),ordinary=try unwrap(model.files.first{$0.path==paths[1]},"Ordinary changed row absent"),untracked=try unwrap(model.files.first{$0.path=="new.txt"},"Untracked row absent")
            // Match Root's mounted working-file capabilities; Ignore is
            // intentionally absent when no owning callback was provided.
            model.onConflictAction={_,_ in};model.onWorkingFiles={_,_ in};model.onIgnoreFiles={_,_ in}
            model.selectedFiles=[conflict.id];model.focusedChangedFile=conflict.id
            let conflictMenu=LogChangedFileMenus.make(model:model,ids:[conflict.id],column:nil,shift:false)
            try require(bold(find(conflictMenu,"Edit conflict…")) && find(conflictMenu,"Resolved") != nil && find(conflictMenu,"Revert…") != nil,"Conflict menu lost source masks/default")
            model.selectedFiles=[ordinary.id];model.focusedChangedFile=ordinary.id
            let ordinaryMenu=LogChangedFileMenus.make(model:model,ids:[ordinary.id],column:nil,shift:false)
            try require(bold(find(ordinaryMenu,"Compare with base")) && find(ordinaryMenu,"Edit conflict…")==nil && find(ordinaryMenu,"Show log") != nil,"Ordinary working mask differs")
            try icons(ordinaryMenu);try icons(conflictMenu)
            if let mark=model.workingFlagMark([ordinary.id]) {
                for action in IndexFlagAction.allCases where action.isAvailable(for:[mark]) {try require(find(ordinaryMenu,action.rawValue) != nil,"Index flag selection-mark action absent")}
            } else {throw Failure(description:"Actual ordinary index mark missing")}
            for action in model.workingLFSActions([ordinary.id]) {let item=try unwrap(find(ordinaryMenu,action.rawValue),"Available LFS action absent");try require(item.image != nil && item.isEnabled==model.canWorkingLFS([ordinary.id],locked:action == .lock),"LFS action bypassed availability gate")}
            model.selectedFiles=[untracked.id];model.focusedChangedFile=untracked.id
            let addMenu=LogChangedFileMenus.make(model:model,ids:[untracked.id],column:nil,shift:true)
            try require(find(addMenu,"Add") != nil && find(addMenu,"Add to ignore list") != nil && find(addMenu,"Revert…")==nil,"Untracked Add/Ignore/Revert mask differs")
            for mode in [WorkingFileAddMode.executable,.symlink] where model.canWorkingAdd([untracked.id],mode:mode) {try require(find(addMenu,mode.rawValue) != nil,"Captured Shift Add mode missing")}
            let preserveIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            // Forced closure must wait for both native sheet links and the real
            // choose continuation; global Quit sees the same counter.
            try await wait("working report ready",window:window){!model.busy && model.canChangeFileColumns}
            let retiredCopy=try unwrap(find(LogChangedFileMenus.make(model:model,ids:[untracked.id],column:nil,shift:false),"Relative paths"),"Retired menu snapshot missing")
            try require(retiredCopy.isEnabled,"Retirement fixture did not capture an admitted action")
            try send(try unwrap(find(try header(table),"Reset columns"),"Forced reset missing"));try await wait("Forced reset sheet",window:window){window.attachedSheet != nil && model.changedFileColumnWorkPending}
            let child=try unwrap(window.attachedSheet,"Forced reset child absent");var completion=false,completedWithPairedDrain=false
            controller.onClosed={completion=true;completedWithPairedDrain=child.sheetParent==nil && window.attachedSheet==nil && !model.changedFileColumnWorkPending && LogWindowModel.activeChangedFileColumnQuestions==0}
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Global Quit ignored changed-file reset work")
            controller.close();try await wait("forced controller/question completion"){completion}
            clipboard.clearContents();clipboard.setString("retired-owner",forType:.string);try send(retiredCopy)
            try require(clipboard.string(forType:.string)=="retired-owner","Retired Log accepted old menu callback")
            try require(completedWithPairedDrain,"Controller completion preceded actual question/parent drain")
            try require(!table.accessibilityPerformShowMenu() && !table.performKeyEquivalent(with:key(table,8,flags:.command,characters:"c",window:window)),"Retired native report accepted commands")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==preserveIndex,"Report/menu validation mutated working index")
            try require(try await repository.rebaseCommit("HEAD").hash==merge,"Report/menu changed HEAD")
            print("PASS: native Log changed-file five-column report, real parent occurrence IDs/group captions, source file-menu masks/icons/defaults, pointed/Extensions/visible-order clipboard, keyboard/AX/focus boundaries, primary selection, persisted layout/font and paired reset ownership; no external launch, destructive action or LFS server mutation")
        } catch {try? await cleanup();throw error}
        try await cleanup()
    }
}
