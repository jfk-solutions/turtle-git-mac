// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore

private extension NSWindow {
    @objc func syncTransferHiddenOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));syncTransferHiddenOrder(mode,relativeTo:number)
    }
}
@MainActor @main enum SyncTransferNotificationsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(description:"Sync notifications line \(line): \(message)")}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Sync notifications readiness timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func own(_ controller:NSWindowController){controller.window?.orderFront(nil)}
    static func drained()->Bool {SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),helper=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.SyncNotifications."+UUID().uuidString,replacementSuite="TurtleGit.SyncNotificationsReplacement."+UUID().uuidString
        let preferences:UserDefaults,replacement:UserDefaults
        let pasteboard=NSPasteboard(name:.init("TurtleGit.SyncNotifications."+UUID().uuidString))
        var syncs:[SynchronizationWindowController]=[],logs:[LogWindowController]=[],sheets:[NSWindow]=[]
        var workspace:RepositoryModel?,host:NSWindow?,old="",new="",head=Data(),index=Data(),config=Data()
        var expectedFetchSpecs:[String]=[]
        var repository:GitRepository {GitRepository(root:root.appendingPathComponent("client"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false,helperURL:root.appendingPathComponent("held-helper")))}
        var hold:URL {root.appendingPathComponent("hold")};var started:URL {root.appendingPathComponent("helper-finished")}
        init(){preferences=UserDefaults(suiteName:suite)!;replacement=UserDefaults(suiteName:replacementSuite)!;preferences.set(true,forKey:"UseLibgit2");preferences.set(4,forKey:"UseLibgit2_mask");preferences.set(false,forKey:"ConfirmKillProcess")}
        func seed()async throws {
            let author=root.appendingPathComponent("author"),bare=root.appendingPathComponent("origin.git")
            try FileManager.default.createDirectory(at:author,withIntermediateDirectories:true)
            let source=GitRepository(root:author,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await source.run(["init","-b","main"])
            for(key,value)in[("user.name","Sync notification QA"),("user.email","sync@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await source.run(["config",key,value])}
            try Data("base\n".utf8).write(to:author.appendingPathComponent("file.txt"));try await source.stage(["file.txt"]);_=try await source.commit(message:"private base")
            old=String(decoding:try await source.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            _=try await source.run(["clone","--bare","--template=","--",author.path,bare.path]);_=try await source.run(["clone","--template=","--",bare.path,repository.root.path])
            try Data("incoming 雪\n".utf8).write(to:author.appendingPathComponent("file.txt"));try await source.stage(["file.txt"]);_=try await source.commit(message:"private incoming 雪")
            new=String(decoding:try await source.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            _=try await source.run(["push",bare.path,"HEAD:refs/heads/main"])
            let script="#!/bin/sh\n"+quote(helper.path)+" \"$@\"\nresult=$?\n: > "+quote(started.path)+"\nwhile test -f "+quote(hold.path)+"; do /bin/sleep 0.05; done\nexit \"$result\"\n"
            try Data(script.utf8).write(to:root.appendingPathComponent("held-helper"));try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.appendingPathComponent("held-helper").path)
        }
        func open()async throws->SynchronizationWindowController {
            let access=try RepositoryAccessStore(storageURL:root.appendingPathComponent("access.json"))
            let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[git,root] in GitRepository(root:$0,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false,helperURL:root.appendingPathComponent("held-helper")))},snapshotWriter:{_ in false},savedAccessStore:access,cachePersistenceDefaults:preferences,publishCachePersistence:{_ in})
            self.workspace=workspace;workspace.fileComparisonPreferences=preferences
            let host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;self.host=host;host.orderFront(nil);workspace.workspaceWindow=host
            workspace.synchronizationWindowPresentation={ [weak self] in self?.syncs.append($0);own($0)}
            workspace.logWindowPresentation={ [weak self] in self?.logs.append($0);own($0)}
            workspace.open(repository.root);try await wait(host){!workspace.busy && workspace.root?.path==self.repository.root.path}
            workspace.showSynchronization();try await wait{self.syncs.count==1 && !self.syncs[0].model.busy && !self.syncs[0].model.hasPendingInlineWork && self.syncs[0].model.outgoing != nil}
            let owner=syncs[0];owner.model.sshSettings.enabled=false;owner.model.localBranch="main";owner.model.remote="origin";owner.model.remoteBranch="main"
            owner.model.notifications.publishClipboard={ [pasteboard] value in pasteboard.clearContents();pasteboard.setString(value,forType:.string)}
            head=try await repository.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:repository.root.appendingPathComponent(".git/index"));config=try Data(contentsOf:repository.root.appendingPathComponent(".git/config"))
            return owner
        }
        func preserved()async throws {
            let currentHead=try await repository.run(["rev-parse","HEAD"]).stdout,currentIndex=try Data(contentsOf:repository.root.appendingPathComponent(".git/index")),currentConfig=try Data(contentsOf:repository.root.appendingPathComponent(".git/config"))
            try require(head==currentHead && index==currentIndex,"Fetch changed local HEAD/index")
            let baseline=root.appendingPathComponent("original-config-witness")
            try config.write(to:baseline)
            let original=try await repository.run(["config","--file",baseline.path,"--null","--list"]).stdout.split(separator:0).map{Data($0)}
            let actual=try await repository.run(["config","--local","--null","--list"]).stdout.split(separator:0).map{Data($0)}
            let fetchKey=Data("remote.origin.fetch\n".utf8)
            try require(actual.filter{!$0.starts(with:fetchKey)}==original.filter{!$0.starts(with:fetchKey)},"Fetch changed unrelated configuration records")
            let expected=original.filter{$0.starts(with:fetchKey)}+expectedFetchSpecs.map{fetchKey+Data($0.utf8)}
            try require(actual.filter{$0.starts(with:fetchKey)}==expected,"Fetch configuration differs from the exact accepted source refspec appends")
            _=currentConfig // Raw config formatting is owned by libgit2's writer.
            try require(try Data(contentsOf:repository.root.appendingPathComponent("file.txt"))==Data("base\n".utf8),"Fetch changed worktree bytes")
        }
        func cleanup()async {
            try? FileManager.default.removeItem(at:hold)
            for sheet in sheets {sheet.sheetParent?.endSheet(sheet,returnCode:.abort);sheet.close()}
            for owner in syncs {owner.close()};for owner in logs {owner.close()}
            workspace?.stopMonitoringForTermination();host?.close()
            for _ in 0..<3000 {if drained() && syncs.allSatisfy({!$0.model.hasPendingInlineWork}){break};try? await Task.sleep(nanoseconds:10_000_000)}
            for window in NSApp.windows {window.orderOut(nil);window.close()}
            preferences.removePersistentDomain(forName:suite);replacement.removePersistentDomain(forName:replacementSuite);pasteboard.releaseGlobally()
        }
    }
    static func table(_ owner:SynchronizationWindowController)async throws->(FileOperationProgressNativeTable,FileOperationProgressTable.Coordinator) {
        owner.model.tab=2
        try await wait(owner.window){views(owner.window?.contentView).contains{$0 is FileOperationProgressNativeTable}}
        let table=try unwrap(views(owner.window?.contentView).compactMap{$0 as? FileOperationProgressNativeTable}.first,"Actual Action/Path table missing")
        let coordinator=try unwrap(table.dataSource as? FileOperationProgressTable.Coordinator,"Actual notification coordinator missing")
        try await wait(owner.window){coordinator.rows.count==owner.model.notifications.rows.count && coordinator.generation==owner.model.notifications.generation && coordinator.parent.available==owner.model.notificationActionsAvailable && coordinator.parent.keyboardAvailable==owner.model.notificationKeyboardAvailable}
        return(table,coordinator)
    }
    static func invoke(_ item:NSMenuItem)throws {let action=try unwrap(item.action,"Native action missing");_=NSApp.sendAction(action,to:item.target,from:item)}
    static func actual(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model;c.workspace?.fileComparisonPreferences=c.replacement
        c.workspace?.open(c.root.appendingPathComponent("author"));try await wait(c.host){c.workspace?.busy==false && c.workspace?.root?.lastPathComponent=="author"}
        c.expectedFetchSpecs.append("refs/heads/main:refs/remotes/origin/main")
        model.fetch();try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && model.commandCompleted}
        try require(model.commandSucceeded && model.showsNotifications,"Actual libgit2 fetch did not publish structured completion: \(model.error ?? model.commandOutput)")
        var (native,coordinator)=try await table(owner)
        try require(native.tableColumns.map{$0.title}==["Action","Path"],"Actual source Action/Path columns missing")
        let row=try unwrap(coordinator.rows.firstIndex{$0.kind == .reference && $0.path.contains("refs/remotes/origin/main")},"Actual fetched ref notification missing")
        let value=coordinator.rows[row]
        try require(value.reference?.oldHash==c.old && value.reference?.newHash==c.new && value.path.contains("Forward 1") && value.action=="Update ref","Real callback hashes/classification were lost")
        try require(coordinator.rows.first?.kind == .command && coordinator.rows.last?.kind == .finished,"Actual structured command/finish rows missing")
        let caption=try unwrap(coordinator.rows.first?.path,"Accepted command caption missing")
        try require(caption=="Fetch origin refs/heads/main:refs/remotes/origin/main","Accepted libgit2 Fetch caption omitted remote/refspec context")
        model.remote="unaccepted-form-edit";model.remoteBranch="unaccepted-branch-edit"
        try require(model.notifications.rows.first?.path==caption,"Editing current form retargeted the accepted Fetch command caption")
        model.remote="origin";model.remoteBranch="main"
        native.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);coordinator.copySelected()
        try require(c.pasteboard.string(forType:.string)==value.action+": "+value.path+"  \r\n","Keyboard copy lost Action/Path text")
        let menu=try unwrap(coordinator.menu(),"Reference row context menu missing")
        try require(menu.items.filter{!$0.isSeparatorItem}.map{$0.title}==["Show Log","Copy to Clipboard"] && menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Reference menu invented file/Compare actions or omitted source icons")
        try invoke(menu.items.last!);try require(c.pasteboard.string(forType:.string)==value.path.trimmingCharacters(in:.whitespacesAndNewlines),"Context copy lost exact reference text")
        let logMenu=try unwrap(coordinator.menu(),"Fresh Log menu missing");try invoke(logMenu.items[0])
        try await wait{c.logs.count==1 && !c.logs[0].model.busy}
        let log=c.logs[0].model
        try require(log.revisionRange?.from==c.old && log.revisionRange?.to==c.new && log.repository.root==c.repository.root && log.colorPreferences===c.preferences,"Actual workspace Show Log lost captured full hashes/root/preferences")
        (native,coordinator)=try await table(owner);native.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:150,height:90),styleMask:.titled,backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;c.sheets.append(sheet)
        let blocked=try unwrap(coordinator.menu(),"Pre-sheet menu missing");owner.window?.beginSheet(sheet,completionHandler:{_ in});try invoke(blocked.items[0]);model.onNotificationLog(c.repository,nil,[],c.old,c.new);try require(c.logs.count==1,"Retained menu/caller crossed actual owner sheet")
        owner.window?.endSheet(sheet,returnCode:.cancel);try await wait{sheet.sheetParent==nil};sheet.close()
        (native,coordinator)=try await table(owner);native.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        let preTab=try unwrap(coordinator.menu(),"Pre-tab menu missing");model.tab=0;model.tab=2;try invoke(preTab.items[0]);try require(c.logs.count==1,"Retained menu revived after Log-tab replacement")
        model.confirmingQuit=true;model.onNotificationLog(c.repository,nil,[],c.old,c.new);try require(c.logs.count==1,"Workspace callback crossed Quit fence");model.confirmingQuit=false
        (native,coordinator)=try await table(owner);native.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        try await wait(owner.window){model.notificationActionsAvailable}
        try await capture(try unwrap(owner.window,"Capture owner missing"))
        let stale=try unwrap(coordinator.menu(),"Pre-close menu missing");owner.close();try await wait{model.closed && !model.hasPendingInlineWork && SynchronizationWindowController.activeInlineReleases==0}
        try invoke(stale.items[0]);model.onNotificationLog(c.repository,nil,[],c.old,c.new);try require(c.logs.count==1,"Closed workspace callback/menu revived Log")
    }
    static func separation(_ c:Context)async throws {
        c.preferences.set(false,forKey:"UseLibgit2");let owner=try await c.open(),model=owner.model
        model.fetch();try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && model.commandCompleted}
        try require(model.commandSucceeded && !model.showsNotifications && model.commandOutput.contains("From"),"CLI Fetch lost original rich text or adopted structured rows")
        model.tab=2;try await wait(owner.window){!views(owner.window?.contentView).contains{$0 is FileOperationProgressNativeTable}}
        c.preferences.set(true,forKey:"UseLibgit2");model.remote=c.root.appendingPathComponent("unavailable-private-remote.git").path;model.remoteBranch="main";model.fetch()
        try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && model.commandCompleted}
        try require(!model.commandSucceeded && model.showsNotifications && model.notifications.rows.contains{$0.kind == .error} && model.notifications.rows.last?.kind == .finished,"Real local Fetch failure lost typed Error/Finished rows")
        try require(!model.notifications.rows.contains{$0.kind == .reference},"Failed unavailable local remote fabricated reference updates")
    }
    static func lifetime(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model
        c.expectedFetchSpecs.append("refs/heads/main:refs/remotes/origin/main")
        try Data().write(to:c.hold);model.fetch()
        try await wait(owner.window){FileManager.default.fileExists(atPath:c.started.path) && model.notifications.rows.contains{$0.kind == .reference}}
        try require(model.busy && model.hasPendingInlineWork && SynchronizationWindowModel.activeInlineOperations>0,"Held actual producer was released before exit")
        c.preferences.set(false,forKey:"UseLibgit2");try require(model.notificationBackend?.enabled==true && model.showsNotifications,"Running Fetch lost its captured backend after preference change")
        let (native,coordinator)=try await table(owner);native.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);coordinator.copySelected()
        try require(c.pasteboard.string(forType:.string) != nil && coordinator.menu()==nil,"Running transfer copy/action availability incorrect")
        model.cancelTransport();try await wait(owner.window){!model.busy && !model.hasPendingInlineWork}
        try require(model.commandCancelled && model.notifications.rows.contains{$0.kind == .reference},"Cancel lost accepted reference receipt or failed to wait for producer")
        c.preferences.set(true,forKey:"UseLibgit2");try? FileManager.default.removeItem(at:c.started);try Data().write(to:c.hold)
        c.expectedFetchSpecs.append("refs/heads/main:refs/remotes/origin/main")
        model.fetch();try await wait(owner.window){FileManager.default.fileExists(atPath:c.started.path) && model.busy}
        var closed=0;owner.onClosed={closed+=1};model.confirmingQuit=true
        try require(!model.notificationActionsAvailable && !model.notificationKeyboardAvailable,"Quit did not fence notification actions/copy")
        owner.close();let rows=model.notifications.rows.map(\.id),generation=model.notifications.generation
        try await wait{closed==1 && !model.hasPendingInlineWork && SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0}
        try? FileManager.default.removeItem(at:c.hold)
        try require(model.closed && model.notifications.rows.map(\.id)==rows && model.notifications.generation==generation,"Retired producer mutated notification rows/generation")
    }
    static func capture(_ window:NSWindow)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_TRANSFER_CAPTURES"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance;defer{window.alphaValue=alpha;window.appearance=appearance}
        window.orderFront(nil);window.alphaValue=1
        for(theme,name)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture window missing")
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2);options.showsCursor=false;options.ignoreShadowsSingleWindow=true;options.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:options)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),"Capture PNG missing")
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("sync-fetch-notifications-log-"+name+".png"));print("Owned Sync capture: \(name) \(image.width)x\(image.height)")
        }
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.syncTransferHiddenOrder(_:relativeTo:))){method_exchangeImplementations(original,hidden)}
        let c=Context(),kind=CommandLine.arguments[4]
        do {try await c.seed();switch kind {case "actual":try await actual(c);case "separation":try await separation(c);case "lifetime":try await lifetime(c);default:throw Failure(description:"Unknown case")};try await c.preserved();await c.cleanup();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Sync/Log windows/work did not drain");print("PASS: Sync transfer notifications "+kind);fflush(stdout)}
        catch {await c.cleanup();fputs("Sync transfer notifications failed: \(error)\n",stderr);fflush(stderr);exit(1)}
    }
}
