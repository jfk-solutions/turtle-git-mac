// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func finderServicesQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-18000,y:-18000));finderServicesQAOrder(mode,relativeTo:number)
    }
}

// This legacy workflow receiver injects its instrumented action owner through
// makeStandaloneWorkspace. Distinct scene/action ownership is verified by the
// current dialog-launch receiver, rather than inferred from this private host.

@MainActor private func verifyPublicOpenService(_ entries:[[String:Any]])throws {
    guard entries.count==1,let entry=entries.first,
          entry["NSMessage"] as? String=="openInTurtleGit",entry["NSUserData"] as? String=="open",
          entry["NSPortName"] as? String=="TurtleGit",entry["NSSendFileTypes"] as? [String]==["public.item"],
          entry["NSRestricted"] as? Bool==true,(entry["NSRequiredContext"] as? [String:Any])?.isEmpty==true,
          (entry["NSMenuItem"] as? [String:String])?["default"]=="Open in TurtleGit" else {
        throw NSError(domain:"TurtleGit.NativeServicesInventory",code:1,userInfo:[NSLocalizedDescriptionKey:"Expected one restricted Open in TurtleGit item Service"])
    }
}

private struct FinderServicesScopes:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}
@main struct FinderServicesVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static var diagnostic:()->String = {""}
    @MainActor static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Services timeout at \(line): \(message); \(diagnostic())")
    }
    @MainActor static func board(_ urls:[URL])->NSPasteboard {
        let value=NSPasteboard.withUniqueName()
        let items=urls.map {url -> NSPasteboardItem in let item=NSPasteboardItem();item.setString(url.absoluteString,forType:.fileURL);return item}
        value.writeObjects(items);return value
    }
    @MainActor static func invoke(_ provider:TurtleGitFinderServicesProvider,_ pasteboard:NSPasteboard,_ command:String)->NSString? {
        var error:NSString?
        provider.performFinderAction(pasteboard,userData:command,error:&error)
        return error
    }
    @MainActor static func main()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.finderServicesQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer {for window in NSApp.windows {window.close()};method_exchangeImplementations(original,hidden)}
        switch ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_SERVICES_CASE"] {
        case "provider":try await provider()
        case "routing":try await routing()
        default:throw Failure(description:"Unknown Services case")
        }
        print("PASS: Finder Services case completed")
    }
    @MainActor static func provider()async throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]),first=directory.appendingPathComponent("first 雪\n.txt"),second=directory.appendingPathComponent("second café.txt")
        for file in [first,second] {try Data("unchanged\n".utf8).write(to:file)}
        var packets:[FinderRequest]=[]
        let receiver=TurtleGitFinderServicesProvider {packets.append($0)}
        let modern=board([second,first]);defer {modern.releaseGlobally();receiver.retire()}
        let initial=modern.changeCount
        for (name,action) in [("log",RepositoryAction.log),("commit",.commit),("status",.status),("diff",.diff)] {
            try require(invoke(receiver,modern,name)==nil,"Modern Services \(name) failed")
            try require(packets.last?.action==action && packets.last?.paths.map(\.path)==[second.path,first.path],"Services lost action, order or newline/Unicode URL")
        }
        let folderBoard=board([directory]);defer {folderBoard.releaseGlobally()}
        for (name,action) in [("clone",RepositoryAction.clone),("initialize",.initialize),("registerRepository",.registerRepository)] {
            try require(invoke(receiver,folderBoard,name)==nil && packets.last?.action==action && packets.last?.paths.map(\.path)==[directory.path],"Folder service request changed")
        }
        let legacy=NSPasteboard.withUniqueName();defer {legacy.releaseGlobally()}
        legacy.setPropertyList([first.path,second.path],forType:.init("NSFilenamesPboardType"))
        try require(invoke(receiver,legacy,"log")==nil && packets.last?.paths.map(\.path)==[first.path,second.path],"Legacy filenames lost exact ordered paths")
        let count=packets.count
        for input in ["https://example.invalid/file","file:///tmp/bad%00name","not a URL"] {
            let malformed=NSPasteboard.withUniqueName();defer {malformed.releaseGlobally()}
            let item=NSPasteboardItem();item.setString(input,forType:.fileURL);malformed.writeObjects([item])
            try require(invoke(receiver,malformed,"log") != nil,"Malformed/nonlocal modern file URL accepted: \(input)")
        }
        let mixed=board([first,URL(string:"https://example.invalid/file")!]);defer {mixed.releaseGlobally()}
        try require(invoke(receiver,mixed,"log") != nil,"Partially invalid modern selection was silently truncated")
        let heterogeneous=NSPasteboard.withUniqueName();defer {heterogeneous.releaseGlobally()}
        let fileItem=NSPasteboardItem(),textItem=NSPasteboardItem();fileItem.setString(first.absoluteString,forType:.fileURL);textItem.setString("not a file",forType:.string);heterogeneous.writeObjects([fileItem,textItem])
        try require(invoke(receiver,heterogeneous,"log") != nil,"Heterogeneous modern selection was narrowed")
        let plain=NSPasteboard.withUniqueName();defer {plain.releaseGlobally()};plain.setString(first.path,forType:.string)
        try require(invoke(receiver,plain,"log") != nil,"Plain text was treated as a Finder grant")
        try require(invoke(receiver,modern,"unknown") != nil && packets.count==count,"Invalid Services command dispatched")
        try require(modern.changeCount==initial,"Service modified input pasteboard")
        receiver.retire();try require(invoke(receiver,modern,"log") != nil && packets.count==count,"Retired provider dispatched")
        let plist=try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])),format:nil) as! [String:Any]
        let services=plist["NSServices"] as? [[String:Any]] ?? []
        try verifyPublicOpenService(services)
        try require(receiver.responds(to:NSSelectorFromString("performFinderAction:userData:error:")) && receiver.responds(to:NSSelectorFromString("openInTurtleGit:userData:error:")),"Public/legacy Objective-C selectors unavailable")
        // An invocation accepted before the workspace exists is delivered once,
        // after startup, through the same ordered open-URL queue.
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotWriter:{_ in false})
        let delegate=TurtleGitApplicationDelegate();delegate.startupArguments=[];delegate.startupDirectory=directory.path
        delegate.activateStandaloneApplication={}
        var preparations=0,preparationReply:CheckedContinuation<Void,Never>?
        delegate.prepareGitConfigurationReads={preparations += 1;await withCheckedContinuation {preparationReply=$0}}
        defer {preparationReply?.resume();delegate.retireFinderServices();workspace.stopMonitoringForTermination();delegate.actionErrorController?.close()}
        var sequence:[String]=[];delegate.startupCommandHandler={_,_,_ in sequence.append("startup")}
        delegate.workspaceServiceHandler={model,request in if model === workspace {sequence.append(request.action.rawValue)};return true}
        try require(invoke(delegate.finderServicesProvider,modern,"log")==nil && sequence.isEmpty,"Cold service escaped startup queue")
        try require(invoke(delegate.finderServicesProvider,modern,"commit") != nil && delegate.pendingFinderServiceRequest?.action == .log,"Second cold service overwrote accepted request")
        delegate.startupDidFinishLaunching();try require(sequence.isEmpty,"Service dispatched before workspace ownership")
        delegate.makeStandaloneWorkspace={workspace};delegate.repositoryModel=workspace
        try await wait("held cold Services configuration preparation") {preparationReply != nil}
        try require(preparations==1 && sequence==["startup"] && delegate.pendingFinderServiceRequest?.action == .log,"Service escaped or duplicated configuration preparation")
        try require(invoke(delegate.finderServicesProvider,modern,"commit") != nil && delegate.pendingFinderServiceRequest?.action == .log,"Pending configuration service was overwritten")
        preparationReply?.resume();preparationReply=nil
        try await wait("startup before exactly-once Services delivery") {delegate.gitConfigurationReadsReady && sequence==["startup",RepositoryAction.log.rawValue]}
        delegate.startupDidFinishLaunching()
        try require(sequence==["startup",RepositoryAction.log.rawValue],"Startup did not precede once-only service delivery")
        try require(preparations==1,"Warm startup repeated Services configuration preparation")
        try require(invoke(delegate.finderServicesProvider,modern,"commit")==nil && sequence.last==RepositoryAction.commit.rawValue,"Warm Services delivery failed")
        let envelope=try FinderServiceCommand.status.serviceURL(paths:[first])
        delegate.application(NSApp,open:[envelope])
        try require(sequence.last==RepositoryAction.status.rawValue,"Workspace service envelope bypassed typed handler")
        let delivered=sequence
        workspace.busy=true;try require(invoke(delegate.finderServicesProvider,modern,"log") != nil && sequence==delivered,"Busy workspace service was lost without rejection")
        workspace.busy=false;workspace.confirmingQuit=true
        try require(invoke(delegate.finderServicesProvider,modern,"log") != nil && sequence==delivered,"Quit allowed service submission")
        workspace.confirmingQuit=false;delegate.retireFinderServices()
        try require(invoke(delegate.finderServicesProvider,modern,"log") != nil && sequence==delivered,"Retired delegate accepted service")
        workspace.stopMonitoringForTermination()
        let queued=TurtleGitApplicationDelegate(),queuedWorkspace=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotWriter:{_ in false})
        queued.makeStandaloneWorkspace={queuedWorkspace};queued.startupArguments=[];queued.startupCommandHandler={model,_,_ in model.busy=true}
        queued.activateStandaloneApplication={}
        var queuedPreparation:CheckedContinuation<Void,Never>?
        queued.prepareGitConfigurationReads={await withCheckedContinuation {queuedPreparation=$0}}
        defer {queuedPreparation?.resume();queued.retireFinderServices();queuedWorkspace.stopMonitoringForTermination();queued.actionErrorController?.close()}
        var queuedCalls=0;queued.workspaceServiceHandler={_,_ in queuedCalls += 1;return true}
        try require(invoke(queued.finderServicesProvider,modern,"log")==nil,"Cold queued request was refused")
        queued.repositoryModel=queuedWorkspace;queued.startupDidFinishLaunching()
        try await wait("held later-busy Services preparation") {queuedPreparation != nil}
        try require(queued.pendingFinderServiceRequest?.action == .log && queuedCalls==0,"Busy startup lost pending service before preparation settled")
        queuedPreparation?.resume();queuedPreparation=nil
        try await wait("later-busy queued Service explicit failure") {queued.gitConfigurationReadsReady && queued.pendingFinderServiceRequest==nil && queuedWorkspace.error != nil}
        try require(queuedCalls==0 && queued.pendingFinderServiceRequest==nil && queuedWorkspace.error != nil,"Later-busy startup silently dropped queued service")
        queued.retireFinderServices();queuedWorkspace.stopMonitoringForTermination()
        // The shared configuration barrier must also preserve the whole URL
        // cohort before delivering the separately accepted typed Service.
        let fifo=TurtleGitApplicationDelegate(),fifoWorkspace=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotWriter:{_ in false})
        fifo.startupArguments=[];fifo.startupDirectory=directory.path;fifo.makeStandaloneWorkspace={fifoWorkspace};fifo.activateStandaloneApplication={}
        var fifoEvents:[String]=[],fifoPreparations=0,fifoReply:CheckedContinuation<Void,Never>?,fifoOwnerCorrect=true
        fifo.prepareGitConfigurationReads={fifoPreparations += 1;await withCheckedContinuation {fifoReply=$0}}
        fifo.startupCommandHandler={_,_,_ in fifoEvents.append("startup")}
        fifo.workspaceOpenHandler={model,url in fifoOwnerCorrect = fifoOwnerCorrect && model === fifoWorkspace;fifoEvents.append("url-"+(FinderRequest(url:url)?.action.rawValue ?? "invalid"))}
        fifo.workspaceServiceHandler={model,request in fifoOwnerCorrect = fifoOwnerCorrect && model === fifoWorkspace;fifoEvents.append("service-"+request.action.rawValue);return true}
        defer {fifoReply?.resume();fifo.retireFinderServices();fifoWorkspace.stopMonitoringForTermination();fifo.actionErrorController?.close()}
        try require(invoke(fifo.finderServicesProvider,modern,"log")==nil,"Cold FIFO service was not accepted")
        fifo.application(NSApp,open:[FinderRequest(action:.status,paths:[first]).url!,FinderRequest(action:.diff,paths:[first,second]).url!])
        fifo.repositoryModel=fifoWorkspace;fifo.startupDidFinishLaunching()
        try await wait("held startup URL cohort and Service") {fifoReply != nil}
        try require(fifoEvents==["startup"] && fifo.pendingFinderServiceRequest?.action == .log,"URL cohort escaped the configuration barrier")
        fifoReply?.resume();fifoReply=nil
        let expectedFIFO=["startup","url-status","url-diff","service-log"]
        try await wait("ordered URL cohort before once-only typed Service") {fifoEvents==expectedFIFO}
        fifo.startupDidFinishLaunching();await Task.yield()
        try require(fifoEvents==expectedFIFO && fifoPreparations==1 && fifoOwnerCorrect,"Startup replay duplicated/reordered delivery or changed its action owner")
        let previous=NSApp.servicesProvider,sentinel=NSObject(),registration=TurtleGitApplicationDelegate()
        NSApp.servicesProvider=sentinel;defer {NSApp.servicesProvider=previous;registration.retireFinderServices()}
        registration.installFinderServices();registration.installFinderServices()
        try require((NSApp.servicesProvider as AnyObject?) === registration.finderServicesProvider,"Provider registration absent")
        registration.retireFinderServices()
        try require((NSApp.servicesProvider as AnyObject?) === sentinel,"Provider retirement did not restore prior owner")
        // A standalone Git tool hands Services to an independent workspace,
        // retaining the Launch Services receipt until its actual completion.
        let base=directory.appendingPathComponent("base"),mine=directory.appendingPathComponent("mine")
        try Data("base\n".utf8).write(to:base);try Data("mine\n".utf8).write(to:mine)
        let tool=TurtleGitApplicationDelegate();tool.startupArguments=["--merge-tool","--base",base.path,"--mine",mine.path,"--readonly"];tool.startupDirectory=directory.path
        var launches:[[URL]]=[],reply:((Error?)->Void)?
        tool.workspaceOpenHandoff.launch={urls,_,configuration,completion in
            launches.append(urls);reply=completion
            precondition(configuration.createsNewApplicationInstance && configuration.arguments == ["--turtlegit-action-only"])
        }
        try require(invoke(tool.finderServicesProvider,modern,"diff")==nil && launches.count==1 && tool.workspaceOpenHandoff.hasPendingWork,"Standalone tool swallowed Services request")
        let decoded=try launches[0].map{try FinderServiceCommand.request(serviceURL:$0)}
        try require(decoded.count==1 && decoded[0].action == .diff && decoded[0].paths.map(\.path)==[second.path,first.path],"Tool handoff changed selected action/files")
        try require(tool.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored pending Services handoff")
        tool.retireFinderServices();tool.workspaceOpenHandoff.retire();reply?(nil);reply=nil
        try require(!tool.workspaceOpenHandoff.hasPendingWork && invoke(tool.finderServicesProvider,modern,"log") != nil,"Retired tool leaked receipt or accepted a late service")
        try require(try Data(contentsOf:first)==Data("unchanged\n".utf8),"Services mutated selected file")
        print("PASS: private NSPasteboard modern/legacy strict ordered Services, malformed/mixed rejection, declared plist selectors, cold/warm/busy/Quit lifecycle and standalone launch receipt")
    }
    @MainActor static func routing()async throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.FinderServices."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        func repository(_ name:String)async throws->GitRepository {
            let root=directory.appendingPathComponent(name);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:git);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Services QA"),("user.email","services@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            for file in ["first 雪\n.txt","second café.txt"] {try Data("base\n".utf8).write(to:root.appendingPathComponent(file))}
            var paths=["first 雪\n.txt","second café.txt"]
            if name=="repoA" {try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("directory link"),withDestinationURL:directory.appendingPathComponent("repoB"));paths.append("directory link")}
            try await repo.stage(paths);_ = try await repo.commit(message:"Services baseline");return repo
        }
        let a=try await repository("repoA"),b=try await repository("repoB")
        let headA=try await a.run(["rev-parse","HEAD"]).stdout,headB=try await b.run(["rev-parse","HEAD"]).stdout,indexA=try Data(contentsOf:a.root.appendingPathComponent(".git/index")),indexB=try Data(contentsOf:b.root.appendingPathComponent(".git/index"))
        let store=try RepositoryAccessStore(storageURL:directory.appendingPathComponent("permissions.json"),provider:FinderServicesScopes());try store.remember(a.root);try store.remember(b.root)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},savedAccessStore:store,comparisonMarks:WorkingComparisonMarkStore(storageURL:directory.appendingPathComponent("marks.json")))
        workspace.repositoryBookmarkProvider=FinderServicesScopes();workspace.requiresRepositoryScope=true;workspace.fileComparisonPreferences=prefs
        var logs:[LogWindowController]=[]
        let host=NSWindow(contentRect:NSRect(x:-3000,y:-3000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);workspace.workspaceWindow=host
        defer {logs.forEach{$0.close()};host.close();workspace.stopMonitoringForTermination();diagnostic={""}}
        diagnostic={"busy=\(workspace.busy), root=\(String(describing:workspace.root)), expectedA=\(a.root.absoluteString), expectedB=\(b.root.absoluteString), error=\(String(describing:workspace.error)), pendingServices=\(workspace.hasPendingFinderServiceWork), pendingRepository=\(workspace.hasPendingRepositoryWork), sheet=\(String(describing:host.attachedSheet)), logs=\(logs.map{"root=\($0.model.repository.root.absoluteString), busy=\($0.model.busy), paths=\($0.model.historyPaths)"})"}
        workspace.logWindowFactory={repo,access in
            let value=LogWindowController(repository:repo,access:access,labelDefaults:prefs,loadsImmediately:false);value.window?.alphaValue=0;value.window?.setFrameOrigin(NSPoint(x:-3000,y:-3000));logs.append(value);return value
        }
        workspace.logWindowPresentation={owner in owner.window?.alphaValue=0}
        workspace.open(b.root);try await wait("initial workspace B") {!workspace.busy && workspace.root?.path==b.root.path}
        let delegate=TurtleGitApplicationDelegate();delegate.startupArguments=[];delegate.startupCommandHandler={_,_,_ in};delegate.activateStandaloneApplication={};delegate.prepareGitConfigurationReads={};delegate.makeStandaloneWorkspace={workspace};delegate.repositoryModel=workspace;delegate.startupDidFinishLaunching();defer {delegate.retireFinderServices()}
        let files=[a.root.appendingPathComponent("second café.txt"),a.root.appendingPathComponent("first 雪\n.txt")],selection=board(files);defer {selection.releaseGlobally()}
        try require(invoke(delegate.finderServicesProvider,selection,"log")==nil,"Real Services Log request rejected")
        try await wait("real selected repo A Log") {!workspace.busy && workspace.root?.path==a.root.path && logs.count==1 && !logs[0].model.busy}
        try require(logs[0].model.repository.root.path==a.root.path && logs[0].model.historyPaths==files.map{$0.lastPathComponent},"Services used workspace B or changed selected file scope/order")
        try require(logs[0].window?.isVisible==false && logs[0].model.colorPreferences===prefs,"Services native Log lost hidden/private presentation")
        logs[0].close();logs=[]
        workspace.open(b.root);try await wait("workspace B before literal symlink service") {!workspace.busy && workspace.root?.path==b.root.path}
        let symlink=a.root.appendingPathComponent("directory link"),symlinkBoard=board([symlink]);defer {symlinkBoard.releaseGlobally()}
        try require(invoke(delegate.finderServicesProvider,symlinkBoard,"log")==nil,"Directory symlink Services request rejected")
        try await wait("literal symlink Log remains in A") {!workspace.busy && logs.count==1 && !logs[0].model.busy}
        try require(workspace.root?.path==a.root.path && logs[0].model.repository.root.path==a.root.path && logs[0].model.historyPaths==["directory link"],"Directory symlink selection followed target repository B")
        try require(try FileManager.default.destinationOfSymbolicLink(atPath:symlink.path)==b.root.path,"Services rewrote directory symlink")
        logs[0].close();logs=[]
        // The first service to an unsaved repository owns an actual native
        // folder panel. Cancellation must drain the sheet and fence late replies.
        let c=try await repository("unsaved repoC")
        workspace.open(b.root);try await wait("workspace B before primary grant") {!workspace.busy && workspace.root?.path==b.root.path}
        var panels:[NSOpenPanel]=[],panelReply:((NSApplication.ModalResponse)->Void)?,selectedFolder:URL?
        defer {panelReply?(.cancel);for panel in panels {if let parent=panel.sheetParent {parent.endSheet(panel,returnCode:.cancel)};panel.close()}}
        workspace.presentFinderServiceFolderPanel={panel,owner,reply in
            panels.append(panel);panelReply=reply;panel.alphaValue=0;panel.setFrameOrigin(NSPoint(x:-3000,y:-3000));if let owner {owner.beginSheet(panel,completionHandler:nil)}
        }
        workspace.selectedFinderServiceFolderURL={_ in selectedFolder}
        let unsavedSelection=board([c.root.appendingPathComponent("first 雪\n.txt")]);defer {unsavedSelection.releaseGlobally()}
        try require(invoke(delegate.finderServicesProvider,unsavedSelection,"log")==nil,"Unsaved Services request was rejected before permission")
        try await wait("owned primary grant") {panelReply != nil && host.attachedSheet===panels.last}
        try require(workspace.hasPendingFinderServiceWork && delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Primary grant lacks Quit ownership")
        try require(panels.last?.alphaValue==0 && panels.last?.canChooseDirectories==true && panels.last?.canChooseFiles==false,"Services permission panel lost hidden folder policy")
        try require(invoke(delegate.finderServicesProvider,unsavedSelection,"log") != nil && panels.count==1,"Busy Services duplicated primary permission")
        let late=panelReply;panelReply?(.cancel);panelReply=nil
        try await wait("cancelled primary permission detached") {!workspace.hasPendingFinderServiceWork && host.attachedSheet==nil}
        selectedFolder=c.root;late?(.OK)
        try require(workspace.root?.path==b.root.path && logs.isEmpty,"Late cancelled primary grant adopted repository")
        try require(invoke(delegate.finderServicesProvider,unsavedSelection,"log")==nil,"Primary permission retry rejected")
        try await wait("retried primary permission") {panelReply != nil}
        panelReply?(.OK);panelReply=nil
        try await wait("accepted primary service opened actual Log") {!workspace.hasPendingFinderServiceWork && !workspace.busy && workspace.root?.path==c.root.path && logs.count==1 && !logs[0].model.busy}
        try require(host.attachedSheet==nil && logs[0].model.repository.root.path==c.root.path,"Accepted grant presented Log before permission detachment or used wrong repository")
        logs[0].close();logs=[]
        // A linked worktree requires a separate metadata grant. Hold the real
        // chooser boundary, close its initiating owner, then deliver a late grant.
        let worktree=directory.appendingPathComponent("linked worktree"),linked=GitRepository(root:worktree,executable:git)
        _ = try await a.run(["worktree","add","-b","linked-service",worktree.path]);try store.remember(worktree)
        workspace.open(b.root);try await wait("restore workspace B") {!workspace.busy && workspace.root?.path==b.root.path}
        var continuation:CheckedContinuation<URL?,Error>?,token:OperationCancellation?
        defer {continuation?.resume(throwing:Failure(description:"Fixture cleanup"));continuation=nil}
        workspace.chooseRepositoryMetadataFolder={_,cancellation in token=cancellation;return try await withCheckedThrowingContinuation {continuation=$0}}
        let linkedSelection=board([worktree.appendingPathComponent("first 雪\n.txt")]);defer {linkedSelection.releaseGlobally()}
        try require(invoke(delegate.finderServicesProvider,linkedSelection,"log")==nil,"Linked Services request not accepted")
        try await wait("held actual metadata permission") {continuation != nil && workspace.busy}
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit released pending service authorization")
        host.close();try require(token?.isCancelled==true && workspace.busy,"Owner close lost grant token/drain ownership")
        continuation?.resume(returning:a.root);continuation=nil
        try await wait("late permission drained") {!workspace.busy}
        try require(workspace.root?.path==b.root.path && logs.isEmpty && workspace.error==nil,"Late retired grant adopted repository or opened Log")
        let afterA=try await a.run(["rev-parse","HEAD"]).stdout,afterB=try await b.run(["rev-parse","HEAD"]).stdout
        try require(afterA==headA && afterB==headB && (try Data(contentsOf:a.root.appendingPathComponent(".git/index")))==indexA && (try Data(contentsOf:b.root.appendingPathComponent(".git/index")))==indexB,"Services routing changed HEAD/index")
        _ = try await linked.run(["rev-parse","HEAD"])
        print("PASS: actual private Git repoA Services Log while workspace repoB, scoped native controller, pending metadata grant Quit/owner close/late callback fencing, HEAD/index preservation")
    }
}
