// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietReportTypingOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;quietReportTypingOrder(mode,relativeTo:number)}
    @objc func quietReportTypingSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?){sheet.alphaValue=0;quietReportTypingSheet(sheet,completionHandler:completionHandler)}
}
@MainActor @main struct CommitReportTypingVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Commit report \(line): "+message)}}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func wait(_ owner:CommitWindowController,_ predicate:()->Bool,line:Int = #line)async throws{
        for _ in 0..<2000{owner.window?.contentView?.layoutSubtreeIfNeeded();if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit report timeout \(line); error=\(owner.model.error ?? "none") busy=\(owner.model.busy)")
    }
    static func settle(_ owner:CommitWindowController)async throws{
        for _ in 0..<4{await Task.yield();owner.window?.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:10_000_000)}
    }
    static func drained()->Bool{CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileDrops==0 && PatchWindowModel.activeOperations==0}
    static func main()async throws{
        NSApp.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietReportTypingOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietReportTypingSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))
        let suite="TurtleGit.CommitReportTyping."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","ShowAppContextMenuIcons"]{prefs.set(true,forKey:key)}
        for key in ["EnableGravatar","SelectFilesForCommit","UseLibgit2","TurtleGit.Commit.GitGuiInterface","AddBeforeCommit"]{prefs.set(false,forKey:key)}
        _=try await repo.run(["init","-b","main"])
        for(k,v)in[("user.name","Report QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")]{_=try await repo.run(["config",k,v])}
        for name in ["alpha.txt","long name 雪.swift"]{try Data("base\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(["."]);_=try await repo.commit(message:"base")
        try Data("working\nextra\n".utf8).write(to:root.appendingPathComponent("alpha.txt"));try Data("untracked\n".utf8).write(to:root.appendingPathComponent("new.txt"))
        let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs),m=owner.model
        owner.window?.setFrameOrigin(.init(x:-22000,y:-22000));owner.showWindow(nil);m.reload(paths:["."])
        do{
            try await wait(owner){!m.busy && m.commitIdentityPrepared && m.changelistsLoaded && !m.fileWorkPending && !m.loadingFileMetadata}
            try require(m.error==nil && !m.gitGuiInterface,"Classic Commit did not load")
            try await wait(owner){m.fileListTable(key:"checkbox")?.headerView?.menu != nil}
            guard let probe=views(owner.window?.contentView).compactMap({$0 as? CommitFileInteraction.Probe}).first,let table=m.fileListTable(key:"checkbox"),let editor=views(owner.window?.contentView).compactMap({$0 as? CommitMessageTextView}).first else{throw Failure(description:"Actual Classic editor/report missing")}
            try await settle(owner)
            var visibilityTransitions=0
            let visibilityObservers=table.tableColumns.map{column in
                column.observe(\.isHidden,options:[.old,.new]){_,change in
                    if change.oldValue != change.newValue{visibilityTransitions += 1}
                }
            }
            defer{visibilityObservers.forEach{$0.invalidate()}}
            func type(_ suffix:String)async throws{
                try require(owner.window?.makeFirstResponder(editor)==true && editor.isEditable,"Native message editor cannot accept text")
                let tableID=ObjectIdentifier(table),header=table.headerView!,menu=table.headerView!.menu!,columns=table.tableColumns.map(ObjectIdentifier.init),frames=table.tableColumns.map{($0.width,$0.isHidden)},count=probe.configurationApplications,receipt=m.fileCheckReceipt,checked=m.checked
                let reportEpoch=m.fileReportRevision,rows=probe.rows,bounds=table.bounds,visibleRect=table.visibleRect,enabled=probe.enabled,content=probe.contentRevision,visibilityBefore=visibilityTransitions
                let rowHeight=table.rowHeight,font=probe.fileListFont?.fontName ?? "system",fontSize=probe.fileListFont?.pointSize ?? 0
                let nativeOwner=NativeListSelection.usesFullRowSelection(in:table)
                var defaultsNotifications=0,columnResizes=0,columnMoves=0
                // AppKit posts these for actual native width/order mutations, including
                // a transient reset later restored to the same final widths.
                let resizeObserver=NotificationCenter.default.addObserver(forName:NSTableView.columnDidResizeNotification,object:table,queue:.main){_ in columnResizes += 1}
                let moveObserver=NotificationCenter.default.addObserver(forName:NSTableView.columnDidMoveNotification,object:table,queue:.main){_ in columnMoves += 1}
                let defaultsObserver=NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:prefs,queue:.main){_ in defaultsNotifications += 1}
                defer{NotificationCenter.default.removeObserver(defaultsObserver);NotificationCenter.default.removeObserver(resizeObserver);NotificationCenter.default.removeObserver(moveObserver)}
                var expected=m.message
                for scalar in suffix{
                    editor.insertText(String(scalar),replacementRange:NSRange(location:(editor.string as NSString).length,length:0));expected += String(scalar)
                    try await wait(owner){m.message==expected};try await settle(owner)
                    try require(m.fileListTable(key:"checkbox").map(ObjectIdentifier.init)==tableID && table.headerView === header && table.headerView?.menu === menu,"Message-only edit replaced native report/header/menu")
                    var sameLayout=table.tableColumns.map(ObjectIdentifier.init)==columns
                    for(index,column)in table.tableColumns.enumerated(){
                        guard frames.indices.contains(index) else{sameLayout=false;continue}
                        if abs(column.width-frames[index].0)>=0.5 || column.isHidden != frames[index].1{sameLayout=false}
                    }
                    try require(sameLayout,"Message-only edit changed native column layout")
                    let delta="typed=\(String(reflecting:expected)) applications=\(count)->\(probe.configurationApplications) reportEpochChanged=\(reportEpoch != m.fileReportRevision) probeEpochChanged=\(content != probe.contentRevision) rowsChanged=\(rows != probe.rows) bounds=\(bounds)->\(table.bounds) visibleRect=\(visibleRect)->\(table.visibleRect) enabled=\(enabled)->\(probe.enabled) rowHeight=\(rowHeight)->\(table.rowHeight) font=\(font)/\(fontSize)->\(probe.fileListFont?.fontName ?? "system")/\(probe.fileListFont?.pointSize ?? 0) nativeOwner=\(String(describing:nativeOwner))->\(String(describing:NativeListSelection.usesFullRowSelection(in:table))) defaultsNotifications=\(defaultsNotifications) columnResizes=\(columnResizes) columnMoves=\(columnMoves) visibilityTransitions=\(visibilityBefore)->\(visibilityTransitions)"
                    try require(visibilityTransitions==visibilityBefore,"Message-only edit transiently hid or showed native report columns; "+delta)
                    try require(columnResizes==0 && columnMoves==0,"Message-only edit transiently resized or moved native report columns; "+delta)
                    try require(probe.configurationApplications==count,"Message-only edit reapplied native report decoration; "+delta)
                    try require(m.fileCheckReceipt==receipt && m.checked==checked,"Typing changed checkbox ownership or inclusion")
                }
            }
            try await type("Review 雪")
            let selectable=probe.rows.firstIndex(where:{$0.entry?.path=="alpha.txt"})!
            func checkbox()throws->NSButton{
                guard let cell=table.view(atColumn:0,row:selectable,makeIfNecessary:true),let button=views(cell).compactMap({$0 as? NSButton}).first(where:{$0.isEnabled}) else{throw Failure(description:"Live native inclusion checkbox missing")}
                return button
            }
            CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:selectable))
            try await wait(owner){m.selection.contains("alpha.txt") && table.selectedRowIndexes==IndexSet(integer:selectable)}
            try await settle(owner);let selectedIDs=m.nativeFileSelection
            try await type(" selected")
            try require(m.nativeFileSelection==selectedIDs && table.selectedRowIndexes==IndexSet(integer:selectable),"Typing lost accepted native file selection")
            let included=m.checked.contains("alpha.txt")
            try checkbox().performClick(nil);try await wait(owner){m.checked.contains("alpha.txt") != included}
            try await settle(owner);try checkbox().performClick(nil);try await wait(owner){m.checked.contains("alpha.txt")==included}
            guard let nameColumn=table.tableColumns.first(where:{$0.sortDescriptorPrototype != nil && probe.columnDefinition(atNativeIndex:table.tableColumns.firstIndex(of:$0)!) == .fileName}),let descriptor=nameColumn.sortDescriptorPrototype else{throw Failure(description:"Native filename sort missing")}
            let previous=table.sortDescriptors;table.sortDescriptors=[descriptor.reversedSortDescriptor as! NSSortDescriptor];table.dataSource?.tableView?(table,sortDescriptorsDidChange:previous)
            try await wait(owner){m.fileSortOrder.first?.column == .fileName && m.fileSortOrder.first?.order == .reverse}
            try await settle(owner);try await type(" sorted")
            guard let status=table.tableColumns.first(where:{probe.columnDefinition(atNativeIndex:table.tableColumns.firstIndex(of:$0)!) == .status}) else{throw Failure(description:"Status column missing")}
            let visibilityBeforeHide=visibilityTransitions
            m.setFileColumn(.status,visible:false);try await wait(owner){status.isHidden};try await settle(owner)
            try require(visibilityTransitions>visibilityBeforeHide,"Native column visibility observer did not detect the actual Hide command")
            try await type(" after hide")
            m.setFileColumn(.status,visible:true);try await wait(owner){!status.isHidden}
            let original=table.tableColumns[2];original.width += 31;table.moveColumn(2,toColumn:4);probe.rememberNativeColumnLayout(adjustedColumn:.fileName)
            try await settle(owner);let saved=m.fileColumns
            try await type(" after resize")
            try require(m.fileColumns==saved && StatusListColumnSettings.load(from:prefs)==saved,"Typing discarded native user column preferences")
            let beforeHeight=table.rowHeight;prefs.set(true,forKey:"LogFontForFileListCtrl");prefs.set("Menlo",forKey:"LogFontName");prefs.set(19,forKey:"LogFontSize")
            try await wait(owner){table.rowHeight>beforeHeight};try await settle(owner);try await type(" font")
            owner.window?.appearance=NSAppearance(named:.darkAqua);try await settle(owner);try await type(" dark")
            let oldReceipt=m.fileCheckReceipt,oldEntry=m.entries.first(where:{$0.path=="alpha.txt"})!,oldFiles=m.visibleEntries
            try Data("base\n".utf8).write(to:root.appendingPathComponent("alpha.txt"));m.reload(paths:["."])
            try await wait(owner){!m.busy && !m.fileWorkPending && m.commitIdentityPrepared && !m.entries.contains(where:{$0.path=="alpha.txt"})}
            try require(m.fileCheckReceipt != oldReceipt,"Real status replacement retained old check receipt")
            let current=m.checked;m.setFileChecked(oldEntry,files:oldFiles,highlighted:[oldEntry.id],checked:!current.contains(oldEntry.id),receipt:oldReceipt)
            try require(m.checked==current,"Old checkbox callback mutated replacement rows")
            try require(probe.rows.compactMap(\.entry).map(\.path)==m.sortedFiles(m.visibleEntries,statistics:m.statistics).map(\.path),"Real status rows failed to update after typing")
            m.message="";owner.close();try await wait(owner){drained() && owner.window?.isVisible != true}
            prefs.removePersistentDomain(forName:suite)
            print("PASS: Classic Commit message typing preserves native report headers and layout; real file/column/font/theme transitions and stale checkbox receipts remain live")
        }catch{m.message="";owner.close();for _ in 0..<2000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite);throw error}
    }
}
