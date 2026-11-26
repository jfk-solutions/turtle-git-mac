// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum ConflictReportVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"Conflict report \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func wait(_ message:String,window:NSWindow?=nil,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Conflict report timeout: "+message)
    }
    static func send(_ item:NSMenuItem)throws {
        guard let action=item.action else{throw Failure(description:"Missing action: "+item.title)}
        try require(NSApp.sendAction(action,to:item.target,from:item),"Native menu action was not dispatched: "+item.title)
    }
    static func find(_ menu:NSMenu,_ title:String)->NSMenuItem? {
        for item in menu.items {if item.title==title{return item};if let child=item.submenu,let result=find(child,title){return result}}
        return nil
    }
    static func visible(_ table:NSTableView)->[NSTableColumn] {table.tableColumns.filter{!$0.isHidden}}
    static func header(_ table:NSTableView)throws->NSMenu {
        let menu=try unwrap(table.headerView?.menu,"Missing native header menu")
        menu.delegate?.menuNeedsUpdate?(menu);return menu
    }
    static func event(_ table:NSTableView,key:UInt16,flags:NSEvent.ModifierFlags=[],characters:String="")->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:table.window!.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:key)!
    }
    static func popup(_ table:ConflictReportNativeTable,row:Int,column:StatusListColumn)throws->NSMenu {
        let index=try unwrap(table.tableColumns.firstIndex{$0.identifier.rawValue==column.rawValue && !$0.isHidden},"Missing pointed column")
        let point=table.convert(NSPoint(x:table.rect(ofColumn:index).midX,y:table.rect(ofRow:row).midY),to:nil)
        let event=NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:table.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        let menu=try unwrap(table.menu(for:event),"Native pointer menu missing")
        menu.delegate?.menuNeedsUpdate?(menu);return menu
    }
    static func answer(_ owner:NSWindow,_ title:String)throws {
        let sheet=try unwrap(owner.attachedSheet,"Reset question did not attach")
        let button=try unwrap(views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title==title},"Reset response button missing: "+title)
        button.performClick(nil)
    }
    @MainActor final class Context {
        let base:URL,git:URL,suite="TurtleGit.ConflictReport."+UUID().uuidString
        let preferences:UserDefaults,clipboard=NSPasteboard.withUniqueName()
        let primary=["file10.swift","file2.txt","file1.txt","line\nname.md"]
        var paths:[String] {primary+(0..<22).map{String(format:"extra%02d.txt",$0)}}
        var repo:GitRepository!,head=Data(),index=Data(),bytes:GitPathMap<Data> = [:]
        var resolve:ResolveWindowController?,sync:SynchronizationWindowController?
        var heldRead:CheckedContinuation<[WorkingTreeFile],Error>?,heldToken:OperationCancellation?
        var menu:NSMenu?,popupPoint:NSPoint?,copied=""
        init(base:URL,git:URL){self.base=base;self.git=git;preferences=UserDefaults(suiteName:suite)!;preferences.set(false,forKey:"UseLibgit2");preferences.set(false,forKey:"ConfirmKillProcess");preferences.set(true,forKey:"RememberFileListPosition")}
        func prepare()async throws {
            let root=base.appendingPathComponent("repository");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Conflict Report QA"),("user.email","report@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
            for path in paths {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
            try await repo.stage(paths);_=try await repo.commit(message:"Report baseline")
            func blob(_ value:String)async throws->String {String(decoding:try await repo.run(["hash-object","-w","--stdin"],input:Data(value.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)}
            let baseHash=try await blob("base\n"),mine=try await blob("mine\n"),theirs=try await blob("theirs\n")
            let records=paths.map{"0 "+String(repeating:"0",count:40)+"\t"+$0+"\u{0}100644 "+baseHash+" 1\t"+$0+"\u{0}100644 "+mine+" 2\t"+$0+"\u{0}100644 "+theirs+" 3\t"+$0+"\u{0}"}.joined()
            _=try await repo.run(["update-index","-z","--index-info"],input:Data(records.utf8))
            for (offset,path) in paths.enumerated() {
                let count=offset==0 ? 4:offset==1 ? 70:offset==2 ? 18:offset==3 ? 12:500+offset
                let data=Data(repeating:UInt8(97+offset%20),count:count);bytes[path]=data;try data.write(to:root.appendingPathComponent(path))
                try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000+Double(offset))],ofItemAtPath:root.appendingPathComponent(path).path)
            }
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            let owner=ResolveWindowController(repository:repo,access:nil,paths:[],preferences:preferences);resolve=owner
            owner.model.writeFileClipboard={[weak self] in self?.copied=$0};owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);owner.model.loadInitial()
            try await ConflictReportVerification.wait("Resolve rows",window:owner.window){!owner.model.busy && owner.model.entries.count==self.paths.count && ConflictReportVerification.views(owner.window?.contentView).contains{$0 is ConflictReportNativeTable}}
        }
        func table(_ window:NSWindow?)throws->ConflictReportNativeTable {try ConflictReportVerification.unwrap(ConflictReportVerification.views(window?.contentView).compactMap{$0 as? ConflictReportNativeTable}.first,"Native conflict report missing")}
        func installPopup(_ table:ConflictReportNativeTable) {
            table.commandKeyWindow={[weak table] in table?.window}
            table.presentSelectionMenu={[weak self] menu,point,_ in self?.menu=menu;self?.popupPoint=point}
        }
        func cleanup()async throws {
            heldRead?.resume(throwing:OperationCancellationFailure.cancelled);heldRead=nil
            resolve?.close();sync?.close()
            try await ConflictReportVerification.wait("owned report/question/worker cleanup") {
                ResolveWindowModel.activeOperations==0 && ResolveWindowController.activeReleases==0 && SynchronizationWindowController.activeInlineReleases==0 && StatusWindowModel.activeOperations==0 && self.resolve?.model.reportResetActive != true && self.sync?.model.conflictFileActions.busy != true
            }
            try ConflictReportVerification.require([resolve?.window,sync?.window].compactMap{$0}.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned window/sheet left visible or attached")
            clipboard.releaseGlobally();preferences.removePersistentDomain(forName:suite)
        }
        func noMutations()async throws {
            try ConflictReportVerification.require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Report changed HEAD")
            try ConflictReportVerification.require(try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Report changed index")
            for path in paths {try ConflictReportVerification.require(try Data(contentsOf:repo.root.appendingPathComponent(path))==bytes[path],"Report changed working file: "+path)}
        }
    }
    static func verify(base:URL,git:URL)async throws {
        let context=Context(base:base,git:git)
        do {
            try await context.prepare()
            let owner=try unwrap(context.resolve,"Resolve owner missing"),model=owner.model,window=try unwrap(owner.window,"Resolve window missing"),table=try context.table(owner.window)
            context.installPopup(table)
            try require(visible(table).map{$0.identifier.rawValue}==["check","Path","Extension"],"Resolve source default differs")
            try require(table.tableColumns.count==9 && !model.availableReportColumns.contains(.lfsOwner),"Optional definitions or non-LFS gate differ")
            let headerIdentity=try unwrap(table.headerView,"Native header missing"),columnIdentities=table.tableColumns.map(ObjectIdentifier.init)
            let nativePaths=model.sortedReportEntries.map(\.path)
            let selected=Array(nativePaths.prefix(3));table.selectRowIndexes(IndexSet(integersIn:0..<3),byExtendingSelection:false)
            try await wait("native highlight publication",window:window){model.selection==GitPathSet(selected)}
            model.checked=[]
            try await wait("unchecked selected row views",window:window){
                (0..<selected.count).allSatisfy{(table.view(atColumn:0,row:$0,makeIfNecessary:true) as? NSButton)?.state == .off}
            }
            // Selection does not grant keyboard focus. In particular the
            // default button may still be first responder on the hosted SDK.
            try require(window.makeFirstResponder(nil),"Could not release initial report focus")
            table.keyDown(with:event(table,key:49,characters:" "))
            try require(model.checked.isEmpty,"Unfocused report consumed Space")
            try require(window.makeFirstResponder(table) && window.firstResponder === table,"Native report did not acquire keyboard focus")
            table.keyDown(with:event(table,key:49,characters:" "))
            try await wait("selected-row Space check",window:window){model.checked==GitPathSet(selected) && (table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSButton)?.state == .on}
            table.keyDown(with:event(table,key:49,characters:" "))
            try await wait("selected-row Space uncheck",window:window){model.checked.isEmpty && (table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSButton)?.state == .off}
            let check=try unwrap(table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSButton,"Native row checkbox missing")
            check.performClick(nil)
            try await wait("native selected checkbox",window:window){model.checked==GitPathSet(selected)}
            try require(table.headerView===headerIdentity && table.tableColumns.map(ObjectIdentifier.init)==columnIdentities,"Selection/check updates replaced native headers/columns")

            // Mark changes inside the identical highlighted set must publish.
            let pointed=try popup(table,row:2,column:.fileExtension)
            try await wait("same-selection pointed focus",window:window){model.focusedFilePath==selected[2] && table.selectionMenuRow()==2}
            window.makeFirstResponder(table);context.menu=nil
            table.keyDown(with:event(table,key:109,flags:.shift))
            try require(context.menu != nil,"Shift-F10 did not reach injected native popup")
            let keyboardMenu=try unwrap(context.menu,"Keyboard popup missing")
            try require(find(keyboardMenu,"Copy \"Extension\" to clipboard")==nil,"Keyboard popup retained old pointed column")
            let point=try unwrap(context.popupPoint,"Keyboard popup anchor missing")
            try require(abs(point.y-table.rect(ofRow:2).midY)<table.rowHeight,"Keyboard popup did not follow published selection mark")
            context.menu=nil;try require(table.accessibilityPerformShowMenu() && context.menu != nil,"Accessibility Show Menu did not reach actual popup")
            try send(try unwrap(find(pointed,"Extensions"),"Extensions missing"))
            let expectedExtensions=selected.map{StatusListClipboard.fileExtension($0)}.joined(separator:"\n")+"\n"
            try require(context.copied==expectedExtensions,"Extensions copy differs")
            let columnMenu=try popup(table,row:1,column:.fileExtension)
            try send(try unwrap(find(columnMenu,"Copy \"Extension\" to clipboard"),"Pointed-column copy missing"))
            try require(context.copied==expectedExtensions,"Pointed-column copy differs")
            try send(try unwrap(find(try header(table),"Status"),"Optional Status missing"))
            try await wait("Status column enabled",window:window){visible(table).contains{$0.identifier.rawValue=="Status"}}
            let extensionIndex=try unwrap(table.tableColumns.firstIndex{$0.identifier.rawValue=="Extension"},"Extension definition missing")
            table.moveColumn(extensionIndex,toColumn:1)
            try await wait("native column order persisted",window:window){model.visibleReportColumns.first == .fileExtension}
            let extensionColumn=try unwrap(table.tableColumns.first{$0.identifier.rawValue=="Extension"},"Extension column missing")
            extensionColumn.width=173;table.delegate?.tableViewColumnDidResize?(Notification(name:NSTableView.columnDidResizeNotification,object:table))
            try await wait("native width persistence",window:window){abs((model.reportColumns.widths[.fileExtension] ?? 0)-173)<1}
            let stored=StatusListColumnSettings.load(from:context.preferences,key:ResolveWindowModel.reportColumnsKey)
            try require(stored==model.reportColumns,"Saved Resolve column state differs")
            let allMenu=try popup(table,row:0,column:.fileExtension)
            try send(try unwrap(find(allMenu,"Copy all information to clipboard"),"Copy all missing"))
            let expectedAll=StatusListClipboard.text(model.sortedReportEntries.filter{model.selection.contains($0.path)},root:model.repository.root,copy:.all,visibleColumns:model.visibleReportColumns,label:FileListLabels.caption)
            try require(context.copied==expectedAll,"Copy all lost visible-column order/content")
            let stale=try unwrap(find(try popup(table,row:0,column:.fileExtension),"Extensions"),"Stale menu fixture missing")
            let previous=context.copied;model.hasChild=true
            try await wait("blocking child disables report",window:window){!table.isEnabled}
            try send(stale);try require(context.copied==previous,"Blocked report copied")
            model.hasChild=false
            try await wait("report restored",window:window){table.isEnabled}
            try send(stale);try require(context.copied==previous,"Obsolete blocked popup revived")

            try send(try unwrap(find(try header(table),"File size"),"Optional file-size column missing"))
            try await wait("typed metadata ready",window:window){!model.busy && model.reportMetadata[context.primary[1]]?.size==70}
            table.sortDescriptors=[NSSortDescriptor(key:StatusListColumn.fileSize.rawValue,ascending:true)]
            try await wait("numeric header sort",window:window){model.reportSort == .fileSize && model.sortedReportEntries.prefix(4).map(\.path)==[context.primary[0],context.primary[3],context.primary[2],context.primary[1]]}
            var submitted:[String]=[];model.confirm={_,entries in submitted=entries.map(\.path)}
            model.request(.mine,ids:context.primary)
            try require(submitted==[context.primary[0],context.primary[3],context.primary[2],context.primary[1]],"Resolution request ignored displayed numeric order")
            model.rejectConfirmation()

            model.selection=[model.sortedReportEntries[15].path];model.focusedFilePath=model.sortedReportEntries[15].path
            try await wait("remembered selection rendered",window:window){table.selectedRowIndexes.contains(15)}
            table.scrollRowToVisible(15);let beforeSelection=model.selection,beforeFocus=model.focusedFilePath
            model.load();try await wait("remembered refresh drained",window:window){!model.busy && !model.reportRefresh.hasPendingPosition}
            try require(model.selection==beforeSelection && model.focusedFilePath==beforeFocus && !table.selectedRowIndexes.isEmpty,"Remember=true lost highlight/focus")
            context.preferences.set(false,forKey:"RememberFileListPosition");model.load()
            try await wait("forget refresh drained",window:window){!model.busy && !model.reportRefresh.hasPendingPosition && table.selectedRowIndexes.isEmpty}
            try require(model.selection.isEmpty && model.focusedFilePath==nil && abs(table.visibleRect.minY)<1,"Remember=false retained highlight/focus/scroll")
            context.preferences.set(true,forKey:"RememberFileListPosition")

            let oldHeight=table.rowHeight
            context.preferences.set(true,forKey:"LogFontForFileListCtrl");context.preferences.set("Menlo",forKey:"LogFontName");context.preferences.set(22,forKey:"LogFontSize")
            let pathColumn=try unwrap(table.tableColumns.firstIndex{$0.identifier.rawValue=="Path"},"Path column missing for custom-font fit")
            try await wait("custom native font",window:window){table.rowHeight>oldHeight && (table.view(atColumn:pathColumn,row:0,makeIfNecessary:true) as? NSTableCellView)?.textField?.font?.pointSize==22}
            let fit=try unwrap(table.delegate?.tableView?(table,sizeToFitWidthOfColumn:pathColumn),"Native font auto-size callback missing")
            let font=MessageEditorFont.resolve(name:"Menlo",size:22)
            let expectedFit=model.sortedReportEntries.map{($0.path.replacingOccurrences(of:"\n",with:"↵") as NSString).size(withAttributes:[.font:font]).width+38}.max()!
            try require(abs(fit-expectedFit)<1,"Native column auto-size ignored configured font")
            context.preferences.set(false,forKey:"LogFontForFileListCtrl")

            let prior=model.reportColumns
            try send(try unwrap(find(try header(table),"Reset columns"),"Reset command missing"))
            try await wait("Reset No question",window:window){window.attachedSheet != nil && model.reportResetActive}
            try answer(window,"No")
            try await wait("Reset No drained",window:window){window.attachedSheet==nil && !model.reportResetActive}
            try require(model.reportColumns==prior,"Reset No changed layout")
            try send(try unwrap(find(try header(table),"Reset columns"),"Reset command missing"))
            try await wait("Reset Yes question",window:window){window.attachedSheet != nil}
            try answer(window,"Yes")
            try await wait("Reset Yes default",window:window){window.attachedSheet==nil && !model.reportResetActive && model.reportColumns==ResolveWindowModel.defaultReportColumns}
            // The accepted model change precedes NSViewRepresentable's native
            // column update. Observe that exact projection before asserting it.
            do {
                try await wait("Reset Yes native default projection",window:window) {
                    table.window === window && !table.isHiddenOrHasHiddenAncestor &&
                        visible(table).map{$0.identifier.rawValue}==["check","Path","Extension"]
                }
            } catch {
                let columns=table.tableColumns.map{"\($0.identifier.rawValue):hidden=\($0.isHidden),width=\($0.width)"}
                print("error: Conflict Reset projection expected=[check,Path,Extension],actual=\(columns),sameWindow=\(table.window === window),hidden=\(table.isHiddenOrHasHiddenAncestor),sheet=\(window.attachedSheet != nil),resetActive=\(model.reportResetActive),modelDefault=\(model.reportColumns==ResolveWindowModel.defaultReportColumns)")
                fflush(stdout);throw error
            }
            try require(visible(table).map{$0.identifier.rawValue}==["check","Path","Extension"],"Reset default native order differs")

            // Sync exercises the actual non-grouped report with a real saved
            // changelist, not only synthetic model arrays.
            _=try await context.repo.assignChangelist(paths:[context.paths[0]],name:"Conflicted files")
            let sync=SynchronizationWindowController(repository:context.repo,access:nil,preferences:context.preferences);context.sync=sync
            sync.window?.alphaValue=0;sync.window?.setFrameOrigin(.init(x:-24000,y:-24000));sync.showWindow(nil);sync.model.tab=6
            let actions=sync.model.conflictFileActions;actions.clipboard=context.clipboard
            try await wait("Sync changelist-bearing conflict report",window:sync.window){!sync.model.busy && !actions.busy && actions.files.count==context.paths.count && !actions.fileListRefresh.hasPendingPosition && views(sync.window?.contentView).contains{$0 is ConflictReportNativeTable}}
            let syncTable=try context.table(sync.window);context.installPopup(syncTable)
            try require(visible(syncTable).map{$0.identifier.rawValue}==["Path","Extension","Status","Lines added","Lines removed"],"Sync visible defaults changed")
            try require(syncTable.tableColumns.count==8 && !actions.hasLFS,"Sync optional column definitions/LFS gate differ")
            syncTable.selectRowIndexes(IndexSet(integersIn:1..<4),byExtendingSelection:false)
            let retained=actions.selection
            actions.requestReload()
            try await wait("Sync changelist refresh drains",window:sync.window){!actions.busy && !actions.fileListRefresh.hasPendingPosition}
            try require(actions.selection==retained && syncTable.selectedRowIndexes.count==retained.count,"Sync refresh lost native selection")
            try send(try unwrap(find(try header(syncTable),"Filename"),"Sync optional Filename missing"))
            try await wait("Sync Filename visible",window:sync.window){visible(syncTable).contains{$0.identifier.rawValue=="Filename"}}
            let syncMenu=try popup(syncTable,row:1,column:.fileExtension)
            try send(try unwrap(find(syncMenu,"Copy \"Extension\" to clipboard"),"Sync pointed-column copy missing"))
            let syncExpected=actions.sortedRows.filter{retained.contains($0.path)}.map(\.fileExtension).joined(separator:"\n")+"\n"
            try require(context.clipboard.string(forType:.string)==syncExpected,"Sync exact column copy differs")
            let snapshot=actions.files
            actions.readStatus={token in context.heldToken=token;return try await withCheckedThrowingContinuation{context.heldRead=$0}}
            actions.requestReload();try await wait("held Sync status read"){context.heldRead != nil && actions.busy}
            _=actions.cancelOperation();try require(context.heldToken?.isCancelled==true,"Sync cancel did not reach read token")
            context.heldRead?.resume(returning:snapshot);context.heldRead=nil
            try await wait("cancelled Sync refresh drained",window:sync.window){!actions.busy && !actions.fileListRefresh.hasPendingPosition}
            try require(actions.selection==retained,"Cancelled Sync read replaced selection")

            model.selection=[model.sortedReportEntries[0].path]
            let retiredItem=try unwrap(find(try popup(table,row:0,column:.fileExtension),"Extensions"),"Retired menu fixture missing")
            try send(try unwrap(find(try header(table),"Reset columns"),"Final Reset command missing"))
            try await wait("forced Reset question",window:window){window.attachedSheet != nil && model.reportResetActive}
            let lastCopy=context.copied;owner.close()
            try await wait("forced report Reset release"){owner.retired && !model.reportResetActive && ResolveWindowController.activeReleases==0}
            try send(retiredItem);try require(context.copied==lastCopy && !table.accessibilityPerformShowMenu(),"Retired menu/AX revived report")
            try await context.noMutations();try await context.cleanup()
            print("PASS: native conflict reports source defaults/optional columns, retained header identities, selected Space/checkbox, same-selection focus/ShiftF10/AX popup entry, exact extension/pointed/visible-order copy, stale blocking/retirement, typed sort/request order, saved layout/reset No/Yes/forced sheet drain, Remember policies, real changelist-bearing Sync refresh/cancel/selection and unchanged HEAD/index/files; no physical gestures, signed grants, real LFS server or actual resolution mutation claimed")
        } catch {
            let original=error
            do {try await context.cleanup()} catch {throw Failure(description:"\(original); cleanup: \(error)")}
            throw original
        }
    }
}
