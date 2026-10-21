// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore

private extension NSWindow {
    @objc func blameHistoryHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-20000,y:-20000));blameHistoryHiddenOrder(place,relativeTo:number)
    }
}
@MainActor @main enum BlameHistoryPresentationVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(message:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(message:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"Blame history timeout at \(line)")}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func send(_ item:NSMenuItem)throws {let action=try unwrap(item.action,"Native menu action missing");_ = NSApp.sendAction(action,to:item.target,from:item)}
    static func drained()->Bool {BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameDocumentOpener.activeReads==0}
    @MainActor final class Context {
        let base:URL,repo:GitRepository,suite:String,prefs:UserDefaults
        var owners:[BlameWindowController]=[],hashes:[String]=[],index=Data(),contents=Data()
        init(){base=URL(fileURLWithPath:CommandLine.arguments[1]);repo=GitRepository(root:base.appendingPathComponent("repository"),executable:URL(fileURLWithPath:CommandLine.arguments[2]),askpass:nil,libgit2Configuration:.init(enabled:false));suite="TurtleGit.BlameHistoryPresentation."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true)
            _ = try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","TurtleGit Author"),("user.email","author@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_ = try await repo.run(["config",key,value])}
            for n in 0..<3 {
                let text=(0..<45).map {"let line\($0) = \($0 < (n+1)*10 ? n:0) // source attribution 雪"}.joined(separator:"\n")+"\n"
                try Data(text.utf8).write(to:repo.root.appendingPathComponent("source.swift"));try Data("Other document \(n)\n".utf8).write(to:repo.root.appendingPathComponent("other.txt"))
                _ = try await repo.run(["add","-A","--"]);_ = try await repo.commit(message:["Initial source","Update attribution","Paint reference badges\u{2028}and preserve raw caption"][n])
                hashes.append(try await repo.rebaseCommit("HEAD").hash)
            }
            _ = try await repo.run(["branch","feature/review",hashes[2]])
            _ = try await repo.run(["tag","-a","v2.1","-m","Annotated release",hashes[2]])
            _ = try await repo.run(["tag","base",hashes[0]])
            _ = try await repo.run(["remote","add","origin",repo.root.path])
            _ = try await repo.run(["update-ref","refs/remotes/origin/main",hashes[2]])
            _ = try await repo.run(["config","branch.main.remote","origin"]);_ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
            for(key,value)in[("EnableGravatar",false),("Blame.EnableLexer",false),("EnableLogCache",false),("UseLibgit2",false),("LogFontForLogCtrl",true),("ShowAppContextMenuIcons",true)] {prefs.set(value,forKey:key)}
            prefs.set("Menlo",forKey:"LogFontName");prefs.set(16,forKey:"LogFontSize")
            index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"));contents=try Data(contentsOf:repo.root.appendingPathComponent("source.swift"))
        }
        func owner()async throws->BlameWindowController {
            let owner=BlameWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),path:"source.swift",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
            owners.append(owner);owner.window?.orderFront(nil);owner.commandKeyWindow={ [weak owner] in owner?.window }
            try await wait{!owner.model.busy && !owner.model.syntaxWorking && owner.model.historyEntries.count==3 && owner.model.canFind}
            _ = try await table(owner);return owner
        }
        func clean(){owners.forEach{$0.close()};owners=[];prefs.removePersistentDomain(forName:suite)}
        func preserved()async throws {try require(try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Blame history modified index");try require(try Data(contentsOf:repo.root.appendingPathComponent("source.swift"))==contents,"Blame history modified source");try require(try await repo.rebaseCommit("HEAD").hash==hashes[2],"Blame history moved HEAD")}
    }
    static func table(_ owner:BlameWindowController)async throws->(BlameHistoryNativeTable,BlameHistoryTable.Coordinator) {
        try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return views(owner.window?.contentView).compactMap{$0 as? BlameHistoryNativeTable}.contains{table in table.numberOfRows==owner.model.historyEntries.count && (table.delegate as? BlameHistoryTable.Coordinator)?.model === owner.model}}
        let table=try unwrap(views(owner.window?.contentView).compactMap{$0 as? BlameHistoryNativeTable}.first{table in table.numberOfRows==owner.model.historyEntries.count && (table.delegate as? BlameHistoryTable.Coordinator)?.model === owner.model},"Native Blame history missing")
        return(table,try unwrap(table.delegate as? BlameHistoryTable.Coordinator,"Native Blame history coordinator missing"))
    }
    static func text(_ table:NSTableView,_ id:String,_ row:Int)throws->NSTextField {
        let col=try unwrap(table.tableColumns.firstIndex{$0.identifier.rawValue==id},"Missing column "+id)
        return try unwrap((table.view(atColumn:col,row:row,makeIfNecessary:true) as? NSTableCellView)?.textField,"Missing actual text cell "+id)
    }
    static func column(_ table:NSTableView,_ id:String)throws->NSTableColumn {try unwrap(table.tableColumn(withIdentifier:.init(id)),"Missing native column "+id)}
    static func selection(_ table:BlameHistoryNativeTable,_ model:BlameWindowModel,_ rows:IndexSet)async throws {
        table.selectRowIndexes(rows,byExtendingSelection:false)
        let hashes=Set(rows.map{model.historyEntries[$0].hash})
        try await wait{model.selectedLogHashes==hashes && table.selectedRowIndexes==rows}
    }
    static func presentation(_ c:Context)async throws {
        // The existing v6 layout must retain its chosen widths/order while the
        // source-only graph constraint migrates to v7.
        c.prefs.set(6,forKey:"Blame.LogColumns.Version");c.prefs.set(["message","author"],forKey:"Blame.LogColumns");c.prefs.set(["author","message","graph"]+BlameHistoryColumns.names.filter{!["author","message","graph"].contains($0)},forKey:"Blame.LogColumns.Order");c.prefs.set(["message":370,"author":160],forKey:"Blame.LogColumns.Widths")
        let owner=try await c.owner(),model=owner.model,(native,coordinator)=try await table(owner)
        try require(model.historyColumns.visible==Set(["graph","message","author"]) && model.historyColumns.order.prefix(3)==["graph","author","message"],"v6 layout migration lost source constraints/intent")
        let savedMessageColumn=try column(native,"message"),savedGraphColumn=try column(native,"graph")
        try require(savedMessageColumn.width==370 && !savedGraphColumn.isHidden,"Saved width/graph projection changed")
        let message=try text(native,"message",0),author=try text(native,"author",0),normal=try text(native,"author",1)
        try require(message.cell is LogReferenceTextCell && message.stringValue.contains("↵") && !message.stringValue.contains("\u{2028}") && message.toolTip?.contains("\u{2028}")==true,"Safe caption or original raw tooltip missing")
        try require(author.font?.pointSize==16 && author.font?.familyName=="Menlo" && NSFontManager.shared.traits(of:author.font!).contains(.boldFontMask) && !NSFontManager.shared.traits(of:normal.font!).contains(.boldFontMask),"Configured font/HEAD emphasis missing")
        var styles:[LogReferenceStyle]=[]
        message.attributedStringValue.enumerateAttribute(.logReference,in:NSRange(location:0,length:message.attributedStringValue.length)){value,_,_ in if let value=value as? LogReferenceStyle{styles.append(value)}}
        try require(styles.contains{$0.label.reference.name=="refs/heads/main" && $0.label.reference.isCurrent} && styles.contains{$0.label.reference.name=="refs/tags/v2.1" && $0.pointed} && styles.contains{$0.label.hasTracking},"Actual native badges lost current branch, annotated tag or tracking")
        let colors=Set(styles.compactMap{$0.color.usingColorSpace(.sRGB)?.description});try require(colors.count>=3,"Distinct reference colors collapsed")
        let menu=coordinator.columnMenu();try require(!menu.items.contains{$0.title=="Graph"},"Graph offered independent visibility toggle")
        let hide=try unwrap(menu.items.first{$0.title=="Message"},"Message toggle missing");try send(hide);try send(hide)
        try require(!model.historyColumns.visible.contains("message") && c.prefs.integer(forKey:"Blame.LogColumns.Version")==7,"Message hide or one-shot/persistence failed")
        let show=try unwrap(coordinator.columnMenu().items.first{$0.title=="Message"},"Message re-show missing");try send(show)
        try await wait{(try? column(native,"message").isHidden)==false}
        try await selection(native,model,IndexSet(integer:1));native.window?.makeFirstResponder(native)
        let sourceFont=model.sourceFont,oldHeight=native.rowHeight,oldSelection=native.selectedRowIndexes
        c.prefs.set(24,forKey:"LogFontSize")
        // Real preferences notification/representable update, not direct refresh.
        NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.prefs)
        try await wait{native.rowHeight>oldHeight && (try? text(native,"author",1).font?.pointSize)==24}
        try require(native.selectedRowIndexes==oldSelection && model.sourceFont==sourceFont,"Log font changed selection or source font")
        c.prefs.set(false,forKey:"LogFontForLogCtrl");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:c.prefs)
        try await wait{(try? text(native,"author",1).font?.pointSize)==12}
        let defaults=BlameHistoryColumns.load(c.prefs)
        try require(!defaults.visible.isEmpty && defaults.widths["message"]==370,"Reloaded layout lost width during font-only updates")
        try await c.preserved()
    }
    static func answer(_ owner:BlameWindowController,_ title:String)async throws {
        try await wait{owner.columnAlert?.window.sheetParent === owner.window}
        let alert=try unwrap(owner.columnAlert,"Missing actual Reset alert"),button=try unwrap(alert.buttons.first{$0.title==title},"Missing native answer "+title)
        button.performClick(nil);try await wait{!owner.model.resettingHistoryColumns && owner.window?.attachedSheet==nil && alert.window.sheetParent==nil && BlameWindowModel.activeHistoryOperations==0}
    }
    static func ownership(_ c:Context)async throws {
        fputs("Blame history phase: ownership setup\n",stderr)
        let owner=try await c.owner(),model=owner.model,(native,coordinator)=try await table(owner)
        let old=try unwrap(coordinator.columnMenu().items.first{$0.title=="Message"},"Header item")
        model.busy=true;model.busy=false;try send(old);try require(model.historyColumns.visible.contains("message"),"Busy transition revived header receipt")
        var widths=model.historyColumns.widths;widths["message"]=70
        let layout=BlameHistoryColumns(visible:model.historyColumns.visible,order:["message","graph"]+model.historyColumns.order,widths:widths)
        model.saveHistoryColumns(layout);coordinator.update()
        let retained=model.historyColumns
        fputs("Blame history phase: Reset No\n",stderr)
        try send(coordinator.columnMenu().items[0]);try await answer(owner,"No");try require(model.historyColumns==retained,"Reset No changed layout")
        fputs("Blame history phase: Reset Yes\n",stderr)
        try send(coordinator.columnMenu().items[0]);try await answer(owner,"Yes");coordinator.update()
        try require(model.historyColumns.order==BlameHistoryColumns.names && (model.historyColumns.widths["message"] ?? 0) > 70,"Reset Yes did not fit current decorated contents")
        let plain=try text(native,"message",0).attributedStringValue.size().width+14
        try require((model.historyColumns.widths["message"] ?? 0)>=min(10000,ceil(plain)),"Reset fitting omitted badge/font width")
        let stale=try unwrap(coordinator.columnMenu().items.first{$0.title=="Author"},"Captured header item")
        // Actual key event carries alternate mode through delayed parent reads.
        fputs("Blame history phase: first-selected activation\n",stderr)
        try await selection(native,model,IndexSet([0,1]));native.window?.makeFirstResponder(native)
        var pending:CheckedContinuation<[GitBlameParentComparison],Error>?,prepared:[GitBlameParentComparison]=[],calls:[(String,Bool)]=[]
        defer{pending?.resume(throwing:OperationCancellationFailure.cancelled);pending=nil}
        model.readHistoryParents={snapshot,hash,token in
            prepared=try await c.repo.blameHistoryParentComparisons(snapshot,revision:hash,cancellation:token)
            return try await withCheckedThrowingContinuation{pending=$0}
        }
        model.onChanges={calls.append(($0.to.label,ComparisonToolInvocation.capture))}
        let event=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:owner.window!.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36),"Return event")
        try require(!native.openSelection(),"Disabled activation compared revision")
        c.prefs.set(true,forKey:"DiffByDoubleClickInLog");native.keyDown(with:event)
        try await wait{pending != nil};pending?.resume(returning:prepared);pending=nil
        try await wait{calls.count==1 && BlameWindowModel.activeHistoryOperations==0}
        try require(calls[0].0==c.hashes[2] && calls[0].1 && native.selectedRowIndexes==IndexSet([0,1]),"Multi-selection activation lost first revision/Shift/selection")
        let control=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.control,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:owner.window!.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36),"Control Return event")
        native.keyDown(with:control);try require(calls.count==1 && pending==nil,"Control Return started source activation")
        // SDI File Open replaces the actual model in this same window. Retained
        // old menus and a dismantled native table must never reach that model.
        let window=owner.window
        fputs("Blame history phase: actual File Open\n",stderr)
        owner.chooseFile={_,_,reply in reply(c.repo.root.appendingPathComponent("other.txt"))};owner.openDocument()
        try await wait{owner.model !== model && !owner.model.busy && !owner.model.syntaxWorking && owner.model.canFind}
        let replacement=owner.model,(newTable,newCoordinator)=try await table(owner),before=replacement.historyColumns
        try send(stale);try require(replacement.historyColumns==before && model.retired && owner.window === window,"Old header retargeted replacement")
        coordinator.retire();try require(native.delegate==nil && native.dataSource==nil && native.target==nil && native.menu==nil && !native.openSelection(),"Dismantled table retained dispatch callbacks")
        var reply:((NSApplication.ModalResponse)->Void)?
        fputs("Blame history phase: close pending Reset\n",stderr)
        owner.presentHistoryColumnReset={parent,alert,respond in parent.beginSheet(alert.window);reply=respond}
        let preserved=replacement.historyColumns;try send(newCoordinator.columnMenu().items[0]);try await wait{reply != nil && owner.columnAlert?.window.sheetParent === window}
        let sheet=owner.columnAlert!.window;var closed=false;owner.onClosed={closed=true}
        owner.close()
        try require(replacement.retired && replacement.resettingHistoryColumns && !closed,"Forced Close released owner before pending Reset completion drained")
        reply?(.alertSecondButtonReturn);reply?(.alertSecondButtonReturn)
        try await wait{closed && !replacement.resettingHistoryColumns && sheet.sheetParent==nil && drained()}
        try require(replacement.historyColumns==preserved && newTable.window?.isVisible != true,"Retired Reset accepted late Yes or left window")
        try await c.preserved()
    }
    static func captures(_ c:Context,_ output:URL)async throws {
        let owner=try await c.owner(),model=owner.model,(native,coordinator)=try await table(owner)
        // An intentional Message-first saved metadata layout makes the original
        // badges readable beside the source while retaining the source graph.
        let layout=BlameHistoryColumns(visible:["graph","id","message","author","date"],order:["graph","id","message","author","date"]+model.historyColumns.order,widths:["graph":55,"id":35,"message":570,"author":150,"date":170]);model.saveHistoryColumns(layout);coordinator.update()
        owner.window?.setContentSize(.init(width:1280,height:850));owner.window?.center();owner.window?.makeKeyAndOrderFront(nil)
        let window=try unwrap(owner.window,"Capture window"),appearance=window.appearance;defer{window.appearance=appearance;owner.close()}
        window.contentView?.layoutSubtreeIfNeeded()
        let property=try unwrap(views(window.contentView).compactMap{$0 as? BlamePropertiesTable}.first,"Capture properties table")
        let splits=views(window.contentView).compactMap{$0 as? NSSplitView}
        if let split=splits.first(where:{!$0.isVertical && $0.arrangedSubviews.count==2 && views($0).contains{$0 === native} && views($0).contains{$0 === property}}) {
            split.setPosition(split.bounds.height-220-split.dividerThickness,ofDividerAt:0)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if let split=splits.first(where:{$0.isVertical && $0.arrangedSubviews.count==2 && views($0).contains{$0 === property} && !views($0).contains{$0 === native}}) {
            split.setPosition(split.bounds.width-380-split.dividerThickness,ofDividerAt:0)
        }
        try await selection(native,model,IndexSet(integer:1))
        try await wait {window.contentView?.layoutSubtreeIfNeeded();return native.visibleRect.contains(native.rect(ofRow:2)) && !model.revisionDetails.basic.allSatisfy{$0.value.isEmpty}}
        guard #available(macOS 14.4,*)else{throw Failure(message:"Compositor capture unavailable")}
        for(theme,name)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
            try await wait{window.isVisible && window.attachedSheet==nil && native.numberOfRows==3 && native.visibleRect.height>=native.rowHeight*3 && !model.busy && !model.syntaxWorking}
            let caption=try text(native,"message",0),graphColumn=try column(native,"graph")
            native.displayIfNeeded()
            let painter=try unwrap(caption.cell as? LogReferenceTextCell,"Capture lost actual badge painter")
            try require(!painter.badgeFrames.isEmpty && caption.bounds.height>0 && (native.headerView?.visibleRect.height ?? 0)>0,"Capture lacks rendered badges or complete native header")
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let data=try unwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),"PNG encoding")
            try data.write(to:output.appendingPathComponent("blame-history-presentation-"+name+".png"))
            try require(native.rowHeight>=24 && !graphColumn.isHidden,"Capture lost configured history geometry")
        }
        try await c.preserved()
    }
    static func main()async throws {
        let which=CommandLine.arguments[3],visual=which=="captures"
        NSApplication.shared.setActivationPolicy(visual ? .regular:.prohibited)
        let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.blameHistoryHiddenOrder(_:relativeTo:)))!
        if !visual {method_exchangeImplementations(normal,hidden)};defer{if !visual{method_exchangeImplementations(normal,hidden)}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard);c.clean()}
        do {
            try await c.seed()
            switch which {case "presentation":try await presentation(c);case "ownership":try await ownership(c);case "captures":try await captures(c,URL(fileURLWithPath:CommandLine.arguments[4]));default:throw Failure(message:"Unknown case")}
            c.clean();try await wait{drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}}
            print("PASS: Blame history presentation \(which)")
        }catch{c.clean();NSApp.windows.forEach{w in if let sheet=w.attachedSheet{w.endSheet(sheet,returnCode:.abort);sheet.close()};w.close()};try? await wait{drained()};throw error}
    }
}
