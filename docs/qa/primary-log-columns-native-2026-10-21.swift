// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Grouped with Commit/Settings by test-primary-parity-family.py. All ownership
/// belongs to this private receiver; no physical key-window/SwiftUI AX claim.
enum PrimaryLogColumnsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    @MainActor static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ window:NSWindow?,line:Int = #line,_ ready:()->Bool)async throws{
        for _ in 0..<1500{window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Log columns timeout at \(line)")
    }
    @MainActor static func table(_ owner:LogWindowController)throws->(NSTableView,RevisionTable.Coordinator){
        for table in views(owner.window?.contentView).compactMap({$0 as? NSTableView}){
            if let coordinator=table.dataSource as? RevisionTable.Coordinator{return(table,coordinator)}
        }
        throw Failure(description:"Actual main Log revision table missing")
    }
    @MainActor static func menu(_ coordinator:RevisionTable.Coordinator)throws->NSMenu{
        guard let menu=coordinator.headerMenu else{throw Failure(description:"Log header menu missing")}
        coordinator.menuNeedsUpdate(menu);return menu
    }
    @MainActor static func item(_ menu:NSMenu,_ id:String)throws->NSMenuItem{
        guard let item=menu.items.first(where:{$0.identifier?.rawValue=="Log.Columns."+id}) else{throw Failure(description:"Missing Log header item \(id)")};return item
    }
    @MainActor static func press(_ item:NSMenuItem)throws{
        guard item.isEnabled,let action=item.action else{throw Failure(description:"Disabled native header command")}
        _ = NSApp.sendAction(action,to:item.target,from:item)
    }
    @MainActor static func run(root:URL,git:URL)async throws{
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git,diffDetection:.init(),libgit2Configuration:.init(enabled:false))
        _ = try await repo.run(["init","-b","main"])
        for(key,value)in [("user.name","Column QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        let caption="Long literal revision subject " + String(repeating:"wide content ",count:16)+"end"
        for number in 0..<3{
            try Data("\(number)\n".utf8).write(to:root.appendingPathComponent("literal.txt"));try await repo.stage(["literal.txt"])
            _ = try await repo.run(["commit","-m",number==1 ? caption:"revision \(number)"])
        }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.PrimaryLogColumns."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        for key in ["EnableLogCache","EnableGravatar","LogIncludeWorkingTreeChanges"]{prefs.set(false,forKey:key)}
        prefs.set(true,forKey:"LogFontForLogCtrl");prefs.set("Menlo",forKey:"LogFontName");prefs.set(18,forKey:"LogFontSize")
        // Deliberately hostile legacy Graph visibility must not hide fixed index0.
        prefs.set(false,forKey:"Log.Column.Visible.graph")
        var owners:[LogWindowController]=[],replies:[(NSApplication.ModalResponse)->Void]=[]
        func own()->LogWindowController{
            let owner=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesGeometry:false)
            owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.window?.orderFront(nil);return owner
        }
        func clean()async{
            owners.forEach{$0.window?.close()};let pending=replies;replies=[];pending.forEach{$0(.alertSecondButtonReturn)}
            for _ in 0..<1200{if LogRevisionColumnQuestion.activeCount==0 && LogWindowModel.activeHistoryLoads==0{return};try? await Task.sleep(nanoseconds:10_000_000)}
        }
        do{
            let owner=own(),model=owner.model
            try await wait(owner.window){!model.busy && model.entries.count==3 && (try? table(owner)) != nil}
            let (native,coordinator)=try table(owner)
            try await wait(owner.window){coordinator.columnCommandsAvailable}
            guard let window=owner.window as? LogHistoryWindow else{throw Failure(description:"Native Log history window missing")}
            window.minSize = .zero;window.contentMinSize = .zero
            try require(window.minSize.width>=1080 && window.minSize.height>=700,"Hosting update erased declared Log minimum")
            window.setFrame(.init(origin:window.frame.origin,size:window.minSize),display:false)
            let graph=native.tableColumn(withIdentifier:.init("graph"))!,message=native.tableColumn(withIdentifier:.init("message"))!
            try require(native.tableColumns.first?.identifier.rawValue=="graph" && !graph.isHidden && graph.width<200,"Default compact graph not before list")
            var header=try menu(coordinator)
            try require(!header.items.contains{$0.identifier?.rawValue=="Log.Columns.graph"},"Source fixed Graph appeared in visibility commands")
            let email=try item(header,"email"),hash=try item(header,"hash")
            let emailColumn=native.tableColumn(withIdentifier:.init("email"))!,hashColumn=native.tableColumn(withIdentifier:.init("hash"))!
            let hashBefore=hashColumn.isHidden
            try press(email);try press(hash)
            try require(!emailColumn.isHidden && hashColumn.isHidden==hashBefore,"Header sibling reused consumed receipt")
            header=try menu(coordinator);let stale=try item(header,"email"),hidden=emailColumn.isHidden
            model.confirmingQuit=true;model.confirmingQuit=false;try press(stale)
            try require(emailColumn.isHidden==hidden,"Header revived across Quit generation")
            header=try menu(coordinator);let oldProjection=try item(header,"email")
            let captured=model.entries;model.entries=captured;try press(oldProjection)
            try require(emailColumn.isHidden==hidden,"Header survived replaced history projection")
            // Unrelated lazy metadata must not retire a menu against the same rows.
            header=try menu(coordinator);let metadata=try item(header,"email")
            model.revisionActions[model.entries[0].hash] = .modified;try press(metadata)
            try require(emailColumn.isHidden != hidden,"Lazy icon metadata retired valid header")
            coordinator.fitColumn(native.column(withIdentifier:message.identifier),automatic:false)
            let measured=message.width
            let font=NSFont(name:"Menlo",size:18)!
            try require(measured>450 && measured >= (caption as NSString).size(withAttributes:[.font:font]).width,"Fit truncated long actual row text at fixed450")
            try require((prefs.stringArray(forKey:"Log.Columns.Adjusted") ?? []).contains("message"),"Manual fit not persisted")
            coordinator.fitColumn(native.column(withIdentifier:message.identifier),automatic:true)
            try require(!(prefs.stringArray(forKey:"Log.Columns.Adjusted") ?? []).contains("message"),"Shift fit retained manual width")
            // Native divider event, not direct selector; ordinary double-click fits.
            if let view=native.headerView as? LogRevisionColumnHeader{
                let column=native.column(withIdentifier:message.identifier),point=view.convert(.init(x:view.headerRect(ofColumn:column).maxX,y:8),to:nil)
                guard let event=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:2,pressure:1) else{throw Failure(description:"Divider event creation")}
                view.mouseDown(with:event)
                try require((prefs.stringArray(forKey:"Log.Columns.Adjusted") ?? []).contains("message"),"Actual divider double-click not routed")
            }else{throw Failure(description:"Log native divider header missing")}
            // Save actual manual resize and reordering through native delegate callbacks.
            message.width=333;coordinator.tableViewColumnDidResize(.init(name:NSTableView.columnDidResizeNotification,object:native,userInfo:["NSTableColumn":message]))
            let emailIndex=native.column(withIdentifier:emailColumn.identifier);native.moveColumn(emailIndex,toColumn:1);coordinator.saveColumns()
            let reopened=own();try await wait(reopened.window){!reopened.model.busy && reopened.model.entries.count==3 && (try? table(reopened)) != nil}
            let (restored,restoredCoordinator)=try table(reopened)
            try require(restored.tableColumns[1].identifier.rawValue=="email" && abs((restored.tableColumn(withIdentifier:.init("message"))?.width ?? 0)-333)<1,"Private reopened layout lost order/manual width")
            try require(restoredCoordinator.model.colorPreferences === prefs,"Layout changed preference owner")
            reopened.window?.close()
            var ordering=0;model.onShowOrdering={ordering += 1}
            coordinator.tableView(native,didClick:message);model.confirmingQuit=true;model.confirmingQuit=false
            try await Task.sleep(nanoseconds:30_000_000);try require(ordering==0,"Delayed Ordering revived after Quit")
            coordinator.tableView(native,didClick:message);try await wait(window){ordering==1}
            model.presentRevisionColumnQuestion={parent,alert,reply in
                replies.append(reply);parent.beginSheet(alert.window,completionHandler:nil)
            }
            header=try menu(coordinator);try press(item(header,"Reset"))
            try require(model.revisionColumnWorkPending && model.resettingRevisionColumns && LogRevisionColumnQuestion.activeCount==1,"Reset question lacks actual lifetime accounting")
            replies.removeFirst()(.alertSecondButtonReturn)
            try await wait(window){!model.revisionColumnWorkPending}
            try require(abs(message.width-333)<1,"Reset No changed layout")
            header=try menu(coordinator);try press(item(header,"Reset"));replies.removeFirst()(.alertFirstButtonReturn)
            try await wait(window){!model.revisionColumnWorkPending}
            try require(native.tableColumns.first?.identifier.rawValue=="graph" && message.width>450 && (prefs.stringArray(forKey:"Log.Columns.Adjusted") ?? ["unexpected"]).isEmpty,"Reset Yes did not restore automatic content geometry")
            let messageRow=model.entries.firstIndex{$0.subject==caption}!
            if let cell=native.view(atColumn:native.column(withIdentifier:message.identifier),row:messageRow,makeIfNecessary:true) as? NSTableCellView,let text=cell.textField{
                native.layoutSubtreeIfNeeded()
                try require(text.frame.height<=native.rowHeight+1 && text.fittingSize.height<=native.rowHeight+1,"Configured Log font escaped native single-line row")
            }else{throw Failure(description:"Actual fitted message data cell missing")}
            try await PrimaryParityCapture.save(window,"log-columns")
            header=try menu(coordinator);try press(item(header,"Reset"));model.confirmingQuit=true
            replies.removeFirst()(.alertFirstButtonReturn);try await wait(window){!model.revisionColumnWorkPending};model.confirmingQuit=false
            var closed=false;owner.onClosed={closed=true}
            header=try menu(coordinator);try press(item(header,"Reset"));window.close()
            try require(!closed && model.revisionColumnWorkPending,"Forced owner close discarded actual Reset reply")
            let delegate=TurtleGitApplicationDelegate()
            try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored closed Log's actual outstanding Reset reply")
            replies.removeFirst()(.alertFirstButtonReturn);try await wait(nil){closed && !model.revisionColumnWorkPending}
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try require(finalHead==head && finalIndex==index,"Column workflow mutated Git state")
            await clean();try require(LogRevisionColumnQuestion.activeCount==0,"Owned Reset questions did not drain")
        }catch{await clean();throw error}
        print("PASS Log columns: content fitting/native divider, fixed Graph, scoped layout, one-use header/Ordering, Reset Yes/No/Quit/forced-close actual drain")
    }
}
